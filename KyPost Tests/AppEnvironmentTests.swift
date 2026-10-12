//
//  AppEnvironmentTests.swift
//  KyPost Tests
//
//  Security-hardening Task 4: the reconstructable dependency graph.
//

import Foundation
import Testing
@testable import KyPost

@MainActor
@Suite struct AppEnvironmentTests {
    private func makeGraph() throws -> SingletonGraph {
        try SingletonGraph(
            userDefaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
            keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)"),
            database: AppDatabase(inMemory: true)
        )
    }

    @Test func rebuildSwapsTheGraphBumpsGenerationAndRunsTheHook() throws {
        let environment = AppEnvironment(graph: try makeGraph())
        let old = environment.graph
        let hookRuns = Box(0)
        environment.onRebuild = { hookRuns.mutate { $0 += 1 } }

        try environment.rebuild { try makeGraph() }

        #expect(environment.generation == 1)
        #expect(environment.graph !== old)
        #expect(hookRuns.value == 1)
    }

    @Test func rebuildStopsTheOldGraphsPolling() throws {
        let environment = AppEnvironment(graph: try makeGraph())
        let old = environment.graph
        old.pushSettingsStore.deliveryMode = .pull
        old.pullPollingScheduler.startForegroundPolling()
        #expect(old.pullPollingScheduler.isPolling)

        try environment.rebuild { try makeGraph() }

        #expect(!old.pullPollingScheduler.isPolling)
    }

    @Test func aFailedRebuildLeavesTheOldGraphRunning() throws {
        struct Boom: Error {}
        let environment = AppEnvironment(graph: try makeGraph())
        let old = environment.graph
        old.pushSettingsStore.deliveryMode = .pull
        old.pullPollingScheduler.startForegroundPolling()

        #expect(throws: Boom.self) {
            try environment.rebuild { throw Boom() }
        }
        #expect(environment.graph === old)
        #expect(environment.generation == 0)
        // The old graph was never shut down — it still polls.
        #expect(old.pullPollingScheduler.isPolling)
    }

    @Test func sharedAliasTracksTheCurrentGraph() {
        #expect(SingletonGraph.shared === AppEnvironment.shared.graph)
    }

    /// Turning Hostile Location Protection on, or launching with it on,
    /// leaves no pinned keys in defaults; pins made afterwards stay in memory.
    @Test func hostileLocationErasesPersistedPinsAndKeepsLaterOnesInMemory() throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let graph = try SingletonGraph(
            userDefaults: defaults,
            keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)"),
            database: AppDatabase(inMemory: true)
        )
        graph.recipientPinStore.pin(addresses: ["a@example.invalid"], publicKey: PinnedKeyFixtures.alicePinned)
        #expect(defaults.data(forKey: "contacts.recipientPins") != nil)

        AppEnvironment.eraseHostileLocationDefaults(in: graph)
        #expect(defaults.data(forKey: "contacts.recipientPins") == nil)

        graph.hostileLocationProtectionStore.enabled = true
        graph.recipientPinStore.pin(addresses: ["b@example.invalid"], publicKey: PinnedKeyFixtures.alicePinned)
        AppEnvironment.eraseHostileLocationDefaults(in: graph)
        #expect(defaults.data(forKey: "contacts.recipientPins") == nil)
        #expect(graph.recipientPinStore.pin(for: "b@example.invalid") != nil)
    }
}
