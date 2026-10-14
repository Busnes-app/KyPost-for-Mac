//
//  SecurityTests.swift
//  KyPost Tests
//
//  Security-hardening Task 1: AppLockStore flag persistence and
//  AppLockManager lock/unlock/toggle behavior, with LAContext stubbed
//  behind DeviceAuthenticating.
//

import Foundation
import Testing
@testable import KyPost

/// Closure-driven stand-in for LAContext, which cannot run headless.
/// Counts authenticate calls so tests can pin when re-auth is required.
private struct StubAuthenticator: DeviceAuthenticating {
    var canAuth = true
    var authResult = true
    let authenticateCalls = Box(0)

    func canAuthenticate() -> Bool { canAuth }

    func authenticate(reason: String) async -> Bool {
        authenticateCalls.mutate { $0 += 1 }
        return authResult
    }
}

// MARK: - AppLockStore

@Suite struct AppLockStoreTests {
    @Test func flagsDefaultToFalseAndRoundTrip() throws {
        let store = makeLockStore()
        #expect(!store.lockEnabled)
        #expect(!store.credentialGateEnabled)

        try store.setLockEnabled(true)
        try store.setCredentialGateEnabled(true)
        #expect(store.lockEnabled)
        #expect(store.credentialGateEnabled)

        try store.setLockEnabled(false)
        #expect(!store.lockEnabled)
        // The two flags are independent items.
        #expect(store.credentialGateEnabled)
    }
}

// MARK: - Credential gate (Task 6)

/// In-memory stand-in for the access-controlled Keychain item, which
/// cannot run headless.
private final class StubGatedStore: GatedCredentialStoring {
    var stored: String?
    var failLoad = false

    func store(_ secret: String) throws { stored = secret }
    func load() throws -> String? { failLoad ? nil : stored }
    func remove() throws { stored = nil }
}

@MainActor
@Suite struct CredentialGateServiceTests {
    private struct Environment {
        var service: CredentialGateService
        var pairingStore: SecurePairingStore
        var lockStore: AppLockStore
        var lockManager: AppLockManager
        var gatedStore: StubGatedStore
    }

    private func makeEnvironment(paired: Bool = true) throws -> Environment {
        let keychain = KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
        let pairingStore = SecurePairingStore(keychain: keychain)
        if paired {
            try pairingStore.savePairing(Pairing(
                sub: "u1", deviceSecret: "s1", srv: server, registrationUrl: nil,
                pairingToken: "pt", lastDeviceId: "dev-1", pairedAt: Date()
            ))
        }
        let lockStore = AppLockStore(keychain: keychain)
        try lockStore.setLockEnabled(true)
        let lockManager = AppLockManager(store: lockStore, authenticator: StubAuthenticator())
        let gatedStore = StubGatedStore()
        let service = CredentialGateService(
            appLockStore: lockStore,
            securePairingStore: pairingStore,
            gatedStore: gatedStore,
            lockManager: lockManager
        )
        return Environment(
            service: service, pairingStore: pairingStore, lockStore: lockStore,
            lockManager: lockManager, gatedStore: gatedStore
        )
    }

    @Test func enableMovesTheSecretBehindTheGateAndKeepsTheSessionWorking() async throws {
        let env = try makeEnvironment()
        _ = await env.lockManager.requestUnlock()

        #expect(env.service.enable())
        #expect(env.gatedStore.stored == "s1")
        #expect(env.lockStore.credentialGateEnabled)
        // The running session still reads the secret (from memory).
        #expect(try env.pairingStore.loadPairing()?.deviceSecret == "s1")
    }

    @Test func lockedReadsThrowCredentialUnavailableAndUnlockRestoresThem() async throws {
        let env = try makeEnvironment()
        _ = await env.lockManager.requestUnlock()
        env.service.enable()

        env.lockManager.lock()
        #expect(env.lockManager.cachedGatedSecret == nil)
        #expect(throws: MailSourceError.credentialUnavailable) {
            try env.pairingStore.loadPairing()
        }

