//
//  RelayMailSource.swift
//  KyPost
//
//  MailSource backed by the relay endpoints, matching the Android reference
//  RelayMailSource.kt / RelayModels.kt (Mobile_Mail_Relay.md) and verified
//  against the live backend 2026-07-10. Pairing auth (deviceId/deviceSecret)
//  travels as headers (RelayAuth.headerFields), not query params:
//    GET  /api/inbox?limit&mailbox&since
//    GET  /api/inbox?limit&mailbox&before&bodies=0  (older mail, one page)
//    GET  /api/mail/body?mailbox&messageId
//    GET  /api/mail/search?q&mailbox&limit  (every field: `field` is not sent)
//    GET  /api/inbox/folders
//    POST /api/mail/send  (encrypt/sign/allowPickupFallback — Client_Encrypted_Send.md)
//    POST /api/mail/draft (same shape as send, minus the PGP flags)
//  Binding contract: send body uses comma-joined recipient strings plus a
//  "mode" field; /api/inbox returns emails grouped by tab.
//

import Foundation

// MARK: - DTOs (match Mobile_Mail_Relay.md JSON exactly, like Android RelayModels.kt)

/// Some deployments emit `cursor` as a bare JSON number rather than a quoted
/// string; decode either shape (Android FlexibleCursorSerializer).
struct FlexibleCursor: Decodable, Equatable, Sendable {
    var value: String

    init(_ value: String) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else {
            value = ""
        }
    }
}

struct RelayEmailDTO: Decodable, Equatable, Sendable {
    var messageId: String
    /// Single display string, e.g. "Ada Lovelace <ada@example.com>".
    var sender: String?
    var sentTo: String?
    var cc: String?
    var bcc: String?
    var subject: String?
    /// Nil (not "") on delta "updated" entries whose body was omitted.
    /// Delta v2 hazard: `toDomain` collapses this to "" , so a body-less
    /// "updated" row for a server-decrypted message would evaluate to
    /// `.clientProtected` and send the user to webmail. Carry nil through as a
    /// distinct "unknown" before enabling delta fetches.
    var body: String?
    /// "html" or "plain". Absent on an older relay, which is a distinct state
    /// from either value: the reader falls back to sniffing the body only
    /// then, never when the server has told us.
    var bodyMode: String?
    /// Whether the message carries attachments, for the list-row marker. The
    /// listing carries no per-attachment metadata; that is a separate lazy
    /// fetch on open.
    var hasAttachments: Bool?
    var label: String?
    /// The message's real IMAP keywords. `omitempty` server-side, so absent
    /// means none. Previously not decoded at all, which meant `Email.keywords`
    /// was synthesised from `label`/tab alone and a keyword the server
    /// actually set — the `$Phishing` anti-phishing flag — never reached this
    /// client.
    var keywords: [String]?
    /// "unread" unless the server says otherwise.
    var status: String?
    /// ISO-8601 timestamp.
    var atUtc: String?
    /// When a snoozed message returned to the inbox. Orders the list; the
    /// displayed date stays `atUtc`.
    var wokenAt: String?
    /// "new" or "updated"; only present when the response has delta=true.
    var changeType: String?
    /// OpenPGP state, all omitempty server-side — absent means "no OpenPGP
    /// content", so these defaults are the contract, not an unknown state.
    /// See kypost-server/docs/E2E_PGP.md.
    var pgpEncrypted: Bool?
    var pgpSigned: Bool?
    var pgpVerified: Bool?
    var pgpSignerFingerprint: String?
    var pgpDecryptError: String?

