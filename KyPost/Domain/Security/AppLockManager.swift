//
//  AppLockManager.swift
//  KyPost
//
//  App-lock state and the unlock decision (security-hardening plan, Task 1;
//  PIN, lockout and wipe from Phase 11). "Locked" means "has the user
//  authenticated since the lock last engaged" — in-memory only, never
//  persisted.
//
//  There are two verifiers, and they are throttled by different things.
//  `LAContext.deviceOwnerAuthentication` is the OS's, and the OS rate-limits
//  it; a PIN set here is checked in this process, so **this file owns its
//  throttle**. That is the reversal Phase 11 makes: the original note said
//  lockout was the OS's job, which was true only while there was nothing of
//  ours to guess at.
//

import Darwin
import Foundation
import LocalAuthentication
import Observation
import os

/// How the app verifies the device owner. Production wraps `LAContext`;
/// tests inject a stub (LAContext cannot run headless).
protocol DeviceAuthenticating {
    /// Whether the device has any owner authentication configured at all
    /// (passcode/login password at minimum).
    func canAuthenticate() -> Bool
    func authenticate(reason: String) async -> Bool
    /// The unlock prompt, which needs to know *why* it did not succeed: a
    /// prompt the user or the system dismissed is not a failed attempt.
    func authenticateForUnlock(reason: String) async -> DeviceAuthOutcome
}

extension DeviceAuthenticating {
    func authenticateForUnlock(reason: String) async -> DeviceAuthOutcome {
        await authenticate(reason: reason) ? .success : .failed
    }
}

/// How one device-owner prompt ended.
nonisolated enum DeviceAuthOutcome: Equatable, Sendable {
    case success
    /// The user dismissed the prompt, or the system or app took it down
    /// (`userCancel`, `systemCancel`, `appCancel`). Not evidence the device
    /// can no longer authenticate.
    case cancelled
    case failed
}

nonisolated struct LocalAuthenticationAuthenticator: DeviceAuthenticating {
    func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async -> Bool {
        await authenticateForUnlock(reason: reason) == .success
    }

    func authenticateForUnlock(reason: String) async -> DeviceAuthOutcome {
        // A fresh context per call: LAContext is single-use once invalidated,
        // and reuse can return stale grace-period results.
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            ) ? .success : .failed
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .systemCancel, .appCancel: return .cancelled
            default: return .failed
            }
        } catch {
            return .failed
        }
    }
}

/// How one PIN attempt ended.
///
/// Every caller must switch over the whole of this. Three of Android's tested
/// `result is Success` and treated everything else as a plain false — so a
/// wipe reached from the settings screen showed "Incorrect PIN", left the
/// screen running against a destroyed database, and never relaunched.
nonisolated enum UnlockAttemptOutcome: Equatable, Sendable {
    case success

    /// Wrong PIN. `delayMillis` is how long the field should stay disabled —
    /// zero for the first two attempts.
    case rejected(delayMillis: Int64)

    /// There is no PIN on this machine, so there was nothing to check. Not a
    /// wrong PIN, and it does not advance the wipe counter.
    case notConfigured

    /// **The PIN could not be checked at all** — the device key behind the
    /// stored verifier is gone or unusable, so neither "correct" nor "wrong" is
    /// knowable.
    ///
    /// Distinct from `rejected` because it must not count toward the wipe
    /// threshold. Folding it in meant an OS-level key invalidation made every
    /// correct PIN read as wrong, and ten of those destroyed the user's mail,
    /// contacts and pairing in response to an event they neither caused nor
    /// could avoid.
    case verifierUnavailable

    /// The PIN was right, but the gated device secret could not be read — the
    /// user declined the presence prompt, or the Keychain refused.
    ///
    /// The app stays **locked**, matching `requestUnlock`. Unlocking without
    /// the secret produces an app that looks fine and silently no-ops every
    /// relay call, with no way to retry short of locking and unlocking again.
    case gatedSecretUnavailable

    /// The threshold was reached and the wipe ran cleanly. By the time this
    /// returns, the local data is gone.
    case wiped

    /// The threshold was reached, the wipe ran, and at least one step failed —
    /// so local data may still be here. Distinct from `wiped` because the UI
    /// must not tell the user their data is gone when it might not be.
    case wipeFailed(failedSteps: [String], willRetry: Bool)
}