        // Unlock reloads through the access-controlled item.
        #expect(await env.lockManager.requestUnlock())
        #expect(try env.pairingStore.loadPairing()?.deviceSecret == "s1")
    }

    /// Declining the presence prompt has to leave the app locked. Unlocking
    /// without the secret would show a working UI whose every relay call
    /// silently no-ops, and `requestUnlock` is the only place the in-memory
    /// copy can be repopulated — so it must not be spent on a failed load.
    @Test func aDeclinedPresencePromptKeepsTheAppLocked() async throws {
        let env = try makeEnvironment()
        _ = await env.lockManager.requestUnlock()
        env.service.enable()
        env.lockManager.lock()

        env.gatedStore.failLoad = true
        #expect(await !env.lockManager.requestUnlock())
        #expect(env.lockManager.isLocked)
        #expect(throws: MailSourceError.credentialUnavailable) {
            try env.pairingStore.loadPairing()
        }

        // Retrying is just another unlock — no relock needed to get out.
        env.gatedStore.failLoad = false
        #expect(await env.lockManager.requestUnlock())
        #expect(!env.lockManager.isLocked)
        #expect(try env.pairingStore.loadPairing()?.deviceSecret == "s1")
    }

    /// The gate can only be reached while the app lock is on. If a partial
    /// write ever leaves it enabled without the lock, nothing in the running
    /// session can undo it — relaunching repairs it.
    @Test func launchRepairsAGateLeftEnabledWithoutTheAppLock() async throws {
        let env = try makeEnvironment()
        _ = await env.lockManager.requestUnlock()
        env.service.enable()
        // The state Settings now refuses to create.
        try env.lockStore.setLockEnabled(false)

        let freshManager = AppLockManager(
            store: env.lockStore, authenticator: StubAuthenticator()
        )
        let freshService = CredentialGateService(
            appLockStore: env.lockStore,
            securePairingStore: env.pairingStore,
            gatedStore: env.gatedStore,
            lockManager: freshManager
        )
        freshService.wireAtLaunch()

        #expect(!freshService.isEnabled)
        #expect(!env.lockStore.credentialGateEnabled)
        #expect(env.gatedStore.stored == nil)
        // The pairing works again without any unlock, which is the point.
        #expect(try env.pairingStore.loadPairing()?.deviceSecret == "s1")
    }

    @Test func reregistrationWritesTheFreshSecretThroughTheGate() async throws {
        let env = try makeEnvironment()
        _ = await env.lockManager.requestUnlock()
        env.service.enable()

        var pairing = try #require(try env.pairingStore.loadPairing())
        pairing.deviceSecret = "s2-minted"
        try env.pairingStore.savePairing(pairing)

        #expect(env.gatedStore.stored == "s2-minted")
        #expect(try env.pairingStore.loadPairing()?.deviceSecret == "s2-minted")
    }

    @Test func disableRestoresThePlainSecretAndRemovesTheGatedCopy() async throws {
        let env = try makeEnvironment()
        _ = await env.lockManager.requestUnlock()
        env.service.enable()

        #expect(env.service.disable())
        #expect(env.gatedStore.stored == nil)
        #expect(!env.lockStore.credentialGateEnabled)
        env.lockManager.lock()
        // Gate off: reads work regardless of lock state, as before.
        #expect(try env.pairingStore.loadPairing()?.deviceSecret == "s1")
    }

    @Test func clearingThePairingDropsTheGatedCopyToo() async throws {
        let env = try makeEnvironment()
        _ = await env.lockManager.requestUnlock()
        env.service.enable()

        try env.pairingStore.clear()

        #expect(env.gatedStore.stored == nil)
        #expect(!env.service.isEnabled)
        #expect(try env.pairingStore.loadPairing() == nil)
    }

    @Test func enableRefusesWithoutAPairing() throws {
        let env = try makeEnvironment(paired: false)
        #expect(!env.service.enable())
        #expect(!env.lockStore.credentialGateEnabled)
    }

    @Test func wireAtLaunchRestoresTheGateForAnAlreadyEnabledFlag() async throws {
        let env = try makeEnvironment()
        _ = await env.lockManager.requestUnlock()
        env.service.enable()
        env.lockManager.lock()

        // A "new process": same stores, fresh manager and service.
        let freshManager = AppLockManager(
            store: env.lockStore, authenticator: StubAuthenticator()
        )
        let freshService = CredentialGateService(
            appLockStore: env.lockStore,
            securePairingStore: env.pairingStore,
            gatedStore: env.gatedStore,
            lockManager: freshManager
        )
        freshService.wireAtLaunch()

        #expect(freshService.isEnabled)
        #expect(throws: MailSourceError.credentialUnavailable) {
            try env.pairingStore.loadPairing()
        }
        _ = await freshManager.requestUnlock()
        #expect(try env.pairingStore.loadPairing()?.deviceSecret == "s1")
    }
}

