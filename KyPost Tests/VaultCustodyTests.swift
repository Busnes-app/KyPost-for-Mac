//
//  VaultCustodyTests.swift
//  KyPost Tests
//
//  The private key at rest: sealed to the device key, opened only through
//  the presence-checked Secure Enclave step, once per app unlock, and
//  migrated off the plaintext layout earlier builds wrote. The Secure
//  Enclave and LocalAuthentication are faked at `VaultKeySealing`.
//

import Foundation
import LocalAuthentication
import Testing
@testable import KyPost

/// Stands in for the Secure Enclave key. Sealing is reversible but never
/// leaves the plaintext readable; opening "prompts" whenever it is handed a
/// context that has not authenticated yet, as the system does.
nonisolated final class FakeKeySealing: VaultKeySealing, @unchecked Sendable {
    private let lock = NSLock()
    /// Held strongly: an `ObjectIdentifier` of a freed context can be reused
    /// by the next one allocated.
    private var authenticated: [LAContext] = []
    private var stale: [LAContext] = []
    private var _prompts = 0
    /// What the next prompt does.
    var cancelPrompts = false
    var failOpens = false

    /// Simulates the app unlock having evaluated `context`.
    func markAuthenticated(_ context: LAContext) {
        lock.lock(); defer { lock.unlock() }
        authenticated.append(context)
    }

    /// Simulates the system invalidating a context: every use of it fails.
    func markStale(_ context: LAContext) {
        lock.lock(); defer { lock.unlock() }
        stale.append(context)
    }

    var prompts: Int {
        lock.lock(); defer { lock.unlock() }
        return _prompts
    }

    func seal(_ plaintext: Data) throws -> Data {
        Data("SEALED".utf8) + Data(plaintext.map { $0 ^ 0xA5 })
    }

    /// Runs inside a successful open, after the prompt — where a real lock
    /// can land while the Secure Enclave is still answering.
    var duringOpen: (() -> Void)?

    func open(_ sealed: Data, context: LAContext) throws -> Data {
        let plaintext = try openLocked(sealed, context: context)
        duringOpen?()
        return plaintext
    }

    private func openLocked(_ sealed: Data, context: LAContext) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if failOpens || stale.contains(where: { $0 === context }) {
            throw EnrollmentVaultError.keychain(errSecAuthFailed)
        }
        if !authenticated.contains(where: { $0 === context }) {
            _prompts += 1
            if cancelPrompts { throw EnrollmentVaultError.cancelled }
            authenticated.append(context)
        }
        guard sealed.starts(with: Data("SEALED".utf8)) else { throw EnrollmentVaultError.unavailable }
        return Data(sealed.dropFirst(6).map { $0 ^ 0xA5 })
    }
}

/// A vault on an in-memory Keychain and a fake device key, with its own
/// presence context so tests never share one.
func testVault(
    _ store: MemoryItemStore = MemoryItemStore(),
    sealing: FakeKeySealing = FakeKeySealing(),
    presence: PresenceContext = PresenceContext()
) -> EnrollmentVault {
    EnrollmentVault(
        keychain: store,
        keyTag: "org.kysecurity.mail.tests.\(UUID().uuidString)",
        sealing: sealing,
        presence: presence
    )
}

@Suite(.serialized) struct VaultCustodyTests {
    private let ring = VaultRecord(
        kind: .keyring, material: V3Fixtures.ringBytes,
        identityFingerprint: V3Fixtures.active, materialGeneration: 2
    )

    private func contains(_ haystack: Data, _ needle: Data) -> Bool {
        haystack.range(of: needle) != nil
    }

    /// The Keychain item holds ciphertext, and the header stays readable
    /// without a prompt.
    @Test func theStoredItemNeverHoldsTheKeyInTheClear() throws {
        let store = MemoryItemStore()
        let sealing = FakeKeySealing()
        let vault = testVault(store, sealing: sealing)
        try vault.store(ring)
        let raw = try #require(try store.data(forKey: "enrollment.vaultRecord"))
        #expect(!contains(raw, V3Fixtures.ringBytes))
        #expect(VaultRecord.decode(raw) == nil, "never the plaintext format")
        #expect(try vault.storedHeader() == ring.header)
        #expect(vault.keyringAcknowledgement()?.materialGeneration == 2)
        #expect(sealing.prompts == 0, "storing and reading the header never prompt")
    }

    @Test func openingIsThePresenceCheckedStep() throws {
        let sealing = FakeKeySealing()
        let vault = testVault(sealing: sealing)
        try vault.store(ring)
        #expect(try vault.openRecord() == ring)
        #expect(sealing.prompts == 1)
    }

    /// Once per app unlock: a second open reuses the held context; a lock
    /// invalidates it and the next open prompts once more.
    @Test func thePromptIsOncePerUnlock() throws {
        let sealing = FakeKeySealing()
        let presence = PresenceContext()
        let vault = testVault(sealing: sealing, presence: presence)
        try vault.store(ring)
        _ = try vault.openRecord()
        _ = try vault.openRecord()
        #expect(sealing.prompts == 1)
        presence.invalidate()
        _ = try vault.openRecord()
        _ = try vault.openRecord()
        #expect(sealing.prompts == 2)
    }

