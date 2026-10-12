//
//  EncryptedMessageReaderTests.swift
//  KyPost Tests
//
//  The exit table, one test per row. These run with fakes because
//  EncryptedMessageReader has no platform imports — which is the whole reason
//  it was written that way.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Fakes

private struct FakeOpener: VaultOpening {
    let outcome: VaultOpenOutcome
    func open() async -> VaultOpenOutcome { outcome }
}

private struct FakePayloads: PgpPayloadSource {
    let result: PgpPayloadResult
    var thrown: (any Error)?
    func fetch(mailbox: String, messageId: String) async throws -> PgpPayloadResult {
        if let thrown { throw thrown }
        return result
    }
}

private struct FakeCrypto: PgpDecrypting {
    var body = Data("plaintext".utf8)
    var signature = RawSignature()
    var error: PgpCryptoError?
    var fingerprints: [String: String] = [:]
    /// Captures what `verifyDetached` was handed, so a signed-only test can
    /// assert the verdict is computed over the canonical octets and not `body`.
    let detachedInput = Box<(bytes: Data, signature: String)?>(nil)
    /// The private keys `decrypt` was handed.
    let decryptKeys = Box<[Data]>([])

    func decrypt(
        armoredCiphertext: String,
        privateKeys: [Data],
        signerKeys: [String]
    ) throws -> DecryptedMessage {
        decryptKeys.value = privateKeys
        if let error { throw error }
        return DecryptedMessage(body: body, signature: signature)
    }

    func verifyDetached(
        signedBytes: Data,
        armoredSignature: String,
        signerKeys: [String]
    ) -> RawSignature {
        detachedInput.value = (signedBytes, armoredSignature)
        return signature
    }

    func fingerprint(ofArmoredPublicKey key: String) -> String? { fingerprints[key] }
}

private let mimeBody = Data("Content-Type: text/plain\r\n\r\nhello\r\n".utf8)

private func makeReader(
    opener: VaultOpenOutcome = .opened(privateKey: Data("KEY".utf8)),
    payload: PgpPayloadResult = .success(PgpPayload(encryptedPayload: "CIPHERTEXT")),
    crypto: FakeCrypto = FakeCrypto(body: mimeBody),
    thrown: (any Error)? = nil,
    pins: RecipientPinSnapshot = .none,
    session: EnrollmentSession
) -> EncryptedMessageReader {
    EncryptedMessageReader(
        opener: FakeOpener(outcome: opener),
        payloads: FakePayloads(result: payload, thrown: thrown),
        crypto: crypto,
        pins: pins,
        session: session
    )
}

/// A session per test. `EnrollmentSession.shared` is process-wide by design,
/// and tests that shared it would leak a held key into each other.
private func freshSession() -> EnrollmentSession { EnrollmentSession() }

// MARK: - Tests

@Suite(.serialized) struct EncryptedMessageReaderTests {

    /// The automatic attempt when a screen opens must not raise a prompt. Only
    /// a deliberate Decrypt may do that.
    @Test func anAutomaticAttemptWithNoHeldKeyAsksForUnlockRatherThanPrompting() async {
        let reader = makeReader(opener: .cancelled, session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: false
        )
        #expect(outcome == .needsUnlock)
    }

    /// Dismissing a sheet you raised is not an error, and the screen goes back
    /// to offering Decrypt.
    @Test func cancellingTheUnlockIsNotAnError() async {
        let reader = makeReader(opener: .cancelled, session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        #expect(outcome == .cancelled)
        #expect(!readOutcomeAllowsRetry(outcome))
    }

    @Test func notEnrolledIsItsOwnRow() async {
        let reader = makeReader(opener: .notEnrolled, session: freshSession())
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .notEnrolled
        )
    }

