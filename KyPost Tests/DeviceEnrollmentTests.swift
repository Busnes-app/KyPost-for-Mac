//
//  DeviceEnrollmentTests.swift
//  KyPost Tests
//

import CryptoKit
import Foundation
import Testing
@testable import KyPost

// MARK: - Envelope

@Suite struct DeviceEnvelopeParsingTests {
    /// `v` is emitted as a **raw JSON token**, so the default `2` reaches the
    /// parser as a JSON *number* — which is what the browser serialises and
    /// what the normative spec shows (`"v": 1`, unquoted). A quoted form is
    /// passed as `"\"2\""` where a test needs it.
    private func envelope(
        v: String = "2",
        alg: String = "ECDH-P256+HKDF-SHA256+A256GCM",
        epk: Data = Data([0x04] + Array(repeating: UInt8(1), count: 64)),
        iv: Data = Data(repeating: 2, count: 12),
        ct: Data = Data(repeating: 3, count: 32)
    ) -> String {
        """
        {"v":\(v),"alg":"\(alg)","epk":"\(epk.base64EncodedString())",
         "iv":"\(iv.base64EncodedString())","ct":"\(ct.base64EncodedString())"}
        """
    }

    @Test func parsesAWellFormedEnvelope() {
        let fields = parseDeviceEnvelope(envelope())
        #expect(fields?.epk.count == 65)
        #expect(fields?.iv.count == 12)
    }

    /// The version tag arrives as a JSON number from the server, but a quoted
    /// string must parse too — Android reads the primitive's textual content,
    /// and a strict `as? String` check here rejected every real server
    /// envelope as malformed. Both forms of "2" are accepted; "1" is not.
    @Test func acceptsTheVersionTagAsNumberOrString() {
        #expect(parseDeviceEnvelope(envelope(v: "2")) != nil, "number 2")
        #expect(parseDeviceEnvelope(envelope(v: "\"2\"")) != nil, "string \"2\"")
        #expect(parseDeviceEnvelope(envelope(v: "\"1\"")) == nil, "string \"1\"")
    }

    /// Nil means re-run the ceremony, never retry — so every malformed shape
    /// must land here rather than reaching the ECDH layer.
    @Test func rejectsAnythingUnsupportedOrWrongSized() {
        #expect(parseDeviceEnvelope(envelope(v: "1")) == nil)
        #expect(parseDeviceEnvelope(envelope(alg: "ECDH-P384+HKDF-SHA256+A256GCM")) == nil)
        #expect(parseDeviceEnvelope("not json") == nil)
        #expect(parseDeviceEnvelope("{}") == nil)
        // The browser requires exactly 65 bytes with an 0x04 prefix before it
        // will import the point; matching that here means the ECDH layer is
        // not the only thing standing between a hostile blob and the key.
        #expect(parseDeviceEnvelope(envelope(epk: Data(repeating: 4, count: 64))) == nil)
        #expect(parseDeviceEnvelope(
            envelope(epk: Data([0x02] + Array(repeating: UInt8(1), count: 64)))
        ) == nil, "a compressed-point marker must be refused")
        #expect(parseDeviceEnvelope(envelope(iv: Data(repeating: 2, count: 16))) == nil)
        // Ciphertext must exceed the GCM tag, or there is no plaintext at all.
        #expect(parseDeviceEnvelope(envelope(ct: Data(repeating: 3, count: 16))) == nil)
    }
}

@Suite struct DeviceEnvelopeAADTests {
    /// The ambiguity length-prefixing removes: under pipe concatenation these
    /// two produce byte-identical AAD, and each envelope opens under the
    /// other's binding.
    @Test func lengthPrefixingRemovesTheDelimiterAmbiguity() throws {
        let a = try deviceEnvelopeAAD(deviceId: "dev|BADC0FFEE", pgpFingerprint: "0123")
        let b = try deviceEnvelopeAAD(deviceId: "dev", pgpFingerprint: "BADC0FFEE0123")
        #expect(a != b)
    }

    /// The repo's fingerprint producer returns space-grouped hex while the
    /// browser strips whitespace, so an unnormalised AAD could never
    /// authenticate — and the failure surfaces as "the key this server gave
    /// the browser is not the key on that device", training users to dismiss
    /// the one alarm this feature has.
    @Test func normalisesSpacedAndLowercaseFingerprints() throws {
        let spaced = try deviceEnvelopeAAD(
            deviceId: "d1", pgpFingerprint: "abcd 1234 ABCD 1234"
        )
        let bare = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "ABCD1234ABCD1234")
        #expect(spaced == bare)
    }

    @Test func refusesAFingerprintThatIsNotHex() {
        #expect(throws: DeviceEnvelopeError.malformedFingerprint) {
            try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "not-a-fingerprint")
        }
        #expect(throws: DeviceEnvelopeError.malformedFingerprint) {
            try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "   ")
        }
    }

    @Test func bindsToBothTheDeviceAndTheIdentity() throws {
        let base = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "ABCD")
        let otherDevice = try deviceEnvelopeAAD(deviceId: "d2", pgpFingerprint: "ABCD")
        let otherIdentity = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "BEEF")
        #expect(base != otherDevice)
        #expect(base != otherIdentity)
    }
}

