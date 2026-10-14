//
//  AppLockPinTests.swift
//  KyPost Tests
//
//  Phase 11: the app-lock PIN's policy, its verifier, and the state the
//  lockout ladder is accounted in.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Test doubles

/// A pepper that mixes deterministically without a Secure Enclave, and can be
/// taken away mid-test — which is the case the whole `PepperUnavailable`
/// distinction exists for.
final class FakePinPepper: PinPepper, @unchecked Sendable {
    var secret: Data
    var available: Bool
    let ensureExistsCalls = Box(0)

    init(secret: String = "pepper-a", available: Bool = true) {
        self.secret = Data(secret.utf8)
        self.available = available
    }

    func ensureExists() throws {
        ensureExistsCalls.mutate { $0 += 1 }
    }

    func mix(_ input: Data) throws -> Data {
        guard available else { throw PepperUnavailable(detail: "test") }
        return secret + input
    }
}

func makeLockStore(defaults: UserDefaults? = nil) -> AppLockStore {
    let suite = defaults ?? UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
    return AppLockStore(
        keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)"),
        defaults: suite
    )
}

// MARK: - PinPolicy

@Suite struct PinPolicyTests {
    @Test func eightDigitsIsTheFloor() {
        #expect(PinPolicy.validate("8391047") == .tooShort)
        #expect(PinPolicy.validate("83910472") == .valid)
    }

    @Test func twelveDigitsIsTheCeiling() {
        #expect(PinPolicy.validate("839104728350") == .valid)
        #expect(PinPolicy.validate("8391047283501") == .tooLong)
    }

    /// Non-ASCII digits are rejected rather than accepted and hashed. Swift
    /// considers these numbers; a PIN keypad does not produce them, and a user
    /// who cannot retype what they entered is locked out of their own device.
    @Test func onlyAsciiDigitsCount() {
        #expect(PinPolicy.validate("8391047a") == .notNumeric)
        #expect(PinPolicy.validate("٤٥٦٧٨٩٠١") == .notNumeric)
        #expect(PinPolicy.validate("8391 047") == .notNumeric)
    }

    @Test func theLeakedDatasetFavouritesAreRefused() {
        #expect(PinPolicy.validate("12345678") == .tooCommon)
        #expect(PinPolicy.validate("12121212") == .tooCommon)
        #expect(PinPolicy.validate("14725836") == .tooCommon)
        #expect(PinPolicy.validate("01012000") == .tooCommon)
    }

    /// The families the fixed list cannot enumerate once a PIN may be twelve
    /// digits long.
    @Test func runsAreRefusedAtEveryLength() {
        #expect(PinPolicy.validate("23456789") == .tooCommon)
        #expect(PinPolicy.validate("987654321") == .tooCommon)
        #expect(PinPolicy.validate("111111111111") == .tooCommon)
        // Not a run: one delta breaks the sequence.
        #expect(PinPolicy.validate("23456780") == .valid)
    }

    /// Length is checked first, so a short weak PIN reports what the user has
    /// to fix rather than a rule that would not have applied yet.
    @Test func lengthOutranksTheWeakList() {
        #expect(PinPolicy.validate("1234") == .tooShort)
    }
}

// MARK: - LockoutPolicy

@Suite struct LockoutPolicyTests {
    @Test func thefirstTwoAttemptsAreFree() {
        #expect(LockoutPolicy.delayMillis(forAttemptCount: 0) == 0)
        #expect(LockoutPolicy.delayMillis(forAttemptCount: 1) == 0)
        #expect(LockoutPolicy.delayMillis(forAttemptCount: 2) == 0)
    }

    @Test func theCurveClimbsThenHolds() {
        #expect(LockoutPolicy.delayMillis(forAttemptCount: 3) == 30_000)
        #expect(LockoutPolicy.delayMillis(forAttemptCount: 4) == 60_000)
        #expect(LockoutPolicy.delayMillis(forAttemptCount: 5) == 300_000)
        #expect(LockoutPolicy.delayMillis(forAttemptCount: 6) == 900_000)
        #expect(LockoutPolicy.delayMillis(forAttemptCount: 7) == 1_800_000)
        // The last value repeats rather than running off the end.
        #expect(LockoutPolicy.delayMillis(forAttemptCount: 9) == 1_800_000)
        #expect(LockoutPolicy.delayMillis(forAttemptCount: 40) == 1_800_000)
    }

