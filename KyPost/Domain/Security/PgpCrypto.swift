//
//  PgpCrypto.swift
//  KyPost
//
//  The seam between this app and whatever OpenPGP implementation backs it.
//
//  **Nothing outside this file's conforming types may reference the crypto
//  library.** GopenPGP's v2→v3 API break is recent enough that a swap should
//  touch one file, and the call sites — the reader, compose, and the signature
//  binding — should never have known which library was underneath.
//

import Foundation

/// A decrypted message body plus what the signature over it claimed.
nonisolated struct DecryptedMessage: Equatable, Sendable {
    var body: Data
    var signature: RawSignature
}

nonisolated enum PgpCryptoError: Error, Equatable {
    /// The key material did not parse. Never a pass: an unparseable key only
    /// ever shrinks the candidate set.
    case unusableKey
    /// Decryption failed against the key held. Distinct from `unusableKey`
    /// because the remedies differ — one is a wrong key, the other a broken one.
    case cannotDecrypt
    /// Decompressed plaintext exceeded the cap **before** allocation. A zip
    /// bomb in an encrypted message is otherwise an OOM kill.
    case tooLarge
    case cannotEncrypt(String)
    /// No implementation is linked yet.
    case unavailable
}

/// Reading. Implemented against the account's private key once this device
/// holds one.
protocol PgpDecrypting: Sendable {
    /// Decrypts and verifies in one pass. `signerKeys` are the candidate
    /// public keys, already narrowed to the sender by the server.
    ///
    /// `privateKeys` is **every** key this device holds, current and retired:
    /// each element is one armored blob, which may itself be a legacy
    /// collection of several keys. Mail encrypted to a retired key, or to a
    /// hidden recipient, can only be opened by trying them all. A blob that
    /// does not parse only shrinks the set; none parsing is `unusableKey`.
    func decrypt(
        armoredCiphertext: String,
        privateKeys: [Data],
        signerKeys: [String]
    ) throws -> DecryptedMessage

    /// Verifies a detached signature over `signedBytes` — the verbatim octets
    /// the signature covers — using the server-narrowed candidate keys. This is
    /// the signed-but-not-encrypted counterpart of `decrypt`.
    ///
    /// Public-key only: it needs no private key, so the reader can call it
    /// without unsealing the vault. It reports on the same terms `decrypt` sets
    /// for its `RawSignature` — a signature that will not parse is absent, one
    /// with no matching offered key is present but not valid, and only a real
    /// verification against an offered key is a pass.
    func verifyDetached(
        signedBytes: Data,
        armoredSignature: String,
        signerKeys: [String]
    ) -> RawSignature

    /// The entity fingerprint of an armored public key — the primary's,
    /// whichever component of it might sign.
    ///
    /// Attribution is deliberately entity-level rather than key-id level. A
    /// signature packet names its *issuer*, which is a signing subkey's id
    /// whenever a subkey signed, and no public key can be asked for its
    /// subkeys' ids through this library: the key-id list it exposes reports
    /// one primary id per entity. Matching issuer against that list rejects
    /// every subkey-signed message, silently and always as "unknown signer".
    ///
    /// Returns nil for a key that does not parse. An unparseable key must only
    /// ever shrink the candidate set, never grant a pass.
    func fingerprint(ofArmoredPublicKey key: String) -> String?
}

extension PgpDecrypting {
    /// One armored key or legacy collection.
    func decrypt(
        armoredCiphertext: String,
        privateKey: Data,
        signerKeys: [String]
    ) throws -> DecryptedMessage {
        try decrypt(
            armoredCiphertext: armoredCiphertext,
            privateKeys: [privateKey],
            signerKeys: signerKeys
        )
    }
}

/// What one private key's own packets say about it. Fingerprints are
/// uppercase hex, computed from the key packets — never copied from a field
/// beside them.
nonisolated struct PrivateKeyInventory: Equatable, Sendable {
    var primaryFingerprint: String
    /// The primary and every subkey.
    var keyFingerprints: [String]
}

