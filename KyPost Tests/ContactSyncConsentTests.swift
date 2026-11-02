//
//  ContactSyncConsentTests.swift
//  KyPost Tests
//
//  Contacts leave this device for the server only after the user agrees to
//  the disclosure naming that server (Android #282). Settings → "Sync with
//  Apple Contacts" asks first, consent belongs to one server, and nothing
//  from Apple Contacts is queued for upload without it.
//

import Contacts
import Foundation
import Testing
@testable import KyPost

@MainActor
@Suite struct ContactSyncConsentTests {
    private let serverA = "https://relay-a.example"
    private let serverB = "https://relay-b.example"
    private var relayA: ContactSyncRelay { ContactSyncRelay(srv: serverA) }
    private var relayB: ContactSyncRelay { ContactSyncRelay(srv: serverB) }

    private struct Harness {
        let graph: SingletonGraph
        let store: MockSystemContactStore
        let exporter: SystemContactsExporter
        let viewModel: SettingsViewModel
        var settings: ContactsSettingsStore { graph.contactsSettingsStore }
    }

    /// The exporter runs on a mock store: the graph's own would reach the
    /// real Contacts database of whoever runs the suite.
    private func makeHarness(pairedTo srv: String?, legacyToggleOn: Bool = false) throws -> Harness {
        let graph = try SingletonGraph(
            userDefaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!,
            keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)"),
            database: AppDatabase(inMemory: true)
        )
        if let srv { try pair(graph, to: srv) }
        graph.contactsSettingsStore.exportToSystemContactsEnabled = legacyToggleOn
        let store = MockSystemContactStore()
        let exporter = SystemContactsExporter(
            store: store,
            linkStore: graph.systemContactsLinkStore,
            baselineStore: graph.systemContactsBaselineStore,
            settings: graph.contactsSettingsStore,
            currentRelay: {
                (try? graph.securePairingStore.loadPairing()).map { ContactSyncRelay(srv: $0.srv) }
            },
            contactDAO: graph.contactDAO
        )
        let viewModel = SettingsViewModel(
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
            erasePreservedStore: graph.erasePreservedStoreStep
        )
        return Harness(graph: graph, store: store, exporter: exporter, viewModel: viewModel)
    }

    private func pair(_ graph: SingletonGraph, to srv: String) throws {
        try graph.securePairingStore.savePairing(Pairing(
            sub: "u1", deviceSecret: "", srv: srv, registrationUrl: nil,
            pairingToken: "pt", lastDeviceId: nil, pairedAt: Date()
        ))
    }

    /// A card added in Apple Contacts, as the user would.
    private func addCard(_ harness: Harness, given: String) {
        let card = CNMutableContact()
        card.givenName = given
        card.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "\(given.lowercased())@example.com" as NSString)]
        harness.store.seed(card)
    }

    /// Contacts queued for the next push to the server.
    private func queued(_ harness: Harness) async throws -> [Contact] {
        try await harness.graph.contactDAO.listAll().filter(\.needsSync)
    }

    private func turnOnAndAgree(_ harness: Harness) async {
        harness.viewModel.exportContactsToSystem = true
        await harness.viewModel.agreeToContactSync()
    }

    @Test func agreeAllowsUploadForThatServerOnly() async throws {
        let harness = try makeHarness(pairedTo: serverA)
        harness.viewModel.exportContactsToSystem = true
        // The toggle only asks: nothing is on, recorded or prompted yet.
        #expect(harness.viewModel.contactSyncDisclosure?.server == "relay-a.example")
        #expect(!harness.viewModel.exportContactsToSystem)
        #expect(!harness.settings.hasSyncConsent(for: relayA))

        await harness.viewModel.agreeToContactSync()
        #expect(harness.viewModel.exportContactsToSystem)
        #expect(harness.settings.hasSyncConsent(for: relayA))
        #expect(harness.viewModel.contactSyncStatus.contains("relay-a.example"))

        addCard(harness, given: "Ada")
        #expect(await harness.exporter.reconcileAll().imported == 1)
        #expect(try await queued(harness).map(\.givenName) == ["Ada"])

        // Another server was never agreed to.
        try pair(harness.graph, to: serverB)
        addCard(harness, given: "Bea")
        #expect(await harness.exporter.reconcileAll().imported == 0)
        #expect(try await queued(harness).map(\.givenName) == ["Ada"])
    }

    @Test func notNowLeavesSyncOffAndQueuesNothing() async throws {
        let harness = try makeHarness(pairedTo: serverA)
        harness.viewModel.exportContactsToSystem = true
        #expect(harness.viewModel.contactSyncDisclosure != nil)

        harness.viewModel.declineContactSync()
        #expect(harness.viewModel.contactSyncDisclosure == nil)
        #expect(!harness.viewModel.exportContactsToSystem)
        #expect(!harness.settings.exportToSystemContactsEnabled)
        #expect(!harness.settings.hasSyncConsent(for: relayA))
        #expect(harness.viewModel.contactSyncStatus.hasPrefix("Off."))

        harness.graph.systemContactsBaselineStore.capture(identifiers: [])
        addCard(harness, given: "Ada")
        #expect(await harness.exporter.reconcileAll() == SystemContactsExporter.Summary())
        #expect(try await queued(harness).isEmpty)
    }

    @Test func turningOffForgetsConsentAndStopsImport() async throws {
        let harness = try makeHarness(pairedTo: serverA)
        await turnOnAndAgree(harness)
        #expect(harness.exporter.isSyncOn)

        harness.viewModel.exportContactsToSystem = false
        // Asks first; still on until confirmed.
        #expect(harness.viewModel.confirmingStopContactSync)
        #expect(harness.viewModel.exportContactsToSystem)
        #expect(harness.viewModel.stopContactSyncMessage.contains("relay-a.example"))

        harness.viewModel.stopContactSync()
        #expect(!harness.viewModel.exportContactsToSystem)
        #expect(!harness.settings.hasSyncConsent(for: relayA))
        #expect(!harness.exporter.isSyncOn)

        addCard(harness, given: "Ada")
        #expect(await harness.exporter.reconcileAll().imported == 0)
        #expect(try await queued(harness).isEmpty)
    }

    /// Android's decision too: an install that turned sync on before the
    /// disclosure existed has agreed to nothing that named the server.
    @Test func existingToggleOnInstallWithoutConsentReadsOff() async throws {
        let harness = try makeHarness(pairedTo: serverA, legacyToggleOn: true)
        #expect(!harness.viewModel.exportContactsToSystem)
        #expect(harness.viewModel.contactSyncStatus.hasPrefix("Off."))
        #expect(!harness.exporter.isSyncOn)

        harness.graph.systemContactsBaselineStore.capture(identifiers: [])
        addCard(harness, given: "Ada")
        #expect(await harness.exporter.reconcileAll().imported == 0)
        #expect(try await queued(harness).isEmpty)

        // Turning it on asks, like a new install.
        harness.viewModel.exportContactsToSystem = true
        #expect(harness.viewModel.contactSyncDisclosure?.server == "relay-a.example")
    }

    @Test func serverChangeNeedsNewConsent() async throws {
        let harness = try makeHarness(pairedTo: serverA)
        await turnOnAndAgree(harness)
        #expect(harness.viewModel.exportContactsToSystem)

        try pair(harness.graph, to: serverB)
        harness.viewModel.pairingDidChange()
        #expect(!harness.viewModel.exportContactsToSystem)
        #expect(!harness.exporter.isSyncOn)

        harness.viewModel.exportContactsToSystem = true
        #expect(harness.viewModel.contactSyncDisclosure?.server == "relay-b.example")
        await harness.viewModel.agreeToContactSync()
        #expect(harness.exporter.isSyncOn)
        #expect(!harness.settings.hasSyncConsent(for: relayA))
    }

    /// Agree on a disclosure that named a server no longer paired records
    /// nothing.
    @Test func agreeAfterThePairingChangedRecordsNothing() async throws {
        let harness = try makeHarness(pairedTo: serverA)
        harness.viewModel.exportContactsToSystem = true
        try pair(harness.graph, to: serverB)
        await harness.viewModel.agreeToContactSync()
        #expect(!harness.settings.hasSyncConsent(for: relayA))
        #expect(!harness.settings.hasSyncConsent(for: relayB))
        #expect(!harness.viewModel.exportContactsToSystem)
    }

    @Test func unpairedAsksNothing() async throws {
        let harness = try makeHarness(pairedTo: nil)
        harness.viewModel.exportContactsToSystem = true
        #expect(harness.viewModel.contactSyncDisclosure == nil)
        #expect(!harness.viewModel.exportContactsToSystem)
    }

    @Test func disclosureNamesTheServerAndHowContactsAreUsed() {
        let text = ContactSyncDisclosure(relay: relayA, device: "iPhone").text
        #expect(text.contains("your KyPost server at relay-a.example"))
        #expect(text.contains("Only to your server at relay-a.example"))
        #expect(text.contains("Apple Contacts on this iPhone after you agree"))
        #expect(text.contains("Cards already in Apple Contacts are not sent"))
        #expect(text.contains("How they are used"))
        #expect(text.contains("suggest recipients"))
        #expect(text.contains("keys.openpgp.org"))
        #expect(text.contains("not used for ads"))
        #expect(text.contains("The KyPost developer never receives them"))
        #expect(text.contains("until you delete them"))
        #expect(text.contains("unless you tap Agree"))
    }

    @Test func serverNameIsThePairingsHost() {
        #expect(ContactSyncDisclosure.serverName(fromSrv: "https://Relay-A.example/") == "relay-a.example")
        #expect(ContactSyncDisclosure.serverName(fromSrv: "https://relay-a.example:8443") == "relay-a.example")
        #expect(ContactSyncRelay(srv: "https://Relay-A.example:8443/kypost/").name == "relay-a.example")
    }

    /// Consent is keyed on the whole base URL; spellings of one URL share it.
    @Test func consentKeyIsTheCanonicalBaseURL() {
        let key = ContactSyncRelay.canonicalBaseURL(fromSrv:)
        #expect(key("https://Relay-A.example/kypost/") == "https://relay-a.example:443/kypost")
        #expect(key("HTTPS://relay-a.example:443/kypost") == "https://relay-a.example:443/kypost")
        #expect(key("http://relay-a.example") == "http://relay-a.example:80")
        #expect(key("https://relay-a.example:8443") == "https://relay-a.example:8443")
        #expect(key("https://relay-a.example/") == key("https://relay-a.example"))
        #expect(key("https://relay-a.example/KyPost") != key("https://relay-a.example/kypost"))
    }

    /// Another deployment on the same host is another relay: replacing the
    /// pairing with it leaves sync off until the user agrees again, though
    /// the disclosure and the Settings row name the same host.
    private func replacementOnTheSameHostNeedsFreshConsent(from first: String, to replacement: String) async throws {
        let harness = try makeHarness(pairedTo: first)
        await turnOnAndAgree(harness)
        #expect(harness.exporter.isSyncOn)
        #expect(harness.viewModel.contactSyncStatus.contains("relay-a.example"))

        try pair(harness.graph, to: replacement)
        harness.viewModel.pairingDidChange()
        #expect(!harness.viewModel.exportContactsToSystem)
        #expect(!harness.exporter.isSyncOn)
        addCard(harness, given: "Ada")
        #expect(await harness.exporter.reconcileAll().imported == 0)
        #expect(try await queued(harness).isEmpty)

        let contacts = ContactsViewModel(
            repository: harness.graph.contactSyncRepository,
            settingsStore: harness.settings
        )
        #expect(contacts.syncDisclosure?.server == "relay-a.example")
        harness.viewModel.exportContactsToSystem = true
        #expect(harness.viewModel.contactSyncDisclosure?.server == "relay-a.example")
        #expect(!harness.viewModel.exportContactsToSystem)
    }

    @Test func replacementOnAnotherPortNeedsFreshConsent() async throws {
        try await replacementOnTheSameHostNeedsFreshConsent(
            from: "https://relay-a.example", to: "https://relay-a.example:8443"
        )
    }

    @Test func replacementOnAnotherBasePathNeedsFreshConsent() async throws {
        try await replacementOnTheSameHostNeedsFreshConsent(
            from: "https://relay-a.example/kypost", to: "https://relay-a.example/kypost-staging"
        )
    }

    // MARK: - Turn Off during an import

    /// A repository pushing to a stub relay through `harness.exporter`; the
    /// returned box collects every request body it sends.
    private func uploads(_ harness: Harness) -> (ContactSyncRepository, Box<[String]>) {
        let bodies = Box<[String]>([])
        let client = stubClient(json: #"{"cursor": 1}"#) { request in
            bodies.mutate { $0.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self)) }
        }
        let repository = ContactSyncRepository(
            client: ContactSyncClient(httpClient: client),
            contactDAO: harness.graph.contactDAO,
            cursorStore: harness.graph.contactCursorStore,
            pendingDeletesStore: harness.graph.contactPendingDeletesStore,
            securePairingStore: harness.graph.securePairingStore,
            systemContactsExporter: harness.exporter
        )
        return (repository, bodies)
    }

    private func turnOff(_ harness: Harness) {
        harness.viewModel.exportContactsToSystem = false
        harness.viewModel.stopContactSync()
    }

    /// Turn Off confirmed while the import waits on its contact read: the
    /// pass resumes, queues nothing, and the sync after it sends nothing.
    @Test func turnOffWhileTheImportIsSuspendedQueuesAndUploadsNothing() async throws {
        let harness = try makeHarness(pairedTo: serverA)
        await turnOnAndAgree(harness)
        addCard(harness, given: "Ada")
        addCard(harness, given: "Bea")

        let (reached, reachedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (resume, resumeContinuation) = AsyncStream.makeStream(of: Void.self)
        harness.exporter.beforeImportRead = {
            reachedContinuation.yield()
            for await _ in resume { break }
        }
        let pass = Task { await harness.exporter.reconcileAll() }
        for await _ in reached { break }

        turnOff(harness)
        resumeContinuation.yield()
        #expect(await pass.value.imported == 0)
        #expect(try await queued(harness).isEmpty)

        let (repository, bodies) = uploads(harness)
        _ = try? await repository.sync()
        #expect(!bodies.value.contains { $0.contains("ada@example.com") || $0.contains("bea@example.com") })
    }

    /// A card imported and queued before Turn Off never goes out after it,
    /// nor after a later Agree: that Agree promises cards already in Apple
    /// Contacts are not sent.
    @Test func importQueuedBeforeTurnOffIsNotUploaded() async throws {
        let harness = try makeHarness(pairedTo: serverA)
        await turnOnAndAgree(harness)
        addCard(harness, given: "Ada")
        #expect(await harness.exporter.reconcileAll().imported == 1)
        turnOff(harness)

        let (repository, bodies) = uploads(harness)
        _ = try? await repository.sync()
        #expect(!bodies.value.contains { $0.contains("ada@example.com") })
        #expect(await repository.pendingSummary().count == 0)

        await turnOnAndAgree(harness)
        _ = try? await repository.sync()
        #expect(!bodies.value.contains { $0.contains("ada@example.com") })
    }

    /// The control for the two above: under the consent it was imported
    /// with, an import does go out.
    @Test func importUnderStandingConsentIsUploaded() async throws {
        let harness = try makeHarness(pairedTo: serverA)
        await turnOnAndAgree(harness)
        addCard(harness, given: "Ada")
        #expect(await harness.exporter.reconcileAll().imported == 1)

        let (repository, bodies) = uploads(harness)
        _ = try? await repository.sync()
        #expect(bodies.value.contains { $0.contains("ada@example.com") })
    }

    /// The Contacts screen's Sync shows the same disclosure, once per
    /// server; agreeing there never turns Apple Contacts sync back on.
    @Test func contactsScreenAsksOncePerServerAndNeverResumesAppleSync() throws {
        let harness = try makeHarness(pairedTo: serverA, legacyToggleOn: true)
        let contacts = ContactsViewModel(
            repository: harness.graph.contactSyncRepository,
            settingsStore: harness.settings
        )
        let disclosure = try #require(contacts.syncDisclosure)
        #expect(disclosure.server == "relay-a.example")

        contacts.agreeToSync(disclosure)
        #expect(contacts.syncDisclosure == nil)
        #expect(harness.settings.hasSyncConsent(for: relayA))
        #expect(!harness.settings.exportToSystemContactsEnabled)

        try pair(harness.graph, to: serverB)
        #expect(contacts.syncDisclosure?.server == "relay-b.example")
    }
}
