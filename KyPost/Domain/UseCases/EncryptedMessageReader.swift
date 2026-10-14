//
//  EncryptedMessageReader.swift
//  KyPost
//
//  Reads one client-protected message: unseal if needed, fetch, decrypt, bind
//  the signature, parse. Swift port of kypost-android's
//  pgp/EncryptedMessageReader.kt.
//
//  **No platform imports**, following EnrollmentCeremony — which is what lets
//  the whole exit table be an ordinary unit test with fakes rather than
//  something that needs a device, a key and a biometric prompt.
//
//  **The decrypted body is never persisted.** Not to SwiftData, not to the
//  cached body field. It is returned to the caller and lives for the life of
//  the view showing it.
//

import Foundation

/// The ciphertext source, behind a protocol so this takes no dependency on
/// URLSession, pairing credentials, or any app singleton.
protocol PgpPayloadSource: Sendable {
    func fetch(mailbox: String, messageId: String) async throws -> PgpPayloadResult
}

/// How unsealing the vault ended.
nonisolated enum VaultOpenOutcome: Equatable, Sendable {
    /// The opened material, for the caller to hold in `EnrollmentSession`.
    case opened(VaultMaterial)
    case cancelled
    case notEnrolled
    case noSecureLockScreen
    case failed(String)
}

extension VaultOpenOutcome {
    /// Legacy armor — one key, or a current-first collection.
    static func opened(privateKey: Data) -> VaultOpenOutcome {
        .opened(.legacyArmor(privateKey))
    }
}

/// Unseals the device's stored key, prompting for presence.
protocol VaultOpening: Sendable {
    func open() async -> VaultOpenOutcome
}