    @Test func noSecureLockScreenIsItsOwnRow() async {
        let reader = makeReader(opener: .noSecureLockScreen, session: freshSession())
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .noSecureLockScreen
        )
    }

    @Test func anUnsealFailureCarriesItsMessage() async {
        let reader = makeReader(opener: .failed("enclave busy"), session: freshSession())
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .unsealFailed("enclave busy")
        )
    }

    @Test func tooLargeIsItsOwnRow() async {
        let reader = makeReader(payload: .tooLarge, session: freshSession())
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .tooLarge
        )
    }

    @Test func notClientProtectedIsItsOwnRow() async {
        let reader = makeReader(payload: .notClientProtected, session: freshSession())
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .notClientProtected
        )
    }

    /// Terminal, and the UI must not offer Retry: the server has the message
    /// and it carries no OpenPGP payload, so retrying cannot change it.
    @Test func noEncryptedContentIsTerminalAndNotRetryable() async {
        let reader = makeReader(payload: .noPayload, session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        #expect(outcome == .noEncryptedContent)
        #expect(!readOutcomeAllowsRetry(outcome))
    }

    /// Unlike the row above, a transport failure is worth retrying.
    @Test func aFetchFailureIsRetryable() async {
        let reader = makeReader(payload: .failed("offline"), session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        #expect(outcome == .fetchFailed("offline"))
        #expect(readOutcomeAllowsRetry(outcome))
    }

    @Test func aThrownFetchIsAFetchFailureRatherThanACrash() async {
        struct Boom: Error {}
        let reader = makeReader(thrown: Boom(), session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        if case .fetchFailed = outcome {} else {
            Issue.record("expected fetchFailed, got \(outcome)")
        }
    }

    @Test func aDecryptFailureSaysWhichKindItWas() async {
        let reader = makeReader(
            crypto: FakeCrypto(error: .cannotDecrypt), session: freshSession()
        )
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .decryptFailed("this message is not encrypted to a key on this device")
        )
    }

    /// One message failing says nothing about the held key, and clearing would
    /// re-prompt for every later message.
    @Test func aDecryptFailureDoesNotDropTheHeldKey() async {
        let session = freshSession()
        let reader = makeReader(crypto: FakeCrypto(error: .cannotDecrypt), session: session)
        _ = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        #expect(session.isHeld)
    }

    /// The size cap surfaces as its own row even when it is the crypto layer
    /// that spots it, not the fetch.
    @Test func aZipBombFoundDuringDecryptionIsTooLarge() async {
        let reader = makeReader(crypto: FakeCrypto(error: .tooLarge), session: freshSession())
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .tooLarge
        )
    }

    @Test func aBodyThatWillNotParseIsADecryptFailureRatherThanAnEmptyPage() async {
        let reader = makeReader(
            crypto: FakeCrypto(body: Data()), session: freshSession()
        )
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .decryptFailed("this message could not be read once decrypted")
        )
    }

    // MARK: - The happy path and what it reports

    @Test func aDecryptedMessageCarriesItsBodyAndResolvedSender() async throws {
        let payload = PgpPayload(
            encryptedPayload: "CIPHERTEXT",
            resolvedSender: "bob@example.com",
            rawSender: "Bob (Eve <eve@evil>) <bob@example.com>"
        )
        let reader = makeReader(payload: .success(payload), session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: payload.rawSender, unlockIfNeeded: true
        )
        guard case .decrypted(let body, _, let resolvedSender) = outcome else {
            Issue.record("expected decrypted, got \(outcome)")
            return
        }
        #expect(body.plain?.contains("hello") == true)
        // The verdict is about what the SERVER resolved, never the raw From.
        #expect(resolvedSender == "bob@example.com")
    }

    /// A held key means no prompt, so a second read does not re-authenticate.
    @Test func aHeldKeySkipsTheUnlockEntirely() async {
        let session = freshSession()
        session.put(armoredKey: "ALREADY-HELD")
        // An opener that would fail if it were consulted at all.
        let reader = makeReader(opener: .failed("should not be called"), session: session)
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: false
        )
        if case .decrypted = outcome {} else {
            Issue.record("expected decrypted without unlocking, got \(outcome)")
        }
    }

    /// A conflicted key carries no key material and must never be offered to a
    /// signature check — but it stays in `signerKeys` so the verdict can be
    /// `.keyChanged` rather than a silent "unknown signer".
    @Test func aConflictedKeyYieldsKeyChanged() async {
        let payload = PgpPayload(
            encryptedPayload: "CIPHERTEXT",
            signerKeys: [SignerKey(publicKey: "", conflict: true)]
        )
        let crypto = FakeCrypto(
            body: mimeBody,
            signature: RawSignature(present: true, valid: true, signerFingerprint: "FPR1")
        )
        let reader = makeReader(payload: .success(payload), crypto: crypto, session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        guard case .decrypted(_, let signature, _) = outcome else {
            Issue.record("expected decrypted, got \(outcome)")
            return
        }
        #expect(signature == .keyChanged)
    }

    @Test func aVerifiedSignatureReachesTheVerdict() async {
        let payload = PgpPayload(
            encryptedPayload: "CIPHERTEXT",
            signerKeys: [SignerKey(publicKey: "k", verified: true)]
        )
        let crypto = FakeCrypto(
            body: mimeBody,
            signature: RawSignature(present: true, valid: true, signerFingerprint: "FPR1"),
            fingerprints: ["k": "FPR1"]
        )
        let reader = makeReader(payload: .success(payload), crypto: crypto, session: freshSession())
        guard case .decrypted(_, let signature, _) = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        ) else {
            Issue.record("expected decrypted")
            return
        }
        #expect(signature == .verifiedConfirmed)
    }

    // MARK: - The signed-but-not-encrypted path

    /// The heart of the signed-only fix: the verdict is computed over the
    /// verbatim signed octets (`signedPartBase64`), never over `body`. A body
    /// that reads the same but differs by a byte would fail a byte-exact
    /// detached check and falsely accuse a real correspondent.
    @Test func aSignedOnlyMessageVerifiesOverTheCanonicalOctetsNotTheBody() async {
        let payload = PgpPayload(
            signaturePayload: "-----BEGIN PGP SIGNATURE-----",
            body: "a different render the signature must NOT be checked against",
            signedPartBase64: mimeBody.base64EncodedString(),
            signerKeys: [SignerKey(publicKey: "k", verified: true)],
            resolvedSender: "bob@example.com"
        )
        let crypto = FakeCrypto(
            signature: RawSignature(present: true, valid: true, signerFingerprint: "FPR1"),
            fingerprints: ["k": "FPR1"]
        )
        let reader = makeReader(payload: .success(payload), crypto: crypto, session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        guard case .decrypted(let body, let signature, let resolvedSender) = outcome else {
            Issue.record("expected decrypted, got \(outcome)")
            return
        }
        // Rendered from the signed part, not the divergent `body`.
        #expect(body.plain?.contains("hello") == true)
        #expect(signature == .verifiedConfirmed)
        #expect(resolvedSender == "bob@example.com")
        // And what was actually handed to the verifier were those exact octets.
        #expect(crypto.detachedInput.value?.bytes == mimeBody)
        #expect(crypto.detachedInput.value?.signature == "-----BEGIN PGP SIGNATURE-----")
    }

    /// A signed-only message from a sender with no saved key reads as unknown —
    /// "signed by a key you haven't saved" — which is information, not an alarm.
    @Test func aSignedOnlyMessageFromAnUnsavedSenderReadsAsUnknown() async {
        let payload = PgpPayload(
            signaturePayload: "SIG",
            signedPartBase64: mimeBody.base64EncodedString()
        )
        // What GopenPGP returns with no offered key: present, not valid.
        let crypto = FakeCrypto(signature: RawSignature(present: true))
        let reader = makeReader(payload: .success(payload), crypto: crypto, session: freshSession())
        guard case .decrypted(_, let signature, _) = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        ) else {
            Issue.record("expected decrypted")
            return
        }
        #expect(signature == .signerUnknown)
    }

    /// When the server could not re-fetch the raw signed part it leaves `body`
    /// populated and ships an empty `signedPartBase64`. Show the readable body,
    /// but claim nothing about a signature that cannot be checked.
    @Test func aSignedOnlyMessageWithNoVerifiablePartShowsTheBodyWithoutAVerdict() async {
        let payload = PgpPayload(
            signaturePayload: "",
            body: "readable but unverifiable",
            signedPartBase64: "",
            resolvedSender: "bob@example.com"
        )
        let reader = makeReader(payload: .success(payload), session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        guard case .decrypted(let body, let signature, _) = outcome else {
            Issue.record("expected decrypted, got \(outcome)")
            return
        }
        #expect(body.plain == "readable but unverifiable")
        #expect(signature == .none)
    }

    /// A signed-only message with neither a verifiable part nor a readable body
    /// is terminal, and — like `noEncryptedContent` — must not offer Retry.
    @Test func aSignedOnlyMessageWithNothingReadableIsTerminal() async {
        let payload = PgpPayload(signaturePayload: "", body: "", signedPartBase64: "")
        let reader = makeReader(payload: .success(payload), session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        #expect(outcome == .noEncryptedContent)
        #expect(!readOutcomeAllowsRetry(outcome))
    }
}

// MARK: - Session

/// Device-envelope v3: a vault holding a keyring decrypts with every member.
@Suite(.serialized) struct EncryptedMessageReaderKeyringTests {
    /// Mail encrypted to a retired key must still open: the reader offers the
    /// whole ring, not just the active key.
    @Test func anOpenedKeyringOffersEveryMemberToDecrypt() async throws {
        let ring = try #require(parsePgpKeyring(
            V3Fixtures.ringBytes,
            expectedActiveFingerprint: V3Fixtures.active,
            inspector: GopenPGPCrypto()
        ))
        let crypto = FakeCrypto(body: mimeBody)
        let session = freshSession()
        let reader = makeReader(opener: .opened(.keyring(ring)), crypto: crypto, session: session)
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        guard case .decrypted = outcome else {
            Issue.record("expected decrypted, got \(outcome)"); return
        }
        #expect(crypto.decryptKeys.value == ring.members.map(\.armor))
        #expect(session.materialGeneration == 2)
    }

    /// End to end with the real library: the fixture's historical ciphertext,
    /// encrypted to the retired member, opens through the reader.
    @Test func aRetiredKeyStillDecryptsOldMailThroughTheReader() async throws {
        let ring = try #require(parsePgpKeyring(
            V3Fixtures.ringBytes,
            expectedActiveFingerprint: V3Fixtures.active,
            inspector: GopenPGPCrypto()
        ))
        let ciphertext = try #require(V3Fixtures.keyringFile["ciphertext"] as? String)
        let session = freshSession()
        session.put(keyring: ring)
        let reader = EncryptedMessageReader(
            opener: FakeOpener(outcome: .notEnrolled),
            payloads: FakePayloads(result: .success(PgpPayload(encryptedPayload: ciphertext)), thrown: nil),
            crypto: GopenPGPCrypto(),
            session: session,
            mime: { DecryptedBody(html: nil, plain: String(decoding: $0, as: UTF8.self), protectedSubject: nil) }
        )
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: false
        )
        guard case .decrypted(let body, _, _) = outcome else {
            Issue.record("expected decrypted, got \(outcome)"); return
        }
        #expect(body.plain == V3Fixtures.keyringFile["plaintext"] as? String)
    }
}