@Suite struct DeviceEnvelopeOpenTests {
    /// Seals exactly as the browser does, then opens it — the only way to know
    /// the HKDF salt, info string, AAD layout and GCM parameters all agree.
    private func seal(
        deviceKey: P256.KeyAgreement.PrivateKey,
        aad: Data,
        plaintext: Data
    ) throws -> (DeviceEnvelopeFields, SharedSecret) {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let ownRaw = deviceKey.publicKey.x963Representation
        let browserSecret = try ephemeral.sharedSecretFromKeyAgreement(
            with: deviceKey.publicKey
        )
        let key = browserSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ownRaw,
            sharedInfo: Data(envelopeInfo.utf8),
            outputByteCount: 32
        )
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 7, count: 12))
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        let fields = DeviceEnvelopeFields(
            epk: ephemeral.publicKey.x963Representation,
            iv: Data(box.nonce),
            ct: box.ciphertext + box.tag
        )
        let deviceSecret = try deviceKey.sharedSecretFromKeyAgreement(
            with: P256.KeyAgreement.PublicKey(x963Representation: fields.epk)
        )
        return (fields, deviceSecret)
    }

    @Test func opensAnEnvelopeSealedTheWayTheBrowserSealsIt() throws {
        let deviceKey = P256.KeyAgreement.PrivateKey()
        let aad = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "ABCD1234")
        let plaintext = Data("-----BEGIN PGP PRIVATE KEY BLOCK-----".utf8)
        let (fields, secret) = try seal(deviceKey: deviceKey, aad: aad, plaintext: plaintext)

        let opened = openDeviceEnvelope(
            sharedSecret: secret,
            ownRawPublicKey: deviceKey.publicKey.x963Representation,
            fields: fields,
            aad: aad
        )
        #expect(opened == plaintext)
    }

    /// A failure is hostile or stale, never a retry: the AAD binds the sealing
    /// to this device and this identity.
    @Test func refusesAnEnvelopeBoundToAnotherIdentity() throws {
        let deviceKey = P256.KeyAgreement.PrivateKey()
        let sealedAAD = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "ABCD1234")
        let (fields, secret) = try seal(
            deviceKey: deviceKey, aad: sealedAAD, plaintext: Data("secret".utf8)
        )
        let otherAAD = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "BEEF5678")

        #expect(openDeviceEnvelope(
            sharedSecret: secret,
            ownRawPublicKey: deviceKey.publicKey.x963Representation,
            fields: fields,
            aad: otherAAD
        ) == nil)
    }

    /// The HKDF salt is this device's own public key, which is what makes a
    /// cross-device replay fail even before the AAD is consulted.
    @Test func refusesAnEnvelopeMintedForAnotherDevice() throws {
        let deviceKey = P256.KeyAgreement.PrivateKey()
        let aad = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "ABCD1234")
        let (fields, secret) = try seal(
            deviceKey: deviceKey, aad: aad, plaintext: Data("secret".utf8)
        )
        let otherDevice = P256.KeyAgreement.PrivateKey()

        #expect(openDeviceEnvelope(
            sharedSecret: secret,
            ownRawPublicKey: otherDevice.publicKey.x963Representation,
            fields: fields,
            aad: aad
        ) == nil)
    }
}

// MARK: - Enrollment code

@Suite struct DeviceEnrollmentCodeTests {
    private let key = Data([0x04] + (1...64).map(UInt8.init))

    @Test func isFourteenCrockfordCharacters() {
        let code = deviceEnrollmentCode(rawPublicKey: key, deviceId: "dev-1", bucket: 100)
        #expect(code.count == enrollmentCodeLength)
        // I, L, O and U are excluded so they cannot be confused with 1, 0, V.
        #expect(code.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
    }

    @Test func isDeterministicForOneBucket() {
        let first = deviceEnrollmentCode(rawPublicKey: key, deviceId: "dev-1", bucket: 100)
        let second = deviceEnrollmentCode(rawPublicKey: key, deviceId: "dev-1", bucket: 100)
        #expect(first == second)
    }

