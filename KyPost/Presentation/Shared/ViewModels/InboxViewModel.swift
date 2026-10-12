//
//  InboxViewModel.swift
//  KyPost
//
//  Inbox state: cached-first load, server refresh, keyword tab filtering,
//  the 90-second foreground refresh cadence (spec §2), list actions held for
//  Undo, and the freshness / empty-folder / new-mail signals.
//

import Foundation
import Observation

@Observable
@MainActor
final class InboxViewModel {
    private let mailRepository: MailRepository
    private let keywordRepository: KeywordRepository
    private let initialRefreshErrorDelay: Duration
    private let initialRefreshRetryDelay: Duration
    private let undoWindow: Duration
    private let noticeDuration: Duration
    private let now: () -> Date
    /// Whether the user's "show All" setting shapes the tab strip. On macOS
    /// the sidebar's Inbox row *is* the folder and its keyword rows sit under
    /// it, so there is no All chip to hide.
    private let appliesAllTabSetting: Bool

    private(set) var folder = Config.defaultFolder
    private(set) var emails: [Email] = []
    private(set) var tabs: [KeywordTab] = []
    /// Server-side children of Inbox and Archive, for folder navigation.
    private(set) var inboxSubfolders: [MailFolder] = []
    private(set) var archiveSubfolders: [MailFolder] = []
    /// The relay's top-level folders (it omits INBOX and Archive). Feeds the
    /// move pickers and Sent/Drafts resolution.
    private(set) var topLevelFolders: [MailFolder] = []
    var selectedTab: String? {
        didSet {
            if oldValue != selectedTab { newMailCount = 0 }
        }
    }
    /// Whether the tab strip leads with All.
    private(set) var showsAllTab = true
    private(set) var errorMessage: String?
    private(set) var connectionNotice: String?
    /// A transient sentence for the toast: a rejected action, a missing
    /// Sent folder, the selection limit. Expires on its own.
    private(set) var notice: String?
    private var hasLoaded = false

    /// Folders with a refresh in flight. Per folder, so a slow refresh of the
    /// folder just left cannot block the one now on screen.
    private var refreshingFolders: Set<String> = []
    /// When each folder last refreshed successfully, for the freshness line.
    private var refreshedAt: [String: Date] = [:]
    /// The folder on screen once it has refreshed successfully; nil while it
    /// is loading or after a failure, when its emptiness is unknown.
    private(set) var loadedFolder: String?
    /// The folder whose rows were last painted, so only a repaint of the same
    /// folder (and tab) can announce new mail.
    private var paintedFolder: String?

    /// New rows that landed above the top while the user was scrolled away.
    private(set) var newMailCount = 0
    /// Bumped when new rows land while the list is at the top, so the view
    /// keeps them in sight.
    private(set) var scrollToTopRequest = 0
    private var isListAtTop = true

    /// List actions waiting out the undo window, and those sent but not yet
    /// answered. Both stay hidden: the first so Undo has something to take
    /// back, the second so rows do not flicker back before the relay answers.
    private var pending = PendingMailActions()
    private var inFlightKeys: Set<MailRowKey> = []
    private(set) var undoMessage: String?
    private var undoTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    private var refreshTask: Task<Void, Never>?
    private var delayedRefreshErrorTask: Task<Void, Never>?
    private var initialRefreshRetryTask: Task<Void, Never>?

    init(
        mailRepository: MailRepository,
        keywordRepository: KeywordRepository,
        initialRefreshErrorDelay: Duration = .seconds(90),
        initialRefreshRetryDelay: Duration = .seconds(15),
        undoWindow: Duration = .seconds(5),
        noticeDuration: Duration = .seconds(4),
        appliesAllTabSetting: Bool = InboxViewModel.platformHasTabStrip,
        now: @escaping () -> Date = Date.init
    ) {
        self.mailRepository = mailRepository
        self.keywordRepository = keywordRepository
        self.initialRefreshErrorDelay = initialRefreshErrorDelay
        self.initialRefreshRetryDelay = initialRefreshRetryDelay
        self.undoWindow = undoWindow
        self.noticeDuration = noticeDuration
        self.appliesAllTabSetting = appliesAllTabSetting
        self.now = now
    }

    nonisolated static var platformHasTabStrip: Bool {
#if os(macOS)
        false
#else
        true
#endif
    }

