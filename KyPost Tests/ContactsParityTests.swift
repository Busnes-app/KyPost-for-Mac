//
//  ContactsParityTests.swift
//  KyPost Tests
//
//  Contact sync status (Android #182), vCard export (Android #184, ported from
//  VCardWriterTest.kt), and pinned-key revocation (Android #191).
//

import Foundation
import Testing
@testable import KyPost

private func contact(_ name: String, email: String? = nil, needsSync: Bool = false, updatedAt: Date = Date()) -> Contact {
    var value = Contact(name: name, avatarUrl: nil, createdAt: updatedAt, updatedAt: updatedAt, needsSync: needsSync)
    if let email { value.emails = [ContactLabeledValue(label: nil, value: email)] }
    return value
}

@MainActor
private struct ContactsEnvironment {
    let repository: ContactSyncRepository
    let dao: ContactDAO
    let pendingDeletes: ContactPendingDeletesStore
    let pins: RecipientPinStore

    init(client: HTTPClient = stubClient(), paired: Bool = true) throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let db = try AppDatabase(inMemory: true)
        dao = ContactDAO(modelContainer: db.container)
        pendingDeletes = ContactPendingDeletesStore(defaults: defaults)
        pins = RecipientPinStore(
            defaults: defaults,
            hostileLocation: HostileLocationProtectionStore(defaults: defaults)
        )
        repository = ContactSyncRepository(
            client: ContactSyncClient(httpClient: client),
            contactDAO: dao,
            cursorStore: ContactCursorStore(defaults: defaults),
            pendingDeletesStore: pendingDeletes,
            securePairingStore: try makePairedStore(paired: paired),
            recipientPins: pins,
            keyRevocation: GopenPGPCrypto()
        )
    }
}

// MARK: - Sync status

@Suite struct ContactSyncStatusTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func nothingQueuedAndNoFailuresIsIdle() {
        #expect(ContactSyncStatus.of(pending: .init(), failures: .init(), now: now) == .idle)
    }

    @Test func aFreshQueueIsWaiting() {
        let pending = ContactPendingSummary(count: 3, oldestQueuedAt: now.addingTimeInterval(-60))
        #expect(ContactSyncStatus.of(pending: pending, failures: .init(), now: now) == .waiting(pending: 3))
    }

    @Test func aChangeQueuedOverAnHourIsStuck() {
        let pending = ContactPendingSummary(count: 1, oldestQueuedAt: now.addingTimeInterval(-3601))
        #expect(ContactSyncStatus.of(pending: pending, failures: .init(), now: now) == .stuck(pending: 1, reason: nil))
    }

    @Test func threeFailuresInARowAreStuckEvenWithNothingQueued() {
        let two = ContactSyncFailures(count: 2, lastReason: "boom")
        let three = ContactSyncFailures(count: 3, lastReason: "boom")
        #expect(ContactSyncStatus.of(pending: .init(), failures: two, now: now) == .idle)
        #expect(ContactSyncStatus.of(pending: .init(), failures: three, now: now) == .stuck(pending: 0, reason: "boom"))
    }

    @Test func theReasonIsTheFirstLineAndAtMost200Characters() {
        #expect(ContactSyncStatus.reasonLine("\n  first line  \nsecond") == "first line")
        #expect(ContactSyncStatus.reasonLine(String(repeating: "x", count: 500))?.count == 200)
        #expect(ContactSyncStatus.reasonLine(" \n ") == nil)
    }
}

