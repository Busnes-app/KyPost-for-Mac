//
//  PgpPayload.swift
//  KyPost
//
//  What `GET /api/mail/pgp-payload` returns, and every way reading a
//  client-protected message can end. Swift port of kypost-android's
//  pgp/PgpPayloadClient.kt and the ReadOutcome half of
//  pgp/EncryptedMessageReader.kt.
//

import Foundation

/// One client-protected message's OpenPGP material.
nonisolated struct PgpPayload: Equatable, Sendable {
    var encryptedPayload: String = ""
    var signaturePayload: String = ""
    /// The display body. On the signed-but-not-encrypted path it is the
    /// server's transfer-decoded *render*, kept only as a fallback for when the
    /// verbatim signed part is unavailable — never as the thing a signature is
    /// checked against.
    var body: String = ""

    /// The verbatim transmitted octets of a signed-but-not-encrypted message,
    /// base64-encoded — the exact bytes the detached `signaturePayload` covers.
    ///
    /// A detached-signature check is byte-exact, and `body` above is a decoded
    /// render that reads identically to a human but can differ by a byte, so
    /// verification must run over THIS and never over `body`. Empty for an
    /// encrypted message, and empty on the signed-only path when the server
    /// could not re-fetch the raw part.
    var signedPartBase64: String = ""

    /// The sender's candidate keys, **already narrowed to the sender the
    /// server resolved**.
    ///
    /// Do not re-narrow these, and above all do not parse a `From` header here
    /// to do it. Android shipped a client-side parser for exactly that and a
    /// differential harness found it disagreeing with the server's on 27 of
    /// 111 adversarial headers — including RFC 5322 comments, where
    /// `Bob (Eve <eve@evil>) <bob@x>` is valid, the server binds `bob@x`, and
    /// the client bound `eve@evil`. That let any contact forge a verified
    /// badge for anyone.
    var signerKeys: [SignerKey] = []

    /// The addr-spec the verdict is about, as the server resolved it.
    ///
    /// Render this wherever a verdict is shown, never the raw `From`: the two
    /// are separable by an attacker, and a badge shown next to an address the
    /// verdict was not about is a lie regardless of how correct the
    /// cryptography underneath it was. Empty when the server resolved none.
    var resolvedSender: String = ""

    /// Display only. Deliberately never feeds a binding decision.
    var rawSender: String = ""
}

/// How a payload fetch ended.
nonisolated enum PgpPayloadResult: Equatable, Sendable {
    case success(PgpPayload)
    case tooLarge
    case notClientProtected
    /// 404 — the server has the message and it carries no OpenPGP payload.
    case noPayload
    case failed(String)
}

/// The decrypted message, split the way the reader renders it.
nonisolated struct DecryptedBody: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    /// Both halves are kept rather than collapsed to one: the caller decides
    /// what reaches the WebView, and a message carrying only a plain part must
    /// not render as an empty page.
    var html: String?
    var plain: String?
    /// The MIME mode that came with the selected body. Never infer this from
    /// the body's characters — that is what `bodyLooksLikeHTML` is for, and
    /// guessing here would let a plain-text message containing angle brackets
    /// render as markup.
    var bodyMode: String = ""
    /// RFC 3156 protected subject, when the message carried one. The header
    /// subject of an encrypted message is plaintext on the wire, so a message
    /// that protects its subject carries the real one inside.
    var protectedSubject: String?
    /// Files out of the decrypted MIME, within `PgpMimeReader`'s part and
    /// byte caps. In memory only, like the rest of this value.
    var attachments: [DecryptedAttachment] = []
    /// A part was dropped for size or count. The screen says so: silence
    /// would show a message that appears to have fewer files than it does.
    var attachmentsOmitted = false
    /// A declared PGP/MIME `multipart/signed` wrapper, root or nested.
    /// Presence establishes neither validity nor a signer.
    var hasDetachedSignature = false

    /// Redacted: every field is a decrypted message.
    var description: String { "DecryptedBody(redacted)" }
    var debugDescription: String { description }
}

/// One attachment part out of a decrypted message. Redacted in every
/// description: its bytes are decrypted mail.
nonisolated struct DecryptedAttachment: Equatable, Sendable, Identifiable,
    CustomStringConvertible, CustomDebugStringConvertible {
    let id = UUID()
    var name: String
    var mimeType: String
    var data: Data
    /// The `Content-ID` without its angle brackets, for `cid:` references in
    /// the html part.
    var contentId: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.mimeType == rhs.mimeType
            && lhs.data == rhs.data && lhs.contentId == rhs.contentId
    }

    var description: String { "DecryptedAttachment(redacted)" }
    var debugDescription: String { description }
}

/// Every way reading a client-protected message can end — one per row of the
/// design spec's exit table.
///
/// Separate cases rather than one error string because the UI shows a
/// different sentence, and sometimes a different button, for each.
nonisolated enum ReadOutcome: Equatable, Sendable {
    case decrypted(body: DecryptedBody, verdict: SignatureVerdict)

    /// The key is not held and this attempt was not allowed to prompt. The
    /// screen goes on offering Decrypt.
    case needsUnlock

    /// **Not an error.** The user dismissed a sheet they raised, so the screen
    /// simply goes back to offering Decrypt.
    case cancelled

    case notEnrolled
    case noSecureLockScreen
    case tooLarge
    case notClientProtected

    /// The server has the message but it carries no OpenPGP payload.
    ///
    /// Terminal: unlike a transport failure, retrying cannot change it, so the
    /// UI must not offer Retry. Reachable when the inbox flag said encrypted
    /// and the fetched message disagrees.
    case noEncryptedContent

    case unsealFailed(String)
    case fetchFailed(String)
    case decryptFailed(String)
}

/// Whether an outcome is worth offering a Retry button for.
///
/// `noEncryptedContent` is the trap here: it reads like a failure and is not
/// retryable, and a Retry that cannot possibly succeed teaches the user their
/// mail is broken.
nonisolated func readOutcomeAllowsRetry(_ outcome: ReadOutcome) -> Bool {
    switch outcome {
    case .fetchFailed, .decryptFailed, .unsealFailed, .tooLarge:
        true
    case .decrypted, .needsUnlock, .cancelled, .notEnrolled,
         .noSecureLockScreen, .notClientProtected, .noEncryptedContent:
        false
    }
}
