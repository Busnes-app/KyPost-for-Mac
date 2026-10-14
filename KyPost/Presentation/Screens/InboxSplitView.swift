//
//  InboxSplitView.swift
//  KyPost
//
//  The Inbox tab in a wide iOS/iPadOS window (`ShellLayout.split`): a
//  collapsible folder sidebar, the message list, and the open message beside
//  it. The macOS window's pattern (`MacRootView`), with the iOS list.
//
//  Everything shown lives in `MailShellState`, so switching to or from the
//  stack (rotation, multitasking, a fold) keeps it. The list never leaves the
//  screen here when a message opens, so held list actions stay on their
//  Undo timer (root AGENTS.md, "Inbox list actions").
//

import SwiftUI

struct InboxSplitView: View {
    @Environment(\.theme) private var theme

    @Bindable var viewModel: InboxViewModel
    @Bindable var state: MailShellState
    /// False while the split is being built: SwiftUI writes its own
    /// opening value through the column binding then, not the user's.
    @State private var columnsReady = false

    var body: some View {
        NavigationSplitView(columnVisibility: columns) {
            folderSidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } content: {
            InboxView(viewModel: viewModel, state: state)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            try? await Task.sleep(for: .seconds(1))
            columnsReady = true
        }
    }

    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { state.inboxColumns },
            set: { if columnsReady { state.inboxColumns = MailShellState.keptColumns($0) } }
        )
    }

    /// The same folders, order and Sent/Drafts resolution as the folder
    /// picker (`InboxView.folderRows`).
    private var folderSidebar: some View {
        List(selection: folderSelection) {
            Section("Mail") {
                InboxView.folderRows(viewModel)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Folders")
    }

    private var folderSelection: Binding<String?> {
        let choice = InboxView.folderSelection(viewModel)
        return Binding(
            get: { choice.wrappedValue },
            set: { if let name = $0 { choice.wrappedValue = name } }
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let email = state.openEmail {
            EmailDetailView(email: email, inboxViewModel: viewModel) {
                state.closeMessage()
            }
            // A new reader per message: its decrypt, body fetch and read
            // flag run for the message shown, and the last one's plaintext
            // goes with its view.
            .id(email.id)
        } else {
            EmptyStateView(
                message: state.isSelecting && !state.selection.isEmpty
                    ? String(localized: "\(state.selection.count) selected")
                    : String(localized: "Select an email"),
                systemImage: "envelope.open"
            )
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
        }
    }
}

#if DEBUG && os(iOS)
/// The shell's Inbox at a measured window size, fed by the demo mailbox in
/// memory: no graph, no pairing, no network (every request throws), nothing
/// persisted. The layout comes from `ShellLayout.resolve`, as in
/// `MainTabView`. No message is opened: the reader reads the live graph.
private struct ShellLayoutPreview: View {
    let width: CGFloat
    let height: CGFloat
    let isRegularWidth: Bool

    @State private var viewModel = Self.demoInbox()
    @State private var state = MailShellState()
    @State private var router = NavigationRouter()

    private static func demoInbox() -> InboxViewModel {
        let database = try! AppDatabase(inMemory: true)
        let repository = MailRepository(
            securePairingStore: SecurePairingStore(keychain: DemoContent.isolatedKeychain),
            emailDAO: EmailDAO(modelContainer: database.container),
            httpClient: HTTPClient { _ in throw URLError(.notConnectedToInternet) },
            overrideSource: DemoMailSource()
        )
        return InboxViewModel(
            mailRepository: repository,
            keywordRepository: KeywordRepository(
                settingsStore: KeywordSettingsStore(defaults: DemoContent.isolatedDefaults)
            )
        )
    }

    var body: some View {
        let layout = ShellLayout.resolve(isRegularWidth: isRegularWidth, windowWidth: width)
        Group {
            switch layout {
            case .split:
                InboxSplitView(viewModel: viewModel, state: state)
            case .stack:
                NavigationStack { InboxView(viewModel: viewModel, state: state) }
            }
        }
        .frame(width: width, height: height)
        .environment(router)
        .environment(\.theme, ThemeManager(defaults: DemoContent.isolatedDefaults).palette)
        .environment(\.shellLayout, layout)
        .environment(\.horizontalSizeClass, isRegularWidth ? .regular : .compact)
        .onAppear { state.layout = layout }
    }
}

#Preview("iPhone Duo inner, rotated 951×669 (split)", traits: .fixedLayout(width: 951, height: 669)) {
    ShellLayoutPreview(width: 951, height: 669, isRegularWidth: true)
}

#Preview("iPhone Duo inner, book 669×951 (stack)", traits: .fixedLayout(width: 669, height: 951)) {
    ShellLayoutPreview(width: 669, height: 951, isRegularWidth: true)
}

#Preview("iPad Pro 13-inch portrait 1032×1376 (split)", traits: .fixedLayout(width: 1032, height: 1376)) {
    ShellLayoutPreview(width: 1032, height: 1376, isRegularWidth: true)
}

#Preview("iPad mini portrait 744×1133 (stack)", traits: .fixedLayout(width: 744, height: 1133)) {
    ShellLayoutPreview(width: 744, height: 1133, isRegularWidth: true)
}

#Preview("iPad mini landscape 1133×744 (split)", traits: .fixedLayout(width: 1133, height: 744)) {
    ShellLayoutPreview(width: 1133, height: 744, isRegularWidth: true)
}
#endif
