//
//  ContactsSettingsStore.swift
//  KyPost
//
//  UserDefaults-backed contacts preferences: the "Sync with Apple Contacts"
//  toggle read by SystemContactsExporter before every pass, and the consent
//  given on the contact-sync disclosure (`ContactSyncDisclosure`).
//

import CryptoKit
import Foundation

final class ContactsSettingsStore {
    private enum Key {
        static let exportToSystemEnabled = "contacts.exportToSystemEnabled"
        static let syncConsentServer = "contacts.syncConsentServer"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The stored toggle. Read `isSystemSyncOn(forServer:)` instead: the
    /// toggle alone, without consent for the paired server, is not "on".
    var exportToSystemContactsEnabled: Bool {
        get { defaults.object(forKey: Key.exportToSystemEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.exportToSystemEnabled) }
    }

    /// Whether the user agreed, on the disclosure, to send contacts to
    /// `server` (`ContactSyncDisclosure.serverName`). One server at a time:
    /// pairing another needs fresh consent. Stored hashed, so these defaults
    /// never name the server.
    func hasSyncConsent(forServer server: String?) -> Bool {
        guard let server, let stored = defaults.string(forKey: Key.syncConsentServer) else { return false }
        return stored == Self.digest(server)
    }

    func recordSyncConsent(forServer server: String) {
        defaults.set(Self.digest(server), forKey: Key.syncConsentServer)
    }

    func forgetSyncConsent() {
        defaults.removeObject(forKey: Key.syncConsentServer)
    }

    /// What "Sync with Apple Contacts" reads as: on only with consent for the
    /// paired server. An install that turned it on before the disclosure
    /// existed reads as off until the user agrees.
    func isSystemSyncOn(forServer server: String?) -> Bool {
        exportToSystemContactsEnabled && hasSyncConsent(forServer: server)
    }

    private static func digest(_ server: String) -> String {
        SHA256.hash(data: Data(server.lowercased().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
