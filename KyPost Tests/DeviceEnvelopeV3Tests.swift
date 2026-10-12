//
//  DeviceEnvelopeV3Tests.swift
//  KyPost Tests
//
//  Device-envelope v3 and the complete keyring. Mirrors kypost-android's
//  DeviceEnvelopeTest, PgpKeyringTest, KeyringImportTest,
//  EnrollmentCeremonyKeyringTest, EnrollmentReportOutcomeTest and
//  EnrollmentStatusTest, against KyPost-Server's shared vectors.
//

import CryptoKit
import Foundation
import Security
import Testing
@testable import KyPost

// MARK: - Fixture access

enum V3Fixtures {
    static func json(_ text: String) -> [String: Any] {
        // swiftlint:disable:next force_try force_cast
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    static var envelopeFile: [String: Any] { json(ServerPgpFixtures.deviceEnvelopeV3) }
    static var keyringFile: [String: Any] { json(ServerPgpFixtures.keyringV1) }

    static func vector(_ index: Int) -> [String: Any] {
        // swiftlint:disable:next force_cast
        (envelopeFile["vectors"] as! [[String: Any]])[index]
    }

    static func data(_ base64: Any?) -> Data {
        Data(base64Encoded: base64 as! String)!  // swiftlint:disable:this force_cast
    }

    /// The exact ring bytes the v3 vector seals.
    static var ringBytes: Data {
        Data((vector(1)["plaintext"] as! String).utf8)  // swiftlint:disable:this force_cast
    }

    static var ringObject: [String: Any] { json(String(decoding: ringBytes, as: UTF8.self)) }
    static let active = "5F117951610CAF01500FA059CDE63F0EBEC934A2"
    static let historical = "3DA91B24C0BFAB595BEFE10D85ED094DCCE10615"
    static let activeSubkey = "F8FF743DD85DDE3D427E8BA25CA9134FFE0FF9F4"

    /// The active member's own fingerprints, from its packets.
    static var activeInventory: [String] {
        GopenPGPCrypto().inspectPrivateKey(armored: Data(memberArmor(0).utf8))?.keyFingerprints ?? []
    }

    static func memberArmor(_ index: Int) -> String {
        let keys = ringObject["keys"] as! [[String: Any]]  // swiftlint:disable:this force_cast
        return keys[index]["privateKey"] as! String  // swiftlint:disable:this force_cast
    }

    static func serialize(_ object: [String: Any]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    static func edited(_ edit: (inout [String: Any]) -> Void) -> Data {
        var object = ringObject
        edit(&object)
        return serialize(object)
    }

    static func editedMember(_ index: Int, _ edit: (inout [String: Any]) -> Void) -> Data {
        edited { ring in
            var keys = ring["keys"] as! [[String: Any]]  // swiftlint:disable:this force_cast
            edit(&keys[index])
            ring["keys"] = keys
        }
    }

    static var delivery: DeliveryMetadata {
        let ring = ringObject
        return DeliveryMetadata(
            version: 3,
            fingerprint: active,
            materialGeneration: 2,
            primaryFingerprints: [active, historical],
            keyFingerprints: ring["keyFingerprints"] as? [String]
        )
    }

    static func armorPrivate(_ binary: Data) -> String {
        "-----BEGIN PGP PRIVATE KEY BLOCK-----\n\n"
            + binary.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            + "\n-----END PGP PRIVATE KEY BLOCK-----\n"
    }
}

private let crypto = GopenPGPCrypto()

@Suite struct ServerFixtureProvenanceTests {
    /// The fixtures are the server's bytes, unchanged; an edit fails here.
    @Test func theSharedFixturesAreTheServersBytes() {
        func sha256(_ text: String) -> String {
            SHA256.hash(data: Data((text + "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        }
        #expect(sha256(ServerPgpFixtures.deviceEnvelopeV3) == ServerPgpFixtures.deviceEnvelopeV3SHA256)
        #expect(sha256(ServerPgpFixtures.keyringV1) == ServerPgpFixtures.keyringV1SHA256)
    }
}

// MARK: - Framing

@Suite struct DeviceEnvelopeV3FramingTests {
    private func envelopeJSON(_ vector: [String: Any]) -> String {
        String(decoding: V3Fixtures.serialize(vector["envelope"] as! [String: Any]), as: UTF8.self)  // swiftlint:disable:this force_cast
    }

    /// Opens a shared vector end to end: the fixed device scalar, ECDH, the
    /// HKDF salt and domain, the AAD bytes, and GCM.
    private func open(_ index: Int) throws -> (opened: Data?, expected: Data, version: Int?) {
        let vector = V3Fixtures.vector(index)
        let file = V3Fixtures.envelopeFile
        let deviceKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: V3Fixtures.data(file["devicePrivateKey"])
        )
        #expect(deviceKey.publicKey.x963Representation == V3Fixtures.data(file["devicePublicKey"]))

        let fields = try #require(parseDeviceEnvelope(envelopeJSON(vector)))
        let secret = try deviceKey.sharedSecretFromKeyAgreement(
            with: P256.KeyAgreement.PublicKey(x963Representation: fields.epk)
        )
        #expect(secret.withUnsafeBytes { Data($0) } == V3Fixtures.data(vector["sharedSecret"]))

        let aad = try deviceEnvelopeAAD(
            version: fields.version,
            deviceId: vector["deviceId"] as! String,  // swiftlint:disable:this force_cast
            pgpFingerprint: vector["fingerprint"] as! String  // swiftlint:disable:this force_cast
        )
        #expect(aad == V3Fixtures.data(vector["aad"]))

        let opened = openDeviceEnvelope(
            sharedSecret: secret,
            ownRawPublicKey: deviceKey.publicKey.x963Representation,
            fields: fields,
            aad: aad
        )
        return (opened, Data((vector["plaintext"] as! String).utf8), fields.version)  // swiftlint:disable:this force_cast
    }

    @Test func theV2VectorStillOpens() throws {
        let result = try open(0)
        #expect(result.version == 2)
        #expect(result.opened == result.expected)
    }

    /// Includes the multibyte, pipe-carrying device id the AAD length-prefixes.
    @Test func theV3VectorOpens() throws {
        let result = try open(1)
        #expect(result.version == 3)
        #expect(result.opened == result.expected)
    }

    /// The domain comes from the parsed version: a v3 envelope is never
    /// reopened as v2, so a downgrade cannot get it past a v2-only check.
    @Test func aV3EnvelopeNeverOpensUnderTheV2Domain() throws {
        let vector = V3Fixtures.vector(1)
        let file = V3Fixtures.envelopeFile
        let deviceKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: V3Fixtures.data(file["devicePrivateKey"])
        )
        var fields = try #require(parseDeviceEnvelope(envelopeJSON(vector)))
        fields.version = 2
        let secret = try deviceKey.sharedSecretFromKeyAgreement(
            with: P256.KeyAgreement.PublicKey(x963Representation: fields.epk)
        )
        for version in [2, 3] {
            let aad = try deviceEnvelopeAAD(
                version: version,
                deviceId: vector["deviceId"] as! String,  // swiftlint:disable:this force_cast
                pgpFingerprint: V3Fixtures.active
            )
            #expect(openDeviceEnvelope(
                sharedSecret: secret,
                ownRawPublicKey: deviceKey.publicKey.x963Representation,
                fields: fields,
                aad: aad
            ) == nil)
        }
    }

    @Test func aV2OnlyCallerRefusesV3() {
        let json = envelopeJSON(V3Fixtures.vector(1))
        #expect(parseDeviceEnvelope(json, allowedVersions: [2]) == nil)
        #expect(parseDeviceEnvelope(json, allowedVersions: [3]) != nil)
    }

    private func v3(_ edit: (inout [String: Any]) -> Void) -> String {
        var envelope = V3Fixtures.vector(1)["envelope"] as! [String: Any]  // swiftlint:disable:this force_cast
        edit(&envelope)
        return String(decoding: V3Fixtures.serialize(envelope), as: UTF8.self)
    }

    /// Nil is "re-run the ceremony", and every malformed v3 shape lands here
    /// before any ECDH work.
    @Test func malformedV3IsRejected() {
        #expect(parseDeviceEnvelope(v3 { _ in }) != nil, "control")
        #expect(parseDeviceEnvelope(v3 { $0["v"] = "3" }) == nil, "a quoted 3 is not the v3 tag")
        #expect(parseDeviceEnvelope(v3 { $0["v"] = 3.5 }) == nil)
        #expect(parseDeviceEnvelope(v3 { $0["v"] = true }) == nil)
        #expect(parseDeviceEnvelope(v3 { $0["v"] = 4 }) == nil)
        #expect(parseDeviceEnvelope(v3 { $0["extra"] = "x" }) == nil, "exactly five fields")
        #expect(parseDeviceEnvelope(v3 { $0["alg"] = "ECDH-P384+HKDF-SHA256+A256GCM" }) == nil)
        #expect(parseDeviceEnvelope(v3 {
            $0["epk"] = (($0["epk"] as? String) ?? "").replacingOccurrences(of: "=", with: "")
        }) == nil, "unpadded base64")
        #expect(parseDeviceEnvelope(v3 {
            $0["iv"] = "AAECAwQFBgcICQoL\n"
        }) == nil, "non-canonical base64")
        #expect(parseDeviceEnvelope(v3 {
            $0["iv"] = Data(repeating: 1, count: 11).base64EncodedString()
        }) == nil)
        #expect(parseDeviceEnvelope(v3 {
            $0["ct"] = Data(repeating: 1, count: 16).base64EncodedString()
        }) == nil, "a ciphertext that is only a tag")
        #expect(parseDeviceEnvelope(v3 {
            $0["epk"] = Data([0x04] + Array(repeating: UInt8(1), count: 64)).base64EncodedString()
        }) == nil, "a point that is not on P-256")
        #expect(parseDeviceEnvelope(v3 {
            $0["epk"] = Data([0x02] + Array(repeating: UInt8(1), count: 32)).base64EncodedString()
        }) == nil)
        let huge = String(repeating: "A", count: maxDeviceEnvelopeV3Bytes)
        #expect(parseDeviceEnvelope(v3 { $0["ct"] = huge }) == nil, "over the 128 KiB bound")
    }

    /// Canonical base64: a different string naming the same bytes is refused.
    @Test func strictBase64RefusesNonCanonicalSpellings() {
        #expect(strictBase64("AAECAwQFBgcICQoL") != nil)
        #expect(strictBase64("AQ==") != nil)
        #expect(strictBase64("AR==") == nil, "non-zero trailing bits")
        #expect(strictBase64("AQ") == nil, "unpadded")
        #expect(strictBase64("") == nil)
    }

    @Test func theV3AadNeedsAFullFingerprintAndADeviceId() throws {
        #expect(throws: DeviceEnvelopeError.malformedFingerprint) {
            try deviceEnvelopeAAD(version: 3, deviceId: "d", pgpFingerprint: "ABCD")
        }
        #expect(throws: DeviceEnvelopeError.emptyDeviceId) {
            try deviceEnvelopeAAD(version: 3, deviceId: "", pgpFingerprint: V3Fixtures.active)
        }
        #expect(throws: DeviceEnvelopeError.unsupportedVersion) {
            try deviceEnvelopeAAD(version: 4, deviceId: "d", pgpFingerprint: V3Fixtures.active)
        }
        // v2 keeps accepting what it always did.
        _ = try deviceEnvelopeAAD(version: 2, deviceId: "d", pgpFingerprint: "ABCD")
        let v2 = try deviceEnvelopeAAD(version: 2, deviceId: "d", pgpFingerprint: V3Fixtures.active)
        let v3 = try deviceEnvelopeAAD(version: 3, deviceId: "d", pgpFingerprint: V3Fixtures.active)
        #expect(v2 != v3, "the domain is part of the AAD")
    }
}

