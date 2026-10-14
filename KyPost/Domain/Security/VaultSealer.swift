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
        _ = try vault.ensureDeviceKey()
        return try vault.rawPublicKey()
    }

    /// Unseals and stores, or throws.
    ///
    /// The ECDH step is where user presence is demanded: the private key is
    /// created with `.userPresence`, so `SecKeyCopyKeyExchangeResult` raises
    /// the system prompt. A cancelled prompt is surfaced as
    /// `EnrollmentVaultError.cancelled` and is **not** an error — the user
    /// dismissed something they raised.
    func openAndStore(
        envelopeJSON: String,
        identityFingerprint: String,
        delivery: DeliveryMetadata?
    ) async throws -> EnrollmentReport {
        guard let fields = parseDeviceEnvelope(envelopeJSON) else {
            throw EnrollmentSealerError.envelopeMalformed
        }
        // A v3 envelope is validated against the delivery the server recorded.
        // Without that record there is nothing to validate the ring against,
        // so it is not opened at all.
        if fields.version == envelopeVersionKeyring,
           !keyringDeliveryIsUsable(delivery, identityFingerprint: identityFingerprint) {
            throw EnrollmentSealerError.envelopeMalformed
        }
        // The AAD comes from this device's id and the checked fingerprint —
        // never from the envelope — under the domain the envelope declared.
        let aad: Data
        do {
            aad = try deviceEnvelopeAAD(
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
        guard let ephemeral = SecKeyCreateWithData(
            fields.epk as CFData,
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                kSecAttrKeySizeInBits as String: 256,
            ] as CFDictionary,
            nil
        ) else {
            throw EnrollmentSealerError.envelopeMalformed
        }

        var error: Unmanaged<CFError>?
        guard let secretData = SecKeyCopyKeyExchangeResult(
            privateKey,
            .ecdhKeyExchangeStandard,
            ephemeral,
            [:] as CFDictionary,
            &error
        ) as Data? else {
            if lease.wasHeld { vault.presence.discard(lease) }
            if vaultError(from: error?.takeRetainedValue()) == .cancelled {
                throw EnrollmentVaultError.cancelled
            }
            // A key-exchange failure that is *not* a cancellation says nothing
            // about the envelope, so it must not be reported as one. Reporting
            // it as "hostile or stale" would tell the user their key was
            // substituted because their Secure Enclave was busy.
            throw EnrollmentVaultError.unavailable
        }
        // The app locked during the key exchange: stop before anything is
        // stored or held.
        guard vault.presence.keep(lease) else { throw EnrollmentVaultError.cancelled }

        // CryptoKit's HKDF wants a SharedSecret, which only its own key
        // agreement produces; the Secure Enclave path hands back raw bytes, so
        // the derivation is done directly here against the same inputs.
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secretData),
            salt: try vault.rawPublicKey(),
            info: Data(envelopeDomain(version: fields.version).utf8),
            outputByteCount: 32
        )
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: fields.iv),
            ciphertext: fields.ct.dropLast(16),
            tag: fields.ct.suffix(16)
        ), var plaintext = try? AES.GCM.open(box, using: derived, authenticating: aad) else {
            // Hostile or stale, never a retry: the AAD binds the sealing to
            // this device and this identity.
            throw EnrollmentSealerError.envelopeRejected
        }
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
