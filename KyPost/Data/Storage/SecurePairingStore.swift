//
//  SecurePairingStore.swift
//  KyPost
//
//  Keychain-backed store for relay pairing credentials (spec §1).
//  Keys are a binding contract: sub, deviceSecret, srv, registrationUrl,
//  pairingToken, lastDeviceId, pairedAtTimestamp.
//

import Foundation

/// Credentials produced by a successful native-pair registration.
struct Pairing: Equatable, Sendable {
    var sub: String
    /// Per-device pairing secret, minted once at registration and returned
    /// only in that response — never carried in the pairing deep link/QR.
    /// May be empty for a pairing created before this field existed
    /// (pre-migration); that's not an error, see DeregisterDeviceUseCase.
    var deviceSecret: String
    /// Relay server URL; sourced from pairing, never edited by the user.
    var srv: String
    var registrationUrl: String?
    var pairingToken: String
    var lastDeviceId: String?
    var pairedAt: Date
}

/// Hooks the credential gate installs on SecurePairingStore. While
/// installed, the device secret lives behind user presence instead of in
/// the plain pairing item; nil (the default) is today's ungated behavior.
protocol PairingSecretGate: AnyObject {
    /// Throws MailSourceError.credentialUnavailable while the app is locked.
    func read() throws -> String
    func write(_ secret: String) throws
    /// The pairing is being cleared (unpair) — drop the gated copy too.
    /// Returns the names of anything it could not remove, so a security wipe
    /// can report an incomplete erasure rather than a clean one. An ordinary
    /// unpair discards the result.
    @discardableResult
    func removeAll() -> [String]
}

