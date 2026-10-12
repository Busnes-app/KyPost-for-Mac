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
    let manager: AppLockManager
    /// The lockout deadline is written on a monotonic clock, so the tests own
    /// one rather than sleeping through a thirty-minute rung.
    let clock = Box<Int64>(0)
    let wipeCalls = Box(0)
    var wipeResult: WipeResult = .complete

    init(pin: String? = "83910472", wireWipe: Bool = true) throws {
        store = makeLockStore()
        // Before the manager is built: it reads the flag at init to decide
        // whether this process starts locked.
        try store.setLockEnabled(true)
        pepper = FakePinPepper()
        let clock = self.clock
        manager = AppLockManager(
            store: store,
            authenticator: StubAlwaysAuthenticator(),
            pepper: pepper,
            monotonicMillis: { clock.value }
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

    /// The deadline lives on a monotonic clock that restarts at zero on
    /// reboot, so a stored deadline can read as the whole of the previous
    /// uptime. Clamping to the recorded duration fails safe.
    @Test func aRebootCannotStretchALockoutToTheWholeUptime() async throws {
        let harness = try PinAttemptHarness()
        await harness.burnWrongAttempts(3)
        #expect(harness.manager.remainingLockoutMillis == 30_000)

        // The stored deadline is far in the future of a clock that just
        // restarted; the clamp holds it to the delay actually imposed.
        try harness.store.setLockout(untilMillis: 9_000_000, durationMillis: 30_000)
        #expect(harness.manager.remainingLockoutMillis == 30_000)
    }
}
