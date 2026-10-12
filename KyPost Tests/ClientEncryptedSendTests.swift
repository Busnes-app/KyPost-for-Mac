//
//  ClientEncryptedSendTests.swift
//  KyPost Tests
//
//  Phase 10. Each of these corresponds to a defect someone already found once
//  — the BCC leak, the folded key_changed row, the pickup fallback that would
//  store plaintext, and the Sent copy encrypted to a server-supplied key.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Fakes

private struct StubOpener: VaultOpening {
    var outcome: VaultOpenOutcome = .opened(privateKey: Data("PRIVATE".utf8))
    func open() async -> VaultOpenOutcome { outcome }
}

private struct StubResolver: RecipientKeyResolving {
    var result: ResolveResult
    func resolve(addresses: [String]) async -> ResolveResult { result }
}

/// Records what it was handed, so the tests can assert on the envelope rather
/// than only on the outcome.
private final class RecordingTransport: ClientEncryptedTransport, @unchecked Sendable {
    var sent: ClientEncryptedMessage?
    var result: Result<ClientSendResult, MailSendFailure> = .success(ClientSendResult(sentSaved: true))

    func send(_ message: ClientEncryptedMessage) async -> Result<ClientSendResult, MailSendFailure> {
        sent = message
        return result
    }
}

/// Records the recipient key sets it was asked to encrypt to, which is how the
/// BCC isolation rule is checked.
private final class RecordingCrypto: PgpEncrypting, @unchecked Sendable {
    var encryptCalls: [[String]] = []
    var signingKeys: [Data] = []
    var error: PgpCryptoError?
    var ownKey = "OWN-PUBLIC-KEY"

    func encryptAndSign(
        plaintext: Data,
        recipientKeys: [String],
        privateKey: Data
    ) throws -> String {
        if let error { throw error }
        encryptCalls.append(recipientKeys)
        signingKeys.append(privateKey)
        return "-----BEGIN PGP MESSAGE-----\n\(recipientKeys.joined(separator: ","))\n-----END PGP MESSAGE-----"
    }

    func ownPublicKey(privateKey: Data) throws -> String {
        if let error { throw error }
        return ownKey
    }
}

private func usable(_ address: String, key: String? = nil) -> ResolvedRecipientKey {
    ResolvedRecipientKey(
        address: address, publicKey: key ?? "KEY-\(address)", usable: true, tier: "contact"
    )
}

private func makeSender(
    opener: VaultOpenOutcome = .opened(privateKey: Data("PRIVATE".utf8)),
    resolve: ResolveResult,
    transport: RecordingTransport = RecordingTransport(),
    crypto: RecordingCrypto = RecordingCrypto(),
    pins: RecipientPinSnapshot = .none,
    accountAddress: String = "me@example.com",
    session: EnrollmentSession = EnrollmentSession()
) -> ClientEncryptedSender {
    ClientEncryptedSender(
        opener: StubOpener(outcome: opener),
        resolver: StubResolver(result: resolve),
        transport: transport,
        crypto: crypto,
        pins: pins,
        accountAddress: accountAddress,
        session: session,
        now: { Date(timeIntervalSince1970: 1_760_000_000) },
        boundaryToken: { "FIXEDTOKEN" }
    )
}

// MARK: - The exit table

@Suite(.serialized) struct ClientEncryptedSendTests {

    @Test func aBlankAccountAddressIsRefusedBeforeAnythingElse() async {
        let sender = makeSender(resolve: .success([usable("a@b.com")]), accountAddress: "   ")
        let outcome = await sender.send(draft: ClientSendDraft(to: "a@b.com"))
        #expect(outcome == .noAccountAddress)
    }

    /// A send that was going to be refused anyway must not interrupt the user
    /// for a biometric they gain nothing from — so resolution happens first.
    @Test func recipientsAreResolvedBeforeTheUserIsAskedToUnlock() async {
        let sender = makeSender(
            opener: .cancelled,
            resolve: .success([])  // no key for the recipient
        )
        let outcome = await sender.send(draft: ClientSendDraft(to: "nokey@b.com"))
        // keysMissing, not cancelled: the unlock was never reached.
        #expect(outcome == .keysMissing(["nokey@b.com"]))
    }

