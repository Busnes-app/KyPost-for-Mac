//
//  AppLockStore.swift
//  KyPost
//
//  Keychain-backed app-lock settings and PIN state. Keys are a binding
//  contract: appLock.enabled, appLock.credentialGateEnabled, appLock.pinSalt,
//  appLock.pinHash, appLock.pinVersion, appLock.failedAttempts,
//  appLock.lockoutUntil, appLock.lockoutDuration, appLock.lockoutBoot,
//  appLock.wipeThreshold, appLock.wipeThresholdTag, appLock.graceSeconds.
//
//  **The PIN fields reverse this file's original decision.** It used to say
//  "deliberately no PIN or lockout fields — verification is LAContext's job,
//  lockout is the OS's". That held while `LAContext` was the only verifier:
//  the OS throttles guesses at the device passcode, so there was nothing for
//  this app to count. An app-lock PIN of our own has no such backstop — a PIN
//  checked in-process is an unthrottled oracle unless something here counts
//  the attempts — so the ladder and the wipe threshold live in
//  `LockoutPolicy`, and their state lives here. `LAContext` remains the
//  verifier wherever a PIN is not configured.
//

import Foundation

final class AppLockStore: Sendable {
    private enum Key {
        static let lockEnabled = "appLock.enabled"
        static let credentialGateEnabled = "appLock.credentialGateEnabled"
        static let pinSalt = "appLock.pinSalt"
        static let pinHash = "appLock.pinHash"
        static let pinVersion = "appLock.pinVersion"
        static let failedAttempts = "appLock.failedAttempts"
        static let lockoutUntil = "appLock.lockoutUntil"
        static let lockoutDuration = "appLock.lockoutDuration"
        static let lockoutBoot = "appLock.lockoutBoot"
        static let wipeThreshold = "appLock.wipeThreshold"
        static let wipeThresholdTag = "appLock.wipeThresholdTag"
        static let graceSeconds = "appLock.graceSeconds"
    }

    /// The unencrypted companion marker — see `tripwireBroken`. In
    /// `UserDefaults` on purpose: it has to survive the disappearance of the
    /// Keychain items it vouches for.
    private static let tripwireKey = "appLock.wasConfigured"

    /// A stored flag, or the fact that it could not be read.
    ///
    /// The distinction matters wherever a `false` triggers a *repair* rather
    /// than just a quieter UI: `errSecInteractionNotAllowed` at launch is a
    /// routine, transient status on a Mac whose Keychain is not ready yet, and
    /// collapsing it into "the user turned this off" let one flaky read move
    /// the device secret out from behind user presence for good.
    nonisolated enum FlagState: Equatable {
        case on
        case off
        case unreadable
    }

    /// The same discipline for the PIN itself, and here it is load-bearing in
    /// a much louder way: `absent` while `tripwireBroken` is armed destroys the
    /// user's local data, so a Keychain that merely will not answer must never
    /// be able to produce it.
    nonisolated enum StoredPin: Equatable {
        case configured(PinHash)
        case absent
        case unreadable
    }

    /// The wipe threshold as stored, before `WipeThresholdSeal` decides
    /// whether to believe it.
    nonisolated enum StoredWipeThreshold: Equatable {
        case absent
        case stored(wire: String, tag: Data)
        case unreadable
    }

    private let keychain: KeychainStorage
    private let defaults: UserDefaults
    /// Runs before each half of a wipe-threshold write, keyed by the item
    /// about to be written. A no-op outside tests, which use it to fail the
    /// second half and prove what a half-written record reads as.
    private let beforeThresholdWrite: @Sendable (String) throws -> Void
    /// Runs before a lockout deadline is written. A no-op outside tests, which
    /// use it to prove a failed write still leaves the delay in force.
    private let beforeLockoutWrite: @Sendable () throws -> Void

    init(
        keychain: KeychainStorage,
        defaults: UserDefaults = .standard,
        beforeThresholdWrite: @escaping @Sendable (String) throws -> Void = { _ in },
        beforeLockoutWrite: @escaping @Sendable () throws -> Void = {}
    ) {
        self.keychain = keychain
        self.defaults = defaults
        self.beforeThresholdWrite = beforeThresholdWrite
        self.beforeLockoutWrite = beforeLockoutWrite
    }

    /// Feature 1: Require Unlock to Open.
    ///
    /// **Whether the app starts locked is decided from this, never from
    /// `lockEnabled`**, and `.unreadable` counts as on. A Mac login item reads
    /// it before the Keychain is ready (`errSecInteractionNotAllowed`), and
    /// reading that as "off" started the app unlocked and made `lock()` a
    /// no-op for the whole session. `AppLockManager` re-reads it until it
    /// answers.
    var lockState: FlagState {
        do {
            return try keychain.string(forKey: Key.lockEnabled) == "true" ? .on : .off
        } catch {
            return .unreadable
        }
    }

