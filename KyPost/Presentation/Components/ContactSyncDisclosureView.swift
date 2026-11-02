//
//  ContactSyncDisclosureView.swift
//  KyPost
//
//  The contact-sync disclosure as a sheet: the text of
//  `ContactSyncDisclosure`, then Agree and Not now. Dismissing the sheet any
//  other way is Not now.
//

import SwiftUI

struct ContactSyncDisclosureView: View {
    @Environment(\.theme) private var theme

    let disclosure: ContactSyncDisclosure
    let onAgree: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(ContactSyncDisclosure.title)
                        .font(AppFont.ui(22, weight: .semibold))
                        .foregroundStyle(theme.inkStrong)
                        .accessibilityAddTraits(.isHeader)
                    Text(disclosure.lead)
                        .font(AppFont.ui(15))
                        .foregroundStyle(theme.ink)
                    ForEach(disclosure.parts, id: \.self) { part in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(part.title)
                                .font(AppFont.ui(13, weight: .semibold))
                                .foregroundStyle(theme.inkStrong)
                                .accessibilityAddTraits(.isHeader)
                            Text(part.body)
                                .font(AppFont.ui(15))
                                .foregroundStyle(theme.ink)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 10) {
                Button("Agree", action: onAgree)
                    .buttonStyle(PrimaryButtonStyle())
                Button("Not now", action: onDecline)
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(20)
            .background(theme.panel)
        }
        .background(theme.bg)
        #if os(macOS)
        .frame(width: 480, height: 620)
        #endif
    }
}

extension View {
    /// Settings' disclosure sheet and turn-off confirmation, for the "Sync
    /// with Apple Contacts" toggle (iOS Settings, macOS Contacts pane).
    func contactSyncPrompts(_ viewModel: SettingsViewModel) -> some View {
        modifier(ContactSyncPrompts(viewModel: viewModel))
    }
}

private struct ContactSyncPrompts: ViewModifier {
    @Environment(\.theme) private var theme
    @Bindable var viewModel: SettingsViewModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $viewModel.contactSyncDisclosure) { disclosure in
                ContactSyncDisclosureView(
                    disclosure: disclosure,
                    onAgree: { Task { await viewModel.agreeToContactSync() } },
                    onDecline: { viewModel.declineContactSync() }
                )
                .environment(\.theme, theme)
            }
            .confirmationDialog(
                "Stop sending contacts?",
                isPresented: $viewModel.confirmingStopContactSync,
                titleVisibility: .visible
            ) {
                Button("Turn Off", role: .destructive) { viewModel.stopContactSync() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(viewModel.stopContactSyncMessage)
            }
    }
}