// MARK: - Hostile Location Protection (Task 5)

@Suite struct HostileLocationProtectionTests {
    @Test func storeFlagRoundTrips() {
        let store = HostileLocationProtectionStore(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        )
        #expect(!store.enabled)
        store.enabled = true
        #expect(store.enabled)
        store.enabled = false
        #expect(!store.enabled)
    }

    @Test func deleteStoreFilesRemovesTheSqliteTrio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "storewipe.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "default.store")
        for suffix in ["", "-wal", "-shm"] {
            FileManager.default.createFile(
                atPath: store.path + suffix, contents: Data("x".utf8)
            )
        }

        try AppDatabase.deleteStoreFiles(at: store)

        for suffix in ["", "-wal", "-shm"] {
            #expect(!FileManager.default.fileExists(atPath: store.path + suffix))
        }
        // Deleting again with nothing there is not an error.
        try AppDatabase.deleteStoreFiles(at: store)
    }

    @Test @MainActor func graphBuildsInMemoryWhenTheFlagIsSet() throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        HostileLocationProtectionStore(defaults: defaults).enabled = true

        let graph = try SingletonGraph(
            userDefaults: defaults,
            keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
        )

        #expect(graph.database.isInMemory)
    }

    @Test @MainActor func purgeRemovesTheAttachmentStagingArea() throws {
        let root = InboxViewModel.attachmentTempRoot
        let file = root.appending(path: "m-1/0/report.pdf")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))

        InboxViewModel.purgeAttachmentTempFiles()

        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

// MARK: - Backup exclusion (Task 8)

@Suite struct BackupExclusionTests {
    @Test func marksTheStoreTrioExcluded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "backupexclude.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "default.store")
        for suffix in ["", "-wal"] {
            FileManager.default.createFile(atPath: store.path + suffix, contents: Data("x".utf8))
        }

        // The missing -shm sibling must not be an error.
        try AppDatabase.excludeStoreFromBackup(at: store)

        for suffix in ["", "-wal"] {
            let values = try URL(fileURLWithPath: store.path + suffix)
                .resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
        }
    }
}

// MARK: - AppLockManager

@MainActor
@Suite struct AppLockManagerTests {
    @Test func startsUnlockedWhenTheFeatureIsOff() {
        let manager = AppLockManager(store: makeLockStore(), authenticator: StubAuthenticator())
        #expect(!manager.isLocked)
    }

