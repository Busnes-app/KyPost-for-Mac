//
//  PinPepper.swift
//  KyPost
//
//  The device-bound secret mixed into the app-lock PIN verifier. Swift port of
//  kypost-android's KeystorePinPepper, whose job here falls to the Secure
//  Enclave.
//

import CryptoKit
import Foundation

/// The pepper is gone or cannot be used — so the stored verifier can no longer
/// be evaluated at all.
///
/// **This is not a wrong PIN**, and the difference is the whole reason this
/// error exists: `AppLockManager` counts wrong PINs toward a wipe, and folding
/// an unevaluable verifier into "wrong" is how Android destroyed user data in
/// response to an OS-level key invalidation nobody caused.
nonisolated struct PepperUnavailable: Error, CustomStringConvertible {
    var detail: String
    var description: String { "The PIN verifier's device key is unavailable: \(detail)" }
}

/// Mixes a device-bound secret into derived key material.
///
/// A protocol because everything downstream — the hasher, the store, the
/// manager's whole exit table — must be testable without a Secure Enclave or a
/// Keychain, neither of which exists in a headless test process.
protocol PinPepper: Sendable {
    /// Creates the secret if this is the first one.
    ///
    /// Deliberately **separate from `mix`**, because "no pepper" means opposite
    /// things on the two paths: setting a PIN legitimately establishes one,
    /// while verifying against a missing one means the stored verifier is
    /// unevaluable. Minting on the verify path made every subsequent correct
    /// PIN read as wrong, and ten of those wipe the device.
    func ensureExists() throws

    /// Peppers `input`. Never creates — throws `PepperUnavailable` instead.
    func mix(_ input: Data) throws -> Data
}

/// The real pepper: a key that cannot leave this machine.
///
/// The point is not secrecy from the user — it is that an attacker who copies
/// the Keychain item off the disk still cannot evaluate a PIN guess anywhere
/// but on this device, through this key. PBKDF2 iterations alone cannot defend
/// a 10^8 keyspace against a GPU; forcing every guess back through the
/// hardware can.
///
/// Two backings, recorded in the stored value itself rather than re-decided at
/// read time. A machine that could once mint a Secure Enclave key and later
/// reports none — an OS change, a VM, a spec that moved — must still be able to
/// tell which derivation its existing verifier used, or every correct PIN reads
/// as wrong.
nonisolated struct DevicePinPepper: PinPepper {
    /// A distinct account from anything else in the Keychain, so the PIN
    /// verifier's pepper and the credential-wrapping key are never
    /// interchangeable.
    static let keychainKey = "appLock.pinPepper"

    private static let secureEnclavePrefix = "se:"
    private static let softwarePrefix = "kc:"
    private static let info = Data("KyPost app-lock PIN pepper v1".utf8)

    private let keychain: KeychainStorage
    /// Injected so a test can force the software path on a machine that has an
    /// enclave, and vice versa.
    private let secureEnclaveAvailable: @Sendable () -> Bool
    /// Mints the enclave key and returns its opaque handle. Injected so a test
    /// can make it fail on a machine whose enclave would not.
    private let makeEnclaveKey: @Sendable () throws -> Data

    init(
        keychain: KeychainStorage,
        secureEnclaveAvailable: @escaping @Sendable () -> Bool = { SecureEnclave.isAvailable },
        makeEnclaveKey: @escaping @Sendable () throws -> Data = {
            try SecureEnclave.P256.KeyAgreement.PrivateKey().dataRepresentation
        }
    ) {
        self.keychain = keychain
        self.secureEnclaveAvailable = secureEnclaveAvailable
        self.makeEnclaveKey = makeEnclaveKey
    }

    func ensureExists() throws {
        if let existing = try? keychain.string(forKey: Self.keychainKey), !existing.isEmpty {
            return
        }
        let stored: String
        if secureEnclaveAvailable() {
            // An enclave that is there but refuses a key is an error, never a
            // reason to fall back: the software pepper can be copied off the
            // disk with the Keychain, which is the one thing the enclave is
            // here to prevent, and a silent downgrade would be permanent —
            // the prefix pins this install to whichever backing it got.
            let key: Data
            do {
                key = try makeEnclaveKey()
            } catch {
                throw PepperUnavailable(detail: "the Secure Enclave refused to create a key (\(error))")
            }
            stored = Self.secureEnclavePrefix + key.base64EncodedString()
        } else {
            // No enclave on this machine. A random key in the device-only
            // Keychain is weaker — it can be read by anything that can read the
            // Keychain — but it is what an Intel Mac without a T2 has, and
            // refusing to offer a PIN at all there would be worse. The prefix
            // records which one this install got.
            stored = Self.softwarePrefix
                + Data(SymmetricKey(size: .bits256).withUnsafeBytes(Array.init)).base64EncodedString()
        }
        try keychain.set(stored, forKey: Self.keychainKey)
    }

    func mix(_ input: Data) throws -> Data {
        let stored: String?
        do {
            stored = try keychain.string(forKey: Self.keychainKey)
        } catch {
            // A Keychain that will not answer is not an absent pepper, but for
            // this caller the consequence is identical and the safe reading is
            // the same one: unevaluable, never "wrong PIN".
            throw PepperUnavailable(detail: "the Keychain refused the read (\(error))")
        }
        guard let stored, !stored.isEmpty else {
            throw PepperUnavailable(detail: "no pepper is stored")
        }

        if stored.hasPrefix(Self.secureEnclavePrefix) {
            let encoded = String(stored.dropFirst(Self.secureEnclavePrefix.count))
            guard let blob = Data(base64Encoded: encoded) else {
                throw PepperUnavailable(detail: "the stored enclave key is unreadable")
            }
            let key: SecureEnclave.P256.KeyAgreement.PrivateKey
            do {
                key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
            } catch {
                throw PepperUnavailable(detail: "the enclave refused this key (\(error))")
            }
            // Agreement against the key's *own* public half. It is deterministic,
            // it needs no constant baked into the source, and the private half
            // never leaves the enclave — which is the only property being bought
            // here.
            guard let secret = try? key.sharedSecretFromKeyAgreement(with: key.publicKey) else {
                throw PepperUnavailable(detail: "the enclave would not perform key agreement")
            }
            let derived = secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: Self.info, sharedInfo: Data(), outputByteCount: 32
            )
            return Data(HMAC<SHA256>.authenticationCode(for: input, using: derived))
        }

        guard stored.hasPrefix(Self.softwarePrefix),
              let raw = Data(base64Encoded: String(stored.dropFirst(Self.softwarePrefix.count)))
        else {
            throw PepperUnavailable(detail: "the stored pepper is in an unknown format")
        }
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: raw)))
    }

    /// Removes the pepper, naming the step it could not remove so
    /// `SecurityWipe` reports an incomplete wipe rather than a clean one.
    func destroy() -> [String] {
        do {
            try keychain.remove(Self.keychainKey)
            return []
        } catch {
            return ["deletePinPepper"]
        }
    }
}
