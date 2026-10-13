//
//  SecurityWipeStepsTests.swift
//  KyPost Tests
//
//  Phase 11: the real step list — what it covers and in what order.
//
//  Only the steps that are safe to run against a test host's own container are
//  actually executed here. The rest are asserted by name: running `database`
//  would delete the store belonging to whatever KyPost build shares this
//  container, which is not something a test suite gets to do.
//

import Foundation
import Testing
@testable import KyPost

@MainActor
@Suite struct SecurityWipeStepsTests {
    private func makeGraph(defaults: UserDefaults) throws -> SingletonGraph {
        try SingletonGraph(
            userDefaults: defaults,
            keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)"),
            database: AppDatabase(inMemory: true)
        )
    }

    /// The list is the contract. A store added to the graph without a step here
    /// survives a wipe silently, which is the failure mode this asserts against.
    @Test func everyStoreIsCoveredAndTheOrderHolds() throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let steps = SecurityWipeSteps.build(graph: try makeGraph(defaults: defaults), defaultsDomain: nil)
        let names = steps.map(\.name)

        #expect(names == [
            "inMemoryPlaintext",
            "database",
            "contactPhotos",
            "attachmentTempFiles",
            "deliveredNotifications",
            "deviceContactCards",
            "enrollmentVault",
            "pinPepper",
            "credentialGate",
            "pairing",
            "mailCursors",
            "mailSignature",
            "appLock",
            "userDefaults",
        ])
    }

    /// The in-memory plaintext leads: it needs no I/O and is the most sensitive
    /// thing in the list. A wipe does not kill this process, so anything left
    /// in memory is still readable in the attacker's session.
    @Test func theUnsealedPrivateKeyGoesFirst() throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let steps = SecurityWipeSteps.build(graph: try makeGraph(defaults: defaults), defaultsDomain: nil)
        #expect(steps.first?.name == "inMemoryPlaintext")
    }

    /// Reading the link store is what drives the deletion of cards from the
    /// user's own Contacts database, and the defaults sweep is what takes that
    /// store away.
    @Test func contactCardsAreRemovedBeforeTheDefaultsSweep() throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let names = SecurityWipeSteps
            .build(graph: try makeGraph(defaults: defaults), defaultsDomain: nil)
            .map(\.name)
        let cards = try #require(names.firstIndex(of: "deviceContactCards"))
        let sweep = try #require(names.firstIndex(of: "userDefaults"))
        #expect(cards < sweep)
    }

    @Test func theUnsealedKeyStepActuallyClearsTheSession() async throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let steps = SecurityWipeSteps.build(graph: try makeGraph(defaults: defaults), defaultsDomain: nil)
        let step = try #require(steps.first { $0.name == "inMemoryPlaintext" })

        EnrollmentSession.shared.put(armoredKey: "-----BEGIN PGP PRIVATE KEY BLOCK-----")
        #expect(EnrollmentSession.shared.isHeld)
        try await step.run()
        #expect(!EnrollmentSession.shared.isHeld)
    }

    // MARK: - The defaults sweep

    @Test func theSweepRemovesEveryKeyThisAppOwns() async throws {
        let suite = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let graph = try makeGraph(defaults: defaults)
        defaults.set("inbox/Archive", forKey: "mail.cursor.someFolder")
        defaults.set(true, forKey: "contacts.legacyFieldsMigrated")

        let step = try #require(
            SecurityWipeSteps.build(graph: graph, defaultsDomain: suite)
                .first { $0.name == "userDefaults" }
        )
        try await step.run()

        #expect(defaults.string(forKey: "mail.cursor.someFolder") == nil)
        #expect(!defaults.bool(forKey: "contacts.legacyFieldsMigrated"))
    }

    /// **The wipe's own record must outlive the wipe's own deletions.** Sweeping
    /// it away erases the evidence that destruction is still owed, and the next
    /// launch presents a clean first-run app over data that was never deleted.
    @Test func theSweepSparesTheWipeMarker() async throws {
        let suite = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let graph = try makeGraph(defaults: defaults)
        let state = WipeStateStore(defaults: defaults)
        state.begin(hostileLocationEnabled: true)
        defaults.set("something", forKey: "keywords.tabs")

        let step = try #require(
            SecurityWipeSteps.build(graph: graph, defaultsDomain: suite)
                .first { $0.name == "userDefaults" }
        )
        try await step.run()

        #expect(defaults.string(forKey: "keywords.tabs") == nil)
        #expect(state.inProgress)
        #expect(state.attempts == 1)
        #expect(state.hostileLocationWasEnabled)
    }
}
