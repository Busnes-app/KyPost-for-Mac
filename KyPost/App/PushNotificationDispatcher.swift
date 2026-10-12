//
//  PushNotificationDispatcher.swift
//  KyPost
//
//  UNUserNotificationCenter integration (spec §3, §5): category setup
//  (MAIL_NOTIFICATION, MFA_CHALLENGE with Approve/Deny), incoming payload
//  handling, local presentation for pull-mode arrivals, and routing taps to
//  NavigationActions for the UI layer (Phase 6 sets `onNavigate`).
//

import Foundation
import os
import UserNotifications

@MainActor
final class PushNotificationDispatcher: NSObject {
    static let mailCategoryId = "MAIL_NOTIFICATION"
    // Nonisolated: read from the nonisolated willPresent delegate callback.
    nonisolated static let mfaCategoryId = "MFA_CHALLENGE"
    static let approveActionId = "APPROVE"
    static let denyActionId = "DENY"

    private let pushRepository: PushRepository
    private let approveMfaChallenge: ApproveMfaChallengeUseCase
    private let pushSettingsStore: PushSettingsStore

    /// Set by the UI layer to route notification taps.
    var onNavigate: ((NavigationAction) -> Void)?

    init(
        pushRepository: PushRepository,
        approveMfaChallenge: ApproveMfaChallengeUseCase,
        pushSettingsStore: PushSettingsStore
    ) {
        self.pushRepository = pushRepository
        self.approveMfaChallenge = approveMfaChallenge
        self.pushSettingsStore = pushSettingsStore
    }

    // MARK: - Setup

    /// Registers categories and takes over as the center's delegate.
    /// Call once at launch, before any notification can arrive.
    func configure(center: UNUserNotificationCenter = .current()) {
        center.delegate = self
        center.setNotificationCategories(Self.categories)
    }

    /// Exposed as a pure value (rather than built inline inside `configure`)
    /// so its action options — notably that Approve requires device
    /// authentication — are directly testable without touching the real
    /// notification center.
    static var categories: Set<UNNotificationCategory> {
        let mailCategory = UNNotificationCategory(
            identifier: Self.mailCategoryId,
            actions: [], // no direct actions; tap opens inbox (spec §3)
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let mfaCategory = UNNotificationCategory(
            identifier: Self.mfaCategoryId,
            actions: [
                // Deny only. Approving now means picking the number the browser
                // is showing (the backend verifies it and refuses an approval
                // without it), and a banner cannot present that choice — an
                // Approve button here could only ever send a blind approval,
                // which the server rejects and which is precisely the tap an
                // MFA-fatigue attack harvests. Body tap opens the approval
                // screen instead.
                //
                // Deny stays: the safe answer must remain one tap away, because
                // the person most likely to press it is someone being fatigued,
                // looking at a number they cannot match.
                UNNotificationAction(identifier: Self.denyActionId, title: "Deny", options: [.destructive]),
            ],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        return [mailCategory, mfaCategory]
    }

    /// Spec §3: request at first app launch. Denial is fine — payloads are
    /// still parsed into in-app history.
    @discardableResult
    func requestAuthorization(center: UNUserNotificationCenter = .current()) async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            if !granted {
                Log.push.warning("Notification authorization not granted — pushes will be delivered silently")
            }
            return granted
        } catch {
            Log.push.error("Notification authorization request failed: \(error)")
            return false
        }
    }

    // MARK: - Incoming payloads

    /// Processes a remote payload (APNs wake or `xcrun simctl push`).
    func handleIncoming(userInfo: [AnyHashable: Any]) async {
        // Refuse everything after a wipe that gave up. That state means a wipe
        // ran because this Mac was presumed to be in the wrong hands, it could
        // not delete everything, and it has stopped trying — and the pairing
        // credential is one of the likelier survivors. Recording an arrival
        // here would write sender and subject back into a machine the app has
        // already decided is compromised. The blocking screen covers windows;
        // this path never presents one.
        guard !SingletonGraph.shared.securityWipe.blockedByAbandonedWipe else {
            Log.push.error("Ignoring a push: a previous wipe was abandoned with data still on disk")
            return
        }
        guard let payload = PushPayloadMapper.map(userInfo: userInfo) else {
            Log.push.warning("Ignoring unrecognized push payload")
            return
        }
        // Resets the heartbeat's quiet clock: APNs is demonstrably working.
        pushSettingsStore.markPushReceived(at: Date())
        switch payload {
        case .mail(let mail):
            // APNs already showed the system banner (aps.alert); record history.
            do {
                try await pushRepository.recordPushArrival(mail)
            } catch {
                Log.push.error("Failed to record push arrival: \(error)")
            }
        case .mfaChallenge:
            // Alert + action buttons come from the aps payload's category;
            // nothing to persist (spec §5: don't retain challenge data).
            break
        }
    }

