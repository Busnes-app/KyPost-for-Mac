//
//  PgpKeyFloor.swift
//  KyPost
//
//  The OpenPGP key-size floor (docs/STRONG-CRYPTO.md). GopenPGP already
//  refuses DSA, ElGamal and secp256k1, but its RSA minimum is 2047 bits
//  (go-crypto `MinimumRSABits`), and the gomobile binding cannot change it.
//  This closes that gap: every key packet must be RSA of at least 2048 actual
//  bits, or an algorithm whose every size is stronger. Anything else,
//  including a version or algorithm this file does not know, fails.
//

import Foundation

nonisolated enum PgpKeyFloor {
    static let minimumRSABits = 2048

    /// Every primary and subkey packet (tags 5, 6, 7, 14) in `data` meets the
    /// floor, and there is at least one.
    static func meets(keyPackets data: Data) -> Bool {
        guard let packets = PgpFingerprint.packets(in: data) else { return false }
        let keys = packets.filter { [5, 6, 7, 14].contains($0.tag) }
        return !keys.isEmpty && keys.allSatisfy { meets(keyPacketBody: $0.body) }
    }

    /// One key packet body. A secret-key packet starts with its public part.
    static func meets(keyPacketBody body: Data) -> Bool {
        let bytes = [UInt8](body)
        // v4: version, 4-byte time, algorithm, key material.
        // v6: the same, then a 4-byte key material length.
        guard let version = bytes.first else { return false }
        let materialOffset: Int
        switch version {
        case 4: materialOffset = 6
        case 6: materialOffset = 10
        default: return false
        }
        guard bytes.count > materialOffset else { return false }
        switch bytes[5] {
        case 1, 2, 3:
            return (rsaModulusBits(bytes, at: materialOffset) ?? 0) >= minimumRSABits
        // ECDH, ECDSA, EdDSA (legacy), X25519, X448, Ed25519, Ed448: every
        // curve the library accepts is at least 255 bits.
        case 18, 19, 22, 25, 26, 27, 28:
            return true
        // ML-DSA and ML-KEM composites, SLH-DSA.
        case 30...36:
            return true
        default:
            return false
        }
    }

    /// Actual bits of the modulus MPI, not the length it declares: leading
    /// zero octets or bits cannot make a short modulus look long.
    private static func rsaModulusBits(_ bytes: [UInt8], at offset: Int) -> Int? {
        guard offset + 2 <= bytes.count else { return nil }
        let declared = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        let start = offset + 2
        let end = start + (declared + 7) / 8
        guard end <= bytes.count,
              let first = bytes[start..<end].firstIndex(where: { $0 != 0 })
        else { return nil }
        return (end - first) * 8 - bytes[first].leadingZeroBitCount
    }
}