@Suite(.serialized) struct EnrollmentSessionTests {
    @Test func aHeldKeyIsLentRatherThanReturned() {
        let session = EnrollmentSession()
        #expect(!session.isHeld)
        session.put(armoredKey: "SECRET")
        #expect(session.isHeld)
        session.withKey { key in
            #expect(key.map { String(decoding: $0, as: UTF8.self) } == "SECRET")
        }
    }

    @Test func clearingForgetsIt() {
        let session = EnrollmentSession()
        session.put(armoredKey: "SECRET")
        session.clear()
        #expect(!session.isHeld)
        session.withKey { #expect($0 == nil) }
    }

    /// Replacing must not strand the previous key.
    @Test func replacingAKeyDoesNotKeepTheOldOne() {
        let session = EnrollmentSession()
        session.put(armoredKey: "FIRST")
        session.put(armoredKey: "SECOND")
        session.withKey { key in
            #expect(key.map { String(decoding: $0, as: UTF8.self) } == "SECOND")
        }
    }

    /// Presence is answered without materialising the key.
    @Test func presenceDoesNotRequireACopy() {
        let session = EnrollmentSession()
        session.put(armoredKey: "SECRET")
        #expect(session.isHeld)
        session.clear()
        #expect(!session.isHeld)
    }
}

/// Local stand-in for LAContext, which cannot run headless. SecurityTests has
/// its own; that one is file-private and counts calls, neither of which these
/// tests need.
private struct AlwaysAuthenticates: DeviceAuthenticating {
    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> Bool { true }
}

// MARK: - Session boundaries

/// The invariant these protect is the one Android got wrong: the holder was
/// missed by a path that forgot to clear it, and the wipe then reported
/// "Complete" with the account's private key still in the process heap. A
/// documented rule that nothing enforces is not a rule.
@Suite(.serialized) @MainActor struct EnrollmentSessionBoundaryTests {