@MainActor
@Suite struct ContactSyncHealthTests {
    @Test func failuresCountAndASuccessClearsThem() async throws {
        let failing = Box(true)
        let client = HTTPClient { request in
            let status = failing.value ? 500 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data((failing.value ? "relay down\nstack trace" : #"{"cursor": 1}"#).utf8), response)
        }
        let env = try ContactsEnvironment(client: client)
        for _ in 0..<3 { _ = try? await env.repository.sync() }
        #expect(env.repository.health.failures.count == 3)
        #expect(env.repository.health.failures.lastReason != nil)

        failing.value = false
        _ = try await env.repository.sync()
        #expect(env.repository.health.failures == ContactSyncFailures())
    }

    /// Not paired is not a failure: nothing was tried.
    @Test func notPairedIsNotCounted() async throws {
        let env = try ContactsEnvironment(paired: false)
        for _ in 0..<5 { _ = try? await env.repository.sync() }
        #expect(env.repository.health.failures.count == 0)
    }

    @Test func pendingCountsNamedChangesAndTombstonesButNotNamelessOnes() async throws {
        let env = try ContactsEnvironment()
        try await env.repository.saveContact(contact("Ada", email: "ada@example.com"))
        try await env.repository.saveContact(contact("   ", email: "nameless@example.com"))
        let queuedAt = Date().addingTimeInterval(-7200)
        env.pendingDeletes.add("srv-gone", now: queuedAt)

        let summary = await env.repository.pendingSummary()
        #expect(summary.count == 2)
        #expect(summary.oldestQueuedAt == queuedAt)
        // The tombstone is two hours old: stuck.
        #expect(ContactSyncStatus.of(pending: summary, failures: .init(), now: Date()) == .stuck(pending: 2, reason: nil))

        env.pendingDeletes.clear()
        #expect(env.pendingDeletes.oldestQueuedAt == nil)
    }
}

// MARK: - vCard (VCardWriterTest.kt)

@Suite struct VCardWriterTests {
    private var jane: Contact {
        var value = Contact(uid: "server-uid", name: "Jane Doe", avatarUrl: nil, createdAt: Date(), updatedAt: Date())
        value.givenName = "Jane"
        value.familyName = "Doe"
        value.org = "Acme"
        value.department = "R&D"
        value.title = "Engineer"
        value.birthday = "1990-01-15"
        value.notes = "line one\nline two"
        value.emails = [ContactLabeledValue(label: "Work", value: "jane@acme.example")]
        value.phones = [ContactLabeledValue(label: "Mobile", value: "+1 555 0100")]
        value.addresses = [ContactPostalAddress(label: "Home", street: "1 Main St", city: "Town", region: "ST", postalCode: "12345", country: "US")]
        value.websites = [ContactLabeledValue(label: nil, value: "https://jane.example")]
        return value
    }

    private func named(_ name: String) -> Contact {
        Contact(name: name, avatarUrl: nil, createdAt: Date(), updatedAt: Date())
    }

    @Test func v4WritesTheMappedFields() {
        let expected = [
            "BEGIN:VCARD",
            "VERSION:4.0",
            "FN:Jane Doe",
            "N:Doe;Jane;;;",
            "ORG:Acme;R&D",
            "TITLE:Engineer",
            "EMAIL;TYPE=work:jane@acme.example",
            "TEL;TYPE=cell:+1 555 0100",
            "ADR;TYPE=home:;;1 Main St;Town;ST;12345;US",
            "URL:https://jane.example",
            "BDAY:19900115",
            "NOTE:line one\\nline two",
            "END:VCARD",
            "",
        ].joined(separator: "\r\n")
        #expect(VCardWriter.write([jane], version: .v4) == expected)
    }

    @Test func v3UsesItsVersionAndDateForm() {
        let card = VCardWriter.write([jane], version: .v3)
        #expect(card.contains("\r\nVERSION:3.0\r\n"))
        #expect(card.contains("\r\nBDAY:1990-01-15\r\n"))
    }

    @Test func theServerUidIsNotExported() {
        #expect(!VCardWriter.write([jane], version: .v4).contains("server-uid"))
    }

    @Test func textIsEscapedSoAValueCannotInjectAProperty() {
        let card = VCardWriter.write([named("Eve\r\nEND:VCARD\r\nBEGIN:VCARD\r\nFN:Mallory; a, b\\c")], version: .v4)
        #expect(card.components(separatedBy: "\r\n").filter { $0.hasPrefix("BEGIN:") } == ["BEGIN:VCARD"])
        #expect(card.contains("FN:Eve\\nEND:VCARD\\nBEGIN:VCARD\\nFN:Mallory\\; a\\, b\\\\c\r\n"))
    }

    /// Beyond Android: lone CR, NEL and the Unicode line separators cannot end
    /// a line either.
    @Test func noLineBreakingScalarSurvivesInAValue() {
        let card = VCardWriter.write([named("A\rB\u{0085}C\u{2028}D\u{2029}E\u{0000}F")], version: .v4)
        #expect(card.contains("FN:A\\nBCDEF\r\n"))
    }

    @Test func urlsAndTypeLabelsCannotBreakTheLineOrParameters() {
        var hostile = named("X")
        hostile.websites = [ContactLabeledValue(label: nil, value: "https://a.example/\r\nNOTE:injected")]
        hostile.emails = [ContactLabeledValue(label: "we\"ird:label;x", value: "x@example.org")]
        let card = VCardWriter.write([hostile], version: .v4)
        #expect(!card.contains("\r\nNOTE:"))
        #expect(card.contains("EMAIL;TYPE=\"weird:label;x\":x@example.org\r\n"))
    }

    @Test func longLinesFoldAt75OctetsWithoutSplittingACharacter() {
        let name = String(repeating: "é", count: 100)
        let card = VCardWriter.write([named(name)], version: .v4)
        for line in card.components(separatedBy: "\r\n") {
            #expect(line.utf8.count <= 75, "line over 75 octets: \(line)")
        }
        #expect(card.replacingOccurrences(of: "\r\n ", with: "").contains("FN:\(name)\r\n"))
    }

    @Test func aMalformedBirthdayIsLeftOut() {
        var value = named("X")
        value.birthday = "soon"
        #expect(!VCardWriter.write([value], version: .v4).contains("BDAY"))
    }

    @Test func aBirthdayThatIsNotACalendarDateIsLeftOutInBothVersions() {
        for version in VCardVersion.allCases {
            for date in ["2025-02-29", "2026-13-01", "+10000-01-01"] {
                var value = named("X")
                value.birthday = date
                #expect(!VCardWriter.write([value], version: version).contains("BDAY"), "\(version) \(date)")
            }
        }
        var leap = named("X")
        leap.birthday = "2024-02-29"
        #expect(VCardWriter.write([leap], version: .v4).contains("\r\nBDAY:20240229\r\n"))
        #expect(VCardWriter.write([leap], version: .v3).contains("\r\nBDAY:2024-02-29\r\n"))
    }

    @Test func aCommaInAFreeTextLabelIsQuotedWhileFaxStaysTwoTypes() {
        var value = named("X")
        value.emails = [ContactLabeledValue(label: "home,work", value: "x@example.org")]
        value.phones = [ContactLabeledValue(label: "Work Fax", value: "+1"), ContactLabeledValue(label: "a,b", value: "+2")]
        let card = VCardWriter.write([value], version: .v4)
        #expect(card.contains("\r\nEMAIL;TYPE=\"home,work\":x@example.org\r\n"))
        #expect(card.contains("\r\nTEL;TYPE=work,fax:+1\r\n"))
        #expect(card.contains("\r\nTEL;TYPE=\"a,b\":+2\r\n"))
    }

    @Test func severalContactsAreConcatenated() {
        let card = VCardWriter.write([named("A"), named("B")], version: .v3)
        #expect(card.components(separatedBy: "BEGIN:VCARD").count - 1 == 2)
    }

    @Test func theFileNameIsTheContactsNameWithoutPathSeparators() {
        #expect(VCardWriter.fileName(for: [named("Jane Doe")]) == "Jane Doe.vcf")
        #expect(VCardWriter.fileName(for: [named("../etc/pass:wd")]) == ".. etc pass wd.vcf")
        #expect(VCardWriter.fileName(for: [named("A"), named("B")]) == "Contacts.vcf")
    }
}

// MARK: - Pinned-key revocation (crypto)

@Suite struct PinnedKeyRevocationTests {
    private let crypto = GopenPGPCrypto()

    @Test func aVerifiedPrimaryRevocationIsTaken() throws {
        #expect(!crypto.isPrimaryRevoked(armoredPublicKey: PinnedKeyFixtures.alicePinned))
        let merged = try #require(crypto.withVerifiedRevocation(
            pinned: PinnedKeyFixtures.alicePinned, synced: PinnedKeyFixtures.aliceRevokedPrimary
        ))
        #expect(crypto.isPrimaryRevoked(armoredPublicKey: merged))
        // Still the same key.
        #expect(PgpFingerprint.compute(fromArmored: merged) == PgpFingerprint.compute(fromArmored: PinnedKeyFixtures.alicePinned))
    }

