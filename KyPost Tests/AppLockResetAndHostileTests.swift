//
//  AppLockResetAndHostileTests.swift
//  KyPost Tests
//
//  The failed-unlock reset as a security wipe, the PIN pepper's refusal to
//  downgrade, and the stores Hostile Location Protection keeps in memory.
//

import Foundation
import Testing
@testable import KyPost

private func scratchKeychain() -> KeychainStorage {
    KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
}

// MARK: - "Reset KyPost on This Device"

@MainActor
@Suite struct FailedUnlockResetTests {
    private let suite = "tests.\(UUID().uuidString)"
    private let keychain = scratchKeychain()
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    private func makeGraph() throws -> SingletonGraph {
        try SingletonGraph(userDefaults: defaults, keychain: keychain, database: AppDatabase(inMemory: true))
    }

    /// A locked app with a PIN, an attempt count and a lockout — and a wipe
    /// whose `database` step fails while `failing` says so. The rest are the
    /// real steps that are safe to run against a scratch Keychain and suite.
    private func makeEnvironment(failing: Box<Bool>) throws -> AppEnvironment {
        let graph = try makeGraph()
        try graph.appLockStore.setLockEnabled(true)
        try graph.appLockStore.setPin(try PinHasher.hash(pin: "83910472", pepper: FakePinPepper()))
        try graph.appLockStore.setFailedAttempts(4)
        try graph.appLockStore.setLockout(untilMillis: 60_000, durationMillis: 60_000, bootId: "b")
        defaults.set(["Work"], forKey: "keywords.order")

        let environment = AppEnvironment(graph: graph)
        let suite = suite
        environment.makeWipeSteps = { graph in
            [WipeStep("database") { if failing.value { throw WipeStepFailure("store busy") } }]
                + SecurityWipeSteps.build(graph: graph, defaultsDomain: suite)
                    .filter { ["pinPepper", "appLock", "userDefaults"].contains($0.name) }
        }
        environment.makeGraphAfterWipe = { try makeGraph() }
        #expect(environment.graph.appLockManager.isLocked)
        return environment
    }

    /// The old reset deleted with `try?` and turned the lock off regardless,
    /// presenting an unlocked app over whatever survived. Through the wipe, a
    /// failed step is reported, the marker stays for the next launch, and the
    /// rebuilt app is still locked.
    @Test func aPartialFailureLeavesTheAppLockedAndTheWipeOwed() async throws {
        let failing = Box(true)
        let environment = try makeEnvironment(failing: failing)

        let result = await environment.resetAfterFailedUnlock()

        #expect(result == .incomplete(failedSteps: ["database"], willRetry: true))
        #expect(environment.wipeNotice == result)
        #expect(environment.generation == 1)
        let graph = environment.graph
        #expect(graph.appLockManager.isLocked)
        #expect(graph.appLockStore.lockState == .on)
        #expect(graph.securityWipe.hasInterruptedWipe)
        // What the other steps could delete, they did.
        #expect(graph.appLockStore.storedPin == .absent)
        #expect(graph.appLockStore.failedAttempts == 0)
        #expect(graph.appLockStore.lockoutDurationMillis == 0)
        #expect(!graph.appLockStore.wasConfigured)
        #expect(defaults.object(forKey: "keywords.order") == nil)
    }

    /// Pressing Reset again retries; once every step succeeds the lock comes
    /// off and the marker clears.
    @Test func aRetryThatCompletesUnlocksAndClearsTheMarker() async throws {
        let failing = Box(true)
        let environment = try makeEnvironment(failing: failing)
        _ = await environment.resetAfterFailedUnlock()

        failing.value = false
        #expect(await environment.resetAfterFailedUnlock() == .complete)

        let graph = environment.graph
        #expect(!graph.appLockManager.isLocked)
        #expect(graph.appLockStore.lockState == .off)
        #expect(!graph.securityWipe.hasInterruptedWipe)
        #expect(environment.wipeNotice == .complete)
    }

