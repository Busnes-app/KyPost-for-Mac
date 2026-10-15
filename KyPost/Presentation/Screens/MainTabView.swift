//
//  MainTabView.swift
//  KyPost
//
//  Root navigation (spec §10): Inbox / Contacts / Settings tabs, with the
//  pairing and MFA flows presented as sheets driven by NavigationRouter.
//
//  A wide window (`ShellLayout.resolve`) shows Inbox and Contacts as splits;
//  a narrow one keeps the stacks. What either shows lives in
//  `MailShellState`, owned here above the switch, together with the one
//  compose sheet, so a rotation, a multitasking resize or a fold changes the
//  layout and nothing else.
//

import SwiftUI
import os

struct MainTabView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(NavigationRouter.self) private var router
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    /// Scene memory, replaced with the rest of the tree by `.id(generation)`.
    @State private var shell = MailShellState()
    /// False for a moment after a switch to the stack. A stack built with a
    /// message already on its path pops it (SwiftUI's navigation state
    /// writes the path back empty), so the open message is pushed once the
    /// new stack exists, and nothing it writes before then counts.
    @State private var mailStackReady = true
    @State private var contactStackReady = true

    private var inboxViewModel: InboxViewModel { SingletonGraph.shared.inboxViewModel }
    private var contactsViewModel: ContactsViewModel { SingletonGraph.shared.contactsViewModel }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
            let resolved = layout(forWindowWidth: width)
            tabs
                .onChange(of: resolved, initial: true) { old, new in
                    shell.layout = new
                    guard new == .stack, old != new else { return }
                    mailStackReady = false
                    contactStackReady = false
                    // Re-armed from here, not from the new stacks' own
                    // lifecycle: a stack that is rebuilt again, or never
                    // appears (another tab), must not stay deaf for good.
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard shell.layout == .stack else { return }
                        mailStackReady = true
                        contactStackReady = true
                    }
                }
#if DEBUG && os(iOS)
                // What the threshold was decided from, for checking it on a
                // new device. Geometry only: no mail, no account.
                .onChange(of: width, initial: true) {
                    Log.app.notice("shell layout: width \(width, privacy: .public) pt, size class \(String(describing: horizontalSizeClass), privacy: .public) -> \(String(describing: resolved), privacy: .public)")
                }
