//
//  PgpFingerprint.swift
//  KyPost
//
//  Locally computed OpenPGP v4 fingerprints (security-hardening plan,
//  Task 10). A compromised relay could pair an armored key with an
//  unrelated fingerprint string, making the out-of-band "does this match?"
//  check verify a label with no cryptographic tie to the key actually
//  saved. Computing from the key's own bytes closes that.
//
//  V4 fingerprint = SHA-1 over 0x99 || 2-byte length || public-key packet
//  body (RFC 4880 §12.2). SHA-1 here is mandated by the OpenPGP spec, not
//  a hashing choice this app owns.
//
//  V6 fingerprint = SHA-256 over 0x9B || 4-byte length || public-key packet
//  body (RFC 9580 §5.5.4). Supported because GnuPG 2.5 and Sequoia emit v6
//  keys today: without it a contact with a current key rendered as an
//  unreadable one, and a scanned v6 code told the user to fetch a fresh
//  code that would fail exactly the same way.
//
//  Anything malformed or of an unknown version returns nil — never
//  trust-and-fall-back to the relay's string.
//

import CryptoKit
import Foundation

nonisolated enum PgpFingerprint {
    /// Uppercase hex fingerprint of the first public-key packet in an
    /// armored key, or nil when the armor or packet stream is malformed or
    /// the key version is one this app cannot fingerprint.
    static func compute(fromArmored armored: String) -> String? {
        guard
            let data = dearmor(armored),
            let body = firstPublicKeyPacketBody(in: data)
        else { return nil }
        return fingerprint(ofKeyPacketBody: body)
    }

    /// The fingerprint of one public-key or public-subkey packet body (tag 6
    /// or 14), uppercase hex. Also the fingerprint of the public prefix of a
    /// secret-key packet, which is how a private key's members are named from
    /// their own packets rather than from anything beside them.
    static func fingerprint(ofKeyPacketBody body: Data) -> String? {
        guard let version = body.first else { return nil }
        switch version {
        case 4:
            guard body.count <= Int(UInt16.max) else { return nil }
            var message = Data([0x99, UInt8(body.count >> 8), UInt8(body.count & 0xFF)])
            message.append(body)
            return Insecure.SHA1.hash(data: message)
                .map { String(format: "%02X", $0) }
                .joined()
        case 6:
            guard body.count <= Int(UInt32.max) else { return nil }
            let length = UInt32(body.count)
            var message = Data([
                0x9B,
                UInt8(truncatingIfNeeded: length >> 24),
                UInt8(truncatingIfNeeded: length >> 16),
                UInt8(truncatingIfNeeded: length >> 8),
                UInt8(truncatingIfNeeded: length),
            ])
            message.append(body)
            return SHA256.hash(data: message)
                .map { String(format: "%02X", $0) }
                .joined()
        default:
            // v3 and v5 use derivations this app does not implement, and an
            // unknown version is not something to guess at.
            return nil
        }
    }

    /// Strips the BEGIN/END lines, armor headers ("Version: …" up to the
    /// blank line), and the "=" CRC24 line, then base64-decodes the rest.
    static func dearmor(_ armored: String) -> Data? {
        let lines = armored
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard
            let begin = lines.firstIndex(of: "-----BEGIN PGP PUBLIC KEY BLOCK-----"),
            let end = lines[begin...].firstIndex(of: "-----END PGP PUBLIC KEY BLOCK-----"),
            end > begin + 1
        else { return nil }

        var base64 = ""
        var inHeaders = true
        for line in lines[(begin + 1)..<end] {
            if inHeaders {
                if line.isEmpty || line.contains(":") { continue }
                inHeaders = false
            }
            if line.isEmpty || line.hasPrefix("=") { continue }
            base64 += line
        }
        guard !base64.isEmpty else { return nil }
        return Data(base64Encoded: base64)
    }

    /// Strictly one armor block of `blockType` (e.g. "PGP PRIVATE KEY BLOCK"),
    /// with nothing but whitespace around it, decoded to its binary packets.
    ///
    /// Stricter than `dearmor`, which tolerates surrounding text: a member of
    /// a keyring must be exactly one key, and a second block or trailing junk
    /// is exactly the ambiguity that let a decoy key be fingerprinted while a
    /// different one was used.
    static func dearmorSingleBlock(_ armored: String, blockType: String) -> Data? {
        let begin = "-----BEGIN \(blockType)-----"
        let end = "-----END \(blockType)-----"
        let lines = armored
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let content = lines.drop(while: \.isEmpty)
        guard content.first == begin,
              let endIndex = content.firstIndex(of: end),
              content[content.index(after: endIndex)...].allSatisfy(\.isEmpty),
              lines.filter({ $0.hasPrefix("-----") }).count == 2
        else { return nil }

        var base64 = ""
        var inHeaders = true
        for line in content[content.index(after: content.startIndex)..<endIndex] {
            if inHeaders {
                if line.isEmpty { inHeaders = false; continue }
                if line.contains(":") { continue }
                inHeaders = false
            }
            if line.isEmpty || line.hasPrefix("=") { continue }
            base64 += line
        }
        guard !base64.isEmpty, let data = Data(base64Encoded: base64), !data.isEmpty else {
            return nil
        }
        return data
    }

    /// Every packet in `data` as (tag, body), or nil if any header is
    /// malformed or a length runs past the end. Partial and indeterminate
    /// lengths are refused, as they are for key material everywhere here.
    static func packets(in data: Data) -> [(tag: UInt8, body: Data)]? {
        let bytes = [UInt8](data)
        var index = 0
        var result: [(tag: UInt8, body: Data)] = []
        while index < bytes.count {
            guard let packet = nextPacket(in: bytes, at: &index) else { return nil }
            result.append(packet)
        }
        return result
    }

    /// Packet types legal inside one transferable public key after the primary
    /// key packet: user id (13), signature (2), public subkey (14), user
    /// attribute (17), trust (12), padding (21, RFC 9580 §5.14), and the
    /// experimental range's 61 as seen in the wild.
    private static let transferableKeyTags: Set<UInt8> = [13, 2, 14, 17, 12, 21, 61]

    /// Body of the primary public-key packet of a *single* transferable public
    /// key (RFC 4880 §11.1), or nil.
    ///
    /// The packet must be first in the stream and must be the only tag 6:
    /// scanning for the first tag-6 packet anywhere in the blob is not the
    /// same thing as identifying the key a consumer will use. An armored blob
    /// that merely *contains* a key packet — a bare tag 6 prepended to a
    /// complete second key — made this return the decoy's fingerprint while
    /// Go's `openpgp.ReadKeyRing` skipped the identity-less leading entity and
    /// selected the second key. The user then verified one key's fingerprint
    /// out of band while mail was encrypted to the other. Refuse anything that
    /// isn't unambiguously one key.
    static func firstPublicKeyPacketBody(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var index = 0
        var primary: Data?

        while index < bytes.count {
            guard let packet = nextPacket(in: bytes, at: &index) else { return nil }

            guard primary != nil else {
                // The primary key packet must open the stream.
                guard packet.tag == 6 else { return nil }
                primary = packet.body
                continue
            }

            // A second tag 6 is a second key in the blob; anything outside the
            // transferable-key set isn't part of this key. Either way we can't
            // say which key a consumer would pick, so we don't guess.
            guard transferableKeyTags.contains(packet.tag) else { return nil }
        }
        return primary
    }

    /// Reads one packet header at `index`, advancing it past the body.
    /// Handles both old- and new-format headers. Partial body lengths and
    /// indeterminate old-format lengths are invalid for key material.
    private static func nextPacket(
        in bytes: [UInt8],
        at index: inout Int
    ) -> (tag: UInt8, body: Data)? {
        guard index < bytes.count else { return nil }
        let header = bytes[index]
        guard header & 0x80 != 0 else { return nil }
        index += 1

        let tag: UInt8
        let length: Int
        if header & 0x40 != 0 {
            // New format: tag in the low six bits, variable-width length.
            tag = header & 0x3F
            guard index < bytes.count else { return nil }
            let first = Int(bytes[index])
            index += 1
            switch first {
            case 0..<192:
                length = first
            case 192...223:
                guard index < bytes.count else { return nil }
                length = ((first - 192) << 8) + Int(bytes[index]) + 192
                index += 1
            case 255:
                guard index + 4 <= bytes.count else { return nil }
                length = bytes[index..<(index + 4)].reduce(0) { ($0 << 8) | Int($1) }
                index += 4
            default:
                return nil // 224–254: partial body lengths
            }
        } else {
            // Old format: tag in bits 5–2, length width in the low two.
            tag = (header >> 2) & 0x0F
            let widths = [1, 2, 4]
            let lengthType = Int(header & 0x03)
            guard lengthType < widths.count else { return nil } // 3: indeterminate
            let width = widths[lengthType]
            guard index + width <= bytes.count else { return nil }
            length = bytes[index..<(index + width)].reduce(0) { ($0 << 8) | Int($1) }
            index += width
        }

        guard length >= 0, index + length <= bytes.count else { return nil }
        let body = Data(bytes[index..<(index + length)])
        index += length
        return (tag, body)
    }
}