    /// The app unlock's own evaluated context is reused: no second prompt.
    @Test func theAppUnlocksContextIsReused() throws {
        let sealing = FakeKeySealing()
        let presence = PresenceContext()
        let vault = testVault(sealing: sealing, presence: presence)
        try vault.store(ring)
        let unlock = LAContext()
        sealing.markAuthenticated(unlock)
        presence.adopt(unlock)
        #expect(try vault.openRecord() == ring)
        #expect(sealing.prompts == 0)
    }

    @Test func aDismissedPromptIsCancelledAndHoldsNothing() throws {
        let sealing = FakeKeySealing()
        let presence = PresenceContext()
        let vault = testVault(sealing: sealing, presence: presence)
        try vault.store(ring)
        sealing.cancelPrompts = true
        #expect(throws: EnrollmentVaultError.cancelled) { try vault.openRecord() }
        #expect(!presence.isHeld)
    }

    /// A lock that lands while a prompt is up must win: the context from
    /// before the lock is not kept.
    @Test func aLeaseFromBeforeALockIsNotKept() {
        let presence = PresenceContext()
        let lease = presence.lease(reason: "test")
        presence.invalidate()
        presence.keep(lease)
        #expect(!presence.isHeld)
    }

    /// A lock that lands after the Secure Enclave answered but before the
    /// open returns wins: no plaintext, no held context, and the next open
    /// asks again.
    @Test func anOpenThatCrossesALockIsCancelled() throws {
        let sealing = FakeKeySealing()
        let presence = PresenceContext()
        let vault = testVault(sealing: sealing, presence: presence)
        try vault.store(ring)
        sealing.duringOpen = { presence.invalidate() }
        #expect(throws: EnrollmentVaultError.cancelled) { try vault.openRecord() }
        #expect(!presence.isHeld)

        sealing.duringOpen = nil
        #expect(try vault.openRecord() == ring)
        #expect(sealing.prompts == 2, "a new presence check after the lock")
    }

    /// The session refuses material from an open that began before a clear.
    @Test func theSessionRefusesMaterialFromBeforeAClear() {
        let session = EnrollmentSession()
        let epoch = session.epoch
        session.clear()
        #expect(!session.install(.legacyArmor(Data("KEY".utf8)), ifEpoch: epoch))
        #expect(!session.isHeld)
        #expect(session.install(.legacyArmor(Data("KEY".utf8)), ifEpoch: session.epoch))
        #expect(session.isHeld)
    }

    /// A held context that stopped working is dropped and asked once, fresh.
    @Test func aStaleHeldContextIsReplacedWithOnePrompt() throws {
        let sealing = FakeKeySealing()
        let presence = PresenceContext()
        let vault = testVault(sealing: sealing, presence: presence)
        try vault.store(ring)
        let invalidated = LAContext()
        sealing.markStale(invalidated)
        presence.adopt(invalidated)
        #expect(try vault.openRecord() == ring)
        #expect(sealing.prompts == 1, "one fresh prompt after the stale context failed")
        #expect(presence.isHeld)
        #expect(presence.lease(reason: "t").context !== invalidated)
    }

    /// A sealed record whose clear header was swapped does not open.
    @Test func aSwappedHeaderIsUnreadable() throws {
        let store = MemoryItemStore()
        let vault = testVault(store)
        try vault.store(ring)
        let raw = try #require(try store.data(forKey: "enrollment.vaultRecord"))
        let parsed = try #require(VaultRecord.parse(raw))
        var forged = parsed.header
        forged.materialGeneration = 9
        try store.setData(
            VaultRecord.encode(forged, format: VaultRecord.sealedFormat, tail: parsed.tail),
            forKey: "enrollment.vaultRecord"
        )
        #expect(throws: EnrollmentVaultError.unreadableRecord) { try vault.openRecord() }
    }

    // MARK: Migration

    /// An earlier build's plaintext record: the first presence-checked open
    /// re-seals it in place, and the plaintext is gone.
    @Test func aPlaintextRecordIsResealedOnTheFirstPresenceCheckedOpen() throws {
        let store = MemoryItemStore()
        try store.setData(ring.encoded(), forKey: "enrollment.vaultRecord")
        let sealing = FakeKeySealing()
        let vault = testVault(store, sealing: sealing)

        #expect(try vault.storedHeader() == ring.header, "readable before migration, without a prompt")
        #expect(try vault.openRecord() == ring)
        #expect(sealing.prompts == 1, "migration is presence-checked")

        let raw = try #require(try store.data(forKey: "enrollment.vaultRecord"))
        #expect(!contains(raw, V3Fixtures.ringBytes))
        #expect(VaultRecord.parse(raw)?.format == VaultRecord.sealedFormat)
        #expect(try vault.openRecord() == ring, "and it still opens")
    }