/// Reached from every background task that talks to the relay (MailRepository,
/// PushRepository, ContactSyncRepository) while `secretGate` is written from
/// the main actor by CredentialGateService. That made an unsynchronised `weak
/// var` racy in a way that is not a torn read but a `swift_weakLoadStrong`
/// race — a crash or a resurrected object, not a stale value. The lock is
/// recursive because `clear()` calls into the gate, whose `removeAll()` unwires
/// itself by assigning `secretGate = nil` back through this same lock.
final class SecurePairingStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    private nonisolated enum Key {
        static let sub = "sub"
        static let deviceSecret = "deviceSecret"
        static let srv = "srv"
        static let registrationUrl = "registrationUrl"
        static let pairingToken = "pairingToken"
        static let lastDeviceId = "lastDeviceId"
        static let pairedAtTimestamp = "pairedAtTimestamp"
        static let pinnedSpkiHash = "pinnedSpkiHash"
        static let all = [
            sub, deviceSecret, srv, registrationUrl, pairingToken,
            lastDeviceId, pairedAtTimestamp, pinnedSpkiHash,
        ]
    }

    /// Keychain accounts the pinned session's nonisolated delegate reads
    /// straight off KeychainStorage (it runs off the main actor).
    nonisolated static let pinnedSpkiHashKey = Key.pinnedSpkiHash
    nonisolated static let srvKey = Key.srv

    private let keychain: KeychainStorage
    private weak var storedSecretGate: (any PairingSecretGate)?
    /// The pairing an account teardown has started erasing
    /// (`retireCurrentPairing`), as (sub, srv, pairedAt). In memory only.
    private var retired: (sub: String, srv: String, pairedAt: Date)?

    /// Set by CredentialGateService while "Require unlock for notifications
    /// & MFA" is on; nil means the plain deviceSecret item is used.
    var secretGate: (any PairingSecretGate)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedSecretGate
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedSecretGate = newValue
        }
    }

    init(keychain: KeychainStorage) {
        self.keychain = keychain
    }

    /// Writes the pairing, or leaves the device unpaired.
    ///
    /// The individual Keychain writes can't be made atomic, so the failure is
    /// resolved instead of left half-applied: `loadPairing` only requires
    /// sub/srv/pairingToken, so a throw between them would otherwise leave a
    /// new subject pointing at the previous server — credentials that look
    /// valid and are silently wrong. Unwinding to "not paired" is the louder,
    /// recoverable outcome, and the caller already surfaces the error
    /// (DeviceRegistrationService.performPair).
    /// Held across the whole multi-key write so a concurrent `loadPairing`
    /// cannot observe a half-written pairing — the exact "new subject pointing
    /// at the previous server" state the unwind below exists to prevent.
    func savePairing(_ pairing: Pairing) throws {
        lock.lock()
        defer { lock.unlock() }
        retired = nil
        do {
            try writePairing(pairing)
        } catch {
            try? clear()
            throw error
        }
    }

    private func writePairing(_ pairing: Pairing) throws {
        try keychain.set(pairing.sub, forKey: Key.sub)
        // Re-registration mints a fresh secret on every success; while the
        // gate is on it must land behind user presence, never in the plain
        // item.
        if let secretGate {
            try secretGate.write(pairing.deviceSecret)
            try keychain.set("", forKey: Key.deviceSecret)
        } else {
            try keychain.set(pairing.deviceSecret, forKey: Key.deviceSecret)
        }
        try keychain.set(pairing.srv, forKey: Key.srv)
        try keychain.set(pairing.pairingToken, forKey: Key.pairingToken)
        try keychain.set(
            String(pairing.pairedAt.timeIntervalSince1970),
            forKey: Key.pairedAtTimestamp
        )
        if let registrationUrl = pairing.registrationUrl {
            try keychain.set(registrationUrl, forKey: Key.registrationUrl)
        } else {
            try keychain.remove(Key.registrationUrl)
        }
        if let lastDeviceId = pairing.lastDeviceId {
            try keychain.set(lastDeviceId, forKey: Key.lastDeviceId)
        } else {
            try keychain.remove(Key.lastDeviceId)
        }
    }

    /// Returns nil unless all required fields (sub, srv, pairingToken) are
    /// present. deviceSecret is deliberately NOT required: a pairing saved
    /// before that field existed must still load as "paired" (with an empty
    /// secret) rather than silently reading as unpaired.
    func loadPairing() throws -> Pairing? {
        lock.lock()
        defer { lock.unlock() }
        guard
            let sub = try keychain.string(forKey: Key.sub), !sub.isEmpty,
            let srv = try keychain.string(forKey: Key.srv), !srv.isEmpty,
            let pairingToken = try keychain.string(forKey: Key.pairingToken), !pairingToken.isEmpty
        else { return nil }

        let pairedAt = try keychain.string(forKey: Key.pairedAtTimestamp)
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:)) ?? .distantPast

        let deviceSecret: String
        if let secretGate {
            deviceSecret = try secretGate.read()
        } else {
            deviceSecret = try keychain.string(forKey: Key.deviceSecret) ?? ""
        }

        return Pairing(
            sub: sub,
            deviceSecret: deviceSecret,
            srv: srv,
            registrationUrl: try keychain.string(forKey: Key.registrationUrl),
            pairingToken: pairingToken,
            lastDeviceId: try keychain.string(forKey: Key.lastDeviceId),
            pairedAt: pairedAt
        )
    }

    /// Marks the stored pairing as torn down: `loadActivePairing` refuses it
    /// until another pairing is saved. A pairing to another account stores
    /// the new pairing only after the whole teardown has run, so the old one
    /// stays readable meanwhile; work that reaches the relay with it would
    /// fetch the old account's data after the step that erased it. Every
    /// teardown step that bumps its own session or epoch calls this first, so
    /// work that starts under the new session cannot load the old pairing.
    func retireCurrentPairing() {
        lock.lock()
        defer { lock.unlock() }
        // The identifying fields only: the device secret may be behind the
        // credential gate, and a pairing whose secret is unreadable is still
        // the one being left.
        guard let sub = try? keychain.string(forKey: Key.sub), !sub.isEmpty,
              let srv = try? keychain.string(forKey: Key.srv), !srv.isEmpty
        else { return }
        retired = (sub, srv, storedPairedAt())
    }

    private func storedPairedAt() -> Date {
        (try? keychain.string(forKey: Key.pairedAtTimestamp))
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:)) ?? .distantPast
    }

    /// The stored pairing, or nil when there is none or it has been retired.
    /// For work that reaches the relay on the account's behalf (mail,
    /// notification pulls, re-registration).
    func loadActivePairing() throws -> Pairing? {
        lock.lock()
        defer { lock.unlock() }
        guard let pairing = try loadPairing() else { return nil }
        if let retired, retired.sub == pairing.sub, retired.srv == pairing.srv,
           retired.pairedAt == pairing.pairedAt {
            return nil
        }
        return pairing
    }

    var isPaired: Bool {
        (try? loadPairing()) != nil
    }

    /// Restores a plain-item secret (credential gate turning off).
    func setDeviceSecret(_ secret: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try keychain.set(secret, forKey: Key.deviceSecret)
    }

    /// The relay's leaf SPKI SHA-256, captured at pairing (TOFU pinning).
    /// Cleared with the pairing, so "clear pairing and re-pair" is the
    /// recovery path for a legitimate certificate rotation.
    var pinnedSpkiHash: String? {
        try? keychain.string(forKey: Key.pinnedSpkiHash)
    }

    func setPinnedSpkiHash(_ hash: String?) throws {
        if let hash {
            try keychain.set(hash, forKey: Key.pinnedSpkiHash)
        } else {
            try keychain.remove(Key.pinnedSpkiHash)
        }
    }

    /// Unpair. Every key gets its own attempt: stopping at the first failure
    /// would leave the device secret, pairing token, and pin behind on a
    /// device the user just unpaired — `deviceSecret` is only the second entry
    /// in `Key.all`. The first error still propagates, so a partial wipe is
    /// reported rather than passing for success.
    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        secretGate?.removeAll()
        var firstError: Error?
        for key in Key.all {
            do {
                try keychain.remove(key)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }
}