// MARK: - Keyring plaintext

@Suite struct PgpKeyringParseTests {
    private func parse(_ bytes: Data, expected: String = V3Fixtures.active) -> PgpKeyring? {
        parsePgpKeyring(bytes, expectedActiveFingerprint: expected, inspector: crypto)
    }

    @Test func theSharedRingParsesCompletely() throws {
        let ring = try #require(parse(V3Fixtures.ringBytes))
        #expect(ring.materialGeneration == 2)
        #expect(ring.activeFingerprint == V3Fixtures.active)
        #expect(ring.members.map(\.fingerprint) == [V3Fixtures.active, V3Fixtures.historical])
        let declared = Set((V3Fixtures.ringObject["keyFingerprints"] as? [String]) ?? [])
        #expect(ring.keyFingerprints == declared)
        #expect(ring.keyFingerprints.contains(V3Fixtures.activeSubkey))
        #expect(ring.active.fingerprint == V3Fixtures.active)
        #expect(ring.original == V3Fixtures.ringBytes, "the original bytes are what gets sealed")
        #expect(ring.members[0].revocationCertificate == nil)
        #expect("\(ring)" == "PgpKeyring(redacted)")
        #expect("\(ring.members[0])" == "PgpKeyring.Member(redacted)")
    }

    /// The keyring fixture's ring and the v3 vector's plaintext agree.
    @Test func theKeyringFixtureIsTheSameRing() throws {
        let file = V3Fixtures.keyringFile["ring"] as! [String: Any]  // swiftlint:disable:this force_cast
        let fromFile = try #require(parse(V3Fixtures.serialize(file)))
        let fromVector = try #require(parse(V3Fixtures.ringBytes))
        #expect(fromFile.keyFingerprints == fromVector.keyFingerprints)
    }

    /// Every AAD input is public, so a self-consistent ring under someone
    /// else's active key is not this account's ring.
    @Test func theActiveKeyMustBeTheOneTheAadCommittedTo() {
        let bytes = V3Fixtures.ringBytes
        #expect(parse(bytes) != nil)
        let spaced = stride(from: 0, to: 40, by: 4).map { index -> String in
            let start = V3Fixtures.active.index(V3Fixtures.active.startIndex, offsetBy: index)
            return String(V3Fixtures.active[start..<V3Fixtures.active.index(start, offsetBy: 4)])
        }.joined(separator: " ").lowercased()
        #expect(parse(bytes, expected: spaced) != nil, "normalised like the AAD")
        #expect(parse(bytes, expected: String(repeating: "A", count: 40)) == nil)
        #expect(parse(bytes, expected: V3Fixtures.historical) == nil, "a historical member is not the committed key")
        #expect(parse(bytes, expected: V3Fixtures.activeSubkey) == nil, "a subkey is not the committed key")
        #expect(parse(bytes, expected: "not-a-fingerprint") == nil)
        #expect(parse(bytes, expected: "") == nil)
    }

