//
//  KyIdentitySignOnView.swift
//  KyPost
//
//  "Sign in with KyIdentity" (iOS), pushed from the pairing screen. The flow
//  itself lives in `KyIdentitySignOnCoordinator`, which outlives this view:
//  the app lock tears it down while KyAuth is in front.
//

#if os(iOS)
import SwiftUI

struct KyIdentitySignOnView: View {
    @Environment(\.theme) private var theme
    @Environment(KyIdentitySignOnCoordinator.self) private var coordinator

    @State private var serverUrl = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(theme.accent)
                Text("Enter your KyPost server address. KyAuth will ask you to approve the sign-in with Face ID or your passcode.")
                    .font(AppFont.ui(14))
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.center)

                TextField("https://mail.example.com", text: $serverUrl)
                    .font(AppFont.mono(13))
                    .textFieldStyle(.plain)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(start)
                    .disabled(coordinator.isWorking)
                    .padding(12)
                    .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
                    .overlay(
                        RoundedRectangle(cornerRadius: Shape.field)
                            .strokeBorder(theme.line, lineWidth: 1)
                    )

                switch coordinator.phase {
                case .idle:
                    Button("Continue with KyAuth", action: start)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                case .readingConfig:
                    ProgressView("Reading the server's sign-in settings…")
                case .waitingForKyAuth:
                    ProgressView("Waiting for KyAuth…")
                    Button("Cancel") { coordinator.cancel() }
                        .buttonStyle(SecondaryButtonStyle())
                case .exchanging:
                    ProgressView("Signing in…")
                }

                if let status = coordinator.status {
                    Text(status)
                        .font(AppFont.ui(13))
                        .foregroundStyle(SemanticColors.warning)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .navigationTitle("Sign in with KyIdentity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func start() {
        guard !serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        coordinator.start(serverUrl: serverUrl)
    }
}
#endif
