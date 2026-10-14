//
//  PgpSignatureState.swift
//  KyPost
//
//  What a message's OpenPGP signature actually claims. Swift port of
//  kypost-android's pgp/PgpMessageState.kt (the PgpSignatureState half) and
//  pgp/SignerBinding.kt.
//
//  **Trust is decided on this device.** The relay supplies candidate keys and
//  the address it resolved; it never decides whether a key is confirmed or
//  the same as last time. Its `verified` flag is not decoded at all, and its
//  `conflict` flag can only ever add a warning (`keyChanged`), never upgrade
//  a verdict.
//

import Foundation

/// Nine states, not a verified/unverified pair: two describe the message
/// (`unsigned`, `unchecked`), seven its sender. The distinction that matters
/// is between *identity* (this device confirmed the key out of band) and
/// *continuity* (same key as last time on this device), because most keys
/// arrive by Autocrypt harvest and a flat "verified" would overclaim for
/// nearly all of them.
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

    /// Signed by the key the user pinned for this sender **on this device**,
    /// by scanning its QR code (`RecipientPinStore`). **The only state that
    /// claims identity.**
    case verifiedConfirmed

    /// Signed by the key this device first saw signing for this sender, which
    /// nobody confirmed. Claims **continuity**, not identity: the same key as
    /// last time, by this device's own history (`SignerKeyHistory`).
    case verifiedSeenBefore

    /// A valid signature by a key the relay offered for this sender, with no
    /// pin and no history on this device. The relay vouches for the key; this
    /// device does not, so it claims neither identity nor continuity.
    case signerNotConfirmed

    /// No offered key made this signature. An ordinary correspondent not yet
    /// in the address book, a key that rotated before harvest, and a forged
    /// `From` are locally indistinguishable — so this is **not an accusation**.
    case signerUnknown

    /// The key that signed is not the one this device pinned or first saw for
    /// this sender, or the pin was revoked, or the relay reports the change.
    /// The one alarm worth raising.
    case keyChanged

    /// Signed, but it does not verify against the offered key.
    case invalid
}

/// One address-bound contact key as the server ships it: a **candidate**,
/// never a verdict.
///
/// `addresses` is the binding the **server's** address book computed. The
/// client must not derive trust from the key's own User IDs: one key can
/// self-assert any User ID, so they are shown as what the key says about
/// itself (`SignatureVerdict.keyAddresses`), never as a binding.
///
/// `conflict` means the server's TOFU pin no longer matches. Such an entry
/// carries no `publicKey` and is never offered to a signature check. It can
/// only ever add a warning: `signatureState` reads it as `keyChanged` unless
/// this device pinned the sender, and nothing reads it as reassurance.
///
/// There is deliberately no `verified` field. The relay's claim that a key
/// was confirmed is not decoded, so no code path can turn it into one.
nonisolated struct SignerKey: Equatable, Sendable {
    var addresses: [String] = []
    var publicKey: String = ""
    var source: String = ""
    var conflict = false
}

/// What this device itself knows about the resolved sender's key — the only
/// trust input a verdict has.
nonisolated enum LocalSignerTrust: Equatable, Sendable {
    /// Verified in person by QR on this device, and intact.
    case pinned(fingerprint: String)
    /// Pinned here, then revoked by its owner or no longer matching its bytes.
    case pinUnusable
    /// Not pinned. The fingerprint this device first saw make a valid
    /// signature for the address, or nil when it has seen none.
    case firstSeen(String?)
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

/// The verdict, and what it may be shown with.
nonisolated struct SignatureVerdict: Equatable, Sendable {
    var state: PgpSignatureState = .none
    /// The address the server resolved, which pins and history are looked up
    /// by. Shown as an identity **only** beside `.verifiedConfirmed`, where
    /// this device pinned the signing key for exactly this address.
    var resolvedSender: String = ""
    /// The signing key's own User ID addresses, lowercased, as the crypto
    /// library reads them (self-signed identities only). What the key says
    /// about itself — displayed as that, never treated as a binding. Empty
    /// when no offered key made the signature.
    var keyAddresses: [String] = []
}

/// The signature verdict for a message being displayed as being from a sender
/// **the server has already resolved**.
///
/// `signerKeys` arrives already narrowed to that sender (or replaced by this
/// device's pin). This function does not know the sender's address and
/// **must not learn it**: `trust` is what this device knows about it.
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
    trust: LocalSignerTrust,
    fingerprint: (String) -> String?
) -> PgpSignatureState {
    guard signature.present else { return .none }

    let signed = signature.signerFingerprint
    func same(_ candidate: String?) -> Bool {
        // Hex, and the case is whatever the producer chose.
        guard let candidate, !candidate.isEmpty, !signed.isEmpty else { return false }
        return candidate.caseInsensitiveCompare(signed) == .orderedSame
    }
    let signedBy = signerKeys.contains { same(fingerprint($0.publicKey)) }

    switch trust {
    case .pinUnusable:
        return .keyChanged

    case .pinned(let pinned):
        // The pin is authoritative: the relay's conflict flag is not read.
        guard signedBy else { return .signerUnknown }
        guard signature.valid else { return .invalid }
        return same(pinned) ? .verifiedConfirmed : .keyChanged

    case .firstSeen(let first):
        // The relay's conflict outranks everything it could be compared with,
        // because reporting the survivor as fine would hide precisely the
        // event worth reporting. It only ever lowers the verdict.
        if signerKeys.contains(where: \.conflict) { return .keyChanged }
        guard signedBy else { return .signerUnknown }
        guard signature.valid else { return .invalid }
        guard let first else { return .signerNotConfirmed }
        return same(first) ? .verifiedSeenBefore : .keyChanged
    }
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
    case .none, .unsigned, .unchecked, .verifiedConfirmed, .verifiedSeenBefore,
         .signerNotConfirmed, .signerUnknown: nil
    }
}

