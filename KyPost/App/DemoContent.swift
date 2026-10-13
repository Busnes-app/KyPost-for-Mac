//
//  DemoContent.swift
//  KyPost
//
//  Fabricated mailbox for App Store screenshots. DEBUG only, and reached
//  only when the process is launched with `-KyPostDemo`; a Release build
//  does not contain this file's contents at all.
//
//  Why it exists: the store listing needs an inbox, and the only inbox on a
//  developer's machine is that developer's real mail. Every name, address,
//  subject and body below is invented.
//
//  It is also the only way to capture the app offline. `MailRepository`
//  refuses to load anything without a stored pairing, so an unpaired build
//  renders "Pair this device (Settings → Connection) to load mail" over the
//  screen we are trying to photograph. DemoMailSource stands in for the
//  relay so the capture never touches the network or the Keychain.
//

#if DEBUG

import Foundation
import os

enum DemoContent {
    /// Set by the screenshot runner; absent in an ordinary Debug run.
    nonisolated static let launchArgument = "-KyPostDemo"
    /// Optional follow-on argument selecting a screen that has no navigable
    /// route (currently only `mfa`, which normally arrives by push).
    static let screenArgument = "-KyPostDemoScreen"

    nonisolated static var isEnabled: Bool {
        isEnabled(in: ProcessInfo.processInfo.arguments)
    }

    nonisolated static func isEnabled(in arguments: [String]) -> Bool {
        arguments.contains(launchArgument)
    }

    /// The value after `-KyPostDemoScreen`, or nil. Nil without
    /// `-KyPostDemo` too: the screen argument alone must not present
    /// fabricated content in an ordinary Debug run.
    static var requestedScreen: String? {
        requestedScreen(in: ProcessInfo.processInfo.arguments)
    }

