//
//  AppLockPinAttemptTests.swift
//  KyPost Tests
//
//  Phase 11: what happens to one PIN attempt — the ladder, the threshold, and
//  the two outcomes that are not about the PIN at all.
//

import Foundation
import Testing
@testable import KyPost

@MainActor
private final class PinAttemptHarness {
    let store: AppLockStore
    let pepper: FakePinPepper
    private(set) var manager: AppLockManager
    /// The lockout deadline is written on a monotonic clock, so the tests own
    /// one rather than sleeping through a thirty-minute rung.
    let clock = Box<Int64>(0)
    /// The boot session the manager sees. Changing it is a reboot.
    let boot = Box<String?>("boot-1")
    /// Makes every lockout write fail, as a Keychain that will not take one.
    let failLockoutWrites = Box(false)
    let wipeCalls = Box(0)
    var wipeResult: WipeResult = .complete

    init(
        pin: String? = "83910472",
        wireWipe: Bool = true,
        authenticator: any DeviceAuthenticating = StubAlwaysAuthenticator()
    ) throws {
        let failLockoutWrites = self.failLockoutWrites
        store = AppLockStore(
            keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)"),
            defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!,
            beforeLockoutWrite: {
                if failLockoutWrites.value { throw KeychainStorage.KeychainError(status: errSecInteractionNotAllowed) }
            }
        )
        // Before the manager is built: it reads the flag at init to decide
        // whether this process starts locked.
        try store.setLockEnabled(true)
        pepper = FakePinPepper()
        let clock = self.clock
        let boot = self.boot
        manager = AppLockManager(
            store: store,
            authenticator: authenticator,
            pepper: pepper,
            monotonicMillis: { clock.value },
            bootSessionId: { boot.value }
        )
        if let pin { try manager.setPin(pin) }
        if wireWipe {
            manager.onWipe = { [self] in
                wipeCalls.mutate { $0 += 1 }
                return wipeResult
            }
        }
    }

    func advance(millis: Int64) {
        clock.mutate { $0 += millis }
    }

    /// A reboot: a new boot session, the monotonic clock restarted at
    /// `clockAfter`, and a fresh process — a manager with no session state —
    /// over the same stored record.
    func reboot(bootId: String?, clockAfter: Int64) {
        boot.value = bootId
        clock.value = clockAfter
        let clock = self.clock
        let boot = self.boot
        manager = AppLockManager(
            store: store,
            authenticator: StubAlwaysAuthenticator(),
            pepper: pepper,
            monotonicMillis: { clock.value },
            bootSessionId: { boot.value }
        )
    }

    /// Burns `count` wrong attempts, stepping the clock past each lockout so
    /// the next one is actually evaluated rather than rejected by the ladder.
    @discardableResult
    func burnWrongAttempts(_ count: Int) async -> UnlockAttemptOutcome {
        var last: UnlockAttemptOutcome = .notConfigured
        for _ in 0..<count {
            advance(millis: manager.remainingLockoutMillis)
            last = await manager.attemptPinUnlock("00000001")
        }
        return last
    }
}

/// The shipped default, ten. Spelled out so a change to the default shows up
/// here as a deliberate edit.
private let defaultWipeAttempts = 10

private struct StubAlwaysAuthenticator: DeviceAuthenticating {
    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> Bool { true }
}

@MainActor
@Suite struct AppLockPinAttemptTests {
    @Test func aCorrectPinUnlocks() async throws {
        let harness = try PinAttemptHarness()
        #expect(harness.manager.isLocked)
        #expect(await harness.manager.attemptPinUnlock("83910472") == .success)
        #expect(!harness.manager.isLocked)
    }

    @Test func aWrongPinIsFreeTwiceThenCostsTime() async throws {
        let harness = try PinAttemptHarness()
        #expect(await harness.manager.attemptPinUnlock("00000001") == .rejected(delayMillis: 0))
        #expect(await harness.manager.attemptPinUnlock("00000001") == .rejected(delayMillis: 0))
        #expect(await harness.manager.attemptPinUnlock("00000001") == .rejected(delayMillis: 30_000))
    }

