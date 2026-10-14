//
//  ScanPgpKeyView.swift
//  KyPost
//
//  "Scan to Add Contact Key" (Client_PGP_Update.md): scan someone's QR code,
//  compare the fingerprint out loud, then attach the key to a contact.
//
//  This half works against today's backend — the key endpoint is
//  unauthenticated. iOS scans with the camera and can paste as a backup;
//  macOS has no VisionKit scanner, so it pastes only (same split as
//  PushPairingView).
//

import SwiftUI

struct ScanPgpKeyView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = ScanPgpKeyViewModel(
        client: SingletonGraph.shared.pgpQrClient,
        repository: SingletonGraph.shared.contactSyncRepository
    )
#if os(iOS)
    /// nil until the camera permission request resolves.
    @State private var cameraAccessGranted: Bool?
#endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch viewModel.state {
                case .scanning:
                    scanContent
                case .fetching:
                    ProgressView("Fetching key…")
                        .frame(maxHeight: .infinity)
                case .confirming(let key, let inPerson):
                    confirmContent(key: key, inPerson: inPerson)
                case .pickingContact(let key, _):
                    ContactKeyPicker(key: key, viewModel: viewModel)
                case .saved(let name, let inPerson):
                    savedContent(name: name, inPerson: inPerson)
                case .failed(let message, let canRescan):
                    failedContent(message: message, canRescan: canRescan)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .navigationTitle("Scan Contact Key")
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

    // MARK: - Scan / paste

    private var scanContent: some View {
        VStack(spacing: 16) {
#if os(iOS)
            scannerContent
#else
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(theme.accent)
            Text("Ask them to open My QR Code, then paste the link below.")
                .font(AppFont.ui(14))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
#endif

            TextField("https://…/api/pgp/qr/key?t=…", text: $viewModel.pastedLink)
                .font(AppFont.mono(13))
                .textFieldStyle(.plain)
                .padding(12)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
                .overlay(
                    RoundedRectangle(cornerRadius: Shape.field)
                        .strokeBorder(theme.line, lineWidth: 1)
                )

            Button("Fetch Key") {
                Task { await viewModel.submitPastedLink() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.pastedLink.isEmpty)
        }
        .frame(maxHeight: .infinity)
    }

#if os(iOS)
    @ViewBuilder
    private var scannerContent: some View {
        if QRScannerView.isSupported && cameraAccessGranted != false {
            Group {
                if cameraAccessGranted == true {
                    QRScannerView { payload in
                        Task { await viewModel.handleScannedPayload(payload) }
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
            Text("Point the camera at their QR code, or paste the link below.")
                .font(AppFont.ui(14))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
        } else {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(theme.accent)
            Text("Camera unavailable — paste their key link below instead.")
                .font(AppFont.ui(14))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
        }
    }
#endif

    // MARK: - Confirm fingerprint

    private func confirmContent(key: PgpQrKeyResponse, inPerson: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: inPerson ? "person.badge.shield.checkmark" : "exclamationmark.shield")
                .font(.system(size: 38))
                .foregroundStyle(inPerson ? theme.accent : SemanticColors.warning)
            Text(key.name)
                .font(AppFont.ui(19, weight: .semibold))
                .foregroundStyle(theme.inkStrong)
            Group {
                if inPerson {
                    Text("Check this fingerprint matches the one on their screen before you save it.")
                } else {
                    Text("This key couldn't be verified in person: their code doesn't carry a fingerprint from their own device. You can save it, but it won't be marked as verified.")
                }
            }
            .font(AppFont.ui(14))
            .foregroundStyle(theme.ink)
            .multilineTextAlignment(.center)
            Text(Self.groupedFingerprint(key.fingerprint))
                .font(AppFont.mono(14))
                .foregroundStyle(theme.inkStrong)
                .multilineTextAlignment(.center)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
                .overlay(
                    RoundedRectangle(cornerRadius: Shape.field)
                        .strokeBorder(theme.line, lineWidth: 1)
                )
            HStack(spacing: 12) {
                if inPerson {
                    Button("Doesn't Match") { viewModel.rescan() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("It Matches") {
                        Task { await viewModel.confirmFingerprint() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Cancel") { viewModel.rescan() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Save Unverified") {
                        Task { await viewModel.confirmFingerprint() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Fingerprints are compared by reading them aloud, so group them into
    /// fours — the convention every other OpenPGP tool prints.
    static func groupedFingerprint(_ fingerprint: String) -> String {
        let cleaned = fingerprint.filter { !$0.isWhitespace }
        guard !cleaned.isEmpty else { return fingerprint }
        return stride(from: 0, to: cleaned.count, by: 4).map { offset in
            let start = cleaned.index(cleaned.startIndex, offsetBy: offset)
            let end = cleaned.index(start, offsetBy: 4, limitedBy: cleaned.endIndex)
                ?? cleaned.endIndex
            return String(cleaned[start..<end])
        }
        .joined(separator: " ")
    }

    // MARK: - Terminal states

    private func savedContent(name: String, inPerson: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(SemanticColors.successBorder)
            Text("Key saved to \(name)")
                .font(AppFont.ui(19, weight: .semibold))
                .foregroundStyle(theme.inkStrong)
                .multilineTextAlignment(.center)
            if !inPerson {
                Text("Not verified in person.")
                    .font(AppFont.ui(14, weight: .semibold))
                    .foregroundStyle(theme.ink)
            }
            Text("It syncs to the server on the next sync.")
                .font(AppFont.ui(14))
                .foregroundStyle(theme.ink)
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 8)
        }
        .frame(maxHeight: .infinity)
    }

    private func failedContent(message: String, canRescan: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(SemanticColors.warning)
            Text(message)
                .font(AppFont.ui(14))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
            if canRescan {
                Button("Try Again") { viewModel.rescan() }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Close") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Contact picker

/// Chooses which contact the scanned key belongs to. Split out so its search
/// and replace-confirmation state resets naturally with the step.
private struct ContactKeyPicker: View {
    @Environment(\.theme) private var theme

    let key: PgpQrKeyResponse
    let viewModel: ScanPgpKeyViewModel

    @State private var search = ""
    /// Non-nil while confirming an overwrite of a different existing key.
    @State private var replacing: Contact?

    private var matches: [Contact] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.contacts }
        return viewModel.contacts.filter { contact in
            // Every address, not just the first: attaching a scanned key is
            // exactly when someone types the work address of a contact whose
            // personal one happens to be stored first, and finding nobody
            // invites them to create a duplicate contact for the key.
            contact.name.localizedCaseInsensitiveContains(query)
                || contact.emails.contains { $0.value.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Whose key is this?")
                .font(AppFont.ui(17, weight: .semibold))
                .foregroundStyle(theme.inkStrong)

            TextField("Search contacts", text: $search)
                .textFieldStyle(.plain)
                .font(AppFont.ui(14))
                .padding(10)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
                .overlay(
                    RoundedRectangle(cornerRadius: Shape.field)
                        .strokeBorder(theme.line, lineWidth: 1)
                )

            List {
                Button {
                    Task { await viewModel.attach(to: nil) }
                } label: {
                    Label("Create New Contact “\(key.name)”", systemImage: "person.crop.circle.badge.plus")
                        .font(AppFont.ui(14))
                        .foregroundStyle(theme.accent)
                }
                .listRowBackground(theme.bg)

                ForEach(matches) { contact in
                    Button {
                        select(contact)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name)
                                    .font(AppFont.ui(14, weight: .medium))
                                    .foregroundStyle(theme.inkStrong)
                                if !contact.primaryEmail.isEmpty {
                                    Text(contact.primaryEmail)
                                        .font(AppFont.mono(11))
                                        .foregroundStyle(theme.ink.opacity(0.8))
                                }
                            }
                            Spacer()
                            if contact.pgpKey != nil {
                                Image(systemName: "lock.shield")
                                    .foregroundStyle(theme.ink.opacity(0.6))
                            }
                        }
                    }
                    .listRowBackground(theme.bg)
                    .listRowSeparatorTint(theme.line)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity)
        .confirmationDialog(
            "Replace existing key?",
            isPresented: Binding(
                get: { replacing != nil },
                set: { if !$0 { replacing = nil } }
            ),
            presenting: replacing
        ) { contact in
            Button("Replace Key", role: .destructive) {
                Task { await viewModel.attach(to: contact) }
            }
            Button("Cancel", role: .cancel) { replacing = nil }
        } message: { contact in
            Text("\(contact.name) already has a different PGP key on file.")
        }
    }

    /// Overwriting a key silently would be the one unrecoverable action here —
    /// the old key is not kept anywhere — so a different existing key asks first.
    private func select(_ contact: Contact) {
        if let existing = contact.pgpKey, existing != key.publicKey {
            replacing = contact
        } else {
            Task { await viewModel.attach(to: contact) }
        }
    }
}