/// Short label for the reader's signature pill, or nil when there is nothing
/// worth saying.
///
/// The wording is the contract. `verifiedSeenBefore` must not read as an
/// identity claim, `signerNotConfirmed` must not read as either, and
/// `signerUnknown` must not read as an accusation.
nonisolated func signatureLabel(_ state: PgpSignatureState) -> String? {
    switch state {
    case .none: nil
    case .unsigned: "Encrypted, not signed"
    case .unchecked: "Signature not checked"
    case .verifiedConfirmed: "Signed — you confirmed this key"
    case .verifiedSeenBefore: "Signed — same key as last time"
    case .signerNotConfirmed: "Signed — signer not confirmed on this device"
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

/// `text` lowercased if it is one plain address, else nil.
///
/// User IDs are free-form UTF-8 the key's owner chose, and these values go
/// into the trust line and the warning. Anything that is not obviously one
/// address — whitespace, control or format (Cf: bidi overrides, zero-width)
/// characters, not exactly one `@`, over 254 characters — is **dropped,
/// never cleaned up**: a repaired string is still the attacker's wording.
nonisolated func plainAddress(_ text: String) -> String? {
    let lowered = text.lowercased()
    guard !lowered.isEmpty, lowered.count <= 254,
          lowered.filter({ $0 == "@" }).count == 1,
          !lowered.hasPrefix("@"), !lowered.hasSuffix("@")
    else { return nil }
    for scalar in lowered.unicodeScalars {
        switch scalar.properties.generalCategory {
        case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator,
             .unassigned, .privateUse, .surrogate:
            return nil
        default:
            if scalar.properties.isWhitespace { return nil }
        }
    }
    return lowered
}

/// The identity a sender verdict is shown with: the pinned address for a
/// confirmed key, otherwise only what the signing key says about itself. The
/// server's resolved sender is never shown as an identity it did not earn.
/// Every address shown passes `plainAddress` here too, whatever its source.
nonisolated func signatureIdentity(_ verdict: SignatureVerdict) -> String? {
    if verdict.state == .verifiedConfirmed, let pinned = plainAddress(verdict.resolvedSender) {
        return pinned
    }
    let named = verdict.keyAddresses.compactMap(plainAddress)
    guard !named.isEmpty else { return nil }
    return "key for \(named.joined(separator: ", "))"
}

/// A warning when the address the message shows is not one the signature is
/// bound to — the pinned address, or the signing key's own User IDs.
///
/// `displayedFrom` is the display parser's address (`Email.senderEmail`). It
/// can only **add** this warning; it never sets or raises a verdict, which is
/// what keeps it clear of the no-`From`-parser rule above.
nonisolated func signatureIdentityMismatch(_ verdict: SignatureVerdict, displayedFrom: String) -> String? {
    let from = RecipientPinStore.normalized(displayedFrom)
    guard !from.isEmpty else { return nil }
    var bound = Set(verdict.keyAddresses.compactMap(plainAddress))
    switch verdict.state {
    case .verifiedConfirmed:
        if let pinned = plainAddress(RecipientPinStore.normalized(verdict.resolvedSender)) {
            bound.insert(pinned)
        }
    case .verifiedSeenBefore, .signerNotConfirmed:
        break
    case .keyChanged, .invalid:
        // Only when a key was attributed; otherwise the alarm says enough.
        guard !bound.isEmpty else { return nil }
    case .none, .unsigned, .unchecked, .signerUnknown:
        return nil
    }
    guard !bound.contains(from) else { return nil }
    let named = bound.isEmpty ? "no address" : bound.sorted().joined(separator: ", ")
    // The From is the display parser's output: shown only if it too is one
    // plain address.
    let shown = plainAddress(from) ?? "a different sender"
    return "This message shows \(shown), but the signing key is for \(named)."
}
