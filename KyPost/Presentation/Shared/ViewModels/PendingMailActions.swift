//
//  PendingMailActions.swift
//  KyPost
//
//  List actions held back while the Undo bar shows (Android
//  PendingRowActions.kt). Pure state; InboxViewModel owns the timer and the
//  relay calls.
//

import Foundation

/// One list action waiting out the undo window. The source folder is pinned
/// when the action is taken, so a window that closes after a folder switch
/// still acts on the right mailbox.
nonisolated struct HeldMailAction: Equatable, Sendable {
    var action: MailMoveAction
    var serverIds: [String]
    var folder: String
    var target: String?

    var keys: Set<MailRowKey> {
        Set(serverIds.map { MailRowKey(folder: folder, serverId: $0) })
    }

    var verb: String {
        switch action {
        case .archive: String(localized: "Archive")
        case .delete: String(localized: "Delete")
        case .spam: String(localized: "Junk")
        case .move: String(localized: "Move")
        }
    }
}

/// There is one Undo bar for everything held, so held actions are taken back
/// together and sent together. Each one leaves this holder exactly once —
/// through `takeAll` (sent) or `undoAll` (never sent) — which is what makes
/// "runs exactly once or never" hold: a timer that fires after a flush finds
/// nothing to take.
nonisolated struct PendingMailActions: Equatable, Sendable {
    private(set) var held: [HeldMailAction] = []

    var isEmpty: Bool { held.isEmpty }

    var heldKeys: Set<MailRowKey> {
        held.reduce(into: []) { $0.formUnion($1.keys) }
    }

    mutating func hold(_ action: HeldMailAction) {
        held.append(action)
    }

    /// False when nothing was held, so there was nothing to take back.
    @discardableResult
    mutating func undoAll() -> Bool {
        defer { held.removeAll() }
        return !held.isEmpty
    }

    /// Everything still held, removed in the same step: the caller sends it.
    mutating func takeAll() -> [HeldMailAction] {
        defer { held.removeAll() }
        return held
    }

    /// The Undo bar's text: "Delete: 1 message" for one action, a combined
    /// count once a second action joins the same bar.
    var summary: String? {
        guard let first = held.first else { return nil }
        let rows = held.reduce(0) { $0 + $1.serverIds.count }
        if held.count == 1 {
            return rows == 1
                ? String(localized: "\(first.verb): 1 message")
                : String(localized: "\(first.verb): \(rows) messages")
        }
        return String(localized: "\(rows) messages changed")
    }
}