    /// The two-item layout: sealed into one record, both plaintext items gone.
    @Test func theTwoItemLayoutIsResealedAndRetired() throws {
        let store = MemoryItemStore()
        try store.setData(Data("ARMOR".utf8), forKey: "enrollment.sealedEnvelope")
        try store.setData(Data("ABCD".utf8), forKey: "enrollment.identityFingerprint")
        let vault = testVault(store)
        #expect(vault.isEnrolled)
        #expect(vault.identityFingerprint == "ABCD")

        let record = try #require(try vault.openRecord())
        #expect(record.kind == .legacyArmor)
        #expect(record.material == Data("ARMOR".utf8))
        #expect(store.keys == ["enrollment.vaultRecord"], "never both")
        let raw = try #require(try store.data(forKey: "enrollment.vaultRecord"))
        #expect(!contains(raw, Data("ARMOR".utf8)))
    }

    /// Dismissing the migration's prompt changes nothing; the next open migrates.
    @Test func aCancelledMigrationLeavesThePlaintextForTheNextOpen() throws {
        let store = MemoryItemStore()
        try store.setData(ring.encoded(), forKey: "enrollment.vaultRecord")
        let sealing = FakeKeySealing()
        let vault = testVault(store, sealing: sealing)
        sealing.cancelPrompts = true
        #expect(throws: EnrollmentVaultError.cancelled) { try vault.openRecord() }
        #expect(try store.data(forKey: "enrollment.vaultRecord") == ring.encoded())
        sealing.cancelPrompts = false
        #expect(try vault.openRecord() == ring)
        #expect(VaultRecord.parse(try #require(try store.data(forKey: "enrollment.vaultRecord")))?.format
            == VaultRecord.sealedFormat)
    }

    /// A device key that will not open what it sealed never replaces the
    /// plaintext: losing the key is worse than one more launch in the clear.
    @Test func aSealThatDoesNotOpenIsNeverWritten() throws {
        let store = MemoryItemStore()
        try store.setData(ring.encoded(), forKey: "enrollment.vaultRecord")
        let sealing = FakeKeySealing()
        sealing.failOpens = true
        let vault = testVault(store, sealing: sealing)
        #expect(throws: (any Error).self) { try vault.openRecord() }
        #expect(try store.data(forKey: "enrollment.vaultRecord") == ring.encoded())
    }

    /// Destroying the vault drops the held context with the record.
    @Test func destroyInvalidatesTheHeldContext() throws {
        let presence = PresenceContext()
        let vault = testVault(presence: presence)
        try vault.store(ring)
        _ = try vault.openRecord()
        #expect(presence.isHeld)
        vault.destroy()
        #expect(!presence.isHeld)
        #expect(!vault.isEnrolled)
    }

    // MARK: The opener

    @Test func theOpenerReadsTheSealedRecordAndMapsCancellation() async throws {
        let sealing = FakeKeySealing()
        let vault = testVault(sealing: sealing)
        try vault.store(privateKey: Data("ARMOR".utf8), identityFingerprint: "AB")
        let opener = DeviceVaultOpener(vault: vault, inspector: GopenPGPCrypto())
        #expect(await opener.open() == .opened(.legacyArmor(Data("ARMOR".utf8))))

        let cancelling = FakeKeySealing()
        cancelling.cancelPrompts = true
        let locked = testVault(sealing: cancelling)
        try locked.store(privateKey: Data("ARMOR".utf8), identityFingerprint: "AB")
        #expect(await DeviceVaultOpener(vault: locked, inspector: GopenPGPCrypto()).open() == .cancelled)
    }
}

// MARK: - The app-lock hook

private struct UnlockingAuthenticator: DeviceAuthenticating {
    let context: LAContext
    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> Bool { true }
    func authenticateForUnlock(reason: String) async -> (succeeded: Bool, context: LAContext?) {
        (true, context)
    }
}

@MainActor @Suite(.serialized) struct AppLockPresenceTests {
    private func manager(_ presence: PresenceContext, context: LAContext) throws -> AppLockManager {
        let store = AppLockStore(
            keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
        )
        try store.setLockEnabled(true)
        return AppLockManager(
            store: store,
            authenticator: UnlockingAuthenticator(context: context),
            enrollmentSession: EnrollmentSession(),
            presence: presence
        )
    }

    @Test func anUnlockHandsItsContextToTheVaultAndTheLockTakesItBack() async throws {
        let presence = PresenceContext()
        let context = LAContext()
        let subject = try manager(presence, context: context)
        #expect(subject.isLocked)
        #expect(await subject.requestUnlock())
        #expect(presence.lease(reason: "t").context === context)

        subject.lock()
        #expect(!presence.isHeld)
    }

    /// Backgrounding on iOS and the macOS screen lock go through
    /// `lockAfterGrace`; the context goes even inside a grace period.
    @Test func theLockTriggerInvalidatesEvenWithAGracePeriod() async throws {
        let presence = PresenceContext()
        let subject = try manager(presence, context: LAContext())
        _ = await subject.requestUnlock()
        try subject.setLockGraceSeconds(60)
        subject.lockAfterGrace()
        #expect(!subject.isLocked)
        #expect(!presence.isHeld)
    }
}
