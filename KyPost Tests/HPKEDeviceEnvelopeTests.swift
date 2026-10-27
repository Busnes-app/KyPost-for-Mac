//
//  HPKEDeviceEnvelopeTests.swift
//  KyPost Tests
//
//  Device-envelope v4/v5 (RFC 9180 HPKE) and the one device key: the CFRG
//  vector, KyPost-Server's cross-platform vectors, the opener end to end, and
//  the vault's migration off the Security-framework key. The Secure Enclave is
//  replaced by `SoftwareKeyMinting` (same CryptoKit calls, software key).
//

import CryptoKit
import Foundation
import Testing
@testable import KyPost

private func hex(_ value: Any?) -> Data {
    let text = value as! String  // swiftlint:disable:this force_cast
    var data = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        data.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return data
}

private enum HPKEFixtures {
    static var file: [String: Any] { V3Fixtures.json(ServerPgpFixtures.deviceEnvelopeHPKE) }
    static var cfrg: [String: Any] {
        V3Fixtures.json(ServerPgpFixtures.hpkeCfrgP256AES256)["vector"] as! [String: Any]  // swiftlint:disable:this force_cast
    }

    static func entries(_ key: String) -> [[String: Any]] {
        file[key] as! [[String: Any]]  // swiftlint:disable:this force_cast
    }

    static func deviceKey() throws -> any DeviceAgreementKey {
        try P256.KeyAgreement.PrivateKey(rawRepresentation: V3Fixtures.data(file["devicePrivateKey"]))
    }

    static func json(_ entry: [String: Any]) -> String {
        String(decoding: V3Fixtures.serialize(entry["envelope"] as! [String: Any]), as: UTF8.self)  // swiftlint:disable:this force_cast
    }

    /// Parse, build the AAD from the opener's own id and fingerprint, open.
    /// Nil at any stage is a refusal.
    static func open(_ json: String, deviceId: String, fingerprint: String, key: any DeviceAgreementKey) throws -> Data? {
        guard let fields = parseDeviceEnvelope(json),
              let info = try? deviceEnvelopeAAD(version: fields.version, deviceId: deviceId, pgpFingerprint: fingerprint)
        else { return nil }
        return try openDeviceEnvelope(with: key, fields: fields, info: info)
    }
}

/// Seals as the browser does for v4/v5.
private func sealHPKE(
    version: Int, plaintext: Data, to publicKey: P256.KeyAgreement.PublicKey,
    deviceId: String = "dev", fingerprint: String = V3Fixtures.active
) throws -> String {
    let info = try deviceEnvelopeAAD(version: version, deviceId: deviceId, pgpFingerprint: fingerprint)
    var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: info)
    let ct = try sender.seal(plaintext)
    return String(decoding: V3Fixtures.serialize([
        "v": version, "alg": "HPKE-Base-P256-SHA256-A256GCM",
        "enc": sender.encapsulatedKey.base64EncodedString(), "ct": ct.base64EncodedString(),
    ]), as: UTF8.self)
}

/// Seals a retired v2/v3 envelope as the browser did (ECDH, HKDF salted with
/// the device key, AES-GCM, length-prefixed AAD), so a refusal is of a real one.
private func sealLegacy(version: Int, plaintext: Data, to publicKey: P256.KeyAgreement.PublicKey) throws -> String {
    let ephemeral = P256.KeyAgreement.PrivateKey()
    let domain = Data(envelopeDomain(version: version).utf8)
    let key = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey).hkdfDerivedSymmetricKey(
        using: SHA256.self, salt: publicKey.x963Representation, sharedInfo: domain, outputByteCount: 32
    )
    var aad = domain
    for field in [Data("dev".utf8), Data(V3Fixtures.active.utf8)] {
        aad.append(bigEndianUInt16(field.count))
        aad.append(field)
    }
    let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
    return String(decoding: V3Fixtures.serialize([
        "v": version, "alg": "ECDH-P256+HKDF-SHA256+A256GCM",
        "epk": ephemeral.publicKey.x963Representation.base64EncodedString(),
        "iv": Data(box.nonce).base64EncodedString(),
        "ct": (box.ciphertext + box.tag).base64EncodedString(),
    ]), as: UTF8.self)
}

