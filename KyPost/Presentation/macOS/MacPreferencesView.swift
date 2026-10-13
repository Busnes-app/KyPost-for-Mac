//
//  MacPreferencesView.swift
//  KyPost
//
//  Native macOS Settings window (Cmd+,): toolbar-style tabs with grouped
//  forms, standard controls, and the theme accent as tint — per the style
//  guide's "stay native wins" rule.
//

#if os(macOS)
import SwiftUI

struct MacPreferencesView: View {
    @Environment(ThemeManager.self) private var themeManager

    @State private var viewModel = SettingsViewModel(
        securePairingStore: SingletonGraph.shared.securePairingStore,
        pushSettingsStore: SingletonGraph.shared.pushSettingsStore,
        desktopSessionStore: SingletonGraph.shared.desktopSessionStore,
        mailRepository: SingletonGraph.shared.mailRepository,
        keywordRepository: SingletonGraph.shared.keywordRepository,
        contactsSettingsStore: SingletonGraph.shared.contactsSettingsStore,
        systemContactsExporter: SingletonGraph.shared.systemContactsExporter,
        deviceRegistrationService: SingletonGraph.shared.deviceRegistrationService,
        deregisterDeviceUseCase: SingletonGraph.shared.deregisterDeviceUseCase,
        pushNotificationDispatcher: SingletonGraph.shared.pushNotificationDispatcher,
        enrollmentVault: SingletonGraph.shared.enrollmentVault,
        appLockManager: SingletonGraph.shared.appLockManager,
        pushRepository: SingletonGraph.shared.pushRepository,
        recipientPinStore: SingletonGraph.shared.recipientPinStore,
        mailSignatureStore: SingletonGraph.shared.mailSignatureStore,
        onUnpaired: { SingletonGraph.shared.inboxViewModel.forgetAccount() },
        pairingDisplayOverride: SingletonGraph.shared.pairingDisplayOverride
    )

    var body: some View {
        TabView {
            ConnectionPane(viewModel: viewModel)
                .tabItem { Label("Connection", systemImage: "link") }

            AppearancePane()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            KeywordsPane(viewModel: viewModel)
                .tabItem { Label("Keywords", systemImage: "tag") }

            SignatureSettingsView()
                .tabItem { Label("Signature", systemImage: "signature") }

            ContactsPane(viewModel: viewModel)
                .tabItem { Label("Contacts", systemImage: "person.crop.circle") }

            NotificationsPane(viewModel: viewModel)
                .tabItem { Label("Notifications", systemImage: "bell") }

            EncryptionPane()
                .tabItem { Label("Encryption", systemImage: "lock.shield") }

            SecurityPane()
                .tabItem { Label("Security", systemImage: "lock") }

        }
        .frame(width: 700, height: 460)
        .tint(themeManager.palette.accent)
        .environment(\.theme, themeManager.palette)
        .preferredColorScheme(themeManager.palette.preferredColorScheme)
    }
}

// MARK: - Connection

