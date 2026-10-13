//
//  MailSource.swift
//  KyPost
//
//  Abstraction over the mail backend. Relay is the only transport
//  (IMAP was dropped); the protocol remains so the transport stays swappable.
//

import Foundation

/// Message ids are Strings (`Email.serverId`) — relay ids.
protocol MailSource: Sendable {
    /// Lists folders; `parent` scopes to that folder's children (nil = top level).
    func listFolders(parent: String?) async throws -> [MailFolder]
    /// Creates a child folder. `parent` is "" for a top-level folder; `name`
    /// is one path segment, never a full path — the relay joins them.
    func createFolder(parent: String, name: String) async throws
    /// Renames `folder` (a full path) to `name` (one segment).
    func renameFolder(folder: String, name: String) async throws
    /// Deletes `folder` (a full path). Only ever offered for a folder the
    /// listing marked `deletable`.
    func deleteFolder(folder: String) async throws
    /// Fetches a folder. `since` is the opaque server cursor from a previous
    /// fetch, or "" for the whole window. Cursors are server-issued strings;
    /// never assume they are numeric or ordered.
    func fetchEmails(
        folder: String,
        from: Int,
        to: Int,
        since: String
    ) async throws -> MailFetchResult
    /// One page of mail older than `before`, a list-row id in `folder`
    /// (`GET /api/inbox?before=`). Metadata only — no body, attachment or PGP
    /// flags — and it never touches the cursor.
    func fetchOlder(folder: String, limit: Int, before: String) async throws -> MailPage
    /// One message's body (`GET /api/mail/body`), for a row that arrived
    /// without one: a page of older mail, or a search result.
    func fetchBody(folder: String, messageId: String) async throws -> MailMessageBody
    /// Server-side search of one folder, every field
    /// (`GET /api/mail/search`). Rows carry no body and are stamped with
    /// `folder`: an id means nothing outside the folder it came from.
    func searchMail(folder: String, query: String, limit: Int) async throws -> [Email]
    /// The four verbs that take a message out of `mailbox` return the relay's
    /// per-id report. A 200 is transport success only — see MailActionReport.
    @discardableResult
    func move(messageIds: [String], from mailbox: String, to targetMailbox: String) async throws -> MailActionReport
    /// Deletes messages. The relay moves them to Trash, or expunges them
    /// permanently when `mailbox` is already Trash (server.go ApplyInboxAction).
    @discardableResult
    func delete(messageIds: [String], mailbox: String) async throws -> MailActionReport
    /// Moves messages to the Archive folder (Android MailAction.ARCHIVE).
    @discardableResult
    func archive(messageIds: [String], mailbox: String) async throws -> MailActionReport
    /// Moves messages to Junk (Android MailAction.SPAM).
    @discardableResult
    func markSpam(messageIds: [String], mailbox: String) async throws -> MailActionReport
    /// Flags messages read on the server so the state syncs across devices.
    func markRead(messageIds: [String], mailbox: String) async throws
    /// Attachment metadata for one message (fetched lazily on open; the
    /// inbox listing carries no attachment info).
    func listAttachments(folder: String, messageId: String) async throws -> [EmailAttachment]
    /// One attachment's raw bytes, by its index from `listAttachments`.
    func downloadAttachment(folder: String, messageId: String, index: Int) async throws -> Data
    /// Sends a message and returns the relay's `warning` — empty on a clean
    /// send, non-empty on a *partial* problem (the Sent copy failed to save,
    /// and/or some pickup links failed to deliver). A warning still means the
    /// message went out: never retry on one, it would duplicate.
    @discardableResult
    func send(email: OutgoingEmail) async throws -> String
    /// Saves a draft server-side (POST /api/mail/draft). Same body shape as
    /// `send` minus the PGP flags; the response is `{"ok": true}` and every
    /// failure is a plain-text error. The client-custody webmail handoff
    /// depends on this call.
    func saveDraft(email: OutgoingEmail) async throws
}

extension MailSource {
    /// Top-level folders.
    func listFolders() async throws -> [MailFolder] {
        try await listFolders(parent: nil)
    }

