//
//  SettingsViewModel.swift
//  KyPost
//
//  Settings state: relay pairing status, notifications,
//  keyword visibility. Mail flows exclusively through the paired relay.
//

import Foundation
import Observation
import os
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// The Connection section's display state. Text only: nothing that reaches
/// the relay, registers a device or authenticates is derived from it.
nonisolated struct PairingDisplay: Equatable, Sendable {
    let serverHost: String
    let deviceId: String?
    /// The account address, when known. A stored pairing carries only an
    /// opaque `sub`, so this is nil outside the screenshot build.
    let account: String?
}

@Observable
@MainActor
final class SettingsViewModel {
    private let securePairingStore: SecurePairingStore
    private let pushSettingsStore: PushSettingsStore
    /// Only to erase a desktop session token an older build left (unpair).
    private let desktopSessionStore: DesktopSessionStore
    private let mailRepository: MailRepository
    private let keywordRepository: KeywordRepository
    private let contactsSettingsStore: ContactsSettingsStore
    private let systemContactsExporter: SystemContactsExporter
    private let deviceRegistrationService: DeviceRegistrationService
    private let deregisterDeviceUseCase: DeregisterDeviceUseCase
    private let pushNotificationDispatcher: PushNotificationDispatcher
    /// The sealed OpenPGP envelope, so unpairing destroys it. Optional for the
    /// same reason `appLockManager` is: existing tests build this view model
    /// without one.
    private let enrollmentVault: EnrollmentVault?
    /// Re-authentication for the destructive actions on this screen. Optional
    /// so existing call sites and tests that don't exercise the lock keep
    /// working; nil means "no lock configured", i.e. proceed.
    private let appLockManager: AppLockManager?
    private let pushRepository: PushRepository?
    private let recipientPinStore: RecipientPinStore?
    private let mailSignatureStore: MailSignatureStore?

    var systemNotificationsEnabled: Bool {
        didSet { pushSettingsStore.systemNotificationsEnabled = systemNotificationsEnabled }
    }

    /// "Export to Apple Contacts" toggle. Enabling prompts for Contacts
    /// access first; when denied the toggle flips back with guidance.
    var exportContactsToSystem: Bool {
        didSet {
            guard !suppressExportToggle, exportContactsToSystem != oldValue else { return }
            Task { await handleExportToggleChanged(exportContactsToSystem) }
        }
    }
    /// Re-entrancy guard so flipping the toggle back after a denial doesn't
    /// trigger another handleExportToggleChanged pass.
    @ObservationIgnored private var suppressExportToggle = false
    private(set) var contactsExportDenied = false
    private(set) var hasExportedContacts = false

    private(set) var statusMessage: String?
    private(set) var keywordSettings: [KeywordSetting] = []
    /// Whether the inbox tab strip leads with All (iOS; the macOS sidebar's
    /// Inbox row is the folder itself).
    private(set) var allTabVisible = true
    /// Runs after the pairing is cleared, for account-scoped state outside
    /// this view model — the inbox's held list actions, rows on screen, and
    /// in-flight refreshes (`InboxViewModel.forgetAccount`).
    private let onUnpaired: (() -> Void)?
    /// `SingletonGraph.erasePreservedStoreStep`: a store file kept under an
    /// in-memory session belongs to the account being left too.
    private let erasePreservedStore: (() -> Bool)?
    /// What Settings → Connection shows instead of the stored pairing. Set
    /// only by the DEBUG screenshot graph (`SingletonGraph.pairingDisplayOverride`);
    /// display text and nothing else — `isPaired`, unpair, Fix Notifications
    /// and every relay path still read `securePairingStore`.
    private let pairingDisplayOverride: PairingDisplay?

    init(
        securePairingStore: SecurePairingStore,
        pushSettingsStore: PushSettingsStore,
        desktopSessionStore: DesktopSessionStore,
        mailRepository: MailRepository,
        keywordRepository: KeywordRepository,
        contactsSettingsStore: ContactsSettingsStore,
        systemContactsExporter: SystemContactsExporter,
        deviceRegistrationService: DeviceRegistrationService,
        deregisterDeviceUseCase: DeregisterDeviceUseCase,
        pushNotificationDispatcher: PushNotificationDispatcher,
        erasePreservedStore: (() -> Bool)?,
        enrollmentVault: EnrollmentVault? = nil,
        appLockManager: AppLockManager? = nil,
        pushRepository: PushRepository? = nil,
        recipientPinStore: RecipientPinStore? = nil,
        mailSignatureStore: MailSignatureStore? = nil,
        onUnpaired: (() -> Void)? = nil,
        pairingDisplayOverride: PairingDisplay? = nil
    ) {
        self.securePairingStore = securePairingStore
        self.pushSettingsStore = pushSettingsStore
        self.desktopSessionStore = desktopSessionStore
        self.mailRepository = mailRepository
        self.keywordRepository = keywordRepository
        self.contactsSettingsStore = contactsSettingsStore
        self.systemContactsExporter = systemContactsExporter
        self.deviceRegistrationService = deviceRegistrationService
        self.deregisterDeviceUseCase = deregisterDeviceUseCase
        self.pushNotificationDispatcher = pushNotificationDispatcher
        self.erasePreservedStore = erasePreservedStore
        self.enrollmentVault = enrollmentVault
        self.appLockManager = appLockManager
        self.pushRepository = pushRepository
        self.recipientPinStore = recipientPinStore
        self.mailSignatureStore = mailSignatureStore
        self.onUnpaired = onUnpaired
        self.pairingDisplayOverride = pairingDisplayOverride
        systemNotificationsEnabled = pushSettingsStore.systemNotificationsEnabled
        exportContactsToSystem = contactsSettingsStore.exportToSystemContactsEnabled
    }