    @Test func changesWithEveryInput() {
        let base = deviceEnrollmentCode(rawPublicKey: key, deviceId: "dev-1", bucket: 100)
        #expect(base != deviceEnrollmentCode(rawPublicKey: key, deviceId: "dev-1", bucket: 101))
        #expect(base != deviceEnrollmentCode(rawPublicKey: key, deviceId: "dev-2", bucket: 100))
        var otherKey = key
        otherKey[10] ^= 0xFF
        #expect(base != deviceEnrollmentCode(rawPublicKey: otherKey, deviceId: "dev-1", bucket: 100))
    }

    /// Length-prefixing the device id: without it, ("ab", bucket) and
    /// ("a", "b"-shifted) could share a preimage.
    @Test func theDeviceIdIsLengthPrefixedNotConcatenated() {
        #expect(
            deviceEnrollmentCode(rawPublicKey: key, deviceId: "ab", bucket: 1)
                != deviceEnrollmentCode(rawPublicKey: key, deviceId: "a", bucket: 1)
        )
    }

    @Test func bucketsAreTwoMinutesWide() {
        #expect(enrollmentBucket(at: Date(timeIntervalSince1970: 0)) == 0)
        #expect(enrollmentBucket(at: Date(timeIntervalSince1970: 119)) == 0)
        #expect(enrollmentBucket(at: Date(timeIntervalSince1970: 120)) == 1)
        #expect(enrollmentBucket(at: Date(timeIntervalSince1970: 241)) == 2)
    }

    @Test func displaysAsFourGroups() {
        #expect(formattedEnrollmentCode("ABCDEFGHJKMNPQ") == "ABCD-EFG-HJKM-NPQ")
    }
}

// MARK: - Ceremony exit table

private final class FakeTransport: EnrollmentTransport, @unchecked Sendable {
    var fingerprint: String? = "ABCD1234"
    var publishResult: EnrollmentPublishResult = .ok
    /// Consumed in order; the last value repeats once exhausted.
    var envelopeResults: [EnrollmentEnvelopeResult] = [.notSealed]
    var reportResult: EnrollmentReportResult = .ok
    private(set) var publishCount = 0
    private(set) var published: Data?
    private(set) var reported: EnrollmentReport?
    private var envelopeIndex = 0

    func identityFingerprint() async -> String? { fingerprint }

    func publish(publicKey: Data) async -> EnrollmentPublishResult {
        publishCount += 1
        published = publicKey
        return publishResult
    }

    func fetchEnvelope() async -> EnrollmentEnvelopeResult {
        defer { envelopeIndex = min(envelopeIndex + 1, envelopeResults.count - 1) }
        return envelopeResults[envelopeIndex]
    }

    func report(_ report: EnrollmentReport) async -> EnrollmentReportResult {
        reported = report
        return reportResult
    }
}

private final class FakeSealer: EnrollmentSealer, @unchecked Sendable {
    var publicKey = Data([0x04] + Array(repeating: UInt8(9), count: 64))
    var publicKeyError: Error?
    var storeError: Error?
    var report: EnrollmentReport = .legacy
    private(set) var stored: (json: String, fingerprint: String, delivery: DeliveryMetadata?)?

    func deviceRawPublicKey() throws -> Data {
        if let publicKeyError { throw publicKeyError }
        return publicKey
    }

    func openAndStore(
        envelopeJSON: String,
        identityFingerprint: String,
        delivery: DeliveryMetadata?
    ) async throws -> EnrollmentReport {
        if let storeError { throw storeError }
        stored = (envelopeJSON, identityFingerprint, delivery)
        return report
    }
}

@Suite struct EnrollmentCeremonyTests {
    private func ceremony(
        transport: FakeTransport = FakeTransport(),
        sealer: FakeSealer = FakeSealer(),
        hostileLocation: Bool = false,
        hasCredential: Bool = true,
        clock: Box<Date> = Box(Date(timeIntervalSince1970: 0)),
        transcript: Box<[EnrollmentState]> = Box([]),
        deferred: Box<Int> = Box(0),
        landed: Box<Int> = Box(0)
    ) -> EnrollmentCeremony {
        EnrollmentCeremony(
            transport: transport,
            sealer: sealer,
            deviceId: "dev-1",
            hostileLocationEnabled: { hostileLocation },
            hasDeviceCredential: { hasCredential },
            now: { clock.value },
            // Advancing the clock in place of sleeping keeps the poll window
            // deterministic and the test instant.
            sleep: { seconds in clock.value = clock.value.addingTimeInterval(seconds) },
            deferReport: { deferred.mutate { $0 += 1 } },
            reportSettled: { landed.mutate { $0 += 1 } },
            onState: { state in transcript.mutate { $0.append(state) } }
        )
    }

