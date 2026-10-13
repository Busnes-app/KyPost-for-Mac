//
//  MailRepository.swift
//  KyPost
//
//  Mail access through the paired relay, keeping the local cache (EmailDAO)
//  in sync so the inbox works offline.
//

import Foundation

final class MailRepository {
    private let securePairingStore: SecurePairingStore
    private let emailDAO: EmailDAO
    private let httpClient: HTTPClient
    /// Nil in tests that only exercise full snapshots; the delta path then
    /// behaves exactly as the pre-cursor code did.
    private let cursorStore: (any MailCursorProviding)?
    /// Serves every call in place of the relay, and stands in for the pairing
    /// the relay path requires. Nil everywhere except the DEBUG screenshot
    /// build (SingletonGraph, DemoContent.isEnabled).
    private let overrideSource: (any MailSource)?

    init(
        securePairingStore: SecurePairingStore,
        emailDAO: EmailDAO,
        httpClient: HTTPClient,
        cursorStore: (any MailCursorProviding)? = nil,
        overrideSource: (any MailSource)? = nil
    ) {
        self.securePairingStore = securePairingStore
        self.emailDAO = emailDAO
        self.httpClient = httpClient
        self.cursorStore = cursorStore
        self.overrideSource = overrideSource
    }

    /// The relay source; requires a stored pairing.
    func makeSource() throws -> any MailSource {
        if let overrideSource { return overrideSource }
        guard let pairing = try securePairingStore.loadPairing() else {
            throw MailSourceError.notPaired
        }
        return RelayMailSource(
            httpClient: httpClient,
            serverUrl: pairing.srv,
            auth: RelayAuth(pairing: pairing)
        )
    }

    func listFolders(parent: String? = nil) async throws -> [MailFolder] {
        try await makeSource().listFolders(parent: parent)
    }

    /// Folder management. Each returns a MailOutcome rather than throwing, so
    /// a 429 or an unconfigured account reads the same here as on the send
    /// path instead of surfacing a raw error.
    func createFolder(parent: String, name: String) async -> MailOutcome {
        await folderMutation { try await $0.createFolder(parent: parent, name: name) }
    }

    func renameFolder(_ folder: String, to name: String) async -> MailOutcome {
        await folderMutation { try await $0.renameFolder(folder: folder, name: name) }
    }

    func deleteFolder(_ folder: String) async -> MailOutcome {
        await folderMutation { try await $0.deleteFolder(folder: folder) }
    }

    private func folderMutation(
        _ body: (any MailSource) async throws -> Void
    ) async -> MailOutcome {
        do {
            try await body(try makeSource())
            return .success
        } catch {
            return MailOutcome.from(error)
        }
    }

    /// Fetches a folder from the server and reconciles it into the cache.
    ///
    /// Sends the stored cursor when there is one, so the relay can answer with
    /// just what changed. `forceFullResync` asks for the whole window
    /// regardless — the documented self-heal for a removal this device was
    /// never told about, and what a push tap must do before opening its target.
    @discardableResult
    func refreshFolder(
        _ folder: String,
        from: Int = 0,
        to: Int = 50,
        forceFullResync: Bool = false
    ) async throws -> [Email] {
        // The override has no pairing and no cursor to advance; snapshot it
        // straight into the cache and let the rest of the app read normally.
        if let overrideSource {
            let result = try await overrideSource.fetchEmails(
                folder: folder, from: from, to: to, since: ""
            )
            try await emailDAO.replaceFolderSnapshot(folder: folder, emails: result.emails)
            return try await emailDAO.getFolder(folder: folder, limit: max(to, 1))
        }
        guard let pairing = try securePairingStore.loadPairing() else {
            throw MailSourceError.notPaired
        }
        let pairingId = pairing.sub
        let wantsFullWindow = forceFullResync
            || cursorStore?.shouldForceFullResync(pairingId: pairingId, folder: folder) ?? true
        let since = wantsFullWindow
            ? ""
            : cursorStore?.cursor(pairingId: pairingId, folder: folder) ?? ""

        let result = try await makeSource()
            .fetchEmails(folder: folder, from: from, to: to, since: since)

        if result.isDelta {
            try await emailDAO.applyDelta(
                folder: folder,
                emails: result.emails,
                updatedIds: result.updatedIds,
                removedIds: result.removedIds,
                pruneAgainstEmails: result.isFullWindow
            )
        } else {
            try await emailDAO.replaceFolderSnapshot(folder: folder, emails: result.emails)
        }

        // Only after the rows are committed: a crash between the two costs a
        // refetch, where advancing first would lose the messages for good.
        cursorStore?.saveCursor(pairingId: pairingId, folder: folder, cursor: result.cursor)
        if result.isFullWindow {
            cursorStore?.recordFullResync(pairingId: pairingId, folder: folder)
        }
        return try await emailDAO.getFolder(folder: folder, limit: max(to, 1))
    }

