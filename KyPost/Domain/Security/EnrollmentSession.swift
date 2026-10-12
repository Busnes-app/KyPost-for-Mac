//
//  EnrollmentSession.swift
//  KyPost
//
//  Holds the opened OpenPGP material for one unlock session. Swift port of
//  kypost-android's pgp/EnrollmentSession.kt.
//
//  The plaintext lifetime is the real exposure, not how often the biometric
//  prompt appears — so the window is the one the user already configured under
//  "Lock after: …" rather than a second concept of its own.
//
//  Held as bytes so `clear()` can zero them. A `String`'s storage cannot be
//  wiped: one would survive in the heap until the collector got to it, and in
//  any dump taken after the app locked. That covers **every** key of a held
//  keyring, not just the active one, and the keyring's original bytes.
//

import Foundation
import Synchronization

/// What the vault held once opened: legacy armor (one key, or a current-first
/// collection of current and retired keys) or one validated complete ring.
nonisolated enum VaultMaterial: Equatable, Sendable {
    case legacyArmor(Data)
    case keyring(PgpKeyring)
}

/// Scoped access to held material. Every buffer is a copy, zeroed when the
/// closure returns.
nonisolated struct HeldKeyMaterial: Sendable {
    /// Every private key that may decrypt — a keyring's members in order, or
    /// the legacy collection whole. History is retained for old mail, and a
    /// hidden recipient can only be found by trying them all.
    var decryptionKeys: [Data]
    /// The one key that signs and that self-encryption targets: a keyring's
    /// explicit active member, or a legacy collection whose first key is the
    /// current one. A historical member is never substituted.
    var signingKey: Data
    /// The held keyring's generation; nil for legacy armor, which has none.
    var materialGeneration: UInt64?
}

/// Process-wide holder for the unsealed private key material.
///
/// A `final class` with a lock rather than an actor: every caller is already on
/// the main actor or inside a synchronous decrypt, and an actor would make
/// `isHeld` an `await` — which is exactly the kind of suspension point that
/// invites a caller to check presence, hop, and then act on a key that was
/// cleared in between.
nonisolated final class EnrollmentSession: Sendable {
    static let shared = EnrollmentSession()

    private let state = Mutex(Storage())

    /// Plain stored fields rather than an enum with payloads: binding a payload
    /// copies the array reference, and zeroing that copy triggers copy-on-write
    /// and leaves the original buffer intact. Mutating a stored property of
    /// uniquely held storage is in place.
    private struct Storage {
        enum Kind { case legacy, keyring }
        var kind: Kind?
        var legacy: [UInt8] = []
        var original: [UInt8] = []
        var members: [[UInt8]] = []
        var activeIndex = 0
        var generation: UInt64?

        mutating func wipe() {
            legacy.zeroAll()
            original.zeroAll()
            for index in members.indices { members[index].zeroAll() }
            legacy = []
            original = []
            members = []
            activeIndex = 0
            generation = nil
            kind = nil
        }
    }

    /// True while material is held, **without minting a copy to answer it.**
    var isHeld: Bool {
        state.withLock { $0.kind != nil }
    }

    /// The held keyring's generation; nil when nothing or legacy armor is held.
    var materialGeneration: UInt64? {
        state.withLock { $0.kind == .keyring ? $0.generation : nil }
    }

    /// Clears first, so replacing material does not strand the previous copy.
    func put(armoredKey: String) {
        put(legacyArmor: Data(armoredKey.utf8))
    }

    func put(legacyArmor: Data) {
        state.withLock {
            $0.wipe()
            $0.legacy = Array(legacyArmor)
            $0.kind = .legacy
        }
    }

    /// Installs a validated ring. Only ever called with a ring that is already
    /// durably sealed, or one just reopened from that seal.
    func put(keyring: PgpKeyring) {
        let activeIndex = keyring.members.firstIndex { $0.fingerprint == keyring.activeFingerprint } ?? 0
        state.withLock {
            $0.wipe()
            $0.original = Array(keyring.original)
            $0.members = keyring.members.map { Array($0.armor) }
            $0.activeIndex = activeIndex
            $0.generation = keyring.materialGeneration
            $0.kind = .keyring
        }
    }

    func install(_ material: VaultMaterial) {
        switch material {
        case .legacyArmor(let data): put(legacyArmor: data)
        case .keyring(let ring): put(keyring: ring)
        }
    }

    /// True when the held keyring is byte-for-byte `original`. Equal
    /// inventories or active keys prove nothing about certifications or
    /// revocations; only identical bytes are known to be the same ring.
    func holdsKeyring(identicalTo original: Data) -> Bool {
        state.withLock { $0.kind == .keyring && $0.original.elementsEqual(original) }
    }

    /// Lends the material for the duration of `body`.
    ///
    /// Scoped rather than returned so no copy outlives the call that needed it.
    /// The bytes handed over are still copies — the crypto library takes
    /// `Data`, and there is no way to feed it storage this type controls — but
    /// their lifetime is one operation rather than the life of the session.
    func withMaterial<T>(_ body: (HeldKeyMaterial?) throws -> T) rethrows -> T {
        try state.withLock { storage in
            switch storage.kind {
            case nil:
                return try body(nil)
            case .legacy:
                var copy = Data(storage.legacy)
                defer { copy.resetBytes(in: 0..<copy.count) }
                return try body(HeldKeyMaterial(
                    decryptionKeys: [copy],
                    signingKey: copy,
                    materialGeneration: nil
                ))
            case .keyring:
                var copies = storage.members.map { Data($0) }
                defer {
                    for index in copies.indices {
                        copies[index].resetBytes(in: 0..<copies[index].count)
                    }
                }
                return try body(HeldKeyMaterial(
                    decryptionKeys: copies,
                    signingKey: copies[storage.activeIndex],
                    materialGeneration: storage.generation
                ))
            }
        }
    }

    /// The signing key alone — see `HeldKeyMaterial.signingKey`.
    func withKey<T>(_ body: (Data?) throws -> T) rethrows -> T {
        try withMaterial { try body($0?.signingKey) }
    }

    /// Zeroes every held buffer and forgets them.
    ///
    /// Every session boundary must call this: the app lock, backgrounding,
    /// memory pressure, a security wipe, and unpairing. On Android the
    /// equivalent holder was missed by the wipe path, which then reported
    /// "Complete" with the account's private key still in the process heap —
    /// the failure this comment exists to stop recurring here.
    func clear() {
        state.withLock { $0.wipe() }
    }
}

private extension Array where Element == UInt8 {
    /// Overwrites in place. Assigning a fresh array would leave the old buffer
    /// intact for the allocator to hand out.
    mutating func zeroAll() {
        for index in indices { self[index] = 0 }
    }
}
