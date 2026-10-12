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
            // this host, and synthesising one here would let a stored value
            // re-arm itself forever.
            pin: nil
        )
    }
}

/// `@MainActor` because `inFlight` and `observedSpkiHash` are unsynchronised
/// mutable state and every caller (PushPairingViewModel, the `@MainActor`
/// PushLifecycle) already runs here. Under Swift 5 language mode the compiler
/// says nothing about that, so the isolation is stated rather than assumed.
@MainActor
final class DeviceRegistrationService {
    private let client: NativeRegistrationClient
    private let securePairingStore: SecurePairingStore
    private let pushSettingsStore: PushSettingsStore
    /// TOFU pinning capture: the SPKI hash the transport saw on its latest
    /// handshake with the given host. Wired by SingletonGraph to the pinned
    /// session's delegate; nil in tests (no pin is recorded).
    var observedSpkiHash: ((_ host: String) -> String?)?
    /// Forces a fresh handshake when `observedSpkiHash` has nothing, because
    /// the registration rode a pooled or resumed connection and no challenge
    /// ever fired. Wired by SingletonGraph; nil in tests.
    var probeSpkiHash: ((_ url: URL) async -> String?)?
    /// Arms a link-supplied pin on the transport for the duration of a
    /// pairing attempt, and clears it afterwards (nil pin). Wired by
    /// SingletonGraph to the pinned session's delegate; nil in tests.
    var setPendingPin: ((_ pin: String?, _ host: String) -> Void)?
    /// Records the banners an existing pairing already delivered into
    /// history, ignoring `lastRegisteredAt`. Run when a pairing that predates
    /// that stamp registers for the first time and so gets it set to now.
    /// Wired by SingletonGraph to `PullPollingScheduler`; nil in tests that
    /// do not exercise it.
    var reconcileExistingPairingPushes: (() async -> Void)?

    /// Runs before a registration's pairing is stored over one for another
    /// account (another `sub` or server), so the previous account's
    /// account-scoped state is erased as an unpair would. Wired by
    /// SingletonGraph to clear cached mail; nil in tests.
    var onAccountReplaced: (@MainActor () async -> Void)?

    /// One registration per (pairing token, device token). A pairing deep
    /// link is delivered to every open main window and each auto-pairs, so
    /// without this guard a single "Pair Desktop App" click registers the
    /// same computer several times (the server appends a device row per
    /// register call). Unlike desktop pairing codes these are not single-use,
    /// so only concurrent calls are shared — a later call with a new device
    /// token (APNs refresh) must still go through.
    private var inFlight: [String: Task<RegistrationOutcome, Never>] = [:]

    init(
        client: NativeRegistrationClient,
        securePairingStore: SecurePairingStore,
        pushSettingsStore: PushSettingsStore
    ) {
        self.client = client
        self.securePairingStore = securePairingStore
        self.pushSettingsStore = pushSettingsStore
    }

    /// Initial pairing (QR scan / deep link). Persists the pairing and
    /// delivery settings only if registration succeeds (spec §1 flow).
    /// Concurrent calls with the same tokens share one registration.
    func pair(
        params: PairingParams,
        deviceToken: String,
        deviceId: String? = nil
    ) async -> RegistrationOutcome {
        let key = "\(params.pt)|\(deviceToken)"
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task {
            await performPair(params: params, deviceToken: deviceToken, deviceId: deviceId)
        }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        return outcome
    }