private struct ConnectionPane: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var showPairingSheet = false
    @State private var showUnpairConfirmation = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    StatusBadgeView(
                        label: viewModel.pairingDisplay != nil ? "Paired" : "Not paired",
                        isActive: viewModel.pairingDisplay != nil
                    )
                }
                if let pairing = viewModel.pairingDisplay {
                    LabeledContent("Server", value: pairing.serverHost)
                    if let account = pairing.account {
                        LabeledContent("Account") {
                            Text(account)
                                .font(AppFont.mono(11))
                                .textSelection(.enabled)
                        }
                    }
                    if let deviceId = pairing.deviceId {
                        LabeledContent("Device ID") {
                            Text(deviceId)
                                .font(AppFont.mono(11))
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Text("Pair this Mac with your KyPost account to load mail.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Relay")
            }

            Section {
                HStack {
                    if viewModel.pairingDisplay != nil {
                        Button("Test Connection") {
                            Task { await viewModel.testConnection() }
                        }
                        Button("Re-pair…") { showPairingSheet = true }
                        Spacer()
                        Button("Remove Pairing", role: .destructive) {
                            showUnpairConfirmation = true
                        }
                    } else {
                        Button("Pair This Mac…") { showPairingSheet = true }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                }
            }

            if let session = viewModel.desktopSession {
                Section {
                    if let email = session.userEmail {
                        LabeledContent("Account", value: email)
                    }
                    LabeledContent(
                        "Signed in",
                        value: session.pairedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    LabeledContent(
                        "Expires",
                        value: session.expiresAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    HStack {
                        Spacer()
                        Button("Forget This Computer", role: .destructive) {
                            Task { await viewModel.forgetDesktopPairing() }
                        }
                    }
                } header: {
                    Text("Desktop Session")
                }
            }

            if let message = viewModel.statusMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPairingSheet) {
            DesktopPairingView(initialParams: nil)
        }
        .confirmationDialog(
            "Unpair this device?",
            isPresented: $showUnpairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                Task { await viewModel.unpair() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the device from your account's paired devices on the server and clears its local pairing. You'll need to scan a new QR code or pass a new link to pair again.")
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        Form {
            Section {
                ForEach(AppTheme.themeNames, id: \.self) { name in
                    let palette = AppTheme.palette(named: name)
                    Button {
                        themeManager.setTheme(named: name)
                    } label: {
                        HStack(spacing: 10) {
                            HStack(spacing: 3) {
                                swatch(palette.bg)
                                swatch(palette.panel)
                                swatch(palette.accent)
                            }
                            Text(name)
                            Spacer()
                            if themeManager.themeName == name {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(themeManager.palette.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Themes are shared with the web and Android apps.")
            }
        }
        .formStyle(.grouped)
    }

    private func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
    }
}

// MARK: - Keywords

private struct KeywordsPane: View {
    let viewModel: SettingsViewModel

    var body: some View {
        List {
            if viewModel.keywordSettings.isEmpty {
                Section {
                    Text("No keywords yet — they appear after your first inbox refresh.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(viewModel.keywordSettings) { setting in
                        Toggle(
                            setting.name,
                            isOn: Binding(
                                get: { setting.visible },
                                set: { viewModel.setKeywordVisible($0, for: setting.name) }
                            )
                        )
                    }
                    .onMove(perform: viewModel.moveKeywords)
                } header: {
                    Text("Inbox Tabs")
                } footer: {
                    Text("Drag a keyword row to set its Inbox tab order. Hidden keywords stay on emails but don't get a sidebar tab.")
                }
            }
        }
        .listStyle(.inset)
        .task { await viewModel.loadKeywordSettings() }
    }
}

// MARK: - Contacts

// MARK: - Encryption

/// "My QR Code" only. Scanning someone else's key starts from the contact
/// list, where the contact to attach it to already is.
private struct EncryptionPane: View {
    var body: some View {
        MyPgpQrCodeView()
    }
}

// MARK: - Security

private struct SecurityPane: View {
    var body: some View {
        Form {
            SecuritySettingsContent()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Contacts

private struct ContactsPane: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Sync contacts with Apple Contacts", isOn: $viewModel.exportContactsToSystem)
                if viewModel.contactsExportDenied {
                    HStack {
                        Text("Contacts access is denied for KyPost.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings") {
                            viewModel.openContactsPrivacySettings()
                        }
                    }
                }
            } footer: {
                Text("Contacts sync both ways: new cards you add in Apple Contacts are imported, matching contacts (same email) are linked instead of duplicated, and only cards created or imported by KyPost are ever updated or removed.")
            }

            if viewModel.exportContactsToSystem || viewModel.hasExportedContacts {
                Section {
                    HStack {
                        if viewModel.exportContactsToSystem {
                            Button("Re-export Missing Contacts") {
                                Task { await viewModel.reexportMissingContacts() }
                            }
                        }
                        Spacer()
                        if viewModel.hasExportedContacts {
                            Button("Remove Exported Contacts", role: .destructive) {
                                Task { await viewModel.removeExportedContacts() }
                            }
                        }
                    }
                } footer: {
                    Text("Re-export recreates cards that were removed from Apple Contacts outside KyPost.")
                }
            }

            if let message = viewModel.statusMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { viewModel.refreshContactsExportState() }
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var history = NotificationHistoryViewModel(
        repository: SingletonGraph.shared.pushRepository,
        pushSettingsStore: SingletonGraph.shared.pushSettingsStore
    )

    var body: some View {
        Form {
            Section {
                Toggle("Show system notifications", isOn: $viewModel.systemNotificationsEnabled)
                LabeledContent("Delivery Mode", value: viewModel.deliveryMode)
            } footer: {
                Text("In Pull mode this Mac checks for notifications every 90 seconds while running. In Push mode it checks the server itself if no push has arrived for three hours.")
            }

            Section {
                HStack {
                    Button("Fix Notifications") {
                        Task { await viewModel.repairNotifications() }
                    }
                    .disabled(viewModel.isRepairingNotifications)
                    Spacer()
                }
            } footer: {
                Text("Checks notification permission, refreshes this Mac's push token, and re-registers it with the server. If the server no longer accepts the pairing, re-pair from the web app.")
            }

            if let message = viewModel.statusMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }

            NotificationHistorySections(viewModel: history)
        }
        .formStyle(.grouped)
        .task { await history.load() }
    }
}
#endif