    /// Retired keys stay for old mail: the fixture's historical ciphertexts,
    /// one of them to a hidden recipient, open only with the whole ring.
    @Test func historicalMailDecryptsWithARetainedMemberIncludingAHiddenRecipient() throws {
        let ring = try #require(parse(V3Fixtures.ringBytes))
        let file = V3Fixtures.keyringFile
        let expected = file["plaintext"] as! String  // swiftlint:disable:this force_cast
        for name in ["ciphertext", "hiddenCiphertext"] {
            let ciphertext = file[name] as! String  // swiftlint:disable:this force_cast
            let all = try crypto.decrypt(
                armoredCiphertext: ciphertext,
                privateKeys: ring.members.map(\.armor),
                signerKeys: []
            )
            #expect(String(decoding: all.body, as: UTF8.self) == expected, "\(name)")
            #expect(throws: PgpCryptoError.self, "\(name) needs the retired member") {
                try crypto.decrypt(
                    armoredCiphertext: ciphertext,
                    privateKeys: [ring.active.armor],
                    signerKeys: []
                )
            }
        }
    }

    @Test func fingerprintsCompareCaseInsensitivelyAndAreReportedUppercase() throws {
        let lowered = V3Fixtures.edited { ring in
            ring["activeFingerprint"] = V3Fixtures.active.lowercased()
            ring["keyFingerprints"] = (ring["keyFingerprints"] as? [String])?.map { $0.lowercased() }
        }
        let ring = try #require(parse(lowered))
        #expect(ring.activeFingerprint == V3Fixtures.active)
    }

    @Test func anOptionalRevocationCertificateIsPreservedVerbatim() throws {
        let certificate = "-----BEGIN PGP PUBLIC KEY BLOCK-----\nrevocation\n-----END PGP PUBLIC KEY BLOCK-----"
        let ring = try #require(parse(V3Fixtures.editedMember(1) { $0["revocationCertificate"] = certificate }))
        #expect(ring.members[1].revocationCertificate == certificate)
        #expect(parse(V3Fixtures.editedMember(1) { $0["revocationCertificate"] = "" }) == nil)
        #expect(parse(V3Fixtures.editedMember(1) { $0["revocationCertificate"] = 1 }) == nil)
    }

    @Test func rejectsWrongFormatFieldsAndTypes() {
        #expect(parse(V3Fixtures.edited { $0["format"] = "kypost-pgp-keyring-v2" }) == nil)
        #expect(parse(V3Fixtures.edited { $0["extra"] = true }) == nil)
        #expect(parse(V3Fixtures.edited { $0.removeValue(forKey: "keys") }) == nil)
        #expect(parse(V3Fixtures.edited { $0["keys"] = "nope" }) == nil)
        #expect(parse(V3Fixtures.editedMember(0) { $0["extra"] = "x" }) == nil)
        #expect(parse(V3Fixtures.editedMember(0) { $0["privateKey"] = 7 }) == nil)
    }

    @Test func rejectsEveryUnsafeGeneration() {
        for bad: Any in [0, -1, "2", 2.5, true, 1 << 53, NSNull()] {
            #expect(parse(V3Fixtures.edited { $0["materialGeneration"] = bad }) == nil, "\(bad)")
        }
        #expect(parse(V3Fixtures.edited { $0["materialGeneration"] = (1 << 53) - 1 }) != nil)
    }

    @Test func rejectsAnInventoryThatDoesNotMatchThePackets() {
        #expect(parse(V3Fixtures.edited { ring in
            ring["keyFingerprints"] = Array(((ring["keyFingerprints"] as? [String]) ?? []).dropLast())
        }) == nil, "missing an entry")
        #expect(parse(V3Fixtures.edited { ring in
            ring["keyFingerprints"] = ((ring["keyFingerprints"] as? [String]) ?? []) + [String(repeating: "B", count: 40)]
        }) == nil, "an extra entry")
        #expect(parse(V3Fixtures.edited { ring in
            let list = (ring["keyFingerprints"] as? [String]) ?? []
            ring["keyFingerprints"] = list + [list[0].lowercased()]
        }) == nil, "a duplicate after case normalisation")
        #expect(parse(V3Fixtures.edited { $0["keyFingerprints"] = [String]() }) == nil)
    }

    @Test func rejectsAnActiveMemberThatIsMissingOrAmbiguous() {
        #expect(parse(V3Fixtures.edited { ring in
            ring["keys"] = [((ring["keys"] as? [[String: Any]]) ?? [])[1]]
        }) == nil, "active member missing")
        #expect(parse(V3Fixtures.edited { ring in
            let keys = (ring["keys"] as? [[String: Any]]) ?? []
            ring["keys"] = keys + [keys[0]]
        }) == nil, "active member twice")
    }

    /// Foundation would keep one of two equal keys and say nothing.
    @Test func rejectsDuplicateJsonKeys() {
        var text = String(decoding: V3Fixtures.ringBytes, as: UTF8.self)
        text = text.replacingOccurrences(
            of: "\"materialGeneration\":2",
            with: "\"materialGeneration\":2,\"materialGeneration\":3"
        )
        #expect(text.contains("\"materialGeneration\":3"))
        #expect(parse(Data(text.utf8)) == nil)
    }

    @Test func duplicateKeyScanUnderstandsNestingAndEscapes() {
        #expect(!jsonHasDuplicateKeys(Data(#"{"a":{"a":1},"b":[{"a":1},{"a":2}]}"#.utf8)))
        #expect(jsonHasDuplicateKeys(Data(#"{"a":1,"b":{"c":1,"c":2}}"#.utf8)))
        #expect(jsonHasDuplicateKeys(Data(#"{"a":1,"a":2}"#.utf8)))
        #expect(jsonHasDuplicateKeys(Data(#"{"a":1,"\u0062":2}"#.utf8)), "an escaped key spelling")
        #expect(!jsonHasDuplicateKeys(Data(#"{"a":"x\"y","b":"{\"a\":1}"}"#.utf8)), "escapes in values")
        #expect(jsonHasDuplicateKeys(Data(#"{"a":"unterminated}"#.utf8)), "malformed is refused")
    }

    @Test func rejectsMalformedUtf8AndOversizedPlaintext() {
        var bytes = V3Fixtures.ringBytes
        bytes.insert(0xFF, at: bytes.index(bytes.startIndex, offsetBy: 2))
        #expect(parse(bytes) == nil)
        var padded = V3Fixtures.ringBytes
        padded.append(Data(repeating: 0x20, count: maxPgpKeyringBytes))
        #expect(parse(padded) == nil)
        #expect(parse(Data()) == nil)
    }

    @Test func rejectsAMemberWhoseDeclaredFingerprintIsNotItsPrimary() {
        #expect(parse(V3Fixtures.edited { ring in
            var keys = (ring["keys"] as? [[String: Any]]) ?? []
            let first = keys[0]["privateKey"]
            keys[0]["privateKey"] = keys[1]["privateKey"]
            keys[1]["privateKey"] = first
            ring["keys"] = keys
        }) == nil)
    }

    @Test func rejectsPublicOnlyMaterial() throws {
        let publicArmor = try crypto.ownPublicKey(privateKey: Data(V3Fixtures.memberArmor(1).utf8))
        #expect(parse(V3Fixtures.editedMember(1) { $0["privateKey"] = publicArmor }) == nil)
    }

    @Test func rejectsTwoRingsInOneEntry() throws {
        let both = V3Fixtures.memberArmor(1) + "\n" + V3Fixtures.memberArmor(0)
        #expect(parse(V3Fixtures.editedMember(1) { $0["privateKey"] = both }) == nil, "two armor blocks")

        // One armor block carrying two keys.
        let first = try #require(PgpFingerprint.dearmorSingleBlock(
            V3Fixtures.memberArmor(1), blockType: "PGP PRIVATE KEY BLOCK"
        ))
        let second = try #require(PgpFingerprint.dearmorSingleBlock(
            V3Fixtures.memberArmor(0), blockType: "PGP PRIVATE KEY BLOCK"
        ))
        let combined = V3Fixtures.armorPrivate(first + second)
        #expect(parse(V3Fixtures.editedMember(1) { $0["privateKey"] = combined }) == nil)
        // The re-armoring helper itself is sound: one key re-armored parses.
        #expect(parse(V3Fixtures.editedMember(1) { $0["privateKey"] = V3Fixtures.armorPrivate(first) }) != nil)
    }

    /// Rewrites one packet of member 1 and re-armors it.
    private func memberWithPacket(
        _ tag: UInt8,
        rewrite: (inout (tag: UInt8, body: Data), Data) -> Void
    ) throws -> Data {
        let armor = V3Fixtures.memberArmor(1)
        let binary = try #require(PgpFingerprint.dearmorSingleBlock(armor, blockType: "PGP PRIVATE KEY BLOCK"))
        var packets = try #require(PgpFingerprint.packets(in: binary))
        let publicArmor = try crypto.ownPublicKey(privateKey: Data(armor.utf8))
        let publicBinary = try #require(PgpFingerprint.dearmor(publicArmor))
        let publicPackets = try #require(PgpFingerprint.packets(in: publicBinary))
        let index = try #require(packets.firstIndex { $0.tag == tag })
        let publicTag: UInt8 = tag == 5 ? 6 : 14
        let publicBody = try #require(publicPackets.first { $0.tag == publicTag }).body
        rewrite(&packets[index], publicBody)
        var out = Data()
        for packet in packets {
            out.append(0xC0 | packet.tag)
            let length = packet.body.count
            if length < 192 {
                out.append(UInt8(length))
            } else if length < 8384 {
                let adjusted = length - 192
                out.append(UInt8((adjusted >> 8) + 192))
                out.append(UInt8(adjusted & 0xFF))
            } else {
                out.append(0xFF)
                out.append(contentsOf: [24, 16, 8, 0].map { UInt8((length >> $0) & 0xFF) })
            }
            out.append(packet.body)
        }
        return V3Fixtures.editedMember(1) { $0["privateKey"] = V3Fixtures.armorPrivate(out) }
    }

    @Test func theRewriteHelperRoundTrips() throws {
        #expect(parse(try memberWithPacket(5) { _, _ in }) != nil)
    }

    /// Refused before any password KDF could run: the S2K usage octet after
    /// the public key material must be zero.
    @Test func rejectsAStillProtectedPrivatePacket() throws {
        let protected = try memberWithPacket(5) { packet, publicBody in
            var body = packet.body
            body[body.startIndex + publicBody.count] = 254
            packet.body = body
        }
        #expect(parse(protected) == nil)
    }

    /// A subkey with no secret packet is material this device cannot use.
    @Test func rejectsAMemberMissingItsSecretSubkeyPacket() throws {
        let stripped = try memberWithPacket(7) { packet, publicBody in
            packet = (tag: 14, body: publicBody)
        }
        #expect(parse(stripped) == nil)
    }
}

