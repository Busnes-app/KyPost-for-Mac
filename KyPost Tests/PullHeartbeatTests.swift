//
//  PullHeartbeatTests.swift
//  KyPost Tests
//
//  The push-mode heartbeat (Android #129 / server issue #137 option 1), the
//  server's pull wire shape, and notification history.
//

import Foundation
import Testing
@testable import KyPost

private struct PullEnvironment {
    var repository: PushRepository
    var cursorStore: NotificationCursorStore
    var settings: PushSettingsStore
    var dao: PushNotificationDAO
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
    return PullEnvironment(repository: repository, cursorStore: cursorStore, settings: settings, dao: dao)
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
    private func makeScheduler(
        _ env: PullEnvironment,
        deliveredPushDate: Date? = nil
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
            deliveredPushDate: { deliveredPushDate }
        )
    }

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

        let scheduler = try makeScheduler(env, deliveredPushDate: Date().addingTimeInterval(-60))
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
