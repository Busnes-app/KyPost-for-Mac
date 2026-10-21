//
//  SendEmailUseCase.swift
//  KyPost
//
//  Validates and sends an outgoing email (spec §7). On failure the compose UI
//  shows a toast and keeps the draft in memory (no DB auto-save).
//

import Foundation

struct SendEmailUseCase {
    /// Total decoded attachment budget per message — mirrors the backend's
    /// maxMailAttachmentBytes so oversized sends fail before the network.
    static let maxAttachmentBytes = 25 << 20

    private let repository: MailRepository

    init(repository: MailRepository) {
        self.repository = repository
    }

    func callAsFunction(_ email: OutgoingEmail) async -> MailOutcome {
        let recipients = (email.to + email.cc + email.bcc)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !recipients.isEmpty else {
            return .invalid("Add at least one recipient")
        }
        guard recipients.allSatisfy(Self.looksLikeEmailAddress) else {
            return .invalid("Check the recipient addresses")
        }
        let attachmentBytes = email.attachments.reduce(0) { $0 + $1.data.count }
        guard attachmentBytes <= Self.maxAttachmentBytes else {
            return .invalid("Attachments too large (max 25 MB total)")
        }
        return await repository.send(email)
    }

    /// Webmail's Drafts view on the paired server, or nil when there is no
    /// usable pairing URL — compose then explains instead of linking.
    var webmailDraftsURL: URL? {
        repository.pairedServerUrl.flatMap {
            webmailMailboxURL(serverUrl: $0, mailbox: StandardFolder.drafts)
        }
    }

    /// Minimal shape check (one @, non-empty local part, dot in domain) —
    /// real validation is the mail server's job.
    static func looksLikeEmailAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasSuffix(".")
    }
}