    private func performPair(
        params: PairingParams,
        deviceToken: String,
        deviceId: String?
    ) async -> RegistrationOutcome {
        // Arm BEFORE the POST, not after it. This request carries the
        // pairing token and the push endpoint up and brings the device
        // secret back down, so a pin applied once the response has landed
        // has already missed everything it was meant to protect.
        let srvURL = URL(string: params.srv)
        let srvHost = srvURL?.host()
        if let linkPin = params.pin {
            // A pin we cannot bind to a host is a pin we cannot enforce. The
            // link asked for pinning, so refuse rather than quietly pairing
            // without it.
            guard let srvURL, let srvHost else {
                return .failure("This pairing link's server address could not be read, so its certificate pin could not be applied.")
            }
            setPendingPin?(linkPin, srvHost)

            // Arming is not enforcement. The delegate's server-trust callback
            // fires once per CONNECTION, so a registration riding a pooled or
            // resumed connection is never compared against the pin — the same
            // fail-open-on-arming hazard `probeSpkiHash` already exists to
            // close on the TOFU path below. Force a handshake here, while the
            // pin is armed, and check what it presented BEFORE any credential
            // is sent. A refused or unobtainable handshake yields nil.
            let observed = await probeSpkiHash?(srvURL)
            guard let observed, observed == linkPin else {
                setPendingPin?(nil, srvHost)
                Log.app.error("Relay certificate does not match the pin in the pairing link; refusing to register.")
                return .failure("This server's certificate does not match the pairing link. Nothing was sent. Do not pair on this network.")
            }
        }
        defer {
            if params.pin != nil, let srvHost {
                setPendingPin?(nil, srvHost)
            }
        }

        let outcome = await client.register(
            deviceToken: deviceToken,
            params: params,
            deviceId: deviceId
        )
        // The same account, paired before `lastRegisteredAt` existed.
        var isExistingPairingWithoutStamp = false
        if case .success(let response) = outcome {
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
            isExistingPairingWithoutStamp = isSameAccount && pushSettingsStore.lastRegisteredAt == nil
            let replacesAccount: Bool = switch previous {
            case .success(let pairing?): pairing.sub != params.sub || pairing.srv != params.srv
            case .success(nil): false
            case .failure: true
            }
            if replacesAccount {
                await onAccountReplaced?()
            }
            do {
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
                ))
            } catch {
                return .failure("Registered but could not save pairing: \(error)")
            }
            pushSettingsStore.deliveryMode = response.deliveryMode ?? .push
            if !isRoutineReregistration {
                pushSettingsStore.lastRegisteredAt = Date()
            }
            pushSettingsStore.pullEndpoint = response
                .resolvedPullEndpoint(srv: params.srv)?.absoluteString
            // Trust on FIRST use: pin the key this handshake presented only
            // when nothing is pinned yet. `performPair` also runs for every
            // re-registration (foreground, APNs token refresh), so pinning
            // unconditionally here would be trust-on-every-use — it would
            // quietly adopt whatever key was last seen, turning a single
            // interception into a permanent pin for the attacker's key and
            // locking out the real relay. Clearing the pairing is the only
            // way to re-pin, which is the documented rotation recovery.
            // Best effort: a Keychain hiccup must not fail a good registration.
            // Empty counts as unpinned, matching the delegate's own lookup.
            if let linkPin = params.pin {
                // Reached only after the probe above observed this exact key
                // on a live handshake, so persisting it records something that
                // was checked rather than something that was hoped for. That
                // ordering is also what makes overwriting an existing pin safe
                // — a mangled or hostile link cannot install a pin the relay
                // does not actually present, which would otherwise lock the
                // device out of the real relay until it was unpaired. It is
                // how a certificate renewal recovers: re-scan, and the new pin
                // replaces the old.
                //
                // NOT `try?`. A pairing that demanded a pin and then failed to
                // store one leaves every later request on system trust while
                // reporting success — the TOFU branch below at least logs that
                // case, and this one is stricter because the link was explicit.
                do {
                    try securePairingStore.setPinnedSpkiHash(linkPin)
                } catch {
                    Log.app.error("Paired but could not store the certificate pin: \(error)")
                    try? securePairingStore.clear()
                    return .failure("Paired, but this device could not store the server's certificate pin, so the pairing was undone. Try again.")
                }
            } else if (securePairingStore.pinnedSpkiHash ?? "").isEmpty,
               let srvURL, let host = srvHost {
                // `observedSpkiHash` only has a value when this registration
                // happened to open a new TLS connection. Connection reuse and
                // session resumption skip the challenge entirely, which used to
                // leave the pin permanently unarmed with nothing logged and
                // `.success` returned — arming failed open while the docs said
                // pinning was always on. The probe removes the coincidence.
                var hash = observedSpkiHash?(host)
                if hash == nil {
                    hash = await probeSpkiHash?(srvURL)
                }
                if let hash {
                    try? securePairingStore.setPinnedSpkiHash(hash)
                } else {
                    Log.app.error(
                        "Could not record a certificate pin for the relay; this connection falls back to system trust. Settings → Security reports it as Not pinned."
                    )
                }
            }
        }
        // After every write above, so nothing here can interleave with them.
        // Its banners are this pairing's, but the stamp just set says they
        // predate it; record them before any heartbeat can pull them again.
        if isExistingPairingWithoutStamp {
            await reconcileExistingPairingPushes?()
        }
        return outcome
    }

    /// Re-registration for safety (token refresh, app foreground, spec §3).
    /// Sends the stored deviceId so the server updates the existing device
    /// row rather than pairing this computer a second time.
    /// Returns nil when the device was never paired — nothing to refresh.
    @discardableResult
    func reregisterIfPaired(deviceToken: String) async -> RegistrationOutcome? {
        guard let pairing = try? securePairingStore.loadPairing() else { return nil }
        return await pair(
            params: PairingParams(pairing: pairing),
            deviceToken: deviceToken,
            deviceId: pairing.lastDeviceId
        )
    }
}
