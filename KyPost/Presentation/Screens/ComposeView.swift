//
//  ComposeView.swift
//  KyPost
//
//  Compose UI (spec §7): aligned header fields, a rich-text body
//  (Bold/Italic/Underline toolbar + system formatting controls; formatted
//  drafts send as mode:"html"), and attachments via file picker or drag &
//  drop. macOS shows this in its own window ("compose" WindowGroup,
//  ⌘↩ sends); iOS presents it as a sheet. Errors show inline and keep the
//  draft in memory.
//

import SwiftUI
import UniformTypeIdentifiers

/// Anchors each recipient row so the dropdown can be positioned against it
/// from the top of the view tree.
private struct RecipientAnchorKey: PreferenceKey {
    static let defaultValue: [RecipientField: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [RecipientField: Anchor<CGRect>],
        nextValue: () -> [RecipientField: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}

struct ComposeView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fontResolutionContext) private var fontResolutionContext
    @Environment(\.openURL) private var openURL

    @State private var viewModel: ComposeViewModel
    @State private var selection = AttributedTextSelection()
    @State private var showFileImporter = false
    @State private var showAddressBook = false
    /// nil = nothing highlighted. The dropdown opens with no selection so
    /// Return commits what was actually typed; see `handleKey`.
    @State private var highlighted: Int?
    /// Drives the Discard / Keep editing prompt.
    @State private var confirmingDiscard = false
    /// Set once the user chose Discard, so the close that follows is not
    /// asked about again.
    @State private var discardConfirmed = false
    /// The compose's own width; at `twoColumnMinimumWidth` and up (iOS) the
    /// header and the body sit side by side.
    @State private var width: CGFloat = 0
    @FocusState private var focusedField: RecipientField?

    /// Android's two-column compose threshold (KyPost-for-Android e247fc6e,
    /// 600dp), measured against the sheet, not the window.
    nonisolated static let twoColumnMinimumWidth: CGFloat = 600

    /// `draft` prefills reply/reply-all/forward compositions.
    init(draft: ComposeDraft? = nil) {
        _viewModel = State(initialValue: ComposeViewModel(
            sendEmail: SingletonGraph.shared.sendEmailUseCase,
            contacts: SingletonGraph.shared.contactsViewModel,
            pgp: SingletonGraph.shared.pgpSendService,
            draft: draft,
            signature: SingletonGraph.shared.mailSignatureStore.signature,
            isLocked: { SingletonGraph.shared.appLockManager.isLocked }
        ))
    }

    private var isLocked: Bool { SingletonGraph.shared.appLockManager.isLocked }

