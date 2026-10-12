//
//  DeviceEnvelope.swift
//  KyPost
//
//  The sealed envelope a browser mints to hand this device the account's
//  OpenPGP private key. Swift port of kypost-android's pgp/DeviceEnvelope.kt.
//
//  Wire-compatible with the browser and with Android: the version tag, the
//  HKDF info string and the AAD layout move together, and changing one alone
//  strands every enrolled device.
//

import CryptoKit
import Foundation

/// The HKDF info string and AAD prefix, per version. Moves together with the
/// version tag; changing either alone strands every device on that version.
///
/// **v1 → v2:** the AAD stopped being pipe-delimited concatenation and became
/// length-prefixed. See `deviceEnvelopeAAD`.
/// **v2 → v3:** the plaintext became the complete `kypost-pgp-keyring-v1`
/// ring rather than one armored key. Framing and AAD layout are unchanged;
/// only the domain string differs, so a v3 envelope can never be opened as v2.
nonisolated func envelopeDomain(version: Int) -> String {
    "kypost-device-envelope/v\(version)"
}

/// One armored private key (or legacy collection), sealed by the browser's
/// legacy path.
nonisolated let envelopeVersionLegacy = 2
/// The complete `kypost-pgp-keyring-v1` ring, for a converted account.
nonisolated let envelopeVersionKeyring = 3
/// What this build can open, and what it publishes as `envelopeVersions`.
/// Publishing without the list resets the server's claim to `[2]`, and the
/// browser then refuses to seal v3.
nonisolated let supportedEnvelopeVersions = [envelopeVersionLegacy, envelopeVersionKeyring]

/// The v2 domain, kept as a name because tests and the legacy path read it.
nonisolated let envelopeInfo = envelopeDomain(version: envelopeVersionLegacy)

/// Serialized v3 envelope bound, checked before any JSON or base64 work.
nonisolated let maxDeviceEnvelopeV3Bytes = 128 * 1024

private let envelopeAlgorithm = "ECDH-P256+HKDF-SHA256+A256GCM"
private let gcmTagBytes = 16
private let envelopeKeysV3: Set<String> = ["v", "alg", "epk", "iv", "ct"]

/// The version is parsed once and travels with the fields, so the opener
/// cannot be pointed at a different domain than the envelope declared.
nonisolated struct DeviceEnvelopeFields: Equatable, Sendable {
    var version: Int = envelopeVersionLegacy
    /// The browser's ephemeral public key, raw SEC1 (65 bytes, 0x04-prefixed).
    var epk: Data
    var iv: Data
    var ct: Data
}

