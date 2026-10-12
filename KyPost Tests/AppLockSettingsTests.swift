//
//  AppLockSettingsTests.swift
//  KyPost Tests
//
//  The user-selectable wipe threshold (Android security/LockoutPolicy.kt),
//  the lock grace period (Android security/AppLockSettings.kt and the
//  2026-08-28 grace fixes), and the unlock field's length cap (Android #139).
//

import Foundation
import Testing
@testable import KyPost

private struct AlwaysAuthenticates: DeviceAuthenticating {
    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> Bool { true }
}

@MainActor
private final class LockHarness {
    let keychain = KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
    let store: AppLockStore
    let pepper = FakePinPepper()
    let clock = Box<Int64>(0)
    let wipeCalls = Box(0)
    let session = EnrollmentSession()
    private(set) var manager: AppLockManager!

    /// Keychain items whose next threshold write fails.
    let failingThresholdWrites = Box<Set<String>>([])

    init(pin: String? = "83910472", lockEnabled: Bool = true) throws {
        let failing = failingThresholdWrites
        store = AppLockStore(
            keychain: keychain,
            defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!,
            beforeThresholdWrite: { key in
                if failing.value.contains(key) { throw KeychainStorage.KeychainError(status: -1) }
            }
        )
        try store.setLockEnabled(lockEnabled)
        rebuildManager()
        if let pin { try manager.setPin(pin) }
    }

    /// A fresh manager over the same store: what the next launch sees.
    func rebuildManager() {
        let clock = self.clock
        manager = AppLockManager(
            store: store,
            authenticator: AlwaysAuthenticates(),
            enrollmentSession: session,
            pepper: pepper,
            monotonicMillis: { clock.value }
        )
        manager.onWipe = { [wipeCalls] in
            wipeCalls.mutate { $0 += 1 }
            return .complete
        }
    }

    func advance(seconds: Int64) {
        clock.mutate { $0 += seconds * 1000 }
    }

    /// Wrong attempts until a wipe or `limit`, stepping past each lockout.
    func burnUntilWipe(limit: Int) async -> Int? {
        for attempt in 1...limit {
            // Read first: the manager's clock is this Box, and `mutate` holds
            // its (non-recursive) lock while the closure runs.
            let remaining = manager.remainingLockoutMillis
            clock.mutate { $0 += remaining }
            if await manager.attemptPinUnlock("00000001") == .wiped { return attempt }
        }
        return nil
    }
}

// MARK: - Wipe threshold values

@Suite struct WipeThresholdTests {
    @Test func theChoicesMatchAndroid() {
        #expect(WipeThreshold.choices == [.after(10), .after(20), .after(30), .never])
    }

    /// Kept at ten — what every existing user was told when they set a PIN.
    @Test func theDefaultIsTenAndIsTheStrictest() {
        #expect(WipeThreshold.default == .after(10))
        #expect(WipeThreshold.strictest == .after(10))
    }

    @Test func onlyTheFourChoicesRoundTrip() {
        for choice in WipeThreshold.choices {
            #expect(WipeThreshold(wire: choice.wire) == choice)
        }
        #expect(WipeThreshold(wire: "25") == nil)
        #expect(WipeThreshold(wire: "0") == nil)
        #expect(WipeThreshold(wire: "999999") == nil)
        #expect(WipeThreshold(wire: "Never") == nil)
    }

    @Test func looserMeansMoreGuesses() {
        #expect(WipeThreshold.after(20).isLooser(than: .after(10)))
        #expect(WipeThreshold.never.isLooser(than: .after(30)))
        #expect(!WipeThreshold.after(10).isLooser(than: .after(20)))
        #expect(!WipeThreshold.after(30).isLooser(than: .never))
        #expect(!WipeThreshold.never.isLooser(than: .never))
    }

    @Test func neverOnlyEverRejects() {
        #expect(!LockoutPolicy.shouldWipe(attemptCount: 10_000, threshold: .never))
        #expect(!LockoutPolicy.shouldWipe(attemptCount: 19, threshold: .after(20)))
        #expect(LockoutPolicy.shouldWipe(attemptCount: 20, threshold: .after(20)))
    }
}

// MARK: - Tamper resistance

@Suite struct WipeThresholdSealTests {
    @Test func aSealedValueReadsBack() throws {
        let pepper = FakePinPepper()
        let tag = try WipeThresholdSeal.tag(for: .never, pepper: pepper)
        #expect(WipeThresholdSeal.read(.stored(wire: "never", tag: tag), pepper: pepper) == .never)
    }

