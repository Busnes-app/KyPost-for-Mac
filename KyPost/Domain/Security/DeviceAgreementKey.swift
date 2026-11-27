//
//  DeviceAgreementKey.swift
//  KyPost
//
//  The device's one P-256 key: the published enrollment key and the vault's
//  at-rest key. A CryptoKit Secure Enclave key under `.userPresence`, kept in
//  the Keychain as its opaque `dataRepresentation` (only this device's enclave
//  can use it), as `PinPepper` keeps its own.
//

import CryptoKit
import CryptoTokenKit
import Foundation
import LocalAuthentication
import os
import Security

/// Opens HPKE envelopes (v4/v5) and the vault with the same key.
nonisolated protocol DeviceAgreementKey: HPKEDiffieHellmanPrivateKey
    where PublicKey == P256.KeyAgreement.PublicKey {}

nonisolated extension SecureEnclave.P256.KeyAgreement.PrivateKey: DeviceAgreementKey {}
nonisolated extension P256.KeyAgreement.PrivateKey: DeviceAgreementKey {}

/// Mints the device key and restores it from its stored blob. A seam because
/// neither the Simulator nor the test host has a Secure Enclave.
nonisolated protocol DeviceKeyMinting: Sendable {
    func make() throws -> Data
    /// With `context`, the key's operations use that `LAContext`, so an
    /// already-authenticated context does not prompt.
    func restore(_ blob: Data, context: LAContext?) throws -> any DeviceAgreementKey
}

/// The production key. The allowed authenticators include the device
/// passcode on purpose (see `EnrollmentVault`); the policy is the one the
/// Security-framework key of earlier builds carried.
nonisolated struct EnclaveKeyMinting: DeviceKeyMinting {
    func make() throws -> Data {
        guard SecureEnclave.isAvailable else { throw EnrollmentVaultError.unavailable }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &accessError
        ) else {
            _ = accessError?.takeRetainedValue()
            throw EnrollmentVaultError.unavailable
        }
        do {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(
                compactRepresentable: false,
                accessControl: access
            ).dataRepresentation
        } catch {
            Log.app.error("Enrollment key generation failed")
            throw EnrollmentVaultError.unavailable
        }
    }

    func restore(_ blob: Data, context: LAContext?) throws -> any DeviceAgreementKey {
        try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
    }
}

#if DEBUG || targetEnvironment(simulator)
/// A software key, for the Simulator (which has no Secure Enclave) and tests.
/// No presence check and no hardware binding; never in a device release build.
nonisolated struct SoftwareKeyMinting: DeviceKeyMinting {
    func make() throws -> Data { P256.KeyAgreement.PrivateKey().rawRepresentation }

    func restore(_ blob: Data, context: LAContext?) throws -> any DeviceAgreementKey {
        try P256.KeyAgreement.PrivateKey(rawRepresentation: blob)
    }
}
#endif

/// The Secure Enclave is required on a device; only the Simulator gets the
/// software key.
nonisolated func defaultDeviceKeyMinting() -> any DeviceKeyMinting {
    #if targetEnvironment(simulator)
    if SecureEnclave.isAvailable { return EnclaveKeyMinting() }
    return SoftwareKeyMinting()
    #else
    return EnclaveKeyMinting()
    #endif
}

/// The device key's one Keychain item.
nonisolated final class DeviceKeyStore: @unchecked Sendable {
    static let item = "enrollment.deviceKey"

    private let keychain: any SecureItemStoring
    private let minting: any DeviceKeyMinting
    private let lock = NSLock()

    init(keychain: any SecureItemStoring, minting: any DeviceKeyMinting) {
        self.keychain = keychain
        self.minting = minting
    }

    func load(context: LAContext?) throws -> (any DeviceAgreementKey)? {
        lock.lock(); defer { lock.unlock() }
        return try loadLocked(context: context)
    }

    /// The key, minted first if there is none.
    func loadOrCreate() throws -> any DeviceAgreementKey {
        lock.lock(); defer { lock.unlock() }
        if let key = try loadLocked(context: nil) { return key }
        let blob = try minting.make()
        try keychain.setData(blob, forKey: Self.item)
        return try minting.restore(blob, context: nil)
    }

    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        try keychain.remove(Self.item)
    }

    private func loadLocked(context: LAContext?) throws -> (any DeviceAgreementKey)? {
        guard let blob = try keychain.data(forKey: Self.item) else { return nil }
        do {
            return try minting.restore(blob, context: context)
        } catch {
            throw EnrollmentVaultError.unavailable
        }
    }
}

/// The vault at rest (record format 3): HPKE to the device key's own public
/// half, `enc || ciphertext`. Sealing mints the key if needed and never
/// prompts; opening is the Secure Enclave decapsulation under presence.
nonisolated struct HPKEKeySealing: VaultKeySealing {
    let keys: DeviceKeyStore

    static let info = Data("kypost-vault-record/v1".utf8)
    private static let encBytes = 65

    func seal(_ plaintext: Data) throws -> Data {
        let key = try keys.loadOrCreate()
        var sender = try HPKE.Sender(
            recipientKey: key.publicKey, ciphersuite: deviceEnvelopeHPKESuite, info: Self.info
        )
        let ciphertext = try sender.seal(plaintext)
        return sender.encapsulatedKey + ciphertext
    }

    func open(_ sealed: Data, context: LAContext) throws -> Data {
        guard sealed.count > Self.encBytes else { throw EnrollmentVaultError.unreadableRecord }
        guard let key = try keys.load(context: context) else { throw EnrollmentVaultError.notEnrolled }
        var recipient: HPKE.Recipient
        do {
            recipient = try HPKE.Recipient(
                privateKey: key,
                ciphersuite: deviceEnvelopeHPKESuite,
                info: Self.info,
                encapsulatedKey: Data(sealed.prefix(Self.encBytes))
            )
        } catch {
            throw deviceKeyError(error)
        }
        guard let plaintext = try? recipient.open(sealed.dropFirst(Self.encBytes)) else {
            throw EnrollmentVaultError.unreadableRecord
        }
        return plaintext
    }
}

