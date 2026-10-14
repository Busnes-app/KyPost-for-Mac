//
//  PullHeartbeatTests.swift
//  KyPost Tests
//
//  The push-mode heartbeat (Android #129 / server issue #137 option 1), the
//  server's pull wire shape, and notification history.
//

import Foundation
import SwiftData
import Testing
@testable import KyPost

private struct PullEnvironment {
    var repository: PushRepository
    var cursorStore: NotificationCursorStore
    var settings: PushSettingsStore
    var dao: PushNotificationDAO
    var db: AppDatabase
    var pairingStore: SecurePairingStore
}

@MainActor
private func makePullEnvironment(client: HTTPClient, paired: Bool = true) throws -> PullEnvironment {
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let pairingStore = try makePairedStore(paired: paired)
    let db = try AppDatabase(inMemory: true)
    let dao = PushNotificationDAO(modelContainer: db.container)
    let cursorStore = NotificationCursorStore(defaults: defaults)
    let settings = PushSettingsStore(defaults: defaults)
    settings.systemNotificationsEnabled = false
    let repository = PushRepository(
        dao: dao,
        cursorStore: cursorStore,
        client: PushNotificationClient(httpClient: client),
        securePairingStore: pairingStore,
        pushSettingsStore: settings
    )
    return PullEnvironment(
        repository: repository, cursorStore: cursorStore, settings: settings, dao: dao, db: db,
        pairingStore: pairingStore
    )
}

/// A transport that holds every response until `release()`, so a test can act
/// while a pull is waiting on the relay.
private final class HeldTransport: @unchecked Sendable {
    let requests = Box(0)
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let json: String

    init(json: String) {
        self.json = json
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    var client: HTTPClient {
        HTTPClient { [self] request in
            requests.mutate { $0 += 1 }
            for await _ in stream { break }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
    }

    func release() { continuation.yield(()) }

    func waitForRequest() async {
        while requests.value == 0 { await Task.yield() }
    }
}

@MainActor
private final class PresentationLog {
    var items: [String] = []
    var presenter: PulledPresenter {
        { [weak self] item in
            switch item {
            case .mail(let mail): self?.items.append("mail:\(mail.messageId)")
            case .mfa(let pulled): self?.items.append("mfa:\(pulled.challenge.challengeId)")
            }
        }
    }
}

@MainActor
private func makeScheduler(
    _ env: PullEnvironment,
    deliveredPushes: [DeliveredPush] = [],
    log: PresentationLog? = nil,
    presenter: PulledPresenter? = nil,
    clock: @escaping () -> Date = Date.init
) throws -> PullPollingScheduler {
    let dispatcher = PushNotificationDispatcher(
        pushRepository: env.repository,
        approveMfaChallenge: ApproveMfaChallengeUseCase(
            client: MfaResponseClient(httpClient: stubClient()),
            securePairingStore: try makePairedStore()
        ),
        pushSettingsStore: env.settings
    )
    return PullPollingScheduler(
        pushRepository: env.repository,
        pushSettingsStore: env.settings,
        dispatcher: dispatcher,
        deliveredPushes: { deliveredPushes },
        presenter: presenter ?? log?.presenter,
        clock: clock
    )
}

/// Every row in the store, visible or not.
@MainActor
private func allRows(_ env: PullEnvironment) throws -> [PushNotificationEntity] {
    try ModelContext(env.db.container).fetch(FetchDescriptor<PushNotificationEntity>())
}

private let hour: TimeInterval = 60 * 60

private func rfc3339(_ date: Date) -> String {
    date.formatted(.iso8601)
}

// MARK: - Policy

@Suite struct PullHeartbeatPolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func pullModeAlwaysPolls() {
        let decision = PullHeartbeatPolicy.decide(
            mode: .pull, lastPushReceivedAt: now, lastRegisteredAt: now, lastPulledAt: now, now: now
        )
        #expect(decision == .poll(heartbeat: false))
    }

    @Test func pushModeStaysOffTheNetworkWhilePushIsHealthy() {
        let decision = PullHeartbeatPolicy.decide(
            mode: .push, lastPushReceivedAt: now.addingTimeInterval(-2.9 * hour),
            lastRegisteredAt: nil, lastPulledAt: nil, now: now
        )
        #expect(decision == .skip)
    }

    @Test func pushModePollsOnceQuietForThreeHours() {
        let decision = PullHeartbeatPolicy.decide(
            mode: .push, lastPushReceivedAt: now.addingTimeInterval(-3 * hour),
            lastRegisteredAt: now, lastPulledAt: nil, now: now
        )
        #expect(decision == .poll(heartbeat: true))
    }

    /// No push ever: the registration is the last moment the relay was proven
    /// reachable, and a fresh token gets the threshold to deliver.
    @Test func withNoPushTheClockStartsAtRegistration() {
        let fresh = PullHeartbeatPolicy.decide(
            mode: .push, lastPushReceivedAt: nil,
            lastRegisteredAt: now.addingTimeInterval(-1 * hour), lastPulledAt: nil, now: now
        )
        let stale = PullHeartbeatPolicy.decide(
            mode: .push, lastPushReceivedAt: nil,
            lastRegisteredAt: now.addingTimeInterval(-4 * hour), lastPulledAt: nil, now: now
        )
        #expect(fresh == .skip)
        #expect(stale == .poll(heartbeat: true))
    }

    /// Anything that is not an explicit pull is push, including no mode yet.
    @Test func noModeIsTreatedAsPush() {
        let decision = PullHeartbeatPolicy.decide(
            mode: nil, lastPushReceivedAt: now, lastRegisteredAt: nil, lastPulledAt: nil, now: now
        )
        #expect(decision == .skip)
        #expect(PullHeartbeatPolicy.decide(
            mode: nil, lastPushReceivedAt: nil, lastRegisteredAt: nil, lastPulledAt: nil, now: now
        ) == .poll(heartbeat: true))
    }

    /// A successful heartbeat does not reset the quiet clock (only a push
    /// does), so the spacing is what stops a 90-second foreground cadence
    /// turning into a 90-second poll.
    @Test func heartbeatsAreSpacedOut() {
        let quiet = now.addingTimeInterval(-5 * hour)
        #expect(PullHeartbeatPolicy.decide(
            mode: .push, lastPushReceivedAt: quiet, lastRegisteredAt: nil,
            lastPulledAt: now.addingTimeInterval(-60), now: now
        ) == .skip)
        #expect(PullHeartbeatPolicy.decide(
            mode: .push, lastPushReceivedAt: quiet, lastRegisteredAt: nil,
            lastPulledAt: now.addingTimeInterval(-16 * 60), now: now
        ) == .poll(heartbeat: true))
    }

    @Test func pushReceivedOnlyMovesForward() {
        let settings = PushSettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        settings.markPushReceived(at: now)
        settings.markPushReceived(at: now.addingTimeInterval(-hour))
        #expect(settings.lastPushReceivedAt == now)
    }
}

