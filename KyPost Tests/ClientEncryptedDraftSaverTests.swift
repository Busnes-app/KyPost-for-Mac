//
//  ClientEncryptedDraftSaverTests.swift
//  KyPost Tests
//
//  The client-custody draft save: what reaches the relay, which key it is
//  encrypted to, and every exit that must upload nothing.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Fakes

private final class RecordingOpener: VaultOpening, @unchecked Sendable {
    var outcome: VaultOpenOutcome = .opened(privateKey: Data("PRIVATE".utf8))
    var calls = 0

    init(_ outcome: VaultOpenOutcome = .opened(privateKey: Data("PRIVATE".utf8))) {
        self.outcome = outcome
    }

    func open() async -> VaultOpenOutcome {
        calls += 1
        return outcome
    }
}

private final class RecordingDraftTransport: ClientEncryptedDraftTransport, @unchecked Sendable {
    var saved: [ClientEncryptedDraft] = []
    var outcome: MailOutcome = .success

    func save(_ draft: ClientEncryptedDraft) async -> MailOutcome {
        saved.append(draft)
        return outcome
    }
}

private nonisolated let armoredCiphertext = "-----BEGIN PGP MESSAGE-----\nOPAQUE\n-----END PGP MESSAGE-----"

/// Records every encryption. The own public key is derived from the private
/// key it is given, so a test can tell "derived from local material" from
/// anything else.
private final class RecordingDraftCrypto: PgpEncrypting, @unchecked Sendable {
    struct Call {
        var plaintext: Data
        var recipientKeys: [String]
        var privateKey: Data
    }

    var calls: [Call] = []
    var encryptError: PgpCryptoError?
    var ownKeyError: PgpCryptoError?

    static func ownKey(for privateKey: Data) -> String {
        "OWN-PUBLIC(\(String(decoding: privateKey, as: UTF8.self)))"
    }

    func encryptAndSign(plaintext: Data, recipientKeys: [String], privateKey: Data) throws -> String {
        if let encryptError { throw encryptError }
        calls.append(Call(plaintext: plaintext, recipientKeys: recipientKeys, privateKey: privateKey))
        return armoredCiphertext
    }

    func ownPublicKey(privateKey: Data) throws -> String {
        if let ownKeyError { throw ownKeyError }
        return Self.ownKey(for: privateKey)
    }
}

private func makeSaver(
    opener: RecordingOpener = RecordingOpener(),
    transport: RecordingDraftTransport = RecordingDraftTransport(),
    crypto: RecordingDraftCrypto = RecordingDraftCrypto(),
    accountAddress: String = "me@example.com",
    session: EnrollmentSession = EnrollmentSession(),
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_760_000_000) }
) -> ClientEncryptedDraftSaver {
    ClientEncryptedDraftSaver(
        opener: opener,
        transport: transport,
        crypto: crypto,
        accountAddress: accountAddress,
        session: session,
        now: now,
        boundaryToken: { "FIXEDTOKEN" }
    )
}

private let fullDraft = ClientSendDraft(
    to: "a@example.com, b@example.com",
    cc: "carol@secret.example",
    bcc: "dave@hidden.example",
    subject: "Merger plans",
    body: "The body nobody else may read",
    mode: "plain",
    attachments: [OutgoingMimeAttachment(
        name: "plan.txt", mimeType: "text/plain", dataBase64: "QVRUQUNITUVOVEJZVEVT"
    )]
)

/// The outer header block, up to the first blank line.
private func outerHeaders(_ message: String) -> [String] {
    (message.components(separatedBy: "\r\n\r\n").first ?? "").components(separatedBy: "\r\n")
}

// MARK: - The saved draft

@Suite(.serialized) struct ClientEncryptedDraftSaverTests {

    @Test func aSaveUploadsOnlyToAndTheEncryptedDraft() async throws {
        let transport = RecordingDraftTransport()
        let outcome = await makeSaver(transport: transport).save(draft: fullDraft)

        #expect(outcome == .saved)
        #expect(transport.saved.count == 1)
        let saved = try #require(transport.saved.first)
        #expect(saved.to == "a@example.com, b@example.com")
        #expect(saved.pgpDraft.hasPrefix("From: me@example.com\r\n"))

        let headers = outerHeaders(saved.pgpDraft)
        #expect(headers.contains("To: a@example.com, b@example.com"))
        #expect(!headers.contains { $0.hasPrefix("Cc:") || $0.hasPrefix("Bcc:") })
        #expect(headers.contains("Subject: \(outerPlaceholderSubject)"))
        #expect(outerPlaceholderSubject == "[Encrypted] Email Sent by KyPost")
        #expect(saved.pgpDraft.contains("multipart/encrypted"))
        #expect(saved.pgpDraft.contains(armoredCiphertext))
    }