    @Test func aVerifiedSubkeyRevocationIsTakenAndLeavesNothingToEncryptTo() throws {
        let merged = try #require(crypto.withVerifiedRevocation(
            pinned: PinnedKeyFixtures.alicePinned, synced: PinnedKeyFixtures.aliceRevokedSubkey
        ))
        #expect(!crypto.isPrimaryRevoked(armoredPublicKey: merged))
        #expect(throws: (any Error).self) {
            try crypto.encryptAndSign(
                plaintext: Data("x".utf8),
                recipientKeys: [merged],
                privateKey: Data(TestPgpFixtures.armoredPrivate.utf8)
            )
        }
    }

    /// A revocation packet that does not verify against the pinned primary is
    /// never taken, and never counts as a revocation.
    @Test func aForgedRevocationIsRefused() {
        #expect(crypto.withVerifiedRevocation(
            pinned: PinnedKeyFixtures.alicePinned, synced: PinnedKeyFixtures.aliceForgedRevocation
        ) == nil)
        #expect(!crypto.isPrimaryRevoked(armoredPublicKey: PinnedKeyFixtures.aliceForgedRevocation))
    }

    @Test func aDifferentPrimaryCannotRevokeThePin() {
        #expect(crypto.withVerifiedRevocation(
            pinned: PinnedKeyFixtures.alicePinned, synced: PinnedKeyFixtures.bobRevoked
        ) == nil)
    }

    /// A synced copy can withdraw pinned keys, never add one.
    @Test func newMaterialInTheSyncedCopyNeverCrosses() {
        #expect(crypto.withVerifiedRevocation(
            pinned: PinnedKeyFixtures.alicePinned, synced: PinnedKeyFixtures.aliceWithExtraSubkey
        ) == nil)
    }

    @Test func anIdenticalCopyHasNothingToTake() {
        #expect(crypto.withVerifiedRevocation(
            pinned: PinnedKeyFixtures.alicePinned, synced: PinnedKeyFixtures.alicePinned
        ) == nil)
    }

    @Test func aRevocationAlreadyHeldIsNotTakenTwice() throws {
        let merged = try #require(crypto.withVerifiedRevocation(
            pinned: PinnedKeyFixtures.alicePinned, synced: PinnedKeyFixtures.aliceRevokedPrimary
        ))
        #expect(crypto.withVerifiedRevocation(pinned: merged, synced: PinnedKeyFixtures.aliceRevokedPrimary) == nil)
    }

    @Test func theSplitterRefusesTwoKeysInOneBlob() throws {
        let one = try #require(OpenPgpKeySections(armored: PinnedKeyFixtures.alicePinned))
        let other = try #require(OpenPgpKeySections(armored: PinnedKeyFixtures.bobRevoked))
        var both = one.data
        both.append(other.data)
        #expect(OpenPgpKeySections(data: both) == nil)
    }
}