// MARK: - Server wire shape

@MainActor
@Suite struct PullWireShapeTests {
    /// The server's `state.PullNotification`: mail fields live in `data`.
    @Test func decodesTheServersPullShape() async throws {
        let json = """
        {
          "deliveryMode": "push",
          "cursor": 7,
          "notifications": [
            { "seq": 7, "title": "Ada", "body": "Lunch?", "createdAt": "\(rfc3339(Date()))",
              "data": { "messageId": "m-7", "senderName": "Ada Lovelace", "emailSubject": "Lunch?",
                        "Keywords": "Personal, Friends", "url": "/read" } }
          ]
        }
        """
        let env = try makePullEnvironment(client: stubClient(json: json))
        env.settings.deliveryMode = .pull
        let batch = try await env.repository.pullOnce()

        let mail = try #require(batch.mail.first)
        #expect(mail.messageId == "m-7")
        #expect(mail.senderName == "Ada Lovelace")
        #expect(mail.emailSubject == "Lunch?")
        #expect(mail.keywords == ["Personal", "Friends"])
        #expect(env.cursorStore.lastCursor == 7)
        // The response mode is authoritative.
        #expect(env.settings.deliveryMode == .push)
    }

    /// A no-content account sends only the message id in `data`; the entry's
    /// title and body are what there is.
    @Test func fallsBackToTitleAndBodyAndSynthesizesAMissingId() async throws {
        let json = """
        { "cursor": 2, "notifications": [
            { "seq": 2, "title": "KyPost", "body": "You have a new email.", "createdAt": "\(rfc3339(Date()))" }
        ] }
        """
        let env = try makePullEnvironment(client: stubClient(json: json))
        let mail = try #require(try await env.repository.pullOnce().mail.first)
        #expect(mail.messageId == "pull-2")
        #expect(mail.senderName == "KyPost")
        #expect(mail.emailSubject == "You have a new email.")
    }

    /// MFA is decided first and never written to history (spec §5).
    @Test func routesAPulledChallengeAsMfaAndDoesNotStoreIt() async throws {
        let json = """
        { "cursor": 3, "notifications": [
            { "seq": 3, "title": "Sign-in", "body": "Approve?", "createdAt": "\(rfc3339(Date()))",
              "data": { "type": "mfa_challenge", "challengeId": "c-1", "matchDigits": "42",
                        "decoyDigits": "17,88", "ipAddress": "203.0.113.9" } }
        ] }
        """
        let env = try makePullEnvironment(client: stubClient(json: json))
        let batch = try await env.repository.pullOnce()
        #expect(batch.mail.isEmpty)
        let pulled = try #require(batch.mfaChallenges.first)
        #expect(pulled.challenge.challengeId == "c-1")
        #expect(pulled.challenge.matchDigits == "42")
        #expect(try await env.repository.history().isEmpty)
        // Only routing keys reach the system's notification store.
        let stored = PushNotificationDispatcher.mfaUserInfo(from: pulled.userInfo)
        #expect(stored["ipAddress"] == nil)
        #expect(stored["challengeId"] == "c-1")
    }

