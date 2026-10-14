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

    /// The pairing session this repository is writing for. `clearForUnpair`
    /// moves it on before clearing anything, and every write a pull makes is
    /// checked against the value it started with — so a pull still waiting on
    /// the relay when the pairing is removed leaves nothing behind.
    private(set) var session = 0

    /// Whether work started under `session` may still write or present.
    func isCurrent(session: Int) -> Bool { session == self.session }

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

    /// Applies the history cap to rows already on disk — a store written
    /// before the cap existed, or one that has received nothing since.
    /// Runs at launch (`runStartupMigrationsIfNeeded`) and when the history
    /// screen loads.
    func pruneHistory(now: Date = Date()) async throws {
        try await dao.prune(keeping: PushNotificationDAO.historyLimit, now: now)
    }

    func markRead(seq: Int) async throws {
        try await dao.markRead(seq: seq)
    }

    /// Records a push-mode arrival. Push payloads carry no server seq, so one
    /// is synthesized from the arrival time (ms epoch), bumped on collision.
    /// Returns nil when this message is already in history — the heartbeat
    /// pull may have delivered it first.
    /// - Parameter session: the pairing session the caller started under;
    ///   the current one when nil. Throws `CancellationError` once it is not.
    @discardableResult
    func recordPushArrival(
        _ payload: MailPushPayload,
        receivedAt: Date = Date(),
        session: Int? = nil
    ) async throws -> PushNotification? {
        let session = session ?? self.session
        guard isCurrent(session: session) else { throw CancellationError() }
        if try await dao.contains(messageId: payload.messageId) { return nil }
        var seq = Int(receivedAt.timeIntervalSince1970 * 1000)
        var notification = payload.toNotification(seq: seq, receivedAt: receivedAt)
        while try await !dao.insert(notification: notification, session: session) {
            if try await dao.contains(messageId: payload.messageId) { return nil }
            seq += 1
            notification.seq = seq
        }
        return notification
    }

    /// Unpair: history, the pull cursor and the heartbeat clock all belong to
    /// the account the pairing was for.
    ///
    /// The session moves on first, synchronously, so nothing a pull already
    /// in flight does afterwards is accepted — not its history rows, not its
    /// cursor, not its heartbeat stamps, not its banners.
    func clearForUnpair() async throws {
        // Before the session moves: a pull that captures the new session
        // must not be able to load the pairing being left.
        securePairingStore.retireCurrentPairing()
        session += 1
        await dao.invalidateSession(to: session)
        cursorStore.reset()
        pushSettingsStore.clearHeartbeatState()
        try await dao.deleteAll()
    }

    /// Records mail pushes the system delivered while the app was not
    /// running. iOS alert pushes do not wake a suspended app, so these never
    /// reached `handleIncoming`; without them history cannot tell the
    /// heartbeat that this mail was already alerted. Idempotent: history
    /// dedupes by message id.
    ///
    /// Only banners inside the heartbeat window are recorded — nothing older
    /// can be pulled again, so nothing older is needed. Banners older than
    /// the current pairing's registration are skipped as well: unpair leaves
    /// Notification Center alone, and a previous pairing's mail does not
    /// belong in this one's history. `includingBeforeRegistration` lifts that
    /// second bound for a pairing that existed before `lastRegisteredAt` was
    /// recorded (`DeviceRegistrationService`), whose banners are its own.
    ///
    /// The whole run belongs to the session it started under: an unpair
    /// part-way through stops it, rather than letting the remaining banners
    /// land in the history the unpair just cleared.
    func reconcileDeliveredPushes(
        _ delivered: [(payload: MailPushPayload, receivedAt: Date)],
        now: Date = Date(),
        includingBeforeRegistration: Bool = false
    ) async {
        let session = self.session
        guard !delivered.isEmpty, (try? securePairingStore.loadActivePairing()) != nil else { return }
        let windowFloor = now.addingTimeInterval(-PullHeartbeatPolicy.heartbeatWindow)
        let since = includingBeforeRegistration
            ? windowFloor
            : max(windowFloor, pushSettingsStore.lastRegisteredAt ?? .distantPast)
        for item in delivered where item.receivedAt >= since {
            do {
                try await recordPushArrival(item.payload, receivedAt: item.receivedAt, session: session)
            } catch {
                // Session moved on (unpair) or the store failed; stop either way.
                return
            }
        }
    }

    // MARK: - Pull mode

    /// What one pull handed over. MFA challenges are never persisted (spec
    /// §5). From `fetchPull`, `mail` is what history does not hold yet — none
    /// of it recorded; from `pullOnce`, what it recorded.
    struct PullBatch: Equatable, Sendable {
        var mail: [PushNotification] = []
        var mfaChallenges: [PulledMfaChallenge] = []
        /// The pairing session it was fetched under; present nothing from it
        /// once `isCurrent(session:)` is false.
        var session = 0
        /// Where the cursor goes once the batch is handed off (`commitPull`).
        var cursor = 0
        var deliveryMode: RegistrationResponse.DeliveryMode?
    }

    struct PulledMfaChallenge: Equatable, Sendable {
        var challenge: MfaChallenge
        var userInfo: [String: String]
    }

    /// One poll of the pull endpoint, recording every new mail entry in
    /// history and advancing the cursor before returning. For callers that
    /// present nothing; `PullPollingScheduler` uses the three steps below, so
    /// an entry is recorded only once it was presented.
    @discardableResult
    func pullOnce(now: Date = Date(), minCreatedAt: Date? = nil) async throws -> PullBatch {
        var batch = try await fetchPull(now: now, minCreatedAt: minCreatedAt)
        var recorded: [PushNotification] = []
        for notification in batch.mail {
            if try await recordPulled(notification, session: batch.session, now: now) {
                recorded.append(notification)
            }
        }
        batch.mail = recorded
        try commitPull(batch, now: now)
        return batch
    }

    /// Fetches the pull queue and writes nothing.
    ///
    /// `minCreatedAt` drops entries queued before it (entries without a
    /// `createdAt` stay) while still advancing the cursor past them. The
    /// heartbeat passes it because its cursor can be months stale and the
    /// server queues every notification in both modes — without it the first
    /// heartbeat after a long healthy stretch re-alerts everything push
    /// already delivered that history no longer remembers. A first pull
    /// (cursor 0, i.e. fresh or re-paired) applies `firstPullWindow` for the
    /// same reason: the queue holds the account's whole recent backlog.
    ///
    /// Mail already in history (same seq or message id — push delivered it,
    /// or an earlier poll presented it) is left out. Nothing is recorded
    /// here: history is the record of what was *presented*, so an entry is
    /// recorded only after its banner was raised (`recordPulled`), and the
    /// cursor moves only once the whole batch was (`commitPull`). A poll cut
    /// short in between — a background task expiring, the process killed —
    /// fetches the same entries again next time instead of losing them; the
    /// banner identifier is the seq, so one presented twice replaces itself.
    func fetchPull(now: Date = Date(), minCreatedAt: Date? = nil) async throws -> PullBatch {
        // Session first, then the pairing: a teardown retires the pairing
        // before it moves the session, so either the session is stale or the
        // old pairing is refused.
        let session = self.session
        guard let pairing = try securePairingStore.loadActivePairing() else {
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
        // Nothing below may land for a pairing that is gone, or for a graph
        // that has been shut down.
        try Task.checkCancellation()
        guard isCurrent(session: session) else { throw CancellationError() }

        let floor = minCreatedAt ?? (lastCursor == 0 ? now.addingTimeInterval(-Self.firstPullWindow) : nil)
        var seen = Set<Int>()
        let fresh = response.notifications
            .filter { $0.seq > lastCursor && seen.insert($0.seq).inserted }
            .filter { dto in
                guard let floor, let created = dto.createdDate else { return true }
                return created >= floor
            }
            .sorted { $0.seq < $1.seq }

        var batch = PullBatch(session: session)
        var messageIds = Set<String>()
        for dto in fresh {
            switch dto.routed(now: now) {
            case .mail(let notification):
                // History is the dedupe against what push already delivered
                // and what an earlier poll already presented: same messageId,
                // no second alert.
                if try await dao.contains(seq: notification.seq) { continue }
                if try await dao.contains(messageId: notification.messageId) { continue }
                if !notification.messageId.isEmpty, !messageIds.insert(notification.messageId).inserted {
                    continue
                }
                batch.mail.append(notification)
            case .mfaChallenge(let challenge, let userInfo):
                batch.mfaChallenges.append(PulledMfaChallenge(challenge: challenge, userInfo: userInfo))
            case nil:
                break
            }
        }
        try Task.checkCancellation()
        guard isCurrent(session: session) else { throw CancellationError() }
        batch.cursor = max(lastCursor, response.cursor)
        batch.deliveryMode = response.deliveryMode.flatMap(RegistrationResponse.DeliveryMode.wire)
        return batch
    }

    /// Records one pulled entry in history, after it was presented. False
    /// when history already held it.
    @discardableResult
    func recordPulled(_ notification: PushNotification, session: Int, now: Date = Date()) async throws -> Bool {
        guard isCurrent(session: session) else { throw CancellationError() }
        return try await dao.insert(notification: notification, session: session, now: now)
    }

    /// The batch was handed off: apply its delivery mode and only now advance
    /// the cursor (spec §3).
    func commitPull(_ batch: PullBatch, now: Date = Date()) throws {
        // No suspension from here to the end, so an unpair cannot interleave
        // with these writes.
        try Task.checkCancellation()
        guard isCurrent(session: batch.session) else { throw CancellationError() }
        // The response mode is authoritative: a flip to pull makes the next
        // tick poll unconditionally, a flip back makes it a heartbeat again.
        if let mode = batch.deliveryMode {
            pushSettingsStore.deliveryMode = mode
        }
        cursorStore.advance(to: batch.cursor)
        pushSettingsStore.lastPulledAt = now
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