    /// Everything the old list left behind goes: PIN hash, pepper, attempt
    /// counter, lockout, tripwire and the defaults domain.
    @Test func aCompleteResetLeavesNothingBehind() async throws {
        let environment = try makeEnvironment(failing: Box(false))
        try keychain.set("kc:AAAA", forKey: DevicePinPepper.keychainKey)

        #expect(await environment.resetAfterFailedUnlock() == .complete)

        let store = environment.graph.appLockStore
        #expect(store.lockState == .off)
        #expect(store.storedPin == .absent)
        #expect(store.failedAttempts == 0)
        #expect(store.lockoutUntilMillis == 0)
        #expect(!store.wasConfigured)
        #expect(try keychain.string(forKey: DevicePinPepper.keychainKey) == nil)
        #expect(defaults.object(forKey: "keywords.order") == nil)
        #expect(!environment.graph.appLockManager.isLocked)
    }

    /// The real step list keeps the lock flag for the release step.
    @Test func theAppLockStepLeavesTheLockToTheRelease() async throws {
        let graph = try makeGraph()
        try graph.appLockStore.setLockEnabled(true)
        let step = try #require(
            SecurityWipeSteps.build(graph: graph, defaultsDomain: nil).first { $0.name == "appLock" }
        )
        try await step.run()
        #expect(graph.appLockStore.lockState == .on)

        let release = SecurityWipeSteps.releaseLock(graph: graph)
        #expect(release.name == "appLockOff")
        try await release.run()
        #expect(graph.appLockStore.lockState == .off)
    }
}

// MARK: - PIN pepper

@Suite struct DevicePinPepperTests {
    private struct EnclaveRefused: Error {}

    /// An enclave that is there but will not mint a key is an error. Falling
    /// back to the software pepper downgraded the install for good, silently:
    /// the stored prefix pins it to whichever backing it got first.
    @Test func aFailedEnclaveKeyThrowsInsteadOfDowngrading() throws {
        let keychain = scratchKeychain()
        let pepper = DevicePinPepper(
            keychain: keychain,
            secureEnclaveAvailable: { true },
            makeEnclaveKey: { throw EnclaveRefused() }
        )
        #expect(throws: PepperUnavailable.self) { try pepper.ensureExists() }
        #expect(try keychain.string(forKey: DevicePinPepper.keychainKey) == nil)
    }

    /// Without an enclave the software pepper is still what the machine gets.
    @Test func noEnclaveUsesTheSoftwarePepper() throws {
        let keychain = scratchKeychain()
        let asked = Box(false)
        let pepper = DevicePinPepper(
            keychain: keychain,
            secureEnclaveAvailable: { false },
            makeEnclaveKey: { asked.value = true; return Data() }
        )
        try pepper.ensureExists()
        #expect(!asked.value)
        #expect(try keychain.string(forKey: DevicePinPepper.keychainKey)?.hasPrefix("kc:") == true)
        #expect(try pepper.mix(Data("x".utf8)).count == 32)
    }
}

// MARK: - Hostile Location Protection

@MainActor
@Suite struct HostileLocationStoresTests {
    private func makeGraph(defaults: UserDefaults, hostile: Bool) throws -> SingletonGraph {
        HostileLocationProtectionStore(defaults: defaults).enabled = hostile
        return try SingletonGraph(userDefaults: defaults, keychain: scratchKeychain(), database: AppDatabase(inMemory: true))
    }

    private static let accountKeys = [
        "keywords.order", "keywords.visibility", "keywords.allTabVisible",
        "notifications.lastCursor", "contacts.lastCursor",
        "contacts.pendingDeletes", "contacts.pendingDeletes.since",
        "contacts.verifiedPgpKeys", "contacts.systemLinks",
    ]

    private func writeEverything(_ graph: SingletonGraph) {
        graph.keywordSettingsStore.setOrder(["Work"])
        graph.keywordSettingsStore.setVisible(false, for: "Work")
        graph.keywordSettingsStore.allTabVisible = false
        graph.notificationCursorStore.advance(to: 7)
        graph.contactCursorStore.advance(to: 9)
        graph.contactPendingDeletesStore.add("uid-1")
        graph.verifiedPgpKeyStore.remember(uid: "uid-2", key: "KEY")
        graph.systemContactsLinkStore.upsert(SystemContactLink(
            localId: UUID(), uid: "uid-3", cnIdentifier: "cn-1", exportedUpdatedAt: Date()
        ))
    }

    /// The six stores that used to write to defaults whatever the mode keep
    /// working under it, in memory, and write nothing.
    @Test func underTheModeTheAccountStoresWriteNothing() throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let graph = try makeGraph(defaults: defaults, hostile: true)
        #expect(graph.hostileMemoryDefaults != nil)

        writeEverything(graph)

