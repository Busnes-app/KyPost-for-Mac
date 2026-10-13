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
            AppEnvironment.eraseHostileLocationDefaults(in: graph)
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
import SwiftUI
import UIKit
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushLifecycle.onLaunch()
        PushLifecycle.installRebuildHandler()
        PrivacySnapshotCover.install()
        installLifecycleObservers()
        if PushLifecycle.registersForRemoteNotifications {
            application.registerForRemoteNotifications()
        }
        registerBackgroundPull()
        return true
    }

    /// The app is scene-based (the SwiftUI lifecycle generates a scene
    /// manifest), and UIKit does not call the app delegate's
    /// `applicationDidEnterBackground` / `WillEnterForeground` /
    /// `DidBecomeActive` in a scene-based app. The `UIApplication`
    /// notifications are still posted, once per app-level transition however
    /// many scenes are open, so the lifecycle hangs off those. Handled
    /// synchronously on the main queue: the lock must engage before the
    /// background snapshot, not on a later hop.
    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                PushLifecycle.onBackground()
                self?.scheduleBackgroundPull()
            }
        }
        // Resolved here as well as in `onForeground`, because this runs
        // before the first frame is drawn: an expired grace period must cover
        // the app before it is visible, not a moment after.
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SingletonGraph.shared.appLockManager.returnedWithinGrace()
            }
        }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PushLifecycle.onForeground()
            }
        }
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

/// An opaque window over each scene while it is in the background, so the
/// app-switcher snapshot shows no mail.
///
/// A window rather than a SwiftUI overlay: an overlay lives inside the root
/// view's tree, and anything presented from it (reply, forward, pairing, MFA)
/// renders above it. A window at `.alert + 1` sits above every presentation.
/// Installed when the scene enters the background — before the snapshot. On
/// return the grace deadline is resolved first, and the cover lifts only if
/// the app is unlocked; a locked app keeps it, showing the unlock screen, until
/// an unlock (or a reset) clears the lock. The in-tree lock presentation is
/// not something to lift it for: it animates in, and is not guaranteed to sit
/// above a presentation that was open when the app left.
@MainActor
private enum PrivacySnapshotCover {
    private static var covers: [ObjectIdentifier: UIWindow] = [:]

    static func install() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIScene.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated {
                guard let scene,
                      SingletonGraph.shared.appLockManager.backgroundSnapshotNeedsCover
                else { return }
                cover(scene)
            }
        }
        center.addObserver(
            forName: UIScene.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated {
                let mayUncover = SingletonGraph.shared.appLockManager.sceneReturningMayUncover()
                guard let scene else { return }
                if mayUncover {
                    uncover(scene)
                } else {
                    showUnlock(on: scene)
                }
            }
        }
    }

    private static func cover(_ scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard covers[key] == nil else { return }
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
        icon.tintColor = .secondaryLabel
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 36)
        icon.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
        ])
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = controller
        window.accessibilityElementsHidden = true
        window.isHidden = false
        covers[key] = window
    }

    /// Turns a scene's cover into the unlock screen. The cover stays opaque
    /// and above every presentation; only its content changes.
    private static func showUnlock(on scene: UIWindowScene) {
        guard let window = covers[ObjectIdentifier(scene)],
              !(window.rootViewController is UIHostingController<LockedCoverContent>)
        else { return }
        let palette = ThemeManager(defaults: SingletonGraph.launchUserDefaults).palette
        let controller = UIHostingController(rootView: LockedCoverContent(palette: palette) {
            uncoverReturnedScenes()
        })
        controller.view.backgroundColor = UIColor(palette.bg)
        window.rootViewController = controller
        window.accessibilityElementsHidden = false
        window.makeKeyAndVisible()
    }

    private static func uncover(_ scene: UIWindowScene) {
        guard let window = covers.removeValue(forKey: ObjectIdentifier(scene)) else { return }
        let wasKey = window.isKeyWindow
        window.isHidden = true
        window.rootViewController = nil
        if wasKey {
            scene.windows.first { $0 !== window && !$0.isHidden }?.makeKey()
        }
    }

    /// After an unlock: every scene on screen loses its cover. A scene still
    /// in the background keeps it until its own return.
    private static func uncoverReturnedScenes() {
        for window in Array(covers.values) {
            guard let scene = window.windowScene, scene.activationState != .background else { continue }
            uncover(scene)
        }
    }
}

/// The unlock screen inside a privacy cover. Reads the lock through the
/// current graph, so a reset that rebuilds the graph unlocked lifts it too.
private struct LockedCoverContent: View {
    let palette: ThemePalette
    let onUnlocked: () -> Void

    var body: some View {
        let manager = SingletonGraph.shared.appLockManager
        let locked = manager.isLocked
        UnlockView(manager: manager, promptsOnAppear: false)
            .environment(\.theme, palette)
            .onChange(of: locked, initial: true) { _, isLocked in
                if !isLocked { onUnlocked() }
            }
    }
}

#elseif os(macOS)
import AppKit
import CoreGraphics

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
        // The notification is only a hint; the session state decides.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                SingletonGraph.shared.appLockManager.screenUnlockReported(
                    verifiedUnlocked: Self.sessionReportsScreenUnlocked()
                )
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

    /// The login session's own record of the screen lock. Fails closed: no
    /// session dictionary, or a session that is not the one on the console
    /// (another user switched in), means "not verified", so a pending
    /// deadline stands.
    private static func sessionReportsScreenUnlocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              (session[kCGSessionOnConsoleKey] as? Bool) == true
        else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) != true
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
