//
//  AppEnvironment.swift
//  KyPost
//
//  Reconstructable holder for the dependency graph (security-hardening
//  plan, Task 4). SingletonGraph.shared aliases the current graph, so the
//  rest of the app keeps compiling unchanged — the rule is that call sites
//  must re-read .shared per use, never capture a graph child into
//  long-lived state outside the .id(generation)-scoped view trees.
//
//  Rebuilding is how Hostile Location Protection swaps between the
//  disk-backed and in-memory databases: every scene root is keyed on
//  `generation`, so a bump tears down the entire view tree, including all
//  view models holding old DAO references.
//

import Foundation
import Observation
import os
import UserNotifications

extension Notification.Name {
    /// Posted when Hostile Location Protection is toggled. The compose scene
    /// observes it and dismisses: `dismissWindow` is a SwiftUI environment
    /// value available only inside a View, so it can't be called from here.
    static let kyPostCloseComposeWindows = Notification.Name("kypost.closeComposeWindows")
    /// Posted, on the main actor, when this device's pairing is erased: a
    /// security wipe, the failed-unlock reset, or an unpair. App-level state
    /// that outlives graph rebuilds (the router, the KyIdentity sign-on) drops
    /// anything that could present or re-pair afterwards.
    static let kyPostSessionReset = Notification.Name("kypost.sessionReset")
}

/// A block observer that removes itself when released, so an owner can hold
/// it without a `deinit` of its own. Posters of the observed name must be on
/// the main actor; the block runs synchronously on the posting thread.
nonisolated final class NotificationObservation {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(center: NotificationCenter, name: Notification.Name, perform: @escaping @MainActor () -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { perform() }
        }
    }

    deinit { center.removeObserver(token) }
}

extension AppEnvironment {
    /// See `Notification.Name.kyPostSessionReset`.
    static func postSessionReset() {
        NotificationCenter.default.post(name: .kyPostSessionReset, object: nil)
    }
}

@Observable
@MainActor
final class AppEnvironment {
    /// A `ModelContainer` that will not open used to crash the app on launch,
    /// forever, with a crash log the user could do nothing about. It is not a
    /// disposable cache, though: it holds contacts not yet synced, and the
    /// Apple Contacts cards linked to every contact follow it. So the file is
    /// deleted only when this build can never read it (an unknown model
    /// version, a failed migration, a file that is not a database —
    /// `AppDatabase.openFailureDisposition`). Anything else — a full disk, a
    /// locked file, an I/O error — runs this session in memory and keeps the
    /// file for the next launch.
    static let shared = AppEnvironment(graph: makeLaunchGraph())

    private static func makeLaunchGraph() -> SingletonGraph {
        let defaults = SingletonGraph.launchUserDefaults
        // A kept store whose account was left while this ran in memory is
        // erased before anything opens it; if it cannot be, it stays shut.
        guard AppDatabase.storeMayOpen(defaults: defaults) else {
            Log.storage.error("A left account's store could not be erased; running in memory")
            return makeFallbackGraph(preservingStore: true)
        }
        do {
            return try SingletonGraph()
        } catch {
            switch AppDatabase.openFailureDisposition(for: error) {
            case .discard:
                Log.storage.error("Local store unreadable by this build, recreating it: \(error.localizedDescription)")
                try? AppDatabase.deleteStoreFiles()
                // The cursor describes rows the deleted file held.
                ContactCursorStore(defaults: defaults).reset()
                do {
                    return try SingletonGraph()
                } catch {
                    Log.storage.error(
                        "Could not recreate the local store, running without one: \(error.localizedDescription)"
                    )
                }
                return makeFallbackGraph(preservingStore: false)
            case .keep:
                Log.storage.error(
                    "Local store would not open; keeping it and running in memory: \(error.localizedDescription)"
                )
                return makeFallbackGraph(preservingStore: true)
            }
        }
    }