    /// The same bounds as the push path (Android `PushPayloadParser.sanitize`).
    @Test func pulledStringsAreBounded() async throws {
        let long = String(repeating: "x", count: 2000)
        let keywords = (0..<50).map { "k\($0)" }.joined(separator: ",")
        let json = """
        { "cursor": 1, "notifications": [
            { "seq": 1, "data": { "messageId": "m-1", "senderName": "\(long)", "emailSubject": "\(long)",
                                  "Keywords": "\(keywords)" } }
        ] }
        """
        let env = try makePullEnvironment(client: stubClient(json: json))
        let mail = try #require(try await env.repository.pullOnce().mail.first)
        #expect(mail.senderName.count == MailPushPayload.maxHeaderLength)
        #expect(mail.emailSubject.count == MailPushPayload.maxHeaderLength)
        #expect(mail.keywords.count == MailPushPayload.maxKeywords)

        let pushed = try #require(PushPayloadMapper.map(userInfo: [
            "messageId": "m-2", "senderName": long, "emailSubject": long,
        ]))
        guard case .mail(let payload) = pushed else { Issue.record("not mail"); return }
        #expect(payload.emailSubject.count == MailPushPayload.maxHeaderLength)
    }

    /// One malformed data value must not fail the batch and stall the cursor.
    @Test func aNonStringDataValueIsDroppedNotFatal() async throws {
        let json = """
        { "cursor": 4, "notifications": [
            { "seq": 4, "data": { "messageId": "m-4", "odd": 12 } }
        ] }
        """
        let env = try makePullEnvironment(client: stubClient(json: json))
        #expect(try await env.repository.pullOnce().mail.map(\.messageId) == ["m-4"])
        #expect(env.cursorStore.lastCursor == 4)
    }
}

// MARK: - Heartbeat pull

@MainActor
@Suite struct PullHeartbeatRepositoryTests {
    /// A heartbeat's cursor can be months stale: old entries are dropped,
    /// entries without a createdAt stay, and the cursor still moves past all.
    @Test func aHeartbeatDropsOldEntriesButAdvancesTheCursor() async throws {
        let now = Date()
        let json = """
        { "cursor": 12, "notifications": [
            { "seq": 10, "createdAt": "\(rfc3339(now.addingTimeInterval(-30 * 24 * hour)))", "data": { "messageId": "old" } },
            { "seq": 11, "data": { "messageId": "undated" } },
            { "seq": 12, "createdAt": "\(rfc3339(now.addingTimeInterval(-hour)))", "data": { "messageId": "new" } }
        ] }
        """
        let env = try makePullEnvironment(client: stubClient(json: json))
        env.cursorStore.advance(to: 9)
        let batch = try await env.repository.pullOnce(
            now: now, minCreatedAt: now.addingTimeInterval(-PullHeartbeatPolicy.heartbeatWindow)
        )
        #expect(batch.mail.map(\.messageId) == ["undated", "new"])
        #expect(env.cursorStore.lastCursor == 12)
    }

    /// A first pull (cursor 0) reaches back no further than a heartbeat: the
    /// queue holds the account's whole recent backlog.
    @Test func aFirstPullIsBoundedToo() async throws {
        let now = Date()
        let json = """
        { "cursor": 2, "notifications": [
            { "seq": 1, "createdAt": "\(rfc3339(now.addingTimeInterval(-48 * hour)))", "data": { "messageId": "old" } },
            { "seq": 2, "createdAt": "\(rfc3339(now))", "data": { "messageId": "new" } }
        ] }
        """
        let env = try makePullEnvironment(client: stubClient(json: json))
        #expect(try await env.repository.pullOnce(now: now).mail.map(\.messageId) == ["new"])
    }

    /// History is the dedupe against what push already delivered.
    @Test func aMessagePushAlreadyDeliveredIsNotAlertedAgain() async throws {
        let json = """
        { "cursor": 5, "notifications": [ { "seq": 5, "data": { "messageId": "m-1" } } ] }
        """
        let env = try makePullEnvironment(client: stubClient(json: json))
        env.cursorStore.advance(to: 4)
        try await env.repository.recordPushArrival(
            MailPushPayload(messageId: "m-1", senderName: "A", emailSubject: "s", keywords: [])
        )
        let batch = try await env.repository.pullOnce()
        #expect(batch.mail.isEmpty)
        #expect(env.cursorStore.lastCursor == 5)
        #expect(try await env.repository.history().count == 1)
    }