// MARK: - Pins: store, writers, consumers

@MainActor
@Suite struct RecipientPinTests {
    @Test func aQrSavePinsTheKeyForTheContactsAddresses() async throws {
        let env = try ContactsEnvironment()
        var alice = contact("Alice", email: "Alice@Example.invalid")
        alice.pgpKey = PinnedKeyFixtures.alicePinned
        try await env.repository.saveContact(alice, verifiedInPerson: true)

        let pin = try #require(env.pins.pin(for: "alice@example.invalid"))
        #expect(pin.fingerprint == PgpFingerprint.compute(fromArmored: PinnedKeyFixtures.alicePinned))
        if case .intact = env.pins.snapshot(revocation: GopenPGPCrypto()).state(for: "ALICE@example.invalid") {} else {
            Issue.record("expected an intact pin")
        }
    }

    /// An ordinary save never creates a pin.
    @Test func anOrdinarySaveDoesNotPin() async throws {
        let env = try ContactsEnvironment()
        var alice = contact("Alice", email: "alice@example.invalid")
        alice.pgpKey = PinnedKeyFixtures.alicePinned
        try await env.repository.saveContact(alice)
        #expect(env.pins.pin(for: "alice@example.invalid") == nil)
    }

    /// A synced copy carrying its owner's revocation revokes the pin; the pin
    /// stays the address's pin.
    @Test func aSyncedRevocationRevokesThePin() async throws {
        let revokedKeyJSON = try String(
            data: JSONEncoder().encode(PinnedKeyFixtures.aliceRevokedPrimary), encoding: .utf8
        )!
        let json = """
        { "cursor": 2, "changed": [
          { "uid": "srv-alice", "rev": 2, "fn": "Alice",
            "emails": [{ "value": "alice@example.invalid" }], "pgpKey": \(revokedKeyJSON) }
        ] }
        """
        let env = try ContactsEnvironment(client: stubClient(json: json))
        env.pins.pin(addresses: ["alice@example.invalid"], publicKey: PinnedKeyFixtures.alicePinned)

        _ = try await env.repository.sync()

        #expect(env.pins.snapshot(revocation: GopenPGPCrypto()).state(for: "alice@example.invalid") == .revoked)
    }

