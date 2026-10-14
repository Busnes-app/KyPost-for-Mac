//
//  DeviceRegistrationService.swift
//  KyPost
//
//  Push token registration flow (spec §3): initial pairing from a QR/deep
//  link, and re-registration on token refresh / app foreground using the
//  stored pairing. On success the pairing and delivery settings are persisted.
//

import Foundation
import os

extension PairingParams {
    /// Rebuilds link params from a stored pairing, for re-registration.
    init(pairing: Pairing) {
        self.init(
            sub: pairing.sub,
            srv: pairing.srv,
            pt: pairing.pairingToken,
            reg: pairing.registrationUrl,
            // Deliberately no pin. Re-registration is not a user handing the
            // app a fresh link; the pin persisted at pairing already governs
            // this host through the shared relay session.
            pin: nil
        )
    }
}

/// One pairing attempt's own connection to the relay: its own URLSession and
/// pinning delegate, so a pin it carries never reaches the shared session
/// background sync uses. `RelayPairingConnection` in the app; a stub in tests.
@MainActor
protocol PairingConnection: AnyObject {
    /// Forces a TLS handshake with `url`'s host and returns the SPKI hash it
    /// presented, or nil when no handshake could be observed.
    func probe(_ url: URL) async -> String?
    /// Every handshake this connection makes from now on must present `hash`.
    func pin(_ hash: String)
    /// Registers over this connection.
    func register(deviceToken: String, params: PairingParams, deviceId: String?) async -> RegistrationOutcome
    /// Ends the connection. Called once the attempt is over, success or not.
    func close()
}

/// `@MainActor` because `inFlight` is unsynchronised mutable state and every
/// caller (PushPairingViewModel, the `@MainActor` PushLifecycle) already runs
/// here. Under Swift 5 language mode the compiler says nothing about that, so
/// the isolation is stated rather than assumed.
@MainActor
final class DeviceRegistrationService {
    /// Re-registration only. It rides the shared relay session, whose
    /// delegate enforces the pin stored for the paired host.
    private let client: NativeRegistrationClient
    private let securePairingStore: SecurePairingStore
    private let pushSettingsStore: PushSettingsStore
    /// Opens a dedicated connection for one pairing from a link, given the
    /// relay host and the pin it must enforce from its first handshake (nil:
    /// none yet, the first handshake runs on system trust). A `var` so a test
    /// can keep the graph's wiring and swap only the network.
    var makePairingConnection: (_ host: String, _ pin: String?) -> any PairingConnection
    /// Records the banners an existing pairing already delivered into
    /// history, ignoring `lastRegisteredAt`. Run when a pairing that predates
    /// that stamp registers for the first time and so gets it set to now.
    /// Wired by SingletonGraph to `PullPollingScheduler`; nil in tests that
    /// do not exercise it.
    var reconcileExistingPairingPushes: (() async -> Void)?

    /// Runs before a registration's pairing is stored over one for another
    /// account (another `sub` or server), so the previous account's
    /// account-scoped state is erased as an unpair would. Wired by
    /// SingletonGraph to `AccountTeardown`, the list unpair runs; nil in tests.
    /// Returns false when a step failed: the new pairing is then not stored.
    var onAccountReplaced: (@MainActor () async -> Bool)?

    /// One registration per (kind, pairing token, device token). A pairing
    /// deep link is delivered to every open main window, so without this
    /// guard a single click could register the same computer several times
    /// (the server appends a device row per register call). Pairing tokens
    /// are not single-use, so only concurrent calls are shared — a later call
    /// with a new device token (APNs refresh) must still go through. A pairing
    /// never shares a re-registration's result: only the pairing checks the
    /// link's pin.
    private var inFlight: [String: Task<RegistrationOutcome, Never>] = [:]

    init(
        client: NativeRegistrationClient,
        securePairingStore: SecurePairingStore,
        pushSettingsStore: PushSettingsStore,
        makePairingConnection: @escaping (_ host: String, _ pin: String?) -> any PairingConnection
    ) {
        self.client = client
        self.securePairingStore = securePairingStore
        self.pushSettingsStore = pushSettingsStore
        self.makePairingConnection = makePairingConnection
    }

