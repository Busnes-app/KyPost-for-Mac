//
//  NotificationHistoryView.swift
//  KyPost
//
//  Latest-notification summary plus the last 30 entries. `content` is a set
//  of Form sections so the macOS Notifications tab can embed it in its own
//  Form; iOS pushes `NotificationHistoryView` from Settings.
//
//  Locked means nothing: the scene's LockedOverlay is the usual cover, but on
//  macOS a sheet can render above it, and history is sender and subject
//  lines — the same thing `presentLocally` withholds from a locked banner.
//  An abandoned wipe means nothing either, and the history is not even loaded
//  (`NotificationHistoryAccess`).
//

import SwiftUI

struct NotificationHistorySections: View {
    @Environment(\.theme) private var theme
    @Environment(NavigationRouter.self) private var router

    let viewModel: NotificationHistoryViewModel

    private var access: NotificationHistoryAccess {
        NotificationHistoryAccess.decide(
            isLocked: SingletonGraph.shared.appLockManager.isLocked,
            blockedByAbandonedWipe: SingletonGraph.shared.securityWipe.blockedByAbandonedWipe
        )
    }
    private var memoryOnly: Bool { SingletonGraph.shared.hostileLocationProtectionStore.enabled }

    var body: some View {
        switch access {
        case .visible:
            latestSection
            historySection
        case .locked:
            Section {
                Text("Unlock KyPost to see notification history.")
                    .foregroundStyle(.secondary)
            }
        case .blockedByAbandonedWipe:
            // This scene (macOS Settings) sits outside the main window's
            // recovery screen, so it must refuse on its own.
            Section {
                Text("KyPost could not finish erasing this device. Notification history is unavailable until it is erased.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var latestSection: some View {
        Section {
            if let latest = viewModel.latest {
                LabeledContent("From", value: displaySender(latest))
                LabeledContent("Subject", value: displaySubject(latest))
                if !latest.keywords.isEmpty {
                    LabeledContent("Keywords", value: latest.keywords.joined(separator: ", "))
                }
                LabeledContent(
                    "Received",
                    value: latest.receivedAt.formatted(date: .abbreviated, time: .shortened)
                )
            } else {
                Text("No notifications yet.")
                    .foregroundStyle(.secondary)
            }
            if let checked = viewModel.lastCheckedAt {
                LabeledContent(
                    "Last checked",
                    value: checked.formatted(date: .abbreviated, time: .shortened)
                )
            }
        } header: {
            Text("Latest Notification")
        }
    }

    private var historySection: some View {
        Section {
            if viewModel.loadFailed {
                Text("Notification history could not be loaded.")
                    .foregroundStyle(.secondary)
            } else if viewModel.entries.isEmpty {
                Text("Notifications you receive appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.entries) { entry in
                    row(entry)
                }
            }
        } header: {
            Text("History")
        } footer: {
            if memoryOnly {
                Text("Hostile Location Protection is on: history is kept in memory and cleared when KyPost quits.")
            } else {
                Text("The last \(PushNotificationDAO.historyLimit) notifications on this device.")
            }
        }
    }

    private func row(_ entry: PushNotification) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(entry.read ? Color.clear : theme.accent)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(displaySender(entry))
                    .font(AppFont.ui(14, weight: entry.read ? .regular : .semibold))
                    .lineLimit(1)
                Text(displaySubject(entry))
                    .font(AppFont.ui(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(entry.receivedAt.formatted(date: .abbreviated, time: .shortened))
                .font(AppFont.ui(12))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                await viewModel.markRead(entry)
                if let messageId = NotificationHistoryViewModel.openableMessageId(entry) {
                    router.handle(.openEmail(messageId: messageId))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(entry.read ? Text("Read") : Text("Unread"))
    }

    private func displaySender(_ entry: PushNotification) -> String {
        entry.senderName.isEmpty ? String(localized: "New Email") : entry.senderName
    }

    private func displaySubject(_ entry: PushNotification) -> String {
        entry.emailSubject.isEmpty ? String(localized: "(no subject)") : entry.emailSubject
    }
}

/// iOS: Settings → Notifications → Notification History.
struct NotificationHistoryView: View {
    @Environment(\.theme) private var theme

    @State private var viewModel = NotificationHistoryViewModel(
        repository: SingletonGraph.shared.pushRepository,
        pushSettingsStore: SingletonGraph.shared.pushSettingsStore
    )

    var body: some View {
        Form {
            NotificationHistorySections(viewModel: viewModel)
                .listRowBackground(theme.panel)
        }
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Notification History")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }
}
