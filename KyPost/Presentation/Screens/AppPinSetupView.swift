//
//  AppPinSetupView.swift
//  KyPost
//
//  Setting or changing the app-lock PIN.
//
//  The consequence is stated **before** the field, not in a footnote after it:
//  the chosen number of wrong attempts (ten by default) erases everything
//  KyPost keeps on this device. A user who learns that from the erasure was
//  not told.
//

import SwiftUI

struct AppPinSetupView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let manager: AppLockManager
    /// True when a PIN already exists, which changes the title and requires the
    /// current one first.
    let isChange: Bool

    @State private var currentPin = ""
    @State private var newPin = ""
    @State private var confirmPin = ""
    @State private var message: String?
    @State private var working = false

    private var consequence: String {
        if let attempts = manager.wipeThresholdSetting.attempts {
            return String(localized: "8 to 12 digits. After \(attempts) wrong attempts in a row, KyPost erases the pairing and everything it has stored on this device. Your mail stays on your server.")
        }
        return String(localized: "8 to 12 digits. Wrong attempts add a wait but never erase this device (Erase Data After: Never).")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isChange ? "Change PIN" : "Set a PIN")
                .font(AppFont.ui(17, weight: .semibold))
                .foregroundStyle(theme.inkStrong)

            Text(consequence)
                .font(AppFont.ui(12))
                .foregroundStyle(theme.secondaryInk)
                .frame(maxWidth: 380, alignment: .leading)

            if isChange {
                SecureField("Current PIN", text: $currentPin)
                    .textFieldStyle(.roundedBorder)
            }
            SecureField("New PIN", text: $newPin)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm new PIN", text: $confirmPin)
                .textFieldStyle(.roundedBorder)

            if let message {
                Text(message)
                    .font(AppFont.ui(12))
                    .foregroundStyle(SemanticColors.danger)
                    .frame(maxWidth: 380, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isChange ? "Change PIN" : "Set PIN") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .disabled(working || newPin.isEmpty || confirmPin.isEmpty
                        || (isChange && currentPin.isEmpty))
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(theme.bg)
    }

    private func save() {
        guard newPin == confirmPin else {
            message = "The two entries don't match."
            return
        }
        working = true
        Task {
            defer { working = false }
            // The current PIN is verified through the throttled path, not
            // against the store directly. A settings screen that checks its own
            // way is the unthrottled second entry point the ladder exists to
            // close — and it runs the same wipe threshold as every other check,
            // so its whole outcome has to be handled here.
            if isChange {
                switch await manager.verifyPinThrottled(currentPin) {
                case .success:
                    break
                case .rejected(let delay):
                    message = delay > 0
                        ? "Incorrect PIN. Try again in \(UnlockView.wait(delay))."
                        : "Incorrect PIN."
                    return
                case .notConfigured:
                    message = "There is no PIN set on this Mac."
                    return
                case .gatedSecretUnavailable:
                    // Not reachable from here — this path never unlocks — but
                    // the switch is exhaustive so a new outcome is a compile
                    // error rather than a silent fall-through to "incorrect".
                    message = "KyPost couldn't complete that check. Try again."
                    return
                case .verifierUnavailable:
                    message = """
                        KyPost can't check your current PIN right now — the key that \
                        protects it is unavailable. This does not mean it is wrong.
                        """
                    return
                case .wiped, .wipeFailed:
                    // The wipe already ran and rebuilt the app underneath this
                    // sheet. Closing is all that is left to do; the notice is
                    // shown by the rebuilt window.
                    dismiss()
                    return
                }
            }

            do {
                switch try manager.setPin(newPin) {
                case .valid:
                    dismiss()
                case .tooShort:
                    message = "Use at least \(PinPolicy.minLength) digits."
                case .tooLong:
                    message = "Use no more than \(PinPolicy.maxLength) digits."
                case .notNumeric:
                    message = "Use digits only."
                case .tooCommon:
                    message = """
                        That PIN is too easy to guess. Avoid runs like 12345678, \
                        repeats, dates, and keypad patterns.
                        """
                }
            } catch {
                message = "Could not save the PIN: \(error.localizedDescription)"
            }
        }
    }
}