    /// An in-memory session. `preservingStore`: a store file is kept on disk
    /// that this session never opened, so leaving the account must erase it
    /// too (`SingletonGraph.preservedStoreURL`, `AccountTeardown`).
    private static func makeFallbackGraph(preservingStore: Bool) -> SingletonGraph {
        do {
            let graph = try SingletonGraph(database: AppDatabase(inMemory: true))
            if preservingStore { graph.preservedStoreURL = AppDatabase.storeURL }
            return graph
        } catch {
            // An in-memory SwiftData container failing means the schema itself
            // is invalid — a programmer error no user action can resolve.
            fatalError("Could not build an in-memory dependency graph: \(error)")
        }
    }

    private(set) var graph: SingletonGraph
    /// Keyed into every scene root via .id(generation).
    private(set) var generation = 0

    /// Re-runs the launch wiring (notification delegate, contact monitor,
    /// foreground sync) after a rebuild. Set by AppDelegate at launch; nil
    /// in tests, where no runtime services should start.
    var onRebuild: (() -> Void)?

    /// What a security wipe destroys, and how the graph after it is built.
    /// The real step list deletes this container's store, so tests substitute
    /// fakes and a scratch graph; the app never changes either.
    var makeWipeSteps: (SingletonGraph) -> [WipeStep] = { graph in
        SecurityWipeSteps.build(graph: graph, defaultsDomain: Bundle.main.bundleIdentifier)
    }
    var makeGraphAfterWipe: () throws -> SingletonGraph = { try SingletonGraph() }

    init(graph: SingletonGraph) {
        self.graph = graph
    }

    /// Swaps the whole graph. The new graph is built before the old one is
    /// shut down, so a failed rebuild leaves the running app untouched; the
    /// shutdown ensures nothing keeps polling or writing to the superseded
    /// database on a timer.
    func rebuild(makeGraph: () throws -> SingletonGraph) rethrows {
        let newGraph = try makeGraph()
        graph.shutdown()
        graph = newGraph
        generation += 1
        onRebuild?()
    }

    /// Flips Hostile Location Protection: wipes everything cached on disk,
    /// then persists the flag and swaps in a graph built for the new mode
    /// (in-memory when enabled). On enable nothing pre-toggle survives; on
    /// disable the in-memory contents are simply dropped and the fresh disk
    /// store starts empty.
    ///
    /// The wipe covers the mail store, contact photos, staged attachments,
    /// delivered notifications, and open compose drafts — everything the
    /// feature's copy promises. It used to cover only the first and third.
    func setHostileLocationProtection(_ enabled: Bool) throws {
        let store = graph.hostileLocationProtectionStore
        let previous = store.enabled
        do {
            // Wipe before persisting the flag. Setting it first meant a crash,
            // force-quit, or power loss in between left the next launch running
            // in memory — reporting the mode as on — while the complete
            // pre-toggle plaintext store sat on disk with nothing to reconcile
            // it. SingletonGraph re-runs this wipe at launch for the same
            // reason.
            try AppDatabase.deleteStoreFiles()
            // The contact cursor describes rows the deleted file held.
            graph.contactCursorStore.reset()
            try ContactPhotoCache.deleteAll()
            InboxViewModel.purgeAttachmentTempFiles()
            // Sender and subject of everything already delivered sit in
            // Notification Center, which is an on-disk artifact like any other.
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            // The enrollment envelope is the account's OpenPGP private key.
            // Hostile Location Protection is the mode in which this device
            // holds nothing, so it is the one thing that cannot survive the
            // switch — and turning the mode off does not bring it back: the
            // user re-runs the ceremony deliberately, which is the point.
            if enabled {
                graph.enrollmentVault.destroy()
                // Still paired, so the server's record of this device is now
                // wrong in the unsafe direction. After `destroy`, which leaves
                // the marker alone: the next foreground reports "not enrolled".
                graph.enrollmentVault.markTeardownReport()
                graph.mailCursorStore.clear()
                Self.eraseHostileLocationDefaults(in: graph)
            }
            // The unsealed copy goes in both directions, unlike the sealed
            // one. Turning the mode *off* does not restore a key, but leaving
            // a decrypted private key in memory across the switch would mean
            // the mode that promises this device holds nothing briefly held
            // the most sensitive thing there is.
            EnrollmentSession.shared.clear()
            // The compose scene value is archived for state restoration, and a
            // reply's body is the full quoted plaintext of the received
            // message. `.id(generation)` recreates the view inside the window,
            // not the window, so the draft would otherwise survive — and the
            // confirmation dialog promises these are closed.
            NotificationCenter.default.post(name: .kyPostCloseComposeWindows, object: nil)

            store.enabled = enabled
            try rebuild { try SingletonGraph() }
        } catch {
            // Leave the app in the mode it was actually built for.
            store.enabled = previous
            throw error
        }
    }

