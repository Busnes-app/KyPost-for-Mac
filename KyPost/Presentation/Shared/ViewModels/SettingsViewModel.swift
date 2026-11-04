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

    /// "Sync with Apple Contacts" toggle. It only asks: turning it on shows
    /// the disclosure (`contactSyncDisclosure`) and turning it off asks to
    /// confirm (`confirmingStopContactSync`); it stays where it was until
    /// the user answers.
    var exportContactsToSystem: Bool {
        didSet {
            guard !suppressExportToggle, exportContactsToSystem != oldValue else { return }
            setExportToggle(oldValue)
            if oldValue {
                confirmingStopContactSync = true
            } else {
                askToSyncContacts()
            }
        }
    }
    /// Re-entrancy guard so setting the toggle from code doesn't ask again.
    @ObservationIgnored private var suppressExportToggle = false
    /// The disclosure, while shown. Nothing is asked of iOS and nothing is
    /// sent until `agreeToContactSync`.
    var contactSyncDisclosure: ContactSyncDisclosure?
    var confirmingStopContactSync = false
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
    /// Bootstrap's cached custody and aliases (`PgpSendService.forgetAccount`).
    private let pgpSendService: PgpSendService?
    /// What Settings → Connection shows instead of the stored pairing. Set
    /// only by the DEBUG screenshot graph (`SingletonGraph.pairingDisplayOverride`);
    /// display text and nothing else — `isPaired`, unpair, Fix Notifications
    /// and every relay path still read `securePairingStore`.
    private let pairingDisplayOverride: PairingDisplay?
    /// `AccountTeardown.legacyHTTPCache`.
    private let legacyHTTPCache: URLCache
    /// For Remove Pairing's optional "remove contacts" (owner Q1). Nil in
    /// tests that do not exercise it.
    private let contactSyncRepository: ContactSyncRepository?
    /// Contact changes not yet synced, counted when the unpair question
    /// opens (`prepareUnpair`), so it can warn before they are removed.
    private(set) var unsyncedContactChanges = 0

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
        pgpSendService: PgpSendService? = nil,
        onUnpaired: (() -> Void)? = nil,
        pairingDisplayOverride: PairingDisplay? = nil,
        legacyHTTPCache: URLCache = .shared,
        contactSyncRepository: ContactSyncRepository? = nil
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
        self.pgpSendService = pgpSendService
        self.onUnpaired = onUnpaired
        self.pairingDisplayOverride = pairingDisplayOverride
        self.legacyHTTPCache = legacyHTTPCache
        self.contactSyncRepository = contactSyncRepository
        systemNotificationsEnabled = pushSettingsStore.systemNotificationsEnabled
        exportContactsToSystem = contactsSettingsStore.isSystemSyncOn(
            for: Self.contactSyncRelay(securePairingStore, override: pairingDisplayOverride)
        )
    }

    // MARK: - Pairing status

    /// The pairing lives in the Keychain, which Observation cannot see.
    /// `isPaired` and `pairingDisplay` read this so that bumping it
    /// (`pairingDidChange`) redraws Settings; without it a pairing stored by
    /// the pairing sheet left "Not paired" on screen until a relaunch.
    private var pairingRevision = 0

    /// A pairing was stored (`.kyPostPaired`): re-read it.
    func pairingDidChange() {
        pairingRevision += 1
        refreshContactsExportState()
    }

    var isPaired: Bool {
        _ = pairingRevision
        return securePairingStore.isPaired
    }

    var pairedServerHost: String? {
        guard let pairing = try? securePairingStore.loadPairing() else { return nil }
        return URL(string: pairing.srv)?.host() ?? pairing.srv
    }

    /// What the Connection section renders: the stored pairing, or the demo
    /// build's display-only stand-in. Nil reads as "Not paired". Views use
    /// this; actions keep using `isPaired`.
    var pairingDisplay: PairingDisplay? {
        _ = pairingRevision
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

    /// Counts what "remove contacts" would lose, for the unpair question.
    func prepareUnpair() async {
        unsyncedContactChanges = await contactSyncRepository?.unsyncedChangeCount() ?? 0
    }

    /// - Parameter removingContacts: the user chose to remove this device's
    ///   contacts too (owner Q1: optional, never the default). Otherwise they
    ///   stay, and pairing another account asks before uploading them.
    func unpair(removingContacts: Bool = false) async {
        // Clearing the pairing also clears the pinned SPKI hash, so the next
        // pairing re-arms trust on whatever certificate is presented. That is
        // as destructive as turning the lock off, and is gated the same way.
        guard await confirmDestructive(String(localized: "Remove this device's pairing")) else {
            return
        }
        _ = await deregisterDeviceUseCase()
        // Kept contacts must stay known as this account's, so another
        // account is asked before they are uploaded to it.
        contactSyncRepository?.recordAccountIfUnknown()
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
            pgpSendService: pgpSendService,
            forgetInbox: onUnpaired,
            legacyHTTPCache: legacyHTTPCache
        ).run()
        var contactsNote: String?
        if removingContacts, let contactSyncRepository {
            do {
                try await contactSyncRepository.removeContactsFromThisDevice()
            } catch let incomplete as ContactRemovalIncomplete {
                contactsNote = incomplete.message
            } catch {
                contactsNote = "Contacts could not be removed: \(error.localizedDescription)"
            }
        }
        let pairingNote = pairingCleared && tornDown
            ? "Pairing removed"
            : "Pairing removed, but some of this account's data could not be erased from this device."
        statusMessage = contactsNote.map { "\(pairingNote.hasSuffix(".") ? pairingNote : pairingNote + ".") \($0)" }
            ?? pairingNote
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
        case .approvalRequired, .awaitingApproval, .notApproved:
            // reregisterIfPaired turns a 202 into .failure; never reached.
            statusMessage = "Could not re-register — pair this device again from the web app."
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

    /// The relay contact sync sends to, which consent is recorded against;
    /// nil when unpaired. The screenshot build names its display-only
    /// server, which no sync path ever reads.
    var contactSyncRelay: ContactSyncRelay? {
        _ = pairingRevision
        return Self.contactSyncRelay(securePairingStore, override: pairingDisplayOverride)
    }

    /// The relay's name, as the disclosure and the Contacts row show it.
    var contactSyncServer: String? { contactSyncRelay?.name }

    private static func contactSyncRelay(_ store: SecurePairingStore, override: PairingDisplay?) -> ContactSyncRelay? {
        if let override { return ContactSyncRelay(srv: "https://\(override.serverHost)") }
        guard let pairing = try? store.loadPairing() else { return nil }
        return ContactSyncRelay(srv: pairing.srv)
    }

    /// The Contacts row's state line, as on Android.
    var contactSyncStatus: String {
        if exportContactsToSystem, let server = contactSyncServer {
            return String(localized: "On. Contacts are sent to \(server).")
        }
        return String(localized: "Off. Turn on to send this \(ContactSyncDisclosure.thisDevice)'s contacts to your KyPost server.")
    }

    func refreshContactsExportState() {
        // Consent belongs to one server: a pairing changed elsewhere reads as
        // off here until the user agrees for the new one.
        setExportToggle(contactsSettingsStore.isSystemSyncOn(for: contactSyncRelay))
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

    private func setExportToggle(_ on: Bool) {
        suppressExportToggle = true
        exportContactsToSystem = on
        suppressExportToggle = false
    }

    private func askToSyncContacts() {
        guard let relay = contactSyncRelay else {
            statusMessage = String(localized: "Pair with your KyPost server first. Contact sync sends your contacts to that server.")
            return
        }
        contactSyncDisclosure = ContactSyncDisclosure(relay: relay)
    }

    /// Not now: the toggle stays off and nothing is recorded.
    func declineContactSync() {
        contactSyncDisclosure = nil
    }

    /// Agree: consent for the server the disclosure named, then today's
    /// flow — the Contacts permission prompt, then a reconcile.
    func agreeToContactSync() async {
        guard let disclosure = contactSyncDisclosure else { return }
        contactSyncDisclosure = nil
        // The pairing may have changed while the disclosure was open: the
        // user agreed to the relay it named, not to whichever is paired now.
        guard disclosure.relay == contactSyncRelay else { return }
        contactsSettingsStore.recordSyncConsent(for: disclosure.relay)
        // The disclosure says cards already in Apple Contacts are not sent.
        systemContactsExporter.resetImportBaseline()
        guard await systemContactsExporter.requestAccessIfNeeded() else {
            contactsExportDenied = true
            statusMessage = "Contacts access is denied. Allow KyPost under "
                + "System Settings > Privacy & Security > Contacts."
            return
        }
        contactsExportDenied = false
        contactsSettingsStore.exportToSystemContactsEnabled = true
        setExportToggle(true)
        let summary = await systemContactsExporter.reconcileAll()
        hasExportedContacts = systemContactsExporter.hasExportedContacts()
        statusMessage = "Exported \(summary.created + summary.updated) contact(s) to Apple Contacts"
    }

    var stopContactSyncMessage: String {
        let server = contactSyncServer ?? String(localized: "your KyPost server")
        return String(localized: "KyPost stops syncing this \(ContactSyncDisclosure.thisDevice)'s contacts with \(server). Cards in Apple Contacts stay; Remove Exported Contacts deletes the ones KyPost added. Contacts already on your server stay there until you delete them.")
    }

    /// Turn off, confirmed: consent is forgotten and nothing more is read
    /// from or written to Apple Contacts. Cards are kept, as before; Remove
    /// Exported Contacts deletes the ones KyPost made.
    func stopContactSync() {
        confirmingStopContactSync = false
        contactsSettingsStore.exportToSystemContactsEnabled = false
        contactsSettingsStore.forgetSyncConsent()
        setExportToggle(false)
        statusMessage = String(localized: "Contact sync turned off. Cards in Apple Contacts were kept.")
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
