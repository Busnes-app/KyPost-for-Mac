//
//  UnpairTeardownTests.swift
//  KyPost Tests
//
//  Unpairing is a session boundary for the OpenPGP key, not only for the
//  pairing credential.
//

import Foundation
import SwiftData
import Testing
@testable import KyPost

@MainActor
@Suite struct UnpairTeardownTests {
    private func makeGraph() throws -> SingletonGraph {
        try SingletonGraph(
            userDefaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!,
            keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)"),
            database: AppDatabase(inMemory: true)
        )
    }

    /// Storing seals to the device key, which a test host has none of: the
    /// graph's vault gets the fake one, on the graph's own Keychain and a
    /// throwaway tag (destroy deletes the key by tag).
    private func useFakeDeviceKey(_ graph: SingletonGraph) {
        graph.enrollmentVault = EnrollmentVault(
            keychain: graph.keychain,
            keyTag: "org.kysecurity.mail.tests.\(UUID().uuidString)",
            sealing: FakeKeySealing(),
            presence: PresenceContext()
        )
    }

    /// Built on a mock contact store rather than `graph.systemContactsExporter`,
    /// whose live store reads the real Contacts database of whoever runs the
    /// suite.
    private func makeViewModel(_ graph: SingletonGraph) -> SettingsViewModel {
        let store = MockSystemContactStore()
        let exporter = SystemContactsExporter(
            store: store,
            linkStore: graph.systemContactsLinkStore,
            baselineStore: graph.systemContactsBaselineStore,
            settings: graph.contactsSettingsStore,
            contactDAO: graph.contactDAO,
            photoCache: graph.contactPhotoCache,
            groupLinker: SystemContactGroupLinker(
                store: store,
                linkStore: graph.systemContactGroupLinkStore
            ),
            groupDAO: graph.groupDAO
        )
        return SettingsViewModel(
            securePairingStore: graph.securePairingStore,
            pushSettingsStore: graph.pushSettingsStore,
            desktopSessionStore: graph.desktopSessionStore,
            mailRepository: graph.mailRepository,
            keywordRepository: graph.keywordRepository,
            contactsSettingsStore: graph.contactsSettingsStore,
            systemContactsExporter: exporter,
            deviceRegistrationService: graph.deviceRegistrationService,
            deregisterDeviceUseCase: graph.deregisterDeviceUseCase,
            pushNotificationDispatcher: graph.pushNotificationDispatcher,
            erasePreservedStore: graph.erasePreservedStoreStep,
            enrollmentVault: graph.enrollmentVault,
            pushRepository: graph.pushRepository,
            mailSignatureStore: graph.mailSignatureStore
        )
    }

    /// A session running in memory over a store it kept (a recoverable open
    /// failure) clears only the in-memory copy on unpair. The kept file holds
    /// the account's mail and must not reopen under the next pairing.
    @Test func unpairingErasesAStoreKeptUnderAnInMemorySession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kypost-unpair-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "store.sqlite")
        _ = try {
            let kept = try AppDatabase(url: url)
            let context = ModelContext(kept.container)
            context.insert(EmailEntity(from: Email(
                serverId: "a-1", folder: "INBOX", senderName: "A", senderEmail: "a@x",
                subject: "Account A's mail", body: "A's body", keywords: [],
                receivedAt: Date(), read: false, starred: false
            )))
            try context.save()
        }()

        let graph = try makeGraph()
        graph.preservedStoreURL = url
        await makeViewModel(graph).unpair()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(AppDatabase.storeMayOpen(defaults: graph.userDefaults, at: url))
        let reopened = try AppDatabase(url: url)
        #expect(try ModelContext(reopened.container).fetch(FetchDescriptor<EmailEntity>()).isEmpty)
    }

    /// The envelope is the account's private key sealed to *this* Mac. Left
    /// behind, it outlives the pairing that authorised putting it here — on a
    /// machine the account no longer knows about, so no revocation reaches it.
    @Test func unpairingDestroysTheSealedEnvelope() async throws {
        let graph = try makeGraph()
        useFakeDeviceKey(graph)
        try graph.enrollmentVault.store(
            privateKey: Data("-----BEGIN PGP PRIVATE KEY BLOCK-----".utf8),
            identityFingerprint: "AABBCCDDEEFF00112233445566778899AABBCCDD"
        )
        #expect(graph.enrollmentVault.isEnrolled)

        await makeViewModel(graph).unpair()
        #expect(!graph.enrollmentVault.isEnrolled)
    }

    /// Desktop pairing is gone, but a session token an older build stored is
    /// still this account's credential and goes with the pairing — as do the
    /// pin and any relay response an older `.default` session cached.
    @Test func unpairingErasesLegacyDesktopSessionPinAndCache() async throws {
        let graph = try makeGraph()
        // No device secret: the deregister call skips the network.
        try graph.securePairingStore.savePairing(Pairing(
            sub: "u1", deviceSecret: "", srv: server, registrationUrl: nil,
            pairingToken: "pt", lastDeviceId: nil, pairedAt: Date()
        ), pinnedSpkiHash: "hash-a")
        for key in DesktopSessionStore.legacyKeys {
            try graph.keychain.set("old", forKey: key)
        }
        let url = URL(string: "\(server)/api/inbox")!
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        URLCache.shared.storeCachedResponse(
            CachedURLResponse(response: response, data: Data("mail".utf8)),
            for: URLRequest(url: url)
        )

        await makeViewModel(graph).unpair()

        for key in DesktopSessionStore.legacyKeys {
            #expect(try graph.keychain.string(forKey: key) == nil)
        }
        #expect(try graph.securePairingStore.pinnedSpkiHash(forHost: "relay.example.com") == nil)
        #expect(URLCache.shared.cachedResponse(for: URLRequest(url: url)) == nil)
    }

    /// Destroying the sealed blob while an unsealed copy sits in this process
    /// would be theatre — the plaintext key is the thing that matters.
    @Test func unpairingDropsTheUnsealedCopyToo() async throws {
        let graph = try makeGraph()
        EnrollmentSession.shared.put(armoredKey: "-----BEGIN PGP PRIVATE KEY BLOCK-----")
        #expect(EnrollmentSession.shared.isHeld)

        await makeViewModel(graph).unpair()
        #expect(!EnrollmentSession.shared.isHeld)
    }

    /// Notification history is the account's sender and subject lines; the
    /// pull cursor is a position in that account's queue.
    @Test func unpairingClearsNotificationHistoryAndTheCursor() async throws {
        let graph = try makeGraph()
        try await graph.pushRepository.recordPushArrival(
            MailPushPayload(messageId: "m-1", senderName: "Ada", emailSubject: "Hi", keywords: [])
        )
        graph.notificationCursorStore.advance(to: 9)

        await makeViewModel(graph).unpair()
        #expect(try await graph.pushRepository.history().isEmpty)
        #expect(graph.notificationCursorStore.lastCursor == 0)
    }

    /// The signature is the unpaired account's. Cleared through the injected
    /// store, so an isolated graph's teardown never reaches another graph's
    /// defaults (here, a second graph standing in for the shared one).
    @Test func unpairingClearsOnlyTheInjectedSignature() async throws {
        let graph = try makeGraph()
        let other = try makeGraph()
        graph.mailSignatureStore.save("Ada")
        other.mailSignatureStore.save("Grace")

        await makeViewModel(graph).unpair()
        #expect(graph.mailSignatureStore.signature.isEmpty)
        #expect(other.mailSignatureStore.signature == "Grace")
    }

    /// The account's mail: window rows, mail paged in from before the window
    /// (which no refresh prunes), cached bodies, and the cursors.
    @Test func unpairingErasesCachedMailAndCursors() async throws {
        let graph = try makeGraph()
        try await seedMail(graph)

        await makeViewModel(graph).unpair()

        #expect(try await graph.emailDAO.getFolder(folder: "INBOX").isEmpty)
        #expect(graph.mailCursorStore.cursor(pairingId: "u1", folder: "INBOX") == "")
    }

    /// Pairing another account without an unpair erases the same.
    @Test func pairingAnotherAccountErasesCachedMail() async throws {
        let graph = try makeGraph()
        try await seedMail(graph)

        #expect(await graph.deviceRegistrationService.onAccountReplaced?() == true)

        #expect(try await graph.emailDAO.getFolder(folder: "INBOX").isEmpty)
        #expect(graph.mailCursorStore.cursor(pairingId: "u1", folder: "INBOX") == "")
    }

    /// Pairing account B over A, with no unpair in between, runs the same
    /// teardown as an unpair before B's pairing is stored: none of A's state
    /// is left for B.
    @Test func pairingAnotherAccountOverThisOneLeavesNoneOfItsState() async throws {
        let graph = try makeGraph()
        useFakeDeviceKey(graph)
        try graph.securePairingStore.savePairing(Pairing(
            sub: "u1", deviceSecret: "s1", srv: server, registrationUrl: nil,
            pairingToken: "pt", lastDeviceId: "dev-1", pairedAt: Date()
        ))
        // Account A's state, one item per teardown step.
        try graph.enrollmentVault.store(
            privateKey: Data("-----BEGIN PGP PRIVATE KEY BLOCK-----".utf8),
            identityFingerprint: "AABBCCDDEEFF00112233445566778899AABBCCDD"
        )
        #expect(graph.enrollmentVault.markReportPending())
        EnrollmentSession.shared.put(armoredKey: "-----BEGIN PGP PRIVATE KEY BLOCK-----")
        try await graph.pushRepository.recordPushArrival(
            MailPushPayload(messageId: "m-1", senderName: "Ada", emailSubject: "Hi", keywords: [])
        )
        graph.notificationCursorStore.advance(to: 9)
        #expect(graph.recipientPinStore.pin(addresses: ["alice@example.invalid"], publicKey: PinnedKeyFixtures.alicePinned))
        graph.mailSignatureStore.save("Ada, account A")
        try await seedMail(graph)
        graph.inboxViewModel.delete(serverIds: ["w1"])
        #expect(graph.inboxViewModel.undoMessage != nil)

        // Account B's registration, against a stub relay: the graph's wiring
        // with the pairing connection swapped for one that never dials out.
        let connections = StubPairingConnections(client: stubClient(
            json: #"{"ok": true, "deviceId": "dev-2", "deviceSecret": "s-2"}"#
        ))
        let service = graph.deviceRegistrationService
        service.makePairingConnection = { connections.make(host: $0, pin: $1) }
        let outcome = await service.pair(
            params: PairingParams(sub: "u2", srv: server, pt: "pt-b"), deviceToken: "apns"
        )
        guard case .success = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }

        #expect(try graph.securePairingStore.loadPairing()?.sub == "u2")
        #expect(!graph.enrollmentVault.isEnrolled)
        #expect(graph.enrollmentVault.pendingReportAttempts == nil)
        #expect(!EnrollmentSession.shared.isHeld)
        #expect(try await graph.pushRepository.history().isEmpty)
        #expect(graph.notificationCursorStore.lastCursor == 0)
        #expect(graph.recipientPinStore.all().isEmpty)
        #expect(graph.mailSignatureStore.signature.isEmpty)
        #expect(try await graph.emailDAO.getFolder(folder: "INBOX").isEmpty)
        #expect(graph.mailCursorStore.cursor(pairingId: "u1", folder: "INBOX") == "")
        #expect(graph.inboxViewModel.undoMessage == nil)
        #expect(graph.inboxViewModel.emails.isEmpty)
    }

    private func seedMail(_ graph: SingletonGraph) async throws {
        func email(_ id: String, _ body: String) -> Email {
            Email(
                serverId: id, folder: "INBOX", senderName: "A", senderEmail: "a@x",
                subject: id, body: body, keywords: [], receivedAt: Date(),
                read: false, starred: false
            )
        }
        try await graph.emailDAO.replaceFolderSnapshot(folder: "INBOX", emails: [email("w1", "window text")])
        try await graph.emailDAO.storeOlderMail(folder: "INBOX", emails: [email("p1", "")])
        try await graph.emailDAO.updateBody(folder: "INBOX", serverId: "w1", body: "cached", bodyMode: "plain")
        graph.mailCursorStore.saveCursor(pairingId: "u1", folder: "INBOX", cursor: "12")
        #expect(try await graph.emailDAO.getFolder(folder: "INBOX").count == 2)
    }
}