    /// What Hostile Location Protection erases from `UserDefaults` that its
    /// in-memory stores would otherwise only stop reading. Run when the mode
    /// is turned on and at every launch while it is on, which also repairs a
    /// toggle interrupted before this ran.
    ///
    /// The stores `SingletonGraph` builds on `hostileMemoryDefaults` are
    /// cleared through throwaway copies over the real defaults, so the erase
    /// reaches the plist whichever mode the graph was built in.
    static func eraseHostileLocationDefaults(in graph: SingletonGraph) {
        graph.recipientPinStore.clearPersisted()
        let defaults = graph.userDefaults
        KeywordSettingsStore(defaults: defaults).clear()
        NotificationCursorStore(defaults: defaults).reset()
        ContactCursorStore(defaults: defaults).reset()
        ContactPendingDeletesStore(defaults: defaults).clear()
        VerifiedPgpKeyStore(defaults: defaults).clear()
        // The record of which Contacts cards this app created. Once it is
        // gone those cards are no longer recognised as the app's, so neither
        // Remove Exported Contacts nor a wipe can remove them; SECURITY.md
        // tells the user to remove them before turning the mode on.
        SystemContactsLinkStore(defaults: defaults).clear()
    }

    /// The security wipe, end to end: capture what the network step will need,
    /// destroy everything local, tell the relay, then rebuild the graph.
    ///
    /// The pairing is read **before** the destruction, not at the deregister's
    /// call site. `pairing` is one of the steps below, so reading it at call
    /// time meant the deregister could only ever report "not registered" and
    /// the server kept pushing to a wiped device forever. Holding it in memory
    /// for the duration costs nothing — the same secret was already in memory
    /// to get here, and this process is about to be rebuilt.
    ///
    /// The deregister is deliberately **not** folded into the result. An
    /// unreachable relay says nothing about whether the data on this machine is
    /// gone, every byte of which is already deleted by that line. Counting it
    /// would tell an offline user their mail might still be here when it is
    /// not, and would keep the resume marker set so the app re-ran the whole
    /// destructive pass at every launch until the server came back.
    @discardableResult
    func performSecurityWipe() async -> WipeResult {
        let graph = self.graph
        let pairing = try? graph.securePairingStore.loadPairing()
        let deregisterClient = graph.deregisterClient
        let hostileLocationEnabled = graph.hostileLocationProtectionStore.enabled
        let hostileStore = graph.hostileLocationProtectionStore
        // First, before anything awaits: a sign-on in flight or a deferred
        // pairing link must not re-pair the device this wipe is erasing.
        Self.postSessionReset()

        let result = await graph.securityWipe.run(
            steps: makeWipeSteps(graph),
            hostileLocationEnabled: hostileLocationEnabled,
            restoreHostileLocation: { hostileStore.enabled = true },
            release: SecurityWipeSteps.releaseLock(graph: graph)
        )

        if let pairing, let deviceId = pairing.lastDeviceId, !deviceId.isEmpty,
           !pairing.deviceSecret.isEmpty {
            let outcome = await deregisterClient.deregister(
                serverUrl: pairing.srv, auth: RelayAuth(pairing: pairing)
            )
            if case .failure(let message) = outcome {
                Log.app.error(
                    """
                    Local wipe finished but server deregistration failed (\(message)); \
                    the relay may keep pushing to this device until it is removed server-side
                    """
                )
            }
        }

        // Recorded before the rebuild, which replaces the graph the wipe just
        // emptied — and would take a notice stored there with it.
        wipeNotice = result

        // Rebuilding is what actually closes the SwiftData container's file
        // descriptors on the store the wipe unlinked, and what brings the app
        // back up in the unpaired state the wipe leaves behind — unlocked only
        // if the wipe completed, because only then did `releaseLock` run.
        do {
            try rebuild(makeGraph: makeGraphAfterWipe)
        } catch {
            Log.app.error("Could not rebuild the graph after a wipe: \(error.localizedDescription)")
        }
        return result
    }

