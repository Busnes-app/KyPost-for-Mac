//
//  PinHasher.swift
//  KyPost
//
//  PBKDF2 verifier for the app-lock PIN. Swift port of kypost-android's
//  security/PinHasher.kt.
//
//  The raw PIN is never stored — only the salted, peppered value below.
//

import CommonCrypto
import CryptoKit
import Foundation

/// A stored verifier. `hash` is never the PIN.
nonisolated struct PinHash: Equatable, Sendable {
    var salt: Data
    var hash: Data
    /// Which derivation produced `hash`. Stored so a future change can migrate
    /// existing installs rather than locking them out.
    var version: Int
}

nonisolated enum PinHasher {
    /// PBKDF2-HMAC-SHA256, then peppered with the device key.
    static let currentVersion = 1

    private static let iterations: UInt32 = 150_000
    private static let keyLengthBytes = 32
    private static let saltLengthBytes = 16

    /// Derives a storable verifier, creating the device pepper if this is the
    /// first one. Set-a-PIN only — see `PinPepper.ensureExists`.
    static func hash(
        pin: String,
        salt: Data = randomSalt(),
        pepper: any PinPepper
    ) throws -> PinHash {
        try pepper.ensureExists()
        return PinHash(salt: salt, hash: try pepper.mix(pbkdf2(pin: pin, salt: salt)), version: currentVersion)
    }

    /// Verifies `pin` against a stored verifier. **Never creates a pepper.**
    ///
    /// Throws rather than returning false when the pepper is gone: a `false`
    /// here is indistinguishable from a wrong PIN, and wrong PINs are counted
    /// toward the user's `WipeThreshold`.
    static func matches(pin: String, stored: PinHash, pepper: any PinPepper) throws -> Bool {
        guard stored.version == currentVersion else {
            // A verifier written by a build this one does not understand. Not a
            // wrong PIN, and it must not be counted as one — the same reasoning
            // as a missing pepper, so it takes the same exit.
            throw PepperUnavailable(detail: "the stored verifier is version \(stored.version)")
        }
        let candidate = try pepper.mix(pbkdf2(pin: pin, salt: stored.salt))
        // Constant-time. A PIN check is exactly where short-circuiting on the
        // first differing byte leaks to a timing attacker with unlimited local
        // retries.
        return constantTimeEquals(candidate, stored.hash)
    }

    static func randomSalt() -> Data {
        Data(SymmetricKey(size: .bits128).withUnsafeBytes(Array.init))
    }

    /// Length is compared first and in the open: it is not secret (the hash is
    /// a fixed width), and a loop over the shorter of two arrays would compare
    /// nothing at all when one is empty.
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    private static func pbkdf2(pin: String, salt: Data) -> Data {
        var derived = Data(count: keyLengthBytes)
        // The PIN is passed as bytes with an explicit length rather than
        // through the C-string overload: `pin` is validated as ASCII digits,
        // but a caller that ever handed this a string containing a NUL would
        // otherwise silently derive from the prefix before it.
        //
        // Every pointer is used *inside* the closure that produced it. Lifting
        // one out — `bytes.withUnsafeBytes { $0.baseAddress }` as an argument —
        // compiles and yields a pointer already invalid at the call.
        //
        // The trailing zero is padding, not data: `count` below excludes it. An
        // empty `Array` can hand back a nil `baseAddress`, and an empty PIN is
        // reachable — `matches` takes whatever the field held.
        let pinBytes = Array(pin.utf8) + [0]
        let status: Int32 = pinBytes.withUnsafeBufferPointer { pinBuffer in
            salt.withUnsafeBytes { saltBuffer in
                derived.withUnsafeMutableBytes { out in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        UnsafeRawPointer(pinBuffer.baseAddress!).assumingMemoryBound(to: CChar.self),
                        pinBuffer.count - 1,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLengthBytes
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            // CommonCrypto fails here only on a programming error (a null
            // buffer, a zero length). Deriving nothing would compare equal to
            // another empty derivation, so an empty result must never be
            // returned as a verifier.
            fatalError("PBKDF2 failed with status \(status)")
        }
        return derived
    }
}