    var body: some View {
#if os(macOS)
        content
            .frame(minWidth: 560, minHeight: 480)
#else
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
        }
        // The root lock cover is a `fullScreenCover`, which cannot present
        // over this sheet, and the router cannot dismiss a sheet the inbox
        // owns. So the sheet covers itself — over the navigation bar too, so
        // Send is not reachable — and keeps the draft underneath for after
        // unlock. macOS gets `LockedOverlay` from its compose scene.
        .overlay {
            if isLocked {
                UnlockView(manager: SingletonGraph.shared.appLockManager)
                    .background(theme.bg.ignoresSafeArea())
            }
        }
#endif
    }

    /// Whether this compose is wide enough for two columns. iOS only: the
    /// macOS window keeps its one column at every size.
    private var isTwoColumn: Bool {
#if os(iOS)
        width >= Self.twoColumnMinimumWidth
#else
        false
#endif
    }

    private var content: some View {
        Group {
            if isTwoColumn {
                // Android's wide compose: the envelope (recipients, subject,
                // protection, files, notices) on the left, the message on the
                // right, 2:3.
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            envelope
                            attachmentsAndNotices
                        }
                    }
                    .frame(width: (width * 0.4).rounded())
                    Divider().overlay(theme.line)
                    bodyEditor
                }
            } else {
                VStack(spacing: 0) {
                    envelope
                    Divider().overlay(theme.line)
                    bodyEditor
                    attachmentsAndNotices
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(theme.bg)
        // The dropdown is anchored from up here rather than overlaid on the
        // field itself: as a sibling of the whole stack it draws reliably
        // over the AppKit-hosted TextEditor, can spill outside the header
        // Grid, and still inherits the theme.
        .overlayPreferenceValue(RecipientAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let field = viewModel.suggestionsField,
                   let anchor = anchors[field] {
                    dropdown(field: field, rect: proxy[anchor], in: proxy.size)
                }
            }
        }
        .toast(message: viewModel.toastMessage)
        .navigationTitle("New Email")
        .toolbar { toolbarContent }
        .task {
            viewModel.adoptForwardedAttachments()
            await viewModel.loadContactsIfNeeded()
        }
        .sheet(isPresented: $showAddressBook) {
            AddressBookView(viewModel: viewModel)
                .environment(\.theme, theme)
        }
        // Copy is verbatim from Client_Encrypted_Send.md — the wording carries
        // the security property. Cancel is the default action (.defaultAction,
        // so Return fires it rather than the destructive button); the confirm
        // button is destructive because it puts plaintext on the server.
        //
        // `presenting:` hands the pickup value into both closures instead of
        // reading it back off the view model after the dialog is dismissed:
        // SwiftUI writes `false` through the `isPresented` binding
        // synchronously when a button is tapped, before the button's own
        // `Task { }` action body runs, so by the time that action read
        // `viewModel.pendingPickup` it was already nil (Critical 1).
        .confirmationDialog(
            "Send an unencrypted link?",
            isPresented: Binding(
                get: { viewModel.pendingPickup != nil },
                set: { if !$0 { viewModel.cancelPickupFallback() } }
            ),
            titleVisibility: .visible,
            presenting: viewModel.pendingPickup
        ) { pickup in
            Button("Send link anyway", role: .destructive) {
                Task { await viewModel.confirmPickupFallback(pickup) }
            }
            Button("Cancel", role: .cancel) { viewModel.cancelPickupFallback() }
                .keyboardShortcut(.defaultAction)
        } message: { pickup in
            Text(viewModel.pickupConfirmationMessage(for: pickup))
        }
        // The handoff opens the user's browser, never an in-app web view: it
        // shares no session and would put an account-password field in here
        // (kypost-server docs/E2E_PGP.md requirement 5).
        .onChange(of: viewModel.webmailHandoffURL) {
            if let url = viewModel.webmailHandoffURL {
                openURL(url)
                viewModel.didOpenWebmail()
            }
        }
        .task { await viewModel.loadPgpIdentityIfNeeded() }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    viewModel.addAttachment(from: url)
                }
            }
        }
        // Dragging files from Finder anywhere onto the compose surface
        // attaches them (addAttachment ignores non-file URLs).
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            for url in files {
                viewModel.addAttachment(from: url)
            }
            return true
        }
        .onChange(of: viewModel.didSend) {
            if viewModel.didSend { dismiss() }
        }
        // Leaving a field commits what's in it, so a typed address isn't
        // quietly lost by clicking away. The dropdown belongs to the field
        // that had focus, so it closes on any change — not just on losing
        // focus entirely, or it would hang over the next field.
        .onChange(of: focusedField) { previous, current in
            guard previous != current else { return }
            if let previous {
                viewModel.commitPendingInput(for: previous, reportingErrors: false)
            }
            viewModel.closeSuggestions()
            highlighted = nil
        }
        // Closing a message with anything in it asks first (Android #118).
        // There is no server-side draft to offer, so it is a plain discard
        // confirmation, and the copy says nothing is kept.
        .confirmationDialog(
            "Discard this message?",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                discardConfirmed = true
                dismiss()
            }
            Button("Keep editing", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("It has not been sent, and KyPost keeps no copy.")
        }
