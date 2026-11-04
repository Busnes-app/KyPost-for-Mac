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
    @State private var confirmingRemoveKept = false

    var body: some View {
        VStack(spacing: 0) {
            if let kept = viewModel.keptFromAnotherAccount {
                keptContactsQuestion(kept)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content(viewModel.syncStatus(now: context.date))
            }
            let withheld = viewModel.withheldCardDeletes
            if withheld > 0 {
                banner(icon: "person.crop.circle.badge.exclamationmark", tint: theme.warning) {
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
            banner(icon: "exclamationmark.triangle.fill", tint: theme.warning) {
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

    /// Owner Q1: contacts kept from the previous account go to a different
    /// account only if the user says so; nothing is sent until then.
    private func keptContactsQuestion(_ kept: Int) -> some View {
        banner(icon: "person.2.badge.gearshape", tint: theme.accent) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bring your ^[\(kept) contact](inflect: true) into \(viewModel.pairedServerName)?")
                    .font(AppFont.ui(13, weight: .semibold))
                    .foregroundStyle(theme.inkStrong)
                Text("They are from the account this device was paired to before. Nothing is uploaded until you choose.")
                    .font(AppFont.ui(12))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Bring Them") {
                        Task { await viewModel.bringKeptContacts() }
                    }
                    Button("Remove Them", role: .destructive) { confirmingRemoveKept = true }
                }
                .disabled(viewModel.isSyncing)
            }
        }
        .confirmationDialog(
            "Remove ^[\(kept) contact](inflect: true) from this device?",
            isPresented: $confirmingRemoveKept,
            titleVisibility: .visible
        ) {
            Button("Remove Contacts", role: .destructive) {
                Task { await viewModel.removeKeptContacts() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.keptUnsynced > 0
                ? "^[\(viewModel.keptUnsynced) change](inflect: true) never reached your previous account and will be lost. The cards KyPost added to Contacts are removed too."
                : "The cards KyPost added to Contacts are removed too. They stay on your previous account's server.")
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

/// Remove Pairing's note on contacts (owner Q1): kept unless the user picks
/// "Unpair and Remove Contacts", with a warning when that would lose changes.
enum UnpairContactsNote {
    static func text(unsynced: Int) -> String {
        let kept = String(localized: "Your contacts stay on this device unless you choose Unpair and Remove Contacts, which also deletes the cards KyPost added to Contacts.")
        guard unsynced > 0 else { return kept }
        return kept + " " + String(localized: "\(unsynced) contact changes haven't synced yet and would be lost.")
    }
}
