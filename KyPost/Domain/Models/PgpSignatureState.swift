//
//  PgpSignatureState.swift
//  KyPost
//
//  What a message's OpenPGP signature actually claims. Swift port of
//  kypost-android's pgp/PgpMessageState.kt (the PgpSignatureState half) and
//  pgp/SignerBinding.kt.
//

import Foundation

/// Eight states, not a verified/unverified pair. The distinction that matters is
/// between *identity* (someone confirmed this key out of band) and *continuity*
/// (same key as last time), because most keys arrive by Autocrypt harvest and a
/// flat "verified" would overclaim for nearly all of them.
nonisolated enum PgpSignatureState: Equatable, Sendable {
    /// No opinion expressed. Nothing to say.
    case none

    /// Decrypted on this device and carrying neither a packet signature nor
    /// a declared PGP/MIME signature wrapper. A message-level notice, not a
    /// sender verdict: it needs no resolved sender and marks no row.
    case unsigned

    /// Decrypted on this device with no packet signature, but carrying a
    /// declared `multipart/signed` (`application/pgp-signature`) wrapper,
    /// root or nested. Detected, **not verified** — so neither "not signed"
    /// (false) nor any verdict (unearned). Malformed signature contents land
    /// here too.
    case unchecked

    /// Signed by a key bound to the sender that the user confirmed out of band
    /// — by reading a fingerprint aloud or scanning a QR code. **The only
    /// state that claims identity.**
    case verifiedConfirmed

    /// Signed by a bound key still matching its TOFU pin, which nobody ever
    /// confirmed. Claims **continuity**, not identity: the same key as last
    /// time.
    case verifiedSeenBefore

    /// No key bound to this sender at all. An ordinary correspondent not yet
    /// in the address book, a key that rotated before harvest, and a forged
    /// `From` are locally indistinguishable — so this is **not an accusation**.
    case signerUnknown

    /// A key IS bound to this sender and no longer matches its TOFU pin. The
    /// one alarm worth raising.
    case keyChanged

    /// Signed, but it does not verify against the bound key.
    case invalid
}

/// One address-bound contact key as the server ships it.
///
/// `addresses` is the binding the **server's** address book computed. The
/// client must not re-derive it from the key's own User IDs: one key can
/// self-assert two User IDs, so a binding taken from the key material is
/// forgeable.
///
/// `conflict` means the stored key no longer matches its TOFU pin. Such an
/// entry carries no `publicKey` and is never offered to a signature check — it
/// exists so the reader can say the key changed rather than silently reporting
/// an unknown signer.
nonisolated struct SignerKey: Equatable, Sendable {
    var addresses: [String] = []
    var publicKey: String = ""
    var verified = false
    var source: String = ""
    var conflict = false
}

/// The raw signature facts, independent of who is bound to them.
nonisolated struct RawSignature: Equatable, Sendable {
    var present = false
    var valid = false
    /// The **issuer** key id from the signature packet — a signing subkey's
    /// id whenever a subkey signed. Carried for display and diagnostics only.
    ///
    /// Deliberately not the attribution key. It lives at a different level
    /// from anything a public key can be asked for: GopenPGP's key-id list
    /// for a key ring reports `PrimaryKey.KeyId` per entity, so matching an
    /// issuer id against it fails for every subkey-signed message, silently
    /// and always in the direction of "unknown signer". Use
    /// `signerFingerprint`.
    var signerKeyID: String = ""
    /// Fingerprint of the **entity** whose key verified the signature — the
    /// primary, whichever component actually signed. This is what attributes
    /// a signature to a bound key, because it is the one value comparable to
    /// what a bound public key reports about itself.
    var signerFingerprint: String = ""
}

