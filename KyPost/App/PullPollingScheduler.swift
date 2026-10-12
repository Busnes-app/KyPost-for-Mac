//
//  PullPollingScheduler.swift
//  KyPost
//
//  Pull-mode polling cadence (spec §3): every 90 seconds while foregrounded,
//  immediately on foreground/pairing. Background: BGAppRefreshTask on iOS
//  (~15 min platform minimum); macOS resumes on wake and otherwise polls
//  full-time while running (spec FAQ).
//
//  In push mode the same poll is the heartbeat (server issue #137 option 1):
//  the server queues every notification for pull in both delivery modes and
//  never flips the mode itself, so a device on a dead relay recovers only by
//  polling. `PullHeartbeatPolicy` decides whether a tick touches the network.
//

import Foundation
import os

/// Whether one tick polls. Pure, so the whole decision is a unit test.
nonisolated enum PullHeartbeatPolicy {
    /// How long APNs may be silent before push mode polls the queue. A
    /// constant, not a setting (as on Android): guessing wrong costs one
    /// heartbeat interval of latency.
    static let pushQuietThreshold: TimeInterval = 3 * 60 * 60

    /// Spacing between heartbeat polls once push has gone quiet — the iOS
    /// background-refresh floor, so a foregrounded app does not poll every
    /// 90 seconds just because nobody has mailed the user for three hours.
    static let heartbeatSpacing: TimeInterval = 15 * 60

    /// A heartbeat drops queued entries older than this. Twice the threshold:
    /// the first heartbeat runs up to one spacing after the threshold, and
    /// nothing since the last push may be dropped.
    static let heartbeatWindow: TimeInterval = 2 * pushQuietThreshold

    enum Decision: Equatable {
        /// Poll. `heartbeat` is true in push mode, which bounds entry age.
        case poll(heartbeat: Bool)
        /// Push mode and push is healthy (or a heartbeat ran recently).
        case skip
    }

    /// Pull mode always polls. Push mode (or no mode yet — anything that is
    /// not an explicit pull is push) polls only once no push has arrived for
    /// `pushQuietThreshold`, counted from the last push or, when none has ever
    /// arrived, from the last registration. A pull answer of "push" is not
    /// "stop polling".
    ///
    /// Spacing counts from the later of the last successful pull and the last
    /// heartbeat *attempt*, so a relay answering errors is retried every
    /// `heartbeatSpacing`, not every tick.
    static func decide(
        mode: RegistrationResponse.DeliveryMode?,
        lastPushReceivedAt: Date?,
        lastRegisteredAt: Date?,
        lastPulledAt: Date?,
        lastHeartbeatAttemptAt: Date? = nil,
        now: Date
    ) -> Decision {
        if mode == .pull { return .poll(heartbeat: false) }
        let quietSince = lastPushReceivedAt ?? lastRegisteredAt ?? .distantPast
        guard now.timeIntervalSince(quietSince) >= pushQuietThreshold else { return .skip }
        for last in [lastPulledAt, lastHeartbeatAttemptAt].compactMap({ $0 })
        where last <= now && now.timeIntervalSince(last) < heartbeatSpacing {
            return .skip
        }
        return .poll(heartbeat: true)
    }
}

@MainActor
final class PullPollingScheduler {
    /// Pulled MFA challenges older than this are not raised: the server's
    /// approval window is five minutes, and a stale tap-to-approve banner
    /// only teaches the user to tap approval banners.
    static let mfaFreshness: TimeInterval = 5 * 60

    private let pushRepository: PushRepository
    private let pushSettingsStore: PushSettingsStore
    private let dispatcher: PushNotificationDispatcher
    /// APNs pushes the system still shows in Notification Center. iOS alert
    /// pushes do not wake the app, so this is the only evidence a push
    /// arrived — and which mail it alerted — while it was suspended.
    private let deliveredPushes: () async -> [DeliveredPush]
    /// Where pulled arrivals are shown; the dispatcher's local banners unless
    /// a test substitutes a recorder.
    private let presenter: PulledPresenter?
    /// The wall clock, injectable so a test can let time pass while a poll
    /// waits on the relay.
    private let clock: () -> Date
    private var pollingTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    init(
        pushRepository: PushRepository,
        pushSettingsStore: PushSettingsStore,
        dispatcher: PushNotificationDispatcher,
        deliveredPushes: @escaping () async -> [DeliveredPush] = { [] },
        presenter: PulledPresenter? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.pushRepository = pushRepository
        self.pushSettingsStore = pushSettingsStore
        self.dispatcher = dispatcher
        self.deliveredPushes = deliveredPushes
        self.presenter = presenter
        self.clock = clock
    }

