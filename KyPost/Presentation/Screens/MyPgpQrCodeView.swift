//
//  MyPgpQrCodeView.swift
//  KyPost
//
//  "My QR Code" (Client_PGP_Update.md): shows a short-lived pickup URL as a QR
//  code for someone standing next to you to scan.
//
//  Minting authenticates with the relay pairing credentials (sub/hash), the
//  same trust boundary as contact sync — see PgpQrClient's header. So the
//  screen works as soon as this computer is paired with the server; no
//  separate desktop-code session is involved.
//

import SwiftUI

struct MyPgpQrCodeView: View {
    @Environment(\.theme) private var theme

    @State private var viewModel = Self.makeViewModel()

    /// Built here, not inline: Xcode 27's `@State` macro moves an inline
    /// initial value into a static stored property, and the closure capture
    /// list below crashes the type checker there ("failed to produce
    /// diagnostic for expression").
    private static func makeViewModel() -> MyPgpQrViewModel {
        let graph = SingletonGraph.shared
        let vault = graph.enrollmentVault
        return MyPgpQrViewModel(
            client: graph.pgpQrClient,
            pairingStore: graph.securePairingStore,
            bootstrapClient: graph.pgpSendClient,
            session: EnrollmentSession.shared,
            crypto: graph.pgpCrypto,
            opener: DeviceVaultOpener(vault: vault, inspector: graph.pgpCrypto),
            deviceIsEnrolled: { vault.isEnrolled }
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            switch viewModel.state {
            case .loading:
                ProgressView("Preparing your code…")
                    .frame(maxHeight: .infinity)
            case .showing(let urlString, _):
                qrContent(urlString: urlString)
            case .needsPairing:
                message(
                    "Pair this computer with the web app to show your key code.",
                    icon: "lock.shield"
                )
            case .noPgpIdentity:
                message(
                    "Set up a PGP key in the web app first, then come back.",
                    icon: "key"
                )
            case .pairingRejected:
                retryable(
                    "The server no longer recognizes this computer — pair it again to show your code.",
                    icon: "lock.slash"
                )
            case .unavailable:
                // 503 is a server config gap; retrying cannot fix it, so no CTA.
                message(
                    "Key exchange isn't set up on this server.",
                    icon: "exclamationmark.triangle"
                )
            case .failed(let text):
                retryable(text, icon: "exclamationmark.triangle")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .navigationTitle("My QR Code")
        .task { await viewModel.refresh() }
        .task { await viewModel.observeExpiry() }
    }

    private func qrContent(urlString: String) -> some View {
        VStack(spacing: 14) {
            if let cgImage = QRCodeGenerator.cgImage(for: urlString) {
                // Always on white regardless of theme — a dark-tinted QR code
                // is a QR code that doesn't scan.
                Image(decorative: cgImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 240)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: Shape.field))
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 44))
                    .foregroundStyle(theme.secondaryInk)
                Text("Couldn't render the QR code.")
                    .font(AppFont.ui(14))
                    .foregroundStyle(theme.ink)
            }

            Text("Have them scan this in KyPost to add your public key.")
                .font(AppFont.ui(14))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)

            fingerprintContent

            if let seconds = viewModel.secondsRemaining {
                Text(seconds > 0 ? "Expires in \(seconds)s" : "Expired — refreshing…")
                    .font(AppFont.mono(12))
                    .foregroundStyle(theme.secondaryInk)
                    .monospacedDigit()
            }

            Button("Refresh") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var fingerprintContent: some View {
        switch viewModel.fingerprint {
        case .thisDevice(let fingerprint):
            Text("Your fingerprint, from the key on this device")
                .font(AppFont.ui(12))
                .foregroundStyle(theme.secondaryInk)
            fingerprintText(fingerprint)
        case .serverReported(let fingerprint):
            Text("Fingerprint reported by the server, not checked on this device. They can't verify this code in person.")
                .font(AppFont.ui(12, weight: .semibold))
                .foregroundStyle(theme.inkStrong)
                .multilineTextAlignment(.center)
            fingerprintText(fingerprint)
        case nil:
            Text("No fingerprint from a key on this device, so they can't verify this code in person.")
                .font(AppFont.ui(12, weight: .semibold))
                .foregroundStyle(theme.inkStrong)
                .multilineTextAlignment(.center)
        }
        if viewModel.canUnlockKey {
            Button("Unlock Key to Verify") {
                Task { await viewModel.unlockKey() }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func fingerprintText(_ fingerprint: String) -> some View {
        Text(ScanPgpKeyView.groupedFingerprint(fingerprint))
            .font(AppFont.mono(13))
            .foregroundStyle(theme.inkStrong)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
    }

    private func message(_ text: String, icon: String) -> some View {
        EmptyStateView(message: text, systemImage: icon)
            .frame(maxHeight: .infinity)
    }

    private func retryable(_ text: String, icon: String) -> some View {
        VStack(spacing: 12) {
            EmptyStateView(message: text, systemImage: icon)
            Button("Try Again") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxHeight: .infinity)
    }
}