    /// The ladder is enforced *here*, not by a disabled submit button. Leaving
    /// it to the view means the policy exists only while that screen is the
    /// only caller, and any second entry point is an unthrottled oracle.
    @Test func anAttemptInsideTheLockoutIsRefusedWithoutBeingChecked() async throws {
        let harness = try PinAttemptHarness()
        await harness.burnWrongAttempts(3)
        #expect(harness.manager.remainingLockoutMillis == 30_000)

        // Even the correct PIN waits. Otherwise the lockout throttles nothing.
        #expect(await harness.manager.attemptPinUnlock("83910472") == .rejected(delayMillis: 30_000))

        harness.advance(millis: 30_000)
        #expect(await harness.manager.attemptPinUnlock("83910472") == .success)
    }

    @Test func aSuccessResetsTheLadder() async throws {
        let harness = try PinAttemptHarness()
        _ = await harness.manager.attemptPinUnlock("00000001")
        _ = await harness.manager.attemptPinUnlock("00000001")
        #expect(await harness.manager.attemptPinUnlock("83910472") == .success)
        #expect(harness.store.failedAttempts == 0)
        // Back to a free attempt, not straight to the next rung.
        #expect(await harness.manager.attemptPinUnlock("00000001") == .rejected(delayMillis: 0))
    }

    @Test func theTenthWrongAttemptWipes() async throws {
        let harness = try PinAttemptHarness()
        let last = await harness.burnWrongAttempts(defaultWipeAttempts)
        #expect(last == .wiped)
        #expect(harness.wipeCalls.value == 1)
    }

    /// The wipe ran and could not finish. The UI must not be told the data is
    /// gone when it might not be.
    @Test func anIncompleteWipeIsItsOwnOutcome() async throws {
        let harness = try PinAttemptHarness()
        harness.wipeResult = .incomplete(failedSteps: ["database"], willRetry: true)
        let last = await harness.burnWrongAttempts(defaultWipeAttempts)
        #expect(last == .wipeFailed(failedSteps: ["database"], willRetry: true))
    }

    /// Fails closed. A threshold nothing is wired to act on would otherwise
    /// reject the eleventh guess exactly like the third and quietly disable the
    /// only limit on guessing.
    @Test func aThresholdWithNoWipeWiredUpReportsItself() async throws {
        let harness = try PinAttemptHarness(wireWipe: false)
        let last = await harness.burnWrongAttempts(defaultWipeAttempts)
        #expect(last == .wipeFailed(failedSteps: ["wipeNotConfigured"], willRetry: false))
    }

    /// A correct PIN that cannot bring the gated credential back leaves the app
    /// **locked**, matching `requestUnlock`. Unlocking anyway produces an app
    /// that looks fine and silently no-ops every relay call.
    @Test func aCorrectPinWithNoGatedSecretDoesNotUnlock() async throws {
        let harness = try PinAttemptHarness()
        harness.manager.loadGatedSecret = { nil }

        #expect(await harness.manager.attemptPinUnlock("83910472") == .gatedSecretUnavailable)
        #expect(harness.manager.isLocked)

        // And it is not counted as a wrong PIN.
        #expect(harness.store.failedAttempts == 0)

        harness.manager.loadGatedSecret = { "device-secret" }
        #expect(await harness.manager.attemptPinUnlock("83910472") == .success)
        #expect(!harness.manager.isLocked)
        #expect(harness.manager.cachedGatedSecret == "device-secret")
    }

    // MARK: - The outcomes that are not about the PIN

    /// **The one that destroyed user data on Android.** A verifier that cannot
    /// be evaluated is not a wrong PIN, and must not advance the counter.
    @Test func anUnevaluableVerifierNeverCountsTowardTheWipe() async throws {
        let harness = try PinAttemptHarness()
        harness.pepper.available = false

        for _ in 0..<(defaultWipeAttempts * 2) {
            #expect(await harness.manager.attemptPinUnlock("83910472") == .verifierUnavailable)
        }
        #expect(harness.wipeCalls.value == 0)
        #expect(harness.store.failedAttempts == 0)

        // And the correct PIN still works the moment the key comes back.
        harness.pepper.available = true
        #expect(await harness.manager.attemptPinUnlock("83910472") == .success)
    }

    @Test func noPinConfiguredIsNotAWrongPin() async throws {
        let harness = try PinAttemptHarness(pin: nil)
        #expect(await harness.manager.attemptPinUnlock("83910472") == .notConfigured)
        #expect(harness.store.failedAttempts == 0)
    }

    // MARK: - Policy at the setting boundary

