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

struct ContactSyncDisclosure: Equatable, Identifiable {
    struct Part: Equatable, Hashable {
        let title: String
        let body: String
    }

    /// The paired server, as `serverName(fromSrv:)` names it.
    let server: String
    /// "iPhone", "iPad" or "Mac".
    let device: String

    var id: String { server }

    init(server: String, device: String = ContactSyncDisclosure.thisDevice) {
        self.server = server
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
    /// of the pairing's `srv`, lowercased. Consent is recorded against it.
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
