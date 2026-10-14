//
//  SpkiPinLinkTests.swift
//  KyPost Tests
//
//  The pairing link's `pin=` parameter: decoding it, refusing it, and
//  enforcing it on the one request that must not go out unpinned.
//

import Foundation
import Testing
@testable import KyPost

// The relay publishes sha256/<base64> over the DER SubjectPublicKeyInfo.
// These two are the same 32 bytes in the two encodings that meet in SpkiPin.
private let pinBase64 = "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
private let pinHex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

@Suite struct SpkiPinNormalisationTests {
    /// The encoding difference is the whole point of this type: the server
    /// speaks base64, PinnedSessionDelegate speaks lowercase hex, and a
    /// comparison across the two fails closed on every pairing.
    @Test func decodesTheServersBase64ToTheDelegatesHex() {
        #expect(SpkiPin.normalizedHex(fromLinkValue: "sha256/" + pinBase64) == pinHex)
    }

    @Test func acceptsTheValueWithoutTheSha256Prefix() {
        #expect(SpkiPin.normalizedHex(fromLinkValue: pinBase64) == pinHex)
    }

    @Test func toleratesSurroundingWhitespace() {
        #expect(SpkiPin.normalizedHex(fromLinkValue: "  sha256/" + pinBase64 + "\n") == pinHex)
    }

    /// Everything here must return nil so the caller refuses. A pin that
    /// decodes to "something plausible" is worse than no pin at all.
    @Test func refusesAnythingThatIsNotA32ByteBase64Digest() {
        // A SHA-1 digest: right shape, wrong length.
        #expect(SpkiPin.normalizedHex(fromLinkValue: "2jmj7l5rSw0yVb/vlWAYkK/YBwk=") == nil)
        // Truncated, over-long, and unpadded.
        #expect(SpkiPin.normalizedHex(fromLinkValue: String(pinBase64.dropLast())) == nil)
        #expect(SpkiPin.normalizedHex(fromLinkValue: pinBase64 + "A") == nil)
        #expect(SpkiPin.normalizedHex(fromLinkValue: String(pinBase64.dropLast()) + "AA") == nil)
        // Already hex — not what the relay emits, and accepting it would mean
        // guessing at encodings rather than knowing one.
        #expect(SpkiPin.normalizedHex(fromLinkValue: pinHex) == nil)
        #expect(SpkiPin.normalizedHex(fromLinkValue: "") == nil)
        #expect(SpkiPin.normalizedHex(fromLinkValue: "sha256/") == nil)
    }

    /// URLSearchParams percent-encodes `+`, `/` and `=`. A query string that
    /// lost that encoding turns `+` into a space, which corrupts roughly half
    /// of all pins — it must refuse, not decode to 32 wrong bytes.
    @Test func refusesAPinWhosePlusBecameASpace() {
        let mangled = pinBase64.replacingOccurrences(of: "+", with: " ")
        #expect(mangled != pinBase64, "fixture must actually contain a '+'")
        #expect(SpkiPin.normalizedHex(fromLinkValue: mangled) == nil)
    }
}

@Suite struct PairingLinkPinTests {
    private func link(pin: String?) -> URL {
        var s = "kypost://native-pair?sub=u&srv=https://relay.example.com&pt=p"
        if let pin, let escaped = pin.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) {
            s += "&pin=" + escaped
        }
        return URL(string: s)!
    }

    @Test func carriesAValidPinAsHex() throws {
        let params = try PairingLinkParser.parse(link(pin: "sha256/" + pinBase64))
        #expect(params.pin == pinHex)
    }

    /// Absent is the 0.3.x relay and the self-hoster terminating TLS
    /// elsewhere. That is TOFU, and legitimate.
    @Test func aLinkWithoutAPinParsesAsUnpinned() throws {
        #expect(try PairingLinkParser.parse(link(pin: nil)).pin == nil)
    }

    /// Refuse rather than ignore. Dropping an unparseable pin silently
    /// reopens the TOFU window on the request carrying the pairing token,
    /// which is the one thing `pin=` exists to prevent. Android refuses too.
    @Test func refusesALinkWhosePinIsMalformed() {
        #expect(throws: PairingLinkError.malformedCertificatePin) {
            try PairingLinkParser.parse(link(pin: "sha256/not-a-digest"))
        }
    }

    /// An empty `pin=` is a link that carried no pin, not a broken one —
    /// matching how every other optional parameter here is read.
    @Test func anEmptyPinParameterIsTreatedAsAbsent() throws {
        let url = URL(
            string: "kypost://native-pair?sub=u&srv=https://relay.example.com&pt=p&pin="
        )!
        #expect(try PairingLinkParser.parse(url).pin == nil)
    }
}
