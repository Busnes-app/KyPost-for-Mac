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

    /// Moves messages between folders via the relay's bulk-actions endpoint.
    func move(messageIds: [String], from mailbox: String, to targetMailbox: String) async throws {
        try await makeSource().move(messageIds: messageIds, from: mailbox, to: targetMailbox)
    }

    /// Deletes messages via the relay: moved to Trash, or expunged when
    /// `mailbox` is already Trash.
    func delete(messageIds: [String], from mailbox: String) async throws {
        try await makeSource().delete(messageIds: messageIds, mailbox: mailbox)
    }

    /// Archives messages via the relay (moved to the Archive folder).
    func archive(messageIds: [String], from mailbox: String) async throws {
        try await makeSource().archive(messageIds: messageIds, mailbox: mailbox)
    }

    /// Marks messages as junk via the relay (moved to Junk).
    func markSpam(messageIds: [String], from mailbox: String) async throws {
        try await makeSource().markSpam(messageIds: messageIds, mailbox: mailbox)
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

    /// The paired server's base URL, for building webmail links. Nil when
    /// unpaired, so callers show no link rather than a dead one.
    var pairedServerUrl: String? {
        guard let pairing = try? securePairingStore.loadPairing(),
              !pairing.srv.isEmpty
        else { return nil }
        return pairing.srv
    }
}