/// A vault on the real HPKE sealing, with a software device key.
private func hpkeVault(_ store: MemoryItemStore, legacyKey: FakeKeySealing = FakeKeySealing()) -> EnrollmentVault {
    EnrollmentVault(
        keychain: store,
        keyTag: "org.kysecurity.mail.tests.\(UUID().uuidString)",
        legacyKey: legacyKey,
        keyMinting: SoftwareKeyMinting(),
        presence: PresenceContext()
    )
}

private let ring = VaultRecord(
    kind: .keyring, material: V3Fixtures.ringBytes,
    identityFingerprint: V3Fixtures.active, materialGeneration: 2
)

// MARK: - Vectors

@Suite struct HPKEVectorTests {
    /// The library check: CryptoKit opens the CFRG entry for this suite,
    /// through the same existential the opener uses.
    @Test func cryptoKitOpensTheCFRGVector() throws {
        let vector = HPKEFixtures.cfrg
        #expect(vector["mode"] as? Int == 0)
        #expect(vector["kem_id"] as? Int == 16)
        #expect(vector["kdf_id"] as? Int == 1)
        #expect(vector["aead_id"] as? Int == 2)
        let key: any DeviceAgreementKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex(vector["skRm"]))
        #expect(key.publicKey.x963Representation == hex(vector["pkRm"]))
        var recipient = try HPKE.Recipient(
            privateKey: key, ciphersuite: deviceEnvelopeHPKESuite,
            info: hex(vector["info"]), encapsulatedKey: hex(vector["enc"])
        )
        let encryptions = vector["encryptions"] as! [[String: Any]]  // swiftlint:disable:this force_cast
        #expect(!encryptions.isEmpty)
        for encryption in encryptions {
            #expect(try recipient.open(hex(encryption["ct"]), authenticating: hex(encryption["aad"]))
                == hex(encryption["pt"]))
        }
    }

    @Test func theServerVectorsOpen() throws {
        let key = try HPKEFixtures.deviceKey()
        #expect(key.publicKey.x963Representation == V3Fixtures.data(HPKEFixtures.file["devicePublicKey"]))
        let vectors = HPKEFixtures.entries("vectors")
        #expect(vectors.map { $0["name"] as? String } == ["v4", "v5"])
        for (vector, version) in zip(vectors, [4, 5]) {
            let deviceId = vector["deviceId"] as! String  // swiftlint:disable:this force_cast
            let fingerprint = vector["fingerprint"] as! String  // swiftlint:disable:this force_cast
            let fields = try #require(parseDeviceEnvelope(HPKEFixtures.json(vector)))
            #expect(fields.version == version)
            #expect(try deviceEnvelopeAAD(version: version, deviceId: deviceId, pgpFingerprint: fingerprint)
                == V3Fixtures.data(vector["info"]))
            let opened = try HPKEFixtures.open(
                HPKEFixtures.json(vector), deviceId: deviceId, fingerprint: fingerprint, key: key
            )
            #expect(opened == Data((vector["plaintext"] as! String).utf8))  // swiftlint:disable:this force_cast
        }
    }

    /// Every negative is refused. "framing" ones never reach the key; this
    /// client refuses the off-curve `enc` at framing too, as it does for v3.
    @Test func theServerNegativesAreRefused() throws {
        let key = try HPKEFixtures.deviceKey()
        let negatives = HPKEFixtures.entries("negative")
        #expect(negatives.count == 5)
        for negative in negatives {
            let name = negative["name"] as? String ?? "?"
            let json = HPKEFixtures.json(negative)
            if negative["rejectedBy"] as? String == "framing" {
                #expect(parseDeviceEnvelope(json) == nil, "\(name)")
            }
            #expect(try HPKEFixtures.open(
                json,
                deviceId: negative["deviceId"] as! String,  // swiftlint:disable:this force_cast
                fingerprint: negative["fingerprint"] as! String,  // swiftlint:disable:this force_cast
                key: key
            ) == nil, "\(name)")
        }
    }

    @Test func malformedHPKEFramingIsRejected() throws {
        let vector = HPKEFixtures.entries("vectors")[1]
        func v5(_ edit: (inout [String: Any]) -> Void) -> String {
            var envelope = vector["envelope"] as! [String: Any]  // swiftlint:disable:this force_cast
            edit(&envelope)
            return String(decoding: V3Fixtures.serialize(envelope), as: UTF8.self)
        }
        #expect(parseDeviceEnvelope(v5 { _ in }) != nil, "control")
        #expect(parseDeviceEnvelope(v5 { $0["v"] = "5" }) == nil, "a quoted 5")
        #expect(parseDeviceEnvelope(v5 { $0["v"] = 6 }) == nil)
        #expect(parseDeviceEnvelope(v5 { $0["iv"] = "AAECAwQFBgcICQoL" }) == nil, "exactly four fields")
        #expect(parseDeviceEnvelope(v5 { $0["epk"] = $0["enc"]; $0["enc"] = nil }) == nil)
        #expect(parseDeviceEnvelope(v5 {
            $0["enc"] = (($0["enc"] as? String) ?? "").replacingOccurrences(of: "=", with: "")
        }) == nil, "unpadded base64")
        #expect(parseDeviceEnvelope(v5 {
            $0["enc"] = Data([0x02] + Array(repeating: UInt8(1), count: 32)).base64EncodedString()
        }) == nil, "a compressed point")
        #expect(parseDeviceEnvelope(v5 {
            $0["ct"] = Data(repeating: 1, count: 16).base64EncodedString()
        }) == nil, "a ciphertext that is only a tag")
        let huge = String(repeating: "A", count: maxDeviceEnvelopeV3Bytes)
        #expect(parseDeviceEnvelope(v5 { $0["ct"] = huge }) == nil, "over the 128 KiB bound")
    }

    @Test func theHPKEAadIsStrict() {
        #expect(throws: DeviceEnvelopeError.emptyDeviceId) {
            try deviceEnvelopeAAD(version: 4, deviceId: "", pgpFingerprint: V3Fixtures.active)
        }
        #expect(throws: DeviceEnvelopeError.malformedFingerprint) {
            try deviceEnvelopeAAD(version: 5, deviceId: "d", pgpFingerprint: "ABCD")
        }
        for retired in [2, 3, 6] {
            #expect(throws: DeviceEnvelopeError.unsupportedVersion) {
                try deviceEnvelopeAAD(version: retired, deviceId: "d", pgpFingerprint: V3Fixtures.active)
            }
        }
    }
}

