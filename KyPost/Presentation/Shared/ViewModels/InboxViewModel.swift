//
//  InboxViewModel.swift
//  KyPost
//
//  Inbox state: cached-first load, server refresh, keyword tab filtering,
//  the 90-second foreground refresh cadence (spec §2), list actions held for
//  Undo, older mail, server-side search of the folder on screen, and the
//  freshness / empty-folder / new-mail signals.
//

import CryptoKit
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
    private let pushTapRefreshWait: Duration
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
    /// Bumped by every folder selection, so an answer that arrives after a
    /// newer pick (a Sent/Drafts listing) is discarded instead of selected.
    private var selectionGeneration = 0
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

    /// "Load older mail", per folder: where the next page starts (the last
    /// page's `nextBefore`), folders with nothing older left (or a server
    /// that cannot page), and folders with a page in flight.
    private var olderFrontier: [String: String] = [:]
    private var olderExhausted: Set<String> = []
    private var loadingOlder: Set<String> = []

    /// Bumped by `forgetAccount`. A refresh or page captures it when it
    /// starts and neither paints nor updates any state if it comes back to a
    /// different one — its rows and answers belong to the account forgotten.
    /// Readable so the iOS shell can close what it shows for that account.
    private(set) var accountGeneration = 0

    /// The submitted search on screen, trimmed; nil when not searching. It
    /// lives only here — never logged, persisted, or restored with the scene.
    private(set) var searchQuery: String?
    /// Results for `searchQuery`, stamped with the searched folder and never
    /// written to the cache. Nil while the search is in flight and after a
    /// failure: the folder list shows then, never an older query's results.
    private(set) var searchResults: [Email]?
    private(set) var isSearchInFlight = false
    /// Which submission may land; any newer one, or the search ending,
    /// supersedes it.
    private var searchGeneration = 0
    /// Bumped whenever the selection must end: a search starting, its results
    /// landing, or the search ending. Selection state lives in the views.
    private(set) var selectionResetRequest = 0
    /// Bumped when the search ends for a reason other than the field — a
    /// folder switch, a notification tap, leaving the account — so the view
    /// clears and closes the field too.
    private(set) var searchDismissRequest = 0

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
        pushTapRefreshWait: Duration = .seconds(30),
        appliesAllTabSetting: Bool = InboxViewModel.platformHasTabStrip,
        now: @escaping () -> Date = Date.init
    ) {
        self.mailRepository = mailRepository
        self.keywordRepository = keywordRepository
        self.initialRefreshErrorDelay = initialRefreshErrorDelay
        self.initialRefreshRetryDelay = initialRefreshRetryDelay
        self.undoWindow = undoWindow
        self.noticeDuration = noticeDuration
        self.pushTapRefreshWait = pushTapRefreshWait
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
        return emails.filter { !hidden.contains($0.id) }
    }

    /// What the list shows: search results while they are on screen (keyword
    /// tabs do not filter them), otherwise the folder under its tab. Held and
    /// in-flight rows are hidden from both, by (folder, id).
    var filteredEmails: [Email] {
        if let searchResults {
            let hidden = pending.heldKeys.union(inFlightKeys)
            return searchResults.filter { !hidden.contains($0.id) }
        }
        guard let selectedTab else { return visibleEmails }
        return visibleEmails.filter { $0.keywords.contains(selectedTab) }
    }

    var isSearchActive: Bool { searchQuery != nil }

    /// No chips at all once All and every keyword are hidden: the list then
    /// shows everything, unfiltered. None while searching either: the tabs
    /// do not filter results.
    var showsTabStrip: Bool {
        !isSearchActive && (showsAllTab || !tabs.isEmpty)
    }

    /// The "Load older mail" footer: below a non-empty list, until the folder
    /// has nothing older or its server cannot page.
    var showsLoadOlder: Bool {
        !isSearchActive && !emails.isEmpty && !olderExhausted.contains(folder)
    }

    var isLoadingOlder: Bool { loadingOlder.contains(folder) }

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
        if searchResults != nil { return filteredEmails.isEmpty }
        return InboxRules.showsEmptyFolder(
            shown: filteredEmails.count, loadedFolder: loadedFolder, currentFolder: folder
        )
    }

    var emptyFolderMessage: String {
        if searchResults != nil {
            return String(localized: "No matching messages")
        }
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
        selectionGeneration += 1
        guard folder != name else {
            selectedTab = tab
            reconcileSelectedTab()
            return
        }
        resetForFolder(name, tab: tab)
        await load()
    }

    private func resetForFolder(_ name: String, tab: String?) {
        endSearch(dismissingField: true)
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
    /// A listing that answers after the account was forgotten is dropped.
    func loadSubfolders() async {
        let generation = accountGeneration
        if let folders = try? await mailRepository.listFolders(parent: StandardFolder.inbox),
           generation == accountGeneration {
            inboxSubfolders = folders
        }
        if let folders = try? await mailRepository.listFolders(parent: StandardFolder.archive),
           generation == accountGeneration {
            archiveSubfolders = folders
        }
        if let folders = try? await mailRepository.listFolders(parent: nil),
           generation == accountGeneration {
            topLevelFolders = folders
        }
    }

    /// Opens Sent or Drafts by resolving the account's real path from a fresh
    /// top-level listing. Never guesses a name and never creates a folder: no
    /// match is reported, and the folder on screen stays where it was. A
    /// listing that answers after the user picked something else is dropped
    /// silently: selecting it then would paint this folder under that one.
    @discardableResult
    func openSpecialFolder(_ kind: SpecialFolder) async -> Bool {
        selectionGeneration += 1
        let generation = selectionGeneration
        let account = accountGeneration
        let folders: [MailFolder]
        do {
            folders = try await mailRepository.listFolders(parent: nil)
        } catch {
            guard generation == selectionGeneration else { return false }
            showNotice(MailOutcome.from(error).userMessage
                ?? String(localized: "Unable to connect to the mail server."))
            return false
        }
        // A listing of a forgotten account is not this account's folders.
        guard account == accountGeneration else { return false }
        topLevelFolders = folders
        guard generation == selectionGeneration else { return false }
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
        let deleted = await folderMutation { await self.mailRepository.deleteFolder(folder) }
        // Leaving the selection on a folder that no longer exists shows an
        // empty list with no explanation and no way back.
        if wasSelected, deleted {
            await selectFolder(StandardFolder.inbox)
        }
    }

    /// A refusal is a toast: `errorMessage` renders only over an empty list,
    /// so beside a folder full of mail it was never seen.
    @discardableResult
    private func folderMutation(_ body: () async -> MailOutcome) async -> Bool {
        let outcome = await body()
        if let message = outcome.userMessage {
            showNotice(message)
            return false
        }
        await loadSubfolders()
        return true
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

    /// A drag onto a sidebar folder. Archive itself is never a move target:
    /// a drop there is the Archive action, which the relay resolves to the
    /// account's real archive. Every other folder is a plain move.
    func drop(serverIds: [String], onto targetFolder: String) {
        if targetFolder.caseInsensitiveCompare(StandardFolder.archive) == .orderedSame {
            archive(serverIds: serverIds)
        } else {
            move(serverIds: serverIds, to: targetFolder)
        }
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

    /// Everything this view model holds about the account, for a security
    /// wipe, an unpair, or a graph rebuild: held actions are dropped (see
    /// `discardHeldActions`) and the older-mail paging state is forgotten — its
    /// frontiers are message ids of an account this device no longer shows.
    ///
    /// The rows on screen and the folder lists go too, and every refresh or
    /// page still in flight is voided (`accountGeneration`): their answers
    /// are the forgotten account's mail.
    func forgetAccount() {
        discardHeldActions()
        accountGeneration += 1
        selectionGeneration += 1
        olderFrontier = [:]
        olderExhausted = []
        loadingOlder = []
        refreshingFolders = []
        refreshedAt = [:]
        delayedRefreshErrorTask?.cancel()
        delayedRefreshErrorTask = nil
        initialRefreshRetryTask?.cancel()
        initialRefreshRetryTask = nil
        inboxSubfolders = []
        archiveSubfolders = []
        topLevelFolders = []
        windowRows = [:]
        hasLoaded = false
        resetForFolder(Config.defaultFolder, tab: nil)
        endSearch(dismissingField: true)
    }

    private func finish(_ entry: HeldMailAction, with result: MailActionResult) {
        inFlightKeys.subtract(entry.keys)
        let confirmed = Set(result.confirmedIds)
        if !confirmed.isEmpty {
            emails.removeAll { $0.folder == entry.folder && confirmed.contains($0.serverId) }
            searchResults?.removeAll { $0.folder == entry.folder && confirmed.contains($0.serverId) }
            rebuildTabs()
        }
        if let message = result.failureMessage {
            showNotice(message)
        }
    }

    // MARK: - Older mail

    /// Loads one page of mail older than the list, from the server's last
    /// `nextBefore` or, for the first page, from the oldest row held. The
    /// footer hides once nothing older is left, and for good on a server that
    /// cannot page; a page that lands after a folder switch is not painted.
    func loadOlderMail() async {
        let requested = folder
        let generation = accountGeneration
        guard !loadingOlder.contains(requested) else { return }
        loadingOlder.insert(requested)
        // A forgotten account's page clears nothing: the set was emptied by
        // `forgetAccount`, and a new page for the same folder may be in it.
        defer { if generation == accountGeneration { loadingOlder.remove(requested) } }
        let outcome = await mailRepository.loadOlder(folder: requested, frontier: olderFrontier[requested])
        guard generation == accountGeneration else { return }
        var message: String?
        switch outcome {
        case .loaded(let next):
            if let next {
                olderFrontier[requested] = next
            } else {
                olderFrontier[requested] = nil
                olderExhausted.insert(requested)
            }
        case .nothingToPageFrom:
            olderExhausted.insert(requested)
        case .unsupported(let text):
            olderExhausted.insert(requested)
            message = text
        case .failed(let text, let staleAnchor):
            // A stale frontier answers 400 forever; start again from the
            // oldest row. Any other failure retries the same page.
            if staleAnchor { olderFrontier[requested] = nil }
            message = text
        }
        guard requested == folder else { return }
        if case .loaded = outcome,
           let rows = try? await mailRepository.cachedFolder(requested),
           generation == accountGeneration, requested == folder {
            apply(emails: rows)
        }
        if let message { showNotice(message) }
    }

    /// The body to show for a row that arrived without one (older mail),
    /// fetched from the relay; nil when the row's own body stands.
    func loadBody(for email: Email) async throws -> MailMessageBody? {
        try await mailRepository.loadBody(for: email)
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
        emails.removeAll { $0.id == email.id }
        // An opened search result leaves the results with it.
        searchResults?.removeAll { $0.id == email.id }
        rebuildTabs()
        return nil
    }

    /// Marks emails as read from the list (relay bulk action). Rows stay in
    /// place, so unlike the move-style actions there is no removal, and no
    /// re-sync on success — the optimistic flag flip already matches the
    /// server. (The relay has no "unread" action, so this is one-way.)
    func markRead(serverIds: [String]) async {
        guard !serverIds.isEmpty else { return }
        let requested = folder
        for index in emails.indices
        where emails[index].folder == requested && serverIds.contains(emails[index].serverId) {
            emails[index].read = true
        }
        if var results = searchResults {
            for index in results.indices
            where results[index].folder == requested && serverIds.contains(results[index].serverId) {
                results[index].read = true
            }
            searchResults = results
        }
        do {
            try await mailRepository.markRead(messageIds: serverIds, from: requested)
        } catch {
            // A toast, not `errorMessage`: that one replaces an empty list,
            // and this list is not empty — the failure would never show.
            showNotice(Self.readerFailure("Couldn't mark as read", error).message)
            await refresh()
        }
    }

    // MARK: - Loading

    /// Instant display from the local cache, then a server refresh.
    func load() async {
        let requested = folder
        let generation = accountGeneration
        if let cached = try? await mailRepository.cachedFolder(requested), !cached.isEmpty,
           generation == accountGeneration, requested == folder {
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

    /// Returns whether a request was issued: false when one for this folder
    /// was already in flight and this call was skipped.
    @discardableResult
    func refresh(forceFullResync: Bool = false, delaysTransientError: Bool = false) async -> Bool {
        let requested = folder
        guard !refreshingFolders.contains(requested) else { return false }
        delayedRefreshErrorTask?.cancel()
        delayedRefreshErrorTask = nil
        initialRefreshRetryTask?.cancel()
        initialRefreshRetryTask = nil
        let generation = accountGeneration
        refreshingFolders.insert(requested)
        defer { if generation == accountGeneration { refreshingFolders.remove(requested) } }
        do {
            let rows = try await mailRepository.refreshFolder(
                requested,
                forceFullResync: forceFullResync
            )
            // A refresh that completes after a folder switch must not paint
            // one mailbox's mail under another's title and actions, nor one
            // that completes after the account was forgotten paint it at all.
            // The latter did not run for the account now shown.
            guard generation == accountGeneration else { return false }
            guard requested == folder else { return true }
            markRefreshed(rows)
        } catch MailSourceError.notPaired {
            guard generation == accountGeneration else { return false }
            guard requested == folder else { return true }
            loadedFolder = nil
            connectionNotice = nil
            errorMessage = "Pair this device (Settings → Connection) to load mail."
        } catch {
            guard generation == accountGeneration else { return false }
            guard requested == folder else { return true }
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
        return true
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
        let generation = accountGeneration
        guard !refreshingFolders.contains(requested) else { return }
        refreshingFolders.insert(requested)
        defer { if generation == accountGeneration { refreshingFolders.remove(requested) } }
        do {
            let rows = try await mailRepository.refreshFolder(requested)
            guard generation == accountGeneration, requested == folder else { return }
            delayedRefreshErrorTask?.cancel()
            delayedRefreshErrorTask = nil
            markRefreshed(rows)
        } catch MailSourceError.notPaired {
            guard generation == accountGeneration, requested == folder else { return }
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
    /// the screen also confirms whatever is held for Undo — unless the list
    /// only went away because the window changed shape (an iOS stack/split
    /// switch, `InboxListPresence.Departure.relaid`): then held actions stay
    /// on their own timer, which still commits them.
    func leaveInbox(commitsHeldActions: Bool = true) {
        stopAutoRefresh()
        if commitsHeldActions { commitHeldActions() }
        delayedRefreshErrorTask?.cancel()
        delayedRefreshErrorTask = nil
        initialRefreshRetryTask?.cancel()
        initialRefreshRetryTask = nil
        connectionNotice = nil
    }

    /// Marks the opened message read. The reader shows the failure: the
    /// list's own error line only appears over an empty list.
    func markRead(_ email: Email) async throws(ReaderFailure) {
        do {
            try await mailRepository.markRead(serverId: email.serverId, folder: email.folder)
        } catch {
            throw Self.readerFailure("Couldn't mark this message as read", error)
        }
        if let index = emails.firstIndex(where: { $0.id == email.id }) {
            emails[index].read = true
        }
        if let index = searchResults?.firstIndex(where: { $0.id == email.id }) {
            searchResults?[index].read = true
        }
    }

    /// The row on screen for `key` — a folder row or a search result — or nil.
    /// When both exist the folder row wins (it carries the body and OpenPGP
    /// state), but a result's own To/Cc replace the row's: Reply All uses
    /// the result's recipients.
    func email(for key: MailRowKey) -> Email? {
        let result = searchResults?.first { $0.id == key }
        guard var row = emails.first(where: { $0.id == key }) else { return result }
        if let result, !result.sentTo.isEmpty || !result.cc.isEmpty {
            row.sentTo = result.sentTo
            row.cc = result.cc
        }
        return row
    }

    /// Rows handed to a reader window, by (folder, id). The main list empties
    /// on every folder switch and search; a window must not go blank because
    /// of it. Dropped by `forgetAccount`.
    private var windowRows: [MailRowKey: Email] = [:]

    /// Remembers `email` for a reader window about to open on it, so the
    /// window resolves it even after the list moved on (`resolveEmail`).
    func rememberForWindow(_ email: Email) {
        windowRows[email.id] = self.email(for: email.id) ?? email
    }

    /// The row a reader window shows, independent of what the main list is
    /// showing now: the list's row when it is still there, else the row the
    /// window was opened with, else the cached row — which is how a restored
    /// window finds its message after a relaunch. Nil only when none of the
    /// three has it (an uncached search result after a relaunch, or mail of
    /// a forgotten account).
    func resolveEmail(for key: MailRowKey) async -> Email? {
        if let row = email(for: key) ?? windowRows[key] { return row }
        let account = accountGeneration
        guard let cached = try? await mailRepository.cachedEmail(key),
              account == accountGeneration
        else { return nil }
        return cached
    }

    /// Prepares the list for a notification tap and returns its target.
    ///
    /// The target is an Inbox message, so this switches there first, then
    /// resyncs the whole window before handing the row back: the cached row
    /// is fine for the list, but opening it before the resync can render the
    /// detail screen from stale data — an out-of-date `bodyMode`, or PGP state
    /// that no longer matches what the server holds. A delta fetch is not
    /// enough: the row may predate the cursor entirely. A refresh already in
    /// flight is waited out rather than skipped, so the forced one runs; if
    /// it outlasts `pushTapRefreshWait`, or the forced resync cannot run, the
    /// tap reports failure and returns nil rather than the cached row.
    func prepareForPushTap(messageId: String) async -> Email? {
        selectionGeneration += 1
        endSearch(dismissingField: true)
        if folder != StandardFolder.inbox {
            resetForFolder(StandardFolder.inbox, tab: nil)
        } else {
            selectedTab = nil
            reconcileSelectedTab()
        }
        let deadline = ContinuousClock.now + pushTapRefreshWait
        while refreshingFolders.contains(folder), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard await refresh(forceFullResync: true) else {
            showNotice(String(localized: "Unable to connect to the mail server."))
            return nil
        }
        // A push names an Inbox message by id alone; the same id in another
        // folder is a different message.
        return email(for: MailRowKey(folder: StandardFolder.inbox, serverId: messageId))
    }

    // MARK: - Search

    /// Searches the folder on screen on the server, every field. Submit-only;
    /// blank text is ignored. Starting a search and its results landing both
    /// end the selection. Results land only if this submission is still the
    /// newest and its query and folder are still the ones on screen; a
    /// failure says why and leaves the folder list.
    func submitSearch(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let requested = folder
        let account = accountGeneration
        searchGeneration += 1
        let generation = searchGeneration
        searchQuery = query
        searchResults = nil
        isSearchInFlight = true
        selectionResetRequest += 1
        // Results never raise the new-mail pill, and one left over from the
        // folder would sit over them.
        newMailCount = 0
        let outcome: Result<[Email], any Error>
        do {
            outcome = .success(try await mailRepository.search(query, in: requested))
        } catch {
            outcome = .failure(error)
        }
        // A search that answers after the account was forgotten lists the
        // forgotten account's mail: it never lands.
        guard account == accountGeneration, generation == searchGeneration,
              searchQuery == query, folder == requested else { return }
        isSearchInFlight = false
        selectionResetRequest += 1
        switch outcome {
        case .success(let rows):
            searchResults = rows
        case .failure(let error):
            searchResults = nil
            showNotice(MailOutcome.from(error).userMessage
                ?? String(localized: "Unable to connect to the mail server."))
        }
    }

    /// The field's text changed. Results must match the text on screen, so
    /// editing it away from the submitted query ends the search — and so does
    /// clearing it.
    func searchTextChanged(_ text: String) {
        guard let searchQuery,
              text.trimmingCharacters(in: .whitespacesAndNewlines) != searchQuery
        else { return }
        endSearch()
    }

    /// The field was cleared or cancelled: the folder list comes back.
    func endSearch() {
        endSearch(dismissingField: false)
    }

    private func endSearch(dismissingField: Bool) {
        if dismissingField { searchDismissRequest += 1 }
        guard searchQuery != nil else { return }
        searchGeneration += 1
        searchQuery = nil
        searchResults = nil
        isSearchInFlight = false
        selectionResetRequest += 1
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

    /// Raw bytes of one attachment (Save As…, Forward, the invite card). The
    /// failure is the reader's to show — it used to land in `errorMessage`,
    /// which only renders over an empty list, so nobody saw it.
    func attachmentData(_ attachment: EmailAttachment, of email: Email) async throws(ReaderFailure) -> Data {
        do {
            return try await mailRepository.downloadAttachment(
                folder: email.folder,
                messageId: email.serverId,
                index: attachment.index
            )
        } catch {
            throw Self.readerFailure("Couldn't download \(attachment.name)", error)
        }
    }

    /// Downloads one attachment to a temporary file and returns its URL
    /// (for Quick Look / opening externally).
    func downloadAttachment(_ attachment: EmailAttachment, of email: Email) async throws(ReaderFailure) -> URL {
        guard let cacheKey = Self.attachmentCacheComponent(for: email) else {
            throw ReaderFailure(message: String(localized: "Couldn't download \(attachment.name): the message id is not valid."))
        }
        let data = try await attachmentData(attachment, of: email)
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
            throw ReaderFailure(message: String(
                localized: "Couldn't open \(attachment.name): it could not be saved for preview on this device."
            ))
        }
    }

    /// The sentence a reader shows for a failed mail call: what failed, then
    /// the relay's own reason. Never a raw transport description.
    static func readerFailure(_ what: String, _ error: any Error) -> ReaderFailure {
        let reason = MailOutcome.from(error).userMessage
            ?? String(localized: "Unable to connect to the mail server.")
        return ReaderFailure(message: "\(what). \(reason)")
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

    /// One staging directory per (folder, id): the same id in two folders is
    /// two messages, and one must not overwrite the other's attachments. The
    /// folder is hashed, so its name never becomes a path component.
    static func attachmentCacheComponent(for email: Email) -> String? {
        guard let id = sanitizedCacheComponent(email.serverId) else { return nil }
        let folder = SHA256.hash(data: Data(email.folder.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(folder)-\(id)"
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
    /// a folder switch announces nothing, and neither does any repaint while a
    /// search is on screen, in flight or landed.
    private func apply(emails newEmails: [Email]) {
        let previous = paintedFolder == folder ? filteredEmails : []
        let tabBefore = selectedTab
        emails = newEmails
        rebuildTabs()
        let sameView = paintedFolder == folder && selectedTab == tabBefore
        paintedFolder = folder
        guard sameView, !isSearchActive else { return }
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

/// Why a reader action (an attachment, mark-read, Save As) failed, as the
/// sentence the reader shows.
nonisolated struct ReaderFailure: Error, Equatable, Sendable {
    let message: String
}
