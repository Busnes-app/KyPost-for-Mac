//
//  EncryptedReadViewModel.swift
//  KyPost
//
//  Drives the Decrypt affordance on a client-protected message.
//
//  **The decrypted body lives here and nowhere else.** It is not written to
//  SwiftData, not assigned to the cached body field, and not carried into a
//  scene value that state restoration would archive. When this object goes, so
//  does the plaintext.
//
//  Its decrypted attachments follow the same rule. The one exception is the
//  Quick Look file a preview needs, which this object stages, tracks, and
//  deletes when the preview closes and in `forget()`.
//

import Foundation
import Observation

@Observable
@MainActor
final class EncryptedReadViewModel {
    /// The last outcome, or nil before anything has been attempted.
    private(set) var outcome: ReadOutcome?
    private(set) var isWorking = false

    /// The decrypted content, held only while this view model is alive.
    private(set) var body: DecryptedBody?
    /// The decrypted HTML with `cid:` images resolved to bounded `data:` URIs
    /// from the message's own parts, or nil for a plain-text message. Built
    /// once per read, off the main actor, before `body` is published: the
    /// screen reads it on every redraw.
    private(set) var renderedHTML: String?
    /// The verdict and what it may be shown with. The server's resolved
    /// sender is shown as an identity only beside a key this device pinned;
    /// otherwise the line says what the signing key itself names.
    private(set) var verdict = SignatureVerdict()
    var signature: PgpSignatureState { verdict.state }
    var resolvedSender: String { verdict.resolvedSender }

    /// Quick Look files staged from `body.attachments`, deleted by `forget()`.
    private var stagedFiles: [URL] = []
    /// Advanced by `forget()`. A read that started under an earlier value
    /// finished after the plaintext was meant to be gone, and is discarded.
    private var generation = 0
    private let files: DecryptedAttachmentFiles

    private let reader: EncryptedMessageReader?
    private let mailbox: String
    private let messageId: String
    private let sender: String

    init(
        reader: EncryptedMessageReader?,
        mailbox: String,
        messageId: String,
        sender: String,
        files: DecryptedAttachmentFiles = DecryptedAttachmentFiles()
    ) {
        self.files = files
        self.reader = reader
        self.mailbox = mailbox
        self.messageId = messageId
        self.sender = sender
    }

    /// Whether there is anything to offer at all. False when the device is not
    /// paired, so there is no authenticated payload source.
    var isAvailable: Bool { reader != nil }

    /// True while the screen should show the Decrypt button.
    var showsDecryptButton: Bool {
        guard isAvailable, !isWorking else { return false }
        switch outcome {
        case .decrypted:
            return false
        // `needsUnlock` and `cancelled` both mean "ask me again when you mean
        // it" — the button comes back rather than an error taking its place.
        case .none, .needsUnlock, .cancelled:
            return true
        default:
            return false
        }
    }

    var showsRetryButton: Bool {
        guard let outcome, !isWorking else { return false }
        return readOutcomeAllowsRetry(outcome)
    }

    /// The signature line, or nil when there is nothing to say. Sender
    /// verdicts need a resolved sender (pins and history are looked up by it)
    /// and are shown with `signatureIdentity` — the pinned address, or what
    /// the signing key names — never the resolved sender as an unearned
    /// identity. The two message-level notices are shown on their own.
    var signatureLine: String? {
        guard body != nil, let label = signatureLabel(signature) else { return nil }
        if signatureIsMessageLevel(signature) { return label }
        guard !resolvedSender.isEmpty else { return nil }
        guard let identity = signatureIdentity(verdict) else { return label }
        return "\(label) — \(identity)"
    }

    /// Said when the address this message shows is not one the signature is
    /// bound to. A warning only; it never changes the verdict.
    var signatureIdentityWarning: String? {
        guard body != nil, !resolvedSender.isEmpty else { return nil }
        return signatureIdentityMismatch(verdict, displayedFrom: sender)
    }

