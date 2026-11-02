//
//  ContactSyncDisclosure.swift
//  KyPost
//
//  What the user agrees to before contacts leave this device: what is sent,
//  to which server, how that server uses them, and how long it keeps them.
//  Settings → "Sync with Apple Contacts" and the Contacts screen's Sync show
//  the same text. Port of KyPost for Android's `contacts_access_disclosure`
//  (#282), with the server's uses taken from KyPost-Server itself; change
//  this when the server's use of contacts changes.
//

import Foundation
#if os(iOS)
import UIKit
#endif

/// The relay contacts are sent to. `name` is what people read; consent is
/// recorded against `consentKey`, the whole base URL, so another deployment
/// on the same host (another port or base path) needs its own Agree.
struct ContactSyncRelay: Equatable {
    /// The host, as Settings → Connection and the disclosure show it.
    /// Display only: never compare it as consent.
    let name: String
    /// `canonicalBaseURL(fromSrv:)` of the pairing's `srv`.
    let consentKey: String

    init(srv: String) {
        name = ContactSyncDisclosure.serverName(fromSrv: srv)
        consentKey = Self.canonicalBaseURL(fromSrv: srv)
    }

    /// Scheme and host lowercased, the effective port always written out
    /// (443 for https, 80 for http), the path kept as is but for trailing
    /// slashes. Query, fragment and user info are dropped: they don't pick
    /// a deployment.
    static func canonicalBaseURL(fromSrv srv: String) -> String {
        let trimmed = srv.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty
        else { return trimmed }
        let port = components.port ?? ["https": 443, "http": 80][scheme]
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")\(path)"
    }
}

struct ContactSyncDisclosure: Equatable, Identifiable {
    struct Part: Equatable, Hashable {
        let title: String
        let body: String
    }

    /// The paired relay. Agree records consent for it.
    let relay: ContactSyncRelay
    /// "iPhone", "iPad" or "Mac".
    let device: String

    /// The relay's name, as the text shows it.
    var server: String { relay.name }

    var id: String { relay.consentKey }

    init(relay: ContactSyncRelay, device: String = ContactSyncDisclosure.thisDevice) {
        self.relay = relay
        self.device = device
    }

    static let title = String(localized: "Send your contacts to your KyPost server?")

    var lead: String {
        String(localized: "KyPost syncs your contacts with your KyPost server at \(server), so your address book stays the same on your other devices and in KyPost mail.")
    }

    var parts: [Part] {
        [
            Part(
                title: String(localized: "What is sent"),
                body: String(localized: "Contacts you add or change in KyPost. With Sync with Apple Contacts on, also cards you add in Apple Contacts on this \(device) after you agree: name, email addresses, phone numbers, postal addresses, birthday, company and the other details on the card. Cards already in Apple Contacts are not sent. Your KyPost contacts are also copied into Apple Contacts, where other apps with contacts access can read them.")
            ),
            Part(
                title: String(localized: "Where"),
                body: String(localized: "Only to your server at \(server). The KyPost developer never receives them. The server stores them unencrypted, so whoever runs it can read them.")
            ),
            Part(
                title: String(localized: "How they are used"),
                body: String(localized: "Your server uses them to sync your address book to your other devices and contacts apps, suggest recipients as you type, check signatures on mail from your contacts, sort their mail into Primary, and find encryption keys. When you send encrypted mail to someone with no key saved, the server asks their mail domain and keys.openpgp.org for one, sending that address. It also adds people whose keys it finds. Your contacts are not shared otherwise, and not used for ads or anything else.")
            ),
            Part(
                title: String(localized: "How long"),
                body: String(localized: "They stay on your server until you delete them there. Turning sync off does not delete them. A deleted contact's key fingerprint is kept for up to 30 days, and backups your server makes keep older copies.")
            ),
            Part(
                title: String(localized: "Your choice"),
                body: String(localized: "Nothing from Apple Contacts is sent unless you tap Agree and Sync with Apple Contacts is on. You can turn it off any time in Settings.")
            ),
        ]
    }

    /// The whole disclosure as one string, in reading order.
    var text: String {
        ([lead] + parts.map { "\($0.title)\n\($0.body)" }).joined(separator: "\n\n")
    }

    /// The paired server's name, as Settings → Connection shows it: the host
    /// of the pairing's `srv`, lowercased. Display only: consent is recorded
    /// against `ContactSyncRelay.consentKey`.
    static func serverName(fromSrv srv: String) -> String {
        (URL(string: srv)?.host() ?? srv).lowercased()
    }

    static var thisDevice: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}