    @Test func startsLockedWhenTheFeatureIsOn() throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let manager = AppLockManager(store: store, authenticator: StubAuthenticator())
        #expect(manager.isLocked)
    }

    @Test func lockIsANoOpWhileTheFeatureIsOff() {
        let manager = AppLockManager(store: makeLockStore(), authenticator: StubAuthenticator())
        manager.lock()
        #expect(!manager.isLocked)
    }

    @Test func successfulUnlockClearsTheLockAndFiresOnUnlock() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let manager = AppLockManager(store: store, authenticator: StubAuthenticator())
        let unlocked = Box(0)
        manager.onUnlock = { unlocked.mutate { $0 += 1 } }

        #expect(await manager.requestUnlock())
        #expect(!manager.isLocked)
        #expect(unlocked.value == 1)

        // Already unlocked: succeeds without another prompt.
        #expect(await manager.requestUnlock())
        #expect(unlocked.value == 1)
    }

    @Test func failedUnlockStaysLocked() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let manager = AppLockManager(
            store: store,
            authenticator: StubAuthenticator(authResult: false)
        )
        #expect(await !manager.requestUnlock())
        #expect(manager.isLocked)
    }

    @Test func relockFiresOnLockAndUnlockPromptsAgain() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let stub = StubAuthenticator()
        let manager = AppLockManager(store: store, authenticator: stub)
        let locked = Box(0)
        manager.onLock = { locked.mutate { $0 += 1 } }

        _ = await manager.requestUnlock()
        manager.lock()
        #expect(manager.isLocked)
        #expect(locked.value == 1)
        // Locking again while already locked does not re-fire.
        manager.lock()
        #expect(locked.value == 1)

        _ = await manager.requestUnlock()
        #expect(stub.authenticateCalls.value == 2)
    }

    @Test func enablingIsRefusedWithoutDeviceAuthentication() async {
        let store = makeLockStore()
        let manager = AppLockManager(
            store: store,
            authenticator: StubAuthenticator(canAuth: false)
        )
        #expect(await !manager.setLockEnabled(true))
        #expect(!store.lockEnabled)
    }

    @Test func enablingDoesNotLockTheRunningSession() async {
        let store = makeLockStore()
        let manager = AppLockManager(store: store, authenticator: StubAuthenticator())
        #expect(await manager.setLockEnabled(true))
        #expect(store.lockEnabled)
        #expect(!manager.isLocked)
        // …but the next trigger locks.
        manager.lock()
        #expect(manager.isLocked)
    }

    @Test func disablingRequiresReauthentication() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)

        let refused = AppLockManager(
            store: store,
            authenticator: StubAuthenticator(authResult: false)
        )
        #expect(await !refused.setLockEnabled(false))
        #expect(store.lockEnabled)
        #expect(refused.isLocked)

        let allowed = AppLockManager(store: store, authenticator: StubAuthenticator())
        #expect(await allowed.setLockEnabled(false))
        #expect(!store.lockEnabled)
        #expect(!allowed.isLocked)
    }
}

// MARK: - Regressions from the hostile review

@Suite struct AppLockFlagStateTests {
    /// `lockEnabled` collapsing every read failure into "off" was fine for
    /// deciding what to show and wrong for deciding to *repair*: one transient
    /// Keychain status at launch used to read as "the user turned the lock off"
    /// and move the device secret out from behind user presence for good.
    @Test func aStoredFlagReportsOnOrOff() throws {
        let store = makeLockStore()
        #expect(store.lockState == .off)
        try store.setLockEnabled(true)
        #expect(store.lockState == .on)
        #expect(store.lockEnabled)
        try store.setLockEnabled(false)
        #expect(store.lockState == .off)
        #expect(!store.lockEnabled)
    }
}