    /// Attack path: a hostile relay hands back "your" public key. The draft is
    /// encrypted to the key derived from the material this device unsealed,
    /// once, and signed with that material's active key.
    @Test func theDraftIsEncryptedOnlyToTheOwnKeyFromLocalMaterial() async throws {
        let crypto = RecordingDraftCrypto()
        let session = EnrollmentSession()
        session.install(.legacyArmor(Data("LOCAL-SECRET".utf8)), ifEpoch: session.epoch)
        let opener = RecordingOpener()

        let outcome = await makeSaver(opener: opener, crypto: crypto, session: session)
            .save(draft: fullDraft)

        #expect(outcome == .saved)
        #expect(opener.calls == 0)  // already held
        #expect(crypto.calls.count == 1)
        let call = try #require(crypto.calls.first)
        #expect(call.recipientKeys == [RecordingDraftCrypto.ownKey(for: Data("LOCAL-SECRET".utf8))])
        #expect(call.privateKey == Data("LOCAL-SECRET".utf8))
    }

    @Test func theKeyUnsealedForThisSaveIsTheOneUsed() async throws {
        let crypto = RecordingDraftCrypto()
        let opener = RecordingOpener(.opened(privateKey: Data("UNSEALED".utf8)))
        let outcome = await makeSaver(opener: opener, crypto: crypto).save(draft: fullDraft)

        #expect(outcome == .saved)
        #expect(opener.calls == 1)
        #expect(crypto.calls.map(\.recipientKeys) == [[RecordingDraftCrypto.ownKey(for: Data("UNSEALED".utf8))]])
        #expect(crypto.calls.map(\.privateKey) == [Data("UNSEALED".utf8)])
    }

    /// Subject, body, Cc, Bcc and attachments travel only inside the
    /// ciphertext.
    @Test func everythingButFromToAndDateIsInsideTheCiphertext() async throws {
        let crypto = RecordingDraftCrypto()
        let transport = RecordingDraftTransport()
        _ = await makeSaver(transport: transport, crypto: crypto).save(draft: fullDraft)

        let plaintext = String(decoding: try #require(crypto.calls.first).plaintext, as: UTF8.self)
        #expect(plaintext.contains("Subject: Merger plans"))
        #expect(plaintext.contains("The body nobody else may read"))
        #expect(plaintext.contains("To: a@example.com, b@example.com"))
        #expect(plaintext.contains("Cc: carol@secret.example"))
        #expect(plaintext.contains("Bcc: dave@hidden.example"))
        #expect(plaintext.contains("QVRUQUNITUVOVEJZVEVT"))

        let saved = try #require(transport.saved.first)
        let outside = saved.pgpDraft.replacingOccurrences(of: armoredCiphertext, with: "")
        for secret in ["Merger plans", "The body nobody else may read", "carol@secret.example",
                       "dave@hidden.example", "QVRUQUNITUVOVEJZVEVT"] {
            #expect(!outside.contains(secret))
            #expect(!saved.to.contains(secret))
        }
    }

    // MARK: Nothing uploaded

    @Test func aBlankAccountAddressStopsBeforeTheVault() async {
        let opener = RecordingOpener()
        let transport = RecordingDraftTransport()
        let outcome = await makeSaver(opener: opener, transport: transport, accountAddress: "  ")
            .save(draft: fullDraft)
        #expect(outcome == .noAccountAddress)
        #expect(opener.calls == 0)
        #expect(transport.saved.isEmpty)
    }

    @Test func anEmptyToStopsBeforeTheVault() async {
        let opener = RecordingOpener()
        let transport = RecordingDraftTransport()
        let outcome = await makeSaver(opener: opener, transport: transport)
            .save(draft: ClientSendDraft(to: " , ", cc: "c@example.com", body: "x"))
        #expect(outcome == .noRecipient)
        #expect(opener.calls == 0)
        #expect(transport.saved.isEmpty)
    }

    @Test func eachVaultRefusalIsItsOwnRow() async {
        let cases: [(VaultOpenOutcome, DraftSaveOutcome)] = [
            (.cancelled, .cancelled),
            (.notEnrolled, .notEnrolled),
            (.noSecureLockScreen, .noSecureLockScreen),
            (.failed("bad seal"), .unsealFailed("bad seal")),
        ]
        for (open, expected) in cases {
            let transport = RecordingDraftTransport()
            let crypto = RecordingDraftCrypto()
            let outcome = await makeSaver(opener: RecordingOpener(open), transport: transport, crypto: crypto)
                .save(draft: fullDraft)
            #expect(outcome == expected)
            #expect(transport.saved.isEmpty)
            #expect(crypto.calls.isEmpty)
        }
    }

    @Test func anEncryptionFailureUploadsNothing() async {
        for failing in ["encrypt", "ownKey"] {
            let crypto = RecordingDraftCrypto()
            if failing == "encrypt" {
                crypto.encryptError = .cannotEncrypt("no luck")
            } else {
                crypto.ownKeyError = .unusableKey
            }
            let transport = RecordingDraftTransport()
            let outcome = await makeSaver(transport: transport, crypto: crypto).save(draft: fullDraft)
            guard case .encryptFailed = outcome else {
                Issue.record("\(failing): expected encryptFailed, got \(outcome)")
                continue
            }
            #expect(transport.saved.isEmpty)
        }
    }

    /// The app locks after the unlock and before encrypting: every lock
    /// boundary clears the session, and the saver must not proceed on a key it
    /// no longer holds. `now` is read between the two, so it stands in for the
    /// lock landing there.
    @Test func losingTheMaterialBeforeEncryptingIsNotEnrolled() async {
        let session = EnrollmentSession()
        let crypto = RecordingDraftCrypto()
        let transport = RecordingDraftTransport()
        let outcome = await makeSaver(
            transport: transport,
            crypto: crypto,
            session: session,
            now: { session.clear(); return Date(timeIntervalSince1970: 1_760_000_000) }
        ).save(draft: fullDraft)
        #expect(outcome == .notEnrolled)
        #expect(crypto.calls.isEmpty)
        #expect(transport.saved.isEmpty)
    }

    /// A lock during the unlock prompt wins: the opened material is not
    /// installed, and nothing is encrypted or uploaded.
    @Test func aLockDuringTheUnlockWins() async {
        let session = EnrollmentSession()
        let transport = RecordingDraftTransport()
        let opener = LockingOpener(session: session)
        let saver = ClientEncryptedDraftSaver(
            opener: opener, transport: transport, crypto: RecordingDraftCrypto(),
            accountAddress: "me@example.com", session: session
        )
        #expect(await saver.save(draft: fullDraft) == .cancelled)
        #expect(!session.isHeld)
        #expect(transport.saved.isEmpty)
    }

    @Test func theTransportDecidesSavedOrSaveFailed() async {
        let transport = RecordingDraftTransport()
        transport.outcome = .upstreamFailure("imap down")
        #expect(await makeSaver(transport: transport).save(draft: fullDraft)
            == .saveFailed(.upstreamFailure("imap down")))

        let ok = RecordingDraftTransport()
        #expect(await makeSaver(transport: ok).save(draft: fullDraft) == .saved)
    }
}

