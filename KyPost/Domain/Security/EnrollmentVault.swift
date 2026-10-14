//
//  EnrollmentVault.swift
//  KyPost
//
//  The durable half of device enrollment: a Secure Enclave P-256 key that
//  requires user presence, and the account's private key sealed under it.
//  Swift port of kypost-android's pgp/EnrollmentVault.kt.
//
//  **Nothing here stores key material in the clear.** The record's material
//  is sealed to the device key (ECIES, AES-GCM) before it reaches the
//  Keychain, and only a Secure Enclave private-key operation under the key's
//  `.userPresence` access control opens it. Reading the Keychain item alone
//  yields ciphertext.
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

/// What a record says about itself without its key material. Stored in the
/// clear beside the sealed material, because the launch-time report and the
/// enrollment marker need it without a presence prompt.
nonisolated struct VaultRecordHeader: Equatable, Sendable {
    var kind: VaultRecordKind
    var identityFingerprint: String
    /// The keyring's generation; nil for legacy armor.
    var materialGeneration: UInt64?

    var acknowledgement: KeyringAcknowledgement? {
        guard kind == .keyring, let materialGeneration else { return nil }
        return KeyringAcknowledgement(
            materialGeneration: materialGeneration,
            fingerprint: identityFingerprint
        )
    }
}

/// One record, written as **one** Keychain item.
///
/// One item is what makes replacement atomic: `SecItemUpdate` on a single
/// item either lands or leaves the old bytes, so a failed write can never
/// leave new material beside an old fingerprint, or a keyring under a legacy
/// kind. The earlier layout stored the key and its fingerprint as two items
/// written one after the other.
///
/// `encoded()` is the plaintext form (format 1). It is what gets sealed to
/// the device key, header included, so the clear header on disk cannot be
/// swapped onto other material. On disk the plaintext form exists only from
/// builds before the seal, and the first presence-checked open re-seals it
/// (`EnrollmentVault.openRecord`).
nonisolated struct VaultRecord: Equatable, Sendable, CustomStringConvertible {
    var kind: VaultRecordKind
    var material: Data
    var identityFingerprint: String
    /// The keyring's generation; nil for legacy armor.
    var materialGeneration: UInt64?

    var description: String { "VaultRecord(\(kind), redacted)" }

    var header: VaultRecordHeader {
        VaultRecordHeader(
            kind: kind,
            identityFingerprint: identityFingerprint,
            materialGeneration: materialGeneration
        )
    }

    var acknowledgement: KeyringAcknowledgement? { header.acknowledgement }

    static let magic = Data("KPVR".utf8)
    /// Material in the clear. Read for migration only; never written to disk.
    static let plainFormat: UInt8 = 1
    /// Material sealed to the device key (`VaultKeySealing`).
    static let sealedFormat: UInt8 = 2

    /// `magic || format || kind || uint64BE(generation) || uint16BE(len fp) || fp || tail`
    static func encode(_ header: VaultRecordHeader, format: UInt8, tail: Data) -> Data {
        var data = magic
        data.append(format)
        data.append(header.kind.rawValue)
        let generation = header.materialGeneration ?? 0
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: generation >> UInt64(shift)))
        }
        let fingerprint = Data(header.identityFingerprint.utf8)
        data.append(bigEndianUInt16(fingerprint.count))
        data.append(fingerprint)
        data.append(tail)
        return data
    }

    /// The plaintext form. The caller zeroes it.
    func encoded() -> Data {
        Self.encode(header, format: Self.plainFormat, tail: material)
    }

    /// Splits either format into its header and its tail — the material, or
    /// the sealed blob.
    static func parse(_ data: Data) -> (format: UInt8, header: VaultRecordHeader, tail: Data)? {
        let bytes = [UInt8](data)
        let headerLength = magic.count + 2 + 8 + 2
        guard bytes.count > headerLength,
              Data(bytes[0..<magic.count]) == magic,
              bytes[magic.count] == plainFormat || bytes[magic.count] == sealedFormat,
              let kind = VaultRecordKind(rawValue: bytes[magic.count + 1])
        else { return nil }
        let format = bytes[magic.count]
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
        let header = VaultRecordHeader(
            kind: kind,
            identityFingerprint: fingerprint,
            materialGeneration: kind == .keyring ? generation : nil
        )
        return (format, header, Data(bytes[index...]))
    }

    /// The plaintext form only.
    static func decode(_ data: Data) -> VaultRecord? {
        guard let parsed = parse(data), parsed.format == plainFormat else { return nil }
        return VaultRecord(
            kind: parsed.header.kind,
            material: parsed.tail,
            identityFingerprint: parsed.header.identityFingerprint,
            materialGeneration: parsed.header.materialGeneration
        )
    }
}