    @Test func aForgedSyncedRevocationLeavesThePinIntact() async throws {
        let env = try ContactsEnvironment()
        env.pins.pin(addresses: ["alice@example.invalid"], publicKey: PinnedKeyFixtures.alicePinned)
        var alice = contact("Alice", email: "alice@example.invalid")
        alice.pgpKey = PinnedKeyFixtures.aliceForgedRevocation
        try await env.repository.saveContact(alice)

        let pin = try #require(env.pins.pin(for: "alice@example.invalid"))
        #expect(pin.publicKey == PinnedKeyFixtures.alicePinned)
    }

    /// Bytes that no longer fingerprint to the pin are broken, not absent.
    @Test func aPinWhoseBytesChangedIsBroken() throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = RecipientPinStore(defaults: defaults, hostileLocation: HostileLocationProtectionStore(defaults: defaults))
        store.pin(addresses: ["a@example.invalid"], publicKey: PinnedKeyFixtures.alicePinned)
        var tampered = store.all()
        tampered["a@example.invalid"]?.publicKey = PinnedKeyFixtures.bobRevoked
        defaults.set(try JSONEncoder().encode(tampered), forKey: "contacts.recipientPins")
        #expect(store.snapshot(revocation: GopenPGPCrypto()).state(for: "a@example.invalid") == .broken)
    }

    @Test func replacingAPinNeedsTheSameFingerprint() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = RecipientPinStore(defaults: defaults, hostileLocation: HostileLocationProtectionStore(defaults: defaults))
        store.pin(addresses: ["a@example.invalid"], publicKey: PinnedKeyFixtures.alicePinned)
        store.replaceRevoked(address: "a@example.invalid", with: PinnedKeyFixtures.bobRevoked)
        #expect(store.pin(for: "a@example.invalid")?.publicKey == PinnedKeyFixtures.alicePinned)
    }

    @Test func underHostileLocationProtectionPinsStayInMemory() throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let hostile = HostileLocationProtectionStore(defaults: defaults)
        hostile.enabled = true
        let store = RecipientPinStore(defaults: defaults, hostileLocation: hostile)
        store.pin(addresses: ["a@example.invalid"], publicKey: PinnedKeyFixtures.alicePinned)
        #expect(store.pin(for: "a@example.invalid") != nil)
        #expect(defaults.data(forKey: "contacts.recipientPins") == nil)
    }

    // MARK: Reader

    @Test func anIntactPinReplacesTheRelaysKeysAndIsConfirmed() {
        let offered = [SignerKey(addresses: ["alice@example.invalid"], publicKey: "RELAY-KEY", verified: false, source: "autocrypt")]
        let pins = RecipientPinSnapshot(states: ["alice@example.invalid": .intact(publicKey: "PINNED", fingerprint: "FP")])
        let keys = EncryptedMessageReader.signerKeys(offered, resolvedSender: "Alice@example.invalid", pins: pins)
        #expect(keys.map(\.publicKey) == ["PINNED"])
        #expect(keys.first?.verified == true)
    }

    /// A revoked pin reads as a changed key for a signed message — no
    /// fallback to the relay's key.
    @Test func aRevokedPinReadsAsKeyChanged() {
        let offered = [SignerKey(addresses: ["alice@example.invalid"], publicKey: "RELAY-KEY", verified: true)]
        let pins = RecipientPinSnapshot(states: ["alice@example.invalid": .revoked])
        let keys = EncryptedMessageReader.signerKeys(offered, resolvedSender: "alice@example.invalid", pins: pins)
        let state = signatureState(
            signature: RawSignature(present: true, valid: true, signerFingerprint: "ANY"),
            signerKeys: keys,
            fingerprint: { _ in "ANY" }
        )
        #expect(state == .keyChanged)
    }

    @Test func anUnpinnedSenderKeepsTheRelaysKeys() {
        let offered = [SignerKey(addresses: ["bob@example.invalid"], publicKey: "RELAY-KEY")]
        let keys = EncryptedMessageReader.signerKeys(offered, resolvedSender: "bob@example.invalid", pins: .none)
        #expect(keys == offered)
    }
}
