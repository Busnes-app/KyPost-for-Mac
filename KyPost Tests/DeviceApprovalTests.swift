//
//  DeviceApprovalTests.swift
//  KyPost Tests
//
//  New-device approval (KyPost-Server #516, `docs/device-approval.md`): a
//  web-minted pairing token registers pending (202), the app polls
//  `native/pairing-status` until 200 or 410, and a `direct` token still pairs
//  at once. Driven through the stub transport; no server.
//

import Foundation
import Testing
@testable import KyPost

private let pendingJSON = #"""
{"ok": false, "synced": false, "status": "pending",
 "error": "approve this device on the web page that showed the pairing code",
 "deviceId": "dev-pending", "deviceSecret": "s-pending", "approvalCode": "048213",
 "expiresAt": "2099-01-01T00:00:00Z",
 "statusEndpoint": "https://relay.example.com/api/notifications/native/pairing-status",
 "pollIntervalSeconds": 3}
"""#
private let stillPendingJSON = #"{"status": "pending", "approvalCode": "048213", "pollIntervalSeconds": 3}"#
private let approvedJSON = #"""
{"ok": true, "synced": true, "status": "approved", "deviceId": "dev-merged",
 "deliveryMode": "pull", "pullEndpoint": null, "transport": "pull"}
"""#
private let rejectedJSON = #"{"status": "rejected", "error": "this pairing was denied or has expired; scan a new pairing code"}"#

/// One HTTP answer: status, body, and an optional `Retry-After`.
private struct Answer: Sendable {
    var status: Int
    var json: String
    var retryAfter: String?

    init(_ status: Int, _ json: String = "{}", retryAfter: String? = nil) {
        self.status = status
        self.json = json
        self.retryAfter = retryAfter
    }
}

/// Holds a request until `open()`, cancelled or not: the answer that lands
/// after the screen closed.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let opened = lock.withLock {
                if !isOpen { waiters.append(continuation) }
                return isOpen
            }
            if opened { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

/// Answers `native/register` with `register`, once `registerGate` (if any)
/// opens, and each `pairing-status` poll with the next of `statuses`, the
/// last one repeating. Every request lands in `log`.
private func approvalClient(
    register: Answer,
    statuses: [Answer] = [],
    registerGate: Gate? = nil,
    log: Box<[URLRequest]>
) -> HTTPClient {
    let polls = Box(0)
    return HTTPClient { request in
        log.mutate { $0.append(request) }
        let answer: Answer
        if request.url?.path().hasSuffix("/native/register") == true {
            await registerGate?.wait()
            answer = register
        } else {
            var index = 0
            polls.mutate { index = $0; $0 += 1 }
            answer = statuses.isEmpty ? Answer(500) : statuses[min(index, statuses.count - 1)]
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: answer.status,
            httpVersion: nil,
            headerFields: answer.retryAfter.map { ["Retry-After": $0] }
        )!
        return (Data(answer.json.utf8), response)
    }
}

private extension Box where T == [URLRequest] {
    var statusPolls: [URLRequest] {
        value.filter { $0.url?.path().hasSuffix("/native/pairing-status") == true }
    }
}

@MainActor
private struct ApprovalEnvironment {
    var service: DeviceRegistrationService
    var viewModel: PushPairingViewModel
    var pairingStore: SecurePairingStore
    var settings: PushSettingsStore
    var connections: StubPairingConnections
    var log: Box<[URLRequest]>
    /// Every wait the poll loop asked for, in order.
    var sleeps: Box<[Duration]>
}

/// `sleep` defaults to returning at once and recording the duration.
@MainActor
private func makeEnvironment(
    register: Answer,
    statuses: [Answer] = [],
    registerGate: Gate? = nil,
    sleep: (@Sendable (Duration) async throws -> Void)? = nil
) -> ApprovalEnvironment {
    let log = Box<[URLRequest]>([])
    let sleeps = Box<[Duration]>([])
    let client = approvalClient(register: register, statuses: statuses, registerGate: registerGate, log: log)
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let pairingStore = SecurePairingStore(
        keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
    )
    let settings = PushSettingsStore(defaults: defaults)
    let connections = StubPairingConnections(client: client)
    let service = makeRegistrationService(
        client: client, pairingStore: pairingStore, settings: settings, connections: connections
    )
    service.sleep = sleep ?? { duration in sleeps.mutate { $0.append(duration) } }
    let viewModel = PushPairingViewModel(
        registrationService: service,
        pushSettingsStore: settings,
        securePairingStore: pairingStore
    )
    return ApprovalEnvironment(
        service: service, viewModel: viewModel, pairingStore: pairingStore,
        settings: settings, connections: connections, log: log, sleeps: sleeps
    )
}

private let params = PairingParams(sub: "u1", srv: server, pt: "pt-1")

@MainActor
@Suite struct DeviceApprovalTests {
    /// 202 then 200: the pairing completes exactly as a 200 from register
    /// would, with the pending secret and the deviceId the status answer names.
    @Test func aPendingRegistrationThatIsApprovedCompletesPairing() async throws {
        let env = makeEnvironment(
            register: Answer(202, pendingJSON),
            statuses: [Answer(202, stillPendingJSON), Answer(200, approvedJSON)]
        )

        await env.viewModel.pair(params: params)

        #expect(env.viewModel.state == .paired(deviceId: "dev-merged"))
        let pairing = try #require(try env.pairingStore.loadPairing())
        #expect(pairing.lastDeviceId == "dev-merged")
        #expect(pairing.deviceSecret == "s-pending")
        #expect(env.settings.deliveryMode == .pull)
        #expect(env.settings.pullEndpoint == "\(server)/api/notifications/native/pull")
        // The pin the registration rode is the one stored.
        #expect(try env.pairingStore.pinnedSpkiHash(forHost: "relay.example.com") == "hash-observed")

        let polls = env.log.statusPolls
        #expect(polls.count == 2)
        #expect(polls.allSatisfy { $0.httpMethod == "GET" })
        #expect(polls.first?.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "dev-pending")
        #expect(polls.first?.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "s-pending")
        #expect(env.sleeps.value == [.seconds(3)])
        // Polls rode the pairing's own connection, closed once it ended.
        let connection = try #require(env.connections.last)
        #expect(env.connections.opened.count == 1)
        #expect(connection.polls == 2)
        #expect(connection.isClosed)
        #expect(env.service.pendingApproval == nil)
    }

    /// While pending, nothing is stored and nothing is announced: the
    /// device has no mail access until it is approved.
    @Test func aPendingRegistrationStoresNothing() async throws {
        let env = makeEnvironment(register: Answer(202, pendingJSON))

        let outcome = await env.service.pair(params: params, deviceToken: "apns")

        #expect(outcome == .awaitingApproval(
            PendingApproval(approvalCode: "048213", server: "relay.example.com")
        ))
        #expect(try env.pairingStore.loadPairing() == nil)
        #expect(env.settings.lastRegisteredAt == nil)
        #expect(env.service.pendingApproval?.groupedCode == "048 213")
        #expect(env.connections.last?.isClosed == false)
    }

    /// 410 (denied, expired or unknown): back to the start with the message,
    /// the pending credentials dropped and nothing stored.
    @Test func aRejectionReturnsToTheStart() async throws {
        let env = makeEnvironment(
            register: Answer(202, pendingJSON),
            statuses: [Answer(202, stillPendingJSON), Answer(410, rejectedJSON)]
        )

        await env.viewModel.pair(params: params)

        #expect(env.viewModel.state == .idle)
        #expect(env.viewModel.notice == "Not approved: denied or timed out. Scan a new code.")
        #expect(env.service.pendingApproval == nil)
        #expect(try env.pairingStore.loadPairing() == nil)
        #expect(env.connections.last?.isClosed == true)
        // A new scan clears the notice.
        env.viewModel.present(params: params)
        #expect(env.viewModel.notice == nil)
    }

    /// Cancel on the waiting screen stops the polls at once and drops the
    /// pending credentials; the wait that was running changes nothing after.
    @Test func cancelStopsPollingAndDropsTheCredentials() async throws {
        let env = makeEnvironment(
            register: Answer(202, pendingJSON),
            statuses: [Answer(202, stillPendingJSON)],
            sleep: { try await Task.sleep(for: .seconds($0.components.seconds * 1000)) }
        )

        let pairing = Task { await env.viewModel.pair(params: params) }
        for _ in 0..<500 where env.connections.last?.polls ?? 0 < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .awaitingApproval(let approval) = env.viewModel.state else {
            Issue.record("Expected the waiting screen, got \(env.viewModel.state)")
            pairing.cancel()
            return
        }
        #expect(approval.approvalCode == "048213")
        #expect(approval.server == "relay.example.com")

        env.viewModel.cancelPairing()
        await pairing.value

        #expect(env.viewModel.state == .idle)
        #expect(env.viewModel.notice == nil)
        #expect(env.service.pendingApproval == nil)
        #expect(env.connections.last?.isClosed == true)
        #expect(try env.pairingStore.loadPairing() == nil)
        let polls = env.log.statusPolls.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(env.log.statusPolls.count == polls)
        #expect(polls == 1)
    }

    /// Closing the screen while the registration is still in flight ends
    /// it: a 202 that lands afterwards keeps no pending credentials and
    /// starts no polls, and the web approving it later changes nothing. The
    /// account already paired here is neither replaced nor torn down.
    @Test func closingWhileRegisteringDropsALatePendingAnswer() async throws {
        let gate = Gate()
        let env = makeEnvironment(
            register: Answer(202, pendingJSON),
            statuses: [Answer(200, approvedJSON)],
            registerGate: gate
        )
        let teardowns = try await closeWhileRegistering(env, gate: gate)

        #expect(env.log.statusPolls.isEmpty)
        #expect(env.connections.last?.polls == 0)
        #expect(env.service.pendingApproval == nil)
        #expect(await env.service.awaitApproval() == .notApproved)
        #expect(env.log.statusPolls.isEmpty)
        #expect(teardowns.value == 0)
        #expect(try env.pairingStore.loadPairing()?.sub == "u-old")
    }

    /// The same for a `direct` token: a 200 that lands after the screen
    /// closed is not stored.
    @Test func closingWhileRegisteringDropsALateDirectPairing() async throws {
        let gate = Gate()
        let json = #"{"ok": true, "synced": true, "status": "approved", "deviceId": "dev-7", "deviceSecret": "s-7", "deliveryMode": "push"}"#
        let env = makeEnvironment(register: Answer(200, json), registerGate: gate)
        let teardowns = try await closeWhileRegistering(env, gate: gate)

        #expect(teardowns.value == 0)
        #expect(try env.pairingStore.loadPairing()?.sub == "u-old")
        #expect(env.settings.lastRegisteredAt == nil)
    }

    /// Pairs another account's link over a stored pairing, closes the screen
    /// while `native/register` is held, then lets the answer through.
    /// Returns how often the previous account was torn down.
    private func closeWhileRegistering(_ env: ApprovalEnvironment, gate: Gate) async throws -> Box<Int> {
        try env.pairingStore.savePairing(Pairing(
            sub: "u-old", deviceSecret: "s-old", srv: server, registrationUrl: nil,
            pairingToken: "pt-old", lastDeviceId: "dev-old", pairedAt: Date()
        ))
        let teardowns = Box(0)
        env.service.onAccountReplaced = {
            teardowns.mutate { $0 += 1 }
            return true
        }

        let pairing = Task { await env.viewModel.pair(params: params) }
        for _ in 0..<500 where env.connections.last?.registrations ?? 0 < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(env.viewModel.state == .working)
        env.viewModel.cancelPairing()
        #expect(env.viewModel.state == .idle)

        gate.open()
        await pairing.value
        try await Task.sleep(for: .milliseconds(50))

        #expect(env.viewModel.state == .idle)
        #expect(env.connections.last?.isClosed == true)
        return teardowns
    }

    /// A sign-on or review-pairing token (signed `direct` claim) is paired at
    /// once with 200, exactly as before: no polling, no waiting screen.
    @Test func aDirectRegistrationIsUnchanged() async throws {
        let json = #"{"ok": true, "synced": true, "status": "approved", "deviceId": "dev-7", "deviceSecret": "s-7", "deliveryMode": "push"}"#
        let env = makeEnvironment(register: Answer(200, json))

        await env.viewModel.pair(params: params)

        #expect(env.viewModel.state == .paired(deviceId: "dev-7"))
        let pairing = try #require(try env.pairingStore.loadPairing())
        #expect(pairing.deviceSecret == "s-7")
        #expect(pairing.lastDeviceId == "dev-7")
        #expect(env.settings.deliveryMode == .push)
        #expect(env.log.statusPolls.isEmpty)
        #expect(env.sleeps.value.isEmpty)
        #expect(env.service.pendingApproval == nil)
        #expect(env.connections.last?.isClosed == true)
        // The new optional field goes up with the request.
        let body = try #require(env.log.value.first?.httpBody)
        let fields = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((fields["osVersion"] as? String)?.isEmpty == false)
    }

    /// Transient failures back off from the server's interval, doubling, and
    /// never sooner than `Retry-After`; a pending answer resets the pace.
    @Test func transientFailuresBackOff() async throws {
        let env = makeEnvironment(
            register: Answer(202, pendingJSON),
            statuses: [
                Answer(503), Answer(502), Answer(429, retryAfter: "20"),
                Answer(202, stillPendingJSON), Answer(200, approvedJSON),
            ]
        )

        let outcome = await env.service.pair(params: params, deviceToken: "apns")
        #expect(outcome != .notApproved)
        let approved = await env.service.awaitApproval()

        guard case .success = approved else {
            Issue.record("Expected success, got \(approved)")
            return
        }
        #expect(env.sleeps.value == [.seconds(3), .seconds(6), .seconds(20), .seconds(3)])
    }

    /// Polling stops at the pending device's expiry: one last poll, then the
    /// credentials go.
    @Test func pollingStopsAtExpiry() async throws {
        let env = makeEnvironment(
            register: Answer(202, pendingJSON),
            statuses: [Answer(202, stillPendingJSON)]
        )
        let clock = Box(Date())
        env.service.now = { clock.value }
        env.service.sleep = { duration in
            clock.mutate { $0 += TimeInterval(duration.components.seconds) * 40 }
        }

        _ = await env.service.pair(params: params, deviceToken: "apns")
        let outcome = await env.service.awaitApproval()

        #expect(outcome == .notApproved)
        #expect(env.service.pendingApproval == nil)
        #expect(env.connections.last?.isClosed == true)
        // 5 minutes at 120 s a step: polls at 0, 120 and 240 s, then a last one.
        #expect(env.log.statusPolls.count == 4)
    }

    /// The pending secret goes to the paired server only.
    @Test func aStatusEndpointOnAnotherOriginIsIgnored() {
        let derived = URL(string: "\(server)/api/notifications/native/pairing-status")
        #expect(PendingRegistration.statusEndpoint("https://evil.example/status", srv: server) == derived)
        #expect(PendingRegistration.statusEndpoint("http://relay.example.com/status", srv: server) == derived)
        #expect(PendingRegistration.statusEndpoint("https://relay.example.com:8443/s", srv: server) == derived)
        #expect(PendingRegistration.statusEndpoint(nil, srv: server) == derived)
        #expect(PendingRegistration.statusEndpoint("https://relay.example.com/custom", srv: server)
            == URL(string: "https://relay.example.com/custom"))
    }

    /// A 202 without what polling needs is a failure, not a pairing.
    @Test func aPendingAnswerWithoutACodeSavesNothing() async throws {
        let json = #"{"ok": false, "status": "pending", "deviceId": "d", "deviceSecret": "s"}"#
        let env = makeEnvironment(register: Answer(202, json))

        await env.viewModel.pair(params: params)

        guard case .failed = env.viewModel.state else {
            Issue.record("Expected .failed, got \(env.viewModel.state)")
            return
        }
        #expect(try env.pairingStore.loadPairing() == nil)
        #expect(env.service.pendingApproval == nil)
    }

    /// A background re-registration never waits on approval and never stores
    /// a pending secret over the working pairing.
    @Test func aReregistrationAnsweredPendingKeepsTheStoredPairing() async throws {
        let env = makeEnvironment(register: Answer(202, pendingJSON))
        try env.pairingStore.savePairing(Pairing(
            sub: "u1", deviceSecret: "s1", srv: server, registrationUrl: nil,
            pairingToken: "pt", lastDeviceId: "dev-1", pairedAt: Date()
        ))

        let outcome = await env.service.reregisterIfPaired(deviceToken: "apns")

        guard case .failure = outcome else {
            Issue.record("Expected .failure, got \(String(describing: outcome))")
            return
        }
        #expect(try env.pairingStore.loadPairing()?.deviceSecret == "s1")
        #expect(env.service.pendingApproval == nil)
    }

    /// The contract's 409s get its wording, not the generic refusal.
    @Test func theApprovalConflictsAreNamed() {
        #expect(NativeRegistrationClient.conflictMessage(#"{"error":"pairing token already used"}"#)
            == "This code was already used. If you did not use it, deny the request on the web page.")
        #expect(NativeRegistrationClient.conflictMessage(
            #"{"error":"a pairing request for this device is already waiting for approval"}"#
        ).contains("already waiting"))
        #expect(NativeRegistrationClient.conflictMessage(
            #"{"error":"too many devices are waiting for approval; approve or deny them"}"#
        ).contains("Too many devices"))
        #expect(NativeRegistrationClient.conflictMessage("device id taken")
            == "The server rejected this pairing request.")
    }
}