// MARK: - Import decision

@Suite struct KeyringImportDecisionTests {
    private func decide(
        version: Int = 3,
        plaintext: Data = V3Fixtures.ringBytes,
        delivery: DeliveryMetadata? = V3Fixtures.delivery,
        previous: VaultRecord? = nil
    ) -> VaultImportDecision {
        decideVaultImport(
            version: version,
            plaintext: plaintext,
            identityFingerprint: V3Fixtures.active,
            delivery: delivery,
            previous: previous,
            inspector: crypto
        )
    }

    private var keyringReport: EnrollmentReport {
        .keyring(materialGeneration: 2, fingerprint: V3Fixtures.active)
    }

    @Test func aMatchingKeyringDeliveryIsStoredAndAcknowledged() throws {
        guard case let .store(record, install, report) = decide() else {
            Issue.record("expected store"); return
        }
        #expect(record.kind == .keyring)
        #expect(record.material == V3Fixtures.ringBytes, "the original bytes, not a re-serialisation")
        #expect(record.materialGeneration == 2)
        #expect(record.identityFingerprint == V3Fixtures.active)
        #expect(report == keyringReport)
        guard case .keyring(let ring) = install else { Issue.record("expected keyring"); return }
        #expect(ring.members.count == 2)
    }

    @Test func aRingAtAnotherGenerationThanTheDeliveryIsRejected() {
        var delivery = V3Fixtures.delivery
        delivery.materialGeneration = 3
        #expect(decide(delivery: delivery) == .invalidRing)
    }

    @Test func aRingWhoseInventoryDiffersFromTheDeliveryIsRejected() {
        var delivery = V3Fixtures.delivery
        delivery.keyFingerprints = Array((delivery.keyFingerprints ?? []).dropLast())
        #expect(decide(delivery: delivery) == .invalidRing)
    }

    @Test func aRingWhoseMembersDifferFromTheDeliveryIsRejected() {
        var delivery = V3Fixtures.delivery
        delivery.primaryFingerprints = [V3Fixtures.active]
        #expect(decide(delivery: delivery) == .invalidRing)
    }

    @Test func aKeyringEnvelopeWithoutUsableDeliveryMetadataIsRefused() {
        #expect(decide(delivery: nil) == .invalidRing)
        var legacy = V3Fixtures.delivery
        legacy.version = 2
        #expect(decide(delivery: legacy) == .invalidRing)
        var otherIdentity = V3Fixtures.delivery
        otherIdentity.fingerprint = V3Fixtures.historical
        #expect(decide(delivery: otherIdentity) == .invalidRing)
        #expect(!keyringDeliveryIsUsable(nil, identityFingerprint: V3Fixtures.active))
        #expect(keyringDeliveryIsUsable(V3Fixtures.delivery, identityFingerprint: V3Fixtures.active.lowercased()))
    }

    @Test func anInvalidRingIsRefused() {
        #expect(decide(plaintext: Data("{}".utf8)) == .invalidRing)
    }

    /// Durable already: nothing to rewrite, completion is idempotent.
    @Test func theExactSameBytesReplayWithoutResealing() {
        let previous = VaultRecord(
            kind: .keyring, material: V3Fixtures.ringBytes,
            identityFingerprint: V3Fixtures.active, materialGeneration: 2
        )
        guard case .replay(_, let report) = decide(previous: previous) else {
            Issue.record("expected replay"); return
        }
        #expect(report == keyringReport)
    }

    /// A newer ring that keeps every key already held replaces the old one.
    @Test func aNewerRingThatKeepsEveryHeldKeyReplacesTheOldOne() {
        let older = V3Fixtures.edited { ring in
            ring["materialGeneration"] = 1
            ring["keys"] = [((ring["keys"] as? [[String: Any]]) ?? [])[0]]
            ring["keyFingerprints"] = V3Fixtures.activeInventory
        }
        let previous = VaultRecord(
            kind: .keyring, material: older,
            identityFingerprint: V3Fixtures.active, materialGeneration: 1
        )
        guard case .store = decide(previous: previous) else {
            Issue.record("expected store"); return
        }
    }

