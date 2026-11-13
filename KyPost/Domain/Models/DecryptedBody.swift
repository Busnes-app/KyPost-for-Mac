//
//  DecryptedBody.swift
//  KyPost
//
//  What `PgpMimeReader` makes of a decrypted message. Its own file, holding
//  Foundation-only value types, so `Fuzz/` can compile the reader on Linux
//  without the rest of the app.
//

import Foundation

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