    func toDomain(folder: String, tab: String) -> Email {
        let (name, address) = Self.splitSender(sender ?? "")
        let keyword = (label?.isEmpty == false ? label : tab) ?? tab
        // Union of the wire keywords and the tab-derived label, not a
        // replacement: the label drives the tab strip, and the wire list
        // carries protocol keywords like $Phishing. Dropping either loses
        // something the UI needs.
        return Email(
            serverId: messageId,
            folder: folder,
            senderName: name,
            senderEmail: address,
            subject: subject ?? "",
            // An omitted body is NOT an empty one. A delta "updated" entry
            // carries no body, and writing "" here made such a row
            // indistinguishable from a client-protected message — so the
            // reader claimed end-to-end encryption for mail the server had
            // decrypted. `bodyOmitted` carries the distinction to the merge,
            // which preserves whatever body is already cached.
            body: body ?? "",
            sentTo: sentTo ?? "",
            cc: cc ?? "",
            keywords: Set(((keywords ?? []) + [keyword]).filter { !$0.isEmpty }),
            // Blank in the list, never "now": see Email.unknownDate.
            receivedAt: Self.parseUtc(atUtc) ?? Email.unknownDate,
            wokenAt: Self.parseUtc(wokenAt),
            read: (status ?? "unread").lowercased() != "unread",
            starred: false,
            bodyMode: bodyMode ?? "",
            bodyOmitted: body == nil,
            hasAttachments: hasAttachments ?? false,
            pgpEncrypted: pgpEncrypted ?? false,
            pgpSigned: pgpSigned ?? false,
            pgpVerified: pgpVerified ?? false,
            pgpSignerFingerprint: pgpSignerFingerprint ?? "",
            pgpDecryptError: pgpDecryptError ?? ""
        )
    }