    // MARK: Device-envelope v3

    private let delivery = DeliveryMetadata(
        version: 3, fingerprint: "ABCD1234", materialGeneration: 2,
        primaryFingerprints: ["ABCD1234"], keyFingerprints: ["ABCD1234"]
    )

    /// The server's delivery record reaches the sealer, which validates the
    /// ring against it, and what the sealer stored is what gets acknowledged.
    @Test func aKeyringDeliveryIsImportedAndAcknowledged() async {
        let transport = FakeTransport()
        transport.envelopeResults = [.sealed("{}", delivery: delivery)]
        let sealer = FakeSealer()
        sealer.report = .keyring(materialGeneration: 2, fingerprint: "ABCD1234", envelopeVersion: 3)
        let landed = Box(0)
        let outcome = await ceremony(transport: transport, sealer: sealer, landed: landed).run()
        #expect(outcome == .enrolled)
        #expect(sealer.stored?.delivery == delivery)
        #expect(transport.reported == .keyring(materialGeneration: 2, fingerprint: "ABCD1234", envelopeVersion: 3))
        #expect(landed.value == 1)
    }

    @Test func aRejectedRingIsItsOwnTerminalStateAndIsNeverAcknowledged() async {
        let transport = FakeTransport()
        transport.envelopeResults = [.sealed("{}", delivery: delivery)]
        let sealer = FakeSealer()
        sealer.storeError = EnrollmentSealerError.keyringRejected
        #expect(await ceremony(transport: transport, sealer: sealer).run() == .keyringRejected)
        #expect(transport.reported == nil)
    }

    /// 409 is final: the same claim cannot become true by repeating it.
    @Test func aRefusedAcknowledgementIsATerminalFailureWithoutRetry() async {
        let transport = FakeTransport()
        transport.envelopeResults = [.sealed("{}", delivery: delivery)]
        transport.reportResult = .conflict
        let deferred = Box(0)
        let outcome = await ceremony(transport: transport, deferred: deferred).run()
        #expect(outcome == .acknowledgementRefused)
        #expect(deferred.value == 0)
    }

    /// A 409 also settles an earlier failed delivery's marker: otherwise the
    /// next foreground repeats the claim the server just refused.
    @Test func aRefusedAcknowledgementClearsAnEarlierPendingMarker() async throws {
        let vault = testVault()
        try vault.store(VaultRecord(
            kind: .keyring, material: V3Fixtures.ringBytes,
            identityFingerprint: V3Fixtures.active, materialGeneration: 2
        ))
        vault.markReportPending(attempts: 1)

        let transport = FakeTransport()
        transport.envelopeResults = [.sealed("{}", delivery: delivery)]
        transport.reportResult = .conflict
        let ceremony = EnrollmentCeremony(
            transport: transport,
            sealer: FakeSealer(),
            deviceId: "dev-1",
            hostileLocationEnabled: { false },
            hasDeviceCredential: { true },
            sleep: { _ in },
            deferReport: { vault.markReportPending() },
            reportSettled: { vault.clearReportPending() },
            onState: { _ in }
        )
        #expect(await ceremony.run() == .acknowledgementRefused)

        let sent = Box(0)
        let reporter = EnrollmentStateReporter(store: vault) { _ in
            sent.mutate { $0 += 1 }
            return .ok
        }
        #expect(await reporter.runIfNeeded() == nil)
        #expect(sent.value == 0)
    }

    /// A dropped acknowledgement is not a failed enrollment: the record is
    /// sealed, and the next launch or foreground restates it.
    @Test func aDroppedAcknowledgementIsRetriedLater() async {
        let transport = FakeTransport()
        transport.envelopeResults = [.sealed("{}")]
        transport.reportResult = .failed("offline")
        let deferred = Box(0)
        let landed = Box(0)
        let outcome = await ceremony(transport: transport, deferred: deferred, landed: landed).run()
        #expect(outcome == .enrolled)
        #expect(deferred.value == 1)
        #expect(landed.value == 0)
    }

    /// The gate, and it is checked before anything is published: enrollment is
    /// available only when Hostile Location Protection is off.
    @Test func hostileLocationProtectionBlocksEnrollmentOutright() async {
        let transport = FakeTransport()
        let outcome = await ceremony(transport: transport, hostileLocation: true).run()
        #expect(outcome == .hostileLocationEnabled)
        #expect(transport.publishCount == 0, "nothing may be published from a device in that mode")
    }

