//
//  KyIdentitySignOnCoordinator.swift
//  KyPost
//
//  "Sign in with KyIdentity" on iOS: read the relay's SSO config, hand a
//  request to KyAuth through the App Group, take KyAuth's ID token back, swap
//  it at the relay for a `kypost://native-pair` link, and hand that link to
//  the ordinary pairing flow so registration, TLS pinning and secret storage
//  stay unchanged. Binding contract: KyAuth-iOS
//  docs/specs/2026-10-11-ios-signon-handoff.md.
//
//  App scope, like Android's `appScope` + `PendingPairingLink`: switching to
//  KyAuth backgrounds KyPost, which engages the app lock and tears the pairing
//  sheet down. So this outlives every screen (it is App-level `@State`, beside
//  the router), and never captures the graph: it re-reads
//  `SingletonGraph.shared` per use. It holds the pending nonce in memory only;
//  the ID token lives in a local for one call.
//
//  Two consequences of outliving the graph:
//  - It is an entry point that acts without presenting a window, so it guards
//    itself: KyAuth's response stays unread in the App Group while the app is
//    locked, before the startup wipe verdict settles, or behind an abandoned
//    wipe. KyPostApp re-checks the moment that gate clears.
//  - It survives the events that erase the pairing, so it listens for
//    `.kyPostSessionReset` (security wipe, failed-unlock reset, unpair) and
//    drops everything it holds. Otherwise "erase everything" could be
//    followed by an automatic re-pair.
//

