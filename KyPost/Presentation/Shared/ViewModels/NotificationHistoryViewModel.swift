//
//  NotificationHistoryViewModel.swift
//  KyPost
//
//  The last `PushNotificationDAO.historyLimit` notifications and a summary of
//  the newest, for Settings → Notifications (iOS) and the Notifications
//  preferences tab (macOS). Mirrors Android's pairing-screen history.
//

import Foundation
import os

/// What the history surface may show. Decided in one place so the view and
/// the loader cannot disagree.
enum NotificationHistoryAccess: Equatable {
    case visible
    case locked
    /// A security wipe gave up with data still on disk; history is part of
    /// what it failed to delete, and is never shown or loaded.
    case blockedByAbandonedWipe

    static func decide(isLocked: Bool, blockedByAbandonedWipe: Bool) -> Self {
        if blockedByAbandonedWipe { return .blockedByAbandonedWipe }
        return isLocked ? .locked : .visible
    }
}

@Observable
@MainActor
final class NotificationHistoryViewModel {
    private(set) var entries: [PushNotification] = []
    private(set) var loadFailed = false
    private(set) var lastCheckedAt: Date?

    private let repository: PushRepository
    private let pushSettingsStore: PushSettingsStore
    private let isBlockedByAbandonedWipe: @MainActor () -> Bool

    /// `isBlockedByAbandonedWipe` defaults to re-reading the live graph's
    /// `securityWipe` at each load.
    init(
        repository: PushRepository,
        pushSettingsStore: PushSettingsStore,
        isBlockedByAbandonedWipe: (@MainActor () -> Bool)? = nil
    ) {
        self.repository = repository
        self.pushSettingsStore = pushSettingsStore
        self.isBlockedByAbandonedWipe = isBlockedByAbandonedWipe ?? {
            SingletonGraph.shared.securityWipe.blockedByAbandonedWipe
        }
    }

    var latest: PushNotification? { entries.first }

    func load() async {
        guard !isBlockedByAbandonedWipe() else {
            entries = []
            lastCheckedAt = nil
            return
        }
        lastCheckedAt = pushSettingsStore.lastPulledAt
        do {
            try await repository.pruneHistory()
            entries = try await repository.history()
            loadFailed = false
        } catch {
            Log.push.error("Could not load notification history: \(error)")
            loadFailed = true
        }
    }

    func markRead(_ entry: PushNotification) async {
        guard !entry.read else { return }
        do {
            try await repository.markRead(seq: entry.seq)
            if let index = entries.firstIndex(where: { $0.seq == entry.seq }) {
                entries[index].read = true
            }
        } catch {
            Log.push.error("Could not mark notification read: \(error)")
        }
    }

    /// The message id worth routing a tap to, or nil for an id this client
    /// synthesized (`pull-<seq>`), which names no message on the server.
    static func openableMessageId(_ entry: PushNotification) -> String? {
        let id = entry.messageId
        return id.isEmpty || id.hasPrefix("pull-") ? nil : id
    }
}