    /// Cached emails for offline/instant display.
    func cachedFolder(_ folder: String, limit: Int = 50, offset: Int = 0) async throws -> [Email] {
        try await emailDAO.getFolder(folder: folder, limit: limit, offset: offset)
    }

    /// Search runs against the local cache (the relay has no search endpoint).
    func search(folder: String, query: String) async throws -> [Email] {
        try await emailDAO.search(folder: folder, query: query)
    }

    /// The relay's per-request cap on `/api/inbox/actions` (server
    /// `maxInboxActionIDs`). The selection enforces it; this refuses rather
    /// than sending a request the relay answers with 413.
    static let maxActionIds = 500

    /// Runs one of the moving actions on `messageIds` in `folder`, one relay
    /// call, and drops **only the cached rows the relay confirmed**.
    ///
    /// HTTP 200 is not success: the relay answers 200 with per-id `failed[]`,
    /// and stops early on a cancelled request, leaving ids in neither list.
    /// So an id is confirmed only when it is absent from `failed[]` *and*
    /// `processed` equals the number of such ids; a shortfall `failed[]` does
    /// not explain confirms nothing. Keeping a row the server may have moved
    /// costs a redundant line until the next refresh; the other way round
    /// hides mail that never moved.
    ///
    /// `source` lets a caller bind the credentials before they become
    /// unreadable — the undo window commits on app lock, which drops the
    /// gated device secret. Nil resolves it now.
    func applyAction(
        _ action: MailMoveAction,
        messageIds: [String],
        from folder: String,
        to target: String? = nil,
        source: (any MailSource)? = nil
    ) async -> MailActionResult {
        // The relay trims and de-duplicates before counting `processed`, so
        // send what it will count, or a duplicate reads as a shortfall.
        var seen = Set<String>()
        let ids = messageIds
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ids.isEmpty else { return MailActionResult(confirmedIds: []) }
        guard ids.count <= Self.maxActionIds else {
            return MailActionResult(
                confirmedIds: [],
                failureMessage: String(localized: "Up to \(Self.maxActionIds) messages at a time")
            )
        }
        if action == .move, (target ?? "").isEmpty {
            return MailActionResult(
                confirmedIds: [],
                failureMessage: String(localized: "Choose a folder to move to.")
            )
        }
        let report: MailActionReport
        do {
            let source = try source ?? makeSource()
            switch action {
            case .archive: report = try await source.archive(messageIds: ids, mailbox: folder)
            case .delete: report = try await source.delete(messageIds: ids, mailbox: folder)
            case .spam: report = try await source.markSpam(messageIds: ids, mailbox: folder)
            case .move: report = try await source.move(messageIds: ids, from: folder, to: target ?? "")
            }
        } catch {
            return MailActionResult(
                confirmedIds: [],
                failureMessage: MailOutcome.from(error).userMessage
            )
        }
        let failedIds = Set(report.failed.map(\.messageId))
        let unexplained = ids.filter { !failedIds.contains($0) }
        guard report.processed == unexplained.count else {
            return MailActionResult(
                confirmedIds: [],
                failureMessage: String(localized: "The server reported an incomplete change.")
            )
        }
        try? await emailDAO.deleteEmails(serverIds: unexplained, folder: folder)
        guard let first = report.failed.first else {
            return MailActionResult(confirmedIds: unexplained)
        }
        return MailActionResult(
            confirmedIds: unexplained,
            failureMessage: String(
                localized: "\(report.failed.count) of \(ids.count) not changed: \(first.error)"
            )
        )
    }

    /// Marks messages read via the relay's bulk action and mirrors the flag
    /// into the cache. List-action counterpart of the single-email
    /// `markRead(serverId:folder:read:)` below.
    func markRead(messageIds: [String], from mailbox: String) async throws {
        try await makeSource().markRead(messageIds: messageIds, mailbox: mailbox)
        for messageId in messageIds {
            try await emailDAO.updateEmail(serverId: messageId, read: true)
        }
    }

