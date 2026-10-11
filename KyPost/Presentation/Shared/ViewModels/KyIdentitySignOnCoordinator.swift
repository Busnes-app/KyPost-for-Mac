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

    var isWorking: Bool { phase != .idle }

    // MARK: Pairing screen presence

    func pairingScreenAppeared() { liveScreens += 1 }
    func pairingScreenDisappeared() { liveScreens = max(0, liveScreens - 1) }

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

    private func begin(serverUrl: String, origin: String) async {
        let config: SignOnConfig
        switch await makeClient().config(serverUrl: serverUrl) {
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
        guard await openURL(kyAuth) else {
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

    /// Also called whenever the app becomes active, so a user who switched
    /// back by hand is not stuck waiting.
    func checkForResponse() {
        guard let current = pending, let store = makeStore() else { return }
        guard now() < current.deadline else {
            return abandon(message: Self.noAnswer)
        }
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
            Task { await exchange(serverUrl: current.serverUrl, idToken: idToken) }
        }
    }

    private func exchange(serverUrl: String, idToken: String) async {
        switch await makeClient().signOn(serverUrl: serverUrl, idToken: idToken) {
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
