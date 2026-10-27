//
//  PgpKeyring.swift
//  KyPost
//
//  The `kypost-pgp-keyring-v1` plaintext a device-envelope v5 carries: the
//  account's complete ring, active key and every retired one. Swift port of
//  kypost-android's pgp/PgpKeyring.kt; the format is the server's
//  (docs/PGP_KEY_LIFECYCLE.md, testdata/pgp-keyring-v1.json).
//
//  Pure: the JSON rules live here, and the packet rules are asked of a
//  `PgpKeyInspecting`, so this file never learns which OpenPGP library is
//  underneath.
//

import Foundation

nonisolated let pgpKeyringFormat = "kypost-pgp-keyring-v1"
/// Plaintext bound, applied before UTF-8 decoding or JSON work.
nonisolated let maxPgpKeyringBytes = 128 * 1024
nonisolated let maxPgpKeyringPrimaries = 16
nonisolated let maxPgpKeyringFingerprints = 256
/// The largest integer every peer, JavaScript included, represents exactly.
nonisolated let maxPgpKeyringGeneration: UInt64 = (1 << 53) - 1

private let ringKeys: Set<String> = [
    "format", "materialGeneration", "activeFingerprint", "keyFingerprints", "keys",
]
private let memberKeys: Set<String> = ["fingerprint", "privateKey"]
private let memberKeysWithRevocation: Set<String> = memberKeys.union(["revocationCertificate"])

/// A validated ring. `original` is the exact plaintext that validated: it, not
/// a re-serialisation, is what the vault seals, so storage is never rebuilt
/// from re-exported keys.
///
/// A value type, so wiping is the holder's job: `EnrollmentSession` copies the
/// bytes into storage it owns and zeroes them at every session boundary. The
/// JSON parser's intermediate strings are ordinary heap objects that cannot be
/// zeroed and are simply dropped.
nonisolated struct PgpKeyring: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    nonisolated struct Member: Equatable, Sendable, CustomStringConvertible,
        CustomDebugStringConvertible {
        /// Uppercase, derived from the primary packet, not copied from JSON.
        var fingerprint: String
        /// The member's own armored private key, byte for byte.
        var armor: Data
        var revocationCertificate: String?
        /// Primary and subkeys, as derived from the packets.
        var keyFingerprints: [String]

        var description: String { "PgpKeyring.Member(redacted)" }
        var debugDescription: String { description }
    }

    var original: Data
    var materialGeneration: UInt64
    var activeFingerprint: String
    /// Every primary and subkey fingerprint, uppercase.
    var keyFingerprints: Set<String>
    var members: [Member]

    /// Validation guarantees exactly one.
    var active: Member {
        members.first { $0.fingerprint == activeFingerprint } ?? members[0]
    }

    var primaryFingerprints: Set<String> { Set(members.map(\.fingerprint)) }

    var description: String { "PgpKeyring(redacted)" }
    var debugDescription: String { description }
}

/// Nil for anything that is not a complete, self-consistent ring whose active
/// key is `expectedActiveFingerprint` — the fingerprint the caller committed to
/// in the envelope AAD, normalised the same way.
///
/// Self-consistency alone is not enough: every AAD input is public, so a ring
/// that merely agrees with itself could name any active key its author
/// controls. In order: the plaintext bound, strict UTF-8, duplicate JSON keys,
/// the exact field set and types, the inventory and its counts, then each
/// member's packets — one unprotected private key per entry whose derived
/// fingerprints, taken together, are exactly the inventory. Nothing here
/// touches the vault or the session.
nonisolated func parsePgpKeyring(
    _ plaintext: Data,
    expectedActiveFingerprint: String,
    inspector: any PgpKeyInspecting
) -> PgpKeyring? {
    let expected = expectedActiveFingerprint.uppercased().filter { !$0.isWhitespace }
    guard isKeyringFingerprint(expected) else { return nil }
    return parseRing(plaintext, expected: expected, inspector: inspector)
}

/// For bytes this device sealed after `parsePgpKeyring` validated them: the
/// record is this device's own, so the ring's own active key is the committed
/// one. Never for material arriving from outside.
nonisolated func reopenPgpKeyring(
    _ plaintext: Data,
    inspector: any PgpKeyInspecting
) -> PgpKeyring? {
    parseRing(plaintext, expected: nil, inspector: inspector)
}