/// The signature verdict for a message being displayed as being from a sender
/// **the server has already resolved**.
///
/// `signerKeys` arrives already narrowed to that sender. This function does not
/// know the sender's address and **must not learn it**.
///
/// Android's client used to parse the raw `From` header itself. A differential
/// harness over 111 adversarial headers found 27 divergences from the server's
/// parser — most seriously RFC 5322 comments, where `Bob (Eve <eve@evil>)
/// <bob@x>` is valid, the server binds `bob@x`, and the client bound
/// `eve@evil`, letting any contact forge a verified badge for anyone. Three fix
/// rounds each closed one construct and opened another.
///
/// **A second parser deciding the same binding is the defect. Do not
/// reintroduce one.** This app's two address parsers are for display
/// (`RelayMailSource.splitSender`) and for outgoing compose
/// (`EmailAddress.parse`); neither may ever reach this function.
///
/// `fingerprint` reads the entity fingerprint out of an armored public key.
/// It is injected because doing it properly needs an OpenPGP implementation;
/// the ordering rules below are testable without one.
///
/// It returns nil for a key that does not parse, and a key that does not parse
/// must only ever shrink the candidate set. An empty fingerprint on either
/// side therefore matches nothing at all — were it allowed to compare equal,
/// an unparseable bound key and a signature with no attribution would agree
/// with each other and produce a verified badge out of two absences.
nonisolated func signatureState(
    signature: RawSignature,
    signerKeys: [SignerKey],
    fingerprint: (String) -> String?
) -> PgpSignatureState {
    guard signature.present else { return .none }
    guard !signerKeys.isEmpty else { return .signerUnknown }

    // A conflict outranks a good key for the same sender. Two entries for one
    // address means one of them is a key that changed, and reporting the
    // survivor as verified would hide precisely the event worth reporting.
    if signerKeys.contains(where: \.conflict) { return .keyChanged }

    let signed = signature.signerFingerprint
    let signedBy = signed.isEmpty ? [] : signerKeys.filter {
        guard let candidate = fingerprint($0.publicKey), !candidate.isEmpty else { return false }
        // Hex, and the case is whatever the producer chose.
        return candidate.caseInsensitiveCompare(signed) == .orderedSame
    }
    guard !signedBy.isEmpty else { return .signerUnknown }
    guard signature.valid else { return .invalid }

    return signedBy.contains(where: \.verified) ? .verifiedConfirmed : .verifiedSeenBefore
}

// MARK: - Presentation

/// SF Symbol for an inbox row, or nil for no marker.
///
/// `signerUnknown` deliberately does **not** mark: it is the ordinary state for
/// a correspondent not yet in the address book, and a glyph on most rows
/// carries nothing actionable.
nonisolated func signatureRowSymbol(_ state: PgpSignatureState) -> String? {
    switch state {
    case .keyChanged, .invalid: "exclamationmark.triangle.fill"
    case .none, .unsigned, .unchecked, .verifiedConfirmed, .verifiedSeenBefore, .signerUnknown: nil
    }
}

/// Short label for the reader's signature pill, or nil when there is nothing
/// worth saying.
///
/// The wording is the contract. `verifiedSeenBefore` must not read as an
/// identity claim, and `signerUnknown` must not read as an accusation.
nonisolated func signatureLabel(_ state: PgpSignatureState) -> String? {
    switch state {
    case .none: nil
    case .unsigned: "Encrypted, not signed"
    case .unchecked: "Signature not checked"
    case .verifiedConfirmed: "Signed — you confirmed this key"
    case .verifiedSeenBefore: "Signed — same key as last time"
    case .signerUnknown: "Signed by a key you haven't saved"
    case .keyChanged: "This sender's key has changed"
    case .invalid: "Signature doesn't match"
    }
}

/// Whether the state describes the message rather than its sender. These two
/// are shown even when the server resolved no sender, and without one beside
/// them; every other label is a verdict about the resolved sender.
nonisolated func signatureIsMessageLevel(_ state: PgpSignatureState) -> Bool {
    state == .unsigned || state == .unchecked
}

/// Whether the state is an alarm rather than information.
nonisolated func signatureIsAlarming(_ state: PgpSignatureState) -> Bool {
    state == .keyChanged || state == .invalid
}
