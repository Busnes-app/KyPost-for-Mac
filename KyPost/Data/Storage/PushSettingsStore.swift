//
//  PushSettingsStore.swift
//  KyPost
//
//  UserDefaults-backed push delivery configuration (spec §3). Nothing here is
//  sensitive: the delivery mode and pull endpoint come from the registration
//  response; the APNs token is device-scoped and rotates.
//

import Foundation

final class PushSettingsStore {
    private enum Key {
        static let deliveryMode = "push.deliveryMode"
        static let pullEndpoint = "push.pullEndpoint"
        static let systemNotificationsEnabled = "push.systemNotificationsEnabled"
        static let lastDeviceToken = "push.lastDeviceToken"
        static let lastPushReceivedAt = "push.lastPushReceivedAt"
        static let lastRegisteredAt = "push.lastRegisteredAt"
        static let lastPulledAt = "push.lastPulledAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var deliveryMode: RegistrationResponse.DeliveryMode? {
        get {
            defaults.string(forKey: Key.deliveryMode)
                .flatMap(RegistrationResponse.DeliveryMode.init(rawValue:))
        }
        set {
            defaults.set(newValue?.rawValue, forKey: Key.deliveryMode)
        }
    }

    /// Resolved pull endpoint from the registration response (spec §3).
    var pullEndpoint: String? {
        get { defaults.string(forKey: Key.pullEndpoint) }
        set { defaults.set(newValue, forKey: Key.pullEndpoint) }
    }

    /// User toggle from Settings; payloads are still parsed and saved to
    /// in-app history when off (spec §3 Notification Permission).
    var systemNotificationsEnabled: Bool {
        get { defaults.object(forKey: Key.systemNotificationsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.systemNotificationsEnabled) }
    }

    // MARK: - Heartbeat clock (PullHeartbeatPolicy)

    /// The newest moment a push is known to have arrived over APNs. Only ever
    /// moves forward: the evidence comes from several places (a payload the
    /// app handled, a banner still in Notification Center) and an older one
    /// must not rewind the quiet clock.
    var lastPushReceivedAt: Date? {
        defaults.object(forKey: Key.lastPushReceivedAt) as? Date
    }

    func markPushReceived(at date: Date) {
        if let current = lastPushReceivedAt, current >= date { return }
        defaults.set(date, forKey: Key.lastPushReceivedAt)
    }

    /// Last successful registration with the server: the last moment the
    /// relay path was proven reachable, used as the quiet clock's start when
    /// no push has ever arrived.
    var lastRegisteredAt: Date? {
        get { defaults.object(forKey: Key.lastRegisteredAt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastRegisteredAt) }
    }

    /// Last successful pull, either mode. Spaces heartbeat polls out.
    var lastPulledAt: Date? {
        get { defaults.object(forKey: Key.lastPulledAt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastPulledAt) }
    }

    /// Forgets the heartbeat clock; unpair calls this so a new pairing starts
    /// counting from its own registration.
    func clearHeartbeatState() {
        defaults.removeObject(forKey: Key.lastPushReceivedAt)
        defaults.removeObject(forKey: Key.lastRegisteredAt)
        defaults.removeObject(forKey: Key.lastPulledAt)
    }

    /// Latest APNs token, kept for re-registration on foreground/pairing.
    var lastDeviceToken: String? {
        get { defaults.string(forKey: Key.lastDeviceToken) }
        set { defaults.set(newValue, forKey: Key.lastDeviceToken) }
    }
}