    /// Full-window fetch, for callers with no cursor to offer.
    func fetchEmails(folder: String, from: Int, to: Int) async throws -> MailFetchResult {
        try await fetchEmails(folder: folder, from: from, to: to, since: "")
    }
}

/// One folder fetch's result. `isDelta` false means `emails` is a full
/// snapshot — the pre-delta shape, and what a relay without cursor support
/// always returns.
struct MailFetchResult: Equatable, Sendable {
    var emails: [Email] = []
    var cursor: String = ""
    /// The rest only matter when `isDelta` is true.
    var isDelta = false
    var updatedIds: Set<String> = []
    var removedIds: [String] = []
    /// True when this response describes the server's whole window rather than
    /// just what changed — i.e. we sent since=0.
    ///
    /// **Not the wire's `delta` flag.** A relay predating the matching server
    /// fix labels a since=0 response `delta: true` all the same, so this, not
    /// the flag, is what says `emails` is complete enough to prune the folder
    /// against. Pruning is the only self-heal for a removal we were never
    /// told about.
    var isFullWindow = false
    /// Ids that fell below the relay's window but still exist: keep them,
    /// out of the window. Absent on a relay predating KyPost-Server #349.
    var agedOutIds: [String] = []
    /// More new mail arrived than the window holds; the rest is paged with
    /// `before=nextBefore` (`MailRepository.fetchOverflow`).
    var hasMore = false
    var nextBefore: String?
}

/// One `before=` page, newest first. `hasMore` is nil when the server ignored
/// `before=` and answered with its newest window instead (a relay predating
/// KyPost-Server #348) — which is not older mail, and is never stored.
struct MailPage: Equatable, Sendable {
    var emails: [Email]
    var hasMore: Bool?
    var nextBefore: String?
}

/// `GET /api/mail/body`: the body and its mode, nothing else. No recipients
/// and no PGP flags — those come from the row (or, for a body taken from
/// the cache, from `cachedPgp`).
nonisolated struct MailMessageBody: Equatable, Sendable {
    var body: String
    var bodyMode: String
    /// The cached row's OpenPGP state when the body came from the cache for a
    /// row that carries none of its own (a search result). Nil for a body
    /// from `/api/mail/body`, which carries no PGP fields.
    var cachedPgp: MailPgpFields? = nil

    /// `email` as the reader renders it: this body in place of the missing
    /// one, and the cached OpenPGP state when there is one — so a cached
    /// signature or encryption verdict is never dropped by opening the same
    /// message from somewhere that lacks it.
    func applied(to email: Email) -> Email {
        var shown = email
        shown.body = body
        if !bodyMode.isEmpty { shown.bodyMode = bodyMode }
        if let cachedPgp {
            shown.pgpEncrypted = cachedPgp.encrypted
            shown.pgpSigned = cachedPgp.signed
            shown.pgpVerified = cachedPgp.verified
            shown.pgpSignerFingerprint = cachedPgp.signerFingerprint
            shown.pgpDecryptError = cachedPgp.decryptError
        }
        return shown
    }
}

/// A cached row's OpenPGP fields (see `Email`).
nonisolated struct MailPgpFields: Equatable, Sendable {
    var encrypted: Bool
    var signed: Bool
    var verified: Bool
    var signerFingerprint: String
    var decryptError: String

    init(of email: Email) {
        encrypted = email.pgpEncrypted
        signed = email.pgpSigned
        verified = email.pgpVerified
        signerFingerprint = email.pgpSignerFingerprint
        decryptError = email.pgpDecryptError
    }
}

/// The list actions that take a message out of its folder, as the relay's
/// `/api/inbox/actions` verbs.
nonisolated enum MailMoveAction: String, Hashable, Sendable {
    case archive
    case delete
    case spam
    case move
}

/// What `POST /api/inbox/actions` reported for one request
/// (`server_inbox.go` `handleInboxActions`: `{ok, action, processed,
/// failed: [{messageId, error}], targetMailbox}`).
///
/// **HTTP 200 is transport success, not operation success.** The relay answers
/// 200 with ids in `failed[]`, and its loop stops early on a cancelled request,
/// leaving ids in neither list. `processed` is a count, not a list, so only
/// `MailRepository.applyAction` decides which ids were confirmed.
nonisolated struct MailActionReport: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        var messageId: String
        var error: String
    }

    var processed: Int
    var failed: [Failure]
}

