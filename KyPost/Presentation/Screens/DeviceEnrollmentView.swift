//
//  DeviceEnrollmentView.swift
//  KyPost
//
//  Sets this device up to read and send encrypted mail for a client-custody
//  account. Counterpart of kypost-android's pgp/DeviceEnrollmentActivity.kt.
//

import SwiftUI

struct DeviceEnrollmentView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: DeviceEnrollmentViewModel

    init(viewModel: DeviceEnrollmentViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up encrypted mail")
                .font(AppFont.ui(17, weight: .semibold))
                .foregroundStyle(theme.inkStrong)

            content

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(viewModel.isFinished ? "Done" : "Cancel") { dismiss() }
                if viewModel.offersRetry {
                    Button("Check again") { viewModel.start() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
        .background(theme.bg)
        .task { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .checkingAccount:
            progress("Checking your account…")
        case .publishing:
            progress("Preparing this device…")
        case .showingCode(let code, let windowOpen):
            codeInstructions(code: code, waiting: windowOpen)
        case .readyToFinish:
            message("Your browser has already sent the key. Choose “Check again” and confirm it's you to finish.")
        case .opening:
            progress("Opening the key that was sent to this device…")
        case .enrolled:
            message("This device can now read and send your encrypted mail.")

        case .noIdentity:
            message("This account has no PGP key yet. Create one in the web app first.")
        case .hostileLocationEnabled:
            // The trade is the whole point of the gate, so it is named rather
            // than hidden behind a generic refusal.
            message("Hostile Location Protection is on, and it's the mode where this device holds nothing. Turn it off in Security settings first — and understand that enrolling means your key lives on this device.")
        case .noDeviceCredential:
            message("Set a passcode on this device first. The key is protected by your lock screen, so a device without one can't hold it.")
        case .notPaired:
            message("Pair this device again — the server didn't accept its credentials.")
        case .publishRejected(let reason):
            message(reason)
        case .timedOut:
            // Deliberately not phrased as an alarm: codes rotate, and the
            // ordinary cause is that the user hasn't reached their browser yet.
            message("Nothing has arrived in the last five minutes. Codes change every couple of minutes, so choose “Check again” for a current one, then type that in your browser.")
        case .envelopeRejected:
            // The feature's one real alarm.
            message("The key that arrived wasn't sealed for this device. Don't continue — start again, and if it happens twice, treat it as a problem with your server.")
        case .keyringRejected:
            message("The keys that arrived don't match what your server says it sent, or would replace keys this device still needs. Nothing was changed. Start again from your browser.")
        case .acknowledgementRefused:
            message("Your server didn't accept this device's keys as current — your account's keys may have changed meanwhile. Set up encryption on this device again.")
        case .sealFailed(let reason), .failed(let reason):
            message(reason)
        case .cancelled:
            message("Confirm it's you to finish setting up this device.")
        }
    }

    private func codeInstructions(code: String, waiting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In your browser, open KyPost and go to Settings → Security → Devices, choose “Set up a device”, and type this code:")
                .font(AppFont.ui(13))
                .foregroundStyle(theme.ink)
            Text(formattedEnrollmentCode(code))
                .font(AppFont.mono(28, weight: .semibold))
                .foregroundStyle(theme.inkStrong)
                .textSelection(.enabled)
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            if waiting {
                progress("Waiting for your browser…")
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(AppFont.ui(13)).foregroundStyle(theme.ink)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(AppFont.ui(13))
            .foregroundStyle(theme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}