// MARK: - The opener, end to end

@Suite(.serialized) struct HPKEOpenAndStoreTests {
    private func sealer(_ store: MemoryItemStore) throws -> (VaultSealer, EnrollmentVault, P256.KeyAgreement.PublicKey) {
        let vault = hpkeVault(store)
        let key = try DeviceKeyStore(keychain: store, minting: SoftwareKeyMinting()).loadOrCreate()
        #expect(try vault.rawPublicKey() == key.publicKey.x963Representation)
        let sealer = VaultSealer(vault: vault, deviceId: "dev", inspector: GopenPGPCrypto(), session: EnrollmentSession())
        return (sealer, vault, key.publicKey)
    }

    private var v5Delivery: DeliveryMetadata {
        var delivery = V3Fixtures.delivery
        delivery.version = 5
        return delivery
    }

    /// v5 opens, is sealed at rest, and is acknowledged as v5 — now and when
    /// restated from the stored header.
    @Test func aV5KeyringIsStoredAndAcknowledgedAsV5() async throws {
        let store = MemoryItemStore()
        let (sealer, vault, publicKey) = try sealer(store)
        let json = try sealHPKE(version: 5, plaintext: V3Fixtures.ringBytes, to: publicKey)
        let report = try await sealer.openAndStore(
            envelopeJSON: json, identityFingerprint: V3Fixtures.active, delivery: v5Delivery
        )
        #expect(report == .keyring(materialGeneration: 2, fingerprint: V3Fixtures.active, envelopeVersion: 5))
        #expect(vault.keyringAcknowledgement()?.envelopeVersion == 5)
        let raw = try #require(try store.data(forKey: "enrollment.vaultRecord"))
        #expect(VaultRecord.parse(raw)?.format == VaultRecord.sealedFormat)
        #expect(raw.range(of: V3Fixtures.ringBytes) == nil)
        #expect(try vault.openRecord()?.material == V3Fixtures.ringBytes)
    }