    /// A broken TOFU pin outranks a missing key and is checked first. Folding
    /// it into "no key on file" tells the user nothing changed at the exact
    /// moment the one thing worth telling them did.
    @Test func aChangedKeyIsItsOwnLouderOutcome() async {
        let sender = makeSender(resolve: .success([
            ResolvedRecipientKey(
                address: "bob@b.com", publicKey: "K", usable: true, tier: pgpTierKeyChanged
            ),
            usable("carol@b.com"),
        ]))
        let outcome = await sender.send(draft: ClientSendDraft(to: "bob@b.com, carol@b.com"))
        #expect(outcome == .keyChanged(["bob@b.com"]))
    }

    // MARK: Keys pinned on this device (Android #191)

    /// A revoked pin refuses the send before the vault opens — the opener
    /// would answer `.cancelled` if it were ever reached.
    @Test func aRevokedPinRefusesBeforeTheVaultOpens() async {
        let sender = makeSender(
            opener: .cancelled,
            resolve: .success([usable("alice@b.com", key: PinnedKeyFixtures.alicePinned)]),
            pins: RecipientPinSnapshot(states: ["alice@b.com": .revoked])
        )
        let outcome = await sender.send(draft: ClientSendDraft(to: "alice@b.com"))
        #expect(outcome == .recipientKeyRevoked(["alice@b.com"]))
    }

    /// Android 1938ed84: the revoked pin is reported whatever the relay says
    /// about the key — `key_changed`, unusable, or absent.
    @Test(arguments: [
        [ResolvedRecipientKey(address: "alice@b.com", publicKey: "K", usable: true, tier: pgpTierKeyChanged)],
        [ResolvedRecipientKey(address: "alice@b.com", publicKey: "", usable: false, tier: "")],
        [],
    ])
    func aRevokedPinOutranksRelayKeyState(relay: [ResolvedRecipientKey]) async {
        let sender = makeSender(
            opener: .cancelled,
            resolve: .success(relay),
            pins: RecipientPinSnapshot(states: ["alice@b.com": .revoked])
        )
        let outcome = await sender.send(draft: ClientSendDraft(to: "alice@b.com"))
        #expect(outcome == .recipientKeyRevoked(["alice@b.com"]))
    }

    /// The relay's key cannot stand in for a pinned one.
    @Test func aRelayKeyThatIsNotThePinIsAKeyChange() async {
        let fingerprint = PgpFingerprint.compute(fromArmored: PinnedKeyFixtures.alicePinned)!
        let sender = makeSender(
            opener: .cancelled,
            resolve: .success([usable("alice@b.com", key: PinnedKeyFixtures.bobRevoked)]),
            pins: RecipientPinSnapshot(states: [
                "alice@b.com": .intact(publicKey: PinnedKeyFixtures.alicePinned, fingerprint: fingerprint),
            ])
        )
        let outcome = await sender.send(draft: ClientSendDraft(to: "alice@b.com"))
        #expect(outcome == .keyChanged(["alice@b.com"]))
    }

    @Test func aBrokenPinIsAKeyChangeNotAnAbsence() async {
        let sender = makeSender(
            opener: .cancelled,
            resolve: .success([usable("alice@b.com", key: PinnedKeyFixtures.alicePinned)]),
            pins: RecipientPinSnapshot(states: ["alice@b.com": .broken])
        )
        #expect(await sender.send(draft: ClientSendDraft(to: "alice@b.com")) == .keyChanged(["alice@b.com"]))
    }

