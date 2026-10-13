//
//  DemoContentTests.swift
//  KyPost Tests
//
//  The DEBUG screenshot build (`-KyPostDemo`) must stay apart from the real
//  app: its own defaults, Keychain items, device key and Contacts adapter,
//  no relay traffic, and nothing fabricated without the launch argument.
//

import Contacts
import Foundation
import Testing
@testable import KyPost

@MainActor
@Suite(.serialized) struct DemoContentTests {
    private struct Production {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let keychain = KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
    }

    private func makeDemoGraph(
        _ production: Production,
        contacts: MockSystemContactStore? = nil
    ) throws -> SingletonGraph {
        try SingletonGraph(
            userDefaults: production.defaults,
            keychain: production.keychain,
            database: AppDatabase(inMemory: true),
            isDemo: true,
            systemContactStore: contacts
        )
    }

    // MARK: - Launch arguments

    @Test func theScreenArgumentAloneRequestsNothing() {
        #expect(DemoContent.requestedScreen(in: ["KyPost", "-KyPostDemoScreen", "mfa"]) == nil)
        #expect(!DemoContent.isEnabled(in: ["KyPost", "-KyPostDemoScreen", "mfa"]))
    }

    @Test func theScreenArgumentIsReadOnlyInTheDemoBuild() {
        let arguments = ["KyPost", "-KyPostDemo", "-KyPostDemoScreen", "mfa"]
        #expect(DemoContent.requestedScreen(in: arguments) == "mfa")
        #expect(DemoContent.requestedScreen(in: ["KyPost", "-KyPostDemo"]) == nil)
    }

    @Test func anOrdinaryTestProcessIsNotTheDemoBuild() {
        #expect(!SingletonGraph.launchIsDemo)
    }

    // MARK: - Fixtures

    /// Screenshots are published; every address in them is on `.example`.
    @Test func everyFixtureAddressIsReserved() {
        var addresses = [DemoContent.accountAddress]
        for email in DemoContent.emails {
            addresses.append(email.senderEmail)
            addresses += [email.sentTo, email.cc]
                .flatMap { field in
                    field.split(separator: ",").compactMap { part -> String? in
                        guard let open = part.firstIndex(of: "<"),
                              let close = part.firstIndex(of: ">") else {
                            return part.trimmingCharacters(in: .whitespaces)
                        }
                        return String(part[part.index(after: open)..<close])
                    }
                }
                .filter { !$0.isEmpty }
        }
        addresses += DemoContent.contacts.flatMap { $0.emails.map(\.value) }
        addresses += [DemoContent.pairingDisplay.serverHost]
        addresses += [DemoContent.pairingDisplay.account].compactMap { $0 }

        #expect(addresses.count > DemoContent.emails.count)
        for address in addresses {
            #expect(address.lowercased().hasSuffix(".example"), "\(address)")
        }
    }

    // MARK: - Isolation

    @Test func theDemoGraphUsesNoneOfTheProductionStores() throws {
        let production = Production()
        let pairing = Pairing(
            sub: "u1", deviceSecret: "s1", srv: "https://relay.example", registrationUrl: nil,
            pairingToken: "pt", lastDeviceId: "dev-1", pairedAt: Date()
        )
        try SecurePairingStore(keychain: production.keychain).savePairing(pairing)
        production.defaults.set("push", forKey: "push.deliveryMode")

        let graph = try makeDemoGraph(production)

        #expect(graph.isDemo)
        #expect(graph.userDefaults !== production.defaults)
        #expect(try graph.securePairingStore.loadPairing() == nil)
        #expect(graph.database.isInMemory)
        // The production pairing is still there, untouched.
        #expect(try SecurePairingStore(keychain: production.keychain).loadPairing() != nil)
    }

    @Test func demoStartupMakesNoContactsChangesAndKeepsProductionLinks() async throws {
        let production = Production()
        let card = CNMutableContact()
        card.givenName = "Real"
        card.familyName = "Person"
        let contacts = MockSystemContactStore()
        contacts.seed(card)
        let link = SystemContactLink(
            localId: UUID(), uid: "real-uid", cnIdentifier: card.identifier,
            exportedUpdatedAt: Date()
        )
        SystemContactsLinkStore(defaults: production.defaults).upsert(link)
        ContactsSettingsStore(defaults: production.defaults).exportToSystemContactsEnabled = true

        let graph = try makeDemoGraph(production, contacts: contacts)
        await graph.runStartupMigrationsIfNeeded()
        await graph.systemContactsChangeMonitor.reconcileNow()

        #expect(contacts.addCount == 0)
        #expect(contacts.updateCount == 0)
        #expect(contacts.deleteCount == 0)
        #expect(try await contacts.listAll().count == 1)
        #expect(SystemContactsLinkStore(defaults: production.defaults).all() == [link])
    }

