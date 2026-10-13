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
    /// A server mailbox other than Inbox (Drafts, Junk, Sent, Trash, Archive/…).
    case folder(name: String)
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
        .sheet(item: $router.desktopPairingParams) { params in
            DesktopPairingView(initialParams: params).environment(\.theme, theme)
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
        .onChange(of: router.pendingMessageId) {
            openPendingMessageIfNeeded()
        }
        .onChange(of: section) {
            switch section {
            case .inbox(let keyword):
                selectedEmails = []
                Task { await inboxViewModel.selectFolder(StandardFolder.inbox, tab: keyword) }
            case .folder(let name):
                selectedEmails = []
                Task { await inboxViewModel.selectFolder(name) }
            case .contacts, nil:
                break
            }
        }
        .onChange(of: inboxViewModel.filteredEmails) {
            // Re-point the selection at the refreshed values (Email is
            // Hashable by value, so a read-flag change would otherwise
            // silently deselect) and drop emails that left the list.
            let byId = Dictionary(
                inboxViewModel.filteredEmails.map { ($0.serverId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            selectedEmails = Set(selectedEmails.compactMap { byId[$0.serverId] })
        }
    }

    // MARK: - Sidebar

    /// Mailboxes shown between the keywords and Archive, in display order.
    private static let interiorFolders = [
        StandardFolder.drafts,
        StandardFolder.junk,
        StandardFolder.sent,
        StandardFolder.trash,
    ]

    private static func folderIcon(_ name: String) -> String {
        switch name {
        case StandardFolder.drafts: "doc.text"
        case StandardFolder.junk: "xmark.bin"
        case StandardFolder.sent: "paperplane"
        case StandardFolder.trash: "trash"
        default: "folder"
        }
    }

    private func sidebar(theme: ThemePalette) -> some View {
        List(selection: $section) {
            Section("Mail") {
                Label("Inbox", systemImage: "tray")
                    .moveDropTarget(StandardFolder.inbox, viewModel: inboxViewModel)
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
                ForEach(inboxViewModel.tabs, id: \.name) { tab in
                    Label(tab.name, systemImage: "tag")
                        .badge(tab.count)
                        .padding(.leading, 12)
                        .tag(MacSection.inbox(keyword: tab.name))
                }
                ForEach(Self.interiorFolders, id: \.self) { name in
                    folderRow(path: name, icon: Self.folderIcon(name), indented: true)
                }
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

    /// A selectable sidebar folder that also accepts dropped emails.
    private func folderRow(
        path: String,
        icon: String,
        indented: Bool,
        deletable: Bool = false
    ) -> some View {
        Label(StandardFolder.displayName(path), systemImage: icon)
            .padding(.leading, indented ? 12 : 0)
            .moveDropTarget(path, viewModel: inboxViewModel)
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
        case .inbox, .folder:
            emailList(theme: theme)
        case .contacts:
            contactList(theme: theme)
        }
    }

    private func emailList(theme: ThemePalette) -> some View {
        Group {
            if inboxViewModel.filteredEmails.isEmpty {
                EmptyStateView(
                    message: inboxViewModel.errorMessage
                        ?? "No emails yet — refresh with ⌘R.",
                    systemImage: "tray"
                )
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                List(inboxViewModel.filteredEmails, selection: $selectedEmails) { email in
                    EmailListRow(email: email)
                        .draggable(dragPayload(for: email))
                        .tag(email)
                        .listRowBackground(theme.bg)
                        .listRowSeparatorTint(theme.line)
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
                        runMailAction(on: selection) { await inboxViewModel.archive(serverIds: $0) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Menu {
                        ForEach(inboxViewModel.moveDestinations, id: \.self) { destination in
                            Button(StandardFolder.displayName(destination)) {
                                runMailAction(on: selection) {
                                    await inboxViewModel.move(serverIds: $0, to: destination)
                                }
                            }
                        }
                    } label: {
                        Label("Move To", systemImage: "folder")
                    }
                    Button {
                        runMailAction(on: selection) { await inboxViewModel.markJunk(serverIds: $0) }
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
            }
        }
        .background(theme.bg)
        .navigationTitle(currentInboxTitle)
        .toolbar {
            // Selection-based mail actions, so archive/read/delete never
            // require opening the email (the context menu's counterparts).
            ToolbarItem {
                Button {
                    runMailAction(on: selectedEmails) { await inboxViewModel.archive(serverIds: $0) }
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
        .toast(message: inboxViewModel.connectionNotice)
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
        case .inbox, .folder:
            if let email = singleSelectedEmail {
                EmailDetailView(email: email, inboxViewModel: inboxViewModel)
                    .id(email.serverId) // re-run markRead when the selection changes
                    .toolbar {
                        ToolbarItem {
                            Button {
                                openWindow(id: "email", value: email.serverId)
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
        runMailAction(on: emails) { await inboxViewModel.delete(serverIds: $0) }
    }

    /// Deselects the affected rows, then runs a bulk mail operation.
    private func runMailAction(
        on emails: Set<Email>,
        _ operation: @escaping ([String]) async -> Void
    ) {
        guard !emails.isEmpty else { return }
        selectedEmails.subtract(emails)
        Task { await operation(emails.map(\.serverId)) }
    }

    private var currentInboxTitle: String {
        switch section ?? .inbox(keyword: nil) {
        case .inbox(let keyword?):
            keyword
        case .folder(let name):
            StandardFolder.displayName(name)
        default:
            "Inbox"
        }
    }

    private func openInNewWindows(_ emails: Set<Email>) {
        for email in emails {
            openWindow(id: "email", value: email.serverId)
        }
    }

    private func openPendingMessageIfNeeded() {
        guard let messageId = router.pendingMessageId else { return }
        Task {
            // Resync before opening: the cached row may carry a stale bodyMode
            // or stale PGP state, and the detail screen renders from it.
            await inboxViewModel.refreshForPushTap()
            guard let email = inboxViewModel.email(withServerId: messageId) else { return }
            section = .inbox(keyword: nil)
            selectedEmails = [email]
            router.pendingMessageId = nil
        }
    }
}

/// Accepts dragged email server ids (newline-joined, see `dragPayload`) and
/// moves them to `folder`, highlighting the row while a drag hovers over it.
private struct MoveDropTarget: ViewModifier {
    let folder: String
    let viewModel: InboxViewModel

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
                guard !serverIds.isEmpty else { return false }
                Task { await viewModel.move(serverIds: serverIds, to: folder) }
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
    }
}

private extension View {
    func moveDropTarget(_ folder: String, viewModel: InboxViewModel) -> some View {
        modifier(MoveDropTarget(folder: folder, viewModel: viewModel))
    }
}

/// Content of a popped-out email window (KyPostApp "email" WindowGroup).
struct EmailWindowView: View {
    @Environment(\.theme) private var theme

    let serverId: String

    private var inboxViewModel: InboxViewModel { SingletonGraph.shared.inboxViewModel }

    var body: some View {
        if let email = inboxViewModel.email(withServerId: serverId) {
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