    /// History is never overwritten: a ring that drops a held key, or that
    /// claims the same generation with different bytes, keeps the old record.
    @Test func aRingThatWouldLoseHeldKeysIsRefusedAndThePreviousKept() {
        let sameGeneration = V3Fixtures.edited { $0["keys"] = Array((($0["keys"] as? [[String: Any]]) ?? []).reversed()) }
        let previous = VaultRecord(
            kind: .keyring, material: sameGeneration,
            identityFingerprint: V3Fixtures.active, materialGeneration: 2
        )
        #expect(decide(previous: previous) == .refusedIncomparable)

        let newerButSmaller = V3Fixtures.edited { ring in
            ring["materialGeneration"] = 3
            ring["keys"] = [((ring["keys"] as? [[String: Any]]) ?? [])[0]]
            ring["keyFingerprints"] = V3Fixtures.activeInventory
        }
        var delivery = V3Fixtures.delivery
        delivery.materialGeneration = 3
        delivery.primaryFingerprints = [V3Fixtures.active]
        delivery.keyFingerprints = V3Fixtures.activeInventory
        let held = VaultRecord(
            kind: .keyring, material: V3Fixtures.ringBytes,
            identityFingerprint: V3Fixtures.active, materialGeneration: 2
        )
        #expect(decideVaultImport(
            version: 3, plaintext: newerButSmaller, identityFingerprint: V3Fixtures.active,
            delivery: delivery, previous: held, inspector: crypto
        ) == .refusedIncomparable)
    }

    /// Conversion keeps the legacy key only when the ring already holds it.
    @Test func aLegacyVaultIsReplacedOnlyByARingThatHoldsItsKeys() {
        let covered = VaultRecord(
            kind: .legacyArmor, material: Data(V3Fixtures.memberArmor(1).utf8),
            identityFingerprint: V3Fixtures.historical
        )
        guard case .store = decide(previous: covered) else {
            Issue.record("expected store"); return
        }
        let unrelated = VaultRecord(
            kind: .legacyArmor, material: Data(TestPgpFixtures.armoredPrivate.utf8),
            identityFingerprint: TestPgpFixtures.fingerprint
        )
        #expect(decide(previous: unrelated) == .refusedIncomparable)
    }

    @Test func aLegacyEnvelopeStillSealsArmorAndReportsTheBoolean() {
        let armor = Data(TestPgpFixtures.armoredPrivate.utf8)
        guard case let .store(record, install, report) = decide(version: 2, plaintext: armor, delivery: nil) else {
            Issue.record("expected store"); return
        }
        #expect(record.kind == .legacyArmor)
        #expect(record.material == armor)
        #expect(install == .legacyArmor(armor))
        #expect(report == .legacy)
    }

    @Test func aLegacyEnvelopeCannotReplaceAKeyring() {
        let previous = VaultRecord(
            kind: .keyring, material: V3Fixtures.ringBytes,
            identityFingerprint: V3Fixtures.active, materialGeneration: 2
        )
        #expect(decide(
            version: 2, plaintext: Data(TestPgpFixtures.armoredPrivate.utf8),
            delivery: nil, previous: previous
        ) == .refusedIncomparable)
    }

    /// Re-enrollment keeps the retired key: mail encrypted to it still opens,
    /// and the new key leads, so it is the one that signs.
    @Test func aLegacyReEnrollmentMergesAndRetiredMailStillDecrypts() throws {
        let retired = Data(TestPgpFixtures.armoredPrivate.utf8)
        let current = Data(V3Fixtures.memberArmor(0).utf8)
        let previous = VaultRecord(
            kind: .legacyArmor, material: retired, identityFingerprint: TestPgpFixtures.fingerprint
        )
        guard case let .store(record, _, report) = decide(
            version: 2, plaintext: current, delivery: nil, previous: previous
        ) else {
            Issue.record("expected store"); return
        }
        #expect(report == .legacy)
        let inventories = try #require(crypto.legacyInventories(armored: record.material))
        #expect(inventories.map(\.primaryFingerprint) == [V3Fixtures.active, TestPgpFixtures.fingerprint])

        let old = try crypto.decrypt(
            armoredCiphertext: TestPgpFixtures.armoredMessage,
            privateKeys: [record.material],
            signerKeys: []
        )
        #expect(String(decoding: old.body, as: UTF8.self) == TestPgpFixtures.expectedPlaintext)
        // The merged collection signs with the new key, not the retired one.
        let ownKey = try crypto.ownPublicKey(privateKey: record.material)
        #expect(crypto.fingerprint(ofArmoredPublicKey: ownKey)?.uppercased() == V3Fixtures.active)
        // And it can still sign and encrypt: gopenpgp refuses a multi-key
        // armor as one key, so the collection's first key is taken.
        let sealed = try crypto.encryptAndSign(
            plaintext: Data("hi".utf8), recipientKeys: [ownKey], privateKey: record.material
        )
        let reopened = try crypto.decrypt(
            armoredCiphertext: sealed, privateKeys: [record.material], signerKeys: [ownKey]
        )
        #expect(reopened.body == Data("hi".utf8))
        #expect(reopened.signature.valid)
    }

    @Test func aMergeDoesNotDuplicateAKeyTheNewEnvelopeAlreadyHolds() throws {
        let armor = Data(TestPgpFixtures.armoredPrivate.utf8)
        let merged = try #require(crypto.mergeLegacy(current: armor, previous: armor))
        #expect(crypto.legacyInventories(armored: merged)?.count == 1)
    }

    @Test func anUnparseablePreviousVaultIsNeverMergedOver() {
        let previous = VaultRecord(
            kind: .legacyArmor, material: Data("garbage".utf8), identityFingerprint: "AB"
        )
        #expect(decide(
            version: 2, plaintext: Data(TestPgpFixtures.armoredPrivate.utf8),
            delivery: nil, previous: previous
        ) == .mergeFailed)
    }
}

// MARK: - Vault record and sealer

/// An in-memory `SecureItemStoring` that can be told to fail writes.
nonisolated final class MemoryItemStore: SecureItemStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var failWrites = false

    func setData(_ data: Data, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw KeychainStorage.KeychainError(status: errSecIO) }
        items[key] = data
    }

    func data(forKey key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = nil
    }

    var keys: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(items.keys)
    }
}

@Suite struct EnrollmentVaultRecordTests {
    private func vault(_ store: MemoryItemStore = MemoryItemStore()) -> EnrollmentVault {
        EnrollmentVault(keychain: store, keyTag: "org.kysecurity.mail.tests.\(UUID().uuidString)")
    }

    @Test func aRecordRoundTripsWithItsKindAndGeneration() throws {
        let record = VaultRecord(
            kind: .keyring, material: V3Fixtures.ringBytes,
            identityFingerprint: V3Fixtures.active, materialGeneration: 2
        )
        #expect(VaultRecord.decode(record.encoded()) == record)
        let legacy = VaultRecord(kind: .legacyArmor, material: Data("armor".utf8), identityFingerprint: "AB")
        #expect(VaultRecord.decode(legacy.encoded()) == legacy)
        #expect(VaultRecord.decode(Data("-----BEGIN".utf8)) == nil)
        #expect("\(record)" == "VaultRecord(keyring, redacted)")
    }