/// Parses the envelope, returning nil for anything malformed, unsupported or
/// wrong-sized. **Nil means re-run the ceremony, never retry.**
///
/// The size and prefix checks match the browser, which requires exactly 65
/// bytes with an 0x04 prefix before it will import the point. Rejecting
/// compressed markers, the point at infinity and trailing junk here means the
/// ECDH layer is not the only thing standing between an attacker-supplied blob
/// and the key.
///
/// v3 is stricter, matching the server's own framing check and Android: the
/// tag must be the JSON **number** 3, the object holds exactly the five
/// fields, the whole envelope fits in 128 KiB, base64 is canonical and padded,
/// and the ephemeral point must be on P-256. v2 keeps its historical leniency
/// (a quoted `"2"` has always opened). A v3 envelope is never retried as v2.
nonisolated func parseDeviceEnvelope(
    _ json: String,
    allowedVersions: Set<Int> = Set(supportedEnvelopeVersions)
) -> DeviceEnvelopeFields? {
    if allowedVersions.contains(envelopeVersionKeyring),
       !allowedVersions.contains(envelopeVersionLegacy),
       json.utf8.count > maxDeviceEnvelopeV3Bytes {
        return nil
    }
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let version: Int
    if jsonPrimitiveContent(object["v"]) == String(envelopeVersionLegacy) {
        version = envelopeVersionLegacy
    } else if let number = object["v"] as? NSNumber, isJSONInteger(number, equalTo: envelopeVersionKeyring) {
        version = envelopeVersionKeyring
    } else {
        return nil
    }
    guard allowedVersions.contains(version),
          object["alg"] as? String == envelopeAlgorithm,
          let epkText = object["epk"] as? String,
          let ivText = object["iv"] as? String,
          let ctText = object["ct"] as? String
    else { return nil }

    let epk, iv, ct: Data
    if version == envelopeVersionKeyring {
        guard Set(object.keys) == envelopeKeysV3,
              data.count <= maxDeviceEnvelopeV3Bytes,
              let strictEpk = strictBase64(epkText),
              let strictIv = strictBase64(ivText),
              let strictCt = strictBase64(ctText)
        else { return nil }
        epk = strictEpk; iv = strictIv; ct = strictCt
    } else {
        guard let looseEpk = Data(base64Encoded: epkText),
              let looseIv = Data(base64Encoded: ivText),
              let looseCt = Data(base64Encoded: ctText)
        else { return nil }
        epk = looseEpk; iv = looseIv; ct = looseCt
    }

    guard epk.count == 65, epk.first == 0x04 else { return nil }
    // On-curve and not the identity, checked here for v3 so the framing
    // stands on its own before any ECDH layer sees the point. CryptoKit's
    // import validates both.
    if version == envelopeVersionKeyring,
       (try? P256.KeyAgreement.PublicKey(x963Representation: epk)) == nil {
        return nil
    }
    guard iv.count == 12, ct.count > gcmTagBytes else { return nil }
    return DeviceEnvelopeFields(version: version, epk: epk, iv: iv, ct: ct)
}

/// Standard alphabet, padded, canonical. Foundation alone accepts encodings
/// with non-zero trailing bits, which lets two strings name one ciphertext.
nonisolated func strictBase64(_ text: String) -> Data? {
    guard !text.isEmpty, text.count % 4 == 0,
          let data = Data(base64Encoded: text),
          data.base64EncodedString() == text
    else { return nil }
    return data
}

/// A JSON integer token (not a boolean, not `3.0`) equal to `value`.
private nonisolated func isJSONInteger(_ number: NSNumber, equalTo value: Int) -> Bool {
    guard CFGetTypeID(number) != CFBooleanGetTypeID(),
          !CFNumberIsFloatType(number as CFNumber)
    else { return false }
    return number.intValue == value
}