        for key in Self.accountKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) reached defaults")
        }
        #expect(graph.keywordSettingsStore.order() == ["Work"])
        #expect(!graph.keywordSettingsStore.isVisible("Work"))
        #expect(!graph.keywordSettingsStore.allTabVisible)
        #expect(graph.notificationCursorStore.lastCursor == 7)
        #expect(graph.contactCursorStore.lastCursor == 9)
        #expect(graph.contactPendingDeletesStore.all() == ["uid-1"])
        #expect(graph.contactPendingDeletesStore.oldestQueuedAt != nil)
        #expect(graph.verifiedPgpKeyStore.key(forUid: "uid-2") == "KEY")
        #expect(graph.systemContactsLinkStore.all().map(\.cnIdentifier) == ["cn-1"])
    }

    @Test func withTheModeOffTheyPersistAsBefore() throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let graph = try makeGraph(defaults: defaults, hostile: false)
        #expect(graph.hostileMemoryDefaults == nil)
        writeEverything(graph)
        #expect(defaults.integer(forKey: "contacts.lastCursor") == 9)
        #expect(defaults.stringArray(forKey: "keywords.order") == ["Work"])
    }

    /// Switching reads to memory does not remove what was written before.
    /// Turning the mode on, and every launch while it is on, erases it.
    @Test func turningTheModeOnErasesWhatWasPersisted() throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let graph = try makeGraph(defaults: defaults, hostile: false)
        writeEverything(graph)

        AppEnvironment.eraseHostileLocationDefaults(in: graph)

        for key in Self.accountKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) survived")
        }
    }

    /// At launch the graph is already memory-backed; the erase still reaches
    /// the plist rather than the graph's in-memory copy.
    @Test func theLaunchEraseReachesThePlistFromAMemoryGraph() throws {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        writeEverything(try makeGraph(defaults: defaults, hostile: false))
        let hostile = try makeGraph(defaults: defaults, hostile: true)
        hostile.keywordSettingsStore.setOrder(["Kept"])

        AppEnvironment.eraseHostileLocationDefaults(in: hostile)

        for key in Self.accountKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) survived")
        }
        #expect(hostile.keywordSettingsStore.order() == ["Kept"])
    }

    /// The wipe's sweep covers the in-memory copies too.
    @Test func theWipeSweepClearsTheMemoryCopies() async throws {
        let suite = "tests.\(UUID().uuidString)"
        let graph = try makeGraph(defaults: UserDefaults(suiteName: suite)!, hostile: true)
        writeEverything(graph)
        let sweep = try #require(
            SecurityWipeSteps.build(graph: graph, defaultsDomain: suite).first { $0.name == "userDefaults" }
        )
        try await sweep.run()
        #expect(graph.verifiedPgpKeyStore.key(forUid: "uid-2") == nil)
        #expect(graph.systemContactsLinkStore.all().isEmpty)
    }
}

@Suite struct MemoryOnlyDefaultsTests {
    /// Every typed accessor the stores use answers from memory and none of
    /// them reaches the real defaults behind the subclass.
    @Test func typedAccessorsRoundTripWithoutTouchingDisk() {
        let key = "tests.memoryOnly.\(UUID().uuidString)"
        let memory = MemoryOnlyDefaults()

        memory.set(42, forKey: key)
        #expect(memory.integer(forKey: key) == 42)
        memory.set(true, forKey: key)
        #expect(memory.bool(forKey: key))
        memory.set(1.5, forKey: key)
        #expect(memory.double(forKey: key) == 1.5)
        memory.set(["a", "b"], forKey: key)
        #expect(memory.stringArray(forKey: key) == ["a", "b"])
        memory.set(["k": true], forKey: key)
        #expect(memory.dictionary(forKey: key) as? [String: Bool] == ["k": true])
        memory.set(Data([1, 2]), forKey: key)
        #expect(memory.data(forKey: key) == Data([1, 2]))
        memory.set("s", forKey: key)
        #expect(memory.string(forKey: key) == "s")
        #expect(memory.dictionaryRepresentation().keys.contains(key))

        #expect(UserDefaults.standard.object(forKey: key) == nil)

        memory.removeObject(forKey: key)
        #expect(memory.object(forKey: key) == nil)
        #expect(memory.integer(forKey: key) == 0)

        memory.set(1, forKey: key)
        memory.removeAll()
        #expect(memory.object(forKey: key) == nil)
    }
}
