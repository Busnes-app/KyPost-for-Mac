// Spec A P2/P3. XCTest exercises the same gomobile seam the shipping app uses.
import CryptoKit
import Foundation
import LocalAuthentication
import XCTest
@testable import KyPost

@MainActor
final class SpecAPqcTests: XCTestCase {
    private func vector() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PqcFixtures.enrollment.utf8)) as? [String: Any])
    }

    private func bytes(_ value: Any?) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(value as? String)))
    }

    private func serialized(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
    }

    func testSASV2MatchesServerAndHashesEveryKeyByte() throws {
        let v = try vector()
        let key = try bytes(v["publicKey"])
        let expected = try XCTUnwrap(v["sas"] as? String)
        XCTAssertEqual(deviceEnrollmentCode(rawPublicKey: key, deviceId: "test-device", bucket: 14_000_000), expected)
        XCTAssertEqual(formattedEnrollmentCode(expected), "2M6T-QPX-9V8F-80T")
        for offset in key.indices {
            var changed = key
            changed[offset] ^= 1
            XCTAssertNotEqual(deviceEnrollmentCode(rawPublicKey: changed, deviceId: "test-device", bucket: 14_000_000), expected)
        }
        XCTAssertNotEqual(deviceEnrollmentCode(rawPublicKey: key, deviceId: "other", bucket: 14_000_000), expected)
        XCTAssertNotEqual(deviceEnrollmentCode(rawPublicKey: key, deviceId: "test-device", bucket: 14_000_001), expected)
    }

    func testSASV1RemainsByteIdentical() {
        let key = Data([4] + Array(repeating: UInt8(1), count: 32) + Array(repeating: UInt8(2), count: 32))
        XCTAssertEqual(deviceEnrollmentCode(rawPublicKey: key, deviceId: "test-device", bucket: 14_000_000), "5R9K6FWA18A8YP")
    }

    func testServerAndBrowserV6EnvelopesOpenThroughBridge() throws {
        let v = try vector()
        let seed = try bytes(v["seed"])
        let publicKey = try bytes(v["publicKey"])
        XCTAssertEqual(try XWingCrypto.publicKey(seed: seed), publicKey)
        XCTAssertTrue(XWingCrypto.isValidPublicKey(publicKey))
        let info = try deviceEnvelopeAAD(version: 6, deviceId: "test-device", pgpFingerprint: try XCTUnwrap(v["fingerprint"] as? String))
        for envelope in [try serialized(try XCTUnwrap(v["envelope"])), PqcFixtures.browserEnvelope] {
            let fields = try XCTUnwrap(parseDeviceEnvelope(envelope))
            let sealed = Data([1]) + fields.epk + fields.ct
            XCTAssertEqual(XWingCrypto.open(seed: seed, info: info, sealed: sealed), Data("public test enrollment payload".utf8))
            XCTAssertNil(XWingCrypto.open(seed: seed, info: info + Data([0]), sealed: sealed))
            var changed = sealed
            changed[changed.count - 1] ^= 1
            XCTAssertNil(XWingCrypto.open(seed: seed, info: info, sealed: changed))
            // Independent Apple implementation proves seed and HPKE interop.
            let nativeKey = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: seed, publicKey: nil)
            var native = try HPKE.Recipient(privateKey: nativeKey,
                ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256, info: info, encapsulatedKey: fields.epk)
            XCTAssertEqual(try native.open(fields.ct), Data("public test enrollment payload".utf8))
        }
    }

    func testV6FramingRejectsWrongSizesSuiteDuplicatesAndVersions() throws {
        let v = try vector()
        let envelope = try XCTUnwrap(v["envelope"] as? [String: Any])
        for size in [0, 65, 1119, 1121] {
            var bad = envelope
            bad["enc"] = Data(repeating: 1, count: size).base64EncodedString()
            XCTAssertNil(parseDeviceEnvelope(try serialized(bad)))
        }
        for (key, value) in [("v", 5 as Any), ("v", "6" as Any), ("v", true as Any), ("alg", "HPKE-Base-P256-SHA256-A256GCM" as Any)] {
            var bad = envelope; bad[key] = value
            XCTAssertNil(parseDeviceEnvelope(try serialized(bad)))
        }
        let json = try serialized(envelope)
        XCTAssertNil(parseDeviceEnvelope("{\"v\":6," + json.dropFirst()))
        XCTAssertNil(parseDeviceEnvelope(json + String(repeating: " ", count: maxDeviceEnvelopeV3Bytes)))
        XCTAssertEqual(enrollmentVersions(for: try bytes(v["publicKey"])), [6])
        XCTAssertEqual(enrollmentVersions(for: Data(repeating: 0, count: 65)), [4, 5])
    }

    func testV6DecryptCompositeVerifyAndV4ReadCompatibility() throws {
        let crypto = GopenPGPCrypto()
        for (key, message) in [(PqcFixtures.pqPrivate, PqcFixtures.pqMessage), (PqcFixtures.v4Private, PqcFixtures.v4Message)] {
            let opened = try crypto.decrypt(armoredCiphertext: message, privateKeys: [Data(key.utf8)], signerKeys: [])
            XCTAssertEqual(opened.body, Data(PqcFixtures.message.utf8))
            XCTAssertNotNil(crypto.inspectPrivateKey(armored: Data(key.utf8)))
        }
        let signature = crypto.verifyDetached(signedBytes: Data(PqcFixtures.message.utf8), armoredSignature: PqcFixtures.pqSignature, signerKeys: [PqcFixtures.pqPublic])
        XCTAssertTrue(signature.present)
        XCTAssertTrue(signature.valid)
        XCTAssertEqual(signature.signerFingerprint.uppercased(), PgpFingerprint.compute(fromArmored: PqcFixtures.pqPublic))
        XCTAssertFalse(crypto.verifyDetached(signedBytes: Data("changed".utf8), armoredSignature: PqcFixtures.pqSignature, signerKeys: [PqcFixtures.pqPublic]).valid)
        XCTAssertFalse(crypto.verifyDetached(signedBytes: Data(PqcFixtures.message.utf8), armoredSignature: PqcFixtures.pqSignature, signerKeys: [PqcFixtures.v4Public]).valid)
        for key in [PqcFixtures.v4Public, PqcFixtures.v6Public, PqcFixtures.pqPublic] {
            XCTAssertFalse(crypto.userIDAddresses(ofArmoredPublicKey: key).isEmpty)
        }
    }

    private func ringV2() throws -> (Data, String, String) {
        let crypto = GopenPGPCrypto()
        let v4 = try XCTUnwrap(crypto.inspectPrivateKey(armored: Data(PqcFixtures.v4Private.utf8)))
        let v6 = try XCTUnwrap(crypto.inspectPrivateKey(armored: Data(PqcFixtures.pqPrivate.utf8)))
        let object: [String: Any] = [
            "format": "kypost-pgp-keyring-v2", "materialGeneration": 2,
            "active": ["v4": v4.primaryFingerprint, "v6": v6.primaryFingerprint],
            "keyFingerprints": v4.keyFingerprints + v6.keyFingerprints,
            "keys": [["fingerprint": v4.primaryFingerprint, "privateKey": PqcFixtures.v4Private],
                     ["fingerprint": v6.primaryFingerprint, "privateKey": PqcFixtures.pqPrivate]],
        ]
        return (Data(try serialized(object).utf8), v4.primaryFingerprint, v6.primaryFingerprint)
    }

    func testV2RingKeepsBothActiveKeysAndV4Sending() throws {
        let (data, v4, v6) = try ringV2()
        let crypto = GopenPGPCrypto()
        let ring = try XCTUnwrap(parsePgpKeyring(data, expectedActiveFingerprint: v6, inspector: crypto))
        XCTAssertEqual(ring.activeFingerprint, v4)
        XCTAssertEqual(ring.activeV6Fingerprint, v6)
        XCTAssertEqual(ring.members.count, 2)
        let session = EnrollmentSession()
        session.put(keyring: ring)
        try session.withMaterial { material in
            let held = try XCTUnwrap(material)
            XCTAssertEqual(held.decryptionKeys.count, 2)
            XCTAssertEqual(held.signingKey, Data(PqcFixtures.v4Private.utf8))
        }
        XCTAssertNotNil(parsePgpKeyring(data, expectedActiveFingerprint: v4, inspector: crypto))
        XCTAssertNil(parsePgpKeyring(data, expectedActiveFingerprint: V3Fixtures.historical, inspector: crypto))
        var bad = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        bad["active"] = ["v4": v6, "v6": v4]
        XCTAssertNil(reopenPgpKeyring(Data(try serialized(bad).utf8), inspector: crypto))
    }

    func testV6ImportRequiresMatchingGenerationAndPreservesHistory() throws {
        let (data, v4, v6) = try ringV2()
        let crypto = GopenPGPCrypto()
        let ring = try XCTUnwrap(reopenPgpKeyring(data, inspector: crypto))
        var delivery = DeliveryMetadata(version: 6, fingerprint: v6, materialGeneration: 2,
            primaryFingerprints: Array(ring.primaryFingerprints), keyFingerprints: Array(ring.keyFingerprints))
        let previous = VaultRecord(kind: .legacyArmor, material: Data(PqcFixtures.v4Private.utf8), identityFingerprint: v4)
        let decision = decideVaultImport(version: 6, plaintext: data, identityFingerprint: v6,
            delivery: delivery, previous: previous, inspector: crypto)
        guard case let .store(record, _, report) = decision else { return XCTFail("complete superset refused") }
        XCTAssertEqual(record.identityFingerprint, v6)
        XCTAssertEqual(report, .keyring(materialGeneration: 2, fingerprint: v6, envelopeVersion: 6))
        delivery.materialGeneration = 3
        XCTAssertEqual(decideVaultImport(version: 6, plaintext: data, identityFingerprint: v6,
            delivery: delivery, previous: previous, inspector: crypto), .invalidRing)
        let legacy = decideVaultImport(version: 6, plaintext: Data(PqcFixtures.v4Private.utf8), identityFingerprint: v4,
            delivery: DeliveryMetadata(version: 6, fingerprint: v4, materialGeneration: 0), previous: nil, inspector: crypto)
        guard case .store(_, _, .legacy) = legacy else { return XCTFail("v6 legacy armor refused") }
    }

    func test64HexQrRoundTripAndInvalidFingerprints() throws {
        let fp = try XCTUnwrap(PgpFingerprint.compute(fromArmored: PqcFixtures.pqPublic))
        XCTAssertEqual(fp.count, 64)
        let url = "https://relay.example/api/pgp/qr/key?t=test"
        let payload = try XCTUnwrap(PgpQrClient.qrPayload(pickupURL: url, fingerprint: fp))
        let parsed = try XCTUnwrap(PgpQrClient.scannedKeyCode(fromPayload: payload))
        XCTAssertEqual(parsed.shownFingerprint, .fingerprint(fp))
        XCTAssertNil(parsed.url.fragment)
        for bad in [String(fp.dropLast()), fp + "A", fp.lowercased(), String(repeating: "G", count: 64)] {
            XCTAssertFalse(PgpQrClient.isFingerprint(bad))
        }
    }

    func testCapabilityReportKeepsAcknowledgementMetadata() throws {
        let request = EnrollmentStateRequest(.keyring(materialGeneration: 7, fingerprint: V3Fixtures.active, envelopeVersion: 6))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["openpgp"] as? [String], ["v4", "v6", "rfc9980"])
        XCTAssertEqual(object["materialGeneration"] as? Int, 7)
        XCTAssertEqual(object["envelopeVersion"] as? Int, 6)
        XCTAssertEqual(maxPgpKeyringBytes, 512 * 1024)
        XCTAssertEqual(maxDeviceEnvelopeV3Bytes, 768 * 1024)
    }

    func testNearLimitKeyringV6EnvelopeRoundTrip() throws {
        let (baseRing, _, v6) = try ringV2()
        XCTAssertLessThan(baseRing.count, maxPgpKeyringBytes)
        let maxRing = baseRing + Data(repeating: 0x20, count: maxPgpKeyringBytes - baseRing.count)
        XCTAssertEqual(maxRing.count, maxPgpKeyringBytes)

        let seed = try XWingCrypto.generateSeed()
        let publicKey = try XWingCrypto.publicKey(seed: seed)
        let info = try deviceEnvelopeAAD(version: 6, deviceId: "test-device", pgpFingerprint: v6)
        let sealed = try XWingCrypto.seal(publicKey: publicKey, info: info, plaintext: maxRing)
        XCTAssertEqual(sealed.first, 1)
        XCTAssertGreaterThan(sealed.count, 1 + 1120)

        let enc = sealed.subdata(in: 1 ..< 1121)
        let ct = sealed.subdata(in: 1121 ..< sealed.count)
        let envelope = try serialized([
            "v": 6,
            "alg": "HPKE-Base-XWing-SHA256-A256GCM",
            "enc": enc.base64EncodedString(),
            "ct": ct.base64EncodedString(),
        ])
        XCTAssertGreaterThan(envelope.utf8.count, maxPgpKeyringBytes)
        XCTAssertLessThanOrEqual(envelope.utf8.count, maxDeviceEnvelopeV3Bytes)

        let fields = try XCTUnwrap(parseDeviceEnvelope(envelope))
        XCTAssertEqual(fields.version, 6)
        let opened = try XCTUnwrap(XWingCrypto.open(seed: seed, info: info, sealed: Data([1]) + fields.epk + fields.ct))
        XCTAssertEqual(opened, maxRing)
        let reopened = try XCTUnwrap(reopenPgpKeyring(opened, inspector: GopenPGPCrypto()))
        XCTAssertEqual(reopened.activeV6Fingerprint, v6)
    }
}