    @Test func historyIsCappedAtThirty() async throws {
        let env = try makePullEnvironment(client: stubClient())
        let base = Date()
        for index in 0..<35 {
            try await env.repository.recordPushArrival(
                MailPushPayload(messageId: "m-\(index)", senderName: "A", emailSubject: "s", keywords: []),
                receivedAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        let history = try await env.repository.history(limit: 100)
        #expect(history.count == PushNotificationDAO.historyLimit)
        #expect(history.first?.messageId == "m-34")
    }

    @Test func unpairClearsHistoryCursorAndClock() async throws {
        let env = try makePullEnvironment(client: stubClient())
        env.cursorStore.advance(to: 40)
        env.settings.markPushReceived(at: Date())
        env.settings.lastRegisteredAt = Date()
        env.settings.lastPulledAt = Date()
        try await env.repository.recordPushArrival(
            MailPushPayload(messageId: "m-1", senderName: "A", emailSubject: "s", keywords: [])
        )

        try await env.repository.clearForUnpair()

        #expect(env.cursorStore.lastCursor == 0)
        #expect(env.settings.lastPushReceivedAt == nil)
        #expect(env.settings.lastRegisteredAt == nil)
        #expect(env.settings.lastPulledAt == nil)
        #expect(try await env.repository.history().isEmpty)
    }
}

// MARK: - Scheduler

@MainActor
@Suite struct PullPollingSchedulerHeartbeatTests {
    @Test func healthyPushModeMakesNoRequest() async throws {
        let requests = Box(0)
        let env = try makePullEnvironment(client: stubClient(json: #"{"cursor":0,"notifications":[]}"#) { _ in
            requests.mutate { $0 += 1 }
        })
        env.settings.deliveryMode = .push
        env.settings.markPushReceived(at: Date().addingTimeInterval(-hour))

        let scheduler = try makeScheduler(env)
        await scheduler.pollNow()
        #expect(requests.value == 0)
    }

    @Test func quietPushModePolls() async throws {
        let requests = Box(0)
        let env = try makePullEnvironment(client: stubClient(json: #"{"cursor":0,"notifications":[]}"#) { _ in
            requests.mutate { $0 += 1 }
        })
        env.settings.deliveryMode = .push
        env.settings.markPushReceived(at: Date().addingTimeInterval(-4 * hour))

        let scheduler = try makeScheduler(env)
        await scheduler.pollNow()
        #expect(requests.value == 1)
        #expect(env.settings.lastPulledAt != nil)
    }

    /// iOS alert pushes do not wake the app; a banner still in Notification
    /// Center is evidence push works and keeps the heartbeat off the network.
    @Test func aDeliveredBannerCountsAsAPush() async throws {
        let requests = Box(0)
        let env = try makePullEnvironment(client: stubClient(json: #"{"cursor":0,"notifications":[]}"#) { _ in
            requests.mutate { $0 += 1 }
        })
        env.settings.deliveryMode = .push
        env.settings.markPushReceived(at: Date().addingTimeInterval(-10 * hour))

        let scheduler = try makeScheduler(env, deliveredPushes: [DeliveredPush(date: Date().addingTimeInterval(-60))])
        await scheduler.pollNow()
        #expect(requests.value == 0)
    }

    @Test func pullModePollsEveryTick() async throws {
        let requests = Box(0)
        let env = try makePullEnvironment(client: stubClient(json: #"{"cursor":0,"notifications":[]}"#) { _ in
            requests.mutate { $0 += 1 }
        })
        env.settings.deliveryMode = .pull
        env.settings.markPushReceived(at: Date())
        let scheduler = try makeScheduler(env)
        await scheduler.pollNow()
        await scheduler.pollNow()
        #expect(requests.value == 2)
    }
}

// MARK: - History screen

@MainActor
@Suite struct NotificationHistoryViewModelTests {
    @Test func loadsNewestFirstAndMarksRead() async throws {
        let env = try makePullEnvironment(client: stubClient())
        let base = Date()
        try await env.repository.recordPushArrival(
            MailPushPayload(messageId: "m-1", senderName: "A", emailSubject: "first", keywords: []),
            receivedAt: base
        )
        try await env.repository.recordPushArrival(
            MailPushPayload(messageId: "m-2", senderName: "B", emailSubject: "second", keywords: []),
            receivedAt: base.addingTimeInterval(1)
        )
        let viewModel = NotificationHistoryViewModel(repository: env.repository, pushSettingsStore: env.settings)
        await viewModel.load()
        #expect(viewModel.latest?.emailSubject == "second")
        #expect(viewModel.entries.count == 2)

        let entry = try #require(viewModel.latest)
        await viewModel.markRead(entry)
        #expect(viewModel.latest?.read == true)
        #expect(try await env.repository.history().first?.read == true)
    }

    @Test func synthesizedIdsAreNotOpenable() {
        func entry(_ id: String) -> PushNotification {
            PushNotification(seq: 1, messageId: id, senderName: "", emailSubject: "", keywords: [], receivedAt: Date(), read: false)
        }
        #expect(NotificationHistoryViewModel.openableMessageId(entry("pull-9")) == nil)
        #expect(NotificationHistoryViewModel.openableMessageId(entry("")) == nil)
        #expect(NotificationHistoryViewModel.openableMessageId(entry("abc")) == "abc")
    }
}

// MARK: - Review findings

@MainActor
@Suite struct PullHeartbeatReviewTests {
    private static func mailJSON(seq: Int, messageId: String, createdAt: Date) -> String {
        """
        { "seq": \(seq), "createdAt": "\(rfc3339(createdAt))",
          "data": { "messageId": "\(messageId)", "senderName": "Ada", "emailSubject": "Hi" } }
        """
    }

    /// Teardown stops the poll in flight, not only the cadence: a response
    /// released after `shutdown` writes and presents nothing.
    @Test func shutdownStopsAPollWaitingOnTheRelay() async throws {
        let held = HeldTransport(json: """
        { "cursor": 1, "notifications": [ \(Self.mailJSON(seq: 1, messageId: "m-1", createdAt: Date())) ] }
        """)
        let env = try makePullEnvironment(client: held.client)
        env.settings.deliveryMode = .pull
        let log = PresentationLog()
        let scheduler = try makeScheduler(env, log: log)

        let poll = Task { await scheduler.pollNow() }
        await held.waitForRequest()
        scheduler.shutdown()
        held.release()
        await poll.value

        #expect(try allRows(env).isEmpty)
        #expect(log.items.isEmpty)
        #expect(env.cursorStore.lastCursor == 0)
    }

    /// Unpairing while a pull waits on the relay: the old account's response
    /// must not repopulate history, the cursor, the heartbeat clock, or
    /// present anything.
    @Test func unpairDuringAPullLeavesNothingBehind() async throws {
        let held = HeldTransport(json: """
        { "cursor": 7, "deliveryMode": "pull", "notifications": [
            \(Self.mailJSON(seq: 7, messageId: "m-7", createdAt: Date())),
            { "seq": 8, "createdAt": "\(rfc3339(Date()))",
              "data": { "type": "mfa_challenge", "challengeId": "c-1", "matchDigits": "42", "decoyDigits": "17,88" } }
        ] }
        """)
        let env = try makePullEnvironment(client: held.client)
        env.settings.deliveryMode = .pull
        let log = PresentationLog()
        let scheduler = try makeScheduler(env, log: log)

        let poll = Task { await scheduler.pollNow() }
        await held.waitForRequest()
        try await env.repository.clearForUnpair()
        held.release()
        await poll.value

        #expect(try allRows(env).isEmpty)
        #expect(env.cursorStore.lastCursor == 0)
        #expect(env.settings.lastPulledAt == nil)
        #expect(env.settings.lastHeartbeatAttemptAt == nil)
        #expect(log.items.isEmpty)

        // The repository refuses on its own, without the scheduler.
        let direct = HeldTransport(json: """
        { "cursor": 9, "notifications": [ \(Self.mailJSON(seq: 9, messageId: "m-9", createdAt: Date())) ] }
        """)
        let env2 = try makePullEnvironment(client: direct.client)
        let pull = Task { try await env2.repository.pullOnce() }
        await direct.waitForRequest()
        try await env2.repository.clearForUnpair()
        direct.release()
        await #expect(throws: CancellationError.self) { try await pull.value }
        #expect(try allRows(env2).isEmpty)
        #expect(env2.cursorStore.lastCursor == 0)
    }

    /// A failed heartbeat is spaced like a successful one.
    @Test func failedHeartbeatsAreSpacedOut() async throws {
        let requests = Box(0)
        let env = try makePullEnvironment(client: stubClient(status: 500, json: "oops") { _ in
            requests.mutate { $0 += 1 }
        })
        env.settings.deliveryMode = .push
        let start = Date()
        env.settings.markPushReceived(at: start.addingTimeInterval(-4 * hour))
        let scheduler = try makeScheduler(env)

        await scheduler.pollNow(now: start)
        await scheduler.pollNow(now: start.addingTimeInterval(90))
        await scheduler.pollNow(now: start.addingTimeInterval(900))
        #expect(requests.value == 2)
    }

    /// Delivery ids outlive the 30 visible rows for the heartbeat window, so
    /// pushes pruned from view are still not alerted twice.
    @Test func prunedPushesAreNotReAlertedByTheHeartbeat() async throws {
        let now = Date()
        let base = now.addingTimeInterval(-3.5 * hour)
        let entries = (0..<31).map {
            Self.mailJSON(seq: $0 + 1, messageId: "m-\($0)", createdAt: base.addingTimeInterval(TimeInterval($0)))
        }
        let env = try makePullEnvironment(client: stubClient(json: """
        { "cursor": 31, "notifications": [ \(entries.joined(separator: ",")) ] }
        """))
        for index in 0..<31 {
            try await env.repository.recordPushArrival(
                MailPushPayload(messageId: "m-\(index)", senderName: "Ada", emailSubject: "Hi", keywords: []),
                receivedAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        #expect(try await env.repository.history().count == PushNotificationDAO.historyLimit)
        #expect(try await !env.repository.history().contains { $0.messageId == "m-0" })

        let batch = try await env.repository.pullOnce(
            now: now, minCreatedAt: now.addingTimeInterval(-PullHeartbeatPolicy.heartbeatWindow)
        )
        #expect(batch.mail.isEmpty)
        // The row kept for its id carries no content.
        let kept = try #require(try allRows(env).first { $0.messageId == "m-0" })
        #expect(kept.senderName.isEmpty && kept.emailSubject.isEmpty && kept.keywords.isEmpty)
    }

    /// A mail push iOS showed while the app was suspended never reached
    /// `handleIncoming`; the heartbeat still must not alert it again.
    @Test func aDeliveredBannerIsNotAlertedAgainByTheHeartbeat() async throws {
        let now = Date()
        let delivered = now.addingTimeInterval(-4 * hour)
        let requests = Box(0)
        let env = try makePullEnvironment(client: stubClient(json: """
        { "cursor": 1, "notifications": [ \(Self.mailJSON(seq: 1, messageId: "m-1", createdAt: delivered)) ] }
        """) { _ in requests.mutate { $0 += 1 } })
        env.settings.deliveryMode = .push
        let log = PresentationLog()
        let pushed = PushNotificationDispatcher.deliveredPush(
            userInfo: ["messageId": "m-1", "senderName": "Ada", "emailSubject": "Hi"],
            date: delivered
        )
        #expect(pushed.mail?.messageId == "m-1")
        let scheduler = try makeScheduler(env, deliveredPushes: [pushed], log: log)

        await scheduler.pollNow(now: now)
        #expect(requests.value == 1)
        #expect(log.items.isEmpty)
        #expect(try await env.repository.history().map(\.messageId) == ["m-1"])
    }

    /// A banner from before this pairing registered is not this pairing's mail.
    @Test func bannersFromBeforeThePairingAreNotRecorded() async throws {
        let env = try makePullEnvironment(client: stubClient())
        let now = Date()
        env.settings.lastRegisteredAt = now.addingTimeInterval(-hour)
        await env.repository.reconcileDeliveredPushes([
            (payload: MailPushPayload(messageId: "old", senderName: "A", emailSubject: "s", keywords: []),
             receivedAt: now.addingTimeInterval(-2 * hour)),
            (payload: MailPushPayload(messageId: "new", senderName: "A", emailSubject: "s", keywords: []),
             receivedAt: now.addingTimeInterval(-60)),
        ])
        #expect(try await env.repository.history().map(\.messageId) == ["new"])
    }

    /// The cap applies to a store written before it existed, with no new
    /// arrival to trigger it.
    @Test func legacyHistoryIsCappedWithoutANewArrival() async throws {
        let env = try makePullEnvironment(client: stubClient())
        let context = ModelContext(env.db.container)
        let old = Date().addingTimeInterval(-30 * 24 * hour)
        for index in 0..<100 {
            context.insert(PushNotificationEntity(from: PushNotification(
                seq: index, messageId: "m-\(index)", senderName: "Ada", emailSubject: "Hi",
                keywords: [], receivedAt: old.addingTimeInterval(TimeInterval(index)), read: false
            )))
        }
        try context.save()

        try await env.repository.pruneHistory()
        let rows = try allRows(env)
        #expect(rows.count == PushNotificationDAO.historyLimit)
        #expect(Set(rows.map(\.messageId)) == Set((70..<100).map { "m-\($0)" }))
    }

    /// The history screen loads nothing after a wipe that gave up.
    @Test func historyIsNotLoadedAfterAnAbandonedWipe() async throws {
        let env = try makePullEnvironment(client: stubClient())
        try await env.repository.recordPushArrival(
            MailPushPayload(messageId: "m-1", senderName: "Ada", emailSubject: "Secret", keywords: ["Work"])
        )
        let viewModel = NotificationHistoryViewModel(
            repository: env.repository,
            pushSettingsStore: env.settings,
            isBlockedByAbandonedWipe: { true }
        )
        await viewModel.load()
        #expect(viewModel.entries.isEmpty)
        #expect(viewModel.latest == nil)

        #expect(NotificationHistoryAccess.decide(isLocked: false, blockedByAbandonedWipe: true) == .blockedByAbandonedWipe)
        #expect(NotificationHistoryAccess.decide(isLocked: true, blockedByAbandonedWipe: true) == .blockedByAbandonedWipe)
        #expect(NotificationHistoryAccess.decide(isLocked: true, blockedByAbandonedWipe: false) == .locked)
        #expect(NotificationHistoryAccess.decide(isLocked: false, blockedByAbandonedWipe: false) == .visible)
    }
}

// MARK: - Review findings, round 2

@MainActor
@Suite struct PullHeartbeatReviewRound2Tests {
    private static func mailJSON(seq: Int, messageId: String, createdAt: Date) -> String {
        """
        { "seq": \(seq), "createdAt": "\(rfc3339(createdAt))",
          "data": { "messageId": "\(messageId)", "senderName": "Ada", "emailSubject": "Hi" } }
        """
    }

    private static func payload(_ id: String) -> MailPushPayload {
        MailPushPayload(messageId: id, senderName: "Ada", emailSubject: "Hi", keywords: [])
    }

    /// An insert that only reaches the DAO after its poll was cancelled
    /// writes nothing, whatever session it carries.
    @Test func aCancelledInsertDoesNotLand() async throws {
        let env = try makePullEnvironment(client: stubClient())
        let notification = PushNotification(
            seq: 1, messageId: "m-1", senderName: "Ada", emailSubject: "Hi",
            keywords: [], receivedAt: Date(), read: false
        )
        let insert = Task { () async throws -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return try await env.dao.insert(notification: notification, session: env.repository.session)
        }
        insert.cancel()
        await #expect(throws: CancellationError.self) { try await insert.value }
        let recorded = Task { () async throws -> PushNotification? in
            while !Task.isCancelled { await Task.yield() }
            return try await env.repository.recordPushArrival(Self.payload("m-2"))
        }
        recorded.cancel()
        await #expect(throws: CancellationError.self) { try await recorded.value }
        #expect(try allRows(env).isEmpty)
    }

    /// A pairing made before `lastRegisteredAt` existed: its first
    /// registration stamps now, and the banner it delivered four hours ago
    /// must still not be alerted again by the heartbeat that follows.
    @Test func anExistingPairingKeepsItsDeliveredBannersAcrossTheMigration() async throws {
        let now = Date()
        let delivered = now.addingTimeInterval(-4 * hour)
        let requests = Box(0)
        let env = try makePullEnvironment(client: stubClient(json: """
        { "cursor": 1, "notifications": [ \(Self.mailJSON(seq: 1, messageId: "m-1", createdAt: delivered)) ] }
        """) { _ in requests.mutate { $0 += 1 } })
        env.settings.deliveryMode = .push
        #expect(env.settings.lastRegisteredAt == nil)
        let log = PresentationLog()
        let pushed = PushNotificationDispatcher.deliveredPush(
            userInfo: ["messageId": "m-1", "senderName": "Ada", "emailSubject": "Hi"],
            date: delivered
        )
        let scheduler = try makeScheduler(env, deliveredPushes: [pushed], log: log)
        let service = makeRegistrationService(
            client: stubClient(
                json: #"{"ok": true, "deviceId": "dev-1", "deviceSecret": "s2", "deliveryMode": "push"}"#
            ),
            pairingStore: env.pairingStore,
            settings: env.settings
        )
        service.reconcileExistingPairingPushes = {
            await scheduler.reconcileDeliveredPushesForExistingPairing(now: now)
        }

        let outcome = await service.pair(
            params: PairingParams(sub: "u1", srv: server, pt: "pt"), deviceToken: "apns"
        )
        guard case .success = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }
        let stamped = try #require(env.settings.lastRegisteredAt)
        #expect(stamped > delivered)

        await scheduler.pollNow(now: now)
        #expect(requests.value == 1)
        #expect(log.items.isEmpty)
        #expect(try await env.repository.history().map(\.messageId) == ["m-1"])
    }

    /// A new pairing (different account) does not adopt banners from before it.
    @Test func aNewPairingDoesNotRunTheExistingPairingReconcile() async throws {
        let env = try makePullEnvironment(client: stubClient(), paired: false)
        let ran = Box(false)
        let service = makeRegistrationService(
            client: stubClient(json: #"{"ok": true, "deviceId": "dev-1", "deviceSecret": "s2"}"#),
            pairingStore: env.pairingStore,
            settings: env.settings
        )
        service.reconcileExistingPairingPushes = { ran.mutate { $0 = true } }
        _ = await service.pair(params: PairingParams(sub: "u1", srv: server, pt: "pt"), deviceToken: "apns")
        #expect(env.settings.lastRegisteredAt != nil)
        #expect(ran.value == false)
        // Nor does routine re-registration once the stamp exists.
        _ = await service.pair(params: PairingParams(sub: "u1", srv: server, pt: "pt"), deviceToken: "apns-2")
        #expect(ran.value == false)
    }

    /// Freshness is measured when the banner would be raised: a challenge
    /// 299 s old at tick start, after a 2 s wait on the relay, is stale.
    @Test func mfaFreshnessIsCheckedAtPresentation() async throws {
        for (elapsed, expected) in [(TimeInterval(2), [String]()), (0, ["mfa:c-1"])] {
            let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let held = HeldTransport(json: """
            { "cursor": 8, "notifications": [
                { "seq": 8, "createdAt": "\(rfc3339(start.addingTimeInterval(-299)))",
                  "data": { "type": "mfa_challenge", "challengeId": "c-1", "matchDigits": "42", "decoyDigits": "17,88" } }
            ] }
            """)
            let env = try makePullEnvironment(client: held.client)
            env.settings.deliveryMode = .pull
            let log = PresentationLog()
            let clock = Box(start)
            let scheduler = try makeScheduler(env, log: log, clock: { clock.value })

            let poll = Task { await scheduler.pollNow(now: start) }
            await held.waitForRequest()
            clock.mutate { $0 = start.addingTimeInterval(elapsed) }
            held.release()
            await poll.value
            #expect(log.items == expected)
        }
    }

    /// Unpairing part-way through recording delivered banners: nothing the
    /// run records afterwards survives into the cleared history.
    @Test func unpairDuringReconcileLeavesNothingBehind() async throws {
        let env = try makePullEnvironment(client: stubClient())
        let now = Date()
        let delivered = (0..<40).map {
            (payload: Self.payload("m-\($0)"), receivedAt: now.addingTimeInterval(TimeInterval(-60 - $0)))
        }
        let reconcile = Task { await env.repository.reconcileDeliveredPushes(delivered, now: now) }
        while try allRows(env).isEmpty { await Task.yield() }
        try env.pairingStore.clear()
        try await env.repository.clearForUnpair()
        await reconcile.value
        #expect(try allRows(env).isEmpty)
    }

    /// Banners older than the heartbeat window are never recorded: nothing
    /// that old can be pulled again, so history has no use for them.
    @Test func bannersOutsideTheHeartbeatWindowAreNotRecorded() async throws {
        let env = try makePullEnvironment(client: stubClient())
        let now = Date()
        await env.repository.reconcileDeliveredPushes([
            (payload: Self.payload("old"), receivedAt: now.addingTimeInterval(-PullHeartbeatPolicy.heartbeatWindow - 60)),
            (payload: Self.payload("new"), receivedAt: now.addingTimeInterval(-60)),
        ], now: now, includingBeforeRegistration: true)
        #expect(try await env.repository.history().map(\.messageId) == ["new"])
    }
}

// MARK: - Presented, then recorded

/// History is the record of what was *presented*. A pulled entry used to be
/// recorded and the cursor advanced before its banner was raised, so a poll
/// cut short in between (a background task expiring) lost the banner for
/// good: the next pull started past it, and history said it was delivered.
@MainActor
@Suite struct PullPresentThenRecordTests {
    private static func mailJSON(seq: Int, messageId: String) -> String {
        """
        { "seq": \(seq), "createdAt": "\(rfc3339(Date()))",
          "data": { "messageId": "\(messageId)", "senderName": "Ada", "emailSubject": "Hi" } }
        """
    }

    private static let twoMails = """
    { "cursor": 2, "deliveryMode": "pull", "notifications": [
        \(mailJSON(seq: 1, messageId: "m-1")), \(mailJSON(seq: 2, messageId: "m-2"))
    ] }
    """

    @Test func fetchingWritesNothingUntilCommitted() async throws {
        let env = try makePullEnvironment(client: stubClient(json: Self.twoMails))

        let batch = try await env.repository.fetchPull()

        #expect(batch.mail.map(\.messageId) == ["m-1", "m-2"])
        #expect(try allRows(env).isEmpty)
        #expect(env.cursorStore.lastCursor == 0)
        #expect(env.settings.lastPulledAt == nil)

        try env.repository.commitPull(batch)
        #expect(env.cursorStore.lastCursor == 2)
        #expect(env.settings.deliveryMode == .pull)
    }

    @Test func whatHistoryHoldsIsNotFetchedAgain() async throws {
        let env = try makePullEnvironment(client: stubClient(json: Self.twoMails))
        let batch = try await env.repository.fetchPull()
        try await env.repository.recordPulled(batch.mail[0], session: batch.session)

        // The cursor never moved: the same entries come back.
        let again = try await env.repository.fetchPull()

        #expect(again.mail.map(\.messageId) == ["m-2"])
    }

    @Test func aPollCutShortPresentsTheRestNextTime() async throws {
        let env = try makePullEnvironment(client: stubClient(json: Self.twoMails))
        env.settings.deliveryMode = .pull
        var presented: [String] = []
        var scheduler: PullPollingScheduler?
        scheduler = try makeScheduler(env, presenter: { item in
            guard case .mail(let mail) = item else { return }
            presented.append(mail.messageId)
            // The background task expires right after the first banner.
            if presented.count == 1 { scheduler?.cancelInFlightPoll() }
        })

        await scheduler?.pollNow()

        #expect(presented == ["m-1"])
        #expect(try allRows(env).isEmpty, "nothing is recorded by a cancelled poll")
        #expect(env.cursorStore.lastCursor == 0)

        await scheduler?.pollNow()

        // The first banner is raised again under the same `pull-<seq>`
        // identifier, which replaces it rather than adding a second.
        #expect(presented == ["m-1", "m-1", "m-2"])
        #expect(try allRows(env).map(\.messageId).sorted() == ["m-1", "m-2"])
        #expect(env.cursorStore.lastCursor == 2)

        await scheduler?.pollNow()
        #expect(presented.count == 3, "a completed poll presents nothing twice")
    }
}
