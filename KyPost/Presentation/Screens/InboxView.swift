//
//  InboxView.swift
//  KyPost
//
//  Email list with keyword tabs (spec §2), pull-to-refresh, 90s auto-refresh
//  while visible, notification-tap deep-open support, edit-mode multi-select
//  with bulk actions, the 5-second Undo for list actions, and server-side
//  search of the folder on screen.
//

import SwiftUI

struct InboxView: View {
    @Environment(\.theme) private var theme
    @Environment(NavigationRouter.self) private var router

    @Bindable var viewModel: InboxViewModel
    @State private var showCompose = false
    /// A `mailto:` compose taken from the router (iOS).
    @State private var mailtoDraft: ComposeDraft?
    @State private var presentedEmail: Email?
    /// Selected rows by (folder, id); only meaningful while editing.
    @State private var selection: Set<MailRowKey> = []
    /// The search field. Plain view state: never stored or restored.
    @State private var searchText = ""
    @State private var isSearchPresented = false
#if os(iOS)
    @State private var editMode: EditMode = .inactive
#endif

    private var isSelecting: Bool {
#if os(iOS)
        editMode.isEditing
#else
        false
#endif
    }

    var body: some View {
        VStack(spacing: 0) {
            // With All and every keyword hidden there is no strip at all, and
            // the list shows everything.
            if viewModel.showsTabStrip {
                KeywordTabView(
                    tabs: viewModel.tabs,
                    showsAll: viewModel.showsAllTab,
                    selected: $viewModel.selectedTab
                )
            }

            FreshnessLine(lastRefreshed: viewModel.lastRefreshed)

            if viewModel.isSearchInFlight {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 4)
            }

            if let message = viewModel.errorMessage {
                Text(message)
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }

            if viewModel.filteredEmails.isEmpty {
                ScrollView {
                    // "No messages" only once this folder refreshed: a loading
                    // or unreachable folder with an empty cache is unknown.
                    if viewModel.showsEmptyFolderState {
                        EmptyStateView(
                            message: viewModel.emptyFolderMessage,
                            systemImage: viewModel.isSearchActive ? "magnifyingglass" : "tray"
                        )
                    } else if viewModel.isRefreshing {
                        ProgressView()
                            .padding(.top, 40)
                    }
                }
                .refreshable { await viewModel.refresh() }
            } else {
                ScrollViewReader { proxy in
                    List(selection: cappedSelection) {
                        ForEach(viewModel.filteredEmails) { email in
                            row(for: email)
                        }
                        if viewModel.showsLoadOlder, !isSelecting {
                            LoadOlderFooter(isLoading: viewModel.isLoadingOlder) {
                                Task { await viewModel.loadOlderMail() }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await viewModel.refresh() }
                    .reportsScrollTop(to: viewModel)
                    .newMailPill(viewModel)
                    .onChange(of: viewModel.scrollToTopRequest) {
                        guard let first = viewModel.filteredEmails.first else { return }
                        withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }
        }
        .background(theme.bg)
        .inboxSearch(
            viewModel: viewModel,
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .automatic
        )
        .undoBar(viewModel)
        .relabelsAtMidnight()
        .toast(message: viewModel.notice ?? viewModel.connectionNotice)
        .navigationTitle(navigationTitle)
        .toolbarTitleMenu {
            folderPicker
        }
        .navigationDestination(item: $presentedEmail) { email in
            EmailDetailView(email: email, inboxViewModel: viewModel)
        }
        .toolbar {
            // Explicit folder button — the title menu's chevron is easy to miss.
            ToolbarItem(placement: .navigation) {
                Menu {
                    folderPicker
                } label: {
                    Label("Folder", systemImage: "folder")
                }
            }
#if os(iOS)
            ToolbarItem {
                Button(isSelecting ? "Done" : "Select") {
                    if isSelecting {
                        endSelection()
                    } else {
                        editMode = .active
                    }
                }
                .disabled(!isSelecting && viewModel.filteredEmails.isEmpty)
            }
#endif
            ToolbarItem {
                Button {
                    showCompose = true
                } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                }
            }
            ToolbarItem {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    if viewModel.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
#if os(iOS)
        .environment(\.editMode, $editMode)
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
            }
        }
        .sheet(isPresented: $showCompose, onDismiss: takeComposeRequestIfIdle) {
            ComposeView().environment(\.theme, theme)
        }
        .sheet(item: $mailtoDraft, onDismiss: takeComposeRequestIfIdle) { draft in
            ComposeView(draft: draft).environment(\.theme, theme)
        }
        .onChange(of: router.composeRequest, initial: true) {
            takeComposeRequestIfIdle()
        }
#else
        .sheet(isPresented: $showCompose) {
            ComposeView().environment(\.theme, theme)
        }
#endif
        .task {
            await viewModel.loadIfNeeded()
            viewModel.refreshKeywordTabs()
            viewModel.startAutoRefresh()
            openPendingMessageIfNeeded()
            await viewModel.loadSubfolders()
        }
        .onDisappear {
            endSelection()
            viewModel.leaveInbox()
        }
        // A selection never outlives the folder it was made in, nor a search
        // starting, landing, or ending.
        .onChange(of: viewModel.folder) { endSelection() }
        .onChange(of: viewModel.selectionResetRequest) { endSelection() }
        .onChange(of: viewModel.filteredEmails) {
            // Rows that left the list (held for Undo, moved by a refresh)
            // leave the selection with them.
            let visible = Set(viewModel.filteredEmails.map(\.id))
            selection.formIntersection(visible)
        }
        .onChange(of: router.pendingMessageId) {
            openPendingMessageIfNeeded()
        }
    }

#if os(iOS)
    /// Opens a `mailto:` compose only when no compose is on screen; a link
    /// that arrives meanwhile waits in the router and opens when the current
    /// compose closes (`takeComposeRequest(composeIsOpen:)`).
    private func takeComposeRequestIfIdle() {
        if let draft = router.takeComposeRequest(composeIsOpen: mailtoDraft != nil || showCompose) {
            mailtoDraft = draft
        }
    }
#endif

    private var navigationTitle: String {
        isSelecting && !selection.isEmpty
            ? String(localized: "\(selection.count) selected")
            : viewModel.folderDisplayName
    }

    @ViewBuilder
    private func row(for email: Email) -> some View {
        Group {
            if isSelecting {
                // A plain row while editing, so the list's own tap handling
                // toggles the selection instead of opening the message.
                EmailListRow(email: email)
            } else {
                Button {
                    presentedEmail = email
                } label: {
                    EmailListRow(email: email)
                }
                .buttonStyle(.plain)
            }
        }
        // Matches Android's gestures: swipe left archives, swipe right
        // deletes (InboxActivity setupSwipeGestures). Off while selecting.
        .swipeActions(edge: .trailing) {
            if !isSelecting {
                Button {
                    viewModel.archive(serverIds: [email.serverId])
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(theme.accent)
            }
        }
        .swipeActions(edge: .leading) {
            if !isSelecting {
                Button(role: .destructive) {
                    viewModel.delete(serverIds: [email.serverId])
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if !isSelecting {
                emailActions(for: [email.serverId])
            }
        }
        .listRowBackground(theme.bg)
        .listRowSeparatorTint(theme.line)
    }

    /// The selection, refusing to grow past the relay's per-request cap.
    private var cappedSelection: Binding<Set<MailRowKey>> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue.count > MailRepository.maxActionIds, newValue.count > selection.count {
                    viewModel.reportSelectionLimit()
                } else {
                    selection = newValue
                }
            }
        )
    }

    private func endSelection() {
        selection = []
#if os(iOS)
        editMode = .inactive
#endif
    }

    /// Bulk actions for the rows selected in edit mode. Each one is held for
    /// Undo exactly like a swipe, then the selection ends.
    private var selectionBar: some View {
        HStack {
            Button {
                runOnSelection { viewModel.archive(serverIds: $0) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            Spacer()
            Menu {
                ForEach(viewModel.moveDestinations, id: \.self) { destination in
                    Button(InboxRules.moveTargetLabel(destination)) {
                        runOnSelection { viewModel.move(serverIds: $0, to: destination) }
                    }
                }
            } label: {
                Label("Move", systemImage: "folder")
            }
            Spacer()
            Button {
                runOnSelection { viewModel.markJunk(serverIds: $0) }
            } label: {
                Label("Junk", systemImage: "xmark.bin")
            }
            Spacer()
            Button(role: .destructive) {
                runOnSelection { viewModel.delete(serverIds: $0) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .labelStyle(.iconOnly)
        .font(AppFont.ui(17))
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .disabled(selection.isEmpty)
        .background(theme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    private func runOnSelection(_ action: ([String]) -> Void) {
        // Rows in on-screen order, so the relay sees what the user saw.
        let ids = viewModel.filteredEmails.filter { selection.contains($0.id) }.map(\.serverId)
        guard !ids.isEmpty else { return }
        action(ids)
        endSelection()
    }

    /// Server folder choices, shared by the title menu and the toolbar
    /// button; same set and order as the macOS sidebar. Sent and Drafts are
    /// resolved from the account's real folders on each pick.
    private var folderPicker: some View {
        Picker("Folder", selection: folderSelection) {
            Label("Inbox", systemImage: "tray").tag(StandardFolder.inbox)
            ForEach(viewModel.inboxSubfolders, id: \.name) { sub in
                Label(StandardFolder.displayName(sub.name), systemImage: "folder")
                    .tag(sub.name)
            }
            Label(SpecialFolder.drafts.label, systemImage: SpecialFolder.drafts.systemImage)
                .tag(Self.specialTag(.drafts))
            Label("Junk", systemImage: "xmark.bin").tag(StandardFolder.junk)
            Label(SpecialFolder.sent.label, systemImage: SpecialFolder.sent.systemImage)
                .tag(Self.specialTag(.sent))
            Label("Trash", systemImage: "trash").tag(StandardFolder.trash)
            Label("Archive", systemImage: "archivebox").tag(StandardFolder.archive)
            ForEach(viewModel.archiveSubfolders, id: \.name) { sub in
                Label(StandardFolder.displayName(sub.name), systemImage: "folder")
                    .tag(sub.name)
            }
        }
    }

    /// Picker tag for Sent/Drafts. Not a mailbox path — the control character
    /// keeps it from ever colliding with one.
    private nonisolated static func specialTag(_ kind: SpecialFolder) -> String {
        "\u{1}special:\(kind.rawValue)"
    }

    /// Long-press actions on a row — the touch counterpart of the macOS
    /// context menu and sidebar drag-and-drop.
    @ViewBuilder
    private func emailActions(for serverIds: [String]) -> some View {
        Button {
            viewModel.archive(serverIds: serverIds)
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        Menu {
            ForEach(viewModel.moveDestinations, id: \.self) { destination in
                Button(InboxRules.moveTargetLabel(destination)) {
                    viewModel.move(serverIds: serverIds, to: destination)
                }
            }
        } label: {
            Label("Move To", systemImage: "folder")
        }
        Button {
            viewModel.markJunk(serverIds: serverIds)
        } label: {
            Label("Move to Junk", systemImage: "xmark.bin")
        }
        Divider()
        Button(role: .destructive) {
            viewModel.delete(serverIds: serverIds)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Folder choice for the menus; switching reloads the list.
    private var folderSelection: Binding<String> {
        Binding(
            get: {
                viewModel.currentSpecialFolder.map(Self.specialTag) ?? viewModel.folder
            },
            set: { name in
                if let kind = SpecialFolder.allCases.first(where: { Self.specialTag($0) == name }) {
                    Task { await viewModel.openSpecialFolder(kind) }
                } else {
                    Task { await viewModel.selectFolder(name) }
                }
            }
        )
    }

    /// Opens the email a notification tap pointed at (spec §3). The target is
    /// consumed here, once: a later appearance of this screen must not hunt
    /// for it again and reopen a message the user already left.
    private func openPendingMessageIfNeeded() {
        guard let messageId = router.pendingMessageId else { return }
        router.pendingMessageId = nil
        endSelection()
        Task {
            if let email = await viewModel.prepareForPushTap(messageId: messageId) {
                presentedEmail = email
            }
        }
    }
}