@Observable
@MainActor
final class AppLockManager {
    private let store: AppLockStore
    private let authenticator: any DeviceAuthenticating

    private(set) var isLocked: Bool
    /// Observable mirror of `store.lockState` so settings toggles track it
    /// (the Keychain-backed store itself is not observation-tracked). True
    /// while the flag is unreadable: an unreadable flag is a locked app.
    private(set) var isLockEnabled: Bool

    /// The lock flag could not be read when this was last decided, so the app
    /// is locked on the assumption that it is on. `refreshLockState` re-reads
    /// it; a later answer of "off" releases the lock without a prompt, "on"
    /// keeps it.
    private(set) var isLockStateUnresolved: Bool

    /// Consecutive failed unlock attempts, reset by any success.
    ///
    /// Drives UnlockView's escape hatch. A device whose biometric enrolment
    /// changed, or whose passcode was removed, fails `evaluatePolicy` every
    /// time — and since the lock's own settings live behind the lock, the user
    /// would have no way back at all. Not a lockout counter: the OS owns
    /// rate-limiting, this only decides when to offer the reset. A dismissed
    /// prompt (`DeviceAuthOutcome.cancelled`) does not count.
    private(set) var failedUnlockAttempts = 0

    /// Whether to offer the destructive reset (see
    /// `AppEnvironment.resetAfterFailedUnlock`).
    var shouldOfferReset: Bool { failedUnlockAttempts >= 3 }

    /// Runs after a successful unlock — the lock-trigger task wires the
    /// deferred foreground sync here.
    var onUnlock: (() -> Void)?
    /// Runs when the lock engages.
    var onLock: (() -> Void)?

    /// Credential gate: the device secret, held in memory only while
    /// unlocked. Dropped the instant the lock engages; reloaded through the
    /// access-controlled Keychain item on unlock.
    private(set) var cachedGatedSecret: String?
    /// Reads the access-controlled item (may prompt for user presence).
    /// Installed by CredentialGateService while the gate is on.
    var loadGatedSecret: (() -> String?)?

    func cacheGatedSecret(_ secret: String?) {
        cachedGatedSecret = secret
    }

    /// The unsealed OpenPGP key holder, cleared whenever the lock engages.
    ///
    /// Injected so a test can prove it happens. Defaulted to the shared
    /// instance so no caller has to remember to pass it — the clearing lives
    /// inside `lock()` rather than behind the `onLock` callback for the same
    /// reason: Android's equivalent holder was missed by a path that forgot to
    /// call it, and the wipe then reported success with the account's private
    /// key still in the process heap.
    private let enrollmentSession: EnrollmentSession

    /// The device-bound secret the stored verifier is peppered with. Injected
    /// so the whole exit table below is testable without a Secure Enclave.
    private let pepper: any PinPepper

    /// The monotonic millisecond clock the lockout deadline is written on.
    /// `CLOCK_MONOTONIC_RAW` on Darwin keeps running while the machine sleeps
    /// and cannot be moved by changing the date, which a wall clock can — and a
    /// lockout a user can clear from the Date & Time pane is not a lockout.
    private let monotonicMillis: () -> Int64

    /// This boot's identity (`kern.bootsessionuuid`), stored beside a lockout
    /// deadline so a deadline from an earlier boot — whose monotonic clock
    /// meant something else — is recognised and restarted.
    private let bootSessionId: () -> String?

    /// Reads the lock flag. Injected so a test can make it unreadable.
    private let readLockState: () -> AppLockStore.FlagState