    /// A match encrypts to the pinned bytes, not the relay's copy of them.
    @Test func aMatchingPinEncryptsToThePinnedBytes() async throws {
        let crypto = RecordingCrypto()
        let pinnedBytes = try #require(GopenPGPCrypto().withVerifiedRevocation(
            pinned: PinnedKeyFixtures.alicePinned, synced: PinnedKeyFixtures.aliceRevokedSubkey
        ))
        let fingerprint = try #require(PgpFingerprint.compute(fromArmored: pinnedBytes))
        let sender = makeSender(
            resolve: .success([usable("alice@b.com", key: PinnedKeyFixtures.alicePinned)]),
            crypto: crypto,
            pins: RecipientPinSnapshot(states: [
                "alice@b.com": .intact(publicKey: pinnedBytes, fingerprint: fingerprint),
            ])
        )
        _ = await sender.send(draft: ClientSendDraft(to: "alice@b.com"))
        #expect(crypto.encryptCalls.first == [pinnedBytes])
    }

    @Test func aChangedKeyOutranksAMissingOne() async {
        let sender = makeSender(resolve: .success([
            ResolvedRecipientKey(
                address: "bob@b.com", publicKey: "K", usable: true, tier: pgpTierKeyChanged
            ),
        ]))
        // carol has no entry at all, so she is "missing" — but bob's changed
        // pin is the more important thing to say.
        let outcome = await sender.send(draft: ClientSendDraft(to: "bob@b.com, carol@b.com"))
        #expect(outcome == .keyChanged(["bob@b.com"]))
    }

    /// **There is no pickup fallback on this path and there must not be.** The
    /// server-side one works by storing the plaintext, which is the very thing
    /// client custody exists to prevent — so a missing key is a refusal.
    @Test func aMissingKeyRefusesRatherThanFallingBackToPickup() async {
        let transport = RecordingTransport()
        let sender = makeSender(resolve: .success([usable("a@b.com")]), transport: transport)
        let outcome = await sender.send(draft: ClientSendDraft(to: "a@b.com, nokey@b.com"))
        #expect(outcome == .keysMissing(["nokey@b.com"]))
        #expect(transport.sent == nil)
    }

    @Test func anUnusableKeyCountsAsMissing() async {
        let sender = makeSender(resolve: .success([
            ResolvedRecipientKey(address: "a@b.com", publicKey: "K", usable: false, tier: "contact"),
        ]))
        #expect(await sender.send(draft: ClientSendDraft(to: "a@b.com")) == .keysMissing(["a@b.com"]))
    }

    @Test func theWrongAccountTypeIsItsOwnRow() async {
        let sender = makeSender(resolve: .notClientProtected)
        #expect(await sender.send(draft: ClientSendDraft(to: "a@b.com")) == .notClientProtected)
    }

    @Test func tooManyRecipientsIsItsOwnRow() async {
        let sender = makeSender(resolve: .tooMany("at most 50"))
        #expect(
            await sender.send(draft: ClientSendDraft(to: "a@b.com")) == .tooManyRecipients("at most 50")
        )
    }

    @Test func aResolveFailureIsItsOwnRow() async {
        let sender = makeSender(resolve: .failed("offline"))
        #expect(await sender.send(draft: ClientSendDraft(to: "a@b.com")) == .resolveFailed("offline"))
    }

    @Test func cancellingTheUnlockIsNotAnError() async {
        let sender = makeSender(opener: .cancelled, resolve: .success([usable("a@b.com")]))
        #expect(await sender.send(draft: ClientSendDraft(to: "a@b.com")) == .cancelled)
    }

    @Test func notEnrolledAndNoLockScreenStayDistinct() async {
        let unenrolled = makeSender(opener: .notEnrolled, resolve: .success([usable("a@b.com")]))
        #expect(await unenrolled.send(draft: ClientSendDraft(to: "a@b.com")) == .notEnrolled)

        let noLock = makeSender(opener: .noSecureLockScreen, resolve: .success([usable("a@b.com")]))
        #expect(await noLock.send(draft: ClientSendDraft(to: "a@b.com")) == .noSecureLockScreen)
    }

    @Test func anEncryptFailureIsReported() async {
        let crypto = RecordingCrypto()
        crypto.error = .cannotEncrypt("no usable recipient key")
        let sender = makeSender(resolve: .success([usable("a@b.com")]), crypto: crypto)
        #expect(
            await sender.send(draft: ClientSendDraft(to: "a@b.com"))
                == .encryptFailed("no usable recipient key")
        )
    }

    @Test func aRelayRefusalIsReported() async {
        let transport = RecordingTransport()
        transport.result = .failure(MailSendFailure(message: "the server refused this message's sender address"))
        let sender = makeSender(resolve: .success([usable("a@b.com")]), transport: transport)
        #expect(
            await sender.send(draft: ClientSendDraft(to: "a@b.com"))
                == .sendFailed("the server refused this message's sender address")
        )
    }

    @Test func aSuccessfulSendReportsWhatTheRelaySaid() async {
        let transport = RecordingTransport()
        transport.result = .success(ClientSendResult(sentSaved: true, warning: "one delivery deferred"))
        let sender = makeSender(resolve: .success([usable("a@b.com")]), transport: transport)
        #expect(
            await sender.send(draft: ClientSendDraft(to: "a@b.com"))
                == .sent(sentSaved: true, warning: "one delivery deferred")
        )
    }

    // MARK: - The BCC rule

    /// **To and CC share one ciphertext; each BCC gets their own.** Otherwise a
    /// BCC recipient's key id appears in a packet another recipient can read,
    /// which reveals to everyone that a blind copy went somewhere.
    @Test func eachBccRecipientGetsTheirOwnCiphertext() async throws {
        let crypto = RecordingCrypto()
        let transport = RecordingTransport()
        let sender = makeSender(
            resolve: .success([
                usable("to@b.com"), usable("cc@b.com"), usable("bcc1@b.com"), usable("bcc2@b.com"),
            ]),
            transport: transport,
            crypto: crypto
        )
        let outcome = await sender.send(draft: ClientSendDraft(
            to: "to@b.com", cc: "cc@b.com", bcc: "bcc1@b.com, bcc2@b.com"
        ))
        guard case .sent = outcome else {
            Issue.record("expected sent, got \(outcome)")
            return
        }
        let message = try #require(transport.sent)
        // One shared delivery plus one per BCC.
        #expect(message.deliveries.count == 3)
        #expect(message.deliveries[0].recipients == ["to@b.com", "cc@b.com"])
        #expect(message.deliveries[1].recipients == ["bcc1@b.com"])
        #expect(message.deliveries[2].recipients == ["bcc2@b.com"])

        // No BCC key travels in a packet another recipient can open.
        #expect(crypto.encryptCalls[0] == ["KEY-to@b.com", "KEY-cc@b.com"])
        #expect(crypto.encryptCalls[1] == ["KEY-bcc1@b.com"])
        #expect(crypto.encryptCalls[2] == ["KEY-bcc2@b.com"])
    }

    /// Delivery 0 stays first, because index 0 failing is a hard failure
    /// server-side while later ones are only a warning.
    @Test func theSharedDeliveryIsAlwaysFirst() async throws {
        let transport = RecordingTransport()
        let sender = makeSender(
            resolve: .success([usable("to@b.com"), usable("bcc@b.com")]),
            transport: transport
        )
        _ = await sender.send(draft: ClientSendDraft(to: "to@b.com", bcc: "bcc@b.com"))
        let message = try #require(transport.sent)
        #expect(message.deliveries.first?.recipients == ["to@b.com"])
    }

    /// A BCC-only message still puts the blind recipient in their own delivery
    /// rather than promoting them into To.
    @Test func aBccOnlyMessageDoesNotPromoteThemIntoTo() async throws {
        let transport = RecordingTransport()
        let sender = makeSender(resolve: .success([usable("bcc@b.com")]), transport: transport)
        _ = await sender.send(draft: ClientSendDraft(bcc: "bcc@b.com"))
        let message = try #require(transport.sent)
        #expect(message.to.isEmpty)
        #expect(message.deliveries.count == 1)
        #expect(message.deliveries[0].recipients == ["bcc@b.com"])
        // And the cleartext headers every recipient reads name nobody.
        //
        // Asserted against the header block alone, not the whole delivery: the
        // stub crypto echoes its recipient keys into the fake ciphertext, so
        // searching the entire string would be testing the stub rather than
        // the writer.
        let headers = message.deliveries[0].ciphertext
            .components(separatedBy: "\r\n\r\n").first ?? ""
        #expect(!headers.contains("bcc@b.com"))
        #expect(!headers.lowercased().contains("bcc:"))
    }

    // MARK: - The Sent copy

    /// **Encrypted to the public half of the vault key, never to anything the
    /// server supplied.** A hostile server handing back "your" public key would
    /// otherwise get a readable copy of every message sent, with nothing on
    /// screen looking any different.
    @Test func theSentCopyIsEncryptedToThisDevicesOwnKey() async throws {
        let crypto = RecordingCrypto()
        let transport = RecordingTransport()
        let sender = makeSender(
            resolve: .success([usable("a@b.com")]), transport: transport, crypto: crypto
        )
        _ = await sender.send(draft: ClientSendDraft(to: "a@b.com"))
        // The final encrypt is the Sent copy, and it used the key derived from
        // the private half — not one that came over the wire.
        #expect(crypto.encryptCalls.last == ["OWN-PUBLIC-KEY"])
        let message = try #require(transport.sent)
        #expect(message.sentCopy.contains("OWN-PUBLIC-KEY"))
    }
}