#endif
        }
    }

    private func layout(forWindowWidth width: CGFloat) -> ShellLayout {
#if os(iOS)
        ShellLayout.resolve(isRegularWidth: horizontalSizeClass == .regular, windowWidth: width)
#else
        .stack
#endif
    }

    private var tabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.selectedTab) {
            Tab("Inbox", systemImage: "tray.fill", value: AppTab.inbox) {
                inboxTab
            }
            Tab("Contacts", systemImage: "person.2.fill", value: AppTab.contacts) {
                contactsTab
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        // The default style: a tab bar on iPhone, the floating top tab bar on
        // iPad. Not `.sidebarAdaptable`: in a landscape split it opens a tab
        // sidebar beside the folder sidebar and squeezes the reader.
        .tint(themeManager.palette.accent)
        .environment(\.theme, themeManager.palette)
        .environment(\.shellLayout, shell.layout)
        .environment(\.presentCompose) { draft in
            shell.compose = .draft(draft)
        }
        .modifier(ShellObservers(
            shell: shell,
            inboxViewModel: inboxViewModel,
            contactsViewModel: contactsViewModel,
            onInboxTab: router.selectedTab == .inbox
        ))
        // The one compose sheet, above the stack/split switch: a draft being
        // written survives the window changing shape. It covers itself while
        // locked (`ComposeView`), which the root cover cannot do over it.
        .sheet(item: $shell.compose, onDismiss: takeComposeRequestIfIdle) { sheet in
            ComposeView(draft: sheet.draft)
                .environment(\.theme, themeManager.palette)
                .presentationSizing(.page)
        }
        .onChange(of: router.composeRequest, initial: true) {
            takeComposeRequestIfIdle()
        }
        .sheet(item: $router.pairingParams) { params in
            PushPairingView(initialParams: params)
                .environment(\.theme, themeManager.palette)
        }
        .sheet(item: $router.mfaRoute) { route in
            MfaApprovalView(challenge: route.challenge)
                .environment(\.theme, themeManager.palette)
        }
        .lockAwareRouting(router)
#if os(iOS)
        .fullScreenCover(isPresented: lockBinding) {
            UnlockView(manager: SingletonGraph.shared.appLockManager)
                .environment(\.theme, themeManager.palette)
        }
#endif
    }

    @ViewBuilder
    private var inboxTab: some View {
        switch shell.layout {
        case .split:
            InboxSplitView(viewModel: inboxViewModel, state: shell)
        case .stack:
            NavigationStack(path: mailPath) {
                InboxView(viewModel: inboxViewModel, state: shell)
            }
        }
    }

    @ViewBuilder
    private var contactsTab: some View {
        switch shell.layout {
        case .split:
            NavigationSplitView {
                ContactsListView(viewModel: contactsViewModel, selection: $shell.openContactID)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
            } detail: {
                contactDetail
            }
            .navigationSplitViewStyle(.balanced)
        case .stack:
            NavigationStack(path: contactPath) {
                ContactsListView(viewModel: contactsViewModel)
            }
        }
    }

    @ViewBuilder
    private var contactDetail: some View {
        if let id = shell.openContactID,
           let contact = contactsViewModel.contacts.first(where: { $0.localId == id }) {
            ContactDetailView(contact: contact, viewModel: contactsViewModel)
                .id(id)
        } else {
            EmptyStateView(message: "Select a contact", systemImage: "person.crop.circle")
                .frame(maxWidth: 340)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(themeManager.palette.bg)
        }
    }

    /// The inbox stack's path: the open message, if any.
    private var mailPath: Binding<[Email]> {
        Binding(
            get: { mailStackReady ? shell.openEmail.map { [$0] } ?? [] : [] },
            set: { path in
                guard mailStackReady else { return }
                shell.openEmail = path.last
            }
        )
    }

    /// The contacts stack's path: the open contact, by id.
    private var contactPath: Binding<[UUID]> {
        Binding(
            get: { contactStackReady ? shell.openContactID.map { [$0] } ?? [] : [] },
            set: { path in
                guard contactStackReady else { return }
                shell.openContactID = path.last
            }
        )
    }

    /// Opens a `mailto:` compose only when no compose is on screen; a link
    /// that arrives meanwhile waits in the router and opens when the current
    /// compose closes (`takeComposeRequest(composeIsOpen:)`).
    private func takeComposeRequestIfIdle() {
        if let draft = router.takeComposeRequest(composeIsOpen: shell.compose != nil) {
            shell.compose = .draft(draft)
        }
    }

    /// Presented while locked; dismissal happens only through a successful
    /// unlock flipping `isLocked`, so the setter is a no-op.
    private var lockBinding: Binding<Bool> {
        Binding(
            get: { SingletonGraph.shared.appLockManager.isLocked },
            set: { _ in }
        )
    }
}

/// Keeps `MailShellState` in step with the inbox and contacts, from above
/// the layout switch, so a list being rebuilt for a new layout is never read
/// as the user leaving it.
private struct ShellObservers: ViewModifier {
    let shell: MailShellState
    let inboxViewModel: InboxViewModel
    let contactsViewModel: ContactsViewModel
    let onInboxTab: Bool

    private var listPresence: InboxListPresence {
        InboxListPresence(
            onInboxTab: onInboxTab,
            layout: shell.layout,
            messageOpen: shell.openEmail != nil
        )
    }

    func body(content: Content) -> some View {
        content
            // Leaving the list commits what is held for Undo; the window
            // changing shape does not (root AGENTS.md, "Inbox list actions").
            .onChange(of: listPresence) { old, new in
                switch InboxListPresence.departure(from: old, to: new) {
                case .left:
                    shell.endSelection()
                    inboxViewModel.leaveInbox()
                case .relaid:
                    inboxViewModel.leaveInbox(commitsHeldActions: false)
                case nil:
                    break
                }
            }
            // A selection never outlives the folder it was made in, nor a
            // search starting, landing, or ending; the open message goes
            // with its folder.
            .onChange(of: inboxViewModel.folder) { shell.folderChanged() }
            .onChange(of: inboxViewModel.selectionResetRequest) { shell.endSelection() }
            .onChange(of: inboxViewModel.searchDismissRequest) { shell.searchDismissed() }
            .onChange(of: inboxViewModel.accountGeneration) { shell.accountForgotten() }
            .onChange(of: inboxViewModel.filteredEmails) {
                shell.listChanged(visible: inboxViewModel.filteredEmails.map(\.id))
            }
            .onChange(of: contactsViewModel.contacts) {
                shell.contactsChanged(present: Set(contactsViewModel.contacts.map(\.localId)))
            }
    }
}
