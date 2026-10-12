//
//  OpenPgpKeySections.swift
//  KyPost
//
//  Packet-level plumbing for `PgpKeyRevocation.withVerifiedRevocation`: split
//  one transferable public key into its primary and subkey sections, find the
//  revocation signatures a synced copy carries that the pinned copy does not,
//  and rebuild key bytes with chosen signatures added.
//
//  **Nothing here decides that a revocation is genuine.** It only moves
//  packets; the crypto implementation verifies every candidate against the
//  pinned primary before one is kept. No crypto import, by design — see
//  `PgpCrypto.swift`.
//

import Foundation

nonisolated struct OpenPgpPacket: Equatable, Sendable {
    var tag: UInt8
    var body: Data
    /// Header and body, exactly as read.
    var raw: Data

    /// The signature type of a signature packet (tag 2), nil otherwise. v4/v6
    /// carry it in the second octet; v3 after a one-octet hashed length.
    var signatureType: UInt8? {
        guard tag == 2, let version = body.first else { return nil }
        let offset = version == 3 ? 2 : 1
        guard body.count > offset else { return nil }
        return body[body.startIndex + offset]
    }

    static let keyRevocation: UInt8 = 0x20
    static let subkeyRevocation: UInt8 = 0x28
}

nonisolated struct OpenPgpKeySections: Equatable, Sendable {
    /// The primary key packet and everything up to the first subkey.
    var primary: [OpenPgpPacket]
    /// Each subkey packet (tag 14) with the packets that follow it.
    var subkeys: [[OpenPgpPacket]]

    /// One public key and nothing else: the primary key packet first, no
    /// second primary, no secret-key packets. Anything else is refused rather
    /// than guessed at — the same rule as `PgpFingerprint`.
    init?(armored: String) {
        guard let data = PgpFingerprint.dearmor(armored) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        var packets: [OpenPgpPacket] = []
        while index < bytes.count {
            let start = index
            guard let packet = PgpFingerprint.nextPacket(in: bytes, at: &index) else { return nil }
            packets.append(OpenPgpPacket(tag: packet.tag, body: packet.body, raw: Data(bytes[start..<index])))
        }
        guard let first = packets.first, first.tag == 6,
              !packets.dropFirst().contains(where: { [5, 6, 7].contains($0.tag) })
        else { return nil }

        var primary: [OpenPgpPacket] = []
        var subkeys: [[OpenPgpPacket]] = []
        for packet in packets {
            if packet.tag == 14 {
                subkeys.append([packet])
            } else if subkeys.isEmpty {
                primary.append(packet)
            } else {
                subkeys[subkeys.count - 1].append(packet)
            }
        }
        self.primary = primary
        self.subkeys = subkeys
    }

    init(primary: [OpenPgpPacket], subkeys: [[OpenPgpPacket]]) {
        self.primary = primary
        self.subkeys = subkeys
    }

    var primaryKeyBody: Data { primary[0].body }

    var data: Data {
        (primary + subkeys.flatMap { $0 }).reduce(into: Data()) { $0.append($1.raw) }
    }

    /// Where a candidate revocation would go.
    enum Target: Equatable, Sendable {
        case primary
        case subkey(Int)
    }

    struct Candidate: Equatable, Sendable {
        var target: Target
        var signature: OpenPgpPacket
    }

    /// Revocations `synced` carries for this key's primary or for subkeys this
    /// key already holds (matched by key-packet bytes, which is what a
    /// fingerprint is computed over), minus any already present. Nil when the
    /// two are not the same primary key. Never offers a subkey, user id or any
    /// other packet: a synced copy can withdraw pinned keys, not change them.
    func revocationCandidates(from synced: OpenPgpKeySections) -> [Candidate]? {
        guard primaryKeyBody == synced.primaryKeyBody else { return nil }
        var candidates: [Candidate] = []

        let heldPrimary = Set(primary.map(\.raw))
        for packet in synced.primary
        where packet.signatureType == OpenPgpPacket.keyRevocation && !heldPrimary.contains(packet.raw) {
            candidates.append(Candidate(target: .primary, signature: packet))
        }

        for (index, section) in subkeys.enumerated() {
            guard let match = synced.subkeys.first(where: { $0[0].body == section[0].body }) else { continue }
            let held = Set(section.map(\.raw))
            for packet in match
            where packet.signatureType == OpenPgpPacket.subkeyRevocation && !held.contains(packet.raw) {
                candidates.append(Candidate(target: .subkey(index), signature: packet))
            }
        }
        return candidates
    }

    /// This key with `candidates` added: primary revocations straight after
    /// the primary key packet, subkey revocations at the end of their section
    /// (RFC 9580 §10.1 order).
    func adding(_ candidates: [Candidate]) -> OpenPgpKeySections {
        var copy = self
        for candidate in candidates {
            switch candidate.target {
            case .primary:
                copy.primary.insert(candidate.signature, at: 1)
            case .subkey(let index):
                copy.subkeys[index].append(candidate.signature)
            }
        }
        return copy
    }

    /// The primary section with one subkey section only — so a check of what
    /// the key can still do speaks for that subkey alone.
    func isolating(subkey index: Int) -> OpenPgpKeySections {
        OpenPgpKeySections(primary: primary, subkeys: [subkeys[index]])
    }
}