// MARK: - Device-envelope v3: generation and the converted-account refusals

@Suite(.serialized) struct ClientEncryptedSendGenerationTests {
    private var ring: PgpKeyring {
        parsePgpKeyring(
            V3Fixtures.ringBytes,
            expectedActiveFingerprint: V3Fixtures.active,
            inspector: GopenPGPCrypto()
        )!
    }

    /// The held generation rides on the send; signing and the Sent copy use
    /// the explicit active member, never a retired one.
    @Test func aHeldKeyringSendsItsGenerationAndSignsWithTheActiveKey() async throws {
        let session = EnrollmentSession()
        let ring = ring
        session.put(keyring: ring)
        let transport = RecordingTransport()
        let crypto = RecordingCrypto()
        let outcome = await makeSender(
            resolve: .success([usable("a@b.com")]),
            transport: transport,
            crypto: crypto,
            session: session
        ).send(draft: ClientSendDraft(to: "a@b.com"))
        #expect(outcome == .sent(sentSaved: true, warning: ""))
        #expect(transport.sent?.materialGeneration == 2)
        #expect(!crypto.signingKeys.isEmpty)
        #expect(crypto.signingKeys.allSatisfy { $0 == ring.active.armor })
    }

    /// A legacy account must never see a made-up generation.
    @Test func legacyArmorSendsNoGeneration() async {
        let transport = RecordingTransport()
        _ = await makeSender(resolve: .success([usable("a@b.com")]), transport: transport)
            .send(draft: ClientSendDraft(to: "a@b.com"))
        #expect(transport.sent != nil)
        #expect(transport.sent?.materialGeneration == nil)
    }

