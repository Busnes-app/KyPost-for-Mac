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

    /// Inserts a notification; skips duplicates (same seq, or same non-empty
    /// messageId), then trims to `historyLimit`.
    /// - Returns: false if the entry was already there — the caller must not
    ///   alert for it again.
    @discardableResult
    func insert(notification: PushNotification) throws -> Bool {
        let seq = notification.seq
        var bySeq = FetchDescriptor<PushNotificationEntity>(
            predicate: #Predicate { $0.seq == seq }
        )
        bySeq.fetchLimit = 1
        guard try modelContext.fetch(bySeq).isEmpty else { return false }
        if try contains(messageId: notification.messageId) { return false }
        modelContext.insert(PushNotificationEntity(from: notification))
        try modelContext.save()
        try prune(keeping: Self.historyLimit)
        return true
    }

    func contains(messageId: String) throws -> Bool {
        guard !messageId.isEmpty else { return false }
        var descriptor = FetchDescriptor<PushNotificationEntity>(
            predicate: #Predicate { $0.messageId == messageId }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    /// Deletes everything past the newest `limit` rows.
    func prune(keeping limit: Int) throws {
        var descriptor = FetchDescriptor<PushNotificationEntity>(
            sortBy: [
                SortDescriptor(\.receivedAt, order: .reverse),
                SortDescriptor(\.seq, order: .reverse),
            ]
        )
        descriptor.fetchOffset = limit
        let stale = try modelContext.fetch(descriptor)
        guard !stale.isEmpty else { return }
        stale.forEach(modelContext.delete)
        try modelContext.save()
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
        descriptor.fetchLimit = limit
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