#if os(iOS)
        // A swipe down would otherwise drop the sheet without asking: it is
        // refused, and the refusal raises the same prompt as Cancel. Locked,
        // the sheet stays put so the draft survives to the unlock.
        .interactiveDismissDisabled(needsDiscardConfirmation || isLocked)
        .background(SheetDismissGuard {
            if needsDiscardConfirmation, !isLocked { confirmingDiscard = true }
        })
#else
        // The window's close button and ⌘W, which never reach `Cancel`.
        .background(WindowCloseGuard(
            shouldConfirm: { needsDiscardConfirmation },
            confirm: { confirmingDiscard = true }
        ))
#endif
        // Anything this compose presents would sit above the lock cover
        // (a sheet or dialog outranks an overlay on both platforms), so the
        // lock closes it. The draft itself is kept.
        .onChange(of: isLocked) { _, locked in
            guard locked else { return }
            showAddressBook = false
            showFileImporter = false
            confirmingDiscard = false
            viewModel.cancelPickupFallback()
        }
        .tint(theme.accent)
    }

    private var envelope: some View {
        VStack(spacing: 0) {
            headerFields
                .padding(.horizontal)
                .padding(.vertical, 10)

            pgpControls
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }

    private var bodyEditor: some View {
        TextEditor(text: $viewModel.body, selection: $selection)
            .font(AppFont.mono(14))
            .foregroundStyle(theme.ink)
            .scrollContentBackground(.hidden)
            .textInputFormattingControlVisibility(.visible, for: .all)
            .padding(8)
            .frame(minHeight: 160)
    }

    @ViewBuilder
    private var attachmentsAndNotices: some View {
        if !viewModel.attachments.isEmpty {
            attachmentBar
        }

        if let warning = viewModel.keylessWarningText {
            messageLine(warning, color: theme.ink)
        }

        if let notice = viewModel.noticeMessage {
            messageLine(notice, color: theme.ink)
        }

        if let message = viewModel.errorMessage {
            messageLine(message, color: SemanticColors.danger)
        }
    }

    private var needsDiscardConfirmation: Bool {
        viewModel.closingNeedsConfirmation && !discardConfirmed
    }

    /// Cancel: closes at once when there is nothing to lose, else asks.
    private func requestClose() {
        if needsDiscardConfirmation {
            confirmingDiscard = true
        } else {
            dismiss()
        }
    }

    // MARK: - PGP

    /// Toggles for a server-custody account, and for a client-custody account
    /// **on an enrolled device** — which can do the crypto itself. An
    /// unenrolled one still gets the webmail handoff: this app must never let
    /// the user believe an encrypted send succeeded when it could not happen.
    @ViewBuilder
    private var pgpControls: some View {
        if viewModel.pgpComposeControls.clientSide {
            clientSideControls
        } else {
            serverCustodyControls
        }
    }

    /// On this path the two chips are one decision. The relay accepts
    /// `multipart/encrypted` only, so sign-only cannot be expressed — offering
    /// it as a separate switch would be offering something that silently does
    /// nothing.
    @ViewBuilder
    private var clientSideControls: some View {
        HStack(spacing: 16) {
            Toggle("Encrypt and sign on this device", isOn: Binding(
                get: { viewModel.encrypt },
                set: { newValue in
                    viewModel.encrypt = newValue
                    viewModel.sign = newValue
                }
            ))
            Spacer(minLength: 0)
        }
        .font(AppFont.ui(12, weight: .medium))
        .foregroundStyle(theme.ink)
    }

    private var encryptToggle: some View {
        Toggle(isOn: $viewModel.encrypt) {
            Text("Encrypt").lineLimit(1).fixedSize()
        }
        .fixedSize()
    }

    private var signToggle: some View {
        Toggle(isOn: $viewModel.sign) {
            Text("Sign").lineLimit(1).fixedSize()
        }
        .fixedSize()
    }

    @ViewBuilder
    private var serverCustodyControls: some View {
        switch viewModel.pgpCustody {
        case .serverHeld:
            // The two-column compose gives this a narrow column: stack the
            // switches rather than let a label wrap mid-word.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    encryptToggle
                    signToggle
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    encryptToggle
                    signToggle
                }
            }
            .font(AppFont.ui(12, weight: .medium))
            .foregroundStyle(theme.ink)
        case .clientHeld:
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(theme.ink.opacity(0.7))
                Text("This account's PGP key is held only by your browser, so signing and encryption happen there.")
                    .font(AppFont.ui(12))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Encrypt in webmail…") {
                    Task { await viewModel.handOffToWebmail(fontTraits: fontTraits) }
                }
                .font(AppFont.ui(12, weight: .medium))
                .buttonStyle(.borderless)
                .disabled(viewModel.isSending || viewModel.isSent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
        case .noIdentity, .none:
            EmptyView()
        }
    }

    private func messageLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(AppFont.ui(13))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 8)
    }

    // MARK: - Header fields

    private var headerFields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(RecipientField.allCases, id: \.self) { field in
                headerRow(field.label) {
                    recipientField(field)
                }
            }
            headerRow("Subject:") {
                TextField("", text: $viewModel.subject)
                    .font(AppFont.ui(14, weight: .medium))
                    .textFieldStyle(.plain)
            }
        }