    /// Runs the security wipe once the threshold is reached. Injected rather
    /// than reached for, because this class is unit-tested without a graph.
    ///
    /// Left unset it fails **closed**: the attempt reports a wipe that could
    /// not run, rather than quietly rejecting the eleventh guess and every one
    /// after it as if the threshold did not exist.
    var onWipe: (() async -> WipeResult)?

    init(
        store: AppLockStore,
        authenticator: any DeviceAuthenticating = LocalAuthenticationAuthenticator(),
        enrollmentSession: EnrollmentSession = .shared,
        pepper: (any PinPepper)? = nil,
        monotonicMillis: @escaping () -> Int64 = AppLockManager.systemMonotonicMillis,
        bootSessionId: @escaping () -> String? = AppLockManager.systemBootSessionId,
        readLockState: (() -> AppLockStore.FlagState)? = nil
    ) {
        self.store = store
        self.authenticator = authenticator
        self.enrollmentSession = enrollmentSession
        let resolvedPepper = pepper ?? DevicePinPepper(keychain: KeychainStorage())
        self.pepper = resolvedPepper
        self.monotonicMillis = monotonicMillis
        self.bootSessionId = bootSessionId
        let readLockState = readLockState ?? { store.lockState }
        self.readLockState = readLockState
        // Decided from the three-state flag. Reading "unreadable" as off
        // started a Mac login item unlocked, and `lock()` then did nothing
        // for the whole session.
        let state = readLockState()
        isLockEnabled = state != .off
        isLocked = state != .off
        isLockStateUnresolved = state == .unreadable
        sessionFailedAttempts = store.failedAttempts
        lockGraceSeconds = store.lockGraceSeconds
        wipeThresholdSetting = WipeThresholdSeal.read(store.wipeThresholdRecord, pepper: resolvedPepper)
    }

