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

/// Opens HPKE (v4/v5, the vault) and plain ECDH (v2/v3) with the same key.
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
    return vaultError(from: nsError as CFError)
}