    @Test func nothingStoredIsTheDefault() {
        #expect(WipeThresholdSeal.read(.absent, pepper: FakePinPepper()) == .default)
    }

    /// Every way the record can fail to vouch for itself reads as the
    /// strictest value — never as the looser one it claims.
    @Test func anythingUnverifiableIsTheStrictest() throws {
        let pepper = FakePinPepper()
        let tagForTen = try WipeThresholdSeal.tag(for: .after(10), pepper: pepper)
        // A forged "never" carrying another value's tag.
        #expect(WipeThresholdSeal.read(.stored(wire: "never", tag: tagForTen), pepper: pepper) == .strictest)
        // A garbage tag.
        #expect(WipeThresholdSeal.read(.stored(wire: "never", tag: Data("x".utf8)), pepper: pepper) == .strictest)
        // A value this app never writes, even correctly tagged.
        let forged = try pepper.mix(Data("KyPost wipe threshold v1:1000".utf8))
        #expect(WipeThresholdSeal.read(.stored(wire: "1000", tag: forged), pepper: pepper) == .strictest)
        // A Keychain that will not answer.
        #expect(WipeThresholdSeal.read(.unreadable, pepper: pepper) == .strictest)
        // A different device's pepper.
        let neverTag = try WipeThresholdSeal.tag(for: .never, pepper: pepper)
        #expect(WipeThresholdSeal.read(.stored(wire: "never", tag: neverTag), pepper: FakePinPepper(secret: "other")) == .strictest)
        // The pepper is gone.
        #expect(WipeThresholdSeal.read(.stored(wire: "never", tag: neverTag), pepper: FakePinPepper(available: false)) == .strictest)
    }

    /// Half a record is not "nothing configured", which would read as the
    /// default and hide the tampering.
    @MainActor
    @Test func aHalfWrittenRecordIsUnreadable() throws {
        let harness = try LockHarness()
        try harness.keychain.set("never", forKey: "appLock.wipeThreshold")
        #expect(harness.store.wipeThresholdRecord == .unreadable)
    }
}

// MARK: - Threshold in the attempt path

@MainActor
@Suite struct WipeThresholdAttemptTests {
    @Test func theDefaultWipesOnTheTenthWrongAttempt() async throws {
        let harness = try LockHarness()
        #expect(await harness.burnUntilWipe(limit: 40) == 10)
    }

    @Test func aChosenThresholdIsHonouredAcrossLaunches() async throws {
        let harness = try LockHarness()
        try harness.manager.setWipeThreshold(.after(20))
        harness.rebuildManager()
        #expect(harness.manager.wipeThresholdSetting == .after(20))
        #expect(await harness.burnUntilWipe(limit: 40) == 20)
    }

    @Test func neverOnlyThrottles() async throws {
        let harness = try LockHarness()
        try harness.manager.setWipeThreshold(.never)
        #expect(await harness.burnUntilWipe(limit: 45) == nil)
        #expect(harness.wipeCalls.value == 0)
        // The ladder still applies.
        #expect(harness.manager.remainingLockoutMillis > 0)
    }

    /// Writing "never" straight into the Keychain, without the pepper, does
    /// not disable the wipe — it tightens it to the strictest value.
    @Test func aTamperedValueFailsClosed() async throws {
        let harness = try LockHarness()
        try harness.manager.setWipeThreshold(.after(30))
        try harness.store.setWipeThreshold(wire: "never", tag: Data("forged".utf8))
        harness.rebuildManager()
        #expect(harness.manager.wipeThresholdSetting == .strictest)
        #expect(await harness.burnUntilWipe(limit: 40) == 10)
    }

    /// The attempt path re-reads and re-verifies; a tamper mid-session is
    /// caught without a relaunch.
    @Test func theAttemptPathDoesNotTrustTheMirror() async throws {
        let harness = try LockHarness()
        try harness.manager.setWipeThreshold(.after(20))
        try harness.store.setWipeThreshold(wire: "never", tag: Data("forged".utf8))
        #expect(await harness.burnUntilWipe(limit: 40) == 10)
    }

    /// Unchanged by the setting: a verifier that cannot be evaluated is not a
    /// wrong PIN, whatever the threshold.
    @Test func verifierUnavailableStillNeverCounts() async throws {
        let harness = try LockHarness()
        harness.pepper.available = false
        for _ in 0..<25 {
            #expect(await harness.manager.attemptPinUnlock("00000001") == .verifierUnavailable)
        }
        #expect(harness.store.failedAttempts == 0)
        #expect(harness.wipeCalls.value == 0)
    }