    // MARK: - What the list shows

    /// The folder's rows minus those held for Undo or awaiting the relay.
    var visibleEmails: [Email] {
        let hidden = pending.heldKeys.union(inFlightKeys)
        guard !hidden.isEmpty else { return emails }
        return emails.filter { !hidden.contains(MailRowKey(folder: $0.folder, serverId: $0.serverId)) }
    }

    var filteredEmails: [Email] {
        guard let selectedTab else { return visibleEmails }
        return visibleEmails.filter { $0.keywords.contains(selectedTab) }
    }

    /// No chips at all once All and every keyword are hidden: the list then
    /// shows everything, unfiltered.
    var showsTabStrip: Bool {
        showsAllTab || !tabs.isEmpty
    }

    /// Sent or Drafts when the folder on screen resolved to one of them.
    var currentSpecialFolder: SpecialFolder? {
        InboxRules.specialFolder(of: folder)
    }

    var folderDisplayName: String {
        currentSpecialFolder?.label ?? StandardFolder.displayName(folder)
    }

    /// When the folder on screen last refreshed successfully.
    var lastRefreshed: Date? { refreshedAt[folder] }

    var isRefreshing: Bool { refreshingFolders.contains(folder) }

    /// Whether "No messages in …" is true — only once this folder refreshed.
    var showsEmptyFolderState: Bool {
        InboxRules.showsEmptyFolder(
            shown: filteredEmails.count, loadedFolder: loadedFolder, currentFolder: folder
        )
    }

    var emptyFolderMessage: String {
        if let selectedTab {
            return String(localized: "Nothing tagged \(selectedTab)")
        }
        return String(localized: "No messages in \(folderDisplayName)")
    }

    // MARK: - Folders

    /// Switches to another server folder (Junk, Trash, Archive/…) and reloads,
    /// optionally landing on a keyword tab. Held actions keep their own pinned
    /// folder, so the switch neither sends nor drops them.
    func selectFolder(_ name: String, tab: String? = nil) async {
        guard folder != name else {
            selectedTab = tab
            reconcileSelectedTab()
            return
        }
        resetForFolder(name, tab: tab)
        await load()
    }

    private func resetForFolder(_ name: String, tab: String?) {
        folder = name
        selectedTab = tab
        emails = []
        tabs = []
        errorMessage = nil
        connectionNotice = nil
        loadedFolder = nil
        paintedFolder = nil
        newMailCount = 0
    }

    /// Best-effort fetch of the folder lists: Inbox and Archive children
    /// (paths come back full, e.g. "INBOX/Receipts"), and the top level.
    func loadSubfolders() async {
        if let folders = try? await mailRepository.listFolders(parent: StandardFolder.inbox) {
            inboxSubfolders = folders
        }
        if let folders = try? await mailRepository.listFolders(parent: StandardFolder.archive) {
            archiveSubfolders = folders
        }
        if let folders = try? await mailRepository.listFolders(parent: nil) {
            topLevelFolders = folders
        }
    }

    /// Opens Sent or Drafts by resolving the account's real path from a fresh
    /// top-level listing. Never guesses a name and never creates a folder: no
    /// match is reported, and the folder on screen stays where it was.
    @discardableResult
    func openSpecialFolder(_ kind: SpecialFolder) async -> Bool {
        let folders: [MailFolder]
        do {
            folders = try await mailRepository.listFolders(parent: nil)
        } catch {
            showNotice(MailOutcome.from(error).userMessage
                ?? String(localized: "Unable to connect to the mail server."))
            return false
        }
        topLevelFolders = folders
        guard let path = InboxRules.resolveSpecialFolder(kind, in: folders.map(\.name)) else {
            showNotice(String(localized: "No \(kind.label) folder on this account"))
            return false
        }
        await selectFolder(path)
        return true
    }

    /// The resolved path of Sent or Drafts from the last top-level listing,
    /// for drop targets that cannot wait on a fetch.
    func specialFolderPath(_ kind: SpecialFolder) -> String? {
        InboxRules.resolveSpecialFolder(kind, in: topLevelFolders.map(\.name))
    }

