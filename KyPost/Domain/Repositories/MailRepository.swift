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

    /// The relay source; requires a stored pairing whose mail has not been
    /// forgotten.
    func makeSource() throws -> any MailSource {
        if let overrideSource { return overrideSource }
        let pairing = try currentPairing()
        return RelayMailSource(
            httpClient: httpClient,
            serverUrl: pairing.srv,
            auth: RelayAuth(pairing: pairing)
        )
    }

    /// The stored pairing, unless an account teardown retired it
    /// (`SecurePairingStore.retireCurrentPairing`).
    private func currentPairing() throws -> Pairing {
        guard let pairing = try securePairingStore.loadActivePairing() else {
            throw MailSourceError.notPaired
        }
        return pairing
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

    /// One window size for every `/api/inbox` request, refresh and page
    /// alike: the relay keeps a window and cursor per `limit`, and a cursor
    /// sent with another limit is one that window never issued.
    static let windowLimit = 50

    /// ponytail: an overflow walk stops after this many pages and commits the
    /// cursor anyway, leaving anything older unlisted. Upgrade path: persist
    /// the paging frontier and resume from it.
    static let maxOverflowPages = 20

    /// Fetches a folder from the server and reconciles it into the cache.
    ///
    /// Sends the stored cursor when there is one, so the relay can answer with
    /// just what changed. `forceFullResync` asks for the whole window
    /// regardless — the documented self-heal for a removal this device was
    /// never told about, and what a push tap must do before opening its target.
    ///
    /// A delta that reports more new mail than its window held (`hasMore`) is
    /// followed down with `before=` pages until one reaches mail already held;
    /// the window and those pages are stored together, and only then is the
    /// cursor committed. A walk that fails or contradicts itself throws and
    /// stores nothing, so the retry walks every page again.
    ///
    /// Returns every cached row of the folder, older mail included.
    @discardableResult
    func refreshFolder(_ folder: String, forceFullResync: Bool = false) async throws -> [Email] {
        // The override has no pairing and no cursor to advance; snapshot it
        // straight into the cache and let the rest of the app read normally.
        // Before any network step: a request that outlives `forgetAccount`
        // must not write the forgotten account's mail back.
        let epoch = await emailDAO.accountEpoch
        if let overrideSource {
            let result = try await overrideSource.fetchEmails(
                folder: folder, from: 0, to: Self.windowLimit, since: ""
            )
            try await emailDAO.replaceFolderSnapshot(folder: folder, emails: result.emails, epoch: epoch)
            return try await emailDAO.getFolder(folder: folder)
        }
        let pairingId = try currentPairing().sub
        // A cursor describes rows this device holds. With none held — a fresh
        // or discarded store, a schema change, a Hostile Location Protection
        // switch — a delta would only list what changed since, and the folder
        // would stay empty until the daily resync.
        let holdsRows = try await emailDAO.hasRows(folder: folder)
        let wantsFullWindow = forceFullResync || !holdsRows
            || cursorStore?.shouldForceFullResync(pairingId: pairingId, folder: folder) ?? true
        let since = wantsFullWindow
            ? ""
            : cursorStore?.cursor(pairingId: pairingId, folder: folder) ?? ""

        let source = try makeSource()
        let result = try await source.fetchEmails(
            folder: folder, from: 0, to: Self.windowLimit, since: since
        )
        // Fetched before anything is written, so "held" means held before
        // this refresh.
        let overflow = result.isDelta && !result.isFullWindow && result.hasMore
            ? try await fetchOverflow(folder: folder, from: result.nextBefore, source: source)
            : []
        try await emailDAO.reconcile(folder: folder, result: result, overflow: overflow, epoch: epoch)
        // Nor its cursor.
        guard await emailDAO.accountEpoch == epoch else { throw EmailDAO.AccountForgotten() }

        // Only after the rows are committed: a crash between the two costs a
        // refetch, where advancing first would lose the messages for good.
        cursorStore?.saveCursor(pairingId: pairingId, folder: folder, cursor: result.cursor)
        if result.isFullWindow {
            cursorStore?.recordFullResync(pairingId: pairingId, folder: folder)
        }
        return try await emailDAO.getFolder(folder: folder)
    }

    /// More new mail arrived than the window holds: page down from
    /// `nextBefore` until a page holds an id the folder already had. Any
    /// failure throws — nothing of the walk may be stored.
    private func fetchOverflow(
        folder: String,
        from nextBefore: String?,
        source: any MailSource
    ) async throws -> [Email] {
        let held = try await emailDAO.heldIds(folder: folder)
        var pages: [Email] = []
        var before = nextBefore
        for _ in 0..<Self.maxOverflowPages {
            guard let anchor = before, !anchor.isEmpty else {
                throw MailSourceError.overflowUnreachable
            }
            let page = try await source.fetchOlder(folder: folder, limit: Self.windowLimit, before: anchor)
            // This server announced overflow, so a page without hasMore
            // contradicts it.
            guard let hasMore = page.hasMore else { throw MailSourceError.overflowUnreachable }
            pages += page.emails
            if !hasMore || page.emails.contains(where: { held.contains($0.serverId) }) {
                return pages
            }
            before = page.nextBefore == anchor ? nil : page.nextBefore
        }
        return pages
    }

    /// Erases the account's mail from this device: every cached row (window,
    /// older mail, fetched bodies) and every cursor. For an unpair and for a
    /// pairing that replaces the account. A refresh, page or body fetch still
    /// in flight is refused when it comes back (`EmailDAO.accountEpoch`), and
    /// the pairing still stored is refused from here on (`currentPairing`).
    /// Recorded before the epoch moves, so a request that captures the new
    /// epoch can no longer reach the old account.
    func forgetAccount() async throws {
        securePairingStore.retireCurrentPairing()
        defer { cursorStore?.clear() }
        try await emailDAO.forgetAccount()
    }

    /// Cached rows of a folder, newest first — every row unless `limit` caps
    /// it — for offline/instant display.
    func cachedFolder(_ folder: String, limit: Int? = nil) async throws -> [Email] {
        try await emailDAO.getFolder(folder: folder, limit: limit)
    }

    /// How many results one search asks for.
    static let searchLimit = 50

    /// Searches `folder` on the server, every field. The results are a view
    /// of the folder, not its sync window: they are never written to the
    /// cache, so they can never prune it or be mistaken for it.
    func search(_ query: String, in folder: String) async throws -> [Email] {
        try await makeSource().searchMail(
            folder: folder,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: Self.searchLimit
        )
    }

    /// What one "Load older mail" press produced.
    enum OlderMailOutcome: Equatable {
        /// A page was stored. `nextBefore` is where the next one starts; nil
        /// when there is nothing older left.
        case loaded(nextBefore: String?)
        /// The folder holds no row to page from.
        case nothingToPageFrom
        /// The server ignored `before=`; nothing was stored.
        case unsupported(String)
        /// Nothing was stored. `staleAnchor` means the relay refused the
        /// anchor itself (400) — retry from the oldest row held; any other
        /// failure retries the same page.
        case failed(String, staleAnchor: Bool)
    }

    /// One page older than `frontier` — the previous page's `nextBefore` — or,
    /// with no frontier yet, than the oldest row the folder holds. The page
    /// lands out of the window, so no snapshot ever prunes it.
    func loadOlder(folder: String, frontier: String?) async -> OlderMailOutcome {
        let epoch = await emailDAO.accountEpoch
        let notSaved = String(localized: "Couldn't save older mail on this device. Free up storage and try again.")
        let anchor: String
        if let frontier, !frontier.isEmpty {
            anchor = frontier
        } else {
            // A failed read is not an empty folder: report it, so the caller
            // keeps offering a retry.
            do {
                guard let oldest = try await emailDAO.oldestRowId(folder: folder) else {
                    return .nothingToPageFrom
                }
                anchor = oldest
            } catch {
                return .failed(notSaved, staleAnchor: false)
            }
        }
        let page: MailPage
        do {
            page = try await makeSource().fetchOlder(folder: folder, limit: Self.windowLimit, before: anchor)
        } catch {
            let outcome = MailOutcome.from(error)
            let message = outcome.userMessage ?? String(localized: "Unable to connect to the mail server.")
            if let networkError = error as? NetworkError, case .badRequest = networkError,
               case .failure = outcome {
                return .failed(message, staleAnchor: true)
            }
            return .failed(message, staleAnchor: false)
        }
        guard let hasMore = page.hasMore else {
            return .unsupported(
                String(localized: "This server can't load older mail. Update KyPost Server to use this.")
            )
        }
        do {
            try await emailDAO.storeOlderMail(folder: folder, emails: page.emails, epoch: epoch)
        } catch {
            return .failed(notSaved, staleAnchor: false)
        }
        let next = page.nextBefore.flatMap { $0.isEmpty || $0 == anchor ? nil : $0 }
        return .loaded(nextBefore: hasMore ? next : nil)
    }

    /// Whether the reader must fetch `email`'s body: it arrived without one
    /// (older mail, a delta overflow page, a search result). A blank body on a
    /// `pgpEncrypted` row is the client-protected shape, not a missing body —
    /// fetching there would hide the decrypt path behind the server's answer.
    nonisolated static func needsBodyFetch(_ email: Email) -> Bool {
        email.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !email.pgpEncrypted
    }

    /// The body for the reader when the row has none, via `/api/mail/body`;
    /// nil when the row's own body stands. Cached only on a window row: an
    /// out-of-window row carries no PGP flags, so its body could be server
    /// plaintext of encrypted mail stored under no marker. Out-of-window and
    /// uncached messages fetch again on every open.
    ///
    /// A search result is never cached, but the same (folder, id) may be: its
    /// cached body is used rather than fetched again, **with the cached row's
    /// OpenPGP state** — a result carries none, and the reader must not lose
    /// a cached verdict (or the client-protected shape, a blank body on an
    /// encrypted row) by opening the message from the results.
    func loadBody(for email: Email) async throws -> MailMessageBody? {
        guard Self.needsBodyFetch(email) else { return nil }
        let epoch = await emailDAO.accountEpoch
        let row = try? await emailDAO.getEmail(folder: email.folder, serverId: email.serverId)
        if let row, !row.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || row.pgpEncrypted {
            return MailMessageBody(body: row.body, bodyMode: row.bodyMode, cachedPgp: MailPgpFields(of: row))
        }
        let fetched = try await makeSource().fetchBody(folder: email.folder, messageId: email.serverId)
        if let row, row.inWindow {
            try? await emailDAO.updateBody(
                folder: email.folder, serverId: email.serverId,
                body: fetched.body, bodyMode: fetched.bodyMode, epoch: epoch
            )
        }
        return fetched
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
            try await emailDAO.updateEmail(folder: mailbox, serverId: messageId, read: true)
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

    /// Updates the local read flag of the row in `folder` and, when marking
    /// read, syncs it to the relay so other devices see it — the relay has a
    /// "read" action but no "unread" counterpart.
    func markRead(serverId: String, folder: String, read: Bool = true) async throws {
        try await emailDAO.updateEmail(folder: folder, serverId: serverId, read: read)
        if read {
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
         NetworkError.certificateMismatch, NetworkError.pinUnreadable, NetworkError.invalidURL:
        true
    case MailSourceError.notPaired, MailSourceError.credentialUnavailable,
         MailSourceError.invalidServerURL, MailSourceError.notConfigured,
         MailSourceError.clientSideNeeded:
        true
    default:
        false
    }
}