    @Test func theWipeResetClearsTheSetting() throws {
        let harness = try LockHarness()
        try harness.manager.setWipeThreshold(.never)
        try harness.manager.setLockGraceSeconds(300)
        try harness.store.reset()
        #expect(harness.store.wipeThresholdRecord == .absent)
        #expect(harness.store.lockGraceSeconds == 0)
    }

    /// The threshold is sealed to the pepper, so there is none to set before a
    /// PIN exists.
    @Test func settingAThresholdNeedsAPepper() throws {
        let harness = try LockHarness(pin: nil)
        harness.pepper.available = false
        #expect(throws: PepperUnavailable.self) {
            try harness.manager.setWipeThreshold(.never)
        }
        #expect(harness.store.wipeThresholdRecord == .absent)
    }
}

// MARK: - Failed saves

@MainActor
@Suite struct WipeThresholdFailedSaveTests {
    /// The value lands, the tag write fails: enforcement reads the strictest
    /// value, and the picker must show that rather than the old choice.
    @Test func aHalfWrittenSaveRefreshesTheDisplayedSetting() async throws {
        let harness = try LockHarness()
        try harness.manager.setWipeThreshold(.never)
        #expect(harness.manager.wipeThresholdSetting == .never)

        harness.failingThresholdWrites.mutate { $0 = ["appLock.wipeThresholdTag"] }
        #expect(throws: KeychainStorage.KeychainError.self) {
            try harness.manager.setWipeThreshold(.after(20))
        }
        #expect(harness.manager.wipeThreshold == .after(10))
        #expect(harness.manager.wipeThresholdSetting == .after(10))
    }
}

// MARK: - Grace period

@MainActor
@Suite struct LockGracePeriodTests {
    private func unlocked(grace: Int) async throws -> LockHarness {
        let harness = try LockHarness(pin: nil)
        try harness.manager.setLockGraceSeconds(grace)
        #expect(await harness.manager.requestUnlock())
        return harness
    }

    @Test func theOptionsMatchAndroidAndTheDefaultIsImmediately() {
        #expect(LockGracePeriod.options == [0, 30, 60, 300])
        #expect(LockGracePeriod.defaultSeconds == 0)
    }

    /// Fails closed: anything this app did not write is Immediately.
    @MainActor
    @Test func anUnknownStoredValueIsImmediately() throws {
        let harness = try LockHarness(pin: nil)
        #expect(harness.store.lockGraceSeconds == 0)
        try harness.keychain.set("86400", forKey: "appLock.graceSeconds")
        #expect(harness.store.lockGraceSeconds == 0)
        try harness.keychain.set("soon", forKey: "appLock.graceSeconds")
        #expect(harness.store.lockGraceSeconds == 0)
        try harness.keychain.set("60", forKey: "appLock.graceSeconds")
        #expect(harness.store.lockGraceSeconds == 60)
    }

    @Test func immediatelyLocksAtTheTrigger() async throws {
        let harness = try await unlocked(grace: 0)
        harness.manager.lockAfterGrace()
        #expect(harness.manager.isLocked)
        #expect(!harness.manager.isLockPending)
    }

    @Test func aGracePeriodDefersTheLockUntilItsDeadline() async throws {
        let harness = try await unlocked(grace: 30)
        harness.manager.lockAfterGrace()
        #expect(!harness.manager.isLocked)
        #expect(harness.manager.isLockPending)

        harness.advance(seconds: 29)
        #expect(!harness.manager.resolvePendingLock())
        harness.advance(seconds: 1)
        #expect(harness.manager.resolvePendingLock())
        #expect(!harness.manager.isLockPending)
    }

    @Test func returningInsideTheWindowCancelsIt() async throws {
        let harness = try await unlocked(grace: 60)
        harness.manager.lockAfterGrace()
        harness.advance(seconds: 10)
        harness.manager.returnedWithinGrace()
        #expect(!harness.manager.isLocked)
        #expect(!harness.manager.isLockPending)
        // A stale deadline cannot fire later (Android 590866f6).
        harness.advance(seconds: 600)
        #expect(!harness.manager.resolvePendingLock())
    }

    /// The suspended-app case: no timer fired, the user returns late, and the
    /// return itself must lock.
    @Test func returningAfterTheWindowLocks() async throws {
        let harness = try await unlocked(grace: 30)
        harness.manager.lockAfterGrace()
        harness.advance(seconds: 31)
        harness.manager.returnedWithinGrace()
        #expect(harness.manager.isLocked)
    }

