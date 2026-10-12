//
//  OpenPgpRevocationSignature.swift
//  KyPost
//
//  Checks one v4 key-revocation or subkey-revocation signature against the
//  pinned primary key, for `GopenPGPCrypto.withVerifiedRevocation`. The
//  crypto library verifies a revocation only as part of a whole key and
//  reports the result as a capability, which cannot tell every genuine
//  revocation apart; this answers the narrower question directly.
//
//  **This decides what may be stored in a pin, never what is trusted.** The
//  library re-verifies every revocation it finds in the pin each time the key
//  is used, so a signature accepted here and rejected there changes nothing.
//  Anything this does not support (other versions, algorithms or hashes)
//  returns false and the caller falls back to the library's own observation.
//
//  RFC 4880 §5.2.4 (hashing), §5.5.2 (v4 key material); RFC 6637 (ECDSA);
//  RFC 9580 §5.5.5 (EdDSALegacy, Ed25519).
//

import CryptoKit
import Foundation
import Security

nonisolated enum OpenPgpRevocationSignature {
    /// True only when `signature` — a v4 signature packet body of the given
    /// type — verifies under the key in `signerKeyBody` over `keyBodies`
    /// (the primary, then the subkey for a subkey revocation), all v4.
    static func verifies(signature: Data, signerKeyBody: Data, over keyBodies: [Data]) -> Bool {
        guard let parsed = Parsed(signature),
              let key = PublicKey(signerKeyBody),
              key.algorithm == parsed.publicKeyAlgorithm,
              !keyBodies.isEmpty
        else { return false }

        var hashed = Data()
        for body in keyBodies {
            guard body.first == 4, body.count <= Int(UInt16.max) else { return false }
            hashed.append(contentsOf: [0x99, UInt8(body.count >> 8), UInt8(body.count & 0xFF)])
            hashed.append(body)
        }
        hashed.append(parsed.hashedPrefix)
        let length = UInt32(parsed.hashedPrefix.count)
        hashed.append(contentsOf: [
            0x04, 0xFF,
            UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
        ])

        guard let digest = Self.digest(algorithm: parsed.hashAlgorithm, of: hashed),
              digest.prefix(2) == parsed.left16
        else { return false }
        return key.verify(
            hashedData: hashed, digest: digest, hashAlgorithm: parsed.hashAlgorithm, material: parsed.material
        )
    }

    /// SHA-256, -384 and -512 only. Anything older or rarer is left to the
    /// library's observation path.
    private static func digest(algorithm: UInt8, of data: Data) -> Data? {
        switch algorithm {
        case 8: Data(SHA256.hash(data: data))
        case 9: Data(SHA384.hash(data: data))
        case 10: Data(SHA512.hash(data: data))
        default: nil
        }
    }

    // MARK: - Signature packet

    private struct Parsed {
        var publicKeyAlgorithm: UInt8
        var hashAlgorithm: UInt8
        /// Version through the end of the hashed subpackets.
        var hashedPrefix: Data
        var left16: Data
        var material: [UInt8]

        init?(_ body: Data) {
            let bytes = [UInt8](body)
            guard bytes.count >= 6, bytes[0] == 4,
                  bytes[1] == OpenPgpPacket.keyRevocation || bytes[1] == OpenPgpPacket.subkeyRevocation
            else { return nil }
            let hashedEnd = 6 + (Int(bytes[4]) << 8 | Int(bytes[5]))
            guard hashedEnd + 2 <= bytes.count else { return nil }
            let unhashedEnd = hashedEnd + 2 + (Int(bytes[hashedEnd]) << 8 | Int(bytes[hashedEnd + 1]))
            guard unhashedEnd + 2 <= bytes.count else { return nil }
            publicKeyAlgorithm = bytes[2]
            hashAlgorithm = bytes[3]
            hashedPrefix = Data(bytes[0..<hashedEnd])
            left16 = Data(bytes[unhashedEnd..<(unhashedEnd + 2)])
            material = Array(bytes[(unhashedEnd + 2)...])
        }
    }

    // MARK: - Key material

    private enum Curve {
        case p256, p384, p521

        static func from(oid: [UInt8]) -> Curve? {
            switch oid {
            case [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]: .p256
            case [0x2B, 0x81, 0x04, 0x00, 0x22]: .p384
            case [0x2B, 0x81, 0x04, 0x00, 0x23]: .p521
            default: nil
            }
        }

        var coordinateLength: Int {
            switch self {
            case .p256: 32
            case .p384: 48
            case .p521: 66
            }
        }
    }

    private static let ed25519LegacyOID: [UInt8] = [0x2B, 0x06, 0x01, 0x04, 0x01, 0xDA, 0x47, 0x0F, 0x01]

    private enum PublicKey {
        case rsa(algorithm: UInt8, modulus: [UInt8], exponent: [UInt8])
        case ecdsa(Curve, point: [UInt8])
        case ed25519(algorithm: UInt8, point: [UInt8])

        var algorithm: UInt8 {
            switch self {
            case .rsa(let algorithm, _, _): algorithm
            case .ecdsa: 19
            case .ed25519(let algorithm, _): algorithm
            }
        }

        init?(_ body: Data) {
            var reader = Reader([UInt8](body))
            guard reader.byte() == 4, reader.bytes(4) != nil, let algorithm = reader.byte() else { return nil }
            switch algorithm {
            case 1, 3:
                guard let modulus = reader.mpi(), let exponent = reader.mpi(),
                      !modulus.isEmpty, !exponent.isEmpty
                else { return nil }
                self = .rsa(algorithm: algorithm, modulus: modulus, exponent: exponent)
            case 19:
                guard let oid = reader.oid(), let curve = Curve.from(oid: oid),
                      let point = reader.mpi(),
                      point.count == 1 + 2 * curve.coordinateLength, point.first == 0x04
                else { return nil }
                self = .ecdsa(curve, point: point)
            case 22:
                guard reader.oid() == OpenPgpRevocationSignature.ed25519LegacyOID,
                      let point = reader.mpi(), point.count == 33, point.first == 0x40
                else { return nil }
                self = .ed25519(algorithm: 22, point: Array(point.dropFirst()))
            case 27:
                guard let point = reader.bytes(32) else { return nil }
                self = .ed25519(algorithm: 27, point: point)
            default:
                return nil
            }
        }

        func verify(hashedData: Data, digest: Data, hashAlgorithm: UInt8, material: [UInt8]) -> Bool {
            var reader = Reader(material)
            switch self {
            case .rsa(_, let modulus, let exponent):
                guard let signature = reader.mpi(), reader.isAtEnd,
                      let padded = leftPad(signature, to: modulus.count),
                      let key = Self.rsaKey(modulus: modulus, exponent: exponent)
                else { return false }
                let algorithm: SecKeyAlgorithm
                switch hashAlgorithm {
                case 8: algorithm = .rsaSignatureDigestPKCS1v15SHA256
                case 9: algorithm = .rsaSignatureDigestPKCS1v15SHA384
                case 10: algorithm = .rsaSignatureDigestPKCS1v15SHA512
                default: return false
                }
                return SecKeyVerifySignature(key, algorithm, digest as CFData, Data(padded) as CFData, nil)

            case .ecdsa(let curve, let point):
                guard let r = reader.mpi(), let s = reader.mpi(), reader.isAtEnd,
                      let r = leftPad(r, to: curve.coordinateLength),
                      let s = leftPad(s, to: curve.coordinateLength)
                else { return false }
                let raw = Data(r + s)
                // Each curve with its own-size hash only. A truncated longer
                // hash is legal ECDSA but is left to the library's path.
                switch (curve, hashAlgorithm) {
                case (.p256, 8):
                    guard let key = try? P256.Signing.PublicKey(x963Representation: point),
                          let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw)
                    else { return false }
                    return key.isValidSignature(signature, for: SHA256.hash(data: hashedData))
                case (.p384, 9):
                    guard let key = try? P384.Signing.PublicKey(x963Representation: point),
                          let signature = try? P384.Signing.ECDSASignature(rawRepresentation: raw)
                    else { return false }
                    return key.isValidSignature(signature, for: SHA384.hash(data: hashedData))
                case (.p521, 10):
                    guard let key = try? P521.Signing.PublicKey(x963Representation: point),
                          let signature = try? P521.Signing.ECDSASignature(rawRepresentation: raw)
                    else { return false }
                    return key.isValidSignature(signature, for: SHA512.hash(data: hashedData))
                default:
                    return false
                }

            case .ed25519(let algorithm, let point):
                let signature: [UInt8]
                if algorithm == 22 {
                    guard let r = reader.mpi(), let s = reader.mpi(), reader.isAtEnd,
                          let r = leftPad(r, to: 32), let s = leftPad(s, to: 32)
                    else { return false }
                    signature = r + s
                } else {
                    guard let raw = reader.bytes(64), reader.isAtEnd else { return false }
                    signature = raw
                }
                // OpenPGP's EdDSA signs the hash digest, not the data.
                guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: point) else { return false }
                return key.isValidSignature(Data(signature), for: digest)
            }
        }

        /// PKCS#1 `RSAPublicKey` DER, which is what `SecKeyCreateWithData`
        /// takes for an RSA public key.
        private static func rsaKey(modulus: [UInt8], exponent: [UInt8]) -> SecKey? {
            let der = derSequence(derInteger(modulus) + derInteger(exponent))
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPublic,
            ]
            return SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, nil)
        }

        private static func derLength(_ count: Int) -> [UInt8] {
            if count < 0x80 { return [UInt8(count)] }
            var bytes: [UInt8] = []
            var value = count
            while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }

        private static func derInteger(_ magnitude: [UInt8]) -> [UInt8] {
            let value = magnitude.first.map { $0 & 0x80 != 0 } == true ? [0] + magnitude : magnitude
            return [0x02] + derLength(value.count) + value
        }

        private static func derSequence(_ content: [UInt8]) -> [UInt8] {
            [0x30] + derLength(content.count) + content
        }
    }

    // MARK: - Reading

    /// A big-endian magnitude left-padded with zeros, or nil when it is
    /// longer than `length`.
    private static func leftPad(_ value: [UInt8], to length: Int) -> [UInt8]? {
        guard value.count <= length else { return nil }
        return [UInt8](repeating: 0, count: length - value.count) + value
    }

    private struct Reader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { index == bytes.count }

        mutating func byte() -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func bytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, index + count <= bytes.count else { return nil }
            defer { index += count }
            return Array(bytes[index..<(index + count)])
        }

        /// One MPI's magnitude, leading zero octets removed.
        mutating func mpi() -> [UInt8]? {
            guard let high = byte(), let low = byte() else { return nil }
            let bits = Int(high) << 8 | Int(low)
            guard let value = bytes((bits + 7) / 8) else { return nil }
            return Array(value.drop(while: { $0 == 0 }))
        }

        /// A one-octet length-prefixed curve OID.
        mutating func oid() -> [UInt8]? {
            guard let length = byte(), length > 0, length < 0xFF else { return nil }
            return bytes(Int(length))
        }
    }
}