    /// True only when the flag reads as on. A display convenience: anything
    /// that decides whether to lock, or acts destructively, uses `lockState`.
    var lockEnabled: Bool { lockState == .on }

    /// **Does not arm the tripwire.** The marker vouches for a stored PIN, and
    /// on this platform the PIN is optional — the lock can be on with `LAContext`
    /// as the only verifier. Arming it here would make "a lock was configured
    /// but there is no PIN" true the instant the toggle went on, and the next
    /// launch would erase the user's mail for switching a setting.
    func setLockEnabled(_ enabled: Bool) throws {
        try keychain.set(enabled ? "true" : "false", forKey: Key.lockEnabled)
    }

    /// Removes the flag outright — the last thing a complete security wipe
    /// does (`SecurityWipeSteps.releaseLock`), so an incomplete one leaves the
    /// app locked over whatever it could not delete.
    func clearLockEnabled() throws {
        try keychain.remove(Key.lockEnabled)
    }

    /// Feature 3: Require unlock to receive push/MFA. Stored here so the
    /// store's shape is final from day one; wired up by the credential-gate
    /// task.
    var credentialGateEnabled: Bool {
        (try? keychain.string(forKey: Key.credentialGateEnabled)) == "true"
    }

    func setCredentialGateEnabled(_ enabled: Bool) throws {
        try keychain.set(enabled ? "true" : "false", forKey: Key.credentialGateEnabled)
    }

    // MARK: - PIN

    var storedPin: StoredPin {
        do {
            guard let salt = try keychain.string(forKey: Key.pinSalt),
                  let hash = try keychain.string(forKey: Key.pinHash),
                  let saltData = Data(base64Encoded: salt),
                  let hashData = Data(base64Encoded: hash)
            else { return .absent }
            // A missing version is not a legacy verifier — this app has never
            // shipped one — so it is a partially written record, which must not
            // read as "no PIN configured".
            guard let version = try keychain.string(forKey: Key.pinVersion).flatMap(Int.init) else {
                return .unreadable
            }
            return .configured(PinHash(salt: saltData, hash: hashData, version: version))
        } catch {
            return .unreadable
        }
    }

    var hasPin: Bool {
        if case .configured = storedPin { return true }
        return false
    }

    /// Writes the verifier and arms the tripwire.
    ///
    /// Order is the point, and it is the opposite of `clearPin`'s: the marker
    /// goes down **after** the hash exists, so an interruption leaves a PIN
    /// with no marker (harmless — the tripwire simply does not fire) rather
    /// than a marker with no PIN, which is the state that wipes the device.
    func setPin(_ hash: PinHash) throws {
        try keychain.set(hash.salt.base64EncodedString(), forKey: Key.pinSalt)
        try keychain.set(hash.hash.base64EncodedString(), forKey: Key.pinHash)
        try keychain.set(String(hash.version), forKey: Key.pinVersion)
        defaults.set(true, forKey: Self.tripwireKey)
    }

    /// Removes the verifier. The tripwire goes **first**: `tripwireBroken` is
    /// "a lock was configured but the PIN is gone", so clearing the hash first
    /// opens a window in which that is momentarily true, and a crash inside it
    /// destroys the user's data in response to them switching a setting off.
    func clearPin() throws {
        defaults.set(false, forKey: Self.tripwireKey)
        try keychain.remove(Key.pinSalt)
        try keychain.remove(Key.pinHash)
        try keychain.remove(Key.pinVersion)
    }

    /// Whether a lock was ever configured on this machine.
    var wasConfigured: Bool { defaults.bool(forKey: Self.tripwireKey) }

    /// The Keychain lost the PIN while the plain marker still says one was
    /// stored — OS-level invalidation, a restore to a new machine, or
    /// someone deleting the item to disable the lock. `SecurityWipe` turns
    /// this into a wipe at startup, so the inbox is not opened over a cache
    /// the lock was supposed to be guarding.
    ///
    /// **`unreadable` deliberately does not arm it.** A Keychain that will not
    /// answer yet is the ordinary state of a Mac a few hundred milliseconds
    /// into launch, and treating that as tampering would erase the user's mail
    /// for a transient status.
    var tripwireBroken: Bool { wasConfigured && storedPin == .absent }

    // MARK: - Wipe threshold and grace period

    /// In the Keychain beside the verifier, not in `UserDefaults`, where any
    /// process running as the user can rewrite a plist. A value without a tag,
    /// or a tag without a value, is `.unreadable` — a half-written or
    /// half-deleted record is not "nothing configured".
    var wipeThresholdRecord: StoredWipeThreshold {
        do {
            let wire = try keychain.string(forKey: Key.wipeThreshold)
            let tag = try keychain.string(forKey: Key.wipeThresholdTag)
            switch (wire, tag) {
            case (nil, nil):
                return .absent
            case (let wire?, let tag?):
                guard let tagData = Data(base64Encoded: tag) else { return .unreadable }
                return .stored(wire: wire, tag: tagData)
            default:
                return .unreadable
            }
        } catch {
            return .unreadable
        }
    }