    static func systemMonotonicMillis() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000)
    }

    /// `kern.bootsessionuuid`: new on every boot, which is exactly when the
    /// monotonic clock restarts. Nil if the kernel will not say.
    nonisolated static func systemBootSessionId() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let id = String(cString: buffer)
        return id.isEmpty ? nil : id
    }

    /// Re-reads the lock flag while it is unresolved — on every unlock
    /// attempt and while the lock screen is up, so a Keychain that was not
    /// ready at launch is asked again once it is.
    ///
    /// Only an unresolved flag can release the lock here. A flag that read
    /// "on" and later reads "off" mid-session is not a reason to open the
    /// app; turning the lock off goes through `setLockEnabled`.
    func refreshLockState() {
        guard isLockStateUnresolved else { return }
        switch readLockState() {
        case .unreadable:
            return
        case .on:
            isLockStateUnresolved = false
            isLockEnabled = true
        case .off:
            isLockStateUnresolved = false
            isLockEnabled = false
            guard isLocked else { return }
            clearPendingLock()
            isLocked = false
            onUnlock?()
        }
    }

    // MARK: - Grace period

    /// Observable mirror of `store.lockGraceSeconds` for the settings picker.
    private(set) var lockGraceSeconds: Int

    /// Monotonic deadline at which a deferred lock engages, nil when none is
    /// pending. A deadline rather than only a timer because iOS suspends the
    /// app: a timer does not fire in a suspended process, so every gate that
    /// asks "is this locked?" after a trip to the background resolves it.
    private var pendingLockDeadline: Int64?
    private var pendingLockTimer: Task<Void, Never>?

    /// True while a deferred lock is counting down.
    var isLockPending: Bool { pendingLockDeadline != nil }

    /// The lock trigger (backgrounding on iOS, screen lock on macOS), honouring
    /// the grace period.
    ///
    /// The unsealed OpenPGP key is still dropped immediately: the grace
    /// period is about the UI gate, not about how long a private key may sit
    /// in a process nobody is looking at. An earlier pending deadline is kept,
    /// never pushed back.
    func lockAfterGrace() {
        enrollmentSession.clear()
        guard isLockEnabled, !isLocked else { return }
        let grace = store.lockGraceSeconds
        guard grace > 0 else {
            lock()
            return
        }
        guard pendingLockDeadline == nil else { return }
        pendingLockDeadline = monotonicMillis() + Int64(grace) * 1000
        pendingLockTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled else { return }
            // Resolve, never lock unconditionally: a return to the app or a
            // successful unlock may have cancelled the deadline while this
            // callback was already queued (Android 590866f6).
            self?.resolvePendingLock()
        }
    }

    /// Engages the lock if a pending deadline has passed. Every gate that acts
    /// on `isLocked` after a background trip calls this first.
    @discardableResult
    func resolvePendingLock() -> Bool {
        if let deadline = pendingLockDeadline, monotonicMillis() >= deadline {
            clearPendingLock()
            lock()
        }
        return isLocked
    }

    /// The user came back (foreground on iOS, screen unlocked on macOS):
    /// lock if the window already closed, otherwise forget the deadline.
    func returnedWithinGrace() {
        resolvePendingLock()
        clearPendingLock()
    }

    /// An iOS scene is coming back on screen. Resolves the deadline first,
    /// then says whether its privacy cover may lift: only while unlocked. A
    /// locked app keeps the window-level cover, which then hosts the unlock
    /// screen — the in-tree lock presentation is not guaranteed to be on
    /// screen, or above every presentation, the moment the cover goes.
    func sceneReturningMayUncover() -> Bool {
        returnedWithinGrace()
        return !isLocked
    }

    /// The macOS screen-unlock notification, which is a hint rather than
    /// verified state. The deadline is cancelled only when the session state
    /// read independently confirms the screen is unlocked; otherwise it
    /// stands, and the lock engages when it passes.
    func screenUnlockReported(verifiedUnlocked: Bool) {
        if verifiedUnlocked {
            returnedWithinGrace()
        } else {
            resolvePendingLock()
        }
    }

    /// Whether the iOS shell must cover the window before the background
    /// snapshot is taken. True whenever the lock is on, pending or not: a
    /// grace period leaves the app unlocked behind the snapshot, and a sheet
    /// open at the time sits above any in-tree cover.
    var backgroundSnapshotNeedsCover: Bool { isLockEnabled }

    /// Stops the pending-lock timer. Called from `SingletonGraph.shutdown()`:
    /// a superseded graph's deadline must never fire later and clear session
    /// state the replacement graph now owns.
    func shutdown() {
        clearPendingLock()
    }

    private func clearPendingLock() {
        pendingLockDeadline = nil
        pendingLockTimer?.cancel()
        pendingLockTimer = nil
    }

    /// Sets the grace period. Lengthening it is the downgrade direction, so
    /// the settings screen authenticates before calling this; this method
    /// does not, for `setPin`'s reason.
    func setLockGraceSeconds(_ seconds: Int) throws {
        try store.setLockGraceSeconds(seconds)
        lockGraceSeconds = store.lockGraceSeconds
    }

    // MARK: - Lock

    /// Engages the lock now (also the end of a grace period). No-op while the
    /// feature is off.
    func lock() {
        // Before the early return, deliberately. The plaintext private key is
        // dropped whenever this is called, whether or not the app lock feature
        // is switched on and whether or not the lock was already engaged —
        // those are settings about the UI gate, not a reason to keep an
        // unsealed key in memory.
        enrollmentSession.clear()
        guard isLockEnabled, !isLocked else { return }
        clearPendingLock()
        isLocked = true
        autoPromptedThisLock = false
        cachedGatedSecret = nil
        onLock?()
    }

    /// The system prompt in flight, shared by every caller. Each macOS window
    /// carries its own lock screen, and each one asking separately stacked one
    /// Touch ID sheet per window.
    @ObservationIgnored private var inFlightUnlock: Task<Bool, Never>?

    /// Whether this lock has already raised its one automatic prompt. Reset
    /// when the lock engages.
    @ObservationIgnored private var autoPromptedThisLock = false

    /// The automatic prompt a lock screen raises when it appears: once per
    /// lock, from whichever window asks first (on macOS, the key window).
    /// After that, the Unlock button is how the user asks again.
    func autoPromptUnlock() async {
        refreshLockState()
        guard isLocked, !autoPromptedThisLock else { return }
        autoPromptedThisLock = true
        await requestUnlock()
    }

    @discardableResult
    func requestUnlock() async -> Bool {
        refreshLockState()
        guard isLocked else { return true }
        if let inFlightUnlock { return await inFlightUnlock.value }
        let task = Task { @MainActor in await self.performUnlock() }
        inFlightUnlock = task
        let unlocked = await task.value
        inFlightUnlock = nil
        return unlocked
    }

    private func performUnlock() async -> Bool {
        switch await authenticator.authenticateForUnlock(reason: String(localized: "Unlock KyPost")) {
        case .success:
            break
        case .cancelled:
            // Dismissing the prompt is not evidence the device cannot
            // authenticate, so it does not move the reset offer closer.
            return false
        case .failed:
            failedUnlockAttempts += 1
            return false
        }
        // A PIN may have unlocked while the prompt was up.
        guard isLocked else { return true }
        // Repopulate the gated secret before clearing the lock — this is the
        // one point the OS may prompt for presence a second time, and it is
        // the *only* place the in-memory copy can come back (the early return
        // above skips it once unlocked). Declining that prompt has to leave
        // the app locked: unlocking without the secret produces an app that
        // looks fine and silently no-ops every relay call, with no way to
        // retry short of locking and unlocking again.
        if let loadGatedSecret, cachedGatedSecret == nil {
            guard let secret = loadGatedSecret() else {
                failedUnlockAttempts += 1
                return false
            }
            cachedGatedSecret = secret
        }
        failedUnlockAttempts = 0
        isLockStateUnresolved = false
        // The device owner just authenticated, which outranks the PIN: the
        // wrong-PIN count and any lockout start over, as a correct PIN would
        // leave them. Serialised with the PIN checks, so one in flight cannot
        // write its stale count back over this.
        _ = await serialized {
            self.resetPinThrottle()
            return .success
        }
        // A stale deadline would re-lock the session the user just opened
        // (Android 7d791090).
        clearPendingLock()
        isLocked = false
        onUnlock?()
        return true
    }

    /// Re-authenticates for a single destructive action without touching lock
    /// state. Turning the lock off already required this; the actions sitting
    /// beside it in Preferences — Remove Pairing (which discards the pinned
    /// SPKI hash and forces an unpinned re-pair), Forget This Computer, Remove
    /// Exported Contacts, and turning Hostile Location Protection off — did
    /// not, which made the lock's protection inconsistent for anyone who
    /// reached Preferences while it was engaged.
    ///
    /// A no-op when the lock feature is off: the user has not asked for this
    /// class of protection, and prompting anyway would just be friction.
    func confirmWithDeviceAuth(reason: String) async -> Bool {
        guard isLockEnabled else { return true }
        return await authenticator.authenticate(reason: reason)
    }

    /// Enabling requires the device to have owner authentication configured;
    /// disabling requires re-authenticating first. Returns whether the change
    /// took, so the settings UI shows an inline explanation instead of a
    /// silent no-op. Enabling does not lock the running session — the user
    /// who just toggled is present; the next trigger locks.
    @discardableResult
    func setLockEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            guard authenticator.canAuthenticate() else { return false }
        } else {
            guard await authenticator.authenticate(
                reason: String(localized: "Turn off Require Unlock to Open")
            ) else { return false }
        }
        return applyLockEnabled(enabled)
    }

    /// Turns the lock off for a caller that has already authenticated.
    ///
    /// Security settings turns the credential gate off in the same step, and
    /// that downgrade has to happen *after* an authentication, not before —
    /// while still costing the user one prompt rather than two. Deliberately
    /// not a flag on `setLockEnabled`: a boolean that decides whether
    /// authentication happens is the last parameter anyone should be able to
    /// pass by accident.
    @discardableResult
    func disableLockAfterAuthentication() -> Bool {
        applyLockEnabled(false)
    }

    // MARK: - PIN

    /// Whether a PIN is configured — for the UI only. A decision that *acts*
    /// must read the outcome of an attempt, which distinguishes "no PIN" from
    /// "the PIN cannot be read right now".
    var hasPin: Bool { store.hasPin }

    /// Session-scoped mirror of the persisted counter, seeded at init.
    ///
    /// The manager always throttles on `max(persisted, session)`. Without it, a
    /// Keychain write that fails hands an attacker a fresh budget on every
    /// force-quit — the durability of the counter is the whole of the
    /// throttle, and it is the one part of this that can silently stop working.
    private var sessionFailedAttempts = 0

    /// Session-scoped mirror of the lockout deadline, on this process's
    /// monotonic clock. The manager gates on the later of this and the stored
    /// one, so a Keychain write that fails cannot turn a lockout into free
    /// guesses for the rest of the session.
    @ObservationIgnored private var sessionLockoutDeadline: Int64?

    /// Serialises every PIN check in the process.
    ///
    /// Both entry points run check-lockout → verify → account-for-failure, and
    /// suspend inside it (the wipe is async, and so is every caller). Without
    /// this, two checks in flight together — the settings screen and a notification-driven approval, or
    /// simply a double submit — both read the same attempt count and both write
    /// `n + 1`, so the ladder and the wipe threshold under-count. They also
    /// pass the lockout gate at the same instant, which is an unthrottled
    /// parallel guessing window.
    private var inFlightAttempt: Task<UnlockAttemptOutcome, Never>?

    /// How long the PIN field should stay disabled, or 0 if there is no active
    /// lockout. The later of the stored deadline and this session's copy.
    ///
    /// The stored deadline is on the monotonic timebase, which restarts at
    /// zero on reboot. Clamping to the stored duration alone froze the
    /// countdown at the full delay after a reboot until uptime caught up —
    /// days, for a 30-minute rung. So the deadline carries the boot it was
    /// written in, and one from another boot restarts as now + its duration:
    /// served in full once more, never shortened. A lockout that ran out
    /// while the app was not looking is served once more too — the fail-safe
    /// direction. Within one boot the clamp still holds.
    var remainingLockoutMillis: Int64 {
        let now = monotonicMillis()
        let session = sessionLockoutDeadline.map { max($0 - now, 0) } ?? 0
        return max(session, storedLockoutRemaining(now: now))
    }

    private func storedLockoutRemaining(now: Int64) -> Int64 {
        let duration = store.lockoutDurationMillis
        guard duration > 0 else { return 0 }
        // Without a boot id there is nothing to compare, and the clamp is the
        // whole defence, as it was before boot ids were recorded.
        if let boot = bootSessionId(), store.lockoutBootId != boot {
            // Rebased once per process and written back with this boot's id,
            // so later reads count down normally. If the write fails, the
            // session copy carries the restarted deadline instead.
            guard !lockoutRebasedThisProcess else { return 0 }
            lockoutRebasedThisProcess = true
            let until = now + duration
            sessionLockoutDeadline = max(sessionLockoutDeadline ?? 0, until)
            try? store.setLockout(untilMillis: until, durationMillis: duration, bootId: boot)
            return duration
        }
        return min(max(store.lockoutUntilMillis - now, 0), duration)
    }

    @ObservationIgnored private var lockoutRebasedThisProcess = false

    /// Clears the wrong-PIN count and any lockout, stored and in session.
    private func resetPinThrottle() {
        try? store.resetFailedAttempts()
        sessionFailedAttempts = 0
        sessionLockoutDeadline = nil
    }

    /// Sets or replaces the PIN. Returns the policy verdict; nothing is stored
    /// unless it is `.valid`.
    ///
    /// The caller must have established the right to do this — the settings
    /// screen re-authenticates first. This method does not, deliberately: a
    /// method that sometimes prompts and sometimes does not is one nobody can
    /// audit at the call site.
    @discardableResult
    func setPin(_ pin: String) throws -> PinPolicyResult {
        let verdict = PinPolicy.validate(pin)
        guard verdict == .valid else { return verdict }
        try store.setPin(try PinHasher.hash(pin: pin, pepper: pepper))
        resetPinThrottle()
        // A first PIN may have minted a new pepper, which no longer vouches
        // for an older stored threshold — that now reads as the strictest.
        wipeThresholdSetting = wipeThreshold
        return .valid
    }

    // MARK: - Wipe threshold

    /// Observable mirror for the settings picker. The attempt path never reads
    /// this — it re-reads and re-verifies the stored value every time.
    private(set) var wipeThresholdSetting: WipeThreshold

    /// The threshold in force, read from the store and verified against the
    /// pepper on every call. Anything that does not verify is the strictest.
    var wipeThreshold: WipeThreshold {
        WipeThresholdSeal.read(store.wipeThresholdRecord, pepper: pepper)
    }

    /// Stores a new threshold, sealed to the pepper. Needs a PIN (the pepper
    /// exists only once one was set) — without one there is nothing to wipe
    /// on. Loosening it is the downgrade direction: the settings screen
    /// authenticates first; this method does not, for `setPin`'s reason.
    func setWipeThreshold(_ threshold: WipeThreshold) throws {
        // Refreshed on failure too: a half-written record is enforced as the
        // strictest value, and the picker must say so rather than keep
        // showing the value it had before.
        defer { wipeThresholdSetting = wipeThreshold }
        let tag = try WipeThresholdSeal.tag(for: threshold, pepper: pepper)
        try store.setWipeThreshold(wire: threshold.wire, tag: tag)
    }

    /// Removes the PIN and disarms the tripwire with it.
    func clearPin() throws {
        try store.clearPin()
        resetPinThrottle()
    }

    /// Unlocks the app with a PIN, under the ladder and the wipe threshold.
    func attemptPinUnlock(_ pin: String) async -> UnlockAttemptOutcome {
        await serialized {
            let outcome = await self.verify(pin)
            guard outcome == .success else { return outcome }
            // Repopulate the gated secret **before** clearing the lock, and
            // leave the app locked if it cannot be read — the same rule
            // `requestUnlock` follows, and for the same reason.
            if let load = self.loadGatedSecret, self.cachedGatedSecret == nil {
                guard let secret = load() else { return .gatedSecretUnavailable }
                self.cachedGatedSecret = secret
            }
            self.failedUnlockAttempts = 0
            self.isLockStateUnresolved = false
            self.clearPendingLock()
            self.isLocked = false
            self.onUnlock?()
            return .success
        }
    }

    /// Verifies a PIN **without** unlocking — for a screen confirming one
    /// destructive action.
    ///
    /// Every PIN check has to come through here or `attemptPinUnlock`. Android's
    /// settings screens called the store's verifier directly, which meant
    /// unlimited untimed guesses that never advanced the wipe counter —
    /// precisely the unthrottled second entry point the ladder exists to close.
    func verifyPinThrottled(_ pin: String) async -> UnlockAttemptOutcome {
        await serialized { await self.verify(pin) }
    }

    private func serialized(
        _ body: @escaping () async -> UnlockAttemptOutcome
    ) async -> UnlockAttemptOutcome {
        let previous = inFlightAttempt
        let task = Task { @MainActor in
            _ = await previous?.value
            return await body()
        }
        inFlightAttempt = task
        return await task.value
    }

    /// The whole check-verify-account sequence — the lockout gate, the
    /// verification, and the accounting for a failure — run under `serialized`
    /// by every entry point.
    ///
    /// It deliberately does **not** unlock. What happens after a correct PIN is
    /// the only thing that distinguishes the callers, and keeping it out here is
    /// what stops the two of them growing separate copies of this accounting.
    private func verify(_ pin: String) async -> UnlockAttemptOutcome {
        let remaining = remainingLockoutMillis
        guard remaining <= 0 else { return .rejected(delayMillis: remaining) }

        let stored: PinHash
        switch store.storedPin {
        case .configured(let hash): stored = hash
        case .absent: return .notConfigured
        case .unreadable: return .verifierUnavailable
        }

        // Run inline, on the main actor. 150k PBKDF2 iterations is roughly 20ms
        // — a hitch on a modal unlock, not a freeze — and the obvious
        // alternative, hopping to a detached task, buys that back at the cost of
        // letting a second attempt interleave at the suspension point. The
        // serialisation above is what makes the counter correct, and keeping the
        // check synchronous is what keeps it simple enough to trust.
        let verified: Bool
        do {
            verified = try PinHasher.matches(pin: pin, stored: stored, pepper: pepper)
        } catch {
            // Not a wrong PIN, and it must not be counted as one — the
            // increment below is what feeds the wipe threshold.
            Log.app.error("PIN verifier is unevaluable; refusing to count an attempt: \(error)")
            return .verifierUnavailable
        }

        if verified {
            resetPinThrottle()
            return .success
        }

        let attempts = max(store.failedAttempts, sessionFailedAttempts) + 1
        sessionFailedAttempts = attempts
        do {
            try store.setFailedAttempts(attempts)
        } catch {
            // Session-scoped throttling still holds; what is lost is durability
            // across a force-quit. Loud, because that is the difference between
            // ten guesses and unlimited ones.
            Log.app.error("Could not persist the failed-attempt count: \(error.localizedDescription)")
        }

        if LockoutPolicy.shouldWipe(attemptCount: attempts, threshold: wipeThreshold) {
            guard let onWipe else {
                Log.app.error("Wipe threshold reached with no wipe wired up")
                return .wipeFailed(failedSteps: ["wipeNotConfigured"], willRetry: false)
            }
            switch await onWipe() {
            case .complete:
                return .wiped
            case .incomplete(let failedSteps, let willRetry):
                return .wipeFailed(failedSteps: failedSteps, willRetry: willRetry)
            }
        }

        let delay = LockoutPolicy.delayMillis(forAttemptCount: attempts)
        if delay > 0 {
            let until = monotonicMillis() + delay
            // Held for the session whether or not the write lands: a failed
            // write must not turn the delay into free guesses.
            sessionLockoutDeadline = until
            do {
                try store.setLockout(untilMillis: until, durationMillis: delay, bootId: bootSessionId())
            } catch {
                Log.app.error("Could not persist the lockout deadline: \(error.localizedDescription)")
            }
        }
        return .rejected(delayMillis: delay)
    }

    private func applyLockEnabled(_ enabled: Bool) -> Bool {
        do {
            try store.setLockEnabled(enabled)
        } catch {
            Log.app.error("Could not persist app-lock setting: \(error.localizedDescription)")
            return false
        }
        isLockEnabled = enabled
        isLockStateUnresolved = false
        if !enabled {
            clearPendingLock()
            isLocked = false
            failedUnlockAttempts = 0
            // The PIN belongs to the lock. Left behind, it would be a verifier
            // for a gate that no longer exists — and the tripwire it arms would
            // still be watching for its disappearance.
            try? clearPin()
        }
        return true
    }
}