    @Test func aV4KeyOpens() async throws {
        let (sealer, _, publicKey) = try sealer(MemoryItemStore())
        let json = try sealHPKE(version: 4, plaintext: Data(V3Fixtures.memberArmor(0).utf8), to: publicKey)
        let report = try await sealer.openAndStore(
            envelopeJSON: json, identityFingerprint: V3Fixtures.active,
            delivery: DeliveryMetadata(version: 4, fingerprint: V3Fixtures.active)
        )
        #expect(report == .legacy)
    }

    /// v2/v3 are retired: a fresh delivery of either is refused before the
    /// device key is used, and nothing is stored.
    @Test func freshV2AndV3DeliveriesAreRefused() async throws {
        let store = MemoryItemStore()
        let (sealer, _, publicKey) = try sealer(store)
        let v2 = try sealLegacy(version: 2, plaintext: Data(V3Fixtures.memberArmor(0).utf8), to: publicKey)
        await #expect(throws: EnrollmentSealerError.unsupportedEnvelopeVersion) {
            try await sealer.openAndStore(
                envelopeJSON: v2, identityFingerprint: V3Fixtures.active,
                delivery: DeliveryMetadata(version: 2, fingerprint: V3Fixtures.active)
            )
        }
        let v3 = try sealLegacy(version: 3, plaintext: V3Fixtures.ringBytes, to: publicKey)
        await #expect(throws: EnrollmentSealerError.unsupportedEnvelopeVersion) {
            try await sealer.openAndStore(
                envelopeJSON: v3, identityFingerprint: V3Fixtures.active, delivery: V3Fixtures.delivery
            )
        }
        #expect(try store.data(forKey: "enrollment.vaultRecord") == nil)
    }

    /// No delivery metadata means a server older than v4/v5. Refused whatever
    /// the envelope is; there is no old-server v2 path.
    @Test func aDeliveryWithoutMetadataIsRefused() async throws {
        let store = MemoryItemStore()
        let (sealer, _, publicKey) = try sealer(store)
        let armor = Data(V3Fixtures.memberArmor(0).utf8)
        let v2 = try sealLegacy(version: 2, plaintext: armor, to: publicKey)
        let v4 = try sealHPKE(version: 4, plaintext: armor, to: publicKey)
        for json in [v2, v4] {
            await #expect(throws: EnrollmentSealerError.unsupportedEnvelopeVersion) {
                try await sealer.openAndStore(
                    envelopeJSON: json, identityFingerprint: V3Fixtures.active, delivery: nil
                )
            }
        }
        #expect(try store.data(forKey: "enrollment.vaultRecord") == nil)
    }

    /// Opened only as the version the server recorded delivering.
    @Test func aVersionTheDeliveryDoesNotNameIsNotOpened() async throws {
        let store = MemoryItemStore()
        let (sealer, _, publicKey) = try sealer(store)
        let v5 = try sealHPKE(version: 5, plaintext: V3Fixtures.ringBytes, to: publicKey)
        await #expect(throws: EnrollmentSealerError.envelopeMalformed) {
            try await sealer.openAndStore(
                envelopeJSON: v5, identityFingerprint: V3Fixtures.active,
                delivery: DeliveryMetadata(version: 4, fingerprint: V3Fixtures.active)
            )
        }
        let v4 = try sealHPKE(version: 4, plaintext: Data(V3Fixtures.memberArmor(0).utf8), to: publicKey)
        await #expect(throws: EnrollmentSealerError.envelopeMalformed) {
            try await sealer.openAndStore(
                envelopeJSON: v4, identityFingerprint: V3Fixtures.active, delivery: v5Delivery
            )
        }
        #expect(try store.data(forKey: "enrollment.vaultRecord") == nil)
    }

    @Test func anEnvelopeForAnotherDeviceIsRejected() async throws {
        let (sealer, _, publicKey) = try sealer(MemoryItemStore())
        let json = try sealHPKE(version: 5, plaintext: V3Fixtures.ringBytes, to: publicKey, deviceId: "other")
        await #expect(throws: EnrollmentSealerError.envelopeRejected) {
            try await sealer.openAndStore(
                envelopeJSON: json, identityFingerprint: V3Fixtures.active, delivery: v5Delivery
            )
        }
    }

    /// An identical ring redelivered as v5 is rewritten, so a restated
    /// acknowledgement names v5; as v3 it stays a replay.
    @Test func aRedeliveryUnderAnotherVersionIsRewritten() {
        func decide(_ version: Int) -> VaultImportDecision {
            var delivery = V3Fixtures.delivery
            delivery.version = version
            return decideVaultImport(
                version: version, plaintext: V3Fixtures.ringBytes, identityFingerprint: V3Fixtures.active,
                delivery: delivery, previous: ring, inspector: GopenPGPCrypto()
            )
        }
        guard case .replay = decide(3) else { Issue.record("expected replay"); return }
        guard case .store(let record, _, _) = decide(5) else { Issue.record("expected store"); return }
        #expect(record.envelopeVersion == 5)
    }
}