    static func requestedScreen(in arguments: [String]) -> String? {
        guard isEnabled(in: arguments),
              let index = arguments.firstIndex(of: screenArgument),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    // MARK: - Isolated stores

    /// Everything the demo graph persists goes here instead of the app's
    /// own defaults, Keychain items and device key, so a demo launch can
    /// neither read nor change the real pairing, settings, contact links or
    /// credentials. The defaults suite is emptied once per process, so every
    /// capture starts from a fresh install's state.
    private static let isolatedPrefix = (Bundle.main.bundleIdentifier ?? "org.kysecurity.mail") + ".demo"

    static let isolatedDefaults: UserDefaults = {
        let suite = isolatedPrefix
        // Never fall back to `.standard`: that is the domain being protected.
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("The demo build could not open its own defaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }()

    static let isolatedKeychain = KeychainStorage(service: isolatedPrefix + ".secure")
    static let isolatedGatedStore = GatedCredentialStore(service: isolatedPrefix + ".gated")
    static let isolatedVaultKeyTag = isolatedPrefix + ".enrollment.deviceKey"

    /// Fixed clock so a rerun produces identical screenshots.
    private static let now = Date(timeIntervalSince1970: 1_788_260_400)

    private static func ago(_ minutes: Int) -> Date {
        now.addingTimeInterval(-Double(minutes) * 60)
    }

    static let accountAddress = "avery.lang@kypost.example"

    static let emails: [Email] = [
        Email(
            serverId: "demo-1",
            folder: StandardFolder.inbox,
            senderName: "Priya Raghavan",
            senderEmail: "priya@northgatelabs.example",
            subject: "Re: Q3 rollout — signed off",
            body: """
            Avery,

            Legal cleared the last two items this morning, so the rollout is approved end to end. I've attached nothing on purpose — the final plan lives in the shared workspace and I'd rather it stayed there.

            One ask: can you take the Thursday walkthrough? I'm in Lisbon until the 14th and the timezone maths is not in my favour.

            Priya
            """,
            sentTo: "Avery Lang <\(accountAddress)>",
            cc: "Devon Okafor <devon@northgatelabs.example>",
            keywords: ["Work"],
            receivedAt: ago(12),
            read: false,
            starred: true,
            bodyMode: "plain",
            pgpEncrypted: true,
            pgpSigned: true,
            pgpVerified: true,
            pgpSignerFingerprint: "9F2C 4B71 08DE 55A3 6C10  D4E8 7B29 A150 3F6D C842"
        ),
        Email(
            serverId: "demo-2",
            folder: StandardFolder.inbox,
            senderName: "Devon Okafor",
            senderEmail: "devon@northgatelabs.example",
            subject: "Key rotation is done — new fingerprint inside",
            body: """
            Rotated this morning as planned. The old key is revoked, not just retired, so anything still encrypting to it will fail loudly instead of quietly.

            New fingerprint: 4D71 A0C3 92FE 1B84 5520  E7A9 C318 66BD 04F2 9E5A

            Verify it out of band before you pin it. I'll be on the call at two if you'd rather read it back to me.

            — Devon
            """,
            sentTo: "Avery Lang <\(accountAddress)>",
            keywords: ["Work", "Security"],
            receivedAt: ago(96),
            read: false,
            starred: false,
            bodyMode: "plain",
            pgpEncrypted: true,
            pgpSigned: true,
            pgpVerified: true,
            pgpSignerFingerprint: "4D71 A0C3 92FE 1B84 5520  E7A9 C318 66BD 04F2 9E5A"
        ),
        Email(
            serverId: "demo-3",
            folder: StandardFolder.inbox,
            senderName: "Meridian Rail",
            senderEmail: "tickets@meridian.example",
            subject: "Your ticket: Lisbon → Porto",
            body: """
            Booking reference QK7-2210. Thursday 11 September.

            Departs Lisboa Oriente 08:15 from platform 4, arrives Porto Campanhã 11:02. Coach 4, seat 22A, window, facing forward.

            Show this message at the gate — the barcode is in the attached PDF, and staff can also look the booking up by reference if your phone has given up on you.

            Changes are free up to 60 minutes before departure, after which the fare is fixed. Refunds go back to the card that paid within five working days.

            Meridian Rail will never ask you for a password or a payment code by email.
            """,
            sentTo: "Avery Lang <\(accountAddress)>",
            keywords: ["Travel"],
            receivedAt: ago(340),
            read: true,
            starred: false,
            bodyMode: "plain",
            hasAttachments: true
        ),
        Email(
            serverId: "demo-4",
            folder: StandardFolder.inbox,
            senderName: "Harbourline Credit Union",
            senderEmail: "statements@harbourline.example",
            subject: "August statement is ready",
            body: """
            Your August statement is available in online banking.

            We will never ask you for a code, a password, or a one-time link by email. If a message claiming to be from us does, it is not from us.
            """,
            sentTo: "Avery Lang <\(accountAddress)>",
            keywords: ["Finance"],
            receivedAt: ago(510),
            read: true,
            starred: false,
            bodyMode: "plain",
            pgpEncrypted: true,
            pgpSigned: true,
            pgpVerified: true
        ),
        Email(
            serverId: "demo-5",
            folder: StandardFolder.inbox,
            senderName: "Sofia Marchetti",
            senderEmail: "sofia@baywood.example",
            subject: "Photos from the ridge walk",
            body: """
            Finally got round to sorting these. The one from the saddle at golden hour is worth the climb on its own.

            No rush on picking favourites — I'm keeping the originals.

            Sofia
            """,
            sentTo: "Avery Lang <\(accountAddress)>",
            keywords: ["Personal"],
            receivedAt: ago(720),
            read: true,
            starred: true,
            bodyMode: "plain",
            hasAttachments: true
        ),
        Email(
            serverId: "demo-6",
            folder: StandardFolder.inbox,
            senderName: "The Sunday Long Read",
            senderEmail: "hello@sundaylongread.example",
            subject: "Issue 214: the people who maintain the cables",
            body: """
            This week: the crews who splice undersea fibre, why a repair ship can take three weeks to reach a fault, and what happens to a country's traffic while it waits.

            Unsubscribe any time — the link is at the foot of every issue.
            """,
            sentTo: "Avery Lang <\(accountAddress)>",
            keywords: ["Newsletters"],
            receivedAt: ago(1_180),
            read: true,
            starred: false,
            bodyMode: "plain"
        ),
        Email(
            serverId: "demo-7",
            folder: StandardFolder.inbox,
            senderName: "Ines Varga",
            senderEmail: "ines@atlasrelay.example",
            subject: "Draft agreement — please review before Friday",
            body: """
            Attached is the redline from their counsel. Two clauses moved and one is new; I've flagged all three.

            I'd rather we talked through clause 9 than traded comments on it. Are you free Thursday afternoon?

            Ines
            """,
            sentTo: "Avery Lang <\(accountAddress)>",
            cc: "Priya Raghavan <priya@northgatelabs.example>",
            keywords: ["Work"],
            receivedAt: ago(1_450),
            read: true,
            starred: false,
            bodyMode: "plain",
            hasAttachments: true,
            pgpEncrypted: true,
            pgpSigned: true,
            pgpVerified: true
        ),
        Email(
            serverId: "demo-8",
            folder: StandardFolder.inbox,
            senderName: "Northgate Build",
            senderEmail: "ci@northgatelabs.example",
            subject: "main is green again (build 4482)",
            body: """
            The flake in the migration suite was a shared temp directory, not the migration. Fixed and green across all three runners.

            Nothing to do — this is the all-clear.
            """,
            sentTo: "Avery Lang <\(accountAddress)>",
            keywords: ["Work"],
            receivedAt: ago(1_610),
            read: true,
            starred: false,
            bodyMode: "plain"
        ),
        Email(
            serverId: "demo-9",
            folder: StandardFolder.inbox,
            senderName: "Kestrel Coffee",
            senderEmail: "orders@kestrelcoffee.example",
            subject: "Your subscription ships Tuesday",
            body: """
            Next box: 2 × 250g, Kiunyu AA and the Huila decaf you asked us to keep on rotation.

            Skip or swap from your account any time before Monday night.
            """,
            sentTo: "Avery Lang <\(accountAddress)>",
            keywords: ["Finance"],
            receivedAt: ago(2_050),
            read: true,
            starred: false,
            bodyMode: "plain"
        ),
        Email(
            serverId: "demo-11",
            folder: StandardFolder.inbox,
            senderName: "Harbourline Credit Union",
            senderEmail: "alerts@harbourline.example",
            subject: "Card ending 4417 used at Kestrel Coffee",
            body: """
            €4.80 at Kestrel Coffee, 08:22 today. Your balance is unchanged from what online banking shows.

            If this was not you, freeze the card from the app and call us on the number printed on it — not one from an email.
            """,
            sentTo: "Avery Lang <\(accountAddress)>",
            keywords: ["Finance"],
            receivedAt: ago(220),
            read: true,
            starred: false,
            bodyMode: "plain"
        ),
        Email(
            serverId: "demo-12",
            folder: StandardFolder.inbox,
            senderName: "Fjordhaus Lettings",
            senderEmail: "billing@fjordhaus.example",
            subject: "Invoice 2026-0841 — cabin, week of the 20th",
            body: """
            Attached is the invoice for the week of the 20th, due on arrival. The cleaning deposit is refundable and is not part of this total.

            Tomas has the keys; he will send the box code the morning you arrive.
            """,
            sentTo: "Avery Lang <\(accountAddress)>",
            keywords: ["Finance", "Travel"],
            receivedAt: ago(1_920),
            read: true,
            starred: false,
            bodyMode: "plain",
            hasAttachments: true
        ),
        Email(
            serverId: "demo-10",
            folder: StandardFolder.inbox,
            senderName: "Tomas Lindqvist",
            senderEmail: "tomas@fjordhaus.example",
            subject: "Cabin is yours the week of the 20th",
            body: """
            Confirmed with the owners. Key box code goes out the morning you arrive — I won't send it any earlier and definitely not by text.

            Bring boots. The track washed out in July and the repair is generous with the word "repair".

            Tomas
            """,
            sentTo: "Avery Lang <\(accountAddress)>",
            keywords: ["Personal", "Travel"],
            receivedAt: ago(2_600),
            read: true,
            starred: false,
            bodyMode: "plain"
        ),
    ]

    static let contacts: [Contact] = [
        contact(
            name: "Priya Raghavan",
            given: "Priya",
            family: "Raghavan",
            org: "Northgate Labs",
            title: "Head of Delivery",
            email: "priya@northgatelabs.example",
            phone: "+351 21 555 0148",
            hasKey: true
        ),
        contact(
            name: "Devon Okafor",
            given: "Devon",
            family: "Okafor",
            org: "Northgate Labs",
            title: "Security Engineer",
            email: "devon@northgatelabs.example",
            phone: "+1 415 555 0172",
            hasKey: true
        ),
        contact(
            name: "Ines Varga",
            given: "Ines",
            family: "Varga",
            org: "Atlas Relay",
            title: "Counsel",
            email: "ines@atlasrelay.example",
            phone: "+44 20 7946 0311",
            hasKey: true
        ),
        contact(
            name: "Sofia Marchetti",
            given: "Sofia",
            family: "Marchetti",
            org: "",
            title: "",
            email: "sofia@baywood.example",
            phone: "+39 06 5555 0190",
            hasKey: false
        ),
        contact(
            name: "Tomas Lindqvist",
            given: "Tomas",
            family: "Lindqvist",
            org: "Fjordhaus",
            title: "Caretaker",
            email: "tomas@fjordhaus.example",
            phone: "+47 21 55 01 66",
            hasKey: false
        ),
        contact(
            name: "Mara Whitfield",
            given: "Mara",
            family: "Whitfield",
            org: "Harbourline Credit Union",
            title: "Relationship Manager",
            email: "mara@harbourline.example",
            phone: "+1 206 555 0133",
            hasKey: false
        ),
        contact(
            name: "Kenji Sato",
            given: "Kenji",
            family: "Sato",
            org: "Meridian Rail",
            title: "Operations",
            email: "kenji@meridian.example",
            phone: "+81 3 5555 0121",
            hasKey: false
        ),
        contact(
            name: "Avery Lang",
            given: "Avery",
            family: "Lang",
            org: "Northgate Labs",
            title: "Principal",
            email: accountAddress,
            phone: "+1 503 555 0107",
            hasKey: true
        ),
    ]

    /// The in-app approval fallback. Real challenges arrive by push; there is
    /// no route that reaches this screen without a server, so the runner asks
    /// for it by name.
    static let mfaChallenge = MfaChallenge(
        challengeId: "K7QP-2F19",
        receivedAt: now,
        matchDigits: "47",
        decoyDigits: ["12", "83"]
    )

    private static func contact(
        name: String,
        given: String,
        family: String,
        org: String,
        title: String,
        email: String,
        phone: String,
        hasKey: Bool
    ) -> Contact {
        var contact = Contact(name: name, createdAt: now, updatedAt: now)
        contact.uid = "demo-\(email)"
        contact.rev = 1
        contact.givenName = given
        contact.familyName = family
        contact.org = org
        contact.title = title
        contact.emails = [ContactLabeledValue(label: "work", value: email)]
        contact.phones = [ContactLabeledValue(label: "mobile", value: phone)]
        if hasKey {
            contact.pgpKey = demoPublicKeyBlock
        }
        return contact
    }

    /// Not a key — a placeholder with a key's shape, so anything that only
    /// checks "is a key present" behaves as it would with a real one. Nothing
    /// in the demo path ever asks GopenPGP to parse it.
    private static let demoPublicKeyBlock = """
        -----BEGIN PGP PUBLIC KEY BLOCK-----

        ZGVtb25zdHJhdGlvbiBwbGFjZWhvbGRlciAtLSBub3QgYSByZWFsIE9wZW5QR1Ag
        a2V5LiBTY3JlZW5zaG90IGZpeHR1cmUgb25seS4=
        =dEmO
        -----END PGP PUBLIC KEY BLOCK-----
        """

    /// Loads the demo address book. Emails arrive through DemoMailSource on
    /// the normal refresh path, so only contacts need planting.
    static func seedContacts(into dao: ContactDAO) async {
        do {
            try await dao.upsert(contacts: contacts)
        } catch {
            Log.storage.error("Demo contact seed failed: \(error.localizedDescription)")
        }
    }
}

/// Stands in for the relay while capturing screenshots: the demo mailbox,
/// served from memory, with every mutation a no-op that succeeds.
struct DemoMailSource: MailSource {
    func listFolders(parent: String?) async throws -> [MailFolder] { [] }
    func createFolder(parent: String, name: String) async throws {}
    func renameFolder(folder: String, name: String) async throws {}
    func deleteFolder(folder: String) async throws {}

    func fetchEmails(
        folder: String,
        from: Int,
        to: Int,
        since: String
    ) async throws -> MailFetchResult {
        MailFetchResult(
            emails: DemoContent.emails.filter { $0.folder == folder },
            cursor: "demo",
            isFullWindow: true
        )
    }

    func fetchOlder(folder: String, limit: Int, before: String) async throws -> MailPage {
        MailPage(emails: [], hasMore: false, nextBefore: nil)
    }

    func fetchBody(folder: String, messageId: String) async throws -> MailMessageBody {
        let email = DemoContent.emails.first { $0.folder == folder && $0.serverId == messageId }
        return MailMessageBody(body: email?.body ?? "", bodyMode: email?.bodyMode ?? "")
    }

    func searchMail(folder: String, query: String, limit: Int) async throws -> [Email] {
        DemoContent.emails.filter {
            $0.folder == folder
                && ($0.subject.localizedCaseInsensitiveContains(query)
                    || $0.senderName.localizedCaseInsensitiveContains(query))
        }
    }
    func move(messageIds: [String], from mailbox: String, to targetMailbox: String) async throws -> MailActionReport {
        MailActionReport(processed: Set(messageIds).count, failed: [])
    }
    func delete(messageIds: [String], mailbox: String) async throws -> MailActionReport {
        MailActionReport(processed: Set(messageIds).count, failed: [])
    }
    func archive(messageIds: [String], mailbox: String) async throws -> MailActionReport {
        MailActionReport(processed: Set(messageIds).count, failed: [])
    }
    func markSpam(messageIds: [String], mailbox: String) async throws -> MailActionReport {
        MailActionReport(processed: Set(messageIds).count, failed: [])
    }
    func markRead(messageIds: [String], mailbox: String) async throws {}

    func listAttachments(folder: String, messageId: String) async throws -> [EmailAttachment] { [] }

    func downloadAttachment(folder: String, messageId: String, index: Int) async throws -> Data {
        Data()
    }

    @discardableResult
    func send(email: OutgoingEmail) async throws -> String { "" }
    func saveDraft(email: OutgoingEmail) async throws {}
}

#endif