    /// Splits "Name <addr@host>" into display name and address; a bare
    /// address fills both fields.
    private static func splitSender(_ sender: String) -> (name: String, email: String) {
        let trimmed = sender.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.lastIndex(of: "<"),
           let close = trimmed.lastIndex(of: ">"),
           open < close {
            let name = String(trimmed[..<open])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let email = String(trimmed[trimmed.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? email : name, email)
        }
        if trimmed.contains("@") {
            return (trimmed, trimmed)
        }
        return (trimmed, "")
    }

    private static func parseUtc(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}

struct RelayInboxResponse: Decodable, Sendable {
    var tabs: [String]?
    var byTab: [String: [RelayEmailDTO]]?
    var cursor: FlexibleCursor?
    var delta: Bool?
    /// Left the mailbox: delete.
    var removed: [String]?
    /// Fell below the window and still exists: keep (KyPost-Server #349).
    var agedOut: [String]?
    /// On a delta: new mail lies below the window. On a `before=` page: there
    /// is older mail still. Absent on a relay predating #348/#349 — and on a
    /// `before=` request that absence is how an old server is recognised.
    var hasMore: Bool?
    var nextBefore: String?

    /// Ids the server marked as changed rather than new. Only meaningful on a
    /// delta response; empty otherwise, which makes every row "new" and the
    /// merge a plain upsert.
    func updatedIds() -> Set<String> {
        Set(
            (byTab ?? [:]).values.flatMap { $0 }
                .filter { $0.changeType?.lowercased() == "updated" }
                .map(\.messageId)
        )
    }

    /// Flattens the per-tab groups; each email keeps its tab as a keyword.
    /// Sorted by `sortDate`, newest first — the per-tab dictionary has no
    /// stable iteration order, and EmailDAO.getFolder reads the cache in the
    /// same order.
    func allEmails(folder: String) -> [Email] {
        (byTab ?? [:])
            .flatMap { tab, emails in
                emails.map { $0.toDomain(folder: folder, tab: tab) }
            }
            .sorted { $0.sortDate > $1.sortDate }
    }
}

/// GET /api/mail/body: `{body, bodyMode}` and nothing else. An absent
/// `bodyMode` is "the server could not tell", not plain — see
/// EmailBodyRendering.swift.
struct RelayMessageBodyResponse: Decodable, Sendable {
    var body: String?
    var bodyMode: String?
}

/// GET /api/mail/search: `{"results": [inboxEmail…]}` — metadata only, no
/// bodies and no PGP flags (`server_inbox.go` `handleMailSearch`).
struct RelaySearchResponse: Decodable, Sendable {
    var results: [RelayEmailDTO]?
}

struct RelayFolderDTO: Decodable, Equatable, Sendable {
    var path: String
    var deletable: Bool?
}

/// POST /api/inbox/folders. `parent` is "" for a top-level folder.
struct RelayFolderCreateRequest: Encodable, Sendable {
    var parent: String
    var name: String
}

/// PUT /api/inbox/folders. `folder` is the full existing path, `name` the new
/// single segment.
struct RelayFolderRenameRequest: Encodable, Sendable {
    var folder: String
    var name: String
}

struct RelayFolderListResponse: Decodable, Sendable {
    var parent: String?
    var folders: [RelayFolderDTO]?
}

struct RelaySendResponse: Decodable, Sendable {
    var ok: Bool?
    var sentSaved: Bool?
    var warning: String?
    /// `true` only when the relay built the request's `calendarReply` into
    /// the message (KyPost-Server #354). Absent on a relay that ignored it.
    var calendarReply: Bool?
}

/// `calendarReply` on /api/mail/send: an iTIP REPLY the relay attaches as
/// `text/calendar; method=REPLY` beside the body.
nonisolated struct RelayCalendarReplyDTO: Encodable, Equatable, Sendable {
    var ics: String
}

/// Shape of a relay 409 body. Both PGP refusals are told apart from an
/// ordinary conflict — and from each other — by which of these fields is
/// present, never by the error prose (see `RelayMailSource.conflictError`).
/// Every field is optional because a 409 body may be neither shape, and
/// because non-409 errors return plain text.
struct RelayConflictDTO: Decodable, Sendable {
    var clientSideNeeded: Bool?
    /// Recipients with no usable PGP key. Nothing was delivered — the refusal
    /// happens before any SMTP, so re-sending with `allowPickupFallback` cannot
    /// duplicate the message.
    var keylessRecipients: [String]?
    /// Whether re-sending with `allowPickupFallback: true` is available at all.
    var pickupFallbackAvailable: Bool?
}

/// Bulk action body (Mobile_Mail_Relay.md /api/inbox/actions).
struct RelayActionRequest: Encodable, Equatable, Sendable {
    var action: String
    var messageIds: [String]
    var mailbox: String
    /// Only "move" takes a target; JSONEncoder drops it when nil.
    var targetMailbox: String? = nil
}

struct RelayActionResponse: Decodable, Sendable {
    var ok: Bool?
    /// Bulk actions only. Absent reads as zero processed — an unconfirmed
    /// change must never delete a visible row.
    var processed: Int?
    var failed: [RelayActionFailureDTO]?

    var report: MailActionReport {
        MailActionReport(
            processed: processed ?? 0,
            failed: (failed ?? []).map {
                MailActionReport.Failure(messageId: $0.messageId ?? "", error: $0.error ?? "")
            }
        )
    }
}

struct RelayActionFailureDTO: Decodable, Sendable {
    var messageId: String?
    var error: String?
}

/// Attachment metadata from GET /api/mail/attachments.
struct RelayAttachmentDTO: Decodable, Equatable, Sendable {
    var index: Int
    var name: String?
    var mimeType: String?
    var size: Int?
    var calendarMethod: String?

    func toDomain() -> EmailAttachment {
        EmailAttachment(
            index: index,
            name: name?.isEmpty == false ? name! : "attachment",
            mimeType: mimeType ?? "application/octet-stream",
            size: size ?? 0,
            calendarMethod: calendarMethod ?? ""
        )
    }
}

struct RelayAttachmentListResponse: Decodable, Sendable {
    var ok: Bool?
    var attachments: [RelayAttachmentDTO]?
}

/// Outgoing attachment: base64 in the send/draft JSON (Mobile_Mail_Relay.md).
nonisolated struct RelaySendAttachmentDTO: Encodable, Equatable, Sendable {
    var name: String
    var mimeType: String
    var dataBase64: String

    init(from attachment: OutgoingAttachment) {
        name = attachment.name
        mimeType = attachment.mimeType
        dataBase64 = attachment.data.base64EncodedString()
    }
}

/// Send body with comma-joined recipients (Mobile_Mail_Relay.md Part 6) —
/// differs from contact sync's array-of-objects shape. POST /api/mail/draft
/// takes the same shape minus the PGP flags.
struct RelaySendRequest: Encodable, Equatable, Sendable {
    var to: String
    var cc: String
    var bcc: String
    var subject: String
    var body: String
    var mode: String
    /// Omitted from the JSON entirely when there are no attachments.
    var attachments: [RelaySendAttachmentDTO]?
    /// PGP flags, omitted when false so a plaintext send is byte-identical to
    /// what this client sent before encryption existed; the relay defaults all
    /// three to false. `allowPickupFallback` is meaningful only with `encrypt`.
    var encrypt: Bool?
    var sign: Bool?
    var allowPickupFallback: Bool?
    /// An alias to send as; omitted for the account's primary address.
    var from: String?
    /// An RSVP. Omitted on every other send.
    var calendarReply: RelayCalendarReplyDTO?

    /// `pgpFlags: false` builds the draft-save body, which carries no PGP
    /// fields at all.
    init(from email: OutgoingEmail, pgpFlags: Bool = true) {
        to = email.to.joined(separator: ", ")
        cc = email.cc.joined(separator: ", ")
        bcc = email.bcc.joined(separator: ", ")
        subject = email.subject
        body = email.body
        mode = email.mode
        attachments = email.attachments.isEmpty
            ? nil
            : email.attachments.map(RelaySendAttachmentDTO.init)
        let pgp = pgpFlags
        encrypt = pgp && email.encrypt ? true : nil
        sign = pgp && email.sign ? true : nil
        allowPickupFallback = pgp && email.encrypt && email.allowPickupFallback ? true : nil
    }

    /// An RSVP: plain text, and never a PGP flag — the relay refuses
    /// `calendarReply` beside `encrypt` or `sign`.
    init(calendarReply draft: CalendarReplyDraft) {
        to = draft.to
        cc = ""
        bcc = ""
        subject = draft.subject
        body = draft.body
        mode = "plain"
        from = draft.from.isEmpty ? nil : draft.from
        calendarReply = RelayCalendarReplyDTO(ics: draft.ics)
    }
}

// MARK: - Source

final class RelayMailSource: MailSource {
    private let httpClient: HTTPClient
    private let serverUrl: String
    private let auth: RelayAuth

    init(httpClient: HTTPClient, serverUrl: String, auth: RelayAuth) {
        self.httpClient = httpClient
        self.serverUrl = serverUrl
        self.auth = auth
    }

    func listFolders(parent: String?) async throws -> [MailFolder] {
        var query: [URLQueryItem] = []
        if let parent, !parent.isEmpty {
            query.append(URLQueryItem(name: "parent", value: parent))
        }
        let response = try await httpClient.get(
            RelayFolderListResponse.self,
            url: try endpoint("api/inbox/folders"),
            query: query,
            headers: auth.headerFields
        )
        return (response.folders ?? []).map {
            MailFolder(name: $0.path, deletable: $0.deletable ?? false)
        }
    }

    func createFolder(parent: String, name: String) async throws {
        _ = try await httpClient.post(
            RelayActionResponse.self,
            url: try endpoint("api/inbox/folders"),
            headers: auth.headerFields,
            jsonBody: RelayFolderCreateRequest(parent: parent, name: name)
        )
    }

    func renameFolder(folder: String, name: String) async throws {
        _ = try await httpClient.put(
            RelayActionResponse.self,
            url: try endpoint("api/inbox/folders"),
            headers: auth.headerFields,
            jsonBody: RelayFolderRenameRequest(folder: folder, name: name)
        )
    }

    func deleteFolder(folder: String) async throws {
        // The target rides in the query string, not a body — DELETE with a
        // payload is what the relay does not accept here.
        _ = try await httpClient.delete(
            RelayActionResponse.self,
            url: try endpoint("api/inbox/folders"),
            query: [URLQueryItem(name: "folder", value: folder)],
            headers: auth.headerFields
        )
    }

    func fetchEmails(
        folder: String,
        from: Int,
        to: Int,
        since: String
    ) async throws -> MailFetchResult {
        // "" and "0" both mean the whole window; the relay's own default is 0.
        let sinceValue = since.isEmpty ? "0" : since
        let response = try await httpClient.get(
            RelayInboxResponse.self,
            url: try endpoint("api/inbox"),
            query: [
                URLQueryItem(name: "limit", value: String(max(to, 1))),
                URLQueryItem(name: "mailbox", value: folder),
                URLQueryItem(name: "since", value: sinceValue),
            ],
            headers: auth.headerFields
        )
        let emails = response.allEmails(folder: folder)
        return MailFetchResult(
            emails: emails,
            cursor: response.cursor?.value ?? "",
            isDelta: response.delta ?? false,
            updatedIds: response.updatedIds(),
            removedIds: response.removed ?? [],
            // Derived from what we asked for, never from the wire's `delta`
            // flag — see MailFetchResult.isFullWindow.
            isFullWindow: sinceValue == "0",
            agedOutIds: response.agedOut ?? [],
            hasMore: response.hasMore ?? false,
            nextBefore: response.nextBefore
        )
    }

    func fetchOlder(folder: String, limit: Int, before: String) async throws -> MailPage {
        let response = try await httpClient.get(
            RelayInboxResponse.self,
            url: try endpoint("api/inbox"),
            query: [
                URLQueryItem(name: "limit", value: String(max(limit, 1))),
                URLQueryItem(name: "mailbox", value: folder),
                URLQueryItem(name: "before", value: before),
                // A page is metadata only. A server that ignores before=
                // answers with its window, bodies included unless told not to.
                URLQueryItem(name: "bodies", value: "0"),
            ],
            headers: auth.headerFields
        )
        return MailPage(
            emails: response.allEmails(folder: folder),
            hasMore: response.hasMore,
            nextBefore: response.nextBefore
        )
    }

    func fetchBody(folder: String, messageId: String) async throws -> MailMessageBody {
        do {
            let response = try await httpClient.get(
                RelayMessageBodyResponse.self,
                url: try endpoint("api/mail/body"),
                query: [
                    URLQueryItem(name: "mailbox", value: folder),
                    URLQueryItem(name: "messageId", value: messageId),
                ],
                headers: auth.headerFields
            )
            return MailMessageBody(body: response.body ?? "", bodyMode: response.bodyMode ?? "")
        } catch NetworkError.server(statusCode: 404) {
            // Both of these arrived and were answered definitively; telling
            // the user to check their connection would be a lie.
            throw MailSourceError.messageUnavailable(
                String(localized: "This message is no longer on the server.")
            )
        } catch NetworkError.server(statusCode: 413) {
            throw MailSourceError.messageUnavailable(
                String(localized: "This message is too large for the server to open.")
            )
        }
    }

    func searchMail(folder: String, query: String, limit: Int) async throws -> [Email] {
        let response: RelaySearchResponse
        do {
            response = try await httpClient.get(
                RelaySearchResponse.self,
                url: try endpoint("api/mail/search"),
                query: [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "mailbox", value: folder),
                    URLQueryItem(name: "limit", value: String(max(limit, 1))),
                ],
                headers: auth.headerFields
            )
        } catch NetworkError.decoding {
            throw MailSourceError.malformedResponse(String(localized: "Malformed search response"))
        }
        guard let results = response.results else {
            throw MailSourceError.malformedResponse(String(localized: "Malformed search response"))
        }
        // Stamped with the searched folder; the label stands in for the tab.
        return results.map { $0.toDomain(folder: folder, tab: $0.label ?? "") }
    }

    @discardableResult
    func move(messageIds: [String], from mailbox: String, to targetMailbox: String) async throws -> MailActionReport {
        try await performAction("move", messageIds: messageIds, mailbox: mailbox, targetMailbox: targetMailbox)
    }

    @discardableResult
    func delete(messageIds: [String], mailbox: String) async throws -> MailActionReport {
        try await performAction("delete", messageIds: messageIds, mailbox: mailbox)
    }

    @discardableResult
    func archive(messageIds: [String], mailbox: String) async throws -> MailActionReport {
        try await performAction("archive", messageIds: messageIds, mailbox: mailbox)
    }

    @discardableResult
    func markSpam(messageIds: [String], mailbox: String) async throws -> MailActionReport {
        try await performAction("spam", messageIds: messageIds, mailbox: mailbox)
    }

    func markRead(messageIds: [String], mailbox: String) async throws {
        try await performAction("read", messageIds: messageIds, mailbox: mailbox)
    }

    /// POST /api/inbox/actions — the bulk verbs share one body shape
    /// (Mobile_Mail_Relay.md; only "move" carries targetMailbox).
    @discardableResult
    private func performAction(
        _ action: String,
        messageIds: [String],
        mailbox: String,
        targetMailbox: String? = nil
    ) async throws -> MailActionReport {
        try await httpClient.post(
            RelayActionResponse.self,
            url: try endpoint("api/inbox/actions"),
            headers: auth.headerFields,
            jsonBody: RelayActionRequest(
                action: action,
                messageIds: messageIds,
                mailbox: mailbox,
                targetMailbox: targetMailbox
            )
        ).report
    }

    func listAttachments(folder: String, messageId: String) async throws -> [EmailAttachment] {
        let response = try await httpClient.get(
            RelayAttachmentListResponse.self,
            url: try endpoint("api/mail/attachments"),
            query: [
                URLQueryItem(name: "mailbox", value: folder),
                URLQueryItem(name: "messageId", value: messageId),
            ],
            headers: auth.headerFields
        )
        return (response.attachments ?? []).map { $0.toDomain() }
    }

    func downloadAttachment(folder: String, messageId: String, index: Int) async throws -> Data {
        try await httpClient.getData(
            url: try endpoint("api/mail/attachment"),
            query: [
                URLQueryItem(name: "mailbox", value: folder),
                URLQueryItem(name: "messageId", value: messageId),
                URLQueryItem(name: "index", value: String(index)),
            ],
            headers: auth.headerFields
        )
    }

    /// The send's idle timeout with attachments on board. The relay answers
    /// only after SMTP accepted the message (and the Sent copy was saved), so
    /// a large message can sit silent past the session's 60 s after its last
    /// byte went up — and a timeout there is a send whose outcome is unknown.
    static let sendWithAttachmentsTimeout: TimeInterval = 180

    @discardableResult
    func send(email: OutgoingEmail) async throws -> String {
        var headers = auth.headerFields
        if let key = email.idempotencyKey, !key.isEmpty {
            headers["Idempotency-Key"] = key
        }
        do {
            let response = try await httpClient.post(
                RelaySendResponse.self,
                url: try endpoint("api/mail/send"),
                headers: headers,
                jsonBody: RelaySendRequest(from: email),
                timeout: email.attachments.isEmpty ? nil : Self.sendWithAttachmentsTimeout
            )
            return response.warning ?? ""
        } catch NetworkError.conflict(let body) {
            throw Self.conflictError(body: body) ?? NetworkError.conflict(body: body)
        }
    }

    /// Sends an RSVP. Returns whether the relay acknowledged it as a calendar
    /// reply; a 200 without that is plain mail to the organizer.
    func sendCalendarReply(_ draft: CalendarReplyDraft) async throws -> Bool {
        let response = try await httpClient.post(
            RelaySendResponse.self,
            url: try endpoint("api/mail/send"),
            headers: auth.headerFields,
            jsonBody: RelaySendRequest(calendarReply: draft)
        )
        return response.calendarReply == true
    }

    func saveDraft(email: OutgoingEmail) async throws {
        // {"ok": true} — same shape as the bulk-action reply, so no extra DTO.
        _ = try await httpClient.post(
            RelayActionResponse.self,
            url: try endpoint("api/mail/draft"),
            headers: auth.headerFields,
            jsonBody: RelaySendRequest(from: email, pgpFlags: false)
        )
    }

    /// Which PGP refusal a relay 409 body represents, or nil for an ordinary
    /// conflict the caller should surface generically.
    ///
    /// Pure so it is testable without a transport, and so the relay-specific
    /// knowledge stays here rather than in HTTPClient. Discriminates by field:
    /// the error strings are user-facing copy and may be reworded.
    static func conflictError(body: String) -> MailSourceError? {
        guard let data = body.data(using: .utf8),
              let dto = try? JSONDecoder().decode(RelayConflictDTO.self, from: data)
        else { return nil }
        if dto.clientSideNeeded == true {
            return .clientSideNeeded
        }
        if let addresses = dto.keylessRecipients, !addresses.isEmpty {
            return .keylessRecipients(
                addresses: addresses,
                pickupFallbackAvailable: dto.pickupFallbackAvailable ?? false
            )
        }
        return nil
    }

    /// The relay's 400 for an account with no mail set up, as its plain-text
    /// body, or nil for an ordinary malformed request.
    ///
    /// Prefix match on the documented wording (`Mobile_Mail_Relay.md`'s error
    /// table, Android's `MailOutcome.NotConfigured`) because that is the only
    /// discriminator the relay offers on this path — a 400 carries no JSON
    /// field to key off, unlike the two 409s. Kept here with the other
    /// relay-specific knowledge rather than in HTTPClient.
    static func notConfiguredMessage(body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("imap configuration is required") else {
            return nil
        }
        return trimmed
    }

    // MARK: - Private

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: serverUrl) else {
            throw MailSourceError.invalidServerURL
        }
        return url.appending(path: path)
    }
}
