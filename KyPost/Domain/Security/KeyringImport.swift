//
//  KeyringImport.swift
//  KyPost
//
//  What an opened envelope becomes on this device: the record to seal, the
//  material to hold, and what to acknowledge. Counterpart of kypost-android's
//  pgp/KeyringImport.kt and the merge half of pgp/EnrollmentCeremony.kt.
//
//  Pure — no Keychain, no network, no library import — so every row of the
//  decision is a plain unit test. The caller stores, then installs, then
//  reports, in that order, and only on `.store` / `.replay`.
//

import Foundation

/// What the server recorded when it delivered the envelope
/// (`GET /api/pgp/device/envelope`). The ring that opens must match it.
nonisolated struct DeliveryMetadata: Equatable, Sendable {
    var version: Int
    var fingerprint: String
    /// Zero or absent on a legacy account.
    var materialGeneration: UInt64?
    var primaryFingerprints: [String]?
    var keyFingerprints: [String]?
}

/// What this device tells `POST /api/pgp/device/enrollment-state` it holds.
nonisolated enum EnrollmentReport: Equatable, Sendable {
    /// Makes the server forget its delivery record for this device. Sent only
    /// on a proven loss — a deliberate teardown — never on a probe that merely
    /// found nothing, which is also what a device awaiting delivery looks like.
    case notEnrolled
    /// The bare boolean, meaning "opens a v2 envelope". A converted account
    /// refuses it.
    case legacy
    /// Confirms the keyring delivery (v3 or v5) the server recorded for this
    /// device, and nothing else.
    case keyring(materialGeneration: UInt64, fingerprint: String, envelopeVersion: Int)
}

nonisolated enum VaultImportDecision: Equatable, Sendable {
    /// Seal `record`; once it is durable, hold `install` and acknowledge `report`.
    case store(VaultRecord, install: VaultMaterial, report: EnrollmentReport)
    /// The identical ring is already sealed on disk: nothing is rewritten.
    case replay(install: VaultMaterial, report: EnrollmentReport)
    /// Not a complete ring naming the committed key, or not the ring the
    /// server says it delivered. Nothing is touched.
    case invalidRing
    /// Replacing what is sealed here would lose key material the device
    /// already holds, or cannot be compared with it. The previous record is
    /// kept and this one dropped.
    case refusedIncomparable
    /// The legacy merge could not be built. The previous record is kept.
    case mergeFailed
}

/// The keyring values a v3/v5 delivery of `version` must carry, or false
/// when the server's record cannot be validated against — in which case the
/// envelope is not opened at all.
nonisolated func keyringDeliveryIsUsable(
    _ delivery: DeliveryMetadata?,
    version: Int,
    identityFingerprint: String
) -> Bool {
    guard let delivery, envelopeCarriesKeyring(version), delivery.version == version,
          let generation = delivery.materialGeneration, generation > 0,
          delivery.primaryFingerprints != nil, delivery.keyFingerprints != nil
    else { return false }
    return normalisedFingerprint(delivery.fingerprint) == normalisedFingerprint(identityFingerprint)
}

/// Decides what an authenticated envelope plaintext becomes.
///
/// **History is never overwritten.** A legacy envelope is merged with the
/// legacy collection already sealed here, current key first, so mail
/// encrypted to a retired key still opens after re-enrollment (Android
/// 8fcbc299 / 67f7dc22). A keyring carries its own history, so it replaces a
/// previous record only when its inventory contains every key the previous
/// record held; otherwise the previous record is kept.
///
/// That replacement rule is the one place this port is deliberately more
/// permissive than Android, which refuses every replacement that is not the
/// identical bytes (`RefusedIncomparable`) pending a server contract for
/// conversion and retirement. A strict superset at a newer generation loses
/// no decryption capability, which is the property both rules protect; it is
/// what lets a device enrolled before the account was converted, or before a
/// rotation, enrol again at all.
nonisolated func decideVaultImport(
    version: Int,
    plaintext: Data,
    identityFingerprint: String,
    delivery: DeliveryMetadata?,
    previous: VaultRecord?,
    inspector: any PgpKeyInspecting
) -> VaultImportDecision {
    let fingerprint = normalisedFingerprint(identityFingerprint)

    guard envelopeCarriesKeyring(version) else {
        return decideLegacy(
            plaintext: plaintext,
            fingerprint: fingerprint,
            previous: previous,
            inspector: inspector
        )
    }

    guard keyringDeliveryIsUsable(delivery, version: version, identityFingerprint: fingerprint),
          let delivery,
          let ring = parsePgpKeyring(
              plaintext,
              expectedActiveFingerprint: fingerprint,
              inspector: inspector
          ),
          ring.materialGeneration == delivery.materialGeneration,
          ring.primaryFingerprints == Set((delivery.primaryFingerprints ?? []).map(normalisedFingerprint)),
          ring.keyFingerprints == Set((delivery.keyFingerprints ?? []).map(normalisedFingerprint))
    else { return .invalidRing }

    let report = EnrollmentReport.keyring(
        materialGeneration: ring.materialGeneration,
        fingerprint: ring.activeFingerprint,
        envelopeVersion: version
    )
    let record = VaultRecord(
        kind: .keyring,
        material: ring.original,
        identityFingerprint: ring.activeFingerprint,
        materialGeneration: ring.materialGeneration,
        envelopeVersion: version
    )

    switch previous?.kind {
    case nil:
        return .store(record, install: .keyring(ring), report: report)

    case .keyring?:
        guard let previous else { return .refusedIncomparable }
        // Durable already: nothing to write, and completion is idempotent.
        // A redelivery under the other version rewrites, so a restated
        // acknowledgement names the version the server now holds.
        if previous.material == ring.original {
            guard (previous.envelopeVersion ?? envelopeVersionKeyring) == version else {
                return .store(record, install: .keyring(ring), report: report)
            }
            return .replay(install: .keyring(ring), report: report)
        }
        guard let held = reopenPgpKeyring(previous.material, inspector: inspector),
              ring.materialGeneration > held.materialGeneration,
              ring.keyFingerprints.isSuperset(of: held.keyFingerprints)
        else { return .refusedIncomparable }
        return .store(record, install: .keyring(ring), report: report)

    case .legacyArmor?:
        // Conversion: the ring must already hold every key the legacy vault
        // could decrypt with, or the conversion would forget one.
        guard let previous,
              let inventories = inspector.legacyInventories(armored: previous.material),
              ring.keyFingerprints.isSuperset(of: inventories.flatMap(\.keyFingerprints))
        else { return .refusedIncomparable }
        return .store(record, install: .keyring(ring), report: report)
    }
}

private nonisolated func decideLegacy(
    plaintext: Data,
    fingerprint: String,
    previous: VaultRecord?,
    inspector: any PgpKeyInspecting
) -> VaultImportDecision {
    let material: Data
    switch previous?.kind {
    case nil:
        material = plaintext
    case .legacyArmor?:
        guard let previous,
              let merged = inspector.mergeLegacy(current: plaintext, previous: previous.material)
        else { return .mergeFailed }
        material = merged
    case .keyring?:
        // A converted account's ring cannot be replaced by one armored key;
        // the server sends v2 only to legacy accounts, so this is stale.
        return .refusedIncomparable
    }
    let record = VaultRecord(kind: .legacyArmor, material: material, identityFingerprint: fingerprint)
    return .store(record, install: .legacyArmor(material), report: .legacy)
}

nonisolated func normalisedFingerprint(_ text: String) -> String {
    text.uppercased().filter { !$0.isWhitespace }
}