    /// Initial pairing (QR scan / deep link). Persists the pairing, its
    /// certificate pin and delivery settings only if registration succeeds
    /// (spec §1 flow). Concurrent calls with the same tokens share one
    /// registration.
    func pair(
        params: PairingParams,
        deviceToken: String,
        deviceId: String? = nil
    ) async -> RegistrationOutcome {
        await deduplicated(key: "pair|\(params.pt)|\(deviceToken)") {
            await self.performPair(params: params, deviceToken: deviceToken, deviceId: deviceId)
        }
    }

    /// Re-registration for safety (token refresh, app foreground, spec §3).
    /// Sends the stored deviceId so the server updates the existing device
    /// row rather than pairing this computer a second time.
    /// Returns nil when the device was never paired — nothing to refresh.
    ///
    /// Never captures a pin. A pairing that has none (an older build could
    /// not record one) stays unpinned until it is removed and paired again:
    /// a key adopted on some later foreground would be whatever that network
    /// presented, not what the pairing saw.
    @discardableResult
    func reregisterIfPaired(deviceToken: String) async -> RegistrationOutcome? {
        // Not a retired pairing: re-registering the account being left would
        // store it again over the teardown.
        guard let pairing = try? securePairingStore.loadActivePairing() else { return nil }
        let params = PairingParams(pairing: pairing)
        return await deduplicated(key: "reregister|\(params.pt)|\(deviceToken)") {
            let outcome = await self.client.register(
                deviceToken: deviceToken,
                params: params,
                deviceId: pairing.lastDeviceId
            )
            return await self.storeRegistration(outcome, params: params, deviceId: pairing.lastDeviceId, pin: nil)
        }
    }

    private func deduplicated(
        key: String,
        _ operation: @escaping @MainActor () async -> RegistrationOutcome
    ) async -> RegistrationOutcome {
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task { await operation() }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        return outcome
    }

    /// A pairing from a link. Every credential this request carries (the
    /// pairing token and push endpoint up, the device secret down) crosses a
    /// connection already held to the pin the pairing will store:
    ///
    /// 1. A pin already stored for this host stays authoritative; a link pin
    ///    that disagrees with it is refused, never swapped in.
    /// 2. A dedicated connection probes the relay. Its hash must match the
    ///    expected pin (the link's, else the stored one); with neither, the
    ///    probed hash becomes the pin (trust on first use). No hash, no
    ///    pairing.
    /// 3. That connection is held to the pin, and the registration rides it.
    /// 4. The pin is stored with the pairing, bound to its host.
    private func performPair(
        params: PairingParams,
        deviceToken: String,
        deviceId: String?
    ) async -> RegistrationOutcome {
        guard let srvURL = URL(string: params.srv),
              let host = SecurePairingStore.host(ofServer: params.srv)
        else {
            return .failure(String(localized: "This pairing link's server address could not be read. Nothing was sent."))
        }

        let storedPin: String?
        do {
            storedPin = try securePairingStore.pinnedSpkiHash(forHost: host)
        } catch {
            Log.app.error("Could not read the stored certificate pin before pairing: \(error)")
            return .failure(String(localized: "KyPost couldn't read the certificate pin it holds for this server, so it didn't pair. Unlock this device and try again. Nothing was sent."))
        }
        if let linkPin = params.pin, let storedPin, linkPin != storedPin {
            Log.app.error("Pairing link pin differs from the pin stored for this host; refusing.")
            return .failure(Self.replacesStoredPinMessage(host: host))
        }
        let expectedPin = params.pin ?? storedPin

        let connection = makePairingConnection(host, expectedPin)
        defer { connection.close() }

        guard let observed = await connection.probe(srvURL) else {
            Log.app.error("No certificate could be observed on the pairing handshake; refusing to register.")
            return .failure(String(localized: "KyPost couldn't read this server's security certificate, so it didn't pair. Check the connection and try again. Nothing was sent."))
        }
        if let expectedPin, observed != expectedPin {
            Log.app.error("Relay certificate does not match the expected pin; refusing to register.")
            return .failure(storedPin != nil
                ? Self.storedPinMismatchMessage(host: host)
                : String(localized: "This server's certificate does not match the pairing link. Nothing was sent. Do not pair on this network."))
        }
        connection.pin(observed)

        let outcome = await connection.register(
            deviceToken: deviceToken,
            params: params,
            deviceId: deviceId
        )
        return await storeRegistration(outcome, params: params, deviceId: deviceId, pin: observed)
    }