    func setWipeThreshold(wire: String, tag: Data) throws {
        try beforeThresholdWrite(Key.wipeThreshold)
        try keychain.set(wire, forKey: Key.wipeThreshold)
        try beforeThresholdWrite(Key.wipeThresholdTag)
        try keychain.set(tag.base64EncodedString(), forKey: Key.wipeThresholdTag)
    }

    /// Seconds the lock waits after its trigger. Fails closed: unreadable,
    /// absent or not one of `LockGracePeriod.options` is Immediately.
    var lockGraceSeconds: Int {
        LockGracePeriod.sanitized((try? keychain.string(forKey: Key.graceSeconds)).flatMap { Int($0) })
    }

    func setLockGraceSeconds(_ seconds: Int) throws {
        try keychain.set(String(LockGracePeriod.sanitized(seconds)), forKey: Key.graceSeconds)
    }

    // MARK: - Lockout accounting

    /// Consecutive wrong attempts. A read failure answers 0 — the manager
    /// keeps its own session-scoped count and takes whichever is higher, so a
    /// Keychain that will not answer cannot hand an attacker a fresh budget
    /// inside one run of the app.
    var failedAttempts: Int {
        Int((try? keychain.string(forKey: Key.failedAttempts)) ?? "") ?? 0
    }

    func setFailedAttempts(_ count: Int) throws {
        try keychain.set(String(count), forKey: Key.failedAttempts)
    }

    /// Lockout deadline on the **monotonic** timebase (`CLOCK_MONOTONIC_RAW`),
    /// not the wall clock: a wall-clock deadline is cleared by setting the date
    /// forward, which is not a defence at all. The monotonic clock restarts at
    /// zero on reboot, so `lockoutBootId` records which boot the deadline was
    /// written in, and `lockoutDurationMillis` is what a later boot restarts
    /// the countdown from (`AppLockManager.remainingLockoutMillis`).
    var lockoutUntilMillis: Int64 {
        Int64((try? keychain.string(forKey: Key.lockoutUntil)) ?? "") ?? 0
    }

    var lockoutDurationMillis: Int64 {
        Int64((try? keychain.string(forKey: Key.lockoutDuration)) ?? "") ?? 0
    }

    /// The boot session the deadline was written in (`kern.bootsessionuuid`),
    /// nil when none was recorded or it cannot be read — which the manager
    /// treats as another boot, restarting the delay rather than shortening it.
    var lockoutBootId: String? {
        try? keychain.string(forKey: Key.lockoutBoot)
    }

    /// Duration first and deadline last, so an interrupted write never leaves
    /// a new deadline without the duration a later boot restarts from.
    func setLockout(untilMillis: Int64, durationMillis: Int64, bootId: String?) throws {
        try beforeLockoutWrite()
        try keychain.set(String(durationMillis), forKey: Key.lockoutDuration)
        if let bootId {
            try keychain.set(bootId, forKey: Key.lockoutBoot)
        } else {
            try keychain.remove(Key.lockoutBoot)
        }
        try keychain.set(String(untilMillis), forKey: Key.lockoutUntil)
    }

    func resetFailedAttempts() throws {
        try setFailedAttempts(0)
        try setLockout(untilMillis: 0, durationMillis: 0, bootId: nil)
    }

    /// Clears the PIN, both feature flags, the attempt counters, the wipe
    /// threshold and the grace period — the app-lock half of `SecurityWipe`.
    ///
    /// `keepingLockEnabled` leaves Require Unlock to Open in place: the wipe
    /// removes it last, and only once every other step succeeded, so a wipe
    /// that could not finish never brings the app back unlocked over the data
    /// it left.
    ///
    /// Tripwire first, for `clearPin`'s reason. Every removal is attempted
    /// even after one fails, and the first error is rethrown: a caller told
    /// "the lock could not be cleared" while three of five items are already
    /// gone is better served by the remaining two also being gone.
    func reset(keepingLockEnabled: Bool = false) throws {
        defaults.set(false, forKey: Self.tripwireKey)
        var firstError: Error?
        var keys = [
            Key.pinSalt, Key.pinHash, Key.pinVersion,
            Key.failedAttempts, Key.lockoutUntil, Key.lockoutDuration, Key.lockoutBoot,
            Key.credentialGateEnabled,
            Key.wipeThreshold, Key.wipeThresholdTag, Key.graceSeconds,
        ]
        if !keepingLockEnabled { keys.append(Key.lockEnabled) }
        for key in keys {
            do { try keychain.remove(key) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }
}
