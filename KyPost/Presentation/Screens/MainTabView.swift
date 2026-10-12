//
//  MainTabView.swift
//  KyPost
//
//  Root navigation (spec §10): Inbox / Contacts / Settings tabs, with the
//  pairing and MFA flows presented as sheets driven by NavigationRouter.
//

import SwiftUI

struct MainTabView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(NavigationRouter.self) private var router

    private var inboxViewModel: InboxViewModel { SingletonGraph.shared.inboxViewModel }
    private var contactsViewModel: ContactsViewModel { SingletonGraph.shared.contactsViewModel }

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            NavigationStack {
                InboxView(viewModel: inboxViewModel)
            }
            .tabItem { Label("Inbox", systemImage: "tray.fill") }
            .tag(AppTab.inbox)

            NavigationStack {
                ContactsListView(viewModel: contactsViewModel)
            }
            .tabItem { Label("Contacts", systemImage: "person.2.fill") }
            .tag(AppTab.contacts)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(AppTab.settings)
        }
        .tint(themeManager.palette.accent)
        .environment(\.theme, themeManager.palette)
        .sheet(item: $router.pairingParams) { params in
            PushPairingView(initialParams: params)
                .environment(\.theme, themeManager.palette)
        }
        .sheet(item: $router.desktopPairingParams) { params in
            DesktopPairingView(initialParams: params)
                .environment(\.theme, themeManager.palette)
        }
        .sheet(item: $router.mfaRoute) { route in
            MfaApprovalView(challenge: route.challenge)
                .environment(\.theme, themeManager.palette)
        }
        .lockAwareRouting(router)
#if os(iOS)
        // While a grace-period lock counts down in the background the app is
        // still unlocked, so the app-switcher snapshot would show mail. Cover
        // it. Best effort: a sheet open at the time sits above this overlay.
        .overlay {
            if SingletonGraph.shared.appLockManager.isLockPending {
                ZStack {
                    themeManager.palette.bg
                    Image(systemName: "lock.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(themeManager.palette.ink.opacity(0.6))
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
            }
        }
        .fullScreenCover(isPresented: lockBinding) {
            UnlockView(manager: SingletonGraph.shared.appLockManager)
                .environment(\.theme, themeManager.palette)
        }
#endif
    }

    /// Presented while locked; dismissal happens only through a successful
    /// unlock flipping `isLocked`, so the setter is a no-op.
    private var lockBinding: Binding<Bool> {
        Binding(
            get: { SingletonGraph.shared.appLockManager.isLocked },
            set: { _ in }
        )
    }
}