    @Test func aWeakPinIsRefusedAndNothingIsStored() throws {
        let harness = try PinAttemptHarness(pin: nil)
        #expect(try harness.manager.setPin("1234") == .tooShort)
        #expect(try harness.manager.setPin("12345678") == .tooCommon)
        #expect(!harness.manager.hasPin)
    }

    @Test func settingAPinClearsAnAccumulatedLadder() async throws {
        let harness = try PinAttemptHarness()
        await harness.burnWrongAttempts(3)
        #expect(harness.store.failedAttempts == 3)

        #expect(try harness.manager.setPin("47382910") == .valid)
        #expect(harness.store.failedAttempts == 0)
        #expect(harness.manager.remainingLockoutMillis == 0)
        #expect(await harness.manager.attemptPinUnlock("47382910") == .success)
    }

    @Test func clearingThePinLeavesNothingToVerifyAgainst() async throws {
        let harness = try PinAttemptHarness()
        try harness.manager.clearPin()
        #expect(!harness.manager.hasPin)
        #expect(await harness.manager.attemptPinUnlock("83910472") == .notConfigured)
    }

    /// The PIN belongs to the lock. Left behind when the lock goes off, it is a
    /// verifier for a gate that no longer exists — and it leaves the tripwire
    /// armed and watching for its own disappearance.
    @Test func turningTheLockOffRemovesThePin() async throws {
        let harness = try PinAttemptHarness()
        #expect(harness.manager.hasPin)
        #expect(harness.store.wasConfigured)

        #expect(await harness.manager.setLockEnabled(false))
        #expect(!harness.manager.hasPin)
        #expect(!harness.store.wasConfigured)
        #expect(!harness.store.tripwireBroken)
    }

    // MARK: - Throttle integrity

    /// Two checks in flight together must not both read the same count and
    /// both write `n + 1` — that under-counts the ladder and opens a parallel
    /// guessing window through the lockout gate.
    @Test func concurrentAttemptsEachCount() async throws {
        let harness = try PinAttemptHarness()
        async let first = harness.manager.attemptPinUnlock("00000001")
        async let second = harness.manager.attemptPinUnlock("00000001")
        _ = await (first, second)
        #expect(harness.store.failedAttempts == 2)
    }

    /// A second entry point must be throttled by the same counter, or the
    /// settings screen becomes the unthrottled oracle the ladder exists to
    /// close.
    @Test func verifyingWithoutUnlockingSharesTheLadder() async throws {
        let harness = try PinAttemptHarness()
        #expect(await harness.manager.verifyPinThrottled("00000001") == .rejected(delayMillis: 0))
        #expect(await harness.manager.verifyPinThrottled("00000001") == .rejected(delayMillis: 0))
        #expect(await harness.manager.attemptPinUnlock("00000001") == .rejected(delayMillis: 30_000))

        // And a success there does not unlock the app.
        harness.advance(millis: 30_000)
        #expect(await harness.manager.verifyPinThrottled("83910472") == .success)
        #expect(harness.manager.isLocked)
    }

    /// Within one boot a stored deadline can never read as more than the delay
    /// actually imposed.
    @Test func theRemainingDelayIsClampedToTheDuration() async throws {
        let harness = try PinAttemptHarness()
        await harness.burnWrongAttempts(3)
        #expect(harness.manager.remainingLockoutMillis == 30_000)

        try harness.store.setLockout(untilMillis: 9_000_000, durationMillis: 30_000, bootId: "boot-1")
        #expect(harness.manager.remainingLockoutMillis == 30_000)
    }

    /// The monotonic clock restarts at zero on reboot. Clamping alone froze
    /// the countdown at the full delay until uptime caught up with the old
    /// deadline — days. A deadline from another boot restarts as now + its
    /// duration, and then counts down.
    @Test func aRebootRestartsTheCountdownInsteadOfFreezingIt() async throws {
        let harness = try PinAttemptHarness()
        harness.clock.value = 5_000_000
        await harness.burnWrongAttempts(3)
        harness.advance(millis: 10_000)
        #expect(harness.manager.remainingLockoutMillis == 20_000)

        // Reboot: new boot session, clock back near zero.
        harness.reboot(bootId: "boot-2", clockAfter: 1_000)
        #expect(harness.manager.remainingLockoutMillis == 30_000)
        #expect(harness.store.lockoutBootId == "boot-2")

        harness.advance(millis: 12_000)
        #expect(harness.manager.remainingLockoutMillis == 18_000)
        harness.advance(millis: 18_000)
        #expect(harness.manager.remainingLockoutMillis == 0)
        #expect(await harness.manager.attemptPinUnlock("83910472") == .success)
    }

