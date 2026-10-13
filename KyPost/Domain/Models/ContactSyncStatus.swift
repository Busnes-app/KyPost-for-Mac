//
//  ContactSyncStatus.swift
//  KyPost
//
//  What the contacts list says about changes that have not reached the
//  server. Swift port of kypost-android's contacts/ContactSyncStatus.kt,
//  adapted to this client's outbox: contacts flagged `needsSync` plus the
//  delete tombstones in `ContactPendingDeletesStore`.
//

import Foundation
import Observation

/// Consecutive failed syncs and the newest failure's text.
nonisolated struct ContactSyncFailures: Equatable, Sendable {
    var count = 0
    var lastReason: String?
}

/// Changes still to reach the server.
nonisolated struct ContactPendingSummary: Equatable, Sendable {
    var count = 0
    /// When the oldest of them was queued; nil when unknown or none.
    var oldestQueuedAt: Date?
}

nonisolated enum ContactSyncStatus: Equatable, Sendable {
    case idle
    case waiting(pending: Int)
    /// `reason` is the first line of the newest failure this process saw, nil
    /// when the outbox is simply old.
    case stuck(pending: Int, reason: String?)

    static let stuckAfterFailures = 3
    static let stuckOutboxAge: TimeInterval = 60 * 60
    static let maxReasonLength = 200

    /// Stuck when a queued change is over an hour old or three syncs in a row
    /// failed; otherwise waiting while anything is queued.
    static func of(
        pending: ContactPendingSummary,
        failures: ContactSyncFailures,
        now: Date
    ) -> ContactSyncStatus {
        let stuckInOutbox = pending.count > 0
            && (pending.oldestQueuedAt.map { now.timeIntervalSince($0) > stuckOutboxAge } ?? false)
        if stuckInOutbox || failures.count >= stuckAfterFailures {
            return .stuck(pending: pending.count, reason: failures.lastReason)
        }
        return pending.count > 0 ? .waiting(pending: pending.count) : .idle
    }

    /// Error text can come from the server: first non-empty line only,
    /// trimmed, at most `maxReasonLength` characters.
    static func reasonLine(_ text: String) -> String? {
        let line = text
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line.map { String($0.prefix(maxReasonLength)) }
    }
}

/// Consecutive sync failures, **in memory only**: a relaunch forgets them, and
/// the outbox age still catches a change that never leaves. Also the last
/// counted outbox, which the repository refreshes after every write and sync.
/// Observable so the contacts list follows syncs started anywhere (the change
/// monitor, the foreground trigger), not only its own button.
@Observable
@MainActor
final class ContactSyncHealth {
    private(set) var failures = ContactSyncFailures()
    private(set) var pending = ContactPendingSummary()

    func recordPending(_ summary: ContactPendingSummary) {
        pending = summary
    }

    func recordSuccess() {
        failures = ContactSyncFailures()
    }

    func recordFailure(reason: String) {
        failures = ContactSyncFailures(
            count: failures.count + 1,
            lastReason: ContactSyncStatus.reasonLine(reason)
        )
    }
}
