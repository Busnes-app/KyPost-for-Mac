//
//  EmailDetailView.swift
//  KyPost
//
//  Read view. HTML bodies render in a themed WebView (matching Android
//  EmailDetailActivity's wrapper); plain-text bodies use the mono font per
//  STYLE_GUIDE §2 (web .email-reader-body-block). Reply/Reply All/Forward
//  open a prefilled composition (ComposeDraft).
//

import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import os

struct EmailDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(\.deviceIsEnrolled) private var deviceIsEnrolled
    @Environment(\.self) private var environment
    @Environment(\.dismiss) private var dismiss
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#endif

    let email: Email
    let inboxViewModel: InboxViewModel

    /// Fetched lazily on open — the inbox listing has no attachment info.
    @State private var attachments: [EmailAttachment] = []
    @State private var downloadingIndex: Int?
    @State private var quickLookURL: URL?
    /// Downloaded attachment staged for Save As…; non-nil shows the exporter.
    @State private var attachmentExport: AttachmentDocument?
    /// Reply/forward prefill; non-nil presents the compose sheet (iOS only —
    /// macOS opens the "compose" window instead).
    @State private var composeDraft: ComposeDraft?
    /// Drives the Decrypt affordance. Built in `.task` because constructing it
    /// reads the pairing out of the Keychain, which `body` must not do.
    @State private var encryptedRead: EncryptedReadViewModel?
    /// Set when Reply/Reply All/Forward is pressed on a message they are not
    /// available for; drives the explanation.
    @State private var showsReplyUnavailable = false
    /// True while Forward downloads the attachments it carries.
    @State private var preparingForward = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
                .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.panel))
                .padding([.horizontal, .top])

            if isPhishing {
                // Above the PGP bar deliberately: whether the server could
                // decrypt a message matters less than the message pretending
                // to be from us.
                phishingBanner
                    .padding(.horizontal)
                    .padding(.top, 10)
            }

            if showsPgpChrome {
                pgpBadges
                    .padding(.horizontal)
                    .padding(.top, 10)
                if pgpState != .clientProtected || !deviceIsEnrolled {
                    pgpBanner
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                decryptControls
                    .padding(.horizontal)
                    .padding(.top, 6)
            }

            // A client-protected message's outer attachments are its PGP/MIME
            // transport parts, not files the sender attached for the reader.
            if pgpState != .clientProtected, !attachments.isEmpty {
                attachmentBar
            }

            // The decrypted message's own files, from memory. Shown with the
            // body they came out of and gone with it.
            if let decrypted = encryptedRead?.body, !decrypted.attachments.isEmpty {
                decryptedAttachmentBar(decrypted.attachments)
            }
            if let model = encryptedRead, model.body != nil,
               model.signatureLine != nil || model.attachmentsOmittedMessage != nil {
                decryptedNotices(model)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }

            if let decrypted = encryptedRead?.body {
                decryptedBodyView(decrypted)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .layoutPriority(1)
            } else if suppressesBody {
                Spacer(minLength: 0)
            } else if !rendersAsPlainText {
                EmailBodyWebView(html: themedHTML(emailBodyToHTML(email.body, mode: email.bodyMode)))
                    .layoutPriority(1)
            } else {
                ScrollView {
                    Text(email.body)
                        .font(AppFont.mono(14))
                        .foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        // The sender already belongs in the message header. Repeating it in
        // the navigation bar wastes the scarce vertical space on iPhone.
        .navigationTitle("")
        .toolbar {
            // Reply/Reply All/Forward + Archive/Junk/Delete, matching Android
            // EmailDetailActivity's action row. On iOS they live in the
            // bottom bar — the navigation bar can't fit six buttons.
#if os(iOS)
            ToolbarItemGroup(placement: .bottomBar) {
                mailActionButtons
            }
#else
            ToolbarItemGroup {
                mailActionButtons
            }
#endif
        }
#if os(iOS)
        // The mail actions live in the bottom bar; hide the app tab bar
        // while reading so the two don't stack.
        .toolbarVisibility(.hidden, for: .tabBar)
        .sheet(item: $composeDraft) { draft in
            ComposeView(draft: draft).environment(\.theme, theme)
        }
#endif
        .quickLookPreview($quickLookURL)
        .onChange(of: quickLookURL) { old, new in
            guard let old, old != new else { return }
            // A decrypted attachment's file is plaintext: deleted the moment
            // its preview closes, whatever mode the app is in, and by
            // `forget()` if it never does. A no-op for any other file.
            encryptedRead?.discardPreview(old)
            // Hostile Location Protection: the preview file must not outlive
            // the Quick Look session (the disclosed brief-disk-touch gap).
            guard new == nil, hostileLocationProtectionActive else { return }
            try? FileManager.default.removeItem(at: old.deletingLastPathComponent())
        }
        .fileExporter(
            isPresented: Binding(
                get: { attachmentExport != nil },
                set: { if !$0 { attachmentExport = nil } }
            ),
            document: attachmentExport,
            contentType: .data,
            defaultFilename: attachmentExport?.name
        ) { result in
            if case .failure(let error) = result {
                Log.mail.error("Attachment save failed: \(error.localizedDescription)")
            }
        }
        .alert("Not available for encrypted mail", isPresented: $showsReplyUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Replying to encrypted mail isn't available in the app yet.")
        }
        .task {
            await prepareEncryptedRead()
            await inboxViewModel.markRead(email)
            attachments = await inboxViewModel.attachments(for: email)
        }
        .onDisappear {
            // The plaintext does not outlive the screen showing it.
            encryptedRead?.forget()
        }
    }

    /// The six mail actions, in Android's order: reply, reply all, forward,
    /// archive, junk, delete.
    @ViewBuilder
    private var mailActionButtons: some View {
        // Not `.disabled`: a disabled button cannot say why it is disabled.
        // Dimmed instead, and pressing it explains.
        Group {
            Button {
                replyOrExplain { compose(.reply(to: email)) }
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .help(replyAvailable ? "Reply to the sender" : replyUnavailableHelp)
            Button {
                replyOrExplain { compose(.replyAll(to: email, ownAddress: ownAddress)) }
            } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            .help(replyAvailable ? "Reply to the sender and all recipients" : replyUnavailableHelp)
            Button {
                replyOrExplain { forward() }
            } label: {
                if preparingForward {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                }
            }
            .disabled(preparingForward)
            .help(replyAvailable ? "Forward this email" : replyUnavailableHelp)
        }
        .opacity(replyAvailable ? 1 : 0.4)
        Button {
            Task {
                await inboxViewModel.archive(serverIds: [email.serverId])
                dismiss()
            }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        .help("Move to Archive")
        Button {
            Task {
                await inboxViewModel.markJunk(serverIds: [email.serverId])
                dismiss()
            }
        } label: {
            Label("Junk", systemImage: "xmark.bin")
        }
        .help("Move to Junk")
        Button(role: .destructive) {
            Task {
                await inboxViewModel.delete(serverIds: [email.serverId])
                dismiss()
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .help("Move to Trash")
    }

    /// Attachment chips; tapping downloads to a temp file and Quick Looks it.
    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    Button {
                        openAttachment(attachment)
                    } label: {
                        HStack(spacing: 6) {
                            if downloadingIndex == attachment.index {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 11))
                            }
                            Text(attachment.name)
                                .font(AppFont.ui(12, weight: .medium))
                                .foregroundStyle(theme.inkStrong)
                                .lineLimit(1)
                            Text(attachment.size.formatted(.byteCount(style: .file)))
                                .font(AppFont.ui(10))
                                .foregroundStyle(theme.ink.opacity(0.7))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.panel, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(downloadingIndex != nil)
                    .help("Click to preview; right-click to save")
                    .contextMenu {
                        if hostileLocationProtectionActive {
                            // Visible, not silent: say why saving is gone.
                            Button("Saving is off during Hostile Location Protection") {}
                                .disabled(true)
                        } else {
                            Button {
                                saveAttachment(attachment)
                            } label: {
                                Label("Save As…", systemImage: "square.and.arrow.down")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    /// Opens a prefilled composition: its own window on macOS (matching
    /// plain compose), a sheet on iOS.
    private func compose(_ draft: ComposeDraft) {
#if os(macOS)
        openWindow(id: "compose", value: draft)
#else
        composeDraft = draft
#endif
    }

    private var replyAvailable: Bool { mayReplyOrForward(pgpState) }

    private var replyUnavailableHelp: String {
        String(localized: "Replying to encrypted mail isn't available in the app yet.")
    }

    private func replyOrExplain(_ action: () -> Void) {
        guard replyAvailable else {
            showsReplyUnavailable = true
            return
        }
        action()
    }

    /// Forward carries the original's attachments. They travel beside the
    /// draft through `ForwardAttachmentHandoff`, never inside it — the draft
    /// is a scene value state restoration writes to disk.
    private func forward() {
        let draft = ComposeDraft.forward(email)
        guard !attachments.isEmpty else {
            compose(draft)
            return
        }
        preparingForward = true
        Task {
            let collected = await collectForwardAttachments(attachments) { attachment in
                await inboxViewModel.attachmentData(attachment, of: email)
            }
            ForwardAttachmentHandoff.shared.put(
                collected.attachments,
                notice: forwardAttachmentNotice(failed: collected.failed, tooLarge: collected.tooLarge),
                for: draft.id
            )
            preparingForward = false
            compose(draft)
        }
    }

    /// Our own relay address (the pairing's sub), excluded from Reply All.
    private var ownAddress: String? {
        (try? SingletonGraph.shared.securePairingStore.loadPairing())?.sub
    }

    private var hostileLocationProtectionActive: Bool {
        SingletonGraph.shared.hostileLocationProtectionStore.enabled
    }

    private func openAttachment(_ attachment: EmailAttachment) {
        downloadingIndex = attachment.index
        Task {
            if let url = await inboxViewModel.downloadAttachment(attachment, of: email) {
                quickLookURL = url
            }
            downloadingIndex = nil
        }
    }

    /// Downloads an attachment's bytes and stages them for the save panel.
    private func saveAttachment(_ attachment: EmailAttachment) {
        downloadingIndex = attachment.index
        Task {
            if let data = await inboxViewModel.attachmentData(attachment, of: email) {
                attachmentExport = AttachmentDocument(name: attachment.name, data: data)
            }
            downloadingIndex = nil
        }
    }

    /// Builds the reader and decrypts immediately when the key is already
    /// held. A sealed key leaves the explicit Decrypt action to raise the
    /// unlock prompt.
    @MainActor
    private func prepareEncryptedRead() async {
        guard pgpState == .clientProtected else {
            encryptedRead = nil
            return
        }
        let model = EncryptedReadViewModel(
            reader: SingletonGraph.shared.makeEncryptedMessageReader(),
            mailbox: email.folder,
            messageId: email.serverId,
            sender: email.senderEmail
        )
        encryptedRead = model
        await model.attemptWithoutPrompting()
    }

    /// The decrypted message. Rendered from the view model's in-memory copy;
    /// nothing here writes it back to the store.
    @ViewBuilder
    private func decryptedBodyView(_ decrypted: DecryptedBody) -> some View {
        if let html = encryptedRead?.renderedHTML ?? decrypted.html, !html.isEmpty {
            EmailBodyWebView(html: themedHTML(html))
        } else {
            ScrollView {
                Text(decrypted.plain ?? "")
                    .font(AppFont.mono(13))
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
        }
    }

    /// The Decrypt row: button, progress, and the outcome's own sentence.
    @ViewBuilder
    private var decryptControls: some View {
        if let model = encryptedRead, model.isAvailable {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if model.isWorking {
                        ProgressView().controlSize(.small)
                        Text("Decrypting…")
                            .font(AppFont.ui(12))
                            .foregroundStyle(theme.ink)
                    }
                    if model.showsDecryptButton {
                        Button("Decrypt this email") {
                            Task { await model.decrypt() }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(width: 180)
                    }
                    // Only where retrying could actually change the answer.
                    // `noEncryptedContent` is terminal, and a Retry that
                    // cannot succeed teaches the user their mail is broken.
                    if model.showsRetryButton {
                        Button("Try again") {
                            Task { await model.decrypt() }
                        }
                        .font(AppFont.ui(12, weight: .medium))
                        .buttonStyle(.borderless)
                    }
                    Spacer(minLength: 0)
                }
                if let message = model.statusMessage {
                    Text(message)
                        .font(AppFont.ui(12))
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What stays visible once plaintext is on screen: the signature line and
    /// a dropped-attachment notice.
    private func decryptedNotices(_ model: EncryptedReadViewModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let line = model.signatureLine {
                // A sender verdict is shown against the address the SERVER
                // resolved, never the raw From — the two are separable by an
                // attacker, and a correct verdict beside the wrong address is
                // still a lie.
                Text(line)
                    .font(AppFont.ui(12))
                    .foregroundStyle(
                        signatureIsAlarming(model.signature) ? SemanticColors.danger : theme.ink
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let omitted = model.attachmentsOmittedMessage {
                Text(omitted)
                    .font(AppFont.ui(12))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Chips for the decrypted message's own files. Tap previews through a
    /// staged temp file; Save As writes only where the user chooses, and is
    /// refused under Hostile Location Protection like any other attachment.
    private func decryptedAttachmentBar(_ parts: [DecryptedAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(parts) { part in
                    Button {
                        if let model = encryptedRead, let url = model.stageForPreview(part) {
                            quickLookURL = url
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 11))
                            // Flattened: a sender-chosen name must not reverse
                            // itself with a bidi override.
                            Text(displayHeaderText(part.name))
                                .font(AppFont.ui(12, weight: .medium))
                                .foregroundStyle(theme.inkStrong)
                                .lineLimit(1)
                            Text(part.data.count.formatted(.byteCount(style: .file)))
                                .font(AppFont.ui(10))
                                .foregroundStyle(theme.ink.opacity(0.7))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.panel, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Click to preview; right-click to save")
                    .contextMenu {
                        if hostileLocationProtectionActive {
                            Button("Saving is off during Hostile Location Protection") {}
                                .disabled(true)
                        } else {
                            Button {
                                attachmentExport = AttachmentDocument(
                                    name: safeAttachmentFileName(part.name),
                                    data: part.data
                                )
                            } label: {
                                Label("Save As…", systemImage: "square.and.arrow.down")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(email.subject.isEmpty ? "(No subject)" : email.subject)
                .font(AppFont.ui(20, weight: .semibold))
                .foregroundStyle(theme.inkStrong)

            HStack(spacing: 10) {
                AvatarView(name: email.senderName.isEmpty ? email.senderEmail : email.senderName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(email.senderName.isEmpty ? email.senderEmail : email.senderName)
                        .font(AppFont.ui(15, weight: .medium))
                        .foregroundStyle(theme.inkStrong)
                    Text(email.senderEmail)
                        .font(AppFont.mono(12))
                        .foregroundStyle(theme.ink.opacity(0.8))
                    recipientLines
                }
                Spacer()
                Text(email.receivedAt, format: .dateTime.day().month().hour().minute())
                    .font(AppFont.ui(12))
                    .foregroundStyle(theme.ink.opacity(0.7))
            }

            if !email.keywords.isEmpty {
                HStack(spacing: 6) {
                    ForEach(email.keywords.sorted(), id: \.self) { keyword in
                        Text(keyword)
                            .font(AppFont.ui(11, weight: .medium))
                            .foregroundStyle(theme.readableOnAccent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(theme.accent))
                    }
                }
            }
        }
    }

    /// To and Cc under the sender, flattened to one line each so a display
    /// name cannot forge a labelled line or reverse an address. Hidden when
    /// the row carries no recipients.
    @ViewBuilder
    private var recipientLines: some View {
        let lines = detailRecipientLines(to: email.sentTo, cc: email.cc)
        if let to = lines.to {
            Text("To: \(to)")
                .font(AppFont.ui(12))
                .foregroundStyle(theme.ink.opacity(0.8))
                .lineLimit(3)
                .textSelection(.enabled)
        }
        if let cc = lines.cc {
            Text("Cc: \(cc)")
                .font(AppFont.ui(12))
                .foregroundStyle(theme.ink.opacity(0.8))
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    /// Native wrapping `Text` rather than WebKit. Driven by the relay's
    /// `bodyMode` when it sent one — sniffing a body the server has already
    /// described is what this replaced. See EmailBodyRendering.swift.
    private var rendersAsPlainText: Bool {
        isPlainTextBody(email.body, mode: email.bodyMode)
    }

    private var isPhishing: Bool { isFlaggedPhishing(email.keywords) }

    /// Wording is deliberate and matches Android's `email_phishing_warning`:
    /// it names the concrete protection applied, and it tells the user the one
    /// thing that actually stops the attack — that a pairing request they did
    /// not start is never legitimate.
    private var phishingBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(SemanticColors.danger)
            Text(phishingWarningText)
                .font(AppFont.ui(12))
                .foregroundStyle(theme.inkStrong)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SemanticColors.dangerFill, in: RoundedRectangle(cornerRadius: Shape.field))
        .overlay(
            RoundedRectangle(cornerRadius: Shape.field)
                .strokeBorder(SemanticColors.dangerBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var phishingWarningText: String {
        "This message impersonates KyPost. Links to KyPost app addresses have been blocked. "
            + "KyPost will never ask you to confirm a pairing request by email — never approve "
            + "one you did not start yourself, on this device."
    }

    private var pgpState: PgpMessageState {
        pgpMessageState(
            pgpEncrypted: email.pgpEncrypted,
            pgpDecryptError: email.pgpDecryptError,
            body: email.body
        )
    }

    /// PGP controls explain or unlock an unreadable message. Once plaintext is
    /// visible they are redundant and the message gets the space back.
    private var showsPgpChrome: Bool {
        pgpState != .none && encryptedRead?.body == nil
    }

    /// Neither unreadable state has content to render; showing an empty
    /// WebView for them is the defect this change fixes.
    private var suppressesBody: Bool {
        pgpState == .clientProtected || pgpState == .decryptFailed
    }

    /// Wraps the message HTML in the same themed scaffold Android uses
    /// (EmailDetailActivity), so colors track the active palette.
    private func themedHTML(_ body: String) -> String {
        """
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <style>
                body {
                    font-family: "IBM Plex Mono", ui-monospace, Menlo, monospace;
                    font-size: 14px;
                    line-height: 1.5;
                    color: \(cssHex(theme.inkStrong));
                    background-color: \(cssHex(theme.bg));
                    margin: 0;
                    padding: 12px;
                    word-break: break-word;
                    overflow-wrap: anywhere;
                }
                *, *::before, *::after {
                    box-sizing: border-box;
                    max-width: 100%;
                    overflow-wrap: anywhere !important;
                    word-break: break-word !important;
                    white-space: normal !important;
                }
                a { color: \(cssHex(theme.accent)); }
                img { max-width: 100%; height: auto; }
                table { width: 100% !important; table-layout: fixed; }
                td, th { overflow-wrap: anywhere; word-break: break-word; }
                body pre { white-space: pre-wrap !important; overflow-wrap: anywhere; }
            </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    private func cssHex(_ color: Color) -> String {
        let resolved = color.resolve(in: environment)
        func channel(_ value: Float) -> Int {
            Int((max(0, min(1, value)) * 255).rounded())
        }
        return String(
            format: "#%02X%02X%02X",
            channel(resolved.red), channel(resolved.green), channel(resolved.blue)
        )
    }

    /// Mirrors the web reader's two security badges (frontend ReadPage.tsx).
    @ViewBuilder
    private var pgpBadges: some View {
        HStack(spacing: 6) {
            StatusBadgeView(
                label: pgpState == .decryptFailed ? "PGP: could not decrypt" : "PGP: encrypted",
                isActive: pgpState != .decryptFailed
            )
            if showsSignaturePill(state: pgpState, signed: email.pgpSigned) {
                StatusBadgeView(
                    label: email.pgpVerified ? "signature verified" : "signature not verified",
                    isActive: email.pgpVerified
                )
            }
            Spacer(minLength: 0)
        }
    }

    /// Same shape as remoteContentBanner below. Copy is ported verbatim from
    /// kypost-android's strings.xml — do not reword.
    @ViewBuilder
    private var pgpBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: pgpState == .decryptFailed ? "exclamationmark.triangle.fill" : "lock.fill")
                .foregroundStyle(theme.ink.opacity(0.7))
            Text(pgpBannerText)
                .font(AppFont.ui(12))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
    }

    private var pgpBannerText: String {
        switch pgpState {
        case .clientProtected:
            // The unenrolled copy is Android's, verbatim, and stays that way.
            // The enrolled copy is new because the old sentence became false
            // the moment this device could hold a key: telling someone their
            // mail "can't be read here" while a Decrypt button sits beneath it
            // is worse than saying nothing.
            if deviceIsEnrolled {
                "This message is end-to-end encrypted. This device holds your key, so it can be decrypted here."
            } else {
                "This message is end-to-end encrypted. Enroll this device in Settings to decrypt it here."
            }
        case .decryptFailed:
            "This message is encrypted and couldn't be decrypted: \(email.pgpDecryptError)"
        case .decryptedByServer:
            "This message was encrypted. The server decrypted it to show it here."
        case .none:
            ""
        }
    }
}

/// Wraps downloaded attachment bytes for `fileExporter`. The generic `.data`
/// content type keeps the attachment's own filename extension authoritative.
private struct AttachmentDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var name: String
    var data: Data

    init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        name = configuration.file.filename ?? "attachment"
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Renders one email's HTML; link taps open in the default browser instead
/// of navigating the message view.
///
/// Sender-controlled HTML is untrusted input, the same way it is in any mail
/// client: JavaScript execution is disabled unconditionally (mainstream mail
/// clients — Apple Mail, Thunderbird, Outlook — do the same in their message
/// view), remote resources (images, stylesheets, anything with a network
/// fetch of its own) are blocked by default, matching those clients'
/// "load remote content" opt-in, and navigation out of the message is
/// default-deny (see `navigationPolicy`) so the block can't be walked around
/// with a redirect. Together: a message can't silently beacon home or probe
/// the local network the moment it's opened.
struct EmailBodyWebView: View {
    let html: String

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var page: WebPage?
    @State private var allowsRemoteContent = false

    private struct LoadKey: Equatable {
        let html: String
        let allowsRemoteContent: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !allowsRemoteContent {
                remoteContentBanner
                    .padding(.horizontal)
                    .padding(.vertical, 10)
            }
            Group {
                if let page {
                    WebView(page)
                        .webViewBackForwardNavigationGestures(.disabled)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: LoadKey(html: html, allowsRemoteContent: allowsRemoteContent)) {
            // Rebuilt (not reused) whenever `allowsRemoteContent` changes —
            // `loadsSubresources` is fixed at configuration time, so opting
            // in to remote content requires a fresh WebPage.
            let page = WebPage(
                configuration: Self.makeConfiguration(allowsRemoteContent: allowsRemoteContent),
                navigationDecider: LinksOpenExternally(openURL: openURL)
            )
            self.page = page
            page.load(html: html)
        }
    }

    private var remoteContentBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(theme.ink.opacity(0.7))
            Text("Remote images and content are blocked.")
                .font(AppFont.ui(12))
                .foregroundStyle(theme.ink)
            Spacer(minLength: 8)
            Button("Load Remote Content") { allowsRemoteContent = true }
                .font(AppFont.ui(12, weight: .medium))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
    }

    /// Pure so the hardening it applies (JS off unconditionally, remote
    /// content gated) is directly testable without touching WebKit itself.
    static func makeConfiguration(allowsRemoteContent: Bool) -> WebPage.Configuration {
        var configuration = WebPage.Configuration()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        configuration.loadsSubresources = allowsRemoteContent
        // A mail reader has no reason to keep website state. The default store
        // is the persistent one, so once the user loaded remote content for a
        // single message, WebKit's on-disk cache retained a record of which
        // messages were opened — and Hostile Location Protection never cleared
        // it, because nothing outside AppDatabase knew that mode existed.
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    /// What a navigation out of the message body is allowed to do.
    enum BodyNavigation: Equatable {
        /// The message document itself loading from memory.
        case allow
        case openInBrowser(URL)
        case block
    }

    /// Default-deny, and pure so the rule is testable without WebKit.
    ///
    /// Disabling JavaScript does not make this view's navigation safe on its
    /// own, and neither does `loadsSubresources`: a `<meta http-equiv=
    /// "refresh">` is plain HTML and a main-frame navigation, so it is neither
    /// script nor subresource. Allowing everything that isn't a link tap would
    /// let a message redirect the reader to a page of the sender's choosing
    /// the instant it opens — a read receipt that walks straight past the
    /// blocked-remote-content banner, rendering the sender's page inside the
    /// reader's own chrome. So: link taps go to the browser, the in-memory
    /// document loads, everything else is dropped.
    nonisolated static func navigationPolicy(
        url: URL?,
        isLinkActivation: Bool
    ) -> BodyNavigation {
        // `page.load(html:)` serves the message against an `about:` base URL;
        // that navigation is the message itself and has to go through.
        let scheme = url?.scheme?.lowercased()
        if scheme == "about" { return .allow }
        guard let url else { return .block }
        // Handing a link tap to `openURL` hands it to the system, and the
        // system routes this app's own scheme straight back into this app. A
        // `kypost://native-pair` link in a message would therefore raise the
        // pairing confirmation on top of the sender's pretext — the attacker
        // supplies the story, and we supply the dialog. The message body is
        // never allowed to reach the app's own URL handlers.
        //
        // Restricted to http/https rather than blocking a list of schemes:
        // a mail body has no business opening `file:`, `tel:` or any other
        // scheme some installed app claims either, and a denylist would need
        // updating every time one appears.
        guard scheme == "http" || scheme == "https" else { return .block }
        return isLinkActivation ? .openInBrowser(url) : .block
    }

    private struct LinksOpenExternally: WebPage.NavigationDeciding {
        let openURL: OpenURLAction

        func decidePolicy(
            for action: WebPage.NavigationAction,
            preferences: inout WebPage.NavigationPreferences
        ) async -> WKNavigationActionPolicy {
            switch EmailBodyWebView.navigationPolicy(
                url: action.request.url,
                isLinkActivation: action.navigationType == .linkActivated
            ) {
            case .allow:
                return .allow
            case .openInBrowser(let url):
                openURL(url)
                return .cancel
            case .block:
                return .cancel
            }
        }
    }
}