    // MARK: - Pairing status

    var isPaired: Bool { securePairingStore.isPaired }

    var pairedServerHost: String? {
        guard let pairing = try? securePairingStore.loadPairing() else { return nil }
        return URL(string: pairing.srv)?.host() ?? pairing.srv
    }

    /// What the Connection section renders: the stored pairing, or the demo
    /// build's display-only stand-in. Nil reads as "Not paired". Views use
    /// this; actions keep using `isPaired`.
    var pairingDisplay: PairingDisplay? {
        if let pairingDisplayOverride { return pairingDisplayOverride }
        guard let pairing = try? securePairingStore.loadPairing() else { return nil }
        return PairingDisplay(
            serverHost: URL(string: pairing.srv)?.host() ?? pairing.srv,
            deviceId: pairing.lastDeviceId,
            account: nil
        )
    }

    var deliveryMode: String {
        pushSettingsStore.deliveryMode?.rawValue.capitalized ?? "Push"
    }

    /// Re-authenticates before a destructive action. Preferences is reachable
    /// from the menu bar while the app lock is engaged, so these need the same
    /// gate that turning the lock off already has.
    private func confirmDestructive(_ reason: String) async -> Bool {
        guard let appLockManager else { return true }
        return await appLockManager.confirmWithDeviceAuth(reason: reason)
    }

    func unpair() async {
        // Clearing the pairing also clears the pinned SPKI hash, so the next
        // pairing re-arms trust on whatever certificate is presented. That is
        // as destructive as turning the lock off, and is gated the same way.
        guard await confirmDestructive(String(localized: "Remove this device's pairing")) else {
            return
        }
        _ = await deregisterDeviceUseCase()
        // A sign-on still in flight would otherwise re-pair right after this.
        AppEnvironment.postSessionReset()
        // A desktop session token an older build stored goes with it.
        let pairingCleared = (try? securePairingStore.clear()) != nil
            && (try? desktopSessionStore.clear()) != nil
        // Everything else the account left on this device — the same list a
        // pairing to another account runs.
        let tornDown = await AccountTeardown(
            erasePreservedStore: erasePreservedStore,
            enrollmentVault: enrollmentVault,
            pushRepository: pushRepository,
            recipientPinStore: recipientPinStore,
            mailSignatureStore: mailSignatureStore,
            mailRepository: mailRepository,
            forgetInbox: onUnpaired
        ).run()
        statusMessage = pairingCleared && tornDown
            ? "Pairing removed"
            : "Pairing removed, but some of this account's data could not be erased from this device."
    }