/// No Keychain or system prompt in the tests; production's only implementation
/// reads the gated seed through Security.framework.
private nonisolated struct TestXWingKeys: XWingKeyStoring {
    let seed: Data
    var cancelled = false
    func publicKey() throws -> Data { try XWingCrypto.publicKey(seed: seed) }
    func withSeed<T>(context: LAContext, _ body: (Data) throws -> T) throws -> T {
        if cancelled { throw EnrollmentVaultError.cancelled }
        return try body(seed)
    }
    func delete() throws {}
}

extension SpecAPqcTests {
    func testXWingVaultMigratesP256AndRejectsTampering() throws {
        let store = MemoryItemStore()
        let legacyVault = EnrollmentVault(keychain: store, keyMinting: SoftwareKeyMinting(), presence: PresenceContext())
        let record = VaultRecord(kind: .legacyArmor, material: Data(PqcFixtures.v4Private.utf8), identityFingerprint: V3Fixtures.active)
        try legacyVault.store(record)
        let old = try XCTUnwrap(store.data(forKey: "enrollment.vaultRecord"))
        let keys = TestXWingKeys(seed: Data(repeating: 101, count: 32))
        let vault = EnrollmentVault(keychain: store, keyMinting: SoftwareKeyMinting(), xwingKeys: keys, presence: PresenceContext())
        XCTAssertEqual(try vault.openRecord(), record)
        let migrated = try XCTUnwrap(store.data(forKey: "enrollment.vaultRecord"))
        XCTAssertNotEqual(migrated, old)
        XCTAssertTrue(try XCTUnwrap(VaultRecord.parse(migrated)).tail.starts(with: XWingKeySealing.marker))
        XCTAssertEqual(try vault.openRecord(), record)
        var changed = migrated
        changed[changed.count - 1] ^= 1
        try store.setData(changed, forKey: "enrollment.vaultRecord")
        XCTAssertThrowsError(try vault.openRecord())
    }