    @Test func bothConvertedAccountRefusalsAreTheirOwnRows() async {
        for (kind, expected) in [
            (MailSendFailure.Kind.reenrollmentRequired, ClientSendOutcome.reenrollmentRequired),
            (.pgpStateChanged, .pgpStateChanged),
        ] {
            let transport = RecordingTransport()
            transport.result = .failure(MailSendFailure(message: "refused", kind: kind))
            let outcome = await makeSender(resolve: .success([usable("a@b.com")]), transport: transport)
                .send(draft: ClientSendDraft(to: "a@b.com"))
            #expect(outcome == expected)
        }
    }

    private func relay(status: Int, json: String, captured: Box<URLRequest?>) -> ClientEncryptedSendClient {
        ClientEncryptedSendClient(
            httpClient: stubClient(status: status, json: json) { captured.value = $0 },
            serverUrl: server,
            auth: RelayAuth(deviceId: "d", deviceSecret: "s")
        )
    }

    private let message = ClientEncryptedMessage(
        from: "me@example.com", to: ["a@b.com"], cc: [], bcc: [],
        deliveries: [ClientEncryptedDelivery(recipients: ["a@b.com"], ciphertext: "CT")],
        sentCopy: "SC", mode: "html"
    )

    /// On the wire: present when held, absent — not null — otherwise.
    @Test func theGenerationIsOnTheWireOnlyWhenHeld() async throws {
        let captured = Box<URLRequest?>(nil)
        var withGeneration = message
        withGeneration.materialGeneration = 2
        _ = await relay(status: 200, json: #"{"ok":true}"#, captured: captured).send(withGeneration)
        let sent = try #require(captured.value?.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(object["materialGeneration"] as? Int == 2)

        _ = await relay(status: 200, json: #"{"ok":true}"#, captured: captured).send(message)
        let legacy = try #require(captured.value?.httpBody)
        #expect(!String(decoding: legacy, as: UTF8.self).contains("materialGeneration"))
    }

    /// Told apart by JSON field, never by the prose.
    @Test func the409sAreMappedByTheirJsonField() async {
        let captured = Box<URLRequest?>(nil)
        let cases: [(String, MailSendFailure.Kind)] = [
            (#"{"error":"this device holds retired key material; enroll it again before sending","reenrollmentRequired":true,"materialGeneration":3}"#, .reenrollmentRequired),
            (#"{"error":"the account's key material changed; reload and send again","pgpStateChanged":true,"materialGeneration":3}"#, .pgpStateChanged),
            (#"{"error":"something else"}"#, .other),
        ]
        for (json, kind) in cases {
            let result = await relay(status: 409, json: json, captured: captured).send(message)
            guard case .failure(let failure) = result else {
                Issue.record("expected a failure"); continue
            }
            #expect(failure.kind == kind)
        }
    }
}