    /// Where a message in `current` can be moved (see InboxRules.moveTargets).
    func moveTargets(from current: String) -> [String] {
        InboxRules.moveTargets(
            current: current,
            inboxChildren: inboxSubfolders.map(\.name),
            topLevel: topLevelFolders.map(\.name),
            archiveChildren: archiveSubfolders.map(\.name)
        )
    }

    /// Move targets for rows in the folder on screen.
    var moveDestinations: [String] {
        moveTargets(from: folder)
    }

    // MARK: - Folder management

    /// Creates a child of `parent` ("" for top level) and refreshes the tree.
    func createFolder(parent: String, name: String) async {
        await folderMutation { await self.mailRepository.createFolder(parent: parent, name: name) }
    }

    func renameFolder(_ folder: String, to name: String) async {
        await folderMutation { await self.mailRepository.renameFolder(folder, to: name) }
    }

    /// Deletes a folder. The caller must only offer this for a folder the
    /// listing marked `deletable`; the relay is the authority either way and
    /// refuses the rest.
    func deleteFolder(_ folder: String) async {
        let wasSelected = self.folder == folder
        await folderMutation { await self.mailRepository.deleteFolder(folder) }
        // Leaving the selection on a folder that no longer exists shows an
        // empty list with no explanation and no way back.
        if wasSelected, errorMessage == nil {
            await selectFolder(StandardFolder.inbox)
        }
    }

    private func folderMutation(_ body: () async -> MailOutcome) async {
        let outcome = await body()
        if let message = outcome.userMessage {
            errorMessage = message
        } else {
            errorMessage = nil
            await loadSubfolders()
        }
    }

    // MARK: - List actions (undoable)

    /// Hides `serverIds` (rows of the folder on screen) at once and holds the
    /// action for the undo window. Nothing reaches the relay until the window
    /// closes: on its timer, when the user leaves the screen, when the app
    /// backgrounds or locks. A new action joins the same bar and restarts the
    /// window without sending what is already held.
    func hold(_ action: MailMoveAction, serverIds: [String], target: String? = nil) {
        var seen = Set<String>()
        let ids = serverIds.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        if action == .move {
            guard let target, !target.isEmpty,
                  target.caseInsensitiveCompare(folder) != .orderedSame
            else { return }
        }
        guard ids.count <= MailRepository.maxActionIds else {
            showNotice(String(localized: "Up to \(MailRepository.maxActionIds) messages at a time"))
            return
        }
        pending.hold(HeldMailAction(action: action, serverIds: ids, folder: folder, target: target))
        undoMessage = pending.summary
        undoTask?.cancel()
        undoTask = Task { [weak self, undoWindow] in
            try? await Task.sleep(for: undoWindow)
            guard !Task.isCancelled else { return }
            self?.commitHeldActions()
        }
    }

    func move(serverIds: [String], to targetFolder: String) {
        hold(.move, serverIds: serverIds, target: targetFolder)
    }

    func delete(serverIds: [String]) {
        hold(.delete, serverIds: serverIds)
    }

    func archive(serverIds: [String]) {
        hold(.archive, serverIds: serverIds)
    }

    func markJunk(serverIds: [String]) {
        hold(.spam, serverIds: serverIds)
    }

    /// Takes back every held action; nothing was sent, so nothing is undone
    /// server-side.
    func undoHeldActions() {
        undoTask?.cancel()
        undoTask = nil
        pending.undoAll()
        undoMessage = nil
    }

    /// Sends everything held, now. The returned task finishes when the relay
    /// has answered, for callers (backgrounding) that want to wait.
    ///
    /// The relay source is bound here, synchronously: the lock calls this
    /// just before it drops the gated device secret, and a source built after
    /// that point would carry no credential.
    @discardableResult
    func commitHeldActions() -> Task<Void, Never>? {
        undoTask?.cancel()
        undoTask = nil
        undoMessage = nil
        let due = pending.takeAll()
        guard !due.isEmpty else { return nil }
        for entry in due { inFlightKeys.formUnion(entry.keys) }
        let source = try? mailRepository.makeSource()
        let repository = mailRepository
        return Task { [weak self] in
            for entry in due {
                let result = await repository.applyAction(
                    entry.action,
                    messageIds: entry.serverIds,
                    from: entry.folder,
                    to: entry.target,
                    source: source
                )
                self?.finish(entry, with: result)
            }
        }
    }

