//
//  VaultSealer.swift
//  KyPost
//
//  Opens a sealed envelope with the device key and stores the result.
//  Counterpart of kypost-android's pgp/VaultOpenerAndroid.kt.
//

import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The `EnrollmentSealer` the ceremony actually runs against.
///
/// Kept apart from `EnrollmentVault` so the ceremony depends on a protocol
/// rather than on the Keychain and LocalAuthentication: that is what lets the
/// whole exit table be a unit test.
struct VaultSealer: EnrollmentSealer {
    private let vault: EnrollmentVault
    private let deviceId: String
    private let inspector: any PgpKeyInspecting
    private let session: EnrollmentSession

    init(
        vault: EnrollmentVault,
        deviceId: String,
        inspector: any PgpKeyInspecting,
        session: EnrollmentSession = .shared
    ) {
        self.vault = vault
        self.deviceId = deviceId
        self.inspector = inspector
        self.session = session
    }

    func deviceRawPublicKey() throws -> Data {
        try vault.ensureDeviceKey()
        return try vault.rawPublicKey()
    }

    /// Unseals and stores, or throws.
    ///
    /// The HPKE decapsulation is where user presence is demanded: the
    /// private key is created with `.userPresence`, so the Secure Enclave
    /// operation raises the system prompt. A cancelled prompt is surfaced as
    /// `EnrollmentVaultError.cancelled` and is **not** an error — the user
    /// dismissed something they raised.
    func openAndStore(
        envelopeJSON: String,
        identityFingerprint: String,
        delivery: DeliveryMetadata?
    ) async throws -> EnrollmentReport {
        // HPKE (v4/v5) only, opened only as the version the server recorded
        // delivering. A v2/v3 delivery, or a server too old to record one, is
        // refused before the envelope is parsed.
        guard let delivery, envelopeIsHPKE(delivery.version) else {
            throw EnrollmentSealerError.unsupportedEnvelopeVersion
        }
        guard let fields = parseDeviceEnvelope(envelopeJSON), fields.version == delivery.version else {
            throw EnrollmentSealerError.envelopeMalformed
        }
        // A v5 ring is validated against the delivery the server recorded.
        // Without the full record there is nothing to validate it against,
        // so it is not opened at all.
        if envelopeCarriesKeyring(fields.version),
           !keyringDeliveryIsUsable(delivery, version: fields.version, identityFingerprint: identityFingerprint) {
            throw EnrollmentSealerError.envelopeMalformed
        }
        // The info comes from this device's id and the checked fingerprint —
        // never from the envelope — under the domain the envelope declared.
        let info: Data
        do {
            info = try deviceEnvelopeAAD(
                version: fields.version,
                deviceId: deviceId,
                pgpFingerprint: identityFingerprint
            )
        } catch {
            throw EnrollmentSealerError.envelopeMalformed
        }

        // Under the shared presence context: the prompt this raises also
        // covers reading the previous record in `importOpened`, and the
        // reader's next open until the app locks.
        let lease = vault.presence.lease(reason: EnrollmentVault.presenceReason)
        let privateKey = try vault.deviceKey(context: lease.context)
        let opened: Data?
        do {
            opened = try openDeviceEnvelope(with: privateKey, fields: fields, info: info)
        } catch {
            if lease.wasHeld { vault.presence.discard(lease) }
            if deviceKeyError(error) == .cancelled {
                throw EnrollmentVaultError.cancelled
            }
            // A key-agreement failure that is *not* a cancellation says nothing
            // about the envelope, so it must not be reported as one. Reporting
            // it as "hostile or stale" would tell the user their key was
            // substituted because their Secure Enclave was busy.
            throw EnrollmentVaultError.unavailable
        }
        // The app locked during the key agreement: stop before anything is
        // stored or held.
        guard vault.presence.keep(lease) else { throw EnrollmentVaultError.cancelled }
        // Hostile or stale, never a retry: the info binds the sealing to this
        // device and this identity.
        guard var plaintext = opened else { throw EnrollmentSealerError.envelopeRejected }
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }

        return try importOpened(
            version: fields.version,
            plaintext: plaintext,
            identityFingerprint: identityFingerprint,
            delivery: delivery
        )
    }

    /// Authenticated plaintext → durable record → held session, in that
    /// order. Every exit before the store leaves the previous record and
    /// session exactly as they were; nothing is held or acknowledged for a
    /// record that is not on disk.
    func importOpened(
        version: Int,
        plaintext: Data,
        identityFingerprint: String,
        delivery: DeliveryMetadata?
    ) throws -> EnrollmentReport {
        // Read without trusting a held session: teardown removes the record
        // without clearing the session, so only the disk says what is sealed.
        // A record that will not read is never sealed over. Opening it is a
        // presence-checked step, covered by the key exchange's prompt.
        let previous = try vault.openRecord()
        switch decideVaultImport(
            version: version,
            plaintext: plaintext,
            identityFingerprint: identityFingerprint,
            delivery: delivery,
            previous: previous,
            inspector: inspector
        ) {
        case .store(var record, let install, let report):
            defer { record.material.resetBytes(in: 0..<record.material.count) }
            try vault.store(record)
            session.install(install)
            return report
        case .replay(let install, let report):
            session.install(install)
            return report
        case .invalidRing, .refusedIncomparable:
            throw EnrollmentSealerError.keyringRejected
        case .mergeFailed:
            throw EnrollmentSealerError.mergeFailed
        }
    }
}