#if os(iOS)
import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class KyIdentitySignOnCoordinator {
    enum Phase: Equatable {
        case idle
        case readingConfig
        case waitingForKyAuth
        case exchanging
    }

    private(set) var phase: Phase = .idle
    /// Last outcome for the sign-on screen; survives the screen being torn
    /// down by the app lock.
    private(set) var status: String?
    /// A finished sign-on waiting for a pairing screen that is on screen.
    /// The pairing link only, never the ID token. Single use.
    private(set) var completed: PairingParams?

    private struct Pending {
        let nonce: String
        let serverUrl: String
        let deadline: Date
    }

    private var pending: Pending?
    private var timeoutTask: Task<Void, Never>?
    private var liveScreens = 0
    /// Bumped by `reset()`. Work that resumes after an `await` checks it, so a
    /// sign-on in flight across a wipe or unpair cannot deliver afterwards.
    private var epoch = 0
    @ObservationIgnored private var resetObservation: NotificationObservation?

    // Seams, so the exit table is testable without KyAuth or a relay.
    var makeStore: @MainActor () -> SignOnHandoffStore? = { SignOnHandoffStore() }
    var makeClient: @MainActor () -> KyIdentitySignOnClient = {
        KyIdentitySignOnClient(
            transport: KyIdentitySignOnClient.sessionTransport(SingletonGraph.shared.relaySession)
        )
    }
    var openURL: @MainActor (URL) async -> Bool = { await UIApplication.shared.open($0) }
    var now: @MainActor () -> Date = { Date() }
    /// Used when no pairing screen is on screen (the lock closed it): the
    /// router defers this while locked and replays it on unlock.
    var deliver: @MainActor (PairingParams) -> Void = { _ in }
    /// True while KyAuth's response must stay unread. See `appIsGated`.
    var isGated: @MainActor () -> Bool = { KyIdentitySignOnCoordinator.appIsGated() }

    var isWorking: Bool { phase != .idle }

    /// The app's security gates, as they apply to a sign-on: locked, the
    /// startup wipe check still pending, or an abandoned wipe blocking the
    /// app. Read by KyPostApp too, so it can re-check when this clears.
    static func appIsGated() -> Bool {
        let graph = SingletonGraph.shared
        return graph.appLockManager.isLocked
            || AppEnvironment.shared.startupWipeVerdict == .pending
            || graph.securityWipe.blockedByAbandonedWipe
    }

    init(notificationCenter: NotificationCenter = .default) {
        resetObservation = NotificationObservation(
            center: notificationCenter,
            name: .kyPostSessionReset
        ) { [weak self] in
            self?.reset()
        }
    }

    // MARK: Pairing screen presence

    func pairingScreenAppeared() { liveScreens += 1 }

    /// When the last pairing screen goes, a finished sign-on it never took
    /// goes to the router instead, which defers it while locked.
    func pairingScreenDisappeared() {
        liveScreens = max(0, liveScreens - 1)
        if liveScreens == 0, let params = takeCompleted() {
            deliver(params)
        }
    }

    func takeCompleted() -> PairingParams? {
        defer { completed = nil }
        return completed
    }

    // MARK: Flow

    func start(serverUrl: String) {
        guard phase == .idle else { return }
        status = nil
        guard let origin = RelayOrigin.origin(serverUrl) else {
            status = "Server URL must use https"
            return
        }
        phase = .readingConfig
        Task { await begin(serverUrl: serverUrl, origin: origin) }
    }

    /// The user gave up waiting. Any late response is swept later.
    func cancel() {
        guard phase == .waitingForKyAuth else { return }
        abandon(message: nil)
    }

    func clearStatus() { status = nil }

    /// Forgets the sign-on entirely: withdraws the request, discards any
    /// response unread, and drops a finished pairing link. Runs on
    /// `.kyPostSessionReset`, so nothing here outlives an erase or unpair.
    func reset() {
        epoch += 1
        if let nonce = pending?.nonce, let store = makeStore() {
            store.withdrawRequest(nonce)
            _ = store.takeResponse(nonce)
        }
        clearPending()
        completed = nil
        finish(nil)
    }

    private func begin(serverUrl: String, origin: String) async {
        let started = epoch
        let config: SignOnConfig
        let answer = await makeClient().config(serverUrl: serverUrl)
        guard epoch == started else { return }
        switch answer {
        case .unavailable(let reason):
            return finish(reason)
        case .ready(let ready):
            config = ready
        }
        guard let store = makeStore() else {
            return finish("KyIdentity sign-in is not available in this build of KyPost.")
        }
        store.sweepStaleResponses(now: now())
        guard let nonce = SignOnHandoff.makeNonce(), let kyAuth = SignOnHandoff.kyAuthURL(nonce: nonce) else {
            return finish("Could not start KyIdentity sign-in.")
        }
        let request = SignOnRequestFile(
            v: 1,
            nonce: nonce,
            consumer: SignOnHandoff.consumer,
            clientId: config.clientId,
            origin: origin,
            issuer: config.issuerUrl,
            createdAtMs: Int64((now().timeIntervalSince1970 * 1000).rounded())
        )
        do {
            try store.writeRequest(request)
        } catch {
            return finish("Could not start KyIdentity sign-in.")
        }
        pending = Pending(
            nonce: nonce,
            serverUrl: serverUrl,
            deadline: now().addingTimeInterval(SignOnHandoff.pendingTimeout)
        )
        phase = .waitingForKyAuth
        scheduleTimeout(nonce: nonce)
        let opened = await openURL(kyAuth)
        guard epoch == started else { return }
        guard opened else {
            store.withdrawRequest(nonce)
            clearPending()
            return finish("Install KyAuth to sign in with KyIdentity.")
        }
    }

    /// `kypost://kyidentity-signon?nonce=…`. True when the URL was a sign-on
    /// return, whether or not it was the nonce KyPost is waiting for, so it
    /// never falls through to the pairing router.
    @discardableResult
    func handleReturn(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Config.deepLinkScheme,
              url.host()?.lowercased() == SignOnHandoff.returnHost
        else { return false }
        if let nonce = SignOnHandoff.returnNonce(from: url), nonce == pending?.nonce {
            checkForResponse()
        }
        return true
    }

    /// Also called whenever the app becomes active, and when the security gate
    /// clears, so a user who switched back by hand or had to unlock first is
    /// not stuck waiting.
    ///
    /// While gated the response is left unread in the App Group: the ID token
    /// stays out of this process, and no relay call is made, until the user
    /// unlocks. The deadline still applies, so a late unlock gets "no answer".
    func checkForResponse() {
        guard let current = pending, let store = makeStore() else { return }
        guard now() < current.deadline else {
            return abandon(message: Self.noAnswer)
        }
        guard !isGated() else { return }
        guard let taken = store.takeResponse(current.nonce) else { return }
        // Single use: cleared before any await so a second trigger (URL and
        // didBecomeActive arrive together) finds nothing.
        clearPending()
        switch taken {
        case nil:
            finish("Could not get a sign-in token from KyAuth.")
        case .cancelled?:
            finish(nil)
        case .error(let message)?:
            finish(message.isEmpty ? "KyAuth refused the sign-in." : message)
        case .ok(let idToken)?:
            guard !idToken.isEmpty else { return finish("KyAuth returned no token.") }
            phase = .exchanging
            let started = epoch
            Task { await exchange(serverUrl: current.serverUrl, idToken: idToken, epoch: started) }
        }
    }

    private func exchange(serverUrl: String, idToken: String, epoch started: Int) async {
        // Reset between scheduling and running: never send the token.
        guard epoch == started else { return }
        let result = await makeClient().signOn(serverUrl: serverUrl, idToken: idToken)
        guard epoch == started else { return }
        switch result {
        case .failure(let message):
            finish(message)
        case .success(let params):
            finish(nil)
            if liveScreens > 0 {
                completed = params
            } else {
                deliver(params)
            }
        }
    }

    // MARK: State

    private static let noAnswer = "KyAuth did not answer. Try again."

    private func scheduleTimeout(nonce: String) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SignOnHandoff.pendingTimeout))
            guard !Task.isCancelled, let self, self.pending?.nonce == nonce else { return }
            self.abandon(message: Self.noAnswer)
        }
    }

    private func abandon(message: String?) {
        if let nonce = pending?.nonce, let store = makeStore() {
            _ = store.takeResponse(nonce)
        }
        clearPending()
        finish(message)
    }

    private func clearPending() {
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func finish(_ message: String?) {
        phase = .idle
        status = message
    }
}
#endif
