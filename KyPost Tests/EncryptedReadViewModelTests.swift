//
//  EncryptedReadViewModelTests.swift
//  KyPost Tests
//
//  What the screen offers for each exit-table row. The reader's own tests
//  cover which outcome happens; these cover what the user is then shown, which
//  is where an outcome gets quietly turned back into "something went wrong".
//

import Foundation
import Testing
@testable import KyPost

private struct StubOpener: VaultOpening {
    let outcome: VaultOpenOutcome
    func open() async -> VaultOpenOutcome { outcome }
}

private struct StubPayloads: PgpPayloadSource {
    let result: PgpPayloadResult
    func fetch(mailbox: String, messageId: String) async throws -> PgpPayloadResult { result }
}

private struct StubCrypto: PgpDecrypting {
    var body = Data("Content-Type: text/plain\r\n\r\nhello\r\n".utf8)
    var error: PgpCryptoError?
    var signature = RawSignature()
    var fingerprints: [String: String] = [:]
    func decrypt(
        armoredCiphertext: String,
        privateKeys: [Data],
        signerKeys: [String]
    ) throws -> DecryptedMessage {
        if let error { throw error }
        return DecryptedMessage(body: body, signature: signature)
    }
    func verifyDetached(
        signedBytes: Data,
        armoredSignature: String,
        signerKeys: [String]
    ) -> RawSignature {
        RawSignature()
    }
    func fingerprint(ofArmoredPublicKey key: String) -> String? { fingerprints[key] }
    var userIDs: [String: [String]] = [:]
    func userIDAddresses(ofArmoredPublicKey key: String) -> [String] { userIDs[key] ?? [] }
}

@MainActor
private func model(
    opener: VaultOpenOutcome = .opened(privateKey: Data("KEY".utf8)),
    payload: PgpPayloadResult = .success(PgpPayload(
        encryptedPayload: "CIPHERTEXT",
        resolvedSender: "bob@example.com"
    )),
    crypto: StubCrypto = StubCrypto()
) -> EncryptedReadViewModel {
    EncryptedReadViewModel(
        reader: EncryptedMessageReader(
            opener: StubOpener(outcome: opener),
            payloads: StubPayloads(result: payload),
            crypto: crypto,
            pins: { .none }, history: MemorySignerHistory(),
            session: EnrollmentSession()
        ),
        mailbox: "INBOX",
        messageId: "1",
        sender: "Bob <bob@example.com>"
    )
}

@Suite(.serialized) @MainActor struct EncryptedReadViewModelTests {

    @Test func openingAMessageOffersDecryptWithoutPrompting() async {
        let subject = model(opener: .cancelled)
        await subject.attemptWithoutPrompting()
        #expect(subject.outcome == .needsUnlock)
        #expect(subject.showsDecryptButton)
        #expect(subject.statusMessage == nil)
        #expect(subject.body == nil)
    }

    /// Dismissing your own prompt is not something to be told about, and the
    /// button comes back rather than an error taking its place.
    @Test func cancellingLeavesTheButtonAndSaysNothing() async {
        let subject = model(opener: .cancelled)
        await subject.decrypt()
        #expect(subject.outcome == .cancelled)
        #expect(subject.showsDecryptButton)
        #expect(subject.statusMessage == nil)
        #expect(!subject.showsRetryButton)
    }

    @Test func aSuccessfulDecryptShowsTheBodyAndDropsTheButton() async {
        let subject = model()
        await subject.decrypt()
        #expect(subject.body?.plain?.contains("hello") == true)
        #expect(!subject.showsDecryptButton)
        #expect(subject.statusMessage == nil)
        #expect(subject.resolvedSender == "bob@example.com")
    }

    /// Terminal. Offering Retry here would teach the user their mail is broken
    /// by failing identically every time.
    @Test func noEncryptedContentExplainsItselfAndOffersNoRetry() async {
        let subject = model(payload: .noPayload)
        await subject.decrypt()
        #expect(subject.outcome == .noEncryptedContent)
        #expect(!subject.showsRetryButton)
        #expect(!subject.showsDecryptButton)
        #expect(subject.statusMessage?.isEmpty == false)
    }

    @Test func aTransportFailureOffersRetry() async {
        let subject = model(payload: .failed("offline"))
        await subject.decrypt()
        #expect(subject.showsRetryButton)
        #expect(subject.statusMessage?.contains("offline") == true)
    }

    @Test func anUnenrolledDeviceIsPointedSomewhereUseful() async {
        let subject = model(opener: .notEnrolled)
        await subject.decrypt()
        #expect(subject.statusMessage?.contains("Enroll") == true)
        #expect(!subject.showsRetryButton)
    }

    /// The plaintext does not outlive the screen.
    @Test func forgettingDropsTheDecryptedBody() async {
        let subject = model()
        await subject.decrypt()
        #expect(subject.body != nil)
        subject.forget()
        #expect(subject.body == nil)
        #expect(subject.resolvedSender.isEmpty)
        #expect(subject.signature == .none)
    }