#if os(iOS)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
#endif
    }

    private func headerRow(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        GridRow {
            Text(label)
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(theme.ink.opacity(0.7))
                .gridColumnAlignment(.trailing)
            field()
                .foregroundStyle(theme.inkStrong)
        }
    }

    private func recipientField(_ field: RecipientField) -> some View {
        HStack(spacing: 6) {
            RecipientTokenField(
                placeholder: field == .to ? "recipient@example.com" : "",
                tokens: Binding(
                    get: { viewModel[field] },
                    set: { viewModel[field] = $0 }
                ),
                input: Binding(
                    get: { viewModel[input: field] },
                    set: { viewModel[input: field] = $0 }
                ),
                onCommit: { commit(field) },
                onRemove: { viewModel.remove($0, from: field) }
            )
            .focused($focusedField, equals: field)
            .onChange(of: viewModel[input: field]) {
                guard focusedField == field else { return }
                highlighted = nil
                viewModel.updateSuggestions(for: field)
            }
            .anchorPreference(key: RecipientAnchorKey.self, value: .bounds) { [field: $0] }
            .onKeyPress { handleKey($0, in: field) }

            if field == .to {
                Button {
                    showAddressBook = true
                } label: {
                    Image(systemName: "text.book.closed")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.ink.opacity(0.7))
                .help("Browse contacts")
                .accessibilityLabel("Browse contacts")
            }
        }
    }

    // MARK: - Recipient input

    private func commit(_ field: RecipientField) {
        if let highlighted, viewModel.suggestionsField == field,
           viewModel.suggestions.indices.contains(highlighted) {
            viewModel.selectSuggestion(viewModel.suggestions[highlighted], for: field)
        } else {
            viewModel.commitPendingInput(for: field)
        }
        highlighted = nil
    }

    /// Key events bubble up the focus chain, so this fires while the inner
    /// TextField still holds focus. `.ignored` hands the key back for normal
    /// editing; `.handled` swallows it.
    private func handleKey(_ press: KeyPress, in field: RecipientField) -> KeyPress.Result {
        let isOpen = viewModel.suggestionsField == field
        switch press.key {
        case .downArrow where isOpen:
            let count = viewModel.suggestions.count
            guard count > 0 else { return .ignored }
            highlighted = highlighted.map { min($0 + 1, count - 1) } ?? 0
            return .handled
        case .upArrow where isOpen:
            guard viewModel.suggestions.count > 0 else { return .ignored }
            // Arrowing off the top returns to "nothing selected" rather than
            // sticking on row 0, so the typed text is reachable again.
            highlighted = highlighted.flatMap { $0 == 0 ? nil : $0 - 1 }
            return .handled
        case .escape where isOpen:
            // Must be handled: on iOS compose is a sheet, and an unhandled
            // Escape from a hardware keyboard would dismiss it and bin the
            // draft.
            viewModel.closeSuggestions()
            highlighted = nil
            return .handled
        case .return where highlighted != nil:
            commit(field)
            return .handled
        case .tab where highlighted != nil:
            commit(field)
            return .handled
        default:
            // No backspace-deletes-last-token case: AppKit's field editor
            // swallows backspace before onKeyPress sees it, at any level of
            // the focus chain, even with the field empty. The only known way
            // around it is a zero-width sentinel character in the text, which
            // corrupts paste and selection. Tokens come off via their X
            // button, which works on both platforms.
            return .ignored
        }
    }

    // MARK: - Suggestions

    private func dropdown(field: RecipientField, rect: CGRect, in size: CGSize) -> some View {
        let width = max(rect.width, 240)
        let estimatedHeight = viewModel.suggestions.isEmpty
            ? 36
            : CGFloat(viewModel.suggestions.count) * 42 + 8
        // Flip above the field when there isn't room below — the iOS
        // keyboard makes this the common case, not the rare one.
        let fitsBelow = size.height - rect.maxY >= estimatedHeight
        let y = fitsBelow ? rect.maxY + 4 : rect.minY - estimatedHeight - 4

        return ContactSuggestionsDropdown(
            matches: viewModel.suggestions,
            highlighted: highlighted,
            onHighlight: { highlighted = $0 },
            onSelect: { match in
                viewModel.selectSuggestion(match, for: field)
                highlighted = nil
                focusedField = field
            }
        )
        .frame(width: width, alignment: .topLeading)
        .position(x: rect.minX + width / 2, y: y + estimatedHeight / 2)
    }

    // MARK: - Attachments

    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 11))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.name)
                                .font(AppFont.ui(12, weight: .medium))
                                .foregroundStyle(theme.inkStrong)
                                .lineLimit(1)
                            Text(attachment.data.count.formatted(.byteCount(style: .file)))
                                .font(AppFont.ui(10))
                                .foregroundStyle(theme.ink.opacity(0.7))
                        }
                        Button {
                            viewModel.removeAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(theme.ink.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Remove attachment")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.panel, in: Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Toolbar

    /// iOS keeps the nav bar to Cancel/title/Send (everything inline
    /// truncates the title and drops the attach button); formatting and
    /// attach live in the bottom bar instead.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { requestClose() }
        }
#if os(macOS)
        ToolbarItemGroup {
            formattingControls
            attachButton
        }
#else
        ToolbarItemGroup(placement: .bottomBar) {
            formattingControls
            Spacer()
            attachButton
        }
#endif
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await viewModel.send(fontTraits: fontTraits) }
            } label: {
                if viewModel.isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Send", systemImage: "paperplane.fill")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(viewModel.isSending || viewModel.isSent)
            .help("Send (⌘↩)")
        }
    }

    private var formattingControls: some View {
        ControlGroup {
            Toggle(isOn: boldBinding) {
                Label("Bold", systemImage: "bold")
            }
            .keyboardShortcut("b")
            Toggle(isOn: italicBinding) {
                Label("Italic", systemImage: "italic")
            }
            .keyboardShortcut("i")
            Toggle(isOn: underlineBinding) {
                Label("Underline", systemImage: "underline")
            }
            .keyboardShortcut("u")
        }
    }

    private var attachButton: some View {
        Button {
            showFileImporter = true
        } label: {
            Label("Attach File", systemImage: "paperclip")
        }
        .help("Attach a file (max 25 MB total)")
    }

    // MARK: - Formatting

    /// Resolves a run's font to concrete traits so ComposeViewModel /
    /// RichTextHTML can tell bold/italic apart without a view environment.
    private var fontTraits: RichTextHTML.FontTraits {
        { [fontResolutionContext] font in
            let resolved = font.resolve(in: fontResolutionContext)
            return (resolved.isBold, resolved.isItalic)
        }
    }

    /// Bold/italic toggles follow the documented rich-TextEditor pattern:
    /// read the typing attributes, write through transformAttributes.
    private var boldBinding: Binding<Bool> {
        Binding {
            let font = selection.typingAttributes(in: viewModel.body).font ?? .default
            return font.resolve(in: fontResolutionContext).isBold
        } set: { isBold in
            viewModel.body.transformAttributes(in: &selection) {
                $0.font = ($0.font ?? .default).bold(isBold)
            }
        }
    }

    private var italicBinding: Binding<Bool> {
        Binding {
            let font = selection.typingAttributes(in: viewModel.body).font ?? .default
            return font.resolve(in: fontResolutionContext).isItalic
        } set: { isItalic in
            viewModel.body.transformAttributes(in: &selection) {
                $0.font = ($0.font ?? .default).italic(isItalic)
            }
        }
    }

    private var underlineBinding: Binding<Bool> {
        Binding {
            selection.typingAttributes(in: viewModel.body).underlineStyle != nil
        } set: { isOn in
            viewModel.body.transformAttributes(in: &selection) {
                $0.underlineStyle = isOn ? .single : nil
            }
        }
    }
}

