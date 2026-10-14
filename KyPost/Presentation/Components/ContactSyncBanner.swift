//
//  ContactSyncBanner.swift
//  KyPost
//
//  "N changes waiting to sync", or "Sync stuck" with the newest failure and a
//  Retry button (Android #182). Renders nothing when idle. Re-evaluated every
//  minute, because a queued change becomes stuck by age alone.
//

import SwiftUI

struct ContactSyncBanner: View {
    @Environment(\.theme) private var theme

    let viewModel: ContactsViewModel

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content(viewModel.syncStatus(now: context.date))
            }
            let withheld = viewModel.withheldCardDeletes
            if withheld > 0 {
                banner(icon: "person.crop.circle.badge.exclamationmark", tint: SemanticColors.warning) {
                    Text("""
                    Kept ^[\(withheld) card](inflect: true) in Contacts: removing them would delete more \
                    than half of the cards KyPost manages at once. If you meant to, delete them in Contacts.
                    """)
                    .font(AppFont.ui(12))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ status: ContactSyncStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .waiting(let pending):
            banner(icon: "arrow.triangle.2.circlepath", tint: theme.accent) {
                Text("^[\(pending) change](inflect: true) waiting to sync")
                    .font(AppFont.ui(13, weight: .medium))
                    .foregroundStyle(theme.inkStrong)
            }
        case .stuck(let pending, let reason):
            banner(icon: "exclamationmark.triangle.fill", tint: SemanticColors.warning) {
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if pending > 0 {
                            Text("Sync stuck — ^[\(pending) change](inflect: true) waiting")
                        } else {
                            Text("Sync stuck")
                        }
                    }
                    .font(AppFont.ui(13, weight: .semibold))
                    .foregroundStyle(theme.inkStrong)
                    Text(reason ?? String(localized: "Not sent for over an hour."))
                        .font(AppFont.ui(12))
                        .foregroundStyle(theme.ink)
                        .lineLimit(3)
                }
                Spacer(minLength: 8)
                Button("Retry") {
                    Task { await viewModel.sync() }
                }
                .disabled(viewModel.isSyncing)
            }
        }
    }

    private func banner<Content: View>(
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}