    /// Said out loud when a part was dropped for size or count.
    var attachmentsOmittedMessage: String? {
        body?.attachmentsOmitted == true
            ? "Some attachments in this message could not be shown on this device."
            : nil
    }

    /// Writes one decrypted attachment for Quick Look. Tracked so `forget()`
    /// deletes it even when the preview is never closed normally.
    func stageForPreview(_ attachment: DecryptedAttachment) -> URL? {
        guard body?.attachments.contains(where: { $0.id == attachment.id }) == true,
              let url = try? files.stage(attachment)
        else { return nil }
        stagedFiles.append(url)
        return url
    }

    /// Deletes one staged preview file, once its preview has closed.
    func discardPreview(_ url: URL) {
        guard let index = stagedFiles.firstIndex(of: url) else { return }
        stagedFiles.remove(at: index)
        files.remove(url)
    }

    /// The sentence for the current outcome, or nil when there is nothing to
    /// say — before the first attempt, or once it worked.
    var statusMessage: String? {
        switch outcome {
        case nil, .decrypted, .needsUnlock:
            nil
        // Deliberately silent: the user dismissed their own prompt, and
        // reporting it back to them as a failure would be the app arguing.
        case .cancelled:
            nil
        case .notEnrolled:
            "This device isn't set up to read encrypted mail. Enroll it in Settings."
        case .noSecureLockScreen:
            "This device has no passcode or biometric lock, so it can't hold your key."
        case .tooLarge:
            "This message is too large to decrypt on this device."
        case .notClientProtected:
            "This message isn't end-to-end encrypted after all — try reopening it."
        case .noEncryptedContent:
            "This message carries no encrypted content. Nothing here can be decrypted."
        case .unsealFailed(let message):
            "Couldn't unlock this device's key: \(message)"
        case .fetchFailed(let message):
            "Couldn't fetch this message: \(message)"
        case .decryptFailed(let message):
            "Couldn't decrypt this message: \(message)"
        }
    }

    /// Decrypts immediately when the key is already held. A sealed key returns
    /// `needsUnlock`, which makes the explicit Decrypt action appear.
    func attemptWithoutPrompting() async {
        await run(unlockIfNeeded: false)
    }

    /// Run from the Decrypt action, which may raise the unlock prompt.
    func decrypt() async {
        await run(unlockIfNeeded: true)
    }

    private func run(unlockIfNeeded: Bool) async {
        guard let reader, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let started = generation

        let result = await reader.read(
            mailbox: mailbox,
            messageId: messageId,
            sender: sender,
            unlockIfNeeded: unlockIfNeeded
        )
        // `forget()` ran meanwhile (the lock engaged, or the screen went):
        // keep nothing, and leave Decrypt on offer.
        guard generation == started else { return }

        if case .decrypted(let body, let verdict) = result {
            // Rendered before anything is published, so the screen never
            // shows a decrypted outcome without its body. `isWorking` stays
            // set meanwhile.
            let html = await Self.render(body)
            guard generation == started else { return }
            self.body = body
            self.renderedHTML = html
            self.verdict = verdict
        }
        outcome = result
    }

    /// `renderedHTML` for `body`. `@concurrent` so it runs off the main
    /// actor: a long body takes real time to scan.
    @concurrent
    private nonisolated static func render(_ body: DecryptedBody) async -> String? {
        guard let html = body.html, !html.isEmpty else { return nil }
        return InlineImages.inlineCidImages(html: html, attachments: body.attachments)
    }

    /// Drops the plaintext. Called when the view goes away, so a decrypted
    /// message does not survive navigating back to the list.
    func forget() {
        generation &+= 1
        for url in stagedFiles { files.remove(url) }
        stagedFiles = []
        body = nil
        renderedHTML = nil
        verdict = SignatureVerdict()
        outcome = nil
    }
}