    /// Attachment metadata for one cached email (lazy, on open).
    func listAttachments(folder: String, messageId: String) async throws -> [EmailAttachment] {
        try await makeSource().listAttachments(folder: folder, messageId: messageId)
    }

    /// Raw bytes of one attachment.
    func downloadAttachment(folder: String, messageId: String, index: Int) async throws -> Data {
        try await makeSource().downloadAttachment(folder: folder, messageId: messageId, index: index)
    }

    /// Updates the local read flag and (when marking read from a known
    /// mailbox) syncs it to the relay so other devices see it — the relay has
    /// a "read" action but no "unread" counterpart.
    func markRead(serverId: String, folder: String? = nil, read: Bool = true) async throws {
        try await emailDAO.updateEmail(serverId: serverId, read: read)
        if read, let folder {
            try await makeSource().markRead(messageIds: [serverId], mailbox: folder)
        }
    }

    func send(_ email: OutgoingEmail) async -> MailOutcome {
        do {
            let warning = try await makeSource().send(email: email)
            return warning.isEmpty ? .success : .sentWithWarning(warning)
        } catch {
            return MailOutcome.from(error)
        }
    }

    /// Saves a draft on the server so the webmail handoff has something to
    /// open. Same failure mapping as `send`.
    func saveDraft(_ email: OutgoingEmail) async -> MailOutcome {
        do {
            try await makeSource().saveDraft(email: email)
            return .success
        } catch {
            return MailOutcome.from(error)
        }
    }

    /// The pairing a send is bound to, or nil when unpaired.
    func currentAccount() -> MailAccountBinding? {
        guard overrideSource == nil, let pairing = try? securePairingStore.loadPairing() else { return nil }
        return MailAccountBinding(pairing)
    }

    /// Sends an RSVP **only as the account it was confirmed under**. Nil, with
    /// no I/O, when the pairing was removed or replaced since: the same read
    /// that authenticates the request is the one compared, so an old account's
    /// reply never reaches a new relay.
    func sendCalendarReply(
        _ draft: CalendarReplyDraft,
        as account: MailAccountBinding
    ) async -> (result: RsvpResult, reason: String)? {
        let pairing: Pairing?
        do {
            pairing = try securePairingStore.loadPairing()
        } catch {
            // The credential is behind the lock: nothing was sent.
            return (.refused, MailOutcome.from(error).reason)
        }
        guard let pairing, MailAccountBinding(pairing) == account else { return nil }
        let source = RelayMailSource(
            httpClient: httpClient,
            serverUrl: pairing.srv,
            auth: RelayAuth(pairing: pairing)
        )
        do {
            return try await source.sendCalendarReply(draft) ? (.sent, "") : (.sentAsPlainMail, "")
        } catch {
            return (rsvpRefusedBeforeSending(error) ? .refused : .maybeSent, MailOutcome.from(error).reason)
        }
    }

    /// The paired server's base URL, for building webmail links. Nil when
    /// unpaired, so callers show no link rather than a dead one.
    var pairedServerUrl: String? {
        guard let pairing = try? securePairingStore.loadPairing(),
              !pairing.srv.isEmpty
        else { return nil }
        return pairing.srv
    }
}

/// Which pairing a send was confirmed under. `pairedAt` changes on every
/// re-pair, so a replaced pairing for the same account still compares
/// unequal.
nonisolated struct MailAccountBinding: Equatable, Sendable {
    var sub: String
    var srv: String
    var pairedAt: Date

    init(_ pairing: Pairing) {
        sub = pairing.sub
        srv = pairing.srv
        pairedAt = pairing.pairedAt
    }
}

/// True when the relay answered and refused, so nothing went out and asking
/// again is safe. Anything else — a timeout, a 5xx, an answer that would not
/// decode — may have been sent.
nonisolated func rsvpRefusedBeforeSending(_ error: Error) -> Bool {
    switch error {
    case NetworkError.badRequest, NetworkError.unauthorized, NetworkError.conflict,
         NetworkError.rateLimited, NetworkError.serviceUnavailable,
         NetworkError.certificateMismatch, NetworkError.invalidURL:
        true
    case MailSourceError.notPaired, MailSourceError.credentialUnavailable,
         MailSourceError.invalidServerURL, MailSourceError.notConfigured,
         MailSourceError.clientSideNeeded:
        true
    default:
        false
    }
}
