//
//  Email.swift
//  KyPost
//
//  Domain model for a received email (spec §8 emails table).
//

import Foundation

struct Email: Identifiable, Hashable, Sendable {
    /// Relay message id.
    var serverId: String
    var folder: String
    var senderName: String
    var senderEmail: String
    var subject: String
    var body: String
    /// Raw To/Cc header strings (comma-joined, entries may be
    /// "Name <addr>"); kept for Reply All recipient building.
    var sentTo: String = ""
    var cc: String = ""
    /// Relay tab/label values; drives inbox tabs.
    var keywords: Set<String>
    var receivedAt: Date
    /// When a snoozed message returned to the inbox (relay `wokenAt`).
    var wokenAt: Date?
    var read: Bool
    var starred: Bool
    /// The relay's `bodyMode`: "html" or "plain", or "" when the server did
    /// not say. When the server *did* say, the reader must honour it rather
    /// than sniffing the body — see EmailBodyRendering.swift.
    var bodyMode: String = ""
    /// True when the relay sent this row without a body at all — a delta
    /// "updated" entry. Distinct from an empty body, and never persisted: the
    /// merge uses it to keep the cached body rather than overwrite it. See
    /// the hazard note on RelayEmailDTO.body.
    var bodyOmitted: Bool = false
    /// Relay `hasAttachments`, for the list-row marker. The inbox listing
    /// carries no attachment metadata, so the paperclip is all this supports;
    /// the actual list is fetched lazily on open.
    var hasAttachments: Bool = false
    /// Relay OpenPGP state. Defaults are the wire contract for a message with
    /// no OpenPGP content — see PgpMessageState.swift for what they mean
    /// together.
    var pgpEncrypted: Bool = false
    var pgpSigned: Bool = false
    var pgpVerified: Bool = false
    /// Stored but not rendered — displaying it usefully means comparing it
    /// against a contact's saved key, which belongs with the contacts work.
    var pgpSignerFingerprint: String = ""
    var pgpDecryptError: String = ""
    /// False for a row older than the relay's window (paged in, or reported
    /// `agedOut`). Such a row carries no body, attachment or PGP flags of its
    /// own; see `MailRepository.loadBody`.
    var inWindow: Bool = true

    /// (folder, id), never the id alone — see `MailRowKey`.
    var id: MailRowKey { MailRowKey(folder: folder, serverId: serverId) }

    /// List order: a woken message sorts as if it arrived when it woke.
    nonisolated var sortDate: Date { wokenAt ?? receivedAt }

    /// Stands in for a missing or unparseable `atUtc`. A sentinel rather than
    /// an optional so the cached schema and its newest-first sort stay as they
    /// are; it sorts last, and every renderer shows it as blank. It used to be
    /// `Date()`, which dressed an undated message up as just-arrived.
    nonisolated static let unknownDate = Date.distantPast

    nonisolated static func isKnownDate(_ date: Date) -> Bool {
        date > unknownDate
    }
}

/// Which message a row is. The relay's `messageId` is a bare IMAP UID on IMAP
/// accounts (KyPost-Server `MessageReference`), unique only within one
/// mailbox, so INBOX and Sent can both hold `42`. Every lookup, write, action,
/// and held or opened row is keyed by (folder, id), never by the id alone.
///
/// Not UIDVALIDITY-aware: the relay does not expose it. After a reset, window
/// rows heal at the daily full resync; nothing else can.
nonisolated struct MailRowKey: Hashable, Codable, Sendable {
    var folder: String
    var serverId: String
}

/// A folder/mailbox on the relay.
struct MailFolder: Hashable, Sendable {
    var name: String
    /// Whether the relay will let this folder be deleted. The built-in
    /// mailboxes are not deletable, and the server is the authority — do not
    /// re-derive it from the name, which is how a localised or renamed
    /// special folder ends up with a Delete item that always fails.
    var deletable: Bool = false
}

/// Built-in relay mailboxes. Binding contract: values are the exact
/// `mailbox` parameter names the relay and the Android reference use
/// (InboxActivity switches between "INBOX"/"Junk"/"Trash").
enum StandardFolder {
    static let inbox = "INBOX"
    static let drafts = "Drafts"
    static let junk = "Junk"
    static let sent = "Sent"
    static let trash = "Trash"
    static let archive = "Archive"

    /// Human title for a mailbox path: "INBOX" → "Inbox",
    /// "Archive/Receipts" → "Receipts". The backend treats both "/" and "."
    /// as hierarchy delimiters (server.go mailboxParentPath), so both split.
    static func displayName(_ path: String) -> String {
        if path == inbox { return "Inbox" }
        return path.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init) ?? path
    }
}

/// An email being composed (spec §7 SendEmailUseCase).
struct OutgoingEmail: Sendable {
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var body: String
    /// Relay send mode: "plain" (default), "html", or "markup".
    var mode: String = "plain"
    var attachments: [OutgoingAttachment] = []
    /// Ask the relay to encrypt this message to its recipients. The server
    /// holds the key and does the OpenPGP work; this client never does
    /// (Client_Encrypted_Send.md).
    var encrypt = false
    /// Ask the relay to sign with the account's key.
    var sign = false
    /// Consent to the relay mailing a one-time pickup link to recipients with
    /// no usable key, which stores this message's plaintext on the server for
    /// 7 days. Meaningful only with `encrypt`. Per-message by design — never
    /// remembered, never persisted.
    var allowPickupFallback = false
    /// Relay mode only: server-side categorization.
    var tab: String?
}

/// A file attached to an outgoing email; sent base64-encoded in the
/// /api/mail/send JSON body (Mobile_Mail_Relay.md, 25 MB total cap).
struct OutgoingAttachment: Hashable, Sendable {
    var name: String
    var mimeType: String
    var data: Data
}

/// Metadata for one attachment on a received email, from
/// GET /api/mail/attachments. Content downloads separately by index.
struct EmailAttachment: Identifiable, Hashable, Sendable {
    var index: Int
    var name: String
    var mimeType: String
    /// Decoded size in bytes.
    var size: Int
    /// The iTIP METHOD of a calendar part (REQUEST, CANCEL, …), as the relay
    /// lists it (KyPost-Server #353); empty for anything else, and for every
    /// part on a relay too old to know it — which also cannot RSVP.
    var calendarMethod: String = ""

    var id: Int { index }
}