private nonisolated func parseRing(
    _ plaintext: Data,
    expected: String?,
    inspector: any PgpKeyInspecting
) -> PgpKeyring? {
    guard !plaintext.isEmpty, plaintext.count <= maxPgpKeyringBytes,
          // Malformed sequences are refused rather than replaced: a
          // substituted character would let two byte strings validate as one.
          String(data: plaintext, encoding: .utf8) != nil,
          !jsonHasDuplicateKeys(plaintext),
          let root = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
          Set(root.keys) == ringKeys,
          root["format"] as? String == pgpKeyringFormat,
          let generationNumber = root["materialGeneration"] as? NSNumber,
          let generation = jsonUnsignedInteger(generationNumber),
          (1...maxPgpKeyringGeneration).contains(generation),
          let activeFingerprint = keyringFingerprint(root["activeFingerprint"])
    else { return nil }
    if let expected, activeFingerprint != expected { return nil }

    guard let inventory = root["keyFingerprints"] as? [Any],
          !inventory.isEmpty, inventory.count <= maxPgpKeyringFingerprints
    else { return nil }
    var declared = Set<String>()
    for entry in inventory {
        guard let fingerprint = keyringFingerprint(entry),
              declared.insert(fingerprint).inserted
        else { return nil }
    }

    guard let entries = root["keys"] as? [Any],
          !entries.isEmpty, entries.count <= maxPgpKeyringPrimaries
    else { return nil }
    var members: [PgpKeyring.Member] = []
    var derived = Set<String>()
    for entry in entries {
        guard let object = entry as? [String: Any],
              let member = parseMember(object, inspector: inspector),
              !members.contains(where: { $0.fingerprint == member.fingerprint })
        else { return nil }
        for fingerprint in member.keyFingerprints {
            guard derived.insert(fingerprint).inserted else { return nil }
        }
        members.append(member)
    }
    guard derived == declared,
          members.filter({ $0.fingerprint == activeFingerprint }).count == 1
    else { return nil }

    return PgpKeyring(
        original: plaintext,
        materialGeneration: generation,
        activeFingerprint: activeFingerprint,
        keyFingerprints: derived,
        members: members
    )
}

private nonisolated func parseMember(
    _ object: [String: Any],
    inspector: any PgpKeyInspecting
) -> PgpKeyring.Member? {
    let keys = Set(object.keys)
    guard keys == memberKeys || keys == memberKeysWithRevocation,
          let declared = keyringFingerprint(object["fingerprint"]),
          let privateKey = object["privateKey"] as? String
    else { return nil }
    var revocation: String?
    if keys.contains("revocationCertificate") {
        guard let text = object["revocationCertificate"] as? String, !text.isEmpty else {
            return nil
        }
        revocation = text
    }
    let armor = Data(privateKey.utf8)
    guard let inventory = inspector.inspectPrivateKey(armored: armor),
          inventory.primaryFingerprint == declared
    else { return nil }
    return PgpKeyring.Member(
        fingerprint: declared,
        armor: armor,
        revocationCertificate: revocation,
        keyFingerprints: inventory.keyFingerprints
    )
}

/// Uppercase for comparison; the reader is case-insensitive, and duplicates
/// are caught after that.
private nonisolated func keyringFingerprint(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let upper = text.uppercased()
    return isKeyringFingerprint(upper) ? upper : nil
}

private nonisolated func isKeyringFingerprint(_ text: String) -> Bool {
    (text.utf8.count == 40 || text.utf8.count == 64)
        && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) }
}

/// A JSON integer token — not a boolean, not `2.0`, not negative.
private nonisolated func jsonUnsignedInteger(_ number: NSNumber) -> UInt64? {
    guard CFGetTypeID(number) != CFBooleanGetTypeID(),
          !CFNumberIsFloatType(number as CFNumber),
          number.int64Value >= 0
    else { return nil }
    return UInt64(number.int64Value)
}

/// Foundation keeps one of two equal keys and says nothing; an inventory or
/// member list stated twice must not parse at all. Keys are compared as source
/// bytes, so a key carrying any escape counts as a duplicate too: no accepted
/// key needs one, and an escaped spelling would otherwise merge unseen with
/// the plain one. True on malformed input as well.
nonisolated func jsonHasDuplicateKeys(_ data: Data) -> Bool {
    let bytes = [UInt8](data)
    var objects: [Set<[UInt8]>?] = []
    var expectKey = false
    var index = 0
    while index < bytes.count {
        switch bytes[index] {
        case UInt8(ascii: "\""):
            var end = index + 1
            var escaped = false
            while true {
                guard end < bytes.count else { return true }
                if bytes[end] == UInt8(ascii: "\"") { break }
                if bytes[end] == UInt8(ascii: "\\") { escaped = true; end += 1 }
                end += 1
            }
            if expectKey {
                guard !escaped, var keys = objects.last ?? nil else { return true }
                guard keys.insert(Array(bytes[(index + 1)..<end])).inserted else { return true }
                objects[objects.count - 1] = keys
                expectKey = false
            }
            index = end
        case UInt8(ascii: "{"):
            objects.append([])
            expectKey = true
        case UInt8(ascii: "["):
            objects.append(nil)
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            guard !objects.isEmpty else { return true }
            objects.removeLast()
        case UInt8(ascii: ","):
            if let last = objects.last, last != nil { expectKey = true }
        default:
            break
        }
        index += 1
    }
    return false
}