    /// Starts the foreground cadence (immediate tick, then every 90s). Runs
    /// in both modes: in push mode each tick is a heartbeat check that does
    /// not touch the network until push has been quiet past the threshold.
    func startForegroundPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollNow()
                try? await Task.sleep(for: .seconds(Config.foregroundRefreshInterval))
            }
        }
    }

    func stopForegroundPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Graph teardown (`SingletonGraph.shutdown`): stops the cadence *and*
    /// the poll in flight, which is its own task and outlives the cadence's
    /// cancellation. A cancelled poll persists and presents nothing.
    /// Backgrounding only stops the cadence, so a poll already under way
    /// still delivers its banners.
    func shutdown() {
        stopForegroundPolling()
        inFlight?.cancel()
        inFlight = nil
    }

    /// Whether the 90s cadence is running (shutdown assertions in tests).
    var isPolling: Bool { pollingTask != nil }

    /// One tick: decide, then fetch, persist, and present local notifications
    /// for new arrivals.
    ///
    /// One at a time. Foreground, the cadence, wake and background refresh
    /// all enter here; two overlapping runs read the same cursor and would
    /// both present the same MFA challenge (mail is deduped by history, MFA
    /// is never stored). A caller arriving mid-run waits for that run.
    func pollNow(now: Date = Date()) async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.runPoll(now: now) }
        inFlight = task
        await task.value
        // `shutdown` may have cleared (or a later poll replaced) the slot.
        if inFlight == task { inFlight = nil }
    }

    /// Records the mail banners still in Notification Center into history,
    /// including those from before `lastRegisteredAt`. Only for a pairing
    /// that existed before that stamp was recorded: its first registration
    /// sets the stamp to now, which would otherwise exclude banners it
    /// delivered earlier and let the heartbeat alert them a second time.
    func reconcileDeliveredPushesForExistingPairing(now: Date = Date()) async {
        let delivered = await deliveredPushes()
        await pushRepository.reconcileDeliveredPushes(
            Self.mail(in: delivered), now: now, includingBeforeRegistration: true
        )
    }

    private static func mail(in delivered: [DeliveredPush]) -> [(payload: MailPushPayload, receivedAt: Date)] {
        delivered.compactMap { item in item.mail.map { (payload: $0, receivedAt: item.date) } }
    }

    private func runPoll(now: Date) async {
        let started = clock()
        let delivered = await deliveredPushes()
        guard !Task.isCancelled else { return }
        if let newest = delivered.map(\.date).max() {
            pushSettingsStore.markPushReceived(at: newest)
        }
        // Before the pull, so history already knows what push alerted.
        await pushRepository.reconcileDeliveredPushes(Self.mail(in: delivered), now: now)
        let decision = PullHeartbeatPolicy.decide(
            mode: pushSettingsStore.deliveryMode,
            lastPushReceivedAt: pushSettingsStore.lastPushReceivedAt,
            lastRegisteredAt: pushSettingsStore.lastRegisteredAt,
            lastPulledAt: pushSettingsStore.lastPulledAt,
            lastHeartbeatAttemptAt: pushSettingsStore.lastHeartbeatAttemptAt,
            now: now
        )
        guard case .poll(let heartbeat) = decision, !Task.isCancelled else { return }
        if heartbeat {
            pushSettingsStore.lastHeartbeatAttemptAt = now
        }
        do {
            let batch = try await pushRepository.pullOnce(
                now: now,
                minCreatedAt: heartbeat ? now.addingTimeInterval(-PullHeartbeatPolicy.heartbeatWindow) : nil
            )
            func stillCurrent() -> Bool {
                !Task.isCancelled && pushRepository.isCurrent(session: batch.session)
            }
            for pulled in batch.mfaChallenges {
                guard stillCurrent() else { return }
                // Measured at presentation, not at tick start: the
                // reconcile and the request both take time, and the tick's
                // `now` moves on with the clock.
                let presentedAt = now.addingTimeInterval(clock().timeIntervalSince(started))
                guard presentedAt.timeIntervalSince(pulled.challenge.receivedAt) < Self.mfaFreshness else {
                    continue
                }
                await present(.mfa(pulled))
            }
            for notification in batch.mail {
                guard stillCurrent() else { return }
                await present(.mail(notification))
            }
        } catch is CancellationError {
            // Shut down or unpaired mid-pull; nothing was kept.
        } catch MailSourceError.notPaired {
            // Not an error state; pairing just hasn't happened yet.
        } catch MailSourceError.credentialUnavailable {
            // Credential gate + locked: retries after the next unlock.
        } catch {
            Log.push.error("Pull poll failed: \(error)")
        }
    }

    private func present(_ item: PulledPresentation) async {
        if let presenter {
            await presenter(item)
            return
        }
        switch item {
        case .mfa(let pulled):
            await dispatcher.presentMfaLocally(pulled.challenge, userInfo: pulled.userInfo)
        case .mail(let notification):
            await dispatcher.presentLocally(notification)
        }
    }
}

/// One APNs notification still in Notification Center: when it arrived and,
/// for mail, which message it alerted.
struct DeliveredPush: Equatable, Sendable {
    var date: Date
    var mail: MailPushPayload? = nil
}

/// Something a pull asks to be shown.
enum PulledPresentation: Sendable {
    case mail(PushNotification)
    case mfa(PushRepository.PulledMfaChallenge)
}

typealias PulledPresenter = @MainActor (PulledPresentation) async -> Void
