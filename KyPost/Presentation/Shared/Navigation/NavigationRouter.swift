//
//  NavigationRouter.swift
//  KyPost
//
//  App-level routing state (spec §10). Receives NavigationActions from deep
//  links and notification taps and drives tab selection + presented sheets.
//

import SwiftUI
import Observation

enum AppTab: Hashable {
    case inbox
    case contacts
    case settings
}

/// Identifiable wrapper so an MFA challenge can drive a sheet.
struct MfaRoute: Identifiable, Equatable {
    let challenge: MfaChallenge
    var id: String { challenge.challengeId }
}

extension PairingParams: Identifiable {
    var id: String { "\(sub)|\(srv)" }
}

@Observable
@MainActor
final class NavigationRouter {
    var selectedTab: AppTab = .inbox
    /// Presented pairing flow (from QR / deep link).
    var pairingParams: PairingParams?
    /// Presented in-app MFA approval fallback.
    var mfaRoute: MfaRoute?
    /// Message the inbox should open once loaded (from a notification tap).
    var pendingMessageId: String?
    /// A compose the platform shell should open (a `mailto:` link). The shell
    /// takes it with `takeComposeRequest()` and owns the window or sheet from
    /// then on, so the lock's route teardown never discards a message being
    /// written — only a request not yet taken.
    var composeRequest: ComposeDraft?

    private let deepLinkHandler: DeepLinkHandler
    /// Held while the lock is engaged, replayed on unlock. At most one — a
    /// queue would replay a stale backlog of sign-in prompts at the user.
    private var deferredAction: NavigationAction?

    /// Whether the app lock is engaged. Injected rather than read from the
    /// graph directly so the routing rule is testable, and because this router
    /// deliberately outlives graph rebuilds.
    var isLocked: () -> Bool = { SingletonGraph.shared.appLockManager.isLocked }

    @ObservationIgnored private var resetObservation: NotificationObservation?

    init(
        deepLinkHandler: DeepLinkHandler = DeepLinkHandler(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.deepLinkHandler = deepLinkHandler
        // This router outlives graph rebuilds, so a pairing link deferred
        // behind the lock would otherwise replay into the app a wipe just
        // erased — the rebuilt graph comes up unlocked.
        resetObservation = NotificationObservation(
            center: notificationCenter,
            name: .kyPostSessionReset
        ) { [weak self] in
            self?.discardForSessionReset()
        }
    }

    /// Drops the deferred action and everything presented. Runs on
    /// `.kyPostSessionReset`.
    func discardForSessionReset() {
        deferredAction = nil
        dismissPresentedRoutes()
    }

    /// Nothing presents while locked.
    ///
    /// The lock cover is a `fullScreenCover` on iOS and an `.overlay` on macOS,
    /// and both lose to a sheet: on macOS a window-modal sheet renders above the
    /// overlay, and on iOS SwiftUI allows one presentation per view, so a sheet
    /// already on screen stops the cover presenting at all. Either way an MFA
    /// approval or a pairing flow was reachable on a locked app. Refusing to
    /// route is the fix; the cover is the backstop, not the control.
    func handle(_ action: NavigationAction) {
        guard !isLocked() else {
            deferredAction = action
            return
        }
        apply(action)
    }

    private func apply(_ action: NavigationAction) {
        switch action {
        case .openPairingFlow(let params):
            pairingParams = params
        case .openEmail(let messageId):
            selectedTab = .inbox
            pendingMessageId = messageId
        case .openMfaApproval(let challenge):
            mfaRoute = MfaRoute(challenge: challenge)
        case .composeMail(let draft):
            selectedTab = .inbox
            composeRequest = draft
        }
    }

    /// Entry point for onOpenURL.
    func handleURL(_ url: URL) {
        guard let action = deepLinkHandler.handle(url) else { return }
        handle(action)
    }

    /// Tears down everything presented when the lock engages, so no sheet is
    /// left on screen for the cover to lose a race against.
    func dismissPresentedRoutes() {
        pairingParams = nil
        mfaRoute = nil
        composeRequest = nil
    }

    /// Hands a pending compose to the shell, once. A shell that shows one
    /// compose at a time (the iOS sheet) passes `composeIsOpen`: the request
    /// then stays pending until that compose closes, because swapping the
    /// sheet's content would drop the message being written without asking.
    /// Pending holds one request — a newer link replaces an unopened one,
    /// never an open compose.
    func takeComposeRequest(composeIsOpen: Bool = false) -> ComposeDraft? {
        guard !composeIsOpen else { return nil }
        defer { composeRequest = nil }
        return composeRequest
    }

    /// Replays the action the lock deferred, if it is still worth showing.
    func resumeDeferredAction() {
        guard let action = deferredAction else { return }
        deferredAction = nil
        apply(action)
    }
}

/// Keeps presentation and lock state in step for a scene root.
private struct LockAwareRouting: ViewModifier {
    let router: NavigationRouter

    private var isLocked: Bool { SingletonGraph.shared.appLockManager.isLocked }

    func body(content: Content) -> some View {
        // `initial: true` covers launching straight into the locked state,
        // where no transition ever fires.
        content.onChange(of: isLocked, initial: true) { _, locked in
            if locked {
                router.dismissPresentedRoutes()
            } else {
                router.resumeDeferredAction()
            }
        }
    }
}

extension View {
    /// Dismisses presented routes when the lock engages and replays the
    /// deferred deep link or notification tap once it clears.
    func lockAwareRouting(_ router: NavigationRouter) -> some View {
        modifier(LockAwareRouting(router: router))
    }
}