/// The textual content of a JSON primitive, whether it arrived as a string or
/// a number — the counterpart of kotlinx's `jsonPrimitive.content`.
///
/// The version tag is a JSON **number** on the wire: the browser serialises
/// `"v": 2` and the normative envelope spec shows `"v": 1`, both unquoted. The
/// server stores and serves the envelope as an opaque string, so those bytes
/// reach this device unchanged. Android reads the tag through
/// `jsonPrimitive.content`, which yields `"2"` for a number or a quoted string
/// alike; Foundation decodes a JSON number as `NSNumber`, and `NSNumber as?
/// String` is nil. Comparing `object["v"] as? String` therefore rejected every
/// well-formed server envelope as **malformed** while Android accepted the same
/// bytes. Matching Android's leniency here is the fix.
private nonisolated func jsonPrimitiveContent(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

enum DeviceEnvelopeError: Error, Equatable {
    /// The fingerprint was not hex once normalised. A caller bug, not a
    /// hostile envelope — see the note below on why this validates rather
    /// than trusting the caller.
    case malformedFingerprint
    case fieldTooLongToLengthPrefix
    case unsupportedVersion
    case emptyDeviceId
}

/// Binds the sealing to this device and this identity, as **length-prefixed**
/// fields:
///
/// `info || uint16BE(len(deviceId)) || deviceId || uint16BE(len(fp)) || fp`
///
/// It used to be `info|deviceId|fingerprint` — unescaped pipe concatenation,
/// which is ambiguous: an envelope sealed under
/// (deviceId "dev|BADC0FFEE", fp "0123…") produces byte-identical AAD to one
/// sealed under (deviceId "dev", fp "BADC0FFEE|0123…"), and each opens under
/// the other. That was not exploitable as it stood — cross-device replay
/// already fails at the HKDF, whose salt is this device's own public key — but
/// it is a latent structural weakness of a class that produced real
/// key-binding CVEs in Matrix, which uses a structured transcript for exactly
/// this reason. Length prefixing removes the class rather than arguing about
/// reachability, at two bytes a field.
///
/// **Normalises and validates the fingerprint rather than trusting the
/// caller.** On Android this was a doc comment, and the repo's only
/// fingerprint producer returns *space-grouped* hex while the browser strips
/// whitespace before building its AAD — so the natural implementation produced
/// an AAD that could never authenticate, and the design's error table turns
/// that into "hostile or stale, no retry", which the browser reports as *"the
/// key this server gave the browser is not the key on that device"*. A
/// formatting bug arriving as a substituted-key alarm trains users to dismiss
/// the one alarm this feature has. A doc comment is not a contract across
/// three implementations.
///
/// The domain is the version's: v3 additionally requires a non-empty device
/// id and a full 40- or 64-digit fingerprint, the only lengths a validated
/// active key can have. The device id goes in unchanged — no trimming,
/// normalisation or case folding.
nonisolated func deviceEnvelopeAAD(
    version: Int = envelopeVersionLegacy,
    deviceId: String,
    pgpFingerprint: String
) throws -> Data {
    guard version == envelopeVersionLegacy || version == envelopeVersionKeyring else {
        throw DeviceEnvelopeError.unsupportedVersion
    }
    let fingerprint = pgpFingerprint.uppercased().filter { !$0.isWhitespace }
    guard !fingerprint.isEmpty,
          fingerprint.allSatisfy({ $0.isHexDigit && $0.isASCII && !$0.isLowercase })
    else { throw DeviceEnvelopeError.malformedFingerprint }
    if version == envelopeVersionKeyring {
        guard !deviceId.isEmpty else { throw DeviceEnvelopeError.emptyDeviceId }
        guard fingerprint.count == 40 || fingerprint.count == 64 else {
            throw DeviceEnvelopeError.malformedFingerprint
        }
    }

    let info = Data(envelopeDomain(version: version).utf8)
    let id = Data(deviceId.utf8)
    let fp = Data(fingerprint.utf8)
    guard id.count <= 0xFFFF, fp.count <= 0xFFFF else {
        throw DeviceEnvelopeError.fieldTooLongToLengthPrefix
    }

    var aad = Data()
    aad.append(info)
    aad.append(bigEndianUInt16(id.count))
    aad.append(id)
    aad.append(bigEndianUInt16(fp.count))
    aad.append(fp)
    return aad
}

/// Opens the envelope, or nil if GCM authentication fails.
///
/// A nil here is **hostile or stale, never a retry**: the AAD binds the
/// sealing to this device and this identity, so a failure means the envelope
/// was minted for someone else, or under an identity the account no longer
/// advertises.
///
/// `ownRawPublicKey` is the HKDF salt — this device's *own* raw 65-byte SEC1
/// point, not the ephemeral one in the envelope.
///
/// Returns bytes, not a String. `String(decoding:as:)` is silently lossy:
/// malformed bytes become U+FFFD and the call still succeeds, which reads as
/// success while handing back different bytes than were sealed. The plaintext
/// here is an OpenPGP private key; its lifetime belongs to the caller.
nonisolated func openDeviceEnvelope(
    sharedSecret: SharedSecret,
    ownRawPublicKey: Data,
    fields: DeviceEnvelopeFields,
    aad: Data
) -> Data? {
    let key = sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: ownRawPublicKey,
        sharedInfo: Data(envelopeDomain(version: fields.version).utf8),
        outputByteCount: 32
    )
    guard let box = try? AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: fields.iv),
        ciphertext: fields.ct.dropLast(gcmTagBytes),
        tag: fields.ct.suffix(gcmTagBytes)
    ) else { return nil }
    return try? AES.GCM.open(box, using: key, authenticating: aad)
}

nonisolated func bigEndianUInt16(_ value: Int) -> Data {
    Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
}
