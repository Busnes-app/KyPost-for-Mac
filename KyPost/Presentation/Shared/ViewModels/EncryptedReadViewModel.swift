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
    /// The address the signature verdict is about, as the **server** resolved
    /// it. Rendered instead of the raw `From`, which is separable from it.
    private(set) var resolvedSender = ""
    private(set) var signature: PgpSignatureState = .none

    /// Quick Look files staged from `body.attachments`, deleted by `forget()`.
    private var stagedFiles: [URL] = []
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
    /// verdicts need the server's resolved sender and are rendered against it;
    /// the two message-level notices (`unsigned`, `unchecked`) are shown on
    /// their own, resolved sender or not.
    var signatureLine: String? {
        guard body != nil, let label = signatureLabel(signature) else { return nil }
        if signatureIsMessageLevel(signature) { return label }
        guard !resolvedSender.isEmpty else { return nil }
        return "\(label) — \(resolvedSender)"
    }

    /// Said out loud when a part was dropped for size or count.
    var attachmentsOmittedMessage: String? {
        body?.attachmentsOmitted == true
            ? "Some attachments in this message could not be shown on this device. Open it in webmail to get them."
            : nil
    }

    /// See `readerOffersWebmail`.
    func offersWebmail(deviceIsEnrolled: Bool) -> Bool {
        readerOffersWebmail(
            outcome: outcome,
            deviceIsEnrolled: deviceIsEnrolled,
            attachmentsOmitted: body?.attachmentsOmitted == true
        )
    }

    /// The decrypted HTML with `cid:` images resolved to bounded `data:` URIs
    /// from the message's own parts, or nil for a plain-text message.
    var renderedHTML: String? {
        guard let html = body?.html, !html.isEmpty else { return nil }
        return InlineImages.inlineCidImages(html: html, attachments: body?.attachments ?? [])
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

        let result = await reader.read(
            mailbox: mailbox,
            messageId: messageId,
            sender: sender,
            unlockIfNeeded: unlockIfNeeded
        )
        outcome = result

        if case .decrypted(let body, let signature, let resolvedSender) = result {
            self.body = body
            self.signature = signature
            self.resolvedSender = resolvedSender
        }
    }

    /// Drops the plaintext. Called when the view goes away, so a decrypted
    /// message does not survive navigating back to the list.
    func forget() {
        for url in stagedFiles { files.remove(url) }
        stagedFiles = []
        body = nil
        signature = .none
        resolvedSender = ""
        outcome = nil
    }
}