@MainActor
@Suite struct UnlockEscapeHatchTests {
    /// A device whose biometric enrolment changed fails every unlock, and the
    /// setting that turns the lock off lives behind the lock. Without a way
    /// out that is a permanent lockout, not a security control.
    @Test func repeatedFailuresOfferTheReset() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let manager = AppLockManager(
            store: store,
            authenticator: StubAuthenticator(authResult: false)
        )
        #expect(!manager.shouldOfferReset)
        for _ in 0..<3 { _ = await manager.requestUnlock() }
        #expect(manager.failedUnlockAttempts == 3)
        #expect(manager.shouldOfferReset)
    }

    @Test func aSuccessfulUnlockClearsTheCounter() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let manager = AppLockManager(
            store: store,
            authenticator: StubAuthenticator(authResult: false)
        )
        _ = await manager.requestUnlock()
        #expect(manager.failedUnlockAttempts == 1)

        let working = AppLockManager(store: store, authenticator: StubAuthenticator())
        _ = await working.requestUnlock()
        #expect(working.failedUnlockAttempts == 0)
    }

    /// The settings screen turns the credential gate off in the same step, and
    /// that downgrade has to land after an authentication, not before — while
    /// still costing one prompt rather than two.
    @Test func disableAfterAuthenticationDoesNotPromptAgain() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let stub = StubAuthenticator()
        let manager = AppLockManager(store: store, authenticator: stub)

        #expect(await manager.confirmWithDeviceAuth(reason: "test"))
        #expect(stub.authenticateCalls.value == 1)
        #expect(manager.disableLockAfterAuthentication())
        #expect(stub.authenticateCalls.value == 1)
        #expect(!manager.isLockEnabled)
        #expect(!manager.isLocked)
        #expect(!store.lockEnabled)
    }

    /// Dismissing the prompt — or the system taking it down — says nothing
    /// about whether the device can still authenticate, so it must not move
    /// the destructive reset closer.
    @Test func aCancelledPromptIsNotAFailure() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let manager = AppLockManager(store: store, authenticator: OutcomeAuthenticator(.cancelled))
        for _ in 0..<5 { #expect(await !manager.requestUnlock()) }
        #expect(manager.isLocked)
        #expect(manager.failedUnlockAttempts == 0)
        #expect(!manager.shouldOfferReset)
    }

    /// Every macOS window carries a lock screen. Asking at once must raise one
    /// prompt, not one per window, and every caller gets its answer.
    @Test func concurrentUnlockRequestsShareOnePrompt() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let gate = GatedAuthenticator()
        let manager = AppLockManager(store: store, authenticator: gate)

        async let first = manager.requestUnlock()
        async let second = manager.requestUnlock()
        async let third = manager.requestUnlock()
        while gate.calls.value == 0 { await Task.yield() }
        gate.release(.success)
        let results = await [first, second, third]

        #expect(results == [true, true, true])
        #expect(gate.calls.value == 1)
        #expect(!manager.isLocked)
    }

    /// The automatic prompt is raised once per lock, whichever window asks
    /// first; the Unlock button still prompts on demand.
    @Test func theAutomaticPromptIsRaisedOncePerLock() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let stub = StubAuthenticator(authResult: false)
        let manager = AppLockManager(store: store, authenticator: stub)

        await manager.autoPromptUnlock()
        await manager.autoPromptUnlock()
        #expect(stub.authenticateCalls.value == 1)

        await manager.requestUnlock()
        #expect(stub.authenticateCalls.value == 2)
    }

    @Test func aNewLockGetsANewAutomaticPrompt() async throws {
        let store = makeLockStore()
        try store.setLockEnabled(true)
        let stub = StubAuthenticator()
        let manager = AppLockManager(store: store, authenticator: stub)

        await manager.autoPromptUnlock()
        #expect(!manager.isLocked)
        manager.lock()
        await manager.autoPromptUnlock()
        #expect(stub.authenticateCalls.value == 2)
    }
}

// MARK: - An unreadable lock flag is a locked app

@MainActor
@Suite struct UnreadableLockStateTests {
    private func manager(
        _ state: Box<AppLockStore.FlagState>,
        authenticator: any DeviceAuthenticating = StubAuthenticator()
    ) -> AppLockManager {
        AppLockManager(store: makeLockStore(), authenticator: authenticator, readLockState: { state.value })
    }

    /// `errSecInteractionNotAllowed` at launch is normal for a Mac login
    /// item. Reading it as "off" started the app unlocked and made `lock()`
    /// a no-op for the whole session.
    @Test func anUnreadableFlagStartsLocked() {
        let lock = manager(Box(.unreadable))
        #expect(lock.isLocked)
        #expect(lock.isLockEnabled)
        #expect(lock.isLockStateUnresolved)
    }

    @Test func lockStillEngagesAfterAnUnreadableLaunch() async {
        let lock = manager(Box(.unreadable))
        #expect(await lock.requestUnlock())
        lock.lock()
        #expect(lock.isLocked)
    }

    /// Once the Keychain answers "off", the lock was never on: it lifts
    /// without a prompt.
    @Test func aLaterOffReleasesWithoutAPrompt() {
        let state = Box(AppLockStore.FlagState.unreadable)
        let stub = StubAuthenticator()
        let lock = manager(state, authenticator: stub)
        let unlocked = Box(0)
        lock.onUnlock = { unlocked.mutate { $0 += 1 } }

        lock.refreshLockState()
        #expect(lock.isLocked)

        state.value = .off
        lock.refreshLockState()
        #expect(!lock.isLocked)
        #expect(!lock.isLockEnabled)
        #expect(!lock.isLockStateUnresolved)
        #expect(unlocked.value == 1)
        #expect(stub.authenticateCalls.value == 0)
    }

