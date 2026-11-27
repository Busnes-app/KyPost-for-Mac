//
//  DeviceEnrollmentCode.swift
//  KyPost
//
//  The short authentication string shown during device enrollment. Swift port
//  of kypost-android's pgp/DeviceEnrollmentCode.kt — byte-identical output is
//  the contract, since the browser derives the same code independently.
//

import CryptoKit
import Foundation

/// Crockford base32: excludes I, L, O and U, so the user cannot mistype a code
/// by confusing them with 1, 0 and V.
private let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

/// Fourteen characters at five bits each — the first **70 bits** of the digest,
/// MSB first.
///
/// This was 10 characters (50 bits) on Android, and 50 bits is not enough. The
/// comparison has **no commitment step**: nothing the browser contributes
/// enters this preimage, so every input is fixed, public or attacker-chosen and
/// the search is entirely *offline* — a work factor, not a per-attempt
/// probability. An adversary who can write the relay's device table (in this
/// design's threat model — "a compromised database") grinds a key, or a
/// `deviceId`, whose code collides with the honest device's at a chosen future
/// bucket, then waits for that bucket. At 50 bits that is roughly 2^50 SHA-256
/// compressions: about 14 GPU-hours per 120-second window. Refusing *future*
/// buckets does not prevent precomputing *into* one.
///
/// 70 bits puts the same search at ~2^70 — roughly a million GPU-years per
/// window.
///
/// The principled fix is a commitment, not a longer code — Matrix's SAS is
/// shorter than this and sound, because the peer commits to its ephemeral key
/// first, giving the attacker exactly one online guess. That needs a
/// browser-to-device channel this protocol does not have. Until it exists,
/// length is what carries the property.
let enrollmentCodeLength = 14

/// The code's validity window, and the browser's. Changing this alone strands
/// every honest enrollment.
let enrollmentBucketSeconds: Int64 = 120

/// Derived from the public key in this device's own keystore — **never** from
/// anything the server sent back, and never from a cached copy of what was
/// published. The browser compares its own derivation (from the key the server
/// handed it) against what the user reads off this screen; if this device ever
/// derived from a server-supplied value, the comparison would compare the
/// server against itself and the whole control would be decoration.
///
/// `rawPublicKey` is the uncompressed SEC1 point, `0x04 ‖ X ‖ Y` with each
/// coordinate left-padded to 32 bytes — the raw 65 bytes, never their base64
/// text.
///
/// `deviceId` is hashed as-is and **must not be normalised**: the server bounds
/// new ids to `A-Z a-z 0-9 . _ : -`, every character of which is byte-identical
/// under UTF-8, NFC and NFD. That bound exists precisely because an NFC/NFD
/// disagreement between two clients would surface to the user as a substituted
/// key.
nonisolated func deviceEnrollmentCode(
    rawPublicKey: Data,
    deviceId: String,
    bucket: Int64
) -> String {
    let id = Data(deviceId.utf8)
    var preimage = Data()
    // Length selects SAS v2 unambiguously; parsing the KEM key belongs to
    // publication, not this byte-hash derivation (including test mutations).
    if rawPublicKey.count == 1216 {
        preimage.append(Data("kypost-device-sas/v2".utf8))
        preimage.append(bigEndianUInt16(rawPublicKey.count))
    }
    preimage.append(rawPublicKey)
    preimage.append(bigEndianUInt16(id.count))
    preimage.append(id)
    preimage.append(bigEndianInt64(bucket))

    let digest = Array(SHA256.hash(data: preimage))
    var code = ""
    for characterIndex in 0..<enrollmentCodeLength {
        var value = 0
        for offset in 0..<5 {
            let bit = characterIndex * 5 + offset
            let byte = Int(digest[bit / 8])
            value = (value << 1) | ((byte >> (7 - bit % 8)) & 1)
        }
        code.append(crockford[value])
    }
    return code
}

/// The bucket a moment falls in. `unixSeconds / 120`.
nonisolated func enrollmentBucket(at date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970.rounded(.down)) / enrollmentBucketSeconds
}

/// Displayed in four dash-separated groups of `4-3-4-3`: `XXXX-XXX-XXXX-XXX`.
/// This grouping is the browser's, so the code the user reads off this screen
/// lines up character-for-character with the field they type it into.
nonisolated func formattedEnrollmentCode(_ code: String) -> String {
    guard code.count == enrollmentCodeLength else { return code }
    let groupSizes = [4, 3, 4, 3]
    var groups: [Substring] = []
    var index = code.startIndex
    for size in groupSizes {
        let end = code.index(index, offsetBy: size)
        groups.append(code[index..<end])
        index = end
    }
    return groups.joined(separator: "-")
}

private nonisolated func bigEndianInt64(_ value: Int64) -> Data {
    var data = Data(count: 8)
    for index in 0..<8 {
        data[index] = UInt8((value >> (8 * (7 - index))) & 0xFF)
    }
    return data
}