    /// An enrollment made by an earlier build survives the upgrade.
    @Test func theEarlierTwoItemLayoutIsStillRead() throws {
        let store = MemoryItemStore()
        try store.setData(Data("ARMOR".utf8), forKey: "enrollment.sealedEnvelope")
        try store.setData(Data("ABCD".utf8), forKey: "enrollment.identityFingerprint")
        let vault = vault(store)
        #expect(vault.isEnrolled)
        let record = try #require(try vault.storedRecord())
        #expect(record.kind == .legacyArmor)
        #expect(record.material == Data("ARMOR".utf8))
        #expect(vault.identityFingerprint == "ABCD")
    }

    @Test func storingRetiresTheEarlierLayoutAndSupersedesTheTeardownMarker() throws {
        let store = MemoryItemStore()
        try store.setData(Data("OLD".utf8), forKey: "enrollment.sealedEnvelope")
        let vault = vault(store)
        vault.markTeardownReport()
        try vault.store(privateKey: Data("NEW".utf8), identityFingerprint: "AB")
        #expect(try vault.storedRecord()?.material == Data("NEW".utf8))
        #expect(!store.keys.contains("enrollment.sealedEnvelope"))
        #expect(!vault.teardownReportPending)
    }

    /// A failed write leaves the previous record exactly as it was.
    @Test func aFailedWriteKeepsThePreviousRecord() throws {
        let store = MemoryItemStore()
        let vault = vault(store)
        try vault.store(privateKey: Data("OLD".utf8), identityFingerprint: "AB")
        store.failWrites = true
        #expect(throws: (any Error).self) {
            try vault.store(VaultRecord(
                kind: .keyring, material: V3Fixtures.ringBytes,
                identityFingerprint: V3Fixtures.active, materialGeneration: 2
            ))
        }
        let record = try #require(try vault.storedRecord())
        #expect(record.kind == .legacyArmor)
        #expect(record.material == Data("OLD".utf8))
    }

    @Test func aRecordThatDoesNotDecodeIsNeverReadAsEmpty() throws {
        let store = MemoryItemStore()
        try store.setData(Data("garbage".utf8), forKey: "enrollment.vaultRecord")
        #expect(throws: EnrollmentVaultError.unreadableRecord) { try vault(store).storedRecord() }
    }

    @Test func theKeyringAcknowledgementIsReadFromTheRecord() throws {
        let vault = vault()
        #expect(vault.keyringAcknowledgement() == nil)
        try vault.store(VaultRecord(
            kind: .keyring, material: V3Fixtures.ringBytes,
            identityFingerprint: V3Fixtures.active, materialGeneration: 2
        ))
        #expect(vault.keyringAcknowledgement() == KeyringAcknowledgement(
            materialGeneration: 2, fingerprint: V3Fixtures.active
        ))
    }

    /// The marker is only replaced or cleared while it is still the revision
    /// the caller read, and a marker written before revisions still reads.
    @Test func thePendingMarkerIsReplacedOnlyAtTheRevisionRead() throws {
        let store = MemoryItemStore()
        let vault = vault(store)
        try store.setData(Data("2".utf8), forKey: "enrollment.reportPendingAttempts")
        #expect(vault.pendingReport == PendingEnrollmentReport(attempts: 2, revision: ""))

        vault.markReportPending(attempts: 0, revision: "b")
        #expect(!vault.replacePendingReport(ifRevision: "", with: nil), "an older revision is out of date")
        #expect(vault.pendingReport == PendingEnrollmentReport(attempts: 0, revision: "b"))
        #expect(vault.replacePendingReport(
            ifRevision: "b", with: PendingEnrollmentReport(attempts: 1, revision: "b")
        ))
        #expect(vault.pendingReportAttempts == 1)
        #expect(vault.replacePendingReport(ifRevision: "b", with: nil))
        #expect(vault.pendingReport == nil)
        #expect(!vault.replacePendingReport(ifRevision: "b", with: nil))

        vault.markReportPending()
        vault.markReportPending()
        #expect(vault.pendingReport?.revision.isEmpty == false, "each delivery mints its own revision")
    }

    /// Android b0786ee8: destroy leaves the teardown marker for the report;
    /// dropping the pairing clears it, so it never speaks for the next device.
    @Test func destroyKeepsTheTeardownMarkerAndForgettingTheParingDropsIt() throws {
        let store = MemoryItemStore()
        let vault = vault(store)
        try vault.store(privateKey: Data("K".utf8), identityFingerprint: "AB")
        vault.markReportPending(attempts: 2)
        vault.markTeardownReport()
        #expect(vault.destroyReportingFailures().isEmpty)
        #expect(!vault.isEnrolled)
        #expect(vault.teardownReportPending)
        #expect(vault.pendingReportAttempts == nil, "a pending acknowledgement describes the removed record")
        vault.markReportPending()
        #expect(vault.forgetPendingReports().isEmpty)
        #expect(!vault.teardownReportPending)
        #expect(vault.pendingReportAttempts == nil)
    }
}

@Suite(.serialized) struct VaultSealerImportTests {
    private func sealer(_ store: MemoryItemStore, session: EnrollmentSession) -> (VaultSealer, EnrollmentVault) {
        let vault = EnrollmentVault(keychain: store, keyTag: "org.kysecurity.mail.tests.\(UUID().uuidString)")
        return (VaultSealer(vault: vault, deviceId: "dev", inspector: crypto, session: session), vault)
    }

    /// Validate, store durably, then hold — and report only after.
    @Test func aFreshImportSealsThenHoldsTheRing() throws {
        let session = EnrollmentSession()
        let (sealer, vault) = sealer(MemoryItemStore(), session: session)
        let report = try sealer.importOpened(
            version: 3, plaintext: V3Fixtures.ringBytes,
            identityFingerprint: V3Fixtures.active, delivery: V3Fixtures.delivery
        )
        #expect(report == .keyring(materialGeneration: 2, fingerprint: V3Fixtures.active))
        #expect(try vault.storedRecord()?.kind == .keyring)
        #expect(session.materialGeneration == 2)
        #expect(session.holdsKeyring(identicalTo: V3Fixtures.ringBytes))
    }

    /// No partial install: a write that fails holds nothing new.
    @Test func aFailedSealHoldsNothingAndKeepsThePreviousRecord() throws {
        let store = MemoryItemStore()
        let session = EnrollmentSession()
        let (sealer, vault) = sealer(store, session: session)
        try vault.store(privateKey: Data(V3Fixtures.memberArmor(1).utf8), identityFingerprint: V3Fixtures.historical)
        session.put(armoredKey: "PREVIOUS")
        store.failWrites = true
        #expect(throws: (any Error).self) {
            try sealer.importOpened(
                version: 3, plaintext: V3Fixtures.ringBytes,
                identityFingerprint: V3Fixtures.active, delivery: V3Fixtures.delivery
            )
        }
        #expect(try vault.storedRecord()?.kind == .legacyArmor)
        #expect(session.materialGeneration == nil)
        #expect(session.withKey { $0 } == Data("PREVIOUS".utf8))
    }

    @Test func anInvalidRingTouchesNothing() throws {
        let store = MemoryItemStore()
        let session = EnrollmentSession()
        let (sealer, _) = sealer(store, session: session)
        var delivery = V3Fixtures.delivery
        delivery.materialGeneration = 9
        #expect(throws: EnrollmentSealerError.keyringRejected) {
            try sealer.importOpened(
                version: 3, plaintext: V3Fixtures.ringBytes,
                identityFingerprint: V3Fixtures.active, delivery: delivery
            )
        }
        #expect(store.keys.isEmpty)
        #expect(!session.isHeld)
    }
}