#if os(macOS)
import AppKit

/// Asks before a compose window closes from its title-bar button or ⌘W.
///
/// Both arrive as `windowShouldClose(_:)` on the window's delegate, which
/// SwiftUI owns, so this installs a proxy that answers that one question and
/// forwards everything else to SwiftUI's delegate untouched. Re-installed on
/// every update in case SwiftUI replaces its delegate.
private struct WindowCloseGuard: NSViewRepresentable {
    let shouldConfirm: () -> Bool
    let confirm: () -> Void

    func makeCoordinator() -> CloseInterceptor { CloseInterceptor() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let interceptor = context.coordinator
        interceptor.shouldConfirm = shouldConfirm
        interceptor.confirm = confirm
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window, window.delegate !== interceptor else { return }
            interceptor.original = window.delegate
            window.delegate = interceptor
        }
    }

    final class CloseInterceptor: NSObject, NSWindowDelegate {
        weak var original: (any NSWindowDelegate)?
        var shouldConfirm: () -> Bool = { false }
        var confirm: () -> Void = {}

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if shouldConfirm() {
                confirm()
                return false
            }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}
#endif

#if os(iOS)
import UIKit

/// Reports a refused swipe-down on the sheet this view is in, so compose can
/// ask Discard / Keep editing instead of silently ignoring the gesture.
///
/// UIKit reports the attempt as `presentationControllerDidAttemptToDismiss`
/// on the presentation controller's delegate, which SwiftUI owns, so this
/// installs a proxy that handles that one call and forwards everything else
/// (including `presentationControllerShouldDismiss`, which carries
/// `interactiveDismissDisabled`) to SwiftUI's delegate untouched. Re-installed
/// on every update in case SwiftUI replaces its delegate.
private struct SheetDismissGuard: UIViewControllerRepresentable {
    let onAttempt: () -> Void

    func makeCoordinator() -> DismissInterceptor { DismissInterceptor() }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let interceptor = context.coordinator
        interceptor.onAttempt = onAttempt
        DispatchQueue.main.async { [weak controller] in
            var root = controller
            while let parent = root?.parent { root = parent }
            guard let root, root.presentingViewController != nil,
                  let presentation = root.presentationController,
                  presentation.delegate !== interceptor
            else { return }
            interceptor.original = presentation.delegate
            presentation.delegate = interceptor
        }
    }

    final class DismissInterceptor: NSObject, UIAdaptivePresentationControllerDelegate {
        weak var original: (any UIAdaptivePresentationControllerDelegate)?
        var onAttempt: () -> Void = {}

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            original?.presentationControllerDidAttemptToDismiss?(presentationController)
            onAttempt()
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}
#endif