nonisolated enum EnrollmentVaultError: Error, Equatable {
    /// No passcode, Touch ID or Face ID is set. The envelope's protection *is*
    /// the lock screen, so a device without one cannot hold a meaningful one.
    /// The honest outcome, not a degradation.
    case noDeviceCredential
    /// The Secure Enclave refused, or this device has none.
    case unavailable
    case keychain(OSStatus)
    case notEnrolled
    /// The user dismissed the authentication prompt. Not an error — the caller
    /// goes back to offering the action.
    case cancelled
    /// A record exists and does not decode, or its sealed header does not
    /// match the clear one. Never overwritten blind.
    case unreadableRecord
}

/// The device-key boundary: what seals a record at rest and what opens it.
///
/// Sealing uses the device key's **public** half and never prompts. Opening
/// is a Secure Enclave private-key operation under the key's `.userPresence`
/// access control, so it *is* the presence check — there is no other path to
/// the material. A protocol so the vault's migration and prompt policy are
/// unit tests; `DeviceKeySealing` is the only production conformer.
nonisolated protocol VaultKeySealing: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    /// Prompts unless `context` already authenticated. Throws
    /// `EnrollmentVaultError.cancelled` when the user dismissed the prompt.
    func open(_ sealed: Data, context: LAContext) throws -> Data
}

/// ECIES to the enrollment device key: an ephemeral P-256 key agreement, the
/// X9.63 KDF with SHA-256, and AES-GCM — Security framework's
/// `eciesEncryptionCofactorVariableIVX963SHA256AESGCM`, so no hand-rolled
/// construction.
///
/// The same key opens enrollment envelopes (HKDF, its own domain strings);
/// reusing it means existing installs migrate without a second key, and the
/// wipe's one key deletion covers both. A second key would add nothing: both
/// uses need the same Secure Enclave operation under the same presence check.
nonisolated struct DeviceKeySealing: VaultKeySealing {
    let keyTag: Data

    static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    func seal(_ plaintext: Data) throws -> Data {
        guard let key = try loadDeviceKey(tag: keyTag, context: nil),
              let publicKey = SecKeyCopyPublicKey(key)
        else { throw EnrollmentVaultError.notEnrolled }
        var error: Unmanaged<CFError>?
        guard let sealed = SecKeyCreateEncryptedData(
            publicKey, Self.algorithm, plaintext as CFData, &error
        ) as Data? else {
            _ = error?.takeRetainedValue()
            throw EnrollmentVaultError.unavailable
        }
        return sealed
    }

    func open(_ sealed: Data, context: LAContext) throws -> Data {
        guard let key = try loadDeviceKey(tag: keyTag, context: context) else {
            throw EnrollmentVaultError.notEnrolled
        }
        var error: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(
            key, Self.algorithm, sealed as CFData, &error
        ) as Data? else {
            throw vaultError(from: error?.takeRetainedValue())
        }
        return plaintext
    }
}

/// The device key by tag. With `context`, operations on the returned key use
/// that `LAContext`, so an already-authenticated context does not prompt.
nonisolated func loadDeviceKey(tag: Data, context: LAContext?) throws -> SecKey? {
    var query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: tag,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecReturnRef as String: true,
    ]
    if let context { query[kSecUseAuthenticationContext as String] = context }
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

/// Maps a failed device-key operation. **Only cancellation reads as
/// cancelled** — the user's, the system's, or this app's own invalidation of
/// the context when the lock engaged mid-prompt. `errSecAuthFailed` is an
/// authentication that was attempted and rejected, a different event with a
/// different remedy.
nonisolated func vaultError(from error: CFError?) -> EnrollmentVaultError {
    guard let error else { return .unavailable }
    let code = CFErrorGetCode(error)
    let domain = CFErrorGetDomain(error) as String
    if domain == LAErrorDomain {
        let cancelled: Set<Int> = [
            LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue,
        ]
        return cancelled.contains(code) ? .cancelled : .unavailable
    }
    if code == Int(errSecUserCanceled) { return .cancelled }
    if domain == NSOSStatusErrorDomain { return .keychain(OSStatus(code)) }
    return .unavailable
}

