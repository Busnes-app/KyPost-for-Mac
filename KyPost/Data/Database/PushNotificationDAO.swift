//
//  PushNotificationDAO.swift
//  KyPost
//
//  Data access for push notification history (spec §8 PushNotificationDAO).
//  De-duplicates by seq (spec §3 pull mode) and by messageId: the same
//  message can arrive over APNs and then again from the pull queue, which the
//  server fills in both delivery modes. Holds at most `historyLimit` rows.
//

import Foundation
import SwiftData

@ModelActor
actor PushNotificationDAO {
    /// Matches Android's history size. History is sender and subject lines at
    /// rest, so it is kept to what the screen shows rather than growing for
    /// the life of the pairing.
    static let historyLimit = 30

    /// How long a row pushed out of the visible history keeps its message id.
    /// The heartbeat re-reads up to this far back, and the id is what stops it
    /// alerting again for mail push already delivered. Such a row keeps only
    /// its id, seq and time — sender, subject and keywords are cleared.
    static let deliveryIdRetention: TimeInterval = PullHeartbeatPolicy.heartbeatWindow

    /// The pairing session writes are accepted for. `invalidateSession` moves
    /// it on unpair, so a pull that started under the old pairing cannot
    /// write into the new one's history.
    private var acceptedSession = 0

    /// Rejects every later insert tagged with an older session.
    func invalidateSession(to session: Int) {
        acceptedSession = max(acceptedSession, session)
    }

    /// Inserts a notification; skips duplicates (same seq, or same non-empty
    /// messageId), then trims to `historyLimit`.
    /// - Parameter session: when given, the insert is refused with
    ///   `CancellationError` unless it is still the accepted session.
    /// - Returns: false if the entry was already there — the caller must not
    ///   alert for it again.
    /// - Throws: `CancellationError` when the calling task was cancelled, as
    ///   well — an insert queued behind other work on this actor when a poll
    ///   is shut down must not land once it finally runs.
    @discardableResult
    func insert(notification: PushNotification, session: Int? = nil, now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        if let session, session != acceptedSession { throw CancellationError() }
        let seq = notification.seq
        var bySeq = FetchDescriptor<PushNotificationEntity>(
            predicate: #Predicate { $0.seq == seq }
        )
        bySeq.fetchLimit = 1
        guard try modelContext.fetch(bySeq).isEmpty else { return false }
        if try contains(messageId: notification.messageId) { return false }
        modelContext.insert(PushNotificationEntity(from: notification))
        try modelContext.save()
        try prune(keeping: Self.historyLimit, now: now)
        return true
    }

    func contains(seq: Int) throws -> Bool {
        var descriptor = FetchDescriptor<PushNotificationEntity>(
            predicate: #Predicate { $0.seq == seq }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    func contains(messageId: String) throws -> Bool {
        guard !messageId.isEmpty else { return false }
        var descriptor = FetchDescriptor<PushNotificationEntity>(
            predicate: #Predicate { $0.messageId == messageId }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    /// Everything past the newest `limit` rows loses its content; those older
    /// than `deliveryIdRetention` are deleted outright. Rows past `limit` are
    /// never listed — at least `limit` newer rows always sit above them.
    func prune(keeping limit: Int, now: Date = Date()) throws {
        var descriptor = FetchDescriptor<PushNotificationEntity>(
            sortBy: [
                SortDescriptor(\.receivedAt, order: .reverse),
                SortDescriptor(\.seq, order: .reverse),
            ]
        )
        descriptor.fetchOffset = limit
        let overflow = try modelContext.fetch(descriptor)
        guard !overflow.isEmpty else { return }
        let keepIdsSince = now.addingTimeInterval(-Self.deliveryIdRetention)
        var changed = false
        for entity in overflow {
            if entity.receivedAt < keepIdsSince {
                modelContext.delete(entity)
                changed = true
            } else if !entity.senderName.isEmpty || !entity.emailSubject.isEmpty || !entity.keywords.isEmpty {
                entity.senderName = ""
                entity.emailSubject = ""
                entity.keywords = []
                entity.read = true
                changed = true
            }
        }
        if changed { try modelContext.save() }
    }

    /// Unpair: history belongs to the account the pairing was for.
    func deleteAll() throws {
        try modelContext.delete(model: PushNotificationEntity.self)
        try modelContext.save()
    }

    /// Newest-first notification history. Sorted by receivedAt (seq as
    /// tiebreaker) because push-mode entries use synthesized seqs that don't
    /// share a scale with pull-mode server seqs.
    func listHistory(limit: Int) throws -> [PushNotification] {
        var descriptor = FetchDescriptor<PushNotificationEntity>(
            sortBy: [
                SortDescriptor(\.receivedAt, order: .reverse),
                SortDescriptor(\.seq, order: .reverse),
            ]
        )
        // Never past the visible cap: rows below it are delivery ids only.
        descriptor.fetchLimit = min(limit, Self.historyLimit)
        return try modelContext.fetch(descriptor).map(\.toDomain)
    }

    func markRead(seq: Int) throws {
        var descriptor = FetchDescriptor<PushNotificationEntity>(
            predicate: #Predicate { $0.seq == seq }
        )
        descriptor.fetchLimit = 1
        guard let entity = try modelContext.fetch(descriptor).first else { return }
        entity.read = true
        try modelContext.save()
    }
}
