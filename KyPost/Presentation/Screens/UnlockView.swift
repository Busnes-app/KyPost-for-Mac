//
//  UnlockView.swift
//  KyPost
//
//  Full-window cover shown while the app is locked (security-hardening
//  plan, Task 2; PIN entry from Phase 11).
//
//  Two verifiers, and which one leads depends on what the user configured. A
//  PIN is only there because they chose it, so with one set the field leads and
//  nothing is auto-prompted — raising a system authentication sheet over a PIN
//  field asks for something the user did not ask for. Without a PIN, this
//  behaves as it always did: auto-attempt on appear, button to retry.
//
//  Presentation is per-platform: iOS uses a fullScreenCover from
//  MainTabView, and the privacy-cover window (AppDelegate) hosts one when the
//  app returns locked; macOS overlays each window's root via LockedOverlay.
//

import SwiftUI

struct UnlockView: View {
    @Environment(\.theme) private var theme

    let manager: AppLockManager
    /// Without a PIN, raise the system prompt on appear. The iOS privacy
    /// cover hosts a second copy over the in-tree one and passes false, so
    /// one return never raises two prompts.
    var promptsOnAppear = true

    @State private var resetConfirmationShown = false
    @State private var resetMessage: String?
    @State private var pin = ""
    @State private var pinStatus: String?
    @State private var submitting = false
    /// Mirrors `manager.remainingLockoutMillis` so the field re-enables itself
    /// when the wait is over. Polled rather than derived, because nothing else
    /// changes to redraw this view while a lockout runs out.
    @State private var lockoutRemaining: Int64 = 0

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 42))
                .foregroundStyle(theme.accent)
            Text("KyPost is locked")
                .font(AppFont.ui(17, weight: .semibold))
                .foregroundStyle(theme.inkStrong)
            if manager.hasPin {
                pinEntry
                Button("Use Touch ID or Password") {
                    Task { await manager.requestUnlock() }
                }
                .buttonStyle(.bordered)
                .tint(theme.accent)
            } else {
                Button("Unlock") {
                    Task { await manager.requestUnlock() }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
            }

            // The lock has no bypass, so a device that can no longer satisfy
            // the authenticator at all — biometric enrolment changed, passcode
            // removed — would otherwise strand the user permanently: the
            // setting that turns the lock off lives behind the lock.
            if manager.shouldOfferReset {
                VStack(spacing: 8) {
                    Text("Can't unlock? Resetting removes this device's pairing and everything KyPost has cached here. Your mail stays on your server.")
                        .font(AppFont.ui(13))
                        .foregroundStyle(theme.ink.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button("Reset KyPost on This Device") {
                        resetConfirmationShown = true
                    }
                    .buttonStyle(.bordered)
                    .tint(SemanticColors.danger)
                }
                .padding(.top, 12)
            }

            if let resetMessage {
                Text(resetMessage)
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.danger)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .confirmationDialog(
            "Reset KyPost on this device?",
            isPresented: $resetConfirmationShown,
            titleVisibility: .visible
        ) {
            Button("Erase & Unpair", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the pairing, the app lock, and all cached mail, contacts, photos, attachments, and drafts. You'll need to pair this device again from the web app.")
        }
        .task {
            // Only without a PIN. See the file header.
            if promptsOnAppear, !manager.hasPin { await manager.requestUnlock() }
        }
        .task(id: manager.hasPin) {
            guard manager.hasPin else { return }
            // A lockout is the one piece of state here that changes on its own.
            while !Task.isCancelled {
                lockoutRemaining = manager.remainingLockoutMillis
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var pinEntry: some View {
        VStack(spacing: 8) {
            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
#if os(iOS)
                .keyboardType(.numberPad)
#endif
                .onChange(of: pin) { _, entry in
                    let capped = PinPolicy.capped(entry)
                    if capped != entry { pin = capped }
                }
                .frame(maxWidth: 220)
                .disabled(submitting || lockoutRemaining > 0)
                .onSubmit { submit() }
            Button("Unlock", action: submit)
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(pin.isEmpty || submitting || lockoutRemaining > 0)

            if lockoutRemaining > 0 {
                Text("Too many attempts. Try again in \(Self.wait(lockoutRemaining)).")
                    .font(AppFont.ui(12))
                    .foregroundStyle(theme.ink.opacity(0.8))
            }
            if let pinStatus {
                Text(pinStatus)
                    .font(AppFont.ui(12))
                    .foregroundStyle(SemanticColors.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
    }

    private func submit() {
        guard !pin.isEmpty, !submitting else { return }
        submitting = true
        Task {
            let outcome = await manager.attemptPinUnlock(pin)
            pin = ""
            submitting = false
            lockoutRemaining = manager.remainingLockoutMillis
            apply(outcome)
        }
    }

    /// Every outcome gets its own sentence.
    ///
    /// `verifierUnavailable` is the one that matters most: the PIN was **not**
    /// wrong, and telling the user it was invites them to burn attempts against
    /// a threshold this outcome deliberately does not advance. The wipe cases
    /// say nothing here — `AppEnvironment` records the notice and the rebuilt
    /// window shows it, because this view is destroyed by the rebuild the wipe
    /// performs.
    private func apply(_ outcome: UnlockAttemptOutcome) {
        switch outcome {
        case .success:
            pinStatus = nil
        case .rejected(let delay):
            pinStatus = delay > 0 ? nil : "Incorrect PIN."
        case .notConfigured:
            pinStatus = "There is no PIN set on this Mac."
        case .gatedSecretUnavailable:
            pinStatus = """
                Your PIN was correct, but KyPost couldn't read the credential it \
                needs to reach your server, so it stayed locked. Try again and \
                allow the authentication prompt.
                """
        case .verifierUnavailable:
            pinStatus = """
                KyPost can't check your PIN on this Mac right now — the key that \
                protects it is unavailable. This does not mean the PIN is wrong. \
                Restart, and use Reset below if it keeps happening.
                """
        case .wiped, .wipeFailed:
            pinStatus = nil
        }
    }

    /// Whole minutes once past a minute; the ladder's rungs are 30s to 30m, so
    /// a live-ticking second counter would be noise for all but the first.
    static func wait(_ millis: Int64) -> String {
        let seconds = Int((millis + 999) / 1000)
        if seconds < 60 { return "\(seconds)s" }
        return "\(Int((Double(seconds) / 60).rounded(.up)))m"
    }

    private func reset() {
        do {
            try AppEnvironment.shared.resetAfterFailedUnlock()
            resetMessage = nil
        } catch {
            resetMessage = "Could not reset: \(error.localizedDescription)"
        }
    }
}

/// Covers a macOS window's content while locked; renders nothing on iOS
/// (which presents UnlockView as a fullScreenCover instead). Known limit,
/// disclosed in the plan: window-modal sheets sit above a root overlay.
struct LockedOverlay: View {
    private var manager: AppLockManager { SingletonGraph.shared.appLockManager }

    var body: some View {
#if os(macOS)
        if manager.isLocked {
            UnlockView(manager: manager)
        }
#endif
    }
}