    /// Drops every held action without sending it. For a security wipe, an
    /// unpair, or a graph rebuild: an action the user can no longer see the
    /// account for must not be sent on their behalf, and "never" is the safe
    /// direction — the mail stays where it was.
    func discardHeldActions() {
        undoHeldActions()
    }

    private func finish(_ entry: HeldMailAction, with result: MailActionResult) {
        inFlightKeys.subtract(entry.keys)
        let confirmed = Set(result.confirmedIds)
        if !confirmed.isEmpty {
            emails.removeAll { $0.folder == entry.folder && confirmed.contains($0.serverId) }
            rebuildTabs()
        }
        if let message = result.failureMessage {
            showNotice(message)
        }
    }

    // MARK: - Detail-screen actions (not undoable)

    /// Runs one moving action on a single message right away and reports a
    /// sentence on failure, nil on success. The row leaves the list only when
    /// the relay confirmed this id.
    func performNow(_ action: MailMoveAction, on email: Email, to target: String? = nil) async -> String? {
        let result = await mailRepository.applyAction(
            action, messageIds: [email.serverId], from: email.folder, to: target
        )
        guard result.confirmedIds.contains(email.serverId) else {
            return result.failureMessage
                ?? String(localized: "The server reported no change.")
        }
        emails.removeAll { $0.folder == email.folder && $0.serverId == email.serverId }
        rebuildTabs()
        return nil
    }

    /// Marks emails as read from the list (relay bulk action). Rows stay in
    /// place, so unlike the move-style actions there is no removal, and no
    /// re-sync on success — the optimistic flag flip already matches the
    /// server. (The relay has no "unread" action, so this is one-way.)
    func markRead(serverIds: [String]) async {
        guard !serverIds.isEmpty else { return }
        for index in emails.indices where serverIds.contains(emails[index].serverId) {
            emails[index].read = true
        }
        do {
            try await mailRepository.markRead(messageIds: serverIds, from: folder)
        } catch {
            errorMessage = "Could not mark as read: \(error.localizedDescription)"
            await refresh()
        }
    }

    // MARK: - Loading

    /// Instant display from the local cache, then a server refresh.
    func load() async {
        let requested = folder
        if let cached = try? await mailRepository.cachedFolder(requested), !cached.isEmpty,
           requested == folder {
            apply(emails: cached)
        }
        await refresh(delaysTransientError: true)
    }

    /// A tab switch reconstructs InboxView and reruns its `.task`; the shared
    /// view model already owns the loaded rows, so that must not become another
    /// cache read and network request.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    /// Applies device-local visibility and ordering changes without a network
    /// request when the user returns from Settings.
    func refreshKeywordTabs() {
        rebuildTabs()
    }

