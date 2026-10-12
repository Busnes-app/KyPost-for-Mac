//
//  AppDelegate.swift
//  KyPost
//
//  Platform app delegates: APNs registration, token forwarding, incoming
//  remote notifications, and pull-mode lifecycle (spec §3).
//

import Foundation
import os

/// Shared launch/lifecycle logic used by both platform delegates.
@MainActor
private enum PushLifecycle {
    /// Retained for the life of the process. A dispatch source stops watching
    /// as soon as its last reference goes, so this cannot be a local.
    static var memoryPressureWatch: MemoryPressureWatch?

    static func onLaunch() {
        let graph = SingletonGraph.shared
        // First, and guarded against re-entry: a wipe rebuilds the graph, and a
        // rebuild re-runs this function. The root view holds a neutral
        // placeholder until the verdict settles, so no screen reads cached data
        // the tripwire is about to have erased.
        Task { await AppEnvironment.shared.enforceWipeAtStartupOnce() }
        // Memory pressure is the moment the kernel starts looking for pages to
        // swap, and a private key written to a swap file has outlived every
        // boundary this app controls.
        memoryPressureWatch = MemoryPressureWatch()
        // Re-apply the Hostile Location Protection wipe if the mode is on.
        // Idempotent, and it repairs a toggle interrupted before its own erase
        // finished: the flag is persisted after the wipe, but a crash between
        // the erase and the rebuild would otherwise leave the app reporting the
        // mode as on while pre-toggle plaintext sat on disk, with nothing
        // anywhere reconciling the flag against the filesystem.
        //
        // Here rather than in SingletonGraph.init so constructing a graph is
        // never destructive — tests build graphs with this flag set.
        if graph.hostileLocationProtectionStore.enabled {
            do {
                try AppDatabase.deleteStoreFiles()
                try ContactPhotoCache.deleteAll()
            } catch {
                Log.storage.error(
                    "Could not re-apply the hostile-location wipe: \(error.localizedDescription)"
                )
            }
        }
        graph.pushNotificationDispatcher.configure()
        graph.systemContactsChangeMonitor.start()
        // Must precede the first poll: a gated pairing read without the
        // hooks would serve the blank plain-item secret.
        graph.credentialGateService.wireAtLaunch()
        // While locked, onForeground is skipped; run the deferred sync the
        // moment the user unlocks instead.
        graph.appLockManager.onUnlock = { onForeground() }
        // The wipe threshold is only real if something is wired to act on it.
        // Left unset, `AppLockManager` reports the eleventh wrong PIN as a wipe
        // that could not run rather than silently rejecting it, so a missing
        // wiring is visible instead of quietly disabling the whole ladder.
        graph.appLockManager.onWipe = { await AppEnvironment.shared.performSecurityWipe() }
        // The screenshot build has no pairing to deliver to, and must not
        // change the real app's notification permission or APNs token.
        guard !graph.isDemo else { return }
        Task {
            await graph.pushNotificationDispatcher.requestAuthorization()
        }
    }

    static var registersForRemoteNotifications: Bool { !SingletonGraph.shared.isDemo }

    /// A graph rebuild (Hostile Location Protection toggle) needs the launch
    /// wiring re-run against the new graph.
    ///
    /// Installed once from the platform delegate, not from `onLaunch`: doing it
    /// there meant `onLaunch` assigned a closure that calls `onLaunch`, which
    /// reassigned the same property — from inside `rebuild`, while that
    /// property was being invoked. It worked only by ordering luck, and it
    /// re-ran `requestAuthorization` on every toggle.
    static func installRebuildHandler() {
        AppEnvironment.shared.onRebuild = {
            onLaunch()
            onForeground()
        }
    }

    static func onDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let graph = SingletonGraph.shared
        graph.pushSettingsStore.lastDeviceToken = token
        Task {
            // Re-registration for safety on every token change (spec §3).
            await graph.deviceRegistrationService.reregisterIfPaired(deviceToken: token)
        }
    }

    static func onForeground() {
        let graph = SingletonGraph.shared
        // A return inside the grace period cancels the pending lock; one after
        // it engages the lock before anything below can read the cache.
        graph.appLockManager.returnedWithinGrace()
        // Gate the sync side, not just the pixels: nothing runs until the
        // user unlocks (onUnlock re-enters here).
        guard !graph.appLockManager.isLocked else { return }
        if let token = graph.pushSettingsStore.lastDeviceToken {
            Task {
                await graph.deviceRegistrationService.reregisterIfPaired(deviceToken: token)
            }
        }
        // Immediate tick on foreground, then the 90s cadence (spec §3). In
        // push mode each tick is a heartbeat check (PullHeartbeatPolicy).
        // The explicit poll covers an unlock while the cadence was already
        // running; pollNow is single-flight, so the two never double up.
        graph.pullPollingScheduler.startForegroundPolling()
        Task {
            await graph.pullPollingScheduler.pollNow()
        }
        // Catch cards added in Contacts.app while we weren't running.
        Task {
            await graph.systemContactsChangeMonitor.reconcileNow()
        }
        runEnrollmentReporter()
    }

    /// Process-wide, not graph-owned: it holds no graph child, and a run that
    /// outlives a rebuild must still keep a second one from starting.
    static let enrollmentReportTrigger = EnrollmentReportTrigger()

    /// An enrollment acknowledgement that did not land, or a teardown the
    /// server has not heard about. A no-op unless a marker is set. Gated on
    /// the app lock and on an abandoned wipe inside the trigger.
    static func runEnrollmentReporter() {
        let graph = SingletonGraph.shared
        enrollmentReportTrigger.fire(
            isLocked: graph.appLockManager.isLocked,
            blockedByAbandonedWipe: graph.securityWipe.blockedByAbandonedWipe,
            makeReporter: { graph.makeEnrollmentStateReporter() }
        )
    }

    static func onBackground() {
        SingletonGraph.shared.pullPollingScheduler.stopForegroundPolling()
        // Also cleared here, not only via lock() below, because `lock()` is a
        // no-op while the app-lock feature is switched off — and a user who
        // has not turned on the app lock still backgrounds the app. The two
        // calls cover different gaps: this one covers lock-disabled
        // backgrounding, and lock() covers the macOS screen lock, which never
        // reaches here.
        EnrollmentSession.shared.clear()
        // iOS lock trigger: backgrounding covers home button, app switch,
        // screen lock, and incoming-call takeover. (macOS never calls this;
        // its trigger is the screen-lock notification in AppDelegate.) The
        // user's grace period defers it; the deadline is resolved on return.
        SingletonGraph.shared.appLockManager.lockAfterGrace()
    }

    static func onRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        await SingletonGraph.shared.pushNotificationDispatcher.handleIncoming(userInfo: userInfo)
    }
}