    /// The repairs are for real stores. Run against demo data, they would
    /// mark themselves done and be skipped on the real database next launch.
    @Test func demoStartupLeavesTheMigrationFlagsUnset() async throws {
        let production = Production()
        let graph = try makeDemoGraph(production)

        await graph.runStartupMigrationsIfNeeded()

        for key in [
            "contacts.legacyFieldsMigrated",
            "contacts.reconciliationRepair.v1",
            "contacts.systemImportDupeRepair.v1",
        ] {
            #expect(production.defaults.object(forKey: key) == nil, "\(key)")
            #expect(graph.userDefaults.object(forKey: key) == nil, "\(key)")
        }
        #expect(!(try await graph.contactDAO.listAll().isEmpty))
    }

    @Test func theDemoGraphSendsNothingToTheRelay() async throws {
        let production = Production()
        try SecurePairingStore(keychain: production.keychain).savePairing(Pairing(
            sub: "u1", deviceSecret: "s1", srv: "https://relay.example", registrationUrl: nil,
            pairingToken: "pt", lastDeviceId: "dev-1", pairedAt: Date()
        ))
        production.defaults.set("pull", forKey: "push.deliveryMode")
        let requests = Box(0)

        let graph = try makeDemoGraph(production)
        graph.httpClient = HTTPClient(transport: { request in
            requests.mutate { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        })

        await graph.runStartupMigrationsIfNeeded()
        await graph.pullPollingScheduler.pollNow()
        await graph.systemContactsChangeMonitor.reconcileNow()
        _ = try await graph.mailRepository.refreshFolder(StandardFolder.inbox)

        #expect(requests.value == 0)
    }

    // MARK: - Settings → Connection

    /// The screenshot's Connection section reads as a paired account, and
    /// that is all it is: no pairing is stored, so registration, pulls, mail
    /// and Fix Notifications all still see an unpaired device.
    @Test func theDemoGraphShowsAPairedAccountThatNothingCanUse() async throws {
        let production = Production()
        let requests = Box(0)
        let graph = try makeDemoGraph(production)
        graph.httpClient = HTTPClient(transport: { _ in
            requests.mutate { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        })
        let settings = SettingsViewModel(
            securePairingStore: graph.securePairingStore,
            pushSettingsStore: graph.pushSettingsStore,
            desktopSessionStore: graph.desktopSessionStore,
            mailRepository: graph.mailRepository,
            keywordRepository: graph.keywordRepository,
            contactsSettingsStore: graph.contactsSettingsStore,
            systemContactsExporter: graph.systemContactsExporter,
            deviceRegistrationService: graph.deviceRegistrationService,
            deregisterDeviceUseCase: graph.deregisterDeviceUseCase,
            pushNotificationDispatcher: graph.pushNotificationDispatcher,
            pairingDisplayOverride: graph.pairingDisplayOverride
        )

        // Presented as paired.
        #expect(settings.pairingDisplay == DemoContent.pairingDisplay)
        #expect(settings.pairingDisplay?.account == DemoContent.accountAddress)
        #expect(settings.deliveryMode == "Push")

        // Nothing paired is readable.
        #expect(!settings.isPaired)
        #expect(try graph.securePairingStore.loadPairing() == nil)
        #expect(try graph.securePairingStore.loadActivePairing() == nil)
        let reregistered = await graph.deviceRegistrationService.reregisterIfPaired(deviceToken: "demo-token")
        #expect(reregistered == nil)
        await settings.repairNotifications()
        #expect(settings.statusMessage == "Not paired — pair this device first.")
        await graph.pullPollingScheduler.pollNow()
        _ = try await graph.mailRepository.refreshFolder(StandardFolder.inbox)
        #expect(requests.value == 0)
    }

    @Test func anOrdinaryGraphHasNoPairingDisplayOverride() throws {
        let production = Production()
        let graph = try SingletonGraph(
            userDefaults: production.defaults,
            keychain: production.keychain,
            database: AppDatabase(inMemory: true),
            isDemo: false
        )
        #expect(graph.pairingDisplayOverride == nil)
    }
}
