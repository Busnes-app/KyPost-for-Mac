//
//  SettingsView.swift
//  KyPost
//
//  iOS settings: relay pairing status, theme, keywords, notifications, about.
//  macOS uses MacPreferencesView (native Settings window) instead.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.theme) private var theme

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
        erasePreservedStore: SingletonGraph.shared.erasePreservedStoreStep,
        enrollmentVault: SingletonGraph.shared.enrollmentVault,
        appLockManager: SingletonGraph.shared.appLockManager,
        pushRepository: SingletonGraph.shared.pushRepository,
        recipientPinStore: SingletonGraph.shared.recipientPinStore,
        mailSignatureStore: SingletonGraph.shared.mailSignatureStore,
        onUnpaired: { SingletonGraph.shared.inboxViewModel.forgetAccount() },
        pairingDisplayOverride: SingletonGraph.shared.pairingDisplayOverride
    )
    @State private var showPairingSheet = false
    @State private var showUnpairConfirmation = false

    var body: some View {
        Form {
            Section("Connection") {
                if let pairing = viewModel.pairingDisplay {
                    LabeledContent("Connected via", value: pairing.serverHost)
                    if let account = pairing.account {
                        LabeledContent("Account") {
                            Text(account).font(AppFont.mono(12))
                        }
                    }
                    if let deviceId = pairing.deviceId {
                        LabeledContent("Device ID") {
                            Text(deviceId).font(AppFont.mono(12))
                        }
                    }
                    HStack {
                        StatusBadgeView(label: "Paired", isActive: true)
                        Spacer()
                    }
                    Button("Test Connection") {
                        Task { await viewModel.testConnection() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Re-pair Device") { showPairingSheet = true }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Remove Pairing") { showUnpairConfirmation = true }
                        .buttonStyle(DangerButtonStyle())
                } else {
                    HStack {
                        StatusBadgeView(label: "Not paired", isActive: false)
                        Spacer()
                    }
                    Text("Pair this device with your KyPost account to load mail.")
                        .font(AppFont.ui(13))
                        .foregroundStyle(theme.secondaryInk)
                    Button("Pair Device") { showPairingSheet = true }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            .listRowBackground(theme.panel)

            Section("Appearance") {
                NavigationLink {
                    ThemesView()
                } label: {
                    LabeledContent("Theme") {
                        ThemeNameLabel()
                    }
                }
            }
            .listRowBackground(theme.panel)

            Section("Keywords") {
                NavigationLink("Keyword Settings") {
                    KeywordSettingsView(viewModel: viewModel)
                }
            }
            .listRowBackground(theme.panel)

            Section("Compose") {
                NavigationLink("Signature") {
                    SignatureSettingsView()
                }
            }
            .listRowBackground(theme.panel)

            Section {
                Toggle("Enable system notifications", isOn: $viewModel.systemNotificationsEnabled)
                LabeledContent("Delivery Mode", value: viewModel.deliveryMode)
                NavigationLink("Notification History") {
                    NotificationHistoryView()
                }
                Button("Fix Notifications") {
                    Task { await viewModel.repairNotifications() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(viewModel.isRepairingNotifications)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Checks notification permission, refreshes this device's push token, and re-registers it with the server.")
            }
            .listRowBackground(theme.panel)

            Section("Security") {
                NavigationLink("Security Settings") {
                    SecuritySettingsView()
                }
            }
            .listRowBackground(theme.panel)

            Section {
                Toggle("Sync with Apple Contacts", isOn: $viewModel.exportContactsToSystem)
                if viewModel.contactsExportDenied {
                    Text("Contacts access is denied for KyPost.")
                        .font(AppFont.ui(13))
                        .foregroundStyle(theme.secondaryInk)
                    Button("Open Settings") { viewModel.openContactsPrivacySettings() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if viewModel.exportContactsToSystem {
                    Button("Re-export Missing Contacts") {
                        Task { await viewModel.reexportMissingContacts() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                if viewModel.hasExportedContacts {
                    Button("Remove Exported Contacts") {
                        Task { await viewModel.removeExportedContacts() }
                    }
                        .buttonStyle(DangerButtonStyle())
                }
            } header: {
                Text("Contacts")
            } footer: {
                Text("Contacts sync both ways: new cards you add in Apple Contacts are imported, matching contacts (same email) are linked instead of duplicated, and only cards created or imported by KyPost are ever updated or removed.")
            }
            .listRowBackground(theme.panel)

            Section {
                NavigationLink("My QR Code") {
                    MyPgpQrCodeView()
                }
            } header: {
                Text("Encryption")
            } footer: {
                Text("Show your public key as a QR code for someone to scan in person. To add someone else's key, use Scan Contact Key on the Contacts screen.")
            }
            .listRowBackground(theme.panel)

            Section("About") {
                NavigationLink("About") {
                    AboutView()
                }
            }
            .listRowBackground(theme.panel)

            if let message = viewModel.statusMessage {
                Section {
                    Text(message)
                        .font(AppFont.ui(13))
                        .foregroundStyle(theme.ink)
                }
                .listRowBackground(theme.panel)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Settings")
        .onAppear { viewModel.refreshContactsExportState() }
        .sheet(isPresented: $showPairingSheet) {
            PushPairingView(initialParams: nil)
                .environment(\.theme, theme)
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

/// Small helper so the settings row shows the live theme name.
private struct ThemeNameLabel: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        Text(themeManager.themeName)
    }
}
