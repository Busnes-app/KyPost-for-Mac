//
//  EnrollmentVault.swift
//  KyPost
//
//  The durable half of device enrollment: a Secure Enclave P-256 key that
//  requires user presence, and the account's sealed private key re-sealed
//  under it. Swift port of kypost-android's pgp/EnrollmentVault.kt.
//

import CryptoKit
import Foundation
import LocalAuthentication
import os

/// The Keychain operations the vault needs, so a test can inject a store that
/// fails on write and prove the previous record survives.
nonisolated protocol SecureItemStoring: Sendable {
    func setData(_ data: Data, forKey key: String) throws
    func data(forKey key: String) throws -> Data?
    func remove(_ key: String) throws
}

extension KeychainStorage: SecureItemStoring {}

/// What a sealed record's plaintext is. Carried in the record itself, so
/// nothing ever inspects plaintext to decide how to read it.
nonisolated enum VaultRecordKind: UInt8, Equatable, Sendable {
    /// One armored key, or a current-first collection of current and retired keys.
    case legacyArmor = 1
    /// The original `kypost-pgp-keyring-v1` bytes, validated before sealing.
    case keyring = 2
}

/// The keyring acknowledgement values, stored beside the material because the
/// launch-time report needs them without the key. Public data: the server
/// lists both on the owner's device page.
nonisolated struct KeyringAcknowledgement: Equatable, Sendable {
    var materialGeneration: UInt64
    var fingerprint: String
}

