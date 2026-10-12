//
//  InboxView.swift
//  KyPost
//
//  Email list with keyword tabs (spec §2), pull-to-refresh, 90s auto-refresh
//  while visible, and notification-tap deep-open support.
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

    var body: some View {
        VStack(spacing: 0) {
            KeywordTabView(tabs: viewModel.tabs, selected: $viewModel.selectedTab)

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
                    EmptyStateView(
                        message: viewModel.selectedTab == nil
                            ? "No emails yet — pull to refresh."
                            : "Nothing tagged \(viewModel.selectedTab ?? "")",
                        systemImage: "tray"
                    )
                }
                .refreshable { await viewModel.refresh() }
            } else {
                List(viewModel.filteredEmails) { email in
                    Button {
                        presentedEmail = email
                    } label: {
                        EmailListRow(email: email)
                    }
                    .buttonStyle(.plain)
                    // Matches Android's gestures: swipe left archives, swipe
                    // right deletes (InboxActivity setupSwipeGestures).
                    .swipeActions(edge: .trailing) {
                        Button {
                            Task { await viewModel.archive(serverIds: [email.serverId]) }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(theme.accent)
                    }
                    .swipeActions(edge: .leading) {
                        Button(role: .destructive) {
                            Task { await viewModel.delete(serverIds: [email.serverId]) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        emailActions(for: email)
                    }
                    .listRowBackground(theme.bg)
                    .listRowSeparatorTint(theme.line)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await viewModel.refresh() }
            }
        }
        .background(theme.bg)
        .toast(message: viewModel.connectionNotice)
        .navigationTitle(viewModel.folderDisplayName)
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
        .sheet(isPresented: $showCompose) {
            ComposeView().environment(\.theme, theme)
        }
#if os(iOS)
        .sheet(item: $mailtoDraft) { draft in
            ComposeView(draft: draft).environment(\.theme, theme)
        }
        .onChange(of: router.composeRequest, initial: true) {
            if let draft = router.takeComposeRequest() { mailtoDraft = draft }
        }
#endif
        .task {
            await viewModel.loadIfNeeded()
            viewModel.refreshKeywordTabs()
            viewModel.startAutoRefresh()
            openPendingMessageIfNeeded()
            await viewModel.loadSubfolders()
        }
        .onDisappear { viewModel.leaveInbox() }
        .onChange(of: router.pendingMessageId) {
            openPendingMessageIfNeeded()
        }
    }

    /// Server folder choices, shared by the title menu and the toolbar
    /// button; same set and order as the macOS sidebar.
    private var folderPicker: some View {
        Picker("Folder", selection: folderSelection) {
            Label("Inbox", systemImage: "tray").tag(StandardFolder.inbox)
            ForEach(viewModel.inboxSubfolders, id: \.name) { sub in
                Label(StandardFolder.displayName(sub.name), systemImage: "folder")
                    .tag(sub.name)
            }
            Label("Drafts", systemImage: "doc.text").tag(StandardFolder.drafts)
            Label("Junk", systemImage: "xmark.bin").tag(StandardFolder.junk)
            Label("Sent", systemImage: "paperplane").tag(StandardFolder.sent)
            Label("Trash", systemImage: "trash").tag(StandardFolder.trash)
            Label("Archive", systemImage: "archivebox").tag(StandardFolder.archive)
            ForEach(viewModel.archiveSubfolders, id: \.name) { sub in
                Label(StandardFolder.displayName(sub.name), systemImage: "folder")
                    .tag(sub.name)
            }
        }
    }

    /// Long-press actions on a row — the touch counterpart of the macOS
    /// context menu and sidebar drag-and-drop.
    @ViewBuilder
    private func emailActions(for email: Email) -> some View {
        Button {
            Task { await viewModel.archive(serverIds: [email.serverId]) }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        Menu {
            ForEach(viewModel.moveDestinations, id: \.self) { destination in
                Button(StandardFolder.displayName(destination)) {
                    Task { await viewModel.move(serverIds: [email.serverId], to: destination) }
                }
            }
        } label: {
            Label("Move To", systemImage: "folder")
        }
        Button {
            Task { await viewModel.markJunk(serverIds: [email.serverId]) }
        } label: {
            Label("Move to Junk", systemImage: "xmark.bin")
        }
        Divider()
        Button(role: .destructive) {
            Task { await viewModel.delete(serverIds: [email.serverId]) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Folder choice for the menus; switching reloads the list.
    private var folderSelection: Binding<String> {
        Binding(
            get: { viewModel.folder },
            set: { name in Task { await viewModel.selectFolder(name) } }
        )
    }

    /// Opens the email a notification tap pointed at (spec §3).
    private func openPendingMessageIfNeeded() {
        guard let messageId = router.pendingMessageId else { return }
        if let email = viewModel.email(withServerId: messageId) {
            presentedEmail = email
            router.pendingMessageId = nil
        }
    }
}