    func testV6CancelledOpenNeverReplacesPreviousRecord() async throws {
        let store = MemoryItemStore()
        let vault = EnrollmentVault(keychain: store, keyMinting: SoftwareKeyMinting(),
            xwingKeys: TestXWingKeys(seed: Data(repeating: 101, count: 32), cancelled: true), presence: PresenceContext())
        let previous = VaultRecord(kind: .legacyArmor, material: Data(PqcFixtures.v4Private.utf8), identityFingerprint: V3Fixtures.active)
        try vault.store(previous)
        let before = try store.data(forKey: "enrollment.vaultRecord")
        let v = try vector()
        let sealer = VaultSealer(vault: vault, deviceId: "test-device", inspector: GopenPGPCrypto(), session: EnrollmentSession())
        do {
            _ = try await sealer.openAndStore(envelopeJSON: serialized(try XCTUnwrap(v["envelope"])),
                identityFingerprint: try XCTUnwrap(v["fingerprint"] as? String),
                delivery: DeliveryMetadata(version: 6, fingerprint: try XCTUnwrap(v["fingerprint"] as? String), materialGeneration: 0))
            XCTFail("cancelled seed read accepted")
        } catch {
            XCTAssertEqual(error as? EnrollmentVaultError, .cancelled)
        }
        XCTAssertEqual(try store.data(forKey: "enrollment.vaultRecord"), before)
    }
}