    /// However far the new boot's clock reads past the old deadline, the
    /// delay is served in full, never skipped.
    @Test func aRebootNeverShortensTheDelay() async throws {
        let harness = try PinAttemptHarness()
        await harness.burnWrongAttempts(3)
        harness.reboot(bootId: "boot-2", clockAfter: 9_999_999_999)
        #expect(harness.manager.remainingLockoutMillis == 30_000)
        #expect(await harness.manager.attemptPinUnlock("83910472") == .rejected(delayMillis: 30_000))
    }

    /// With no boot identity (the kernel would not say) there is nothing to
    /// compare, so the clamp alone applies — and the delay still runs out.
    @Test func withoutABootIdTheClampStillHoldsAndRunsOut() async throws {
        let harness = try PinAttemptHarness()
        await harness.burnWrongAttempts(3)
        harness.reboot(bootId: nil, clockAfter: 500)
        #expect(harness.manager.remainingLockoutMillis == 29_500)
        harness.advance(millis: 29_500)
        #expect(harness.manager.remainingLockoutMillis == 0)
    }

    /// A rebased deadline that cannot be written back is restarted once, held
    /// in session, and then runs out — never restarted on every read.
    @Test func aRebaseThatCannotBeWrittenStillRunsOut() async throws {
        let harness = try PinAttemptHarness()
        await harness.burnWrongAttempts(3)
        harness.failLockoutWrites.value = true
        harness.reboot(bootId: "boot-2", clockAfter: 1_000)
        #expect(harness.manager.remainingLockoutMillis == 30_000)
        harness.advance(millis: 10_000)
        #expect(harness.manager.remainingLockoutMillis == 20_000)
        harness.advance(millis: 20_000)
        #expect(harness.manager.remainingLockoutMillis == 0)
    }

    /// A lockout that cannot be written to the Keychain is still a lockout for
    /// the rest of the session — otherwise a failing write is free guesses.
    @Test func aFailedLockoutWriteStillDelaysTheNextGuess() async throws {
        let harness = try PinAttemptHarness()
        harness.failLockoutWrites.value = true
        #expect(await harness.burnWrongAttempts(3) == .rejected(delayMillis: 30_000))
        #expect(harness.store.lockoutDurationMillis == 0)

        #expect(harness.manager.remainingLockoutMillis == 30_000)
        #expect(await harness.manager.attemptPinUnlock("83910472") == .rejected(delayMillis: 30_000))
        harness.advance(millis: 30_000)
        #expect(await harness.manager.attemptPinUnlock("83910472") == .success)
    }

    // MARK: - Device-owner unlock

    /// Touch ID or the login password proves more than the PIN does, so a
    /// successful one resets the wrong-PIN count and the lockout — stored and
    /// in session — exactly as a correct PIN would.
    @Test func aDeviceOwnerUnlockResetsTheWrongPinCount() async throws {
        let harness = try PinAttemptHarness()
        await harness.burnWrongAttempts(4)
        #expect(harness.store.failedAttempts == 4)
        #expect(harness.manager.remainingLockoutMillis > 0)

        #expect(await harness.manager.requestUnlock())
        #expect(harness.store.failedAttempts == 0)
        #expect(harness.manager.remainingLockoutMillis == 0)

        // The session count went too: the next wrong PIN is the first again.
        harness.manager.lock()
        #expect(await harness.manager.attemptPinUnlock("00000001") == .rejected(delayMillis: 0))
        #expect(harness.store.failedAttempts == 1)
    }

    /// A failed or cancelled prompt resets nothing.
    @Test func aFailedDeviceOwnerUnlockKeepsTheCount() async throws {
        let harness = try PinAttemptHarness(authenticator: ScriptedUnlockAuthenticator(.failed))
        await harness.burnWrongAttempts(2)
        #expect(await harness.manager.requestUnlock() == false)
        #expect(harness.store.failedAttempts == 2)
    }
}

/// Answers every unlock prompt with one outcome.
private struct ScriptedUnlockAuthenticator: DeviceAuthenticating {
    let outcome: DeviceAuthOutcome
    init(_ outcome: DeviceAuthOutcome) { self.outcome = outcome }
    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> Bool { outcome == .success }
    func authenticateForUnlock(reason: String) async -> DeviceAuthOutcome { outcome }
}