/// Maps a failed CryptoKit Secure Enclave operation. Only cancellation reads
/// as cancelled, as in `vaultError(from:)`; CryptoKit reports the enclave
/// through CryptoTokenKit, so its cancel code counts too.
nonisolated func deviceKeyError(_ error: any Error) -> EnrollmentVaultError {
    if let vault = error as? EnrollmentVaultError { return vault }
    let nsError = error as NSError
    if nsError.domain == TKErrorDomain, nsError.code == TKError.Code.canceledByUser.rawValue {
        return .cancelled
    }
    return vaultError(domain: nsError.domain, code: nsError.code)
}

/// X-Wing is a software KEM on this bridge. Its seed is readable only through
/// a ThisDeviceOnly, passcode-set, user-presence Keychain item. It is NEVER
/// stored in the ordinary background-readable KeychainStorage. The public half
/// is a separate item so displaying SAS or sealing does not raise a prompt.
nonisolated protocol XWingKeyStoring: Sendable {
    func publicKey() throws -> Data
    func withSeed<T>(context: LAContext, _ body: (Data) throws -> T) throws -> T
    func delete() throws
}

nonisolated final class XWingKeyStore: XWingKeyStoring, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    init(service: String) { self.service = service + ".xwing.v1" }

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: account, kSecUseDataProtectionKeychain: true]
    }

    func publicKey() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        var q = query("public")
        q[kSecReturnData] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, XWingCrypto.isValidPublicKey(data) else {
                throw EnrollmentVaultError.unavailable
            }
            // A surviving public half is never authority to replace a lost seed.
            var seedQuery = query("seed")
            seedQuery[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
            let seedStatus = SecItemCopyMatching(seedQuery as CFDictionary, nil)
            guard seedStatus == errSecSuccess || seedStatus == errSecInteractionNotAllowed else {
                throw EnrollmentVaultError.keychain(seedStatus)
            }
            return data
        }
        guard status == errSecItemNotFound else { throw EnrollmentVaultError.keychain(status) }
        var seed = try XWingCrypto.generateSeed()
        defer { seed.resetBytes(in: 0..<seed.count) }
        let pub = try XWingCrypto.publicKey(seed: seed)
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &accessError
        ) else { throw vaultError(from: accessError?.takeRetainedValue()) }
        var seedQuery = query("seed")
        seedQuery[kSecAttrAccessControl] = access
        seedQuery[kSecValueData] = seed
        let added = SecItemAdd(seedQuery as CFDictionary, nil)
        // A crash between writes leaves the seed intact. Recover it under
        // presence instead of replacing it and making a sealed vault unreadable.
        if added == errSecDuplicateItem {
            return try withSeed(context: LAContext()) { oldSeed in
                let oldPublic = try XWingCrypto.publicKey(seed: oldSeed)
                try storePublic(oldPublic)
                return oldPublic
            }
        }
        guard added == errSecSuccess else { throw EnrollmentVaultError.keychain(added) }
        try storePublic(pub)
        return pub
    }

    private func storePublic(_ data: Data) throws {
        var q = query("public")
        q[kSecValueData] = data
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw EnrollmentVaultError.keychain(status) }
    }

    func withSeed<T>(context: LAContext, _ body: (Data) throws -> T) throws -> T {
        var q = query("seed")
        q[kSecReturnData] = true
        q[kSecUseAuthenticationContext] = context
        q[kSecUseOperationPrompt] = EnrollmentVault.presenceReason
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecUserCanceled { throw EnrollmentVaultError.cancelled }
        guard status == errSecSuccess else { throw EnrollmentVaultError.keychain(status) }
        guard var seed = item as? Data, seed.count == 32 else { throw EnrollmentVaultError.unavailable }
        defer { seed.resetBytes(in: 0..<seed.count) }
        return try body(seed)
    }

    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        for account in ["seed", "public"] {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw EnrollmentVaultError.keychain(status)
            }
        }
    }
}

/// New records use X-Wing; old P-256 records are opened for migration.
nonisolated struct XWingKeySealing: VaultKeySealing {
    let keys: any XWingKeyStoring
    let legacy: HPKEKeySealing
    static let marker = Data("KPXW1".utf8)
    static let info = Data("kypost-vault-record/v2".utf8)

    func seal(_ plaintext: Data) throws -> Data {
        try Self.marker + XWingCrypto.seal(publicKey: keys.publicKey(), info: Self.info, plaintext: plaintext)
    }

    func open(_ sealed: Data, context: LAContext) throws -> Data {
        guard sealed.starts(with: Self.marker) else { return try legacy.open(sealed, context: context) }
        return try keys.withSeed(context: context) { seed in
            guard let value = XWingCrypto.open(seed: seed, info: Self.info, sealed: Data(sealed.dropFirst(Self.marker.count))) else {
                throw EnrollmentVaultError.unreadableRecord
            }
            return value
        }
    }
}