    @Test func aLaterOnKeepsItLocked() {
        let state = Box(AppLockStore.FlagState.unreadable)
        let lock = manager(state)
        state.value = .on
        lock.refreshLockState()
        #expect(lock.isLocked)
        #expect(lock.isLockEnabled)
        #expect(!lock.isLockStateUnresolved)
    }

    /// The unlock path re-reads first, so a Keychain that became readable
    /// and says "off" does not ask for anything.
    @Test func requestUnlockReReadsTheFlag() async {
        let state = Box(AppLockStore.FlagState.unreadable)
        let stub = StubAuthenticator()
        let lock = manager(state, authenticator: stub)
        state.value = .off
        #expect(await lock.requestUnlock())
        #expect(stub.authenticateCalls.value == 0)
    }

    /// Only an *unresolved* flag may release the lock. One that read "on" and
    /// later reads "off" is not a reason to open the app mid-session.
    @Test func aResolvedFlagIsNotReReadIntoAnUnlock() {
        let state = Box(AppLockStore.FlagState.on)
        let lock = manager(state)
        state.value = .off
        lock.refreshLockState()
        #expect(lock.isLocked)
    }
}

/// Answers every prompt with one outcome.
private struct OutcomeAuthenticator: DeviceAuthenticating {
    let outcome: DeviceAuthOutcome
    init(_ outcome: DeviceAuthOutcome) { self.outcome = outcome }
    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> Bool { outcome == .success }
    func authenticateForUnlock(reason: String) async -> DeviceAuthOutcome { outcome }
}

/// Holds every prompt open until the test releases it.
private final class GatedAuthenticator: DeviceAuthenticating, @unchecked Sendable {
    let calls = Box(0)
    private let result = Box<DeviceAuthOutcome?>(nil)

    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> Bool { await authenticateForUnlock(reason: reason) == .success }

    func authenticateForUnlock(reason: String) async -> DeviceAuthOutcome {
        calls.mutate { $0 += 1 }
        while true {
            if let outcome = result.value { return outcome }
            await Task.yield()
        }
    }

    func release(_ outcome: DeviceAuthOutcome) { result.value = outcome }
}

@MainActor
@Suite struct LockAwareRoutingTests {
    private func makeRouter(locked: Bool) -> NavigationRouter {
        let router = NavigationRouter()
        router.isLocked = { locked }
        return router
    }

    private var challenge: MfaChallenge {
        MfaChallenge(challengeId: "c1", receivedAt: Date(), matchDigits: "47")
    }

    /// The lock cover loses to a sheet on both platforms — window-modal on
    /// macOS, one-presentation-per-view on iOS — so an MFA approval used to be
    /// reachable on a locked app. Refusing to route is the control.
    @Test func nothingPresentsWhileLocked() {
        let router = makeRouter(locked: true)
        router.handle(.openMfaApproval(challenge))
        #expect(router.mfaRoute == nil)

        router.handle(.openDesktopPairingFlow(
            DesktopPairingParams(code: String(repeating: "a", count: 32), srv: "https://x.example")
        ))
        #expect(router.desktopPairingParams == nil)
    }

    @Test func theDeferredActionReplaysOnUnlock() {
        let router = makeRouter(locked: true)
        router.handle(.openMfaApproval(challenge))
        #expect(router.mfaRoute == nil)

        router.isLocked = { false }
        router.resumeDeferredAction()
        #expect(router.mfaRoute?.challenge.challengeId == "c1")

        // Replayed once, not on every unlock afterwards.
        router.mfaRoute = nil
        router.resumeDeferredAction()
        #expect(router.mfaRoute == nil)
    }

    @Test func lockingDismissesEverythingPresented() {
        let router = makeRouter(locked: false)
        router.handle(.openMfaApproval(challenge))
        #expect(router.mfaRoute != nil)

        router.dismissPresentedRoutes()
        #expect(router.mfaRoute == nil)
        #expect(router.pairingParams == nil)
        #expect(router.desktopPairingParams == nil)
    }

    @Test func routingWorksNormallyWhileUnlocked() {
        let router = makeRouter(locked: false)
        router.handle(.openEmail(messageId: "m1"))
        #expect(router.pendingMessageId == "m1")
        #expect(router.selectedTab == .inbox)
    }
}
