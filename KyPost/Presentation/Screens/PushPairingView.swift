//
//  PushPairingView.swift
//  KyPost
//
//  Pairing flow (spec §1). Auto-pairs when opened from a deep link. On iOS
//  the default entry point is camera QR scanning, with a paste-the-link
//  fallback and "Sign in with KyIdentity" (KyAuth handoff); macOS pairs via
//  deep link or paste.
//

import SwiftUI

struct PushPairingView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Non-nil when opened from a kypost://native-pair deep link.
    let initialParams: PairingParams?

    @State private var viewModel = PushPairingViewModel(
        registrationService: SingletonGraph.shared.deviceRegistrationService,
        pushSettingsStore: SingletonGraph.shared.pushSettingsStore,
        securePairingStore: SingletonGraph.shared.securePairingStore
    )
#if os(iOS)
    /// nil until the camera permission request resolves.
    @State private var cameraAccessGranted: Bool?
    /// Optional so a presentation that forgot to inject it hides the entry
    /// rather than trapping.
    @Environment(KyIdentitySignOnCoordinator.self) private var signOn: KyIdentitySignOnCoordinator?
    @State private var showSignOn = false
#endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch viewModel.state {
                case .idle:
                    idleContent
                case .confirming(let confirmation):
                    confirmingContent(confirmation)
                case .working:
                    ProgressView("Pairing…")
                        .frame(maxHeight: .infinity)
                case .paired(let deviceId):
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(SemanticColors.successBorder)
                        Text("Device paired")
                            .font(AppFont.ui(19, weight: .semibold))
                            .foregroundStyle(theme.inkStrong)
                        if let deviceId {
                            Text(deviceId)
                                .font(AppFont.mono(12))
                                .foregroundStyle(theme.ink.opacity(0.8))
                        }
                        Button("Done") { dismiss() }
                            .buttonStyle(PrimaryButtonStyle())
                            .padding(.top, 8)
                    }
                    .frame(maxHeight: .infinity)
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(SemanticColors.warning)
                        Text(message)
                            .font(AppFont.ui(14))
                            .foregroundStyle(theme.ink)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { viewModel.reset() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .navigationTitle("Pair Device")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
#if os(iOS)
            .navigationDestination(isPresented: $showSignOn) {
                KyIdentitySignOnView()
            }
#endif
        }
        .tint(theme.accent)
        .task {
            if let initialParams {
                viewModel.present(params: initialParams)
            }
        }
#if os(iOS)
        .modifier(SignOnHandoffReceiver(signOn: signOn, showSignOn: $showSignOn) { params in
            viewModel.present(params: params)
        })
        // Nothing presents while locked. This sheet is also presented from
        // Settings, outside the router, and switching to KyAuth backgrounds
        // the app and engages the lock; a sign-on that finishes meanwhile is
        // delivered through the router, which defers it until unlock.
        .onChange(of: SingletonGraph.shared.appLockManager.isLocked) { _, locked in
            if locked { dismiss() }
        }
#endif
    }

    /// Shown before any network call fires — names the destination host and
    /// requires an explicit tap to continue, for every entry point (deep
    /// link, scanned QR, pasted link). A crafted link/QR could otherwise
    /// silently repoint the pairing at an attacker server.
    private func confirmingContent(_ confirmation: PendingPairingConfirmation) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 38))
                .foregroundStyle(theme.accent)
            Text("Pair with this server?")
                .font(AppFont.ui(19, weight: .semibold))
                .foregroundStyle(theme.inkStrong)
            Text(URL(string: confirmation.params.srv)?.host ?? confirmation.params.srv)
                .font(AppFont.mono(15))
                .foregroundStyle(theme.inkStrong)
                .multilineTextAlignment(.center)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
            if let existingHost = confirmation.existingHost {
                Text("This replaces your current pairing with \(existingHost).")
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.warning)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Cancel") { viewModel.reset() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Pair") {
                    Task { await viewModel.pair(params: confirmation.params) }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var idleContent: some View {
        VStack(spacing: 16) {
#if os(iOS)
            scannerContent
#else
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(theme.accent)
            Text("Open a pairing link from the web app, or paste it below.")
                .font(AppFont.ui(14))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
#endif

            TextField("kypost://native-pair?…", text: $viewModel.pastedLink)
                .font(AppFont.mono(13))
                .textFieldStyle(.plain)
                .padding(12)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
                .overlay(
                    RoundedRectangle(cornerRadius: Shape.field)
                        .strokeBorder(theme.line, lineWidth: 1)
                )

            Button("Pair") {
                Task { await viewModel.pairFromPastedLink() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.pastedLink.isEmpty)

#if os(iOS)
            if signOn != nil {
                Button("Sign in with KyIdentity") { showSignOn = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
#endif
        }
        .frame(maxHeight: .infinity)
    }

#if os(iOS)
    /// Default iOS entry point: scan the pairing QR code from the web app.
    @ViewBuilder
    private var scannerContent: some View {
        if QRScannerView.isSupported && cameraAccessGranted != false {
            Group {
                if cameraAccessGranted == true {
                    QRScannerView { payload in
                        Task { await viewModel.pairFromScannedCode(payload) }
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: Shape.field))
            .overlay(
                RoundedRectangle(cornerRadius: Shape.field)
                    .strokeBorder(theme.line, lineWidth: 1)
            )
            .task {
                if cameraAccessGranted == nil {
                    cameraAccessGranted = await QRScannerView.requestCameraAccess()
                }
            }
            Text("Point the camera at the pairing QR code from the web app, or paste the link below.")
                .font(AppFont.ui(14))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
        } else {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(theme.accent)
            Text("Camera unavailable — paste the pairing link below instead.")
                .font(AppFont.ui(14))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
        }
    }
#endif
}

#if os(iOS)
/// Takes a finished sign-on into this pairing screen's confirmation step. Registers the screen as live so the
/// coordinator knows whether to hand over here or through the router.
private struct SignOnHandoffReceiver: ViewModifier {
    let signOn: KyIdentitySignOnCoordinator?
    @Binding var showSignOn: Bool
    let present: (PairingParams) -> Void

    func body(content: Content) -> some View {
        if let signOn {
            content
                .onAppear { signOn.pairingScreenAppeared() }
                .onDisappear { signOn.pairingScreenDisappeared() }
                .onChange(of: signOn.completed, initial: true) { _, _ in
                    guard let params = signOn.takeCompleted() else { return }
                    showSignOn = false
                    present(params)
                }
        } else {
            content
        }
    }
}
#endif