    @Test func engagingTheAppLockDropsTheKey() throws {
        let session = EnrollmentSession()
        session.put(armoredKey: "PRIVATE")
        let store = AppLockStore(keychain: KeychainStorage(service: scratchService()))
        try store.setLockEnabled(true)
        let manager = AppLockManager(
            store: store,
            authenticator: AlwaysAuthenticates(),
            enrollmentSession: session
        )
        manager.lock()
        #expect(!session.isHeld)
    }

    /// The clearing happens **before** the early return, so it does not depend
    /// on the app-lock feature being switched on. Someone who never enabled the
    /// lock still backgrounds the app, and the key is no less sensitive for it.
    @Test func theKeyIsDroppedEvenWhenTheAppLockIsOff() throws {
        let session = EnrollmentSession()
        session.put(armoredKey: "PRIVATE")
        let store = AppLockStore(keychain: KeychainStorage(service: scratchService()))
        try store.setLockEnabled(false)
        let manager = AppLockManager(
            store: store,
            authenticator: AlwaysAuthenticates(),
            enrollmentSession: session
        )
        manager.lock()
        #expect(!session.isHeld)
    }

    /// Already-locked is not a reason to keep it either.
    @Test func lockingTwiceStillLeavesNothingHeld() throws {
        let session = EnrollmentSession()
        let store = AppLockStore(keychain: KeychainStorage(service: scratchService()))
        try store.setLockEnabled(true)
        let manager = AppLockManager(
            store: store,
            authenticator: AlwaysAuthenticates(),
            enrollmentSession: session
        )
        manager.lock()
        session.put(armoredKey: "PRIVATE-AGAIN")
        manager.lock()
        #expect(!session.isHeld)
    }

    /// Only the policy, not the trigger: the kernel event cannot be raised
    /// from a test. What is checked is that what runs *on* pressure actually
    /// drops the key — the half that could silently stop being true.
    @Test func theMemoryPressurePolicyDropsTheKey() {
        EnrollmentSession.shared.put(armoredKey: "PRIVATE")
        #expect(EnrollmentSession.shared.isHeld)
        MemoryPressureWatch.dropSensitiveState()
        #expect(!EnrollmentSession.shared.isHeld)
    }
}

private func scratchService() -> String {
    "org.kysecurity.mail.tests.\(UUID().uuidString)"
}
