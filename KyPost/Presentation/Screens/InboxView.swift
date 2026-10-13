//
//  InboxView.swift
//  KyPost
//
//  Email list with keyword tabs (spec §2), pull-to-refresh, 90s auto-refresh
//  while visible, notification-tap deep-open support, edit-mode multi-select
//  with bulk actions, the 5-second Undo for list actions, and server-side
//  search of the folder on screen.
//
//  The list column of both iOS layouts (`ShellLayout`): pushed messages in
//  the stack, the content column of `InboxSplitView` in the split. What it
//  shows lives in `MailShellState`, above the switch, so a rotation or a
//  fold keeps the open message, the selection and the search.
//

import SwiftUI

struct InboxView: View {
    @Environment(\.theme) private var theme
    @Environment(NavigationRouter.self) private var router

    @Bindable var viewModel: InboxViewModel
    /// The open message, selection and search field, held by the shell.
    @Bindable var state: MailShellState

    private var isSelecting: Bool {
#if os(iOS)
        state.isSelecting
#else
        false
#endif
    }

    private var selection: Set<MailRowKey> { state.selection }

#if os(iOS)
    /// Select mode as the list's edit mode, kept in the shell state.
    private var editMode: Binding<EditMode> {
        Binding(
            get: { state.isSelecting ? .active : .inactive },
            set: { mode in
                if mode.isEditing { state.beginSelection() } else { state.endSelection() }
            }
        )
    }
#endif

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
            text: $state.searchText,
            isPresented: $state.isSearchPresented,
            placement: .automatic
        )
        .undoBar(viewModel)
        .relabelsAtMidnight()
        .toast(message: viewModel.notice ?? viewModel.connectionNotice)
        .navigationTitle(navigationTitle)
        .toolbarTitleMenu {
            folderPicker
        }
        .modifier(StackedReader(viewModel: viewModel, state: state))
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
                        state.beginSelection()
                    }
                }
                .disabled(!isSelecting && viewModel.filteredEmails.isEmpty)
            }
#endif
            ToolbarItem {
                Button {
                    state.compose = .blank(id: UUID())
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
        .environment(\.editMode, editMode)
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
            }
        }
#endif
        .task {
            await viewModel.loadIfNeeded()
            viewModel.refreshKeywordTabs()
            viewModel.startAutoRefresh()
            openPendingMessageIfNeeded()
            await viewModel.loadSubfolders()
        }
        // Leaving the list, ending the selection on a folder switch or a
        // search, and dropping rows that left the list are the shell's
        // (`MainTabView`), so a layout switch is not mistaken for any of them.
        .onChange(of: router.pendingMessageId) {
            openPendingMessageIfNeeded()
        }
    }

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
                    state.open(email)
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
        // The split's detail pane names the row it shows.
        .listRowBackground(
            state.layout == .split && state.openKey == email.id
                ? theme.accent.opacity(0.18)
                : theme.bg
        )
        .listRowSeparatorTint(theme.line)
    }

    /// The selection, refusing to grow past the relay's per-request cap.
    private var cappedSelection: Binding<Set<MailRowKey>> {
        Binding(
            get: { state.selection },
            set: { newValue in
                if newValue.count > MailRepository.maxActionIds, newValue.count > state.selection.count {
                    viewModel.reportSelectionLimit()
                } else {
                    state.selection = newValue
                }
            }
        )
    }

    private func endSelection() {
        state.endSelection()
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
        Picker("Folder", selection: Self.folderSelection(viewModel)) {
            Self.folderRows(viewModel)
        }
    }

    /// Every folder choice, tagged for `folderSelection`: the picker's
    /// content and the split's sidebar rows.
    @ViewBuilder
    static func folderRows(_ viewModel: InboxViewModel) -> some View {
        Label("Inbox", systemImage: "tray").tag(StandardFolder.inbox)
        ForEach(viewModel.inboxSubfolders, id: \.name) { sub in
            Label(StandardFolder.displayName(sub.name), systemImage: "folder")
                .tag(sub.name)
        }
        Label(SpecialFolder.drafts.label, systemImage: SpecialFolder.drafts.systemImage)
            .tag(specialTag(.drafts))
        Label("Junk", systemImage: "xmark.bin").tag(StandardFolder.junk)
        Label(SpecialFolder.sent.label, systemImage: SpecialFolder.sent.systemImage)
            .tag(specialTag(.sent))
        Label("Trash", systemImage: "trash").tag(StandardFolder.trash)
        Label("Archive", systemImage: "archivebox").tag(StandardFolder.archive)
        ForEach(viewModel.archiveSubfolders, id: \.name) { sub in
            Label(StandardFolder.displayName(sub.name), systemImage: "folder")
                .tag(sub.name)
        }
    }

    /// Picker tag for Sent/Drafts. Not a mailbox path — the control character
    /// keeps it from ever colliding with one.
    nonisolated static func specialTag(_ kind: SpecialFolder) -> String {
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

    /// Folder choice for the menus and the split's sidebar; switching
    /// reloads the list.
    static func folderSelection(_ viewModel: InboxViewModel) -> Binding<String> {
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
                state.openEmail = email
            }
        }
    }
}

/// The stack's reader: the open message pushed over the list, by the
/// stack's path (`MainTabView.mailPath`). Not `navigationDestination(item:)`:
/// a stack rebuilt with the item already set (a switch back from the split)
/// writes nil through it and the message closes. In the split the detail
/// column shows it instead (`InboxSplitView`), so nothing pushes.
private struct StackedReader: ViewModifier {
    let viewModel: InboxViewModel
    let state: MailShellState

    func body(content: Content) -> some View {
        if state.layout == .stack {
            content.navigationDestination(for: Email.self) { email in
                EmailDetailView(email: email, inboxViewModel: viewModel) {
                    state.closeMessage()
                }
            }
        } else {
            content
        }
    }
}