nonisolated struct EncryptedMessageReader: Sendable {
    private let opener: any VaultOpening
    private let payloads: any PgpPayloadSource
    private let crypto: any PgpDecrypting
    private let session: EnrollmentSession
    private let mime: @Sendable (Data) -> DecryptedBody?
    /// Keys verified on this device, read afresh on every attempt: a reader
    /// lives as long as its screen, and a pin revoked by a sync meanwhile
    /// must count from the next attempt on. Deliberately not defaulted: an
    /// empty snapshot is "no pins", and a caller that forgot to pass them
    /// would silently let the relay's key stand in for one the user verified.
    private let pins: @MainActor @Sendable () -> RecipientPinSnapshot
    /// The on-device first-seen signer history. Not defaulted, for `pins`'
    /// reason: a forgotten history would read every sender as first seen.
    private let history: any SignerKeyHistory

    init(
        opener: any VaultOpening,
        payloads: any PgpPayloadSource,
        crypto: any PgpDecrypting,
        pins: @escaping @MainActor @Sendable () -> RecipientPinSnapshot,
        history: any SignerKeyHistory,
        session: EnrollmentSession = .shared,
        mime: @escaping @Sendable (Data) -> DecryptedBody? = { PgpMimeReader.read($0) }
    ) {
        self.opener = opener
        self.payloads = payloads
        self.crypto = crypto
        self.pins = pins
        self.history = history
        self.session = session
        self.mime = mime
    }

    /// The signer keys a verdict may use and the trust this device holds for
    /// the resolved sender. Where this device pinned a key, the pin
    /// **replaces** what the server offered: an intact pin is the only key
    /// accepted; a revoked or broken one is unusable, so a signed message
    /// reads as `.keyChanged` with no fallback to the relay's key. Otherwise
    /// the relay's candidates stand, judged against this device's history.
    ///
    /// Keyed on `resolvedSender` — the server's binding — never on a parsed
    /// `From`; that parser is the one this client must not have.
    static func signerInputs(
        _ offered: [SignerKey],
        resolvedSender: String,
        pins: RecipientPinSnapshot,
        firstSeen: String?
    ) -> (keys: [SignerKey], trust: LocalSignerTrust) {
        switch pins.state(for: resolvedSender) {
        case nil:
            return (offered, .firstSeen(firstSeen))
        case .intact(let publicKey, let fingerprint):
            return (
                [SignerKey(addresses: [resolvedSender], publicKey: publicKey, source: "device")],
                .pinned(fingerprint: fingerprint)
            )
        case .revoked, .broken:
            return ([SignerKey(addresses: [resolvedSender], conflict: true)], .pinUnusable)
        }
    }

    /// - Parameters:
    ///   - sender: the sender exactly as displayed. **Display context only**,
    ///     and deliberately unread here. The binding is the server's job: it
    ///     narrows `payload.signerKeys` to the resolved sender before this
    ///     runs. Do not wire this up to filter `signerKeys` — that
    ///     reintroduces the client-side `From` parser that diverged from the
    ///     server's on 27 of 111 adversarial headers. It stays a parameter
    ///     because callers have it. The screen compares it against the
    ///     verdict's bound addresses to *add* a mismatch warning
    ///     (`signatureIdentityMismatch`); it never sets a verdict.
    ///   - unlockIfNeeded: false on the automatic attempt when a screen opens,
    ///     true when the user pressed Decrypt. This is what keeps the presence
    ///     prompt tied to a deliberate action.
    func read(
        mailbox: String,
        messageId: String,
        sender: String,
        unlockIfNeeded: Bool
    ) async -> ReadOutcome {
        if !session.isHeld {
            guard unlockIfNeeded else { return .needsUnlock }
            switch await opener.open() {
            case .opened(let material):
                session.install(material)
            case .cancelled: return .cancelled
            case .notEnrolled: return .notEnrolled
            case .noSecureLockScreen: return .noSecureLockScreen
            case .failed(let message): return .unsealFailed(message)
            }
        }

        var payload: PgpPayload
        do {
            switch try await payloads.fetch(mailbox: mailbox, messageId: messageId) {
            case .success(let fetched): payload = fetched
            case .tooLarge: return .tooLarge
            case .notClientProtected: return .notClientProtected
            case .noPayload: return .noEncryptedContent
            case .failed(let message): return .fetchFailed(message)
            }
        } catch {
            return .fetchFailed(error.localizedDescription)
        }

        let pinSnapshot = await pins()
        let firstSeen = payload.resolvedSender.isEmpty
            ? nil
            : await history.firstSeenFingerprint(for: payload.resolvedSender)
        let inputs = Self.signerInputs(
            payload.signerKeys,
            resolvedSender: payload.resolvedSender,
            pins: pinSnapshot,
            firstSeen: firstSeen
        )
        payload.signerKeys = inputs.keys
        let trust = inputs.trust

        guard !payload.encryptedPayload.isEmpty else {
            // A signed-but-not-encrypted message: readable content in the
            // clear, a detached signature, nothing to decrypt.
            return await signedOnly(payload, trust: trust)
        }

        // Conflicted entries carry no key material and must never be offered
        // to a signature check. They stay in `payload.signerKeys` so
        // `signatureState` can still report `.keyChanged` from them.
        //
        // This filter cannot change today's outcome: `signatureState` returns
        // `.keyChanged` for any signed message the moment any entry conflicts,
        // before it looks at what was offered. It stays as defence against one
        // plausible future edit — reordering `signatureState` so conflict no
        // longer short-circuits first. Do not remove it as dead code without
        // re-checking that precedence.
        let offeredKeys = payload.signerKeys.filter { !$0.conflict }.map(\.publicKey)

        let decrypted: DecryptedMessage
        do {
            // Every held key, current and retired: mail encrypted to a key the
            // account has since rotated away from must still open.
            decrypted = try session.withMaterial { material in
                guard let material else { throw PgpCryptoError.unavailable }
                return try crypto.decrypt(
                    armoredCiphertext: payload.encryptedPayload,
                    privateKeys: material.decryptionKeys,
                    signerKeys: offeredKeys
                )
            }
        } catch PgpCryptoError.unavailable {
            // The session was cleared between the check above and here — the
            // app can lock mid-read. Re-read rather than trusting the branch.
            return .needsUnlock
        } catch PgpCryptoError.tooLarge {
            return .tooLarge
        } catch {
            // Deliberately does **not** clear the session: one message failing
            // says nothing about the held key, and clearing would re-prompt
            // for every later message.
            return .decryptFailed(Self.message(for: error))
        }

        guard let body = mime(decrypted.body) else {
            return .decryptFailed("this message could not be read once decrypted")
        }

        // No packet signature: say which kind of absence. A nested MIME
        // signature is detected, not verified — checking it would mean
        // verifying the exact signed-part bytes, which this reader does not
        // do — so it reads "not checked", never "not signed".
        guard decrypted.signature.present else {
            return .decrypted(body: body, verdict: SignatureVerdict(
                state: body.hasDetachedSignature ? .unchecked : .unsigned,
                resolvedSender: payload.resolvedSender
            ))
        }
        return .decrypted(
            body: body,
            verdict: await verdict(decrypted.signature, payload: payload, trust: trust)
        )
    }

    /// The verdict for a present signature, and the history it starts.
    ///
    /// The only write to the first-seen history: a valid signature by a key
    /// this device has no pin or history for, and only when that key's own
    /// User IDs name the resolved sender — so a key the relay attaches to an
    /// address it does not even claim never becomes that address's key.
    private func verdict(
        _ signature: RawSignature,
        payload: PgpPayload,
        trust: LocalSignerTrust
    ) async -> SignatureVerdict {
        let state = signatureState(
            signature: signature,
            signerKeys: payload.signerKeys,
            trust: trust,
            fingerprint: crypto.fingerprint(ofArmoredPublicKey:)
        )
        let signed = signature.signerFingerprint
        let signingKey = signed.isEmpty ? nil : payload.signerKeys.first { key in
            guard !key.conflict, let candidate = crypto.fingerprint(ofArmoredPublicKey: key.publicKey)
            else { return false }
            return candidate.caseInsensitiveCompare(signed) == .orderedSame
        }
        let keyAddresses = signingKey.map { crypto.userIDAddresses(ofArmoredPublicKey: $0.publicKey) } ?? []

        let sender = RecipientPinStore.normalized(payload.resolvedSender)
        if state == .signerNotConfirmed, !sender.isEmpty, keyAddresses.contains(sender) {
            await history.recordFirstSeen(signed, for: sender)
        }
        return SignatureVerdict(
            state: state,
            resolvedSender: payload.resolvedSender,
            keyAddresses: keyAddresses
        )
    }

    /// A signed-but-not-encrypted message: nothing to decrypt, but a detached
    /// signature still to check.
    ///
    /// Verification runs over `signedPartBase64` — the verbatim transmitted
    /// octets the server re-fetched raw — and **never** over `body`. `body` is
    /// the server's transfer-decoded render: it reads identically to a human
    /// but can differ from the signed bytes by a newline, and a byte-exact
    /// detached check over it would falsely accuse a real correspondent. That
    /// is precisely the trap the server's own signedOnlyParts avoids by
    /// shipping the raw part.
    private func signedOnly(_ payload: PgpPayload, trust: LocalSignerTrust) async -> ReadOutcome {
        guard let signedPart = Data(base64Encoded: payload.signedPartBase64),
              !signedPart.isEmpty,
              !payload.signaturePayload.isEmpty else {
            // The server could not produce verifiable octets (its raw re-fetch
            // failed), so it left the readable `body` populated instead. Show
            // it, but claim nothing about a signature that cannot be checked —
            // the honest could-not-check state, neither a false accusation nor
            // a failure. With nothing readable either, it is terminal.
            guard !payload.body.isEmpty else { return .noEncryptedContent }
            return .decrypted(
                body: DecryptedBody(html: nil, plain: payload.body, protectedSubject: nil),
                verdict: SignatureVerdict(resolvedSender: payload.resolvedSender)
            )
        }

        guard let body = mime(signedPart) else {
            return .decryptFailed("this message could not be read")
        }

        // Conflicted entries carry no key material and must never be offered to
        // a signature check; they stay in `signerKeys` so the verdict can be
        // `.keyChanged`. Same reasoning as the encrypted path above.
        let offeredKeys = payload.signerKeys.filter { !$0.conflict }.map(\.publicKey)
        let signature = crypto.verifyDetached(
            signedBytes: signedPart,
            armoredSignature: payload.signaturePayload,
            signerKeys: offeredKeys
        )
        return .decrypted(body: body, verdict: await verdict(signature, payload: payload, trust: trust))
    }

    /// Sentences for the exit table, not a forwarded library string.
    private static func message(for error: Error) -> String {
        switch error {
        case PgpCryptoError.unusableKey:
            "the key on this device could not be read"
        case PgpCryptoError.cannotDecrypt:
            "this message is not encrypted to a key on this device"
        default:
            "this message could not be decrypted"
        }
    }
}