    @Test func theTenthWrongAttemptWipes() {
        #expect(!LockoutPolicy.shouldWipe(attemptCount: 9, threshold: .default))
        #expect(LockoutPolicy.shouldWipe(attemptCount: 10, threshold: .default))
        #expect(LockoutPolicy.shouldWipe(attemptCount: 11, threshold: .default))
    }
}

// MARK: - PinHasher

@Suite struct PinHasherTests {
    @Test func aCorrectPinMatchesAndAWrongOneDoesNot() throws {
        let pepper = FakePinPepper()
        let stored = try PinHasher.hash(pin: "83910472", pepper: pepper)
        #expect(try PinHasher.matches(pin: "83910472", stored: stored, pepper: pepper))
        #expect(try !PinHasher.matches(pin: "83910473", stored: stored, pepper: pepper))
    }

    @Test func theStoredValueIsNotThePin() throws {
        let stored = try PinHasher.hash(pin: "83910472", pepper: FakePinPepper())
        #expect(!stored.hash.isEmpty)
        #expect(!String(decoding: stored.hash, as: UTF8.self).contains("83910472"))
    }

    @Test func eachPinGetsItsOwnSalt() throws {
        let pepper = FakePinPepper()
        let first = try PinHasher.hash(pin: "83910472", pepper: pepper)
        let second = try PinHasher.hash(pin: "83910472", pepper: pepper)
        #expect(first.salt != second.salt)
        #expect(first.hash != second.hash)
    }

    /// The pepper is actually mixed in, which is the property that forces a
    /// brute force back onto this machine. Without it the stored verifier is
    /// crackable offline on a GPU.
    @Test func aDifferentPepperDoesNotVerify() throws {
        let stored = try PinHasher.hash(pin: "83910472", pepper: FakePinPepper(secret: "pepper-a"))
        #expect(try !PinHasher.matches(
            pin: "83910472", stored: stored, pepper: FakePinPepper(secret: "pepper-b")
        ))
    }

    /// **The load-bearing one.** A verifier that cannot be evaluated must
    /// throw, not answer false: false is indistinguishable from a wrong PIN,
    /// and wrong PINs are counted toward a wipe.
    @Test func aMissingPepperThrowsRatherThanReportingAWrongPin() throws {
        let pepper = FakePinPepper()
        let stored = try PinHasher.hash(pin: "83910472", pepper: pepper)
        pepper.available = false
        #expect(throws: PepperUnavailable.self) {
            try PinHasher.matches(pin: "83910472", stored: stored, pepper: pepper)
        }
    }

    /// A verifier from a build this one does not understand takes the same
    /// exit, for the same reason.
    @Test func anUnknownVerifierVersionThrows() throws {
        let pepper = FakePinPepper()
        var stored = try PinHasher.hash(pin: "83910472", pepper: pepper)
        stored.version = PinHasher.currentVersion + 1
        #expect(throws: PepperUnavailable.self) {
            try PinHasher.matches(pin: "83910472", stored: stored, pepper: pepper)
        }
    }

    /// Setting a PIN establishes the device key; verifying against a missing
    /// one must never mint a replacement, or every later correct PIN reads as
    /// wrong and ten of those wipe the machine.
    @Test func onlySettingAPinCreatesThePepper() throws {
        let pepper = FakePinPepper()
        let stored = try PinHasher.hash(pin: "83910472", pepper: pepper)
        #expect(pepper.ensureExistsCalls.value == 1)
        _ = try PinHasher.matches(pin: "83910472", stored: stored, pepper: pepper)
        _ = try PinHasher.matches(pin: "00000000", stored: stored, pepper: pepper)
        #expect(pepper.ensureExistsCalls.value == 1)
    }

    @Test func constantTimeComparisonStillCompares() {
        #expect(PinHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!PinHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        #expect(!PinHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
        #expect(PinHasher.constantTimeEquals(Data(), Data()))
    }
}

// MARK: - AppLockStore PIN state

@Suite struct AppLockPinStoreTests {
    @Test func aPinRoundTripsAndReportsItself() throws {
        let store = makeLockStore()
        #expect(store.storedPin == .absent)
        #expect(!store.hasPin)

        let hash = try PinHasher.hash(pin: "83910472", pepper: FakePinPepper())
        try store.setPin(hash)
        #expect(store.hasPin)
        #expect(store.storedPin == .configured(hash))
    }