/// The outcome of one batch as the cache saw it: the ids the relay confirmed
/// (their cached rows are already gone) and, when anything was not changed,
/// a sentence for the user.
nonisolated struct MailActionResult: Equatable, Sendable {
    var confirmedIds: [String]
    var failureMessage: String?
}

/// Mail-layer failures that aren't plain network errors.
enum MailSourceError: Error, Equatable {
    /// No pairing stored — the user must pair the device first.
    case notPaired
    /// The pairing exists but its secret is unreadable right now: the
    /// credential gate is on and the app is locked. Not an error state —
    /// background work retries after the next unlock, like `notPaired`.
    case credentialUnavailable
    /// A 200 whose body is not the documented shape. Carries the sentence.
    case malformedResponse(String)
    /// The relay answered definitively that this message cannot be opened
    /// (404 gone, 413 too large). Not a connectivity failure: retrying will
    /// not help, and saying "couldn't reach the server" would be a lie.
    case messageUnavailable(String)
    /// The server ignored `before=`: it predates older-mail paging.
    case olderMailUnsupported
    /// A delta announced more new mail than its window held, then would not
    /// page it (no `nextBefore`, or a page without `hasMore`).
    case overflowUnreachable
    /// Relay 400 whose plain-text body says IMAP configuration is required.
    /// The account exists but has no mail set up; only the web app can fix it.
    case notConfigured(String)
    case invalidServerURL
    /// Relay 409 + clientSideNeeded: a client-protected account asked the
    /// server to sign or encrypt and it refused rather than silently sending
    /// in the clear.
    case clientSideNeeded
    /// Relay 409 + keylessRecipients: at least one recipient has no usable
    /// key. **Nothing was delivered** — the refusal happens before any SMTP.
    /// Re-sending the identical request with `allowPickupFallback: true` is
    /// safe and cannot duplicate. `pickupFallbackAvailable` is false when the
    /// server has one-time links turned off, in which case there is nothing to
    /// offer the user.
    case keylessRecipients(addresses: [String], pickupFallbackAvailable: Bool)
}

/// User-facing result of a mail operation (spec §11 relay response mapping).
enum MailOutcome: Equatable, Sendable {
    case success
    /// Recipients/fields invalid before any network call.
    case invalid(String)
    /// Credentials rejected — re-pair the device.
    case unauthorized
    case notPaired
    case failure(String)
    /// The account's PGP key is end-to-end protected; the server will not sign
    /// or encrypt on its behalf and this app holds no private key.
    case clientSideNeeded
    /// Sent, but with a partial problem worth showing (Sent copy not saved,
    /// some pickup links undelivered). Not a failure; offering a retry here
    /// would duplicate the message. Treat the text as opaque human-readable
    /// prose — never pattern-match its wording.
    case sentWithWarning(String)
    /// Some recipients have no usable key and nothing was sent. Confirming
    /// mails them a one-time link and stores this message's plaintext on the
    /// server for 7 days.
    case keylessRecipients(addresses: [String], pickupFallbackAvailable: Bool)
    /// Relay 429 — the per-device lockout after repeated bad credentials.
    /// `retryAfter` is seconds from the header, nil when it was absent or
    /// unparseable. Back off either way.
    case rateLimited(retryAfter: Int?)
    /// Relay 400 "imap configuration is required…" — the account has no mail
    /// set up yet. Direct the user to the web app; never build a form for the
    /// server's web-only configuration endpoints.
    case notConfigured(String)
    /// Relay 502 — an upstream IMAP/SMTP failure. Safe to retry with backoff,
    /// unlike the other failures here.
    case upstreamFailure(String)

    /// A short reason for a user-facing sentence, or "" when there is none.
    var reason: String {
        switch self {
        case .success, .sentWithWarning: ""
        case .invalid(let message), .failure(let message),
             .notConfigured(let message), .upstreamFailure(let message):
            message
        case .unauthorized: "the server rejected this device's credentials"
        case .notPaired: "this device isn't paired"
        case .clientSideNeeded: "the server refused to send it"
        case .keylessRecipients: "the server refused to send it"
        case .rateLimited(let retryAfter):
            retryAfter.map { "too many attempts — try again in \(NetworkError.formatRetryAfter($0))" }
                ?? "too many attempts — try again later"
        }
    }

