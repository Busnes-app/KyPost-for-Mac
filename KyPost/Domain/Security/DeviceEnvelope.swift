//
//  DeviceEnvelope.swift
//  KyPost
//
//  The sealed envelope a browser mints to hand this device the account's
//  OpenPGP private key, sealed with RFC 9180 HPKE (v4/v5).
//
//  Wire-compatible with the browser: the version tag and the HPKE `info`
//  layout move together, and changing one alone strands every enrolled device.
//

import CryptoKit
import Foundation

/// The version's domain string, which heads the HPKE `info`
/// (`deviceEnvelopeAAD`). Moves together with the version tag; changing
/// either alone strands every device on that version.
nonisolated func envelopeDomain(version: Int) -> String {
    "kypost-device-envelope/v\(version)"
}

/// Retired ECDH envelope carrying a keyring; never opened. Still named by
/// vault records written before the version was kept (`EnrollmentVault`).
nonisolated let envelopeVersionKeyring = 3
/// One armored private key (or legacy collection) under HPKE.
nonisolated let envelopeVersionLegacyHPKE = 4
/// The complete `kypost-pgp-keyring-v1` ring under HPKE.
nonisolated let envelopeVersionKeyringHPKE = 5
/// What this build opens, and what it publishes as `envelopeVersions`: RFC
/// 9180 HPKE only. v2/v3 (custom ECDH+HKDF+GCM) are retired for enrollment.
nonisolated let supportedEnvelopeVersions = [envelopeVersionLegacyHPKE, envelopeVersionKeyringHPKE]

/// True for the versions whose plaintext is a `kypost-pgp-keyring-v1` ring.
nonisolated func envelopeCarriesKeyring(_ version: Int) -> Bool {
    version == envelopeVersionKeyring || version == envelopeVersionKeyringHPKE
}

nonisolated func envelopeIsHPKE(_ version: Int) -> Bool {
    version == envelopeVersionLegacyHPKE || version == envelopeVersionKeyringHPKE
}

/// RFC 9180 mode_base, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM.
nonisolated let deviceEnvelopeHPKESuite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256

/// Serialized v5 envelope bound.
nonisolated let maxDeviceEnvelopeV3Bytes = 128 * 1024

private let gcmTagBytes = 16
private let hpkeEnvelopeAlgorithm = "HPKE-Base-P256-SHA256-A256GCM"
private let hpkeEnvelopeKeys: Set<String> = ["v", "alg", "enc", "ct"]

/// The version is parsed once and travels with the fields, so the opener
/// cannot be pointed at a different domain than the envelope declared.
nonisolated struct DeviceEnvelopeFields: Equatable, Sendable {
    var version: Int
    /// HPKE `enc`: for DHKEM(P-256) the sender's ephemeral point, raw SEC1
    /// (65 bytes, 0x04-prefixed).
    var epk: Data
    var ct: Data
}

/// Parses a v4/v5 envelope, returning nil for anything malformed,
/// unsupported or wrong-sized — including every v2/v3 envelope. **Nil means
/// re-run the ceremony, never retry.**
///
/// Strict, matching the server's framing check: the tag is the JSON
/// **number** 4 or 5, the object holds exactly `v`, `alg`, `enc`, `ct`, base64
/// is canonical and padded, `enc` is an on-curve uncompressed point, and v5
/// fits in 128 KiB.
nonisolated func parseDeviceEnvelope(_ json: String) -> DeviceEnvelopeFields? {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let number = object["v"] as? NSNumber,
          let version = supportedEnvelopeVersions.first(where: { isJSONInteger(number, equalTo: $0) })
    else { return nil }
    return parseHPKEEnvelope(object, version: version, byteCount: data.count)
}