    @Test func attemptCountersRoundTrip() throws {
        let store = makeLockStore()
        #expect(store.failedAttempts == 0)
        try store.setFailedAttempts(4)
        try store.setLockout(untilMillis: 5_000, durationMillis: 30_000, bootId: "boot-a")
        #expect(store.failedAttempts == 4)
        #expect(store.lockoutUntilMillis == 5_000)
        #expect(store.lockoutDurationMillis == 30_000)
        #expect(store.lockoutBootId == "boot-a")

        try store.resetFailedAttempts()
        #expect(store.failedAttempts == 0)
        #expect(store.lockoutUntilMillis == 0)
        #expect(store.lockoutDurationMillis == 0)
        #expect(store.lockoutBootId == nil)
    }

    @Test func aHalfWrittenVerifierIsUnreadableRatherThanAbsent() throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let keychain = KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
        let store = AppLockStore(keychain: keychain, defaults: defaults)
        try store.setPin(try PinHasher.hash(pin: "83910472", pepper: FakePinPepper()))

        // The documented key names are a binding contract; reaching them
        // directly is how a partial record is reproduced at all.
        try keychain.remove("appLock.pinVersion")
        #expect(store.storedPin == .unreadable)
        #expect(!store.hasPin)
    }
}

// MARK: - The tripwire

@Suite struct AppLockTripwireTests {
    @Test func aMachineThatNeverHadALockDoesNotFireIt() {
        let store = makeLockStore()
        #expect(!store.wasConfigured)
        #expect(!store.tripwireBroken)
    }

    /// **Not armed by the toggle.** The PIN is optional here — the lock can run
    /// with `LAContext` as its only verifier — so arming the marker when the
    /// toggle went on would make "configured, and the PIN vanished" true
    /// immediately, and the next launch would erase the user's mail for
    /// switching a setting.
    @Test func enablingTheLockAloneDoesNotArmIt() throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        #expect(!store.wasConfigured)
        #expect(!store.tripwireBroken)
    }

    /// The state the tripwire exists for: the plain marker says a lock was
    /// configured and the Keychain no longer holds one, which is what deleting
    /// the item to disable the lock looks like.
    @Test func aVanishedPinWithTheMarkerStillSetFiresIt() throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let keychain = KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
        let store = AppLockStore(keychain: keychain, defaults: defaults)
        try store.setPin(try PinHasher.hash(pin: "83910472", pepper: FakePinPepper()))
        #expect(!store.tripwireBroken)

        try keychain.remove("appLock.pinSalt")
        try keychain.remove("appLock.pinHash")
        try keychain.remove("appLock.pinVersion")
        #expect(store.tripwireBroken)
    }

    /// **Unreadable is not vanished.** This is the difference between a
    /// Keychain that is not ready yet and one that has been tampered with, and
    /// getting it wrong erases the user's mail for a transient status.
    @Test func anUnreadableVerifierDoesNotFireIt() throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let keychain = KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
        let store = AppLockStore(keychain: keychain, defaults: defaults)
        try store.setPin(try PinHasher.hash(pin: "83910472", pepper: FakePinPepper()))

        try keychain.remove("appLock.pinVersion")
        #expect(store.storedPin == .unreadable)
        #expect(!store.tripwireBroken)
    }

    /// Turning the PIN off must not leave the marker armed, or the next launch
    /// wipes the machine in response to the user changing a setting.
    @Test func clearingThePinDisarmsIt() throws {
        let store = makeLockStore()
        try store.setPin(try PinHasher.hash(pin: "83910472", pepper: FakePinPepper()))
        try store.clearPin()
        #expect(!store.wasConfigured)
        #expect(!store.tripwireBroken)
        #expect(store.storedPin == .absent)
    }

    @Test func resetClearsEverythingIncludingTheMarker() throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        try store.setCredentialGateEnabled(true)
        try store.setPin(try PinHasher.hash(pin: "83910472", pepper: FakePinPepper()))
        try store.setFailedAttempts(7)

        try store.reset()
        #expect(!store.lockEnabled)
        #expect(!store.credentialGateEnabled)
        #expect(store.storedPin == .absent)
        #expect(store.failedAttempts == 0)
        #expect(!store.wasConfigured)
        #expect(!store.tripwireBroken)
    }
}