    /// Where the startup wipe check has got to.
    ///
    /// The check is a **gate**, and `.pending` exists so it can be used as one:
    /// the root view renders nothing but a neutral placeholder until this
    /// settles. Android ran the equivalent inside a fire-and-forget coroutine
    /// under a comment claiming it ran "before anything reads cached data" —
    /// a claim the launch path could not make — so someone who deleted the
    /// app-lock state to disable the lock got the inbox rendered with every
    /// cached message intact, and the wipe landed a few hundred milliseconds
    /// later, tearing the database out from under a live screen.
    enum StartupWipeVerdict: Equatable {
        case pending
        /// The check finished. `nil` means nothing was needed; a value is the
        /// result of the wipe that ran, so the first screen can say what
        /// actually happened rather than claiming an erasure that failed.
        case settled(WipeResult?)
    }

    private(set) var startupWipeVerdict: StartupWipeVerdict = .pending

    /// Set when a wipe finishes, and held here rather than in the graph
    /// because the graph is replaced by the wipe's own rebuild — a notice
    /// stored in it would be destroyed by the event it describes.
    private(set) var wipeNotice: WipeResult?

    func dismissWipeNotice() { wipeNotice = nil }

    /// Runs the startup gate exactly once per process.
    ///
    /// Once, because a wipe rebuilds the graph and a rebuild re-runs the launch
    /// wiring: without the guard, a wipe would re-enter this and wipe again,
    /// forever.
    func enforceWipeAtStartupOnce() async {
        guard startupWipeVerdict == .pending, !startupCheckBegun else { return }
        startupCheckBegun = true

        let graph = self.graph
        // Checked before the resume, and never cleared by anything but a clean
        // run: past the ceiling the app stops re-running the destructive pass,
        // but it does not stop knowing that data may still be here.
        if let abandoned = graph.securityWipe.abandonedWipe {
            startupWipeVerdict = .settled(abandoned)
            return
        }
        // A wipe that started and never finished is resumed before anything
        // else, *including the tripwire check* — the interrupted run may have
        // deleted the app-lock state the tripwire reads, so relying on the
        // tripwire alone would leave the rest undone forever. Re-running is
        // safe: every step is idempotent.
        guard graph.securityWipe.hasInterruptedWipe || graph.appLockStore.tripwireBroken else {
            startupWipeVerdict = .settled(nil)
            return
        }
        let result = await performSecurityWipe()
        startupWipeVerdict = .settled(result)
    }

    private var startupCheckBegun = false

    /// Escape hatch from the app lock, offered by UnlockView after repeated
    /// authentication failures.
    ///
    /// The lock has no bypass by design, which means a device that can no
    /// longer satisfy `LAContext` — biometrics reset, passcode removed,
    /// enrolment changed — otherwise strands the user with their mail behind a
    /// prompt that can never succeed and a settings screen behind the same
    /// lock. This is not a bypass: it reveals nothing, it erases. Everything
    /// cached locally goes, the pairing goes, and the device comes back
    /// unpaired and unlocked, exactly as if it had been reinstalled.
    ///
    /// **It is the security wipe**, not a list of its own. A separate list
    /// with `try?` deletes turned the lock off even when deletion failed, and
    /// left the PIN hash, pepper, attempt counter, threshold, tripwire, the
    /// defaults domain and the cards exported to Contacts behind. Through the
    /// wipe, every step is reported, an incomplete run keeps its resume marker
    /// and is retried at the next launch (or by pressing Reset again), and the
    /// lock comes off only once the wipe reports complete — so a failed step
    /// brings the app back locked over what it could not delete.
    @discardableResult
    func resetAfterFailedUnlock() async -> WipeResult {
        await performSecurityWipe()
    }
}