/// v4/v5 framing. `enc` must be an on-curve uncompressed point.
private nonisolated func parseHPKEEnvelope(
    _ object: [String: Any],
    version: Int,
    byteCount: Int
) -> DeviceEnvelopeFields? {
    guard Set(object.keys) == hpkeEnvelopeKeys,
          object["alg"] as? String == hpkeEnvelopeAlgorithm,
          version != envelopeVersionKeyringHPKE || byteCount <= maxDeviceEnvelopeV3Bytes,
          let encText = object["enc"] as? String,
          let ctText = object["ct"] as? String,
          let enc = strictBase64(encText),
          let ct = strictBase64(ctText),
          enc.count == 65, enc.first == 0x04,
          (try? P256.KeyAgreement.PublicKey(x963Representation: enc)) != nil,
          ct.count > gcmTagBytes
    else { return nil }
    return DeviceEnvelopeFields(version: version, epk: enc, ct: ct)
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

enum DeviceEnvelopeError: Error, Equatable {
    /// The fingerprint was not hex once normalised. A caller bug, not a
    /// hostile envelope — see the note below on why this validates rather
    /// than trusting the caller.
    case malformedFingerprint
    case fieldTooLongToLengthPrefix
    case unsupportedVersion
    case emptyDeviceId
}

/// The HPKE `info`: binds the sealing to this version, this device and this
/// identity, as **length-prefixed** fields:
///
/// `domain || uint16BE(len(deviceId)) || deviceId || uint16BE(len(fp)) || fp`
///
/// It used to be `info|deviceId|fingerprint` — unescaped pipe concatenation,
/// which is ambiguous: an envelope sealed under
/// (deviceId "dev|BADC0FFEE", fp "0123…") produces byte-identical AAD to one
/// sealed under (deviceId "dev", fp "BADC0FFEE|0123…"), and each opens under
/// the other. That was not exploitable as it stood — cross-device replay
/// already fails at the KEM, which seals to this device's own key — but
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
/// Requires a non-empty device id and a full 40- or 64-digit fingerprint, the
/// only lengths a validated active key can have. The device id goes in
/// unchanged — no trimming, normalisation or case folding.
nonisolated func deviceEnvelopeAAD(
    version: Int,
    deviceId: String,
    pgpFingerprint: String
) throws -> Data {
    guard supportedEnvelopeVersions.contains(version) else {
        throw DeviceEnvelopeError.unsupportedVersion
    }
    let fingerprint = pgpFingerprint.uppercased().filter { !$0.isWhitespace }
    guard !fingerprint.isEmpty,
          fingerprint.allSatisfy({ $0.isHexDigit && $0.isASCII && !$0.isLowercase })
    else { throw DeviceEnvelopeError.malformedFingerprint }
    guard !deviceId.isEmpty else { throw DeviceEnvelopeError.emptyDeviceId }
    guard fingerprint.count == 40 || fingerprint.count == 64 else {
        throw DeviceEnvelopeError.malformedFingerprint
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

/// Opens a v4/v5 envelope with the device key, or nil when authentication
/// fails (hostile or stale, never a retry).
///
/// **Throws only when the device key operation itself fails** — a dismissed
/// presence prompt, a busy Secure Enclave — so the caller never reports that
/// as a substituted key. `info` is `deviceEnvelopeAAD`; the HPKE AAD is empty.
///
/// Returns bytes, not a String: `String(decoding:as:)` silently replaces
/// malformed bytes. The plaintext is an OpenPGP private key; its lifetime
/// belongs to the caller.
nonisolated func openDeviceEnvelope(
    with key: any DeviceAgreementKey,
    fields: DeviceEnvelopeFields,
    info: Data
) throws -> Data? {
    guard envelopeIsHPKE(fields.version) else { return nil }
    var recipient = try HPKE.Recipient(
        privateKey: key,
        ciphersuite: deviceEnvelopeHPKESuite,
        info: info,
        encapsulatedKey: fields.epk
    )
    return try? recipient.open(fields.ct)
}

nonisolated func bigEndianUInt16(_ value: Int) -> Data {
    Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
}
