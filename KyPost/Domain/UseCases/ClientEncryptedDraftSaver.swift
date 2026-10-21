//
//  ClientEncryptedDraftSaver.swift
//  KyPost
//
//  Saves one draft to Drafts for a client-custody account: encrypted and
//  signed on this device to the account's own key, so the relay stores only
//  ciphertext. Swift port of kypost-android's pgp/ClientEncryptedDraftSaver.kt.
//
//  **No platform imports**, like ClientEncryptedSender, so the whole exit
//  table is an ordinary unit test with fakes.
//
//  Nothing here decides whether the account *may* save this way;
//  `draftHandoffMode` does that.
//

import Foundation

/// The body of `POST /api/mail/draft`: the To header for the relay's listing,
/// and the PGP/MIME message. Nothing else of the draft leaves the device.
nonisolated struct ClientEncryptedDraft: Equatable, Sendable {
    var to: String
    var pgpDraft: String
}

/// The relay hop. `.success` only when the relay acknowledged the save.
protocol ClientEncryptedDraftTransport: Sendable {
    func save(_ draft: ClientEncryptedDraft) async -> MailOutcome
}

/// Every way a draft save can end.
nonisolated enum DraftSaveOutcome: Equatable, Sendable {
    case saved
    /// **Not an error.** The user dismissed a prompt they raised.
    case cancelled
    case notEnrolled
    case noSecureLockScreen
    /// No mail account configured, so no valid `From` can be built.
    case noAccountAddress
    /// The draft names nobody in To, which the relay's Drafts listing needs.
    case noRecipient
    case unsealFailed(String)
    case encryptFailed(String)
    case saveFailed(MailOutcome)
}

nonisolated struct ClientEncryptedDraftSaver: Sendable {
    private let opener: any VaultOpening
    private let transport: any ClientEncryptedDraftTransport
    private let crypto: any PgpEncrypting
    private let session: EnrollmentSession
    /// Bootstrap's `suggestedUserIDs[0]`, the draft's `From`.
    private let accountAddress: String
    private let now: @Sendable () -> Date
    private let boundaryToken: @Sendable () -> String

    init(
        opener: any VaultOpening,
        transport: any ClientEncryptedDraftTransport,
        crypto: any PgpEncrypting,
        accountAddress: String,
        session: EnrollmentSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        boundaryToken: @escaping @Sendable () -> String = PgpMimeWriter.randomBoundaryToken
    ) {
        self.opener = opener
        self.transport = transport
        self.crypto = crypto
        self.accountAddress = accountAddress
        self.session = session
        self.now = now
        self.boundaryToken = boundaryToken
    }

    func save(draft: ClientSendDraft) async -> DraftSaveOutcome {
        let from = accountAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty else { return .noAccountAddress }

        let fields = splitRecipientFields(to: draft.to, cc: draft.cc, bcc: draft.bcc)
        guard !fields.to.isEmpty else { return .noRecipient }

        if !session.isHeld {
            // As in the sender: a lock during the open wins.
            let epoch = session.epoch
            switch await opener.open() {
            case .opened(let material):
                guard session.install(material, ifEpoch: epoch) else { return .cancelled }
            case .cancelled: return .cancelled
            case .notEnrolled: return .notEnrolled
            case .noSecureLockScreen: return .noSecureLockScreen
            case .failed(let message): return .unsealFailed(message)
            }
        }

        // Cc and Bcc ride only inside the ciphertext, as protected headers.
        // The outer envelope names To alone: `OutgoingEnvelope` has no Bcc
        // field, and its `cc` is empty for a draft.
        let contentType = draft.mode.lowercased() == "plain" ? "text/plain" : "text/html"
        let protectedContent = Data(PgpMimeWriter.buildProtectedContent(
            contentType: "\(contentType); charset=utf-8",
            body: draft.body,
            subject: draft.subject,
            to: fields.to,
            cc: fields.cc,
            bcc: fields.bcc,
            attachments: draft.attachments,
            boundaryToken: boundaryToken
        ).utf8)
        let envelope = OutgoingEnvelope(
            from: from, to: fields.to, cc: [], date: PgpMimeWriter.rfc5322Date(now())
        )

        enum Prepared {
            case ready(String)
            case stop(DraftSaveOutcome)
        }

        // Re-read rather than trusting the branch above: every lock boundary
        // clears the session. The draft is encrypted to the public half of the
        // key just unsealed, never to anything the server supplied — a hostile
        // relay handing back "your" key would otherwise read every draft.
        // Built inside the lock; the network hop happens after, outside it.
        let prepared: Prepared = session.withMaterial { material in
            guard let material else { return .stop(.notEnrolled) }
            do {
                let ownKey = try crypto.ownPublicKey(privateKey: material.signingKey)
                let armored = try crypto.encryptAndSign(
                    plaintext: protectedContent,
                    recipientKeys: [ownKey],
                    privateKey: material.signingKey
                )
                return .ready(PgpMimeWriter.wrapAsPgpMime(
                    envelope: envelope, armoredMessage: armored, boundaryToken: boundaryToken
                ))
            } catch {
                return .stop(.encryptFailed(Self.message(for: error)))
            }
        }

        let pgpDraft: String
        switch prepared {
        case .ready(let built): pgpDraft = built
        case .stop(let outcome): return outcome
        }

        let outcome = await transport.save(ClientEncryptedDraft(
            to: fields.to.joined(separator: ", "), pgpDraft: pgpDraft
        ))
        return outcome == .success ? .saved : .saveFailed(outcome)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case PgpCryptoError.unusableKey:
            "the key on this device could not be read"
        case let PgpCryptoError.cannotEncrypt(detail):
            detail
        default:
            "this draft could not be encrypted"
        }
    }
}
