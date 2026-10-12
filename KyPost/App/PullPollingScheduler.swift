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
    static func decide(
        mode: RegistrationResponse.DeliveryMode?,
        lastPushReceivedAt: Date?,
        lastRegisteredAt: Date?,
        lastPulledAt: Date?,
        now: Date
    ) -> Decision {
        if mode == .pull { return .poll(heartbeat: false) }
        let quietSince = lastPushReceivedAt ?? lastRegisteredAt ?? .distantPast
        guard now.timeIntervalSince(quietSince) >= pushQuietThreshold else { return .skip }
        if let lastPulledAt, now.timeIntervalSince(lastPulledAt) < heartbeatSpacing,
           lastPulledAt <= now {
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
    /// Newest APNs arrival the system still remembers. iOS alert pushes do
    /// not wake the app, so Notification Center is the only evidence a push
    /// arrived while it was suspended.
    private let deliveredPushDate: () async -> Date?
    private var pollingTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    init(
        pushRepository: PushRepository,
        pushSettingsStore: PushSettingsStore,
        dispatcher: PushNotificationDispatcher,
        deliveredPushDate: @escaping () async -> Date? = { nil }
    ) {
        self.pushRepository = pushRepository
        self.pushSettingsStore = pushSettingsStore
        self.dispatcher = dispatcher
        self.deliveredPushDate = deliveredPushDate
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
        inFlight = nil
    }

    private func runPoll(now: Date) async {
        if let delivered = await deliveredPushDate() {
            pushSettingsStore.markPushReceived(at: delivered)
        }
        let decision = PullHeartbeatPolicy.decide(
            mode: pushSettingsStore.deliveryMode,
            lastPushReceivedAt: pushSettingsStore.lastPushReceivedAt,
            lastRegisteredAt: pushSettingsStore.lastRegisteredAt,
            lastPulledAt: pushSettingsStore.lastPulledAt,
            now: now
        )
        guard case .poll(let heartbeat) = decision else { return }
        do {
            let batch = try await pushRepository.pullOnce(
                now: now,
                minCreatedAt: heartbeat ? now.addingTimeInterval(-PullHeartbeatPolicy.heartbeatWindow) : nil
            )
            for pulled in batch.mfaChallenges
            where now.timeIntervalSince(pulled.challenge.receivedAt) < Self.mfaFreshness {
                await dispatcher.presentMfaLocally(pulled.challenge, userInfo: pulled.userInfo)
            }
            for notification in batch.mail {
                await dispatcher.presentLocally(notification)
            }
        } catch MailSourceError.notPaired {
            // Not an error state; pairing just hasn't happened yet.
        } catch MailSourceError.credentialUnavailable {
            // Credential gate + locked: retries after the next unlock.
        } catch {
            Log.push.error("Pull poll failed: \(error)")
        }
    }
}
