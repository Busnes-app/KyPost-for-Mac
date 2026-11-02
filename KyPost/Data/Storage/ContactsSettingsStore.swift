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
        static let syncConsentToken = "contacts.syncConsentToken"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The stored toggle. Read `isSystemSyncOn(for:)` instead: the
    /// toggle alone, without consent for the paired server, is not "on".
    var exportToSystemContactsEnabled: Bool {
        get { defaults.object(forKey: Key.exportToSystemEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.exportToSystemEnabled) }
    }

    /// Whether the user agreed, on the disclosure, to send contacts to
    /// `relay` (its `consentKey`: scheme, host, port and path). One relay at
    /// a time: pairing another needs fresh consent. Stored hashed, so these
    /// defaults never name the server.
    func hasSyncConsent(for relay: ContactSyncRelay?) -> Bool {
        guard let relay, let stored = defaults.string(forKey: Key.syncConsentServer) else { return false }
        return stored == Self.digest(relay.consentKey)
    }

    func recordSyncConsent(for relay: ContactSyncRelay) {
        defaults.set(Self.digest(relay.consentKey), forKey: Key.syncConsentServer)
        defaults.set(UUID().uuidString, forKey: Key.syncConsentToken)
    }

    func forgetSyncConsent() {
        defaults.removeObject(forKey: Key.syncConsentServer)
        defaults.removeObject(forKey: Key.syncConsentToken)
    }

    /// Names one Agree for `relay`: its consent key's digest and the token
    /// recorded with it, new each time consent is recorded. Nil without
    /// consent for `relay`. Stamped on every Apple Contacts import
    /// (`Contact.importConsent`); an import stops, and an unsent card stays
    /// unsent, once it changes (`SystemContactsExporter.mayUpload`).
    func importConsentStamp(for relay: ContactSyncRelay?) -> String? {
        guard hasSyncConsent(for: relay),
              let server = defaults.string(forKey: Key.syncConsentServer),
              let token = defaults.string(forKey: Key.syncConsentToken)
        else { return nil }
        return "\(server)/\(token)"
    }

    /// What "Sync with Apple Contacts" reads as: on only with consent for the
    /// paired relay. An install that turned it on before the disclosure
    /// existed reads as off until the user agrees.
    func isSystemSyncOn(for relay: ContactSyncRelay?) -> Bool {
        exportToSystemContactsEnabled && hasSyncConsent(for: relay)
    }

    private static func digest(_ key: String) -> String {
        // Not lowercased: the key's path is case-sensitive, and its scheme
        // and host are lowercased already.
        SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
