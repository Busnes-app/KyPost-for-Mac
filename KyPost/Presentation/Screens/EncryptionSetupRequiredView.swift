//
//  EncryptionSetupRequiredView.swift
//  KyPost
//
//  Shown over the shell while the relay holds this account for first
//  sign-in encryption setup (`InboxViewModel.encryptionSetupMessage`). Not a
//  sign-out and not a connection error: setup happens on the web.
//

import SwiftUI

struct EncryptionSetupRequiredView: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    let message: String
    let setupURL: URL?
    let checkAgain: () async -> Void

    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)
            Text("Finish encryption setup")
                .font(AppFont.ui(20, weight: .semibold))
                .foregroundStyle(theme.inkStrong)
            Text(message)
                .font(AppFont.ui(14))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
            if let setupURL {
                Button("Open KyPost on the web") { openURL(setupURL) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            Button {
                Task {
                    isChecking = true
                    await checkAgain()
                    isChecking = false
                }
            } label: {
                if isChecking { ProgressView().controlSize(.small) } else { Text("Check again") }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isChecking)
        }
        .frame(maxWidth: 420)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }
}