extension SpecAPqcTests {
    func testV6EnrollmentStoresAndAcknowledgesExactRing() async throws {
        let (data, _, v6) = try ringV2()
        let crypto = GopenPGPCrypto()
        let ring = try XCTUnwrap(reopenPgpKeyring(data, inspector: crypto))
        let keys = TestXWingKeys(seed: Data(repeating: 101, count: 32))
        let store = MemoryItemStore()
        let vault = EnrollmentVault(keychain: store, keyMinting: SoftwareKeyMinting(), xwingKeys: keys, presence: PresenceContext())
        let session = EnrollmentSession()
        let sealer = VaultSealer(vault: vault, deviceId: "device", inspector: crypto, session: session)
        let info = try deviceEnvelopeAAD(version: 6, deviceId: "device", pgpFingerprint: v6)
        let sealed = try XWingCrypto.seal(publicKey: keys.publicKey(), info: info, plaintext: data)
        let json = try serialized(["v": 6, "alg": "HPKE-Base-XWing-SHA256-A256GCM",
            "enc": Data(sealed[1..<1121]).base64EncodedString(), "ct": Data(sealed.dropFirst(1121)).base64EncodedString()])
        let delivery = DeliveryMetadata(version: 6, fingerprint: v6, materialGeneration: 2,
            primaryFingerprints: Array(ring.primaryFingerprints), keyFingerprints: Array(ring.keyFingerprints))
        let report = try await sealer.openAndStore(envelopeJSON: json, identityFingerprint: v6, delivery: delivery)
        XCTAssertEqual(report, .keyring(materialGeneration: 2, fingerprint: v6, envelopeVersion: 6))
        XCTAssertEqual(try vault.openRecord()?.material, data)
        XCTAssertTrue(session.holdsKeyring(identicalTo: data))
    }
}