/// Holds the device keypair and the sealed record.
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
    private let sealing: any VaultKeySealing
    /// The authenticated context reused across opens until the app locks.
    let presence: PresenceContext
    private let lock = NSLock()

    /// Separate from the pairing store's service so a device unpair does not
    /// silently take the enrollment with it, and vice versa.
    static let defaultKeyTag = "org.kysecurity.mail.enrollment.deviceKey"

    /// The prompt's reason line, wherever the vault raises it.
    static var presenceReason: String { String(localized: "Unlock your encryption key") }

    init(
        keychain: any SecureItemStoring,
        keyTag: String = EnrollmentVault.defaultKeyTag,
        sealing: (any VaultKeySealing)? = nil,
        presence: PresenceContext = .shared
    ) {
        self.keychain = keychain
        self.keyTag = Data(keyTag.utf8)
        self.sealing = sealing ?? DeviceKeySealing(keyTag: Data(keyTag.utf8))
        self.presence = presence
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
        if let existing = try loadDeviceKey(tag: keyTag, context: nil) { return existing }
        guard hasDeviceCredential else { throw EnrollmentVaultError.noDeviceCredential }
        return try generateDeviceKeyLocked()
    }

    /// The device key. With `context`, its operations use that `LAContext`.
    func deviceKey(context: LAContext? = nil) throws -> SecKey {
        lock.lock()
        defer { lock.unlock() }
        guard let key = try loadDeviceKey(tag: keyTag, context: context) else {
            throw EnrollmentVaultError.notEnrolled
        }
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
        // The Secure Enclave is required: every device this app supports has
        // one (macOS 26 runs only on Apple silicon and T2 Macs), so a device
        // without one is refused rather than given a software key under a
        // weaker claim. The Simulator alone has none, and keeps a
        // keychain-resident key under the same access control for development.
        #if targetEnvironment(simulator)
        if SecureEnclave.isAvailable {
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        }
        #else
        guard SecureEnclave.isAvailable else { throw EnrollmentVaultError.unavailable }
        attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        #endif

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            Log.app.error("Enrollment key generation failed")
            throw EnrollmentVaultError.unavailable
        }
        return key
    }

    // MARK: - Record

    /// True when this device holds a record it could open.
    var isEnrolled: Bool {
        ((try? keychain.data(forKey: Key.record)) ?? nil) != nil
            || ((try? keychain.data(forKey: Key.envelope)) ?? nil) != nil
    }

    /// Seals the record to the device key and replaces the stored one,
    /// durably and atomically, or throws and leaves the previous one exactly
    /// as it was. Never prompts: sealing uses the public half.
    ///
    /// A successful store is a new delivery: a pending teardown no longer
    /// describes the device, so this is the one event that supersedes the
    /// teardown marker (key regeneration and `destroy` leave it alone).
    func store(_ record: VaultRecord) throws {
        var encoded = record.encoded()
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        let sealed = try sealing.seal(encoded)
        lock.lock()
        defer { lock.unlock() }
        try keychain.setData(
            VaultRecord.encode(record.header, format: VaultRecord.sealedFormat, tail: sealed),
            forKey: Key.record
        )
        // The new record wins on every read, so a failed removal of the old
        // layout costs nothing but a stale item that the next open and
        // `destroy` both remove again.
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

    /// What is stored, as read: sealed, or plaintext from an earlier build.
    private enum StoredItem {
        case sealed(VaultRecordHeader, blob: Data, raw: Data)
        /// `raw` is nil for the two-item layout.
        case plain(VaultRecord, raw: Data?)
    }

    private func storedItem() throws -> StoredItem? {
        if let data = try keychain.data(forKey: Key.record) {
            guard let parsed = VaultRecord.parse(data) else {
                throw EnrollmentVaultError.unreadableRecord
            }
            if parsed.format == VaultRecord.sealedFormat {
                return .sealed(parsed.header, blob: parsed.tail, raw: data)
            }
            return .plain(VaultRecord(
                kind: parsed.header.kind,
                material: parsed.tail,
                identityFingerprint: parsed.header.identityFingerprint,
                materialGeneration: parsed.header.materialGeneration
            ), raw: data)
        }
        guard let legacy = try keychain.data(forKey: Key.envelope) else { return nil }
        let fingerprint = try keychain.data(forKey: Key.fingerprint)
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        return .plain(
            VaultRecord(kind: .legacyArmor, material: legacy, identityFingerprint: fingerprint),
            raw: nil
        )
    }

    /// The stored record's header, or nil when there is none. Never prompts.
    /// **Throws** when the Keychain will not answer or the record does not
    /// decode, so a caller never acts on a record it could not classify.
    func storedHeader() throws -> VaultRecordHeader? {
        switch try storedItem() {
        case nil: nil
        case .sealed(let header, _, _): header
        case .plain(let record, _): record.header
        }
    }

    /// Opens the stored record — **the presence-checked step**. Prompts once
    /// per app unlock (`PresenceContext`); nil when there is none.
    ///
    /// A plaintext record from a build before the seal is migrated here: it
    /// is sealed, the seal is opened under presence (which is both the check
    /// and the proof the new item opens), and only then does the sealed item
    /// replace it — the same single Keychain item, so plaintext and sealed
    /// copies never coexist. A cancelled prompt changes nothing.
    ///
    /// Throws `cancelled` when the prompt was dismissed, and
    /// `unreadableRecord` for a record that does not decode or whose sealed
    /// header disagrees with the clear one.
    func openRecord() throws -> VaultRecord? {
        switch try storedItem() {
        case nil:
            return nil

        case .sealed(let header, let blob, _):
            var inner = try openUnderPresence(blob)
            defer { inner.resetBytes(in: 0..<inner.count) }
            guard let record = VaultRecord.decode(inner), record.header == header else {
                throw EnrollmentVaultError.unreadableRecord
            }
            retireTwoItemLayout()
            return record

        case .plain(let record, let raw):
            var encoded = record.encoded()
            defer { encoded.resetBytes(in: 0..<encoded.count) }
            let sealed = try sealing.seal(encoded)
            var check = try openUnderPresence(sealed)
            defer { check.resetBytes(in: 0..<check.count) }
            guard check == encoded else { throw EnrollmentVaultError.unavailable }
            try replacePlaintext(raw: raw, with: VaultRecord.encode(
                record.header, format: VaultRecord.sealedFormat, tail: sealed
            ))
            return record
        }
    }

    /// Writes the sealed migration only while the plaintext it was made from
    /// is still what is stored: a ceremony that stored a newer record during
    /// the prompt wins, and nothing is sealed over it.
    private func replacePlaintext(raw: Data?, with sealedRecord: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if let current = try keychain.data(forKey: Key.record) {
            guard current == raw else { return }
        } else if raw != nil {
            return
        }
        try keychain.setData(sealedRecord, forKey: Key.record)
        retireTwoItemLayoutLocked()
    }

    private func retireTwoItemLayout() {
        lock.lock()
        defer { lock.unlock() }
        retireTwoItemLayoutLocked()
    }

    /// The plaintext two-item layout must not outlive the sealed record.
    private func retireTwoItemLayoutLocked() {
        guard ((try? keychain.data(forKey: Key.envelope)) ?? nil) != nil
            || ((try? keychain.data(forKey: Key.fingerprint)) ?? nil) != nil
        else { return }
        try? keychain.remove(Key.envelope)
        try? keychain.remove(Key.fingerprint)
    }

    /// One device-key open under the shared presence context. A held context
    /// that stopped working is dropped and the open asked once more, fresh; a
    /// dismissed prompt is never retried.
    private func openUnderPresence(_ blob: Data) throws -> Data {
        let lease = presence.lease(reason: Self.presenceReason)
        do {
            let plaintext = try sealing.open(blob, context: lease.context)
            presence.keep(lease)
            return plaintext
        } catch EnrollmentVaultError.cancelled {
            throw EnrollmentVaultError.cancelled
        } catch where lease.wasHeld {
            presence.discard(lease)
            let fresh = presence.lease(reason: Self.presenceReason)
            let plaintext = try sealing.open(blob, context: fresh.context)
            presence.keep(fresh)
            return plaintext
        }
    }

    var identityFingerprint: String? {
        ((try? storedHeader()) ?? nil)?.identityFingerprint
    }

    /// What a keyring record acknowledges, or nil for legacy armor or none.
    func keyringAcknowledgement() -> KeyringAcknowledgement? {
        ((try? storedHeader()) ?? nil)?.acknowledgement
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
    /// on, on unpair, by a security wipe, and by the failed-unlock reset — a
    /// kept record after any of those is the account's private key sitting on
    /// a device that is supposed to hold nothing.
    func destroy() {
        _ = destroyReportingFailures()
    }

    /// The same destruction, naming what it could not remove.
    ///
    /// `SecurityWipe` needs the names: a key surviving a wipe nobody chose is
    /// exactly what an incomplete result exists to report, and `destroy`'s
    /// discarded errors cannot say so. The record is re-read afterwards
    /// rather than trusted to the delete's status — the claim being made is
    /// "the private key is gone", so it is worth checking.
    func destroyReportingFailures() -> [String] {
        // The held context authenticates a key that is about to be gone.
        presence.invalidate()
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