// MARK: - Vault migration

/// Each state the device can be found in, including after a crash at any
/// step: the legacy key goes only after the new item is on disk.
@Suite(.serialized) struct DeviceKeyMigrationTests {
    private let item = "enrollment.vaultRecord"

    /// A format 2 item, as an earlier build wrote it.
    private func legacyItem(_ legacy: FakeKeySealing, _ record: VaultRecord = ring) throws -> Data {
        VaultRecord.encode(record.header, format: VaultRecord.legacySealedFormat, tail: try legacy.seal(record.encoded()))
    }

    private func format(_ store: MemoryItemStore) throws -> UInt8? {
        VaultRecord.parse(try #require(try store.data(forKey: item)))?.format
    }

    @Test func aFreshInstallSealsWithHPKEToTheDeviceKey() throws {
        let store = MemoryItemStore()
        let vault = hpkeVault(store)
        #expect(try vault.openRecord() == nil)
        try vault.store(ring)
        #expect(try store.data(forKey: DeviceKeyStore.item) != nil, "minted on first seal")
        #expect(try format(store) == VaultRecord.sealedFormat)
        #expect(try store.data(forKey: item)?.range(of: V3Fixtures.ringBytes) == nil)
        #expect(try vault.openRecord()?.material == ring.material)
    }

    @Test func anOldOnlyInstallIsResealedThenTheLegacyKeyGoes() throws {
        let store = MemoryItemStore()
        let legacy = FakeKeySealing()
        try store.setData(try legacyItem(legacy), forKey: item)
        let vault = hpkeVault(store, legacyKey: legacy)
        #expect(try vault.storedHeader() == ring.header, "the header reads without a prompt")

        #expect(try vault.openRecord()?.material == ring.material)
        #expect(try format(store) == VaultRecord.sealedFormat)
        #expect(!legacy.exists)
        #expect(vault.keyringAcknowledgement()?.envelopeVersion == 3, "only v3 existed before")
        #expect(try vault.openRecord()?.material == ring.material, "opens with the new key alone")
    }

    /// Crashed after the write, before the delete: the next open finishes.
    @Test func bothPresentMidMigrationRetiresTheLegacyKey() throws {
        let store = MemoryItemStore()
        let legacy = FakeKeySealing()
        let vault = hpkeVault(store, legacyKey: legacy)
        try vault.store(ring)
        #expect(legacy.exists)
        #expect(try vault.openRecord()?.material == ring.material)
        #expect(!legacy.exists)
    }

    /// A re-seal that does not open is never written; the record still opens
    /// and the next open resumes.
    @Test func aReSealThatDoesNotOpenKeepsTheLegacyItemAndKey() throws {
        let store = MemoryItemStore()
        let legacy = FakeKeySealing()
        let sealing = FakeKeySealing()
        let original = try legacyItem(legacy)
        try store.setData(original, forKey: item)
        let vault = testVault(store, sealing: sealing, legacyKey: legacy)

        sealing.failOpens = true
        #expect(try vault.openRecord() == ring)
        #expect(try store.data(forKey: item) == original)
        #expect(legacy.exists)

        sealing.failOpens = false
        #expect(try vault.openRecord() == ring)
        #expect(try format(store) == VaultRecord.sealedFormat)
        #expect(!legacy.exists)
    }

    @Test func aFailedWriteKeepsTheLegacyItemAndKey() throws {
        let store = MemoryItemStore()
        let legacy = FakeKeySealing()
        let original = try legacyItem(legacy)
        try store.setData(original, forKey: item)
        let vault = testVault(store, legacyKey: legacy)
        store.failWrites = true
        #expect(try vault.openRecord() == ring)
        #expect(try store.data(forKey: item) == original)
        #expect(legacy.exists)
    }

    @Test func aCancelledLegacyPromptChangesNothing() throws {
        let store = MemoryItemStore()
        let legacy = FakeKeySealing()
        let original = try legacyItem(legacy)
        try store.setData(original, forKey: item)
        let vault = testVault(store, legacyKey: legacy)
        legacy.cancelPrompts = true
        #expect(throws: EnrollmentVaultError.cancelled) { try vault.openRecord() }
        #expect(try store.data(forKey: item) == original)
        #expect(legacy.exists)
    }

    @Test func aNewOnlyInstallOpensWithoutTheLegacyKey() throws {
        let store = MemoryItemStore()
        let legacy = FakeKeySealing()
        try legacy.delete()
        let vault = hpkeVault(store, legacyKey: legacy)
        try vault.store(ring)
        #expect(try vault.openRecord()?.material == ring.material)
    }

    @Test func destroyDeletesBothKeys() throws {
        let store = MemoryItemStore()
        let legacy = FakeKeySealing()
        let vault = hpkeVault(store, legacyKey: legacy)
        try vault.store(ring)
        #expect(vault.destroyReportingFailures().isEmpty)
        #expect(try store.data(forKey: DeviceKeyStore.item) == nil)
        #expect(!legacy.exists)
        #expect(!vault.isEnrolled)
    }

    /// The envelope version rides in the clear header and survives the seal.
    @Test func theEnvelopeVersionIsKeptWithTheRecord() throws {
        let store = MemoryItemStore()
        let vault = hpkeVault(store)
        var v5 = ring
        v5.envelopeVersion = 5
        try vault.store(v5)
        #expect(try vault.storedHeader()?.envelopeVersion == 5)
        #expect(vault.keyringAcknowledgement()?.envelopeVersion == 5)
        #expect(try vault.openRecord() == v5)
    }
}
