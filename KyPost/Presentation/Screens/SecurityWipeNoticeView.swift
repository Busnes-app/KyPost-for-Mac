//
//  SecurityWipeNoticeView.swift
//  KyPost
//
//  What the user is told after a security wipe, and the terminal screen for a
//  wipe that gave up.
//
//  The three states say three different things on purpose. "Everything has
//  been erased" is the one claim in this app that must never be made falsely,
//  and "it will be retried" must not be shown by the run that stopped
//  retrying — which is exactly when Android showed it.
//

import SwiftUI

/// Shown in place of the whole app when a wipe has stopped retrying with steps
/// still failing.
///
/// Blocking, not advisory. The state that reaches here is: a wipe ran because
/// this Mac was presumed to be in the wrong hands, it could not delete
/// everything, and it has given up. The pairing credential is often part of
/// what survives — so left merely warned, the app can still receive push,
/// still render sender and subject in a notification, and still approve an
/// account login. Every one of those is what the wipe existed to prevent.
struct ManualRecoveryView: View {
    @Environment(\.theme) private var theme

    let failedSteps: [String]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(SemanticColors.danger)
            Text("Manual recovery required")
                .font(AppFont.ui(17, weight: .semibold))
                .foregroundStyle(theme.inkStrong)
            Text("""
                KyPost erased what it could from this Mac and could not finish. \
                Some data may still be here, so the app will not open. \
                Delete KyPost and install it again to clear it.
                """)
                .font(AppFont.ui(13))
                .foregroundStyle(theme.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !failedSteps.isEmpty {
                // Named, not summarised. The user cannot act on "some steps",
                // and support cannot either.
                Text("Could not remove: \(failedSteps.joined(separator: ", "))")
                    .font(AppFont.ui(12))
                    .foregroundStyle(theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }
}

/// The banner shown once after a wipe, above whatever the app came back as.
struct SecurityWipeNoticeBanner: View {
    @Environment(\.theme) private var theme

    let result: WipeResult
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppFont.ui(13, weight: .semibold))
                Text(message).font(AppFont.ui(12))
            }
            .foregroundStyle(theme.inkStrong)
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.plain)
                .font(AppFont.ui(12, weight: .semibold))
                .foregroundStyle(theme.accent)
        }
        .padding(12)
        .background(theme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    private var icon: String {
        if case .complete = result { "checkmark.shield.fill" } else { "exclamationmark.triangle.fill" }
    }

    private var tint: Color {
        if case .complete = result { theme.accent } else { SemanticColors.danger }
    }

    private var title: String {
        switch result {
        case .complete: "This Mac was erased"
        case .incomplete: "This Mac was only partly erased"
        }
    }

    private var message: String {
        switch result {
        case .complete:
            return """
                Too many incorrect attempts, so KyPost removed the pairing and \
                everything it had stored here. Your mail is still on your server.
                """
        case .incomplete(let steps, let willRetry):
            let named = steps.isEmpty ? "" : " Could not remove: \(steps.joined(separator: ", "))."
            // Two messages, because promising a retry that will never happen
            // tells the user their data will be erased when it will not be.
            return willRetry
                ? "KyPost could not remove everything and will try again the next time it starts.\(named)"
                : "KyPost could not remove everything and has stopped trying. Delete and reinstall the app to clear it.\(named)"
        }
    }
}