    /// A later trigger never pushes an earlier deadline back.
    @Test func aSecondTriggerKeepsTheEarlierDeadline() async throws {
        let harness = try await unlocked(grace: 30)
        harness.manager.lockAfterGrace()
        harness.advance(seconds: 20)
        harness.manager.lockAfterGrace()
        harness.advance(seconds: 10)
        #expect(harness.manager.resolvePendingLock())
    }

    /// A successful unlock clears any pending deadline so it cannot re-lock the
    /// session the user just opened (Android 7d791090).
    @Test func anUnlockClearsAPendingDeadline() async throws {
        let harness = try await unlocked(grace: 30)
        harness.manager.lockAfterGrace()
        harness.manager.lock()
        #expect(await harness.manager.requestUnlock())
        harness.advance(seconds: 600)
        #expect(!harness.manager.resolvePendingLock())
        #expect(!harness.manager.isLockPending)
    }

    /// The grace period is about the UI gate. The unsealed private key goes
    /// at the trigger, as before.
    @Test func theTriggerStillDropsTheUnsealedKeyAtOnce() async throws {
        let harness = try await unlocked(grace: 300)
        harness.session.put(armoredKey: "-----BEGIN PGP PRIVATE KEY BLOCK-----")
        harness.manager.lockAfterGrace()
        #expect(!harness.session.isHeld)
        #expect(!harness.manager.isLocked)
    }

    /// A screen-unlock hint the session state does not confirm leaves the
    /// deadline in place, and passing it locks and drops the gated secret.
    @Test func anUnverifiedScreenUnlockKeepsTheDeadline() async throws {
        let harness = try await unlocked(grace: 30)
        harness.manager.cacheGatedSecret("device-secret")
        harness.manager.lockAfterGrace()
        harness.advance(seconds: 5)
        harness.manager.screenUnlockReported(verifiedUnlocked: false)
        #expect(harness.manager.isLockPending)
        #expect(!harness.manager.isLocked)

        harness.advance(seconds: 26)
        #expect(harness.manager.resolvePendingLock())
        #expect(harness.manager.cachedGatedSecret == nil)
    }

    @Test func aVerifiedScreenUnlockCancelsTheDeadline() async throws {
        let harness = try await unlocked(grace: 30)
        harness.manager.lockAfterGrace()
        harness.advance(seconds: 5)
        harness.manager.screenUnlockReported(verifiedUnlocked: true)
        #expect(!harness.manager.isLockPending)
        harness.advance(seconds: 600)
        #expect(!harness.manager.resolvePendingLock())
    }

    /// The background snapshot is covered for the whole grace period, not
    /// only once the lock engages.
    @Test func theSnapshotIsCoveredWhileALockIsPending() async throws {
        let harness = try await unlocked(grace: 30)
        harness.manager.lockAfterGrace()
        #expect(harness.manager.isLockPending)
        #expect(harness.manager.backgroundSnapshotNeedsCover)
        let off = try LockHarness(pin: nil, lockEnabled: false)
        #expect(!off.manager.backgroundSnapshotNeedsCover)
    }

    /// A superseded graph's manager, still retained, must not act on the
    /// shared session after shutdown.
    @Test func shutdownDropsThePendingLock() async throws {
        let harness = try await unlocked(grace: 30)
        let old = harness.manager!
        old.lockAfterGrace()
        old.shutdown()
        #expect(!old.isLockPending)

        harness.session.put(armoredKey: "-----BEGIN PGP PRIVATE KEY BLOCK-----")
        harness.advance(seconds: 600)
        #expect(!old.resolvePendingLock())
        #expect(harness.session.isHeld)
    }

    @Test func nothingIsPendingWhileTheLockIsOff() throws {
        let harness = try LockHarness(pin: nil, lockEnabled: false)
        try harness.manager.setLockGraceSeconds(30)
        harness.manager.lockAfterGrace()
        #expect(!harness.manager.isLockPending)
        #expect(!harness.manager.isLocked)
    }
}

// MARK: - Unlock field

@Suite struct PinFieldCapTests {
    @Test func theFieldKeepsUpToTheLongestValidPin() {
        #expect(PinPolicy.capped("839104728350") == "839104728350")
        #expect(PinPolicy.capped("8391047283501234") == "839104728350")
        #expect(PinPolicy.capped("8391") == "8391")
        // The longest PIN the policy accepts must survive the cap.
        #expect(PinPolicy.validate(PinPolicy.capped("839104728350")) == .valid)
    }
}