    func refresh(forceFullResync: Bool = false, delaysTransientError: Bool = false) async {
        let requested = folder
        guard !refreshingFolders.contains(requested) else { return }
        delayedRefreshErrorTask?.cancel()
        delayedRefreshErrorTask = nil
        initialRefreshRetryTask?.cancel()
        initialRefreshRetryTask = nil
        refreshingFolders.insert(requested)
        defer { refreshingFolders.remove(requested) }
        do {
            let rows = try await mailRepository.refreshFolder(
                requested,
                forceFullResync: forceFullResync
            )
            // A refresh that completes after a folder switch must not paint
            // one mailbox's mail under another's title and actions.
            guard requested == folder else { return }
            markRefreshed(rows)
        } catch MailSourceError.notPaired {
            guard requested == folder else { return }
            loadedFolder = nil
            connectionNotice = nil
            errorMessage = "Pair this device (Settings → Connection) to load mail."
        } catch {
            guard requested == folder else { return }
            // A failed fetch un-confirms the folder: its emptiness is unknown.
            loadedFolder = nil
            let message = "Unable to connect to the mail server."
            errorMessage = nil
            if delaysTransientError {
                connectionNotice = nil
                delayedRefreshErrorTask = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: self.initialRefreshErrorDelay)
                    guard !Task.isCancelled else { return }
                    self.connectionNotice = message
                    self.delayedRefreshErrorTask = nil
                }
                initialRefreshRetryTask = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: self.initialRefreshRetryDelay)
                    guard !Task.isCancelled else { return }
                    await self.retryInitialRefresh()
                }
            } else {
                connectionNotice = message
            }
        }
    }

    private func markRefreshed(_ rows: [Email]) {
        apply(emails: rows)
        refreshedAt[folder] = now()
        loadedFolder = folder
        errorMessage = nil
        connectionNotice = nil
    }

    /// One silent retry inside the initial grace window. A second transient
    /// failure leaves the original 90-second banner timer in place.
    private func retryInitialRefresh() async {
        initialRefreshRetryTask = nil
        let requested = folder
        guard !refreshingFolders.contains(requested) else { return }
        refreshingFolders.insert(requested)
        defer { refreshingFolders.remove(requested) }
        do {
            let rows = try await mailRepository.refreshFolder(requested)
            guard requested == folder else { return }
            delayedRefreshErrorTask?.cancel()
            delayedRefreshErrorTask = nil
            markRefreshed(rows)
        } catch MailSourceError.notPaired {
            guard requested == folder else { return }
            delayedRefreshErrorTask?.cancel()
            delayedRefreshErrorTask = nil
            connectionNotice = nil
            errorMessage = "Pair this device (Settings → Connection) to load mail."
        } catch {
            // The delayed task reports the persistent failure at 90 seconds.
        }
    }

    /// Best-effort 90s refresh while the inbox is in the foreground (spec §2).
    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Config.foregroundRefreshInterval))
                await self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Stops work owned by the visible Inbox tab. SwiftUI retains this view
    /// model while Settings is selected, so delayed tasks must not publish a
    /// stale toast behind that tab and reveal it when Inbox returns. Leaving
    /// the screen also confirms whatever is held for Undo.
    func leaveInbox() {
        stopAutoRefresh()
        commitHeldActions()
        delayedRefreshErrorTask?.cancel()
        delayedRefreshErrorTask = nil
        initialRefreshRetryTask?.cancel()
        initialRefreshRetryTask = nil
        connectionNotice = nil
    }

    func markRead(_ email: Email) async {
        try? await mailRepository.markRead(serverId: email.serverId, folder: email.folder)
        if let index = emails.firstIndex(where: { $0.serverId == email.serverId }) {
            emails[index].read = true
        }
    }

    /// Resolves a notification tap's messageId to a cached email.
    func email(withServerId serverId: String) -> Email? {
        emails.first { $0.serverId == serverId }
    }

    /// Prepares the list for a notification tap and returns its target.
    ///
    /// The target is an Inbox message, so this switches there first, then
    /// resyncs the whole window before handing the row back: the cached row
    /// is fine for the list, but opening it before the resync can render the
    /// detail screen from stale data — an out-of-date `bodyMode`, or PGP state
    /// that no longer matches what the server holds. A delta fetch is not
    /// enough: the row may predate the cursor entirely. A refresh already in
    /// flight is waited out rather than skipped, so the forced one runs.
    func prepareForPushTap(messageId: String) async -> Email? {
        if folder != StandardFolder.inbox {
            resetForFolder(StandardFolder.inbox, tab: nil)
        } else {
            selectedTab = nil
            reconcileSelectedTab()
        }
        var waited = 0
        while refreshingFolders.contains(folder), waited < 300 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        await refresh(forceFullResync: true)
        return email(withServerId: messageId)
    }

    // MARK: - New mail

    /// The view reports whether the list sits at its top. Reaching the top
    /// clears the "N new messages" pill.
    func listScrolled(atTop: Bool) {
        isListAtTop = atTop
        if atTop { newMailCount = 0 }
    }

    /// The pill was tapped: the view scrolls up.
    func acknowledgeNewMail() {
        newMailCount = 0
        scrollToTopRequest += 1
    }

    // MARK: - Notices

    private func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self, noticeDuration] in
            try? await Task.sleep(for: noticeDuration)
            guard !Task.isCancelled, self?.notice == message else { return }
            self?.notice = nil
        }
    }

    /// For the selection's 500-row cap, which is enforced in the view.
    func reportSelectionLimit() {
        showNotice(String(localized: "Up to \(MailRepository.maxActionIds) messages at a time"))
    }

    /// Attachment metadata for an email, fetched lazily when it's opened
    /// (the inbox listing carries none). Nil when it could not be fetched —
    /// which Forward must tell apart from "no attachments".
    func attachmentListing(for email: Email) async -> [EmailAttachment]? {
        try? await mailRepository.listAttachments(
            folder: email.folder, messageId: email.serverId
        )
    }

    /// Raw bytes of one attachment (for Save As…), or nil on failure.
    func attachmentData(_ attachment: EmailAttachment, of email: Email) async -> Data? {
        do {
            return try await mailRepository.downloadAttachment(
                folder: email.folder,
                messageId: email.serverId,
                index: attachment.index
            )
        } catch {
            errorMessage = "Could not download attachment: \(error.localizedDescription)"
            return nil
        }
    }

    /// Downloads one attachment to a temporary file and returns its URL
    /// (for Quick Look / opening externally), or nil on failure.
    func downloadAttachment(_ attachment: EmailAttachment, of email: Email) async -> URL? {
        guard let cacheKey = Self.sanitizedCacheComponent(email.serverId) else {
            errorMessage = "Could not download attachment: invalid message id"
            return nil
        }
        guard let data = await attachmentData(attachment, of: email) else { return nil }
        do {
            let directory = Self.attachmentTempRoot
                .appending(path: "\(cacheKey)/\(attachment.index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // tmp is not normally backed up anyway; excluding explicitly
            // costs nothing and removes any doubt (belt and suspenders).
            var root = Self.attachmentTempRoot
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
            let safeName = attachment.name
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\0", with: "")
            let file = directory.appending(path: safeName.isEmpty ? "attachment" : safeName)
            try data.write(to: file)
            return file
        } catch {
            errorMessage = "Could not download attachment: \(error.localizedDescription)"
            return nil
        }
    }

    /// Root of the Quick Look staging area for downloaded attachments.
    static var attachmentTempRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "attachments")
    }

    /// Deletes every staged attachment file. Run when Hostile Location
    /// Protection toggles (both directions), so no pre-toggle bytes survive
    /// the mode switch. Missing directory is fine.
    static func purgeAttachmentTempFiles() {
        try? deleteAttachmentTempFiles()
    }

    /// The same purge, reporting a failure instead of swallowing it.
    /// `SecurityWipe` needs the throw: a preview file left in the temporary
    /// directory is decrypted attachment plaintext, and a wipe that could not
    /// remove it must not report a clean erasure.
    static func deleteAttachmentTempFiles() throws {
        guard FileManager.default.fileExists(atPath: attachmentTempRoot.path) else { return }
        try FileManager.default.removeItem(at: attachmentTempRoot)
    }

    /// The relay-supplied `serverId` must never be trusted as a path
    /// component (mirrors the same guard in ContactPhotoCache.fileURL) — a
    /// crafted "../" value would otherwise redirect the cache write outside
    /// the intended attachments subtree.
    static func sanitizedCacheComponent(_ value: String) -> String? {
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains(".."),
              !value.contains("\0")
        else { return nil }
        return value
    }

    /// Paints `newEmails`. A repaint of the folder and tab already on screen
    /// announces rows that landed above the old top row: kept in sight when
    /// the list is at the top, counted on the pill otherwise. A first paint or
    /// a folder switch announces nothing.
    private func apply(emails newEmails: [Email]) {
        let previous = paintedFolder == folder ? filteredEmails : []
        let tabBefore = selectedTab
        emails = newEmails
        rebuildTabs()
        let sameView = paintedFolder == folder && selectedTab == tabBefore
        paintedFolder = folder
        guard sameView else { return }
        let added = InboxRules.newRowsAbove(old: previous, new: filteredEmails)
        guard added > 0 else { return }
        if isListAtTop {
            scrollToTopRequest += 1
        } else {
            newMailCount += added
        }
    }

    private func rebuildTabs() {
        showsAllTab = !appliesAllTabSetting || keywordRepository.isAllTabVisible
        tabs = keywordRepository.visibleTabs(from: emails)
        reconcileSelectedTab()
    }

    /// A tab that disappeared falls back to All, or — with All hidden — to the
    /// first visible tab. With nothing visible the filter is off entirely.
    private func reconcileSelectedTab() {
        if let selectedTab, !tabs.contains(where: { $0.name == selectedTab }) {
            self.selectedTab = nil
        }
        if selectedTab == nil, !showsAllTab {
            selectedTab = tabs.first?.name
        }
    }
}