/// One sealed record, written as **one** Keychain item.
///
/// One item is what makes replacement atomic: `SecItemUpdate` on a single
/// item either lands or leaves the old bytes, so a failed write can never
/// leave new material beside an old fingerprint, or a keyring under a legacy
/// kind. The earlier layout stored the key and its fingerprint as two items
/// written one after the other.
nonisolated struct VaultRecord: Equatable, Sendable, CustomStringConvertible {
    var kind: VaultRecordKind
    var material: Data
    var identityFingerprint: String
    /// The keyring's generation; nil for legacy armor.
    var materialGeneration: UInt64?

    var description: String { "VaultRecord(\(kind), redacted)" }

    var acknowledgement: KeyringAcknowledgement? {
        guard kind == .keyring, let materialGeneration else { return nil }
        return KeyringAcknowledgement(
            materialGeneration: materialGeneration,
            fingerprint: identityFingerprint
        )
    }

    private static let magic = Data("KPVR".utf8)
    private static let format: UInt8 = 1

    /// `magic || format || kind || uint64BE(generation) || uint16BE(len fp) || fp || material`
    func encoded() -> Data {
        var data = Self.magic
        data.append(Self.format)
        data.append(kind.rawValue)
        let generation = materialGeneration ?? 0
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: generation >> UInt64(shift)))
        }
        let fingerprint = Data(identityFingerprint.utf8)
        data.append(bigEndianUInt16(fingerprint.count))
        data.append(fingerprint)
        data.append(material)
        return data
    }

    static func decode(_ data: Data) -> VaultRecord? {
        let bytes = [UInt8](data)
        let header = magic.count + 2 + 8 + 2
        guard bytes.count > header,
              Data(bytes[0..<magic.count]) == magic,
              bytes[magic.count] == format,
              let kind = VaultRecordKind(rawValue: bytes[magic.count + 1])
        else { return nil }
        var index = magic.count + 2
        let generation = bytes[index..<(index + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        index += 8
        let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        index += 2
        guard index + length < bytes.count,
              let fingerprint = String(bytes: bytes[index..<(index + length)], encoding: .utf8)
        else { return nil }
        index += length
        if kind == .keyring, generation == 0 { return nil }
        return VaultRecord(
            kind: kind,
            material: Data(bytes[index...]),
            identityFingerprint: fingerprint,
            materialGeneration: kind == .keyring ? generation : nil
        )
    }
}

nonisolated enum EnrollmentVaultError: Error, Equatable {
    /// No passcode, Touch ID or Face ID is set. The envelope's protection *is*
    /// the lock screen, so a device without one cannot hold a meaningful one.
    /// The honest outcome, not a degradation.
    case noDeviceCredential
    /// The Secure Enclave refused. On a Mac without one this is terminal.
    case unavailable
    case keychain(OSStatus)
    case notEnrolled
    /// The user dismissed the authentication prompt. Not an error — the caller
    /// goes back to offering the action.
    case cancelled
    /// A record exists and does not decode. Never overwritten blind.
    case unreadableRecord
}

/// Holds the device keypair and the re-sealed envelope.
///
/// **The allowed authenticators include the device passcode on purpose**, so
/// the key survives a biometric enrollment change. Biometry-only would
/// invalidate it whenever a face or fingerprint is added, costing every
/// ordinary user a full re-enrollment ceremony — and enrolling a biometric
/// already requires the passcode, so the attacker it would exclude already
/// holds what this key accepts. It also stops the enrollment marker flapping
/// false for benign reasons: a marker that cries wolf is one users learn to
/// dismiss.
///
/// The strict posture is not a switch here. It is Hostile Location Protection,
/// under which there is no envelope at all.
nonisolated final class EnrollmentVault: @unchecked Sendable {
    private let keyTag: Data
    private let keychain: any SecureItemStoring
    private let lock = NSLock()

    /// Separate from the pairing store's service so a device unpair does not
    /// silently take the enrollment with it, and vice versa.
    static let defaultKeyTag = "org.kysecurity.mail.enrollment.deviceKey"

    init(keychain: any SecureItemStoring, keyTag: String = EnrollmentVault.defaultKeyTag) {
        self.keychain = keychain
        self.keyTag = Data(keyTag.utf8)
    }

    private enum Key {
        /// The current layout: one `VaultRecord`.
        static let record = "enrollment.vaultRecord"
        /// The earlier two-item layout, still read so an existing enrollment
        /// survives the upgrade; retired once a record replaces it.
        static let envelope = "enrollment.sealedEnvelope"
        static let fingerprint = "enrollment.identityFingerprint"
        /// Left by a deliberate teardown while still paired; the one signal
        /// that lets the launch-time report tell the server "not enrolled".
        static let teardownReport = "enrollment.teardownReportPending"
        /// A direct acknowledgement that failed transiently:
        /// `"<attempts>:<revision>"`.
        static let reportPending = "enrollment.reportPendingAttempts"
    }

    // MARK: - Device key

    /// True when a device credential exists at all. Checked before generating,
    /// because a key created without one carries no protection worth the name.
    var hasDeviceCredential: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Creates the device keypair, or returns the existing one.
    ///
    /// **An existing key is adopted only if it still carries the properties
    /// this design rests on.** Presence alone was Android's test, which meant a
    /// key generated by an earlier build — with different, possibly weaker
    /// parameters — was reused forever with no signal. That was never remotely
    /// exploitable, since the keychain is per-app; the reason it matters is
    /// that the design plans exactly the migration it silently breaks.
    func ensureDeviceKey() throws -> SecKey {
        lock.lock()
        defer { lock.unlock() }
        if let existing = try loadDeviceKeyLocked() { return existing }
        guard hasDeviceCredential else { throw EnrollmentVaultError.noDeviceCredential }
        return try generateDeviceKeyLocked()
    }

    func deviceKey() throws -> SecKey {
        lock.lock()
        defer { lock.unlock() }
        guard let key = try loadDeviceKeyLocked() else { throw EnrollmentVaultError.notEnrolled }
        return key
    }

    /// The raw 65-byte SEC1 point, for the enrollment code and the HKDF salt.
    func rawPublicKey() throws -> Data {
        let key = try deviceKey()
        guard let publicKey = SecKeyCopyPublicKey(key),
              let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { throw EnrollmentVaultError.unavailable }
        return data
    }

    private func loadDeviceKeyLocked() throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let key = item else { return nil }
            // swiftlint:disable:next force_cast
            return (key as! SecKey)
        case errSecItemNotFound:
            return nil
        default:
            throw EnrollmentVaultError.keychain(status)
        }
    }

    private func generateDeviceKeyLocked() throws -> SecKey {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &accessError
        ) else {
            throw EnrollmentVaultError.unavailable
        }

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessControl as String: access,
            ] as [String: Any],
        ]
        // The Secure Enclave is the intent; a Mac without one still gets a
        // keychain-resident key under the same access control rather than
        // refusing enrollment outright.
        if isSecureEnclaveAvailable {
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        }

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            Log.app.error("Enrollment key generation failed")
            throw EnrollmentVaultError.unavailable
        }
        return key
    }

    private var isSecureEnclaveAvailable: Bool {
        SecureEnclave.isAvailable
    }

    // MARK: - Envelope

    /// True when this device holds an envelope it could open.
    var isEnrolled: Bool {
        ((try? keychain.data(forKey: Key.record)) ?? nil) != nil
            || ((try? keychain.data(forKey: Key.envelope)) ?? nil) != nil
    }

    /// Replaces the record, durably and atomically, or throws and leaves the
    /// previous one exactly as it was.
    ///
    /// A successful store is a new delivery: a pending teardown no longer
    /// describes the device, so this is the one event that supersedes the
    /// teardown marker (key regeneration and `destroy` leave it alone).
    func store(_ record: VaultRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        var encoded = record.encoded()
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        try keychain.setData(encoded, forKey: Key.record)
        // The new record wins on every read, so a failed removal of the old
        // layout costs nothing but a stale item that `destroy` still removes.
        try? keychain.remove(Key.envelope)
        try? keychain.remove(Key.fingerprint)
        try? keychain.remove(Key.teardownReport)
    }

    /// Legacy armor under the identity it was sealed to.
    func store(privateKey: Data, identityFingerprint: String) throws {
        try store(VaultRecord(
            kind: .legacyArmor,
            material: privateKey,
            identityFingerprint: identityFingerprint
        ))
    }

    /// The record on disk, or nil when there is none. **Throws** when the
    /// Keychain will not answer or the record does not decode, so a caller
    /// never seals over a record it could not classify.
    func storedRecord() throws -> VaultRecord? {
        if let data = try keychain.data(forKey: Key.record) {
            guard let record = VaultRecord.decode(data) else {
                throw EnrollmentVaultError.unreadableRecord
            }
            return record
        }
        guard let legacy = try keychain.data(forKey: Key.envelope) else { return nil }
        let fingerprint = try keychain.data(forKey: Key.fingerprint)
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        return VaultRecord(kind: .legacyArmor, material: legacy, identityFingerprint: fingerprint)
    }

    func storedPrivateKey() throws -> Data {
        guard let record = try storedRecord() else { throw EnrollmentVaultError.notEnrolled }
        return record.material
    }

    var identityFingerprint: String? {
        ((try? storedRecord()) ?? nil)?.identityFingerprint
    }

    /// What a keyring record acknowledges, or nil for legacy armor or none.
    func keyringAcknowledgement() -> KeyringAcknowledgement? {
        ((try? storedRecord()) ?? nil)?.acknowledgement
    }

    // MARK: - Report markers

    /// Set after a deliberate teardown while the device is still paired.
    @discardableResult
    func markTeardownReport() -> Bool {
        (try? keychain.setData(Data([1]), forKey: Key.teardownReport)) != nil
    }

    var teardownReportPending: Bool {
        ((try? keychain.data(forKey: Key.teardownReport)) ?? nil) != nil
    }

    @discardableResult
    func clearTeardownReport() -> Bool {
        (try? keychain.remove(Key.teardownReport)) != nil
    }

    /// Records that the ceremony's own acknowledgement did not land, so the
    /// next launch or foreground restates it. `attempts` counts tries so far.
    ///
    /// Each new delivery mints a fresh `revision`, so a reporter whose request
    /// was in flight when it was written can tell the marker is not the one it
    /// sent for, and leaves it alone.
    @discardableResult
    func markReportPending(attempts: Int = 0, revision: String = UUID().uuidString) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return writeReportPending(PendingEnrollmentReport(attempts: attempts, revision: revision))
    }

    /// The pending acknowledgement, or nil when none is pending. A marker from
    /// before revisions existed reads with an empty revision.
    var pendingReport: PendingEnrollmentReport? {
        lock.lock()
        defer { lock.unlock() }
        return readReportPending()
    }

    /// Attempts made so far, or nil when no report is pending.
    var pendingReportAttempts: Int? { pendingReport?.attempts }

    /// Replaces (or with nil, clears) the pending marker only if it is still
    /// the revision `expected` names. Returns false when a newer marker, or
    /// none, is there — the caller's request is then out of date.
    @discardableResult
    func replacePendingReport(ifRevision expected: String, with next: PendingEnrollmentReport?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard readReportPending()?.revision == expected else { return false }
        guard let next else { return (try? keychain.remove(Key.reportPending)) != nil }
        return writeReportPending(next)
    }

    @discardableResult
    func clearReportPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (try? keychain.remove(Key.reportPending)) != nil
    }

    private func readReportPending() -> PendingEnrollmentReport? {
        guard let data = (try? keychain.data(forKey: Key.reportPending)) ?? nil else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let attempts = Int(parts[0]) ?? 0
        let revision = parts.count > 1 ? String(parts[1]) : ""
        return PendingEnrollmentReport(attempts: attempts, revision: revision)
    }

    private func writeReportPending(_ pending: PendingEnrollmentReport) -> Bool {
        let value = "\(pending.attempts):\(pending.revision)"
        return (try? keychain.setData(Data(value.utf8), forKey: Key.reportPending)) != nil
    }

    /// Both markers. For dropping the pairing: with no device row left there
    /// is nothing to correct, and a marker must not speak for the next
    /// pairing's device.
    @discardableResult
    func forgetPendingReports() -> [String] {
        var failures: [String] = []
        if !clearTeardownReport() { failures.append("deleteTeardownMarker") }
        if !clearReportPending() { failures.append("deleteReportMarker") }
        return failures
    }

    /// Destroys everything. Called when Hostile Location Protection is turned
    /// on, on unpair, and by a security wipe — a kept envelope after any of
    /// those is the account's private key sitting on a device that is supposed
    /// to hold nothing.
    func destroy() {
        _ = destroyReportingFailures()
    }

    /// The same destruction, naming what it could not remove.
    ///
    /// `SecurityWipe` needs the names: a key surviving a wipe nobody chose is
    /// exactly what an incomplete result exists to report, and `destroy`'s
    /// discarded errors cannot say so. The envelope is re-read afterwards
    /// rather than trusted to the delete's status — the claim being made is
    /// "the private key is gone", so it is worth checking.
    func destroyReportingFailures() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var failures: [String] = []
        do { try keychain.remove(Key.record) } catch { failures.append("deleteRecord") }
        do { try keychain.remove(Key.envelope) } catch { failures.append("deleteEnvelope") }
        do { try keychain.remove(Key.fingerprint) } catch { failures.append("deleteFingerprint") }
        // A pending acknowledgement describes the record just removed. The
        // teardown marker is deliberately left alone: the caller sets it
        // after this, and only `store` or dropping the pairing clears it.
        try? keychain.remove(Key.reportPending)
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            failures.append("deleteDeviceKey")
        }
        if ((try? keychain.data(forKey: Key.envelope)) ?? nil) != nil
            || ((try? keychain.data(forKey: Key.record)) ?? nil) != nil {
            failures.append("envelopeSurvived")
        }
        return failures
    }
}