private struct LockingOpener: VaultOpening {
    let session: EnrollmentSession
    func open() async -> VaultOpenOutcome {
        session.clear()
        return .opened(privateKey: Data("PRIVATE".utf8))
    }
}

// MARK: - The relay hop

@Suite struct ClientEncryptedDraftClientTests {
    private func client(status: Int, json: String, captured: Box<URLRequest?>) -> ClientEncryptedDraftClient {
        ClientEncryptedDraftClient(
            httpClient: stubClient(status: status, json: json) { captured.value = $0 },
            serverUrl: server,
            auth: RelayAuth(deviceId: "d", deviceSecret: "s")
        )
    }

    private let draft = ClientEncryptedDraft(to: "a@example.com", pgpDraft: "PGP/MIME")

    @Test func theBodyIsExactlyToAndPgpDraft() async throws {
        let captured = Box<URLRequest?>(nil)
        let outcome = await client(status: 200, json: #"{"ok":true}"#, captured: captured).save(draft)

        #expect(outcome == .success)
        let request = try #require(captured.value)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "\(server)/api/mail/draft")
        #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "d")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["to", "pgpDraft"])
        #expect(object["to"] as? String == "a@example.com")
        #expect(object["pgpDraft"] as? String == "PGP/MIME")
    }

    /// A 200 that does not say `ok` is not an acknowledgement.
    @Test func anUnacknowledged200IsAFailure() async {
        let captured = Box<URLRequest?>(nil)
        for json in ["{}", #"{"ok":false}"#] {
            #expect(await client(status: 200, json: json, captured: captured).save(draft)
                == .failure("Draft save was not acknowledged"))
        }
    }

    @Test func refusalsMapThroughMailOutcome() async {
        let captured = Box<URLRequest?>(nil)
        #expect(await client(status: 401, json: "", captured: captured).save(draft) == .unauthorized)
        #expect(await client(status: 502, json: "", captured: captured).save(draft)
            == MailOutcome.from(NetworkError.server(statusCode: 502)))
    }
}