// MARK: - Session

@Suite(.serialized) struct KeyringSessionTests {
    private var ring: PgpKeyring {
        parsePgpKeyring(V3Fixtures.ringBytes, expectedActiveFingerprint: V3Fixtures.active, inspector: crypto)!
    }

    /// Every member decrypts; only the active member signs.
    @Test func aHeldRingLendsEveryMemberForDecryptionAndOnlyTheActiveToSign() {
        let session = EnrollmentSession()
        let ring = ring
        session.put(keyring: ring)
        session.withMaterial { material in
            #expect(material?.decryptionKeys == ring.members.map(\.armor))
            #expect(material?.signingKey == ring.active.armor)
            #expect(material?.materialGeneration == 2)
        }
        #expect(session.materialGeneration == 2)
    }

    @Test func legacyArmorHasNoGeneration() {
        let session = EnrollmentSession()
        session.put(armoredKey: "ARMOR")
        session.withMaterial { material in
            #expect(material?.decryptionKeys == [Data("ARMOR".utf8)])
            #expect(material?.materialGeneration == nil)
        }
    }

    /// Every buffer of the ring is forgotten at a session boundary.
    @Test func clearForgetsTheWholeRing() {
        let session = EnrollmentSession()
        session.put(keyring: ring)
        session.clear()
        #expect(!session.isHeld)
        #expect(session.materialGeneration == nil)
        #expect(!session.holdsKeyring(identicalTo: V3Fixtures.ringBytes))
        session.withMaterial { #expect($0 == nil) }
    }

    @Test func replacingMaterialDropsThePreviousKind() {
        let session = EnrollmentSession()
        session.put(keyring: ring)
        session.put(armoredKey: "LEGACY")
        #expect(session.materialGeneration == nil)
        #expect(!session.holdsKeyring(identicalTo: V3Fixtures.ringBytes))
    }
}

// MARK: - Reporting

private final class FakeReportStore: EnrollmentReportStore, @unchecked Sendable {
    var summary: EnrollmentRecordSummary?
    var unreadable = false
    var teardownReportPending = false
    var pendingReport: PendingEnrollmentReport?
    var pendingReportAttempts: Int? {
        get { pendingReport?.attempts }
        set { pendingReport = newValue.map { PendingEnrollmentReport(attempts: $0, revision: "r0") } }
    }

    func recordSummary() throws -> EnrollmentRecordSummary? {
        if unreadable { throw EnrollmentVaultError.unreadableRecord }
        return summary
    }

    func replacePendingReport(ifRevision expected: String, with next: PendingEnrollmentReport?) -> Bool {
        guard pendingReport?.revision == expected else { return false }
        pendingReport = next
        return true
    }
    func clearTeardownReport() -> Bool { teardownReportPending = false; return true }
}

@Suite struct EnrollmentReportTests {
    private let ack = KeyringAcknowledgement(materialGeneration: 2, fingerprint: V3Fixtures.active)

    @Test func whatEachRecordLetsTheDeviceClaim() {
        #expect(enrollmentReportFor(EnrollmentRecordSummary(kind: .legacyArmor), tornDown: false) == .legacy)
        #expect(enrollmentReportFor(
            EnrollmentRecordSummary(kind: .keyring, acknowledgement: ack), tornDown: false
        ) == .keyring(materialGeneration: 2, fingerprint: V3Fixtures.active))
        // A keyring is never restated as the legacy boolean.
        #expect(enrollmentReportFor(EnrollmentRecordSummary(kind: .keyring), tornDown: false) == nil)
        // No record proves nothing — unless a deliberate teardown left its marker.
        #expect(enrollmentReportFor(nil, tornDown: false) == nil)
        #expect(enrollmentReportFor(nil, tornDown: true) == .notEnrolled)
    }

    @Test func outcomes() {
        #expect(enrollmentReportOutcome(.ok, attempts: 1) == .done)
        #expect(enrollmentReportOutcome(.failed("x"), attempts: 1) == .retry)
        #expect(enrollmentReportOutcome(.failed("x"), attempts: maxEnrollmentReportAttempts) == .giveUp)
        #expect(enrollmentReportOutcome(.conflict, attempts: 1) == .giveUp, "a refused claim is never retried")
        #expect(enrollmentReportOutcome(.unauthorized, attempts: 1) == .giveUp)
        #expect(enrollmentReportOutcome(.notFound, attempts: 1) == .giveUp)
        #expect(teardownReportSpent(.ok))
        #expect(teardownReportSpent(.notFound))
        #expect(!teardownReportSpent(.failed("offline")))
    }

    @Test func nothingIsSentWithoutAMarker() async {
        let store = FakeReportStore()
        store.summary = EnrollmentRecordSummary(kind: .legacyArmor)
        let sent = Box<[EnrollmentReport]>([])
        let reporter = EnrollmentStateReporter(store: store) { report in
            sent.mutate { $0.append(report) }
            return .ok
        }
        #expect(await reporter.runIfNeeded() == nil)
        #expect(sent.value.isEmpty)
    }

    @Test func aPendingKeyringAcknowledgementIsRestatedAndRetriedThenCleared() async {
        let store = FakeReportStore()
        store.summary = EnrollmentRecordSummary(kind: .keyring, acknowledgement: ack)
        store.pendingReportAttempts = 0
        let result = Box<EnrollmentReportResult>(.failed("offline"))
        let reporter = EnrollmentStateReporter(store: store) { _ in result.value }

        #expect(await reporter.runIfNeeded() == .keyring(materialGeneration: 2, fingerprint: V3Fixtures.active))
        #expect(store.pendingReportAttempts == 1, "a transient failure stays pending")
        result.value = .ok
        _ = await reporter.runIfNeeded()
        #expect(store.pendingReportAttempts == nil)
    }

    @Test func aRefusedAcknowledgementIsNotRetried() async {
        let store = FakeReportStore()
        store.summary = EnrollmentRecordSummary(kind: .keyring, acknowledgement: ack)
        store.pendingReportAttempts = 0
        let reporter = EnrollmentStateReporter(store: store) { _ in .conflict }
        _ = await reporter.runIfNeeded()
        #expect(store.pendingReportAttempts == nil)
    }

    @Test func aTeardownIsReportedAndItsMarkerKeptUntilItLands() async {
        let store = FakeReportStore()
        store.teardownReportPending = true
        let result = Box<EnrollmentReportResult>(.failed("offline"))
        let reporter = EnrollmentStateReporter(store: store) { _ in result.value }
        #expect(await reporter.runIfNeeded() == .notEnrolled)
        #expect(store.teardownReportPending)
        result.value = .ok
        _ = await reporter.runIfNeeded()
        #expect(!store.teardownReportPending)
    }

    /// A re-enrollment while an older request is in flight writes a newer
    /// marker; whatever the older request returns says nothing about it.
    @Test(arguments: [EnrollmentReportResult.ok, .conflict, .failed("offline")])
    func anOlderRequestLeavesANewerMarkerAlone(_ outcome: EnrollmentReportResult) async {
        let store = FakeReportStore()
        store.summary = EnrollmentRecordSummary(kind: .keyring, acknowledgement: ack)
        store.pendingReportAttempts = 3
        let (started, startedTo) = AsyncStream<Void>.makeStream()
        let (release, releaseTo) = AsyncStream<EnrollmentReportResult>.makeStream()
        let reporter = EnrollmentStateReporter(store: store) { _ in
            startedTo.yield()
            for await result in release { return result }
            return .failed("closed")
        }
        let run = Task { await reporter.runIfNeeded() }
        for await _ in started { break }

        let newer = PendingEnrollmentReport(attempts: 0, revision: "newer")
        store.pendingReport = newer
        releaseTo.yield(outcome)
        _ = await run.value
        #expect(store.pendingReport == newer)
    }

    /// An unreadable record proves nothing and must not speak for the device.
    @Test func anUnreadableRecordSaysNothing() async {
        let store = FakeReportStore()
        store.unreadable = true
        store.teardownReportPending = true
        let reporter = EnrollmentStateReporter(store: store) { _ in .ok }
        #expect(await reporter.runIfNeeded() == nil)
        #expect(store.teardownReportPending)
    }
}