    static func replacesStoredPinMessage(host: String) -> String {
        String(localized: "This pairing link carries a different certificate pin from the one this device already holds for \(host). If the server's certificate was replaced, remove the pairing in Settings → Connection first, then open the link again. Nothing was sent.")
    }

    static func storedPinMismatchMessage(host: String) -> String {
        String(localized: "\(host) presented a different certificate from the one this device pinned. If the server's certificate was replaced, remove the pairing in Settings → Connection first, then pair again. Otherwise the connection may be intercepted. Nothing was sent.")
    }

    /// Persists a successful registration. `pin` is the pin a pairing held
    /// its connection to; nil for re-registration, which keeps the stored pin
    /// for the same host and never captures one.
    private func storeRegistration(
        _ outcome: RegistrationOutcome,
        params: PairingParams,
        deviceId: String?,
        pin: String?
    ) async -> RegistrationOutcome {
        guard case .success(let response) = outcome else { return outcome }
        // Routine re-registration of the same account (foreground, token
        // refresh) must not restart the heartbeat's quiet clock: it proves
        // the relay answers, not that APNs delivers, and resetting it on
        // every foreground would postpone the heartbeat indefinitely.
        //
        // Pairing another account over this one, without an unpair first,
        // replaces the account. An unreadable previous pairing counts as
        // replaced: erasing a disposable cache is the safe direction.
        let previous = Result { try securePairingStore.loadPairing() }
        let previousPairing = try? previous.get()
        let isSameAccount = previousPairing?.sub == params.sub && previousPairing?.srv == params.srv
        let isRoutineReregistration = isSameAccount && pushSettingsStore.lastRegisteredAt != nil
        // The same account, paired before `lastRegisteredAt` existed.
        let isExistingPairingWithoutStamp = isSameAccount && pushSettingsStore.lastRegisteredAt == nil
        let replacesAccount: Bool = switch previous {
        case .success(let pairing?): pairing.sub != params.sub || pairing.srv != params.srv
        case .success(nil): false
        case .failure: true
        }
        // Stored only once the previous account is gone: a pairing saved
        // over an incomplete teardown would list what was left under the
        // new account. The previous pairing stays, so a retry runs the
        // teardown again.
        if replacesAccount, let onAccountReplaced, !(await onAccountReplaced()) {
            return .failure(String(localized: "Registered, but this device could not erase the previous account's data, so the new pairing was not saved. Try again."))
        }
        do {
            // The pin is written with the pairing, under the same lock, and
            // a pin for another host is dropped there. A pairing that
            // demanded a pin and could not store one is undone rather than
            // left on system trust while reporting success.
            try securePairingStore.savePairing(Pairing(
                sub: params.sub,
                // Every successful register mints a brand-new secret
                // server-side, invalidating whatever was stored before —
                // persist unconditionally, never fall back to the
                // previous value.
                deviceSecret: response.deviceSecret ?? "",
                srv: params.srv,
                registrationUrl: params.reg,
                pairingToken: params.pt,
                lastDeviceId: response.deviceId ?? deviceId,
                pairedAt: Date()
            ), pinnedSpkiHash: pin)
        } catch {
            Log.app.error("Registered but could not save the pairing: \(error)")
            return .failure(pin == nil
                ? String(localized: "Registered but could not save the pairing: \(error.localizedDescription)")
                : String(localized: "Paired, but this device could not store the pairing and the server's certificate pin, so the pairing was undone. Try again."))
        }
        pushSettingsStore.deliveryMode = response.deliveryMode ?? .push
        if !isRoutineReregistration {
            pushSettingsStore.lastRegisteredAt = Date()
        }
        pushSettingsStore.pullEndpoint = response
            .resolvedPullEndpoint(srv: params.srv)?.absoluteString
        // After every write above, so nothing here can interleave with them.
        // Its banners are this pairing's, but the stamp just set says they
        // predate it; record them before any heartbeat can pull them again.
        if isExistingPairingWithoutStamp {
            await reconcileExistingPairingPushes?()
        }
        if pin != nil {
            // A new pairing: screens showing "not paired" load at once
            // instead of waiting for their next timer.
            NotificationCenter.default.post(name: .kyPostPaired, object: nil)
        }
        return outcome
    }
}

extension Notification.Name {
    /// Posted on the main actor after a pairing from a link is stored.
    static let kyPostPaired = Notification.Name("kypost.paired")
}