    /// Presents a local notification for a pull-mode arrival (the server
    /// never contacted APNs in pull mode, spec §3).
    ///
    /// While the app lock is engaged the sender and subject are withheld:
    /// "Require Unlock to Open" is the toggle a user reads as "nobody sees my
    /// mail without authenticating", and putting a subject line on the lock
    /// screen is the most visible way to break that promise. The full entry is
    /// still recorded in history and shows once the app is unlocked.
    func presentLocally(
        _ notification: PushNotification,
        center: UNUserNotificationCenter = .current(),
        redactContent: Bool? = nil
    ) async {
        guard pushSettingsStore.systemNotificationsEnabled else { return }
        guard !SingletonGraph.shared.securityWipe.blockedByAbandonedWipe else { return }
        // Resolve first: inside a suspended grace period the timer never
        // fired, and the deadline is the truth.
        let redact = redactContent ?? SingletonGraph.shared.appLockManager.resolvePendingLock()

        let content = UNMutableNotificationContent()
        content.title = redact
            ? String(localized: "KyPost")
            : notification.senderName
        content.body = redact
            ? String(localized: "New mail — unlock KyPost to read it")
            : notification.emailSubject
        content.sound = .default
        content.categoryIdentifier = Self.mailCategoryId
        // The tap only needs the message id. Sender and subject ride along
        // only when they are on screen anyway: a delivered notification's
        // userInfo is stored by the system, and a redacted banner carrying the
        // subject in its payload has only hidden it from the user.
        content.userInfo = redact
            ? ["messageId": notification.messageId]
            : [
                "messageId": notification.messageId,
                "senderName": notification.senderName,
                "emailSubject": notification.emailSubject,
                "Keywords": notification.keywords,
            ]
        let request = UNNotificationRequest(
            identifier: "pull-\(notification.seq)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            Log.push.error("Failed to present local notification: \(error)")
        }
    }
}

extension PushNotificationDispatcher {
    /// Presents a pulled MFA challenge. Tap-to-open only, and no challenge
    /// detail in the banner whether or not the app is locked — the decision
    /// happens on the approval screen, which re-authenticates. The userInfo
    /// is the server's data map, so a tap routes through `PushPayloadMapper`
    /// exactly like an APNs challenge.
    func presentMfaLocally(
        _ challenge: MfaChallenge,
        userInfo: [String: String],
        center: UNUserNotificationCenter = .current()
    ) async {
        guard pushSettingsStore.systemNotificationsEnabled else { return }
        guard !SingletonGraph.shared.securityWipe.blockedByAbandonedWipe else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Sign-in approval requested")
        content.body = String(localized: "Open KyPost to review this sign-in.")
        content.sound = .default
        content.categoryIdentifier = Self.mfaCategoryId
        content.userInfo = Self.mfaUserInfo(from: userInfo)
        let request = UNNotificationRequest(
            identifier: "mfa-\(challenge.challengeId)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            Log.push.error("Failed to present local MFA notification: \(error)")
        }
    }

    /// Only what routing a tap needs; nothing else from the relay is stored
    /// in the system's notification database.
    static func mfaUserInfo(from data: [String: String]) -> [String: String] {
        data.filter { ["type", "challengeId", "matchDigits", "decoyDigits"].contains($0.key) }
    }

    /// The remote (APNs) notifications still in Notification Center, with
    /// the mail each one alerted. Alert pushes do not wake a suspended app,
    /// so this is how the heartbeat learns push is alive, and how history
    /// learns what push already alerted, without a service extension. Empty
    /// when the user has cleared them — the heartbeat then errs toward one
    /// extra poll — and after an abandoned wipe, which records nothing.
    func deliveredRemotePushes(
        center: UNUserNotificationCenter = .current()
    ) async -> [DeliveredPush] {
        guard !SingletonGraph.shared.securityWipe.blockedByAbandonedWipe else { return [] }
        return await center.deliveredNotifications()
            .filter { $0.request.trigger is UNPushNotificationTrigger }
            .map { Self.deliveredPush(userInfo: $0.request.content.userInfo, date: $0.date) }
    }

    static func deliveredPush(userInfo: [AnyHashable: Any], date: Date) -> DeliveredPush {
        guard case .mail(let mail) = PushPayloadMapper.map(userInfo: userInfo, receivedAt: date) else {
            return DeliveredPush(date: date, mail: nil)
        }
        return DeliveredPush(date: date, mail: mail)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationDispatcher: UNUserNotificationCenterDelegate {
    /// Foreground presentation: MFA challenges are high priority (banner +
    /// sound, spec §3); mail shows a banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if notification.request.trigger is UNPushNotificationTrigger {
            let date = notification.date
            await MainActor.run { self.pushSettingsStore.markPushReceived(at: date) }
        }
        return notification.request.content.categoryIdentifier == Self.mfaCategoryId
            ? [.banner, .sound]
            : [.banner]
    }

    /// Action buttons and body taps.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case Self.approveActionId:
            // No longer registered (see `categories`), but a notification
            // delivered before this build was installed can still carry it.
            // Route it to the approval screen rather than sending a blind
            // approval the server would refuse.
            switch PushPayloadMapper.map(userInfo: userInfo) {
            case .mfaChallenge(let challenge):
                onNavigate?(.openMfaApproval(challenge))
            default:
                break
            }

        case Self.denyActionId:
            guard let challengeId = userInfo["challengeId"] as? String else { return }
            // Deny needs no number — the backend ignores matchDigits on a deny.
            let outcome = await approveMfaChallenge(challengeId: challengeId, approved: false)
            Log.push.info("MFA deny outcome: \(String(describing: outcome))")

        case UNNotificationDefaultActionIdentifier:
            // Body tap: MFA → in-app approval screen (spec §5); mail → inbox.
            switch PushPayloadMapper.map(userInfo: userInfo) {
            case .mfaChallenge(let challenge):
                onNavigate?(.openMfaApproval(challenge))
            case .mail(let mail):
                onNavigate?(.openEmail(messageId: mail.messageId))
            case nil:
                break
            }

        default:
            break
        }
    }
}