    static func from(_ error: Error) -> MailOutcome {
        switch error {
        case NetworkError.unauthorized:
            .unauthorized
        case MailSourceError.notPaired:
            .notPaired
        case MailSourceError.clientSideNeeded:
            .clientSideNeeded
        case MailSourceError.keylessRecipients(let addresses, let pickupFallbackAvailable):
            .keylessRecipients(
                addresses: addresses,
                pickupFallbackAvailable: pickupFallbackAvailable
            )
        case NetworkError.rateLimited(let retryAfter):
            .rateLimited(retryAfter: retryAfter)
        case NetworkError.badRequest(let body):
            RelayMailSource.notConfiguredMessage(body: body).map(MailOutcome.notConfigured)
                ?? .failure(Self.message(for: .badRequest(body: body)))
        case MailSourceError.notConfigured(let message):
            .notConfigured(message)
        case MailSourceError.messageUnavailable(let message),
             MailSourceError.malformedResponse(let message):
            .failure(message)
        case MailSourceError.olderMailUnsupported:
            .failure(String(localized: "This server can't load older mail. Update KyPost Server to use this."))
        case MailSourceError.overflowUnreachable:
            .failure(String(localized: "The server reported more new mail than it would page."))
        case NetworkError.server(statusCode: 502):
            .upstreamFailure(Self.message(for: .server(statusCode: 502)))
        case let networkError as NetworkError:
            .failure(Self.message(for: networkError))
        default:
            .failure("\(error)")
        }
    }

    /// One sentence for any outcome that is not a success, for callers that
    /// only report (list actions, folder changes) rather than branch.
    var userMessage: String? {
        switch self {
        case .success, .sentWithWarning:
            nil
        case .rateLimited(let retryAfter):
            retryAfter.map {
                String(localized: "Too many attempts — try again in \(NetworkError.formatRetryAfter($0)).")
            } ?? String(localized: "Too many attempts — try again later.")
        case .notConfigured:
            String(localized: "Set up your mail account in the web app first.")
        case .unauthorized:
            String(localized: "Not authorized — re-pair the device or check credentials.")
        case .notPaired:
            String(localized: "Pair this device first.")
        case .invalid(let message), .failure(let message), .upstreamFailure(let message):
            message
        case .clientSideNeeded, .keylessRecipients:
            // Neither is reachable outside the send path.
            String(localized: "The server refused that change.")
        }
    }

    /// Human-readable text for the `NetworkError` cases that reach here
    /// unclaimed (401 and the two PGP 409s are already peeled off above).
    /// Without this, `.failure("\(error)")` puts the raw enum dump — e.g.
    /// "server(statusCode: 404)" — straight in front of the user; the server
    /// side of this feature isn't merged yet, so a 404 from the draft-save
    /// call is exactly what the first tester hits.
    ///
    /// Internal rather than private because the networking clients need it
    /// too: they each ended in `.failure("\(error)")`, and string
    /// interpolation resolves through `String(describing:)`, which never
    /// consults `LocalizedError`. That printed "certificateMismatch" where a
    /// warning that the connection may be intercepted was intended.
    static func message(for error: NetworkError) -> String {
        switch error {
        case .invalidURL: "This server's address looks wrong."
        case .unauthorized: "Not authorized — re-pair the device or check credentials."
        case .badRequest(let body):
            body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "The server rejected this request."
                : body
        case .conflict: "The server rejected this request."
        case .rateLimited: error.errorDescription ?? "Too many attempts — try again later."
        case .serviceUnavailable: "The server is temporarily unavailable."
        case .responseTooLarge: "The server sent more data than this app will accept."
        case .certificateMismatch: error.errorDescription
            ?? "The server's security certificate changed — re-pair the device."
        case .server(statusCode: 502): "Couldn't reach the mail server — try again shortly."
        case .server(let statusCode): "The server returned an error (status \(statusCode))."
        case .transport(let description): description
        case .decoding: "The server sent a response this app couldn't read."
        }
    }
}
