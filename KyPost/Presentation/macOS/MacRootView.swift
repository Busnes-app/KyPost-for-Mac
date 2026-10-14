//
//  MacRootView.swift
//  KyPost
//
//  macOS main window (spec Phase 7): NavigationSplitView with a themed
//  sidebar (inbox + keyword filters + contacts), list content column, and
//  detail pane. Settings live in the Preferences window (Cmd+,), not a tab.
//

#if os(macOS)
import SwiftUI

/// Which folder sheet is showing. Identifiable so `sheet(item:)` presents it,
/// and one value for both actions so they cannot both be up at once.
enum FolderPrompt: Identifiable, Hashable {
    case create(parent: String)
    case rename(folder: String)

    var id: String {
        switch self {
        case .create(let parent): "create:\(parent)"
        case .rename(let folder): "rename:\(folder)"
        }
    }

    var title: String {
        switch self {
        case .create(let parent):
            parent.isEmpty
                ? "New folder"
                : "New folder in \(StandardFolder.displayName(parent))"
        case .rename(let folder):
            "Rename \(StandardFolder.displayName(folder))"
        }
    }
}

enum MacSection: Hashable {
    case inbox(keyword: String?)
    /// A server mailbox other than Inbox (Junk, Trash, Archive/…).
    case folder(name: String)
    /// Sent or Drafts, opened by resolving the account's real path on each
    /// selection — never by a hardcoded name.
    case special(SpecialFolder)
    case contacts
}

