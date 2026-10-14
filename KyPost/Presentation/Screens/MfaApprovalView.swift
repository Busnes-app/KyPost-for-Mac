//
//  MfaApprovalView.swift
//  KyPost
//
//  In-app MFA approval (spec §5) — reached by tapping the MFA notification
//  body. This is the only place a sign-in can be approved: the notification
//  offers Deny only, because approving means picking the number the browser is
//  showing and a banner cannot present that choice.
//

import SwiftUI

struct MfaApprovalView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: MfaApprovalViewModel

    init(challenge: MfaChallenge) {
        _viewModel = State(initialValue: MfaApprovalViewModel(
            challenge: challenge,
            approveMfaChallenge: SingletonGraph.shared.approveMfaChallengeUseCase
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 48))
                    .foregroundStyle(theme.accent)

                Text("Sign-in request")
                    .font(AppFont.ui(20, weight: .semibold))
                    .foregroundStyle(theme.inkStrong)

                Text(viewModel.matchOptions == nil
                     ? "A sign-in is waiting for a response from this device."
                     : "Tap the number shown in the browser you are signing in from.")
                    .font(AppFont.ui(14))
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.center)

                Text(viewModel.challengeId)
                    .font(AppFont.mono(12))
                    .foregroundStyle(theme.secondaryInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.panel, in: Capsule())

                switch viewModel.state {
                case .pending:
                    actionButtons
                case .sending:
                    ProgressView()
                case .done(let message):
                    Text(message)
                        .font(AppFont.ui(15, weight: .medium))
                        .foregroundStyle(SemanticColors.successText)
                    Button("Close") { dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                case .failed(let message):
                    Text(message)
                        .font(AppFont.ui(13))
                        .foregroundStyle(SemanticColors.danger)
                        .multilineTextAlignment(.center)
                    actionButtons
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .navigationTitle("Two-Factor Approval")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .tint(theme.accent)
    }

    /// Number matching, or no way to approve at all.
    ///
    /// There is deliberately no plain Approve fallback. Number matching exists
    /// because a contentless Approve button is exactly the tap an MFA-fatigue
    /// attack harvests — so falling back to that button whenever `matchDigits`
    /// is missing handed the downgrade to whoever shapes the push payload, and
    /// the relay is inside this app's threat model. It did not even work: the
    /// server refuses an approval with no number, so the fallback could only
    /// ever produce a failure. Deny stays one tap away.
    private var actionButtons: some View {
        VStack(spacing: 10) {
            if let options = viewModel.matchOptions {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { value in
                        Button(value) {
                            Task { await viewModel.choose(value) }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .font(AppFont.mono(20, weight: .semibold))
                    }
                }
            } else {
                Text("This request didn't include a verification number, so it can't be approved from this device. Deny it and start the sign-in again.")
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.warning)
                    .multilineTextAlignment(.center)
            }

            Button("Deny") {
                Task { await viewModel.respond(approved: false) }
            }
            .buttonStyle(DangerButtonStyle())
        }
        .padding(.top, 8)
    }
}