// MARK: - Enrollment client wire format

@Suite struct EnrollmentClientV3Tests {
    private func client(
        status: Int = 200,
        json: String = #"{"ok":true}"#,
        captured: Box<[URLRequest]>
    ) -> EnrollmentClient {
        let http = stubClient(status: status, json: json) { request in
            captured.mutate { $0.append(request) }
        }
        return EnrollmentClient(
            httpClient: http,
            bootstrapClient: PgpSendClient(httpClient: http),
            serverUrl: server,
            auth: RelayAuth(deviceId: "d", deviceSecret: "s")
        )
    }

    private func body(_ request: URLRequest?) -> [String: Any] {
        guard let data = request?.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Omitting the list resets the claim to [2] and the browser refuses v3.
    @Test func publishAdvertisesBothEnvelopeVersions() async {
        let captured = Box<[URLRequest]>([])
        _ = await client(captured: captured).publish(publicKey: Data([4, 1, 2]))
        #expect(body(captured.value.last)["envelopeVersions"] as? [Int] == [2, 3])
    }

    @Test func theEnvelopeCarriesItsDeliveryMetadata() async {
        let captured = Box<[URLRequest]>([])
        let json = #"""
        {"slot":"device:d","envelope":"{}","version":3,"fingerprint":"5F117951610CAF01500FA059CDE63F0EBEC934A2",
         "materialGeneration":2,"pgpRevision":7,
         "keyring":{"version":1,"materialGeneration":2,"primaryFingerprints":["A"],"keyFingerprints":["A","B"]},
         "publicKey":"-----BEGIN PGP PUBLIC KEY BLOCK-----"}
        """#
        let result = await client(json: json, captured: captured).fetchEnvelope()
        #expect(result == .sealed("{}", delivery: DeliveryMetadata(
            version: 3,
            fingerprint: V3Fixtures.active,
            materialGeneration: 2,
            primaryFingerprints: ["A"],
            keyFingerprints: ["A", "B"]
        )))
    }

    @Test func anOlderServerSendsNoDeliveryMetadata() async {
        let captured = Box<[URLRequest]>([])
        let result = await client(json: #"{"envelope":"{}"}"#, captured: captured).fetchEnvelope()
        #expect(result == .sealed("{}", delivery: nil))
    }

    /// The three metadata fields go together, and only for a keyring.
    @Test func reportsCarryExactlyTheFieldsTheServerExpects() async {
        let captured = Box<[URLRequest]>([])
        let client = client(captured: captured)
        #expect(await client.report(.keyring(materialGeneration: 2, fingerprint: V3Fixtures.active)) == .ok)
        let keyring = body(captured.value.last)
        #expect(keyring["encryptionEnrolled"] as? Bool == true)
        #expect(keyring["envelopeVersion"] as? Int == 3)
        #expect(keyring["materialGeneration"] as? Int == 2)
        #expect(keyring["fingerprint"] as? String == V3Fixtures.active)

        _ = await client.report(.legacy)
        #expect(Set(body(captured.value.last).keys) == ["encryptionEnrolled"])
        _ = await client.report(.notEnrolled)
        #expect(body(captured.value.last)["encryptionEnrolled"] as? Bool == false)
        #expect(captured.value.last?.url?.path == "/api/pgp/device/enrollment-state")
    }

    @Test func aRefusedAcknowledgementIsAConflict() async {
        let captured = Box<[URLRequest]>([])
        let refused = client(status: 409, json: #"{"pgpStateChanged":true,"materialGeneration":3}"#, captured: captured)
        #expect(await refused.report(.keyring(materialGeneration: 2, fingerprint: V3Fixtures.active)) == .conflict)
        let gone = client(status: 404, json: "{}", captured: captured)
        #expect(await gone.report(.legacy) == .notFound)
        let down = client(status: 500, json: "{}", captured: captured)
        guard case .failed = await down.report(.legacy) else {
            Issue.record("expected a transient failure"); return
        }
    }
}

// MARK: - Report trigger

@MainActor @Suite(.serialized) struct EnrollmentReportTriggerTests {
    private func pendingVault() throws -> EnrollmentVault {
        let vault = EnrollmentVault(
            keychain: MemoryItemStore(), keyTag: "org.kysecurity.mail.tests.\(UUID().uuidString)"
        )
        try vault.store(VaultRecord(
            kind: .keyring, material: V3Fixtures.ringBytes,
            identityFingerprint: V3Fixtures.active, materialGeneration: 2
        ))
        vault.markReportPending()
        return vault
    }

    @Test func nothingRunsWhileLockedOrAfterAnAbandonedWipe() {
        let trigger = EnrollmentReportTrigger()
        let built = Box(0)
        let make: () -> EnrollmentStateReporter? = {
            built.mutate { $0 += 1 }
            return nil
        }
        #expect(trigger.fire(isLocked: true, blockedByAbandonedWipe: false, makeReporter: make) == nil)
        #expect(trigger.fire(isLocked: false, blockedByAbandonedWipe: true, makeReporter: make) == nil)
        #expect(built.value == 0)
    }

    /// macOS: a failed acknowledgement is retried on reactivation without a
    /// relaunch, exactly once.
    @Test func anActivationRetriesAPendingAcknowledgementOnce() async throws {
        let vault = try pendingVault()
        let sent = Box(0)
        let reporter = EnrollmentStateReporter(store: vault) { _ in
            sent.mutate { $0 += 1 }
            return .ok
        }
        let trigger = EnrollmentReportTrigger()
        await trigger.fire(isLocked: false, blockedByAbandonedWipe: false) { reporter }?.value
        #expect(sent.value == 1)
        #expect(vault.pendingReport == nil)
        await trigger.fire(isLocked: false, blockedByAbandonedWipe: false) { reporter }?.value
        #expect(sent.value == 1, "nothing is pending any more")
    }

    /// Launch and activation fire together on macOS; only one run may send.
    @Test func overlappingHooksStartOneRun() async throws {
        let vault = try pendingVault()
        let sent = Box(0)
        let (release, releaseTo) = AsyncStream<Void>.makeStream()
        let reporter = EnrollmentStateReporter(store: vault) { _ in
            sent.mutate { $0 += 1 }
            for await _ in release { break }
            return .ok
        }
        let trigger = EnrollmentReportTrigger()
        let first = trigger.fire(isLocked: false, blockedByAbandonedWipe: false) { reporter }
        #expect(first != nil)
        #expect(trigger.fire(isLocked: false, blockedByAbandonedWipe: false) { reporter } == nil)
        releaseTo.yield()
        await first?.value
        #expect(sent.value == 1)
    }
}
