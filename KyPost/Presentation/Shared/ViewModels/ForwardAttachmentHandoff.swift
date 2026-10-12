//
//  ForwardAttachmentHandoff.swift
//  KyPost
//
//  Carries a forwarded message's attachments from the reader to the compose
//  window it opens. Port of kypost-android's ForwardAttachmentHandoff.
//
//  Not part of `ComposeDraft`: that is a `WindowGroup` scene value, so state
//  restoration archives it to disk, and 12 MiB of someone else's files has no
//  business in a restoration archive. Held in memory, keyed by the draft id,
//  claimed once by the compose window that draft opens, and dropped at every
//  session boundary.
//

import Foundation

@MainActor
final class ForwardAttachmentHandoff {
    static let shared = ForwardAttachmentHandoff()

    /// Attachment bytes retained for one forward (Android
    /// `MemoryBudget.FORWARD_ATTACHMENT_BYTES`).
    nonisolated static let byteBudget = 12 * 1024 * 1024

    struct Pending {
        var draftID: UUID
        var attachments: [OutgoingAttachment]
        /// What did not come along, said in compose rather than lost.
        var notice: String?
    }

    /// One slot: a second forward replaces the first, so an abandoned handoff
    /// costs at most one forward's worth of memory.
    private var pending: Pending?
    private var observations: [NotificationObservation] = []

    init(center: NotificationCenter = .default) {
        // A wipe, a failed-unlock reset, an unpair, or a Hostile Location
        // Protection switch (which closes compose windows) ends the session
        // these bytes belong to.
        observations = [.kyPostSessionReset, .kyPostCloseComposeWindows].map { name in
            NotificationObservation(center: center, name: name) { [weak self] in self?.clear() }
        }
    }

    func put(_ attachments: [OutgoingAttachment], notice: String?, for draftID: UUID) {
        pending = attachments.isEmpty && notice == nil
            ? nil
            : Pending(draftID: draftID, attachments: attachments, notice: notice)
    }

    /// Claims the handoff for `draftID`, once. A restored window carrying the
    /// same draft id later gets nothing — the bytes were never archived.
    func take(for draftID: UUID) -> Pending? {
        guard let current = pending, current.draftID == draftID else { return nil }
        pending = nil
        return current
    }

    func clear() {
        pending = nil
    }

    var isHoldingAttachments: Bool { pending != nil }
}

/// Fetches a message's attachments for forwarding, within `budget`.
///
/// Refuses rather than evicts: dropping an earlier attachment to make room
/// would forward a message that silently lost one. The sender's order is
/// kept. A listed size already past the budget is not downloaded at all.
nonisolated func collectForwardAttachments(
    _ listing: [EmailAttachment],
    budget: Int = ForwardAttachmentHandoff.byteBudget,
    fetch: (EmailAttachment) async -> Data?
) async -> (attachments: [OutgoingAttachment], failed: Int, tooLarge: Int) {
    var kept: [OutgoingAttachment] = []
    var held = 0
    var failed = 0
    var tooLarge = 0
    for item in listing.sorted(by: { $0.index < $1.index }) {
        guard held + max(item.size, 0) <= budget else {
            tooLarge += 1
            continue
        }
        guard let data = await fetch(item) else {
            failed += 1
            continue
        }
        guard held + data.count <= budget else {
            tooLarge += 1
            continue
        }
        held += data.count
        kept.append(OutgoingAttachment(name: item.name, mimeType: item.mimeType, data: data))
    }
    return (kept, failed, tooLarge)
}

/// The compose notice for what a forward left behind, or nil when nothing was.
nonisolated func forwardAttachmentNotice(failed: Int, tooLarge: Int) -> String? {
    var parts: [String] = []
    if failed > 0 {
        parts.append(failed == 1
            ? "1 attachment couldn't be downloaded and isn't included."
            : "\(failed) attachments couldn't be downloaded and aren't included.")
    }
    if tooLarge > 0 {
        parts.append(tooLarge == 1
            ? "1 attachment is too large to forward from here and isn't included."
            : "\(tooLarge) attachments are too large to forward from here and aren't included.")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}