    /// The envelope's protection *is* the lock screen, so a device without one
    /// cannot hold a meaningful envelope. The honest outcome, not degradation.
    @Test func aDeviceWithNoCredentialCannotEnrol() async {
        let outcome = await ceremony(hasCredential: false).run()
        #expect(outcome == .noDeviceCredential)
    }

    @Test func anAccountWithNoPgpIdentityStopsBeforePublishing() async {
        let transport = FakeTransport()
        transport.fingerprint = nil
        let outcome = await ceremony(transport: transport).run()
        #expect(outcome == .noIdentity)
        #expect(transport.publishCount == 0)
    }

    @Test func anUnauthorizedPublishReportsPairingRatherThanAGenericFailure() async {
        let transport = FakeTransport()
        transport.publishResult = .unauthorized
        #expect(await ceremony(transport: transport).run() == .notPaired)
    }

    @Test func aRejectedPublishCarriesItsReason() async {
        let transport = FakeTransport()
        transport.publishResult = .rejected("device already enrolled")
        #expect(await ceremony(transport: transport).run()
            == .publishRejected("device already enrolled"))
    }

    @Test func showsACodeWhileWaitingAndTimesOutAfterTheWindow() async {
        let transcript = Box<[EnrollmentState]>([])
        let outcome = await ceremony(transcript: transcript).run()
        #expect(outcome == .timedOut)
        let codes = transcript.value.compactMap { state -> String? in
            if case .showingCode(let code, _) = state { return code }
            return nil
        }
        #expect(!codes.isEmpty)
        #expect(codes.allSatisfy { $0.count == enrollmentCodeLength })
    }

    /// The code rotates with its bucket, so a window spanning one must show
    /// more than one — a stale code is one the browser rejects.
    @Test func theCodeRotatesAsBucketsPass() async {
        let transcript = Box<[EnrollmentState]>([])
        _ = await ceremony(transcript: transcript).run()
        let codes = Set(transcript.value.compactMap { state -> String? in
            if case .showingCode(let code, _) = state { return code }
            return nil
        })
        #expect(codes.count > 1)
    }

    @Test func aSealedEnvelopeCompletesTheCeremony() async {
        let transport = FakeTransport()
        transport.envelopeResults = [.notSealed, .sealed("{\"v\":\"2\"}")]
        let sealer = FakeSealer()
        let outcome = await ceremony(transport: transport, sealer: sealer).run()
        #expect(outcome == .enrolled)
        #expect(sealer.stored?.fingerprint == "ABCD1234")
        #expect(transport.reported == .legacy)
    }

    /// Hostile or stale, never a retry.
    @Test func aRejectedEnvelopeIsItsOwnTerminalState() async {
        let transport = FakeTransport()
        transport.envelopeResults = [.sealed("{}")]
        let sealer = FakeSealer()
        sealer.storeError = EnrollmentSealerError.envelopeRejected
        let outcome = await ceremony(transport: transport, sealer: sealer).run()
        #expect(outcome == .envelopeRejected)
        #expect(transport.reported == nil, "a failed open must not report enrolment")
    }

    /// Not an error: the user dismissed a prompt they raised, and the envelope
    /// is still there, so the screen goes back to offering the action.
    @Test func aCancelledAuthenticationIsNotAFailure() async {
        let transport = FakeTransport()
        transport.envelopeResults = [.sealed("{}")]
        let sealer = FakeSealer()
        sealer.storeError = EnrollmentVaultError.cancelled
        #expect(await ceremony(transport: transport, sealer: sealer).run() == .cancelled)
    }

    /// The user can turn the protection on while the window is open; storing
    /// after that would leave the account's key on a device meant to hold none.
    @Test func protectionTurnedOnMidCeremonyStopsTheStore() async {
        let clock = Box(Date(timeIntervalSince1970: 0))
        let transcript = Box<[EnrollmentState]>([])
        let hostile = Box(false)
        let transport = FakeTransport()
        transport.envelopeResults = [.sealed("{}")]
        let sealer = FakeSealer()

        let ceremony = EnrollmentCeremony(
            transport: transport,
            sealer: sealer,
            deviceId: "dev-1",
            hostileLocationEnabled: { hostile.value },
            hasDeviceCredential: { true },
            now: { clock.value },
            sleep: { _ in },
            onState: { state in
                transcript.mutate { $0.append(state) }
                // Flipped the instant the code goes up, i.e. before the sealed
                // envelope is stored.
                if case .showingCode = state { hostile.value = true }
            }
        )
        let outcome = await ceremony.run()
        #expect(outcome == .hostileLocationEnabled)
        #expect(sealer.stored == nil)
    }
}