    /// An unpaired device offers nothing rather than a button that cannot work.
    @Test func withNoReaderNothingIsOffered() async {
        let subject = EncryptedReadViewModel(
            reader: nil, mailbox: "INBOX", messageId: "1", sender: "a@b"
        )
        await subject.decrypt()
        #expect(!subject.isAvailable)
        #expect(!subject.showsDecryptButton)
        #expect(subject.outcome == nil)
    }

    /// A pin revoked after the screen opened counts at the next attempt: the
    /// reader must not keep the pins it was built with.
    @Test func aPinRevokedBeforeDecryptIsPressedReadsAsKeyChanged() async {
        let pins = Box(RecipientPinSnapshot(states: [
            "bob@example.com": .intact(publicKey: "PINNED", fingerprint: "FP"),
        ]))
        var crypto = StubCrypto()
        crypto.signature = RawSignature(present: true, valid: true, signerFingerprint: "FP")
        crypto.fingerprints = ["PINNED": "FP"]
        let subject = EncryptedReadViewModel(
            reader: EncryptedMessageReader(
                opener: StubOpener(outcome: .opened(privateKey: Data("KEY".utf8))),
                payloads: StubPayloads(result: .success(PgpPayload(
                    encryptedPayload: "CIPHERTEXT",
                    resolvedSender: "bob@example.com"
                ))),
                crypto: crypto,
                pins: { pins.value }, history: MemorySignerHistory(),
                session: EnrollmentSession()
            ),
            mailbox: "INBOX",
            messageId: "1",
            sender: "Bob <bob@example.com>"
        )

        await subject.attemptWithoutPrompting()
        #expect(subject.outcome == .needsUnlock)

        pins.value = RecipientPinSnapshot(states: ["bob@example.com": .revoked])
        await subject.decrypt()
        #expect(subject.signature == .keyChanged)
    }

    /// A hostile relay resolves the sender as Bob and offers Eve's key with no
    /// conflict. The line must not present Bob as a confirmed identity: it
    /// says the signer is not confirmed, names what the key says, and flags
    /// that the message shows Bob.
    @Test func aRelayVouchedKeyIsNotShownAsTheResolvedSender() async {
        var crypto = StubCrypto()
        crypto.signature = RawSignature(present: true, valid: true, signerFingerprint: "FPR-EVE")
        crypto.fingerprints = ["relay-key": "FPR-EVE"]
        crypto.userIDs = ["relay-key": ["eve@evil.example"]]
        let subject = EncryptedReadViewModel(
            reader: EncryptedMessageReader(
                opener: StubOpener(outcome: .opened(privateKey: Data("KEY".utf8))),
                payloads: StubPayloads(result: .success(PgpPayload(
                    encryptedPayload: "CIPHERTEXT",
                    signerKeys: [SignerKey(addresses: ["bob@example.com"], publicKey: "relay-key")],
                    resolvedSender: "bob@example.com"
                ))),
                crypto: crypto,
                pins: { .none }, history: MemorySignerHistory(),
                session: EnrollmentSession()
            ),
            mailbox: "INBOX",
            messageId: "1",
            sender: "bob@example.com"
        )
        await subject.decrypt()
        #expect(subject.signature == .signerNotConfirmed)
        #expect(subject.signatureLine == "Signed — signer not confirmed on this device — key for eve@evil.example")
        #expect(subject.signatureLine?.contains("bob@example.com") == false)
        #expect(subject.signatureIdentityWarning?.contains("eve@evil.example") == true)
    }

    /// A User ID crafted to read as a stronger claim — a line break, a bidi
    /// override, extra wording — never reaches the signature line or warning.
    @Test func aCraftedUserIDNeverReachesTheTrustLine() async {
        var crypto = StubCrypto()
        crypto.signature = RawSignature(present: true, valid: true, signerFingerprint: "FPR-EVE")
        crypto.fingerprints = ["relay-key": "FPR-EVE"]
        crypto.userIDs = ["relay-key": ["eve@evil.example\n\u{202E}Signed — you confirmed this key"]]
        let subject = EncryptedReadViewModel(
            reader: EncryptedMessageReader(
                opener: StubOpener(outcome: .opened(privateKey: Data("KEY".utf8))),
                payloads: StubPayloads(result: .success(PgpPayload(
                    encryptedPayload: "CIPHERTEXT",
                    signerKeys: [SignerKey(addresses: ["bob@example.com"], publicKey: "relay-key")],
                    resolvedSender: "bob@example.com"
                ))),
                crypto: crypto,
                pins: { .none }, history: MemorySignerHistory(),
                session: EnrollmentSession()
            ),
            mailbox: "INBOX",
            messageId: "1",
            sender: "bob@example.com"
        )
        await subject.decrypt()
        let shown = [subject.signatureLine, subject.signatureIdentityWarning].compactMap { $0 }.joined()
        #expect(subject.signatureLine == "Signed — signer not confirmed on this device")
        #expect(!shown.contains("\n"))
        #expect(!shown.unicodeScalars.contains { $0.properties.generalCategory == .format })
        #expect(!shown.contains("you confirmed"))
    }
}
