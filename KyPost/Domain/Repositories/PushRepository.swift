//
//  PushRepository.swift
//  KyPost
//
//  Notification history + pull-mode polling (spec §3). De-duplication is by
//  strictly-increasing seq; the cursor advances to max(last, response.cursor)
//  only after notifications are handed off.
//

import Foundation

final class PushRepository {
    private let dao: PushNotificationDAO
    private let cursorStore: NotificationCursorStore
    private let client: PushNotificationClient
    private let securePairingStore: SecurePairingStore
    private let pushSettingsStore: PushSettingsStore

    init(
        dao: PushNotificationDAO,
        cursorStore: NotificationCursorStore,
        client: PushNotificationClient,
        securePairingStore: SecurePairingStore,
        pushSettingsStore: PushSettingsStore
    ) {
        self.dao = dao
        self.cursorStore = cursorStore
        self.client = client
        self.securePairingStore = securePairingStore
        self.pushSettingsStore = pushSettingsStore
    }

    // MARK: - History

    func history(limit: Int = PushNotificationDAO.historyLimit) async throws -> [PushNotification] {
        try await dao.listHistory(limit: limit)
    }

    func markRead(seq: Int) async throws {
        try await dao.markRead(seq: seq)
    }

    /// Records a push-mode arrival. Push payloads carry no server seq, so one
    /// is synthesized from the arrival time (ms epoch), bumped on collision.
    /// Returns nil when this message is already in history — the heartbeat
    /// pull may have delivered it first.
    @discardableResult
    func recordPushArrival(
        _ payload: MailPushPayload,
        receivedAt: Date = Date()
    ) async throws -> PushNotification? {
        if try await dao.contains(messageId: payload.messageId) { return nil }
        var seq = Int(receivedAt.timeIntervalSince1970 * 1000)
        var notification = payload.toNotification(seq: seq, receivedAt: receivedAt)
        while try await !dao.insert(notification: notification) {
            if try await dao.contains(messageId: payload.messageId) { return nil }
            seq += 1
            notification.seq = seq
        }
        return notification
    }

    /// Unpair: history, the pull cursor and the heartbeat clock all belong to
    /// the account the pairing was for.
    func clearForUnpair() async throws {
        cursorStore.reset()
        pushSettingsStore.clearHeartbeatState()
        try await dao.deleteAll()
    }

    // MARK: - Pull mode

    /// What one pull handed over. Mail is already persisted to history and
    /// contains only entries that were new to it; MFA challenges are never
    /// persisted (spec §5).
    struct PullBatch: Equatable, Sendable {
        var mail: [PushNotification] = []
        var mfaChallenges: [PulledMfaChallenge] = []
    }

    struct PulledMfaChallenge: Equatable, Sendable {
        var challenge: MfaChallenge
        var userInfo: [String: String]
    }

    /// One poll of the pull endpoint.
    ///
    /// `minCreatedAt` drops entries queued before it (entries without a
    /// `createdAt` stay) while still advancing the cursor past them. The
    /// heartbeat passes it because its cursor can be months stale and the
    /// server queues every notification in both modes — without it the first
    /// heartbeat after a long healthy stretch re-alerts everything push
    /// already delivered that history no longer remembers. A first pull
    /// (cursor 0, i.e. fresh or re-paired) applies `firstPullWindow` for the
    /// same reason: the queue holds the account's whole recent backlog.
    @discardableResult
    func pullOnce(now: Date = Date(), minCreatedAt: Date? = nil) async throws -> PullBatch {
        guard let pairing = try securePairingStore.loadPairing() else {
            throw MailSourceError.notPaired
        }
        guard let endpoint = resolvePullEndpoint(srv: pairing.srv) else {
            throw NetworkError.invalidURL
        }

        let lastCursor = cursorStore.lastCursor
        let response = try await client.pull(
            endpoint: endpoint,
            auth: RelayAuth(pairing: pairing),
            after: lastCursor
        )
        // The response mode is authoritative: a flip to pull makes the next
        // tick poll unconditionally, a flip back makes it a heartbeat again.
        if let mode = response.deliveryMode.flatMap(RegistrationResponse.DeliveryMode.wire) {
            pushSettingsStore.deliveryMode = mode
        }

        let floor = minCreatedAt ?? (lastCursor == 0 ? now.addingTimeInterval(-Self.firstPullWindow) : nil)
        var seen = Set<Int>()
        let fresh = response.notifications
            .filter { $0.seq > lastCursor && seen.insert($0.seq).inserted }
            .filter { dto in
                guard let floor, let created = dto.createdDate else { return true }
                return created >= floor
            }
            .sorted { $0.seq < $1.seq }

        var batch = PullBatch()
        for dto in fresh {
            switch dto.routed(now: now) {
            case .mail(let notification):
                // History is the dedupe against what push already delivered:
                // same messageId, no second alert.
                if try await dao.insert(notification: notification) {
                    batch.mail.append(notification)
                }
            case .mfaChallenge(let challenge, let userInfo):
                batch.mfaChallenges.append(PulledMfaChallenge(challenge: challenge, userInfo: userInfo))
            case nil:
                break
            }
        }

        // Hand-off complete; only now advance the cursor (spec §3).
        cursorStore.advance(to: max(lastCursor, response.cursor))
        pushSettingsStore.lastPulledAt = now
        return batch
    }

    /// How far back a first pull (cursor 0) reaches.
    static let firstPullWindow: TimeInterval = PullHeartbeatPolicy.heartbeatWindow

    // MARK: - Private

    private func resolvePullEndpoint(srv: String) -> URL? {
        if let stored = pushSettingsStore.pullEndpoint, let url = URL(string: stored) {
            return url
        }
        return URL(string: srv)?.appending(path: "api/notifications/native/pull")
    }
}