#if os(iOS)
import UIKit
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushLifecycle.onLaunch()
        PushLifecycle.installRebuildHandler()
        if PushLifecycle.registersForRemoteNotifications {
            application.registerForRemoteNotifications()
        }
        registerBackgroundPull()
        return true
    }

    /// Resolved here as well as in `onForeground`, because this runs before
    /// the first frame is drawn: an expired grace period must cover the app
    /// before it is visible, not a moment after.
    func applicationWillEnterForeground(_ application: UIApplication) {
        SingletonGraph.shared.appLockManager.returnedWithinGrace()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        PushLifecycle.onForeground()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        PushLifecycle.onBackground()
        scheduleBackgroundPull()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushLifecycle.onDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Log.push.error("APNs registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            await PushLifecycle.onRemoteNotification(userInfo)
            completionHandler(.newData)
        }
    }

    // MARK: - Background pull (spec §3 pull mode)

    private func registerBackgroundPull() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Config.backgroundPullTaskId,
            using: nil
        ) { task in
            Task { @MainActor in
                // Same gate as onForeground. Without it, background refresh
                // kept pulling and posting local notifications — sender and
                // subject included — onto the lock screen of a locked app.
                if SingletonGraph.shared.appLockManager.resolvePendingLock() {
                    task.setTaskCompleted(success: false)
                    return
                }
                await SingletonGraph.shared.pullPollingScheduler.pollNow()
                task.setTaskCompleted(success: true)
            }
            Task { @MainActor in
                self.scheduleBackgroundPull() // keep the chain going
            }
        }
    }

    /// Armed whenever the device is paired, in both modes: in push mode the
    /// refresh is the heartbeat, and `pollNow` decides whether it polls.
    private func scheduleBackgroundPull() {
        guard SingletonGraph.shared.securePairingStore.isPaired else { return }
        let request = BGAppRefreshTaskRequest(identifier: Config.backgroundPullTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Config.backgroundPullInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.push.error("Could not schedule background pull: \(error)")
        }
    }
}

#elseif os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        PushLifecycle.onLaunch()
        PushLifecycle.installRebuildHandler()
        if PushLifecycle.registersForRemoteNotifications {
            NSApplication.shared.registerForRemoteNotifications()
        }
        PushLifecycle.onForeground()

        // macOS has no background app refresh; resume polling on wake and
        // let the app poll full-time while running (spec FAQ).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // Same lock gate as onForeground and iOS background refresh:
                // waking from a screen lock wakes a locked app, and the
                // deferred poll runs from onUnlock instead.
                guard !SingletonGraph.shared.appLockManager.resolvePendingLock() else { return }
                await SingletonGraph.shared.pullPollingScheduler.pollNow()
            }
        }

        // macOS lock trigger: the screen locking (screen saver / login
        // window) is the "device left unattended" signal. Deliberately NOT
        // didResignActiveNotification — losing focus to another app is
        // normal Mac usage, not abandonment (design decision 2).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                SingletonGraph.shared.appLockManager.lockAfterGrace()
            }
        }
        // Unlocking the screen inside the grace period is the user coming
        // back: the pending lock is cancelled (or engages, if it expired).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                SingletonGraph.shared.appLockManager.returnedWithinGrace()
            }
        }
    }

    /// macOS has no foreground transition: `onForeground` runs only at launch,
    /// rebuild and unlock. Activation is the "next foreground" a pending
    /// enrollment report waits for. Only the reporter runs here; polling is
    /// already full-time while the app runs.
    func applicationDidBecomeActive(_ notification: Notification) {
        PushLifecycle.runEnrollmentReporter()
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushLifecycle.onDeviceToken(deviceToken)
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Log.push.error("APNs registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        Task {
            await PushLifecycle.onRemoteNotification(userInfo)
        }
    }
}
#endif