    func testConnection() async {
        statusMessage = "Testing…"
        do {
            let folders = try await mailRepository.listFolders()
            statusMessage = "Connected — \(folders.count) folder(s)"
        } catch MailSourceError.notPaired {
            statusMessage = "Not paired — pair this device first."
        } catch {
            statusMessage = "Connection failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Notification repair

    /// True while "Fix Notifications" runs, so the button can't be re-pressed
    /// into overlapping repairs.
    private(set) var isRepairingNotifications = false

    /// "Fix Notifications": walks the whole push setup in order — notification
    /// permission, APNs token, server registration — and reports the first
    /// broken step. Registration normally repeats silently on foreground, so
    /// this exists to surface what that silence hides: after an app update the
    /// APNs token can rotate while the stored pairing token has expired, the
    /// re-register 401s, and the server keeps (or has already dropped) a dead
    /// token. Only re-pairing mints a new pairing token, so that case ends in
    /// a "re-pair" message rather than a fix.
    func repairNotifications() async {
        guard !isRepairingNotifications else { return }
        isRepairingNotifications = true
        defer { isRepairingNotifications = false }

        guard isPaired else {
            statusMessage = "Not paired — pair this device first."
            return
        }
        statusMessage = "Fixing notifications…"

        // Previously-denied permission returns false here without prompting.
        guard await pushNotificationDispatcher.requestAuthorization() else {
            statusMessage = "Notifications are turned off for KyPost — allow them under "
                + "System Settings > Notifications, then try again."
            return
        }

        guard let token = await refreshedDeviceToken() else {
            statusMessage = "Apple hasn't issued a push token for this device — "
                + "check your internet connection and try again."
            return
        }

        switch await deviceRegistrationService.reregisterIfPaired(deviceToken: token) {
        case .success:
            statusMessage = "Notifications re-registered with "
                + "\(pairedServerHost ?? "the server") — delivery mode \(deliveryMode)."
        case .unauthorized:
            statusMessage = "The server no longer accepts this device's pairing — "
                + "re-pair from the web app to fix notifications."
        case .backendMisconfigured:
            statusMessage = "The server isn't configured for pairing — "
                + "notifications can't be fixed from this device."
        case .failure(let text):
            statusMessage = "Could not re-register: \(text)"
        case nil:
            statusMessage = "Not paired — pair this device first."
        }
    }

    /// Re-requests APNs registration and waits briefly for the delegate to
    /// store the token, in case it rotated with an app update or never
    /// arrived at launch. If a rotated token lands after the wait, the
    /// delegate's own re-registration still carries it to the server.
    private func refreshedDeviceToken() async -> String? {
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #elseif os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
        for _ in 0..<8 where pushSettingsStore.lastDeviceToken == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return pushSettingsStore.lastDeviceToken
    }

    // MARK: - Apple Contacts export

    func refreshContactsExportState() {
        contactsExportDenied = systemContactsExporter.isDenied
        hasExportedContacts = systemContactsExporter.hasExportedContacts()
    }

    /// "Re-export Missing Contacts": runs a full reconcile pass, which
    /// recreates cards that were deleted outside the app (removed in
    /// Contacts.app, or lost with an account change).
    func reexportMissingContacts() async {
        let summary = await systemContactsExporter.reconcileAll()
        hasExportedContacts = systemContactsExporter.hasExportedContacts()
        statusMessage = "Re-exported \(summary.created + summary.updated) contact(s) to Apple Contacts"
    }

    /// Removes every card the app created in Apple Contacts and forgets the
    /// links; separate from the toggle, which keeps exported cards.
    func removeExportedContacts() async {
        guard await confirmDestructive(
            String(localized: "Remove exported contacts from Apple Contacts")
        ) else { return }
        let removed = await systemContactsExporter.removeAllExported().deleted
        hasExportedContacts = systemContactsExporter.hasExportedContacts()
        statusMessage = "Removed \(removed) exported contact(s) from Apple Contacts"
    }

    func openContactsPrivacySettings() {
        #if os(macOS)
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        ) else { return }
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    private func handleExportToggleChanged(_ enabled: Bool) async {
        guard enabled else {
            contactsSettingsStore.exportToSystemContactsEnabled = false
            statusMessage = "Contacts export turned off — exported cards were kept."
            return
        }
        guard await systemContactsExporter.requestAccessIfNeeded() else {
            suppressExportToggle = true
            exportContactsToSystem = false
            suppressExportToggle = false
            contactsExportDenied = true
            statusMessage = "Contacts access is denied. Allow KyPost under "
                + "System Settings > Privacy & Security > Contacts."
            return
        }
        contactsExportDenied = false
        contactsSettingsStore.exportToSystemContactsEnabled = true
        let summary = await systemContactsExporter.reconcileAll()
        hasExportedContacts = systemContactsExporter.hasExportedContacts()
        statusMessage = "Exported \(summary.created + summary.updated) contact(s) to Apple Contacts"
    }

    // MARK: - Keyword visibility (spec §9 KeywordSettingsView)

    func loadKeywordSettings() async {
        let cached = (try? await mailRepository.cachedFolder(
            Config.defaultFolder,
            limit: 200
        )) ?? []
        keywordSettings = keywordRepository.allSettings(from: cached)
        allTabVisible = keywordRepository.isAllTabVisible
    }

    func setAllTabVisible(_ visible: Bool) {
        keywordRepository.isAllTabVisible = visible
        allTabVisible = visible
    }

    func setKeywordVisible(_ visible: Bool, for keyword: String) {
        keywordRepository.setVisible(visible, for: keyword)
        if let index = keywordSettings.firstIndex(where: { $0.name == keyword }) {
            keywordSettings[index].visible = visible
        }
    }

    func moveKeywords(from source: IndexSet, to destination: Int) {
        keywordSettings.move(fromOffsets: source, toOffset: destination)
        keywordRepository.setOrder(keywordSettings.map(\.name))
    }
}