/// Packet-level checks on private key material. Lives behind the crypto seam
/// because only the library can say which packets it accepted.
protocol PgpKeyInspecting: Sendable {
    /// Exactly one complete, **unprotected** transferable secret key in one
    /// armor block, or nil. Refused: public-only or missing secret packets
    /// (including GNU dummy stubs), any passphrase-protected packet, a second
    /// key, a subkey the library dropped, anything outside the armor block.
    func inspectPrivateKey(armored: Data) -> PrivateKeyInventory?

    /// Every key in a legacy armored collection, in order, or nil when it
    /// does not parse. Used only to compare what a vault holds; it does not
    /// apply the keyring rules above.
    func legacyInventories(armored: Data) -> [PrivateKeyInventory]?

    /// A legacy collection holding `current` first and every key of
    /// `previous` that `current` does not already cover, so mail encrypted
    /// to a retired key still opens after re-enrollment. Nil when either
    /// side does not parse — the caller then keeps the previous record
    /// rather than storing something that lost history.
    func mergeLegacy(current: Data, previous: Data) -> Data?
}

/// Writing. Used only on the client-custody send path.
protocol PgpEncrypting: Sendable {
    /// Encrypts to `recipientKeys` and signs with the device's key.
    func encryptAndSign(
        plaintext: Data,
        recipientKeys: [String],
        privateKey: Data
    ) throws -> String

    /// The public half of the key this device holds.
    ///
    /// The Sent copy is encrypted to **this**, never to bootstrap's
    /// `publicKey`: a hostile server supplying "your" key would otherwise get
    /// a readable copy of every message sent.
    func ownPublicKey(privateKey: Data) throws -> String
}

/// Revocation of keys pinned on this device (Android #191).
///
/// A key verified here by QR is authoritative for its address; the one thing a
/// synced copy of it may do is revoke it.
protocol PgpKeyRevocation: Sendable {
    /// `pinned` with the revocations taken from `synced`, or nil when there is
    /// none to take. `synced` must be a copy of the **same primary key**; it
    /// may revoke that primary or a subkey the pin already holds, and each
    /// revocation must verify against the pinned primary. Only those
    /// signatures cross — no subkey, user id or other material — so a synced
    /// copy can withdraw pinned keys but never change what they are.
    func withVerifiedRevocation(pinned: String, synced: String) -> String?

    /// The primary key carries a revocation that verifies against it. A
    /// revocation packet alone is not enough.
    func isPrimaryRevoked(armoredPublicKey: String) -> Bool
}

/// The cap applied before allocating decompressed plaintext.
let maxDecompressedPlaintextBytes = 32 * 1024 * 1024

/// Stands in until an implementation is linked.
///
/// Deliberately fails rather than degrading: a decrypt path that silently
/// returns nothing is indistinguishable from a client-protected message the
/// user must open in webmail, and that is precisely the confusion the message
/// states exist to avoid.
struct UnavailablePgpCrypto: PgpDecrypting, PgpEncrypting, PgpKeyInspecting, PgpKeyRevocation {
    func withVerifiedRevocation(pinned: String, synced: String) -> String? { nil }

    /// Fails closed: a pin whose revocation cannot be checked is not usable.
    func isPrimaryRevoked(armoredPublicKey: String) -> Bool { true }

    func decrypt(
        armoredCiphertext: String,
        privateKeys: [Data],
        signerKeys: [String]
    ) throws -> DecryptedMessage {
        throw PgpCryptoError.unavailable
    }

    func inspectPrivateKey(armored: Data) -> PrivateKeyInventory? { nil }
    func legacyInventories(armored: Data) -> [PrivateKeyInventory]? { nil }
    func mergeLegacy(current: Data, previous: Data) -> Data? { nil }

    func verifyDetached(
        signedBytes: Data,
        armoredSignature: String,
        signerKeys: [String]
    ) -> RawSignature {
        RawSignature()
    }

    func fingerprint(ofArmoredPublicKey key: String) -> String? { nil }

    func encryptAndSign(
        plaintext: Data,
        recipientKeys: [String],
        privateKey: Data
    ) throws -> String {
        throw PgpCryptoError.unavailable
    }

    func ownPublicKey(privateKey: Data) throws -> String {
        throw PgpCryptoError.unavailable
    }
}