struct MacRootView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(NavigationRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    private var inboxViewModel: InboxViewModel { SingletonGraph.shared.inboxViewModel }
    private var contactsViewModel: ContactsViewModel { SingletonGraph.shared.contactsViewModel }

    @State private var section: MacSection? = .inbox(keyword: nil)
    @State private var selectedEmails: Set<Email> = []
    @State private var selectedContact: Contact?
    /// The mail search field. Plain view state: never stored or restored.
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var showScanKey = false
    /// Which folder sheet is up, if any. One piece of state for both actions
    /// so they cannot be presented at once.
    @State private var folderPrompt: FolderPrompt?
    @State private var folderName = ""
    /// The folder a Delete confirmation is asking about. Deleting a mail
    /// folder takes its messages with it, so it gets a confirmation rather
    /// than firing straight off a context-menu click.
    @State private var folderPendingDelete: String?
    /// When off, the email preview pane is hidden and reading happens in
    /// pop-out windows (double-click). Contacts always keep their detail pane.
    @AppStorage("macShowPreviewPane") private var showPreviewPane = true

    var body: some View {
        @Bindable var router = router
        let theme = themeManager.palette

        Group {
            if showPreviewPane || section == .contacts {
                NavigationSplitView {
                    sidebar(theme: theme)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
                } content: {
                    contentColumn(theme: theme)
                        .navigationSplitViewColumnWidth(min: 280, ideal: 340)
                } detail: {
                    detailPane(theme: theme)
                }
            } else {
                NavigationSplitView {
                    sidebar(theme: theme)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
                } detail: {
                    contentColumn(theme: theme)
                }
            }
        }
        .tint(theme.accent)
        .environment(\.theme, theme)
        .sheet(item: $router.pairingParams) { params in
            PushPairingView(initialParams: params).environment(\.theme, theme)
        }
        .sheet(item: $router.mfaRoute) { route in
            MfaApprovalView(challenge: route.challenge).environment(\.theme, theme)
        }
        .sheet(item: $folderPrompt) { _ in
            folderPromptSheet.environment(\.theme, theme)
        }
        .confirmationDialog(
            folderPendingDelete.map { "Delete \(StandardFolder.displayName($0))?" } ?? "",
            isPresented: Binding(
                get: { folderPendingDelete != nil },
                set: { if !$0 { folderPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                guard let folder = folderPendingDelete else { return }
                folderPendingDelete = nil
                Task { await inboxViewModel.deleteFolder(folder) }
            }
            Button("Cancel", role: .cancel) { folderPendingDelete = nil }
        } message: {
            Text("This deletes the folder and the messages in it on the server. It can't be undone from here.")
        }
        .lockAwareRouting(router)
        .task {
            await inboxViewModel.load()
            inboxViewModel.startAutoRefresh()
            await inboxViewModel.loadSubfolders()
            await contactsViewModel.load()
        }
        // A pairing just landed: load now rather than leaving "not paired"
        // up until the next 90-second refresh.
        .onReceive(NotificationCenter.default.publisher(for: .kyPostPaired)) { _ in
            Task {
                await inboxViewModel.load()
                await inboxViewModel.loadSubfolders()
                await contactsViewModel.sync()
            }
        }
        .onChange(of: router.pendingMessageId) {
            openPendingMessageIfNeeded()
        }
        // A `mailto:` link, once the router let it through the lock. Opened
        // as its own compose window, which owns it from here on.
        .onChange(of: router.composeRequest, initial: true) {
            if let draft = router.takeComposeRequest() {
                openWindow(id: "compose", value: draft)
            }
        }
        .onChange(of: section) { previous, current in
            switch current {
            case .inbox(let keyword):
                selectedEmails = []
                Task { await inboxViewModel.selectFolder(StandardFolder.inbox, tab: keyword) }
            case .folder(let name):
                selectedEmails = []
                Task { await inboxViewModel.selectFolder(name) }
            case .special(let kind):
                selectedEmails = []
                Task {
                    // No such folder (or no answer): the toast says so, and
                    // the sidebar goes back to what is actually on screen.
                    if !(await inboxViewModel.openSpecialFolder(kind)), section == current {
                        section = previous
                    }
                }
            case .contacts, nil:
                break
            }
        }
        // A selection never outlives the folder it was made in, however the
        // folder changed (sidebar, a deleted folder, a notification tap).
        .onChange(of: inboxViewModel.folder) {
            selectedEmails = []
        }
        // Nor a search starting, landing, or ending.
        .onChange(of: inboxViewModel.selectionResetRequest) {
            selectedEmails = []
        }
        .onChange(of: inboxViewModel.filteredEmails) {
            // Re-point the selection at the refreshed values (Email is
            // Hashable by value, so a read-flag change would otherwise
            // silently deselect) and drop emails that left the list.
            let byId = Dictionary(
                inboxViewModel.filteredEmails.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            selectedEmails = Set(selectedEmails.compactMap { byId[$0.id] })
        }
    }

    // MARK: - Sidebar


    private func sidebar(theme: ThemePalette) -> some View {
        List(selection: $section) {
            Section("Mail") {
                Label("Inbox", systemImage: "tray")
                    .moveDropTarget(viewModel: inboxViewModel) { StandardFolder.inbox }
                    .tag(MacSection.inbox(keyword: nil))
                    .contextMenu {
                        // Inbox itself is never deletable or renamable, so it
                        // only offers the one action. There is deliberately no
                        // "new top-level folder": this sidebar renders the
                        // children of INBOX and Archive only, so a folder
                        // created beside them would be invisible here.
                        Button("New Subfolder…") {
                            folderPrompt = .create(parent: StandardFolder.inbox)
                        }
                    }
                // Everything between Inbox and Archive is indented one level.
                ForEach(inboxViewModel.inboxSubfolders, id: \.name) { sub in
                    folderRow(
                        path: sub.name, icon: "folder", indented: true,
                        deletable: sub.deletable
                    )
                }
                // Keyword rows do not filter search results, so they step
                // aside while a search is on screen.
                ForEach(inboxViewModel.isSearchActive ? [] : inboxViewModel.tabs, id: \.name) { tab in
                    Label(tab.name, systemImage: "tag")
                        .badge(tab.count)
                        .padding(.leading, 12)
                        .tag(MacSection.inbox(keyword: tab.name))
                }
                // Between the keywords and Archive, in display order. Sent and
                // Drafts resolve to the account's real folders when picked.
                specialFolderRow(.drafts)
                folderRow(path: StandardFolder.junk, icon: "xmark.bin", indented: true)
                specialFolderRow(.sent)
                folderRow(path: StandardFolder.trash, icon: "trash", indented: true)
                folderRow(path: StandardFolder.archive, icon: "archivebox", indented: false)
                ForEach(inboxViewModel.archiveSubfolders, id: \.name) { sub in
                    folderRow(
                        path: sub.name, icon: "folder", indented: true,
                        deletable: sub.deletable
                    )
                }
            }
            Section("People") {
                Label("Contacts", systemImage: "person.2")
                    .tag(MacSection.contacts)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
    }

    /// Sent or Drafts. Selecting it resolves the path from a fresh folder
    /// listing; a drop goes to the path the last listing resolved, and is
    /// refused when there is none.
    private func specialFolderRow(_ kind: SpecialFolder) -> some View {
        Label(kind.label, systemImage: kind.systemImage)
            .padding(.leading, 12)
            .moveDropTarget(viewModel: inboxViewModel) { inboxViewModel.specialFolderPath(kind) }
            .tag(MacSection.special(kind))
    }

    /// A selectable sidebar folder that also accepts dropped emails.
    private func folderRow(
        path: String,
        icon: String,
        indented: Bool,
        deletable: Bool = false
    ) -> some View {
        Label(StandardFolder.displayName(path), systemImage: icon)
            .padding(.leading, indented ? 12 : 0)
            .moveDropTarget(viewModel: inboxViewModel) { path }
            .tag(MacSection.folder(name: path))
            .contextMenu {
                Button("New Subfolder…") { folderPrompt = .create(parent: path) }
                // Only offered where the server said it is allowed; the
                // built-in mailboxes come back not deletable, and guessing
                // from the name breaks on a renamed or localised one.
                if deletable {
                    Button("Rename…") { folderPrompt = .rename(folder: path) }
                    Button("Delete…", role: .destructive) {
                        folderPendingDelete = path
                    }
                }
            }
    }

    /// The folder name sheet, for both create and rename.
    private var folderPromptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(folderPrompt?.title ?? "")
                .font(AppFont.ui(15, weight: .semibold))
            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitFolderPrompt() }
            HStack {
                Spacer()
                Button("Cancel") { folderPrompt = nil; folderName = "" }
                Button("Save") { submitFolderPrompt() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func submitFolderPrompt() {
        let name = folderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let prompt = folderPrompt else { return }
        folderPrompt = nil
        folderName = ""
        Task {
            switch prompt {
            case .create(let parent):
                await inboxViewModel.createFolder(parent: parent, name: name)
            case .rename(let folder):
                await inboxViewModel.renameFolder(folder, to: name)
            }
        }
    }

    // MARK: - Content column

    @ViewBuilder
    private func contentColumn(theme: ThemePalette) -> some View {
        switch section ?? .inbox(keyword: nil) {
        case .inbox, .folder, .special:
            emailList(theme: theme)
        case .contacts:
            contactList(theme: theme)
        }
    }

    private func emailList(theme: ThemePalette) -> some View {
        VStack(spacing: 0) {
            FreshnessLine(lastRefreshed: inboxViewModel.lastRefreshed)
            if inboxViewModel.isSearchInFlight {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 4)
            }
            if inboxViewModel.filteredEmails.isEmpty {
                Group {
                    // "No messages" only once this folder refreshed: a loading
                    // or unreachable folder with an empty cache is unknown.
                    if let message = inboxViewModel.errorMessage {
                        EmptyStateView(message: message, systemImage: "exclamationmark.triangle")
                    } else if inboxViewModel.showsEmptyFolderState {
                        EmptyStateView(
                            message: inboxViewModel.emptyFolderMessage,
                            systemImage: inboxViewModel.isSearchActive ? "magnifyingglass" : "tray"
                        )
                    } else if inboxViewModel.isRefreshing {
                        ProgressView()
                            .padding(.top, 40)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    List(selection: cappedSelection) {
                        ForEach(inboxViewModel.filteredEmails) { email in
                            EmailListRow(email: email)
                                .draggable(dragPayload(for: email))
                                .tag(email)
                                .listRowBackground(theme.bg)
                                .listRowSeparatorTint(theme.line)
                        }
                        if inboxViewModel.showsLoadOlder {
                            LoadOlderFooter(isLoading: inboxViewModel.isLoadingOlder) {
                                Task { await inboxViewModel.loadOlderMail() }
                            }
                        }
                    }
                    // Single click selects (fills the preview pane when shown);
                    // double click / primaryAction pops the email out.
                    .contextMenu(forSelectionType: Email.self) { selection in
                        Button {
                            openInNewWindows(selection)
                        } label: {
                            Label("Open in New Window", systemImage: "macwindow.badge.plus")
                        }
                        Divider()
                        Button {
                            Task { await inboxViewModel.markRead(serverIds: selection.map(\.serverId)) }
                        } label: {
                            Label("Mark as Read", systemImage: "envelope.open")
                        }
                        .disabled(selection.allSatisfy(\.read))
                        Button {
                            runMailAction(on: selection) { inboxViewModel.archive(serverIds: $0) }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        Menu {
                            ForEach(inboxViewModel.moveDestinations, id: \.self) { destination in
                                Button(InboxRules.moveTargetLabel(destination)) {
                                    runMailAction(on: selection) {
                                        inboxViewModel.move(serverIds: $0, to: destination)
                                    }
                                }
                            }
                        } label: {
                            Label("Move To", systemImage: "folder")
                        }
                        Button {
                            runMailAction(on: selection) { inboxViewModel.markJunk(serverIds: $0) }
                        } label: {
                            Label("Move to Junk", systemImage: "xmark.bin")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deleteEmails(selection)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } primaryAction: { selection in
                        openInNewWindows(selection)
                    }
                    .onDeleteCommand {
                        deleteEmails(selectedEmails)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .reportsScrollTop(to: inboxViewModel)
                    .newMailPill(inboxViewModel)
                    .onChange(of: inboxViewModel.scrollToTopRequest) {
                        guard let first = inboxViewModel.filteredEmails.first else { return }
                        withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }
        }
        .background(theme.bg)
        .inboxSearch(
            viewModel: inboxViewModel,
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .toolbar
        )
        .undoBar(inboxViewModel)
        .relabelsAtMidnight()
        // Switching to Contacts or closing the window leaves the list, which
        // confirms whatever is held for Undo.
        .onDisappear { inboxViewModel.commitHeldActions() }
        .navigationTitle(currentInboxTitle)
        .toolbar {
            // Selection-based mail actions, so archive/read/delete never
            // require opening the email (the context menu's counterparts).
            ToolbarItem {
                Button {
                    runMailAction(on: selectedEmails) { inboxViewModel.archive(serverIds: $0) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .help("Archive the selected emails")
                .disabled(selectedEmails.isEmpty)
            }
            ToolbarItem {
                Button {
                    Task { await inboxViewModel.markRead(serverIds: selectedEmails.map(\.serverId)) }
                } label: {
                    Label("Mark as Read", systemImage: "envelope.open")
                }
                .help("Mark the selected emails as read")
                // allSatisfy is true for an empty selection, so this also
                // covers the nothing-selected case.
                .disabled(selectedEmails.allSatisfy(\.read))
            }
            ToolbarItem {
                Button {
                    deleteEmails(selectedEmails)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete the selected emails")
                .disabled(selectedEmails.isEmpty)
            }
            ToolbarItem {
                Toggle(isOn: $showPreviewPane) {
                    Label("Preview Pane", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the preview pane")
            }
            ToolbarItem {
                Button {
                    openWindow(id: "compose")
                } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                }
            }
            ToolbarItem {
                Button {
                    Task { await inboxViewModel.refresh() }
                } label: {
                    if inboxViewModel.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .toast(message: inboxViewModel.notice ?? inboxViewModel.connectionNotice)
    }

    private func contactList(theme: ThemePalette) -> some View {
        Group {
            if contactsViewModel.contacts.isEmpty {
                EmptyStateView(
                    message: "No contacts yet — sync or add one.",
                    systemImage: "person.crop.circle.badge.plus"
                )
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                List(contactsViewModel.contacts, selection: $selectedContact) { contact in
                    HStack(spacing: 10) {
                        AvatarView(name: contact.name)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contact.name)
                                .font(AppFont.ui(14, weight: .medium))
                                .foregroundStyle(theme.inkStrong)
                            Text(contact.primaryEmail)
                                .font(AppFont.mono(11))
                                .foregroundStyle(theme.ink.opacity(0.8))
                        }
                    }
                    .tag(contact)
                    .listRowBackground(theme.bg)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ContactSyncBanner(viewModel: contactsViewModel)
        }
        .background(theme.bg)
        .navigationTitle("Contacts")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await contactsViewModel.sync() }
                } label: {
                    if contactsViewModel.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            ToolbarItem {
                Button {
                    Task { await contactsViewModel.dedupe() }
                } label: {
                    Label("Find Duplicates", systemImage: "person.crop.circle.badge.checkmark")
                }
                .disabled(contactsViewModel.isSyncing)
            }
            ToolbarItem {
                Button {
                    showScanKey = true
                } label: {
                    Label("Scan Contact Key", systemImage: "qrcode.viewfinder")
                }
            }
            ToolbarItem {
                VCardShareMenu(contacts: contactsViewModel.contacts) {
                    Label("Export All as vCard", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showScanKey) {
            ScanPgpKeyView()
                .environment(\.theme, theme)
        }
        .onChange(of: showScanKey) { _, isPresented in
            // A scanned key lands on a contact via the repository, so the list
            // in memory is stale until it reloads.
            if !isPresented { Task { await contactsViewModel.load() } }
        }
        .toast(message: contactsViewModel.statusMessage)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private func detailPane(theme: ThemePalette) -> some View {
        switch section ?? .inbox(keyword: nil) {
        case .inbox, .folder, .special:
            if let email = singleSelectedEmail {
                EmailDetailView(email: email, inboxViewModel: inboxViewModel)
                    .id(email.id) // re-run markRead when the selection changes
                    .toolbar {
                        ToolbarItem {
                            Button {
                                openWindow(id: "email", value: email.id)
                            } label: {
                                Label("Open in New Window", systemImage: "macwindow.badge.plus")
                            }
                        }
                    }
            } else {
                EmptyStateView(
                    message: selectedEmails.count > 1
                        ? "\(selectedEmails.count) emails selected"
                        : "Select an email",
                    systemImage: "envelope.open"
                )
                .frame(maxWidth: 340)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.bg)
            }
        case .contacts:
            if let selectedContact {
                ContactDetailView(contact: selectedContact, viewModel: contactsViewModel)
                    .id(selectedContact.localId)
            } else {
                EmptyStateView(message: "Select a contact", systemImage: "person.crop.circle")
                    .frame(maxWidth: 340)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.bg)
            }
        }
    }

    // MARK: - Helpers

    /// The email shown in the preview pane — only when exactly one is selected.
    private var singleSelectedEmail: Email? {
        selectedEmails.count == 1 ? selectedEmails.first : nil
    }

    /// Dragging a row that's part of the selection carries the whole
    /// selection. ponytail: ids are newline-joined into one plain-text
    /// payload; a custom Transferable UTType is the cleaner v2.
    private func dragPayload(for email: Email) -> String {
        let ids = selectedEmails.contains(email)
            ? selectedEmails.map(\.serverId)
            : [email.serverId]
        return ids.joined(separator: "\n")
    }

    private func deleteEmails(_ emails: Set<Email>) {
        runMailAction(on: emails) { inboxViewModel.delete(serverIds: $0) }
    }

    /// Deselects the affected rows, then holds a bulk mail action for Undo.
    /// Ids go in on-screen order, so the relay sees what the user saw.
    private func runMailAction(
        on emails: Set<Email>,
        _ operation: ([String]) -> Void
    ) {
        guard !emails.isEmpty else { return }
        selectedEmails.subtract(emails)
        let keys = Set(emails.map(\.id))
        operation(inboxViewModel.filteredEmails.filter { keys.contains($0.id) }.map(\.serverId))
    }

    /// The selection, refusing to grow past the relay's per-request cap.
    private var cappedSelection: Binding<Set<Email>> {
        Binding(
            get: { selectedEmails },
            set: { newValue in
                if newValue.count > MailRepository.maxActionIds, newValue.count > selectedEmails.count {
                    inboxViewModel.reportSelectionLimit()
                } else {
                    selectedEmails = newValue
                }
            }
        )
    }

    private var currentInboxTitle: String {
        switch section ?? .inbox(keyword: nil) {
        case .inbox(let keyword?):
            keyword
        case .folder(let name):
            StandardFolder.displayName(name)
        case .special(let kind):
            kind.label
        default:
            "Inbox"
        }
    }

    private func openInNewWindows(_ emails: Set<Email>) {
        for email in emails {
            openWindow(id: "email", value: email.id)
        }
    }

    /// Opens the email a notification tap pointed at. The target is consumed
    /// here, once, whether or not it is found: a later folder switch or
    /// window must not hunt for it again.
    private func openPendingMessageIfNeeded() {
        guard let messageId = router.pendingMessageId else { return }
        router.pendingMessageId = nil
        Task {
            // Switches to Inbox and resyncs before opening: the cached row may
            // carry a stale bodyMode or stale PGP state, and the detail screen
            // renders from it.
            guard let email = await inboxViewModel.prepareForPushTap(messageId: messageId) else {
                return
            }
            section = .inbox(keyword: nil)
            selectedEmails = [email]
        }
    }
}

/// Accepts dragged email server ids (newline-joined, see `dragPayload`) and
/// moves them to the folder `folder` resolves to at drop time (Archive runs
/// the Archive action instead, see `InboxViewModel.drop`), highlighting
/// the row while a drag hovers over it. A nil folder refuses the drop.
private struct MoveDropTarget: ViewModifier {
    let viewModel: InboxViewModel
    let folder: () -> String?

    @Environment(\.theme) private var theme
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isTargeted ? theme.accent.opacity(0.25) : Color.clear)
            )
            .dropDestination(for: String.self) { payloads, _ in
                let serverIds = payloads.flatMap {
                    $0.split(separator: "\n").map(String.init)
                }
                guard !serverIds.isEmpty, let target = folder() else { return false }
                viewModel.drop(serverIds: serverIds, onto: target)
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
    }
}

private extension View {
    func moveDropTarget(viewModel: InboxViewModel, folder: @escaping () -> String?) -> some View {
        modifier(MoveDropTarget(viewModel: viewModel, folder: folder))
    }
}

/// Content of a popped-out email window (KyPostApp "email" WindowGroup).
/// Keyed by (folder, id): the id alone names a message only within a folder.
struct EmailWindowView: View {
    @Environment(\.theme) private var theme

    let key: MailRowKey?

    private var inboxViewModel: InboxViewModel { SingletonGraph.shared.inboxViewModel }

    var body: some View {
        if let key, let email = inboxViewModel.email(for: key) {
            EmailDetailView(email: email, inboxViewModel: inboxViewModel)
        } else {
            EmptyStateView(
                message: "This email is no longer available.",
                systemImage: "envelope"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
        }
    }
}
#endif
