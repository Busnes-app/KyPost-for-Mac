//
//  KyPostApp.swift
//  KyPost
//
//  App entry point: platform delegate, dependency graph, theme, router,
//  deep links, and notification-tap routing. iOS gets the tab layout;
//  macOS gets the split-view window + Preferences + menu commands.
//

import SwiftUI
import SwiftData

@main
struct KyPostApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#endif

    @State private var themeManager = ThemeManager(defaults: SingletonGraph.launchUserDefaults)
    // The router deliberately outlives graph rebuilds (it holds navigation
    // state, not graph state); DeepLinkHandler is a stateless parser.
    @State private var router = NavigationRouter()
#if os(iOS)
    // Outlives graph rebuilds and every screen for the same reason as the
    // router: a KyIdentity sign-on spans a trip to KyAuth, during which the
    // app lock tears the pairing sheet down. It holds no graph state, and it
    // clears itself on `.kyPostSessionReset` (wipe, failed-unlock reset,
    // unpair).
    @State private var signOn = KyIdentitySignOnCoordinator()
    @Environment(\.scenePhase) private var scenePhase
#endif

    private var graph: SingletonGraph { .shared }
    private var environment: AppEnvironment { .shared }

    var body: some Scene {
#if os(macOS)
        mainWindow
            .commands {
                KyPostCommands(router: router)
            }

        WindowGroup("About KyPost", id: "about") {
            AboutView()
                .id(environment.generation)
                .environment(themeManager)
                .environment(router)
                .environment(\.theme, themeManager.palette)
                .preferredColorScheme(themeManager.palette.preferredColorScheme)
                .overlay { LockedOverlay().environment(\.theme, themeManager.palette) }
                .protectedFromCapture()
                .lockAwareRouting(router)
        }
        .defaultSize(width: 480, height: 620)

        // Pop-out reader: one window per email, keyed by relay server id.
        WindowGroup("Email", id: "email", for: String.self) { $serverId in
            EmailWindowView(serverId: serverId ?? "")
                .id(environment.generation)
                .environment(themeManager)
                .environment(router)
                .environment(\.theme, themeManager.palette)
                .environment(\.deviceIsEnrolled, graph.enrollmentVault.isEnrolled)
                .preferredColorScheme(themeManager.palette.preferredColorScheme)
                .background(themeManager.palette.bg.ignoresSafeArea())
                .overlay { LockedOverlay().environment(\.theme, themeManager.palette) }
                .protectedFromCapture()
        }
        .defaultSize(width: 680, height: 620)

        // Compose in its own resizable window (⌘N / toolbar); reply/forward
        // pass a prefill draft, plain compose opens with none.
        WindowGroup("New Email", id: "compose", for: ComposeDraft.self) { $draft in
            ComposeView(draft: draft)
                .id(environment.generation)
                .environment(themeManager)
                .environment(router)
                .environment(\.theme, themeManager.palette)
                .preferredColorScheme(themeManager.palette.preferredColorScheme)
                .background(themeManager.palette.bg.ignoresSafeArea())
                .overlay { LockedOverlay().environment(\.theme, themeManager.palette) }
                .protectedFromCapture()
                .modifier(CloseOnHostileLocationProtection(draft: $draft))
        }
        .defaultSize(width: 640, height: 560)

        Settings {
            MacPreferencesView()
                .id(environment.generation)
                .environment(themeManager)
                .environment(router)
                // AGENTS.md: every scene carries the lock cover. This one did
                // not, so ⌘, reached Remove Pairing (which clears the pinned
                // SPKI hash) and the Hostile Location Protection toggle while
                // the app was locked.
                .overlay { LockedOverlay().environment(\.theme, themeManager.palette) }
                .protectedFromCapture()
        }
#else
        mainWindow
#endif
    }

    private var mainWindow: some Scene {
        WindowGroup {
            rootView
                // Rebuilds (Hostile Location Protection) tear down the whole
                // tree, so no view model outlives its graph.
                .id(environment.generation)
                .environment(themeManager)
                .environment(router)
#if os(iOS)
                .environment(signOn)
#endif
                .environment(\.theme, themeManager.palette)
                // Read here rather than in a row's body: it reads the Keychain,
                // and SwiftUI re-evaluates a list row's body constantly.
                .environment(\.deviceIsEnrolled, graph.enrollmentVault.isEnrolled)
                .preferredColorScheme(themeManager.palette.preferredColorScheme)
                .background(themeManager.palette.bg.ignoresSafeArea())
                .onOpenURL { url in
#if os(iOS)
                    // kypost://kyidentity-signon carries only a nonce and
                    // presents nothing, so the router does not defer it; the
                    // coordinator holds the token exchange itself while the
                    // app is gated, and the pairing link it produces goes
                    // through the router.
                    if signOn.handleReturn(url) { return }
#endif
                    router.handleURL(url)
                }
                .onAppear {
                    // Notification taps (mail body / MFA fallback) route here.
                    graph.pushNotificationDispatcher.onNavigate = { [weak router] action in
                        router?.handle(action)
                    }
#if os(iOS)
                    signOn.deliver = { [weak router] params in
                        router?.handle(.openPairingFlow(params))
                    }
#endif
                }
#if os(iOS)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { signOn.checkForResponse() }
                }
                // The coordinator leaves KyAuth's response unread while the
                // app is locked, the startup wipe check is pending, or an
                // abandoned wipe blocks the app. Returning from KyAuth lands
                // on the lock screen, so this is what picks the response up
                // once the user unlocks.
                .onChange(of: KyIdentitySignOnCoordinator.appIsGated()) { _, gated in
                    if !gated { signOn.checkForResponse() }
                }
#endif
                .task {
                    await graph.runStartupMigrationsIfNeeded()
#if DEBUG
                    // MFA approval normally arrives by push; the screenshot
                    // runner has no server to send one.
                    if graph.isDemo, DemoContent.requestedScreen == "mfa" {
                        router.handle(.openMfaApproval(DemoContent.mfaChallenge))
                    }
#endif
                }
                .overlay { LockedOverlay().environment(\.theme, themeManager.palette) }
                .protectedFromCapture()
        }
        .modelContainer(environment.graph.database.container)
    }

    /// The startup wipe gate, then the app.
    ///
    /// Three states, and the order is the point. An abandoned wipe blocks
    /// everything — data the wipe could not remove is still here, and the
    /// pairing is often part of it. A pending verdict shows a neutral
    /// placeholder rather than the inbox, because a tripwire that is about to
    /// fire must not have rendered the cached mail first. Only then the app,
    /// with a one-time notice above it if a wipe just ran.
    @ViewBuilder
    private var rootView: some View {
        if case .incomplete(let steps, false) = graph.securityWipe.abandonedWipe {
            // Read from the graph, not from `startupWipeVerdict`: a wipe
            // triggered at runtime by ten wrong PINs reaches this state without
            // the startup check ever having seen it, and the block must not wait
            // for a relaunch.
            ManualRecoveryView(failedSteps: steps)
        } else if environment.startupWipeVerdict == .pending {
            StartupGatePlaceholder()
        } else {
            VStack(spacing: 0) {
                if let notice = environment.wipeNotice {
                    SecurityWipeNoticeBanner(result: notice) { environment.dismissWipeNotice() }
                }
                appContent
            }
        }
    }

    @ViewBuilder
    private var appContent: some View {
#if os(macOS)
        MacRootView()
#else
        MainTabView()
#endif
    }
}

#if os(macOS)
/// Closes a compose window when Hostile Location Protection is toggled.
///
/// Two things have to happen and only one of them is the visible one: the
/// scene value is archived for state restoration, and a reply's draft body is
/// the full quoted plaintext of the received message — so clearing the binding
/// is what actually removes mail text from disk. `dismissWindow` lives in the
/// SwiftUI environment and is only reachable from a View, which is why this is
/// a modifier rather than a call in `AppEnvironment`.
private struct CloseOnHostileLocationProtection: ViewModifier {
    @Binding var draft: ComposeDraft?
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .kyPostCloseComposeWindows)
        ) { _ in
            draft = nil
            dismissWindow(id: "compose")
        }
    }
}
#endif

/// Held while the startup wipe check runs. Deliberately says nothing about
/// mail: if the tripwire fires, everything this window could have shown is
/// about to be deleted.
private struct StartupGatePlaceholder: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Checking this Mac…")
                .font(AppFont.ui(13))
                .foregroundStyle(theme.ink.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }
}
