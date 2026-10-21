//
//  PgpMimeWriter.swift
//  KyPost
//
//  Outbound PGP/MIME construction — the writing counterpart to PgpMimeReader.
//  Swift port of kypost-android's pgp/PgpMimeWriter.kt.
//
//  Hand-assembled strings, deliberately. The requirement is not "emit valid
//  MIME", it is "emit the exact byte shape the relay's validator accepts and
//  the browser client already produces". A string builder is directly
//  reviewable against that validator; a general MIME writer is not, and one
//  that synthesises or rewrites headers underneath us could not be reviewed at
//  all. PgpMimeReader stays independent of this file so it can serve as an
//  oracle for these tests rather than validating the writer with itself.
//

import Foundation

/// One outgoing attachment, already base64-encoded.
nonisolated struct OutgoingMimeAttachment: Equatable, Sendable {
    var name: String
    var mimeType: String
    var dataBase64: String
}

/// The outer, cleartext envelope of one delivery.
///
/// There is deliberately **no `bcc` field**. A `Bcc` header is refused outright
/// by the relay, and each BCC recipient gets their own delivery so they never
/// appear in one another's headers. Making it unrepresentable is stronger than
/// remembering not to write it.
nonisolated struct OutgoingEnvelope: Equatable, Sendable {
    var from: String
    var to: [String]
    var cc: [String]
    var date: String
}

/// Matches the server's `pgpmail.OuterPlaceholderSubject` so both send paths
/// look identical on the wire.
nonisolated let outerPlaceholderSubject = "[Encrypted] Email Sent by KyPost"

nonisolated enum PgpMimeWriter {
    private static let crlf = "\r\n"
    private static let base64LineLength = 76

    /// Wraps an armored PGP message as a complete RFC 5322 message with an
    /// RFC 3156 `multipart/encrypted` body.
    ///
    /// Emits the **full** envelope, not just the Content-Type:
    /// `/api/mail/send-pgp` relays these bytes verbatim, so anything omitted
    /// here is simply absent from the delivered mail.
    ///
    /// The header set is fixed and closed — there is no caller-supplied header
    /// path at all, which is what structurally guarantees the relay's forbidden
    /// headers (`Received`, `Authentication-Results`, `Return-Path`, `Bcc`)
    /// can never appear.
    static func wrapAsPgpMime(
        envelope: OutgoingEnvelope,
        armoredMessage: String,
        boundaryToken: () -> String = randomBoundaryToken
    ) -> String {
        let boundary = "kypost-pgp-boundary-\(boundaryToken())"
        var lines: [String] = []
        lines.append("From: \(sanitizeHeaderValue(envelope.from))")
        lines.append("To: \(joinAddresses(envelope.to))")
        let cc = joinAddresses(envelope.cc)
        if !cc.isEmpty { lines.append("Cc: \(cc)") }
        // The real subject travels inside the ciphertext as a protected
        // header; this is the same placeholder the server-side path uses.
        lines.append("Subject: \(outerPlaceholderSubject)")
        lines.append("Date: \(sanitizeHeaderValue(envelope.date))")
        lines.append("MIME-Version: 1.0")
        lines.append(
            "Content-Type: multipart/encrypted; protocol=\"application/pgp-encrypted\"; "
            + "boundary=\"\(boundary)\""
        )
        lines.append("")
        lines.append("This is an OpenPGP/MIME encrypted message (RFC 3156).")
        lines.append("--\(boundary)")
        lines.append("Content-Type: application/pgp-encrypted")
        lines.append("Content-Description: PGP/MIME version identification")
        lines.append("")
        lines.append("Version: 1")
        lines.append("")
        lines.append("--\(boundary)")
        lines.append("Content-Type: application/octet-stream; name=\"encrypted.asc\"")
        lines.append("Content-Description: OpenPGP encrypted message")
        lines.append("Content-Disposition: inline; filename=\"encrypted.asc\"")
        lines.append("")
        lines.append(armoredMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        lines.append("--\(boundary)--")
        lines.append("")
        return lines.joined(separator: crlf)
    }

    /// Wraps the real content in a protected-headers part carrying the true
    /// Subject and, for a draft, its recipients.
    ///
    /// The outer envelope's Subject is a fixed placeholder, so this is the only
    /// place the real one travels. `PgpMimeReader` lifts it back out as
    /// `DecryptedBody.protectedSubject`. `to`, `cc` and `bcc` are for a draft
    /// saved to Drafts, whose outer envelope names only To: the Cc and Bcc the
    /// user typed travel only here, inside the ciphertext. The send path leaves
    /// them empty, and its bytes are then exactly what they were without them.
    static func buildProtectedContent(
        contentType: String,
        body: String,
        subject: String,
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        attachments: [OutgoingMimeAttachment] = [],
        boundaryToken: () -> String = randomBoundaryToken
    ) -> String {
        let clean = sanitizeHeaderValue(subject)
        let boundary = "kypost-protected-\(boundaryToken())"
        var headers: [String] = []
        if !clean.isEmpty { headers.append("Subject: \(clean)") }
        for (name, addresses) in [("To", to), ("Cc", cc), ("Bcc", bcc)] {
            let joined = joinAddresses(addresses)
            if !joined.isEmpty { headers.append("\(name): \(joined)") }
        }
        var lines = headers
        lines.append(
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"; protected-headers=\"v1\""
        )
        lines.append("")
        // The memoryhole convention. This app's own reader takes the subject
        // off the top-level header above, but Thunderbird, Mutt and K-9 look
        // for it here — without this part they show the outer placeholder
        // instead of the real subject.
        if !headers.isEmpty {
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/rfc822-headers; protected-headers=\"v1\"")
            lines.append("Content-Disposition: inline")
            lines.append("")
            lines.append(contentsOf: headers)
            lines.append("")
        }
        lines.append("--\(boundary)")
        lines.append("Content-Type: \(contentType)")
        lines.append("")
        lines.append(body)
        lines.append("")
        for attachment in attachments {
            let name = sanitizeHeaderValue(attachment.name).replacingOccurrences(of: "\"", with: "")
            lines.append("--\(boundary)")
            lines.append("Content-Type: \(sanitizeHeaderValue(attachment.mimeType)); name=\"\(name)\"")
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("Content-Disposition: attachment; filename=\"\(name)\"")
            lines.append("")
            // Attachment bytes are held as one unbroken base64 line. RFC 2045
            // caps an encoded line at 76 characters, and a parser that
            // enforces it would reject the part.
            lines.append(wrapBase64(attachment.dataBase64))
            lines.append("")
        }
        lines.append("--\(boundary)--")
        lines.append("")
        return lines.joined(separator: crlf)
    }

    /// The `Date` header, which the relay requires and does not synthesise.
    ///
    /// Fixed English abbreviations, and **not** a locale-dependent formatter:
    /// `DateFormatter` with `EEE, dd MMM yyyy HH:mm:ss Z` renders through the
    /// device locale and yields "Sal, 11 Ağu 2026" on a Turkish device — i.e.
    /// non-ASCII in an RFC 5322 header. `dateIsAsciiUnderANonEnglishLocale`
    /// is the guard against exactly that edit.
    static func rfc5322Date(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents(
            [.weekday, .day, .month, .year, .hour, .minute, .second], from: date
        )
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        let weekday = days[max(0, min(6, (parts.weekday ?? 1) - 1))]
        let month = months[max(0, min(11, (parts.month ?? 1) - 1))]
        return String(
            format: "%@, %02d %@ %04d %02d:%02d:%02d +0000",
            weekday,
            parts.day ?? 1,
            month,
            parts.year ?? 1970,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    static func randomBoundaryToken() -> String {
        (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Flattens CR/LF so a header value cannot inject additional headers.
    static func sanitizeHeaderValue(_ value: String) -> String {
        // **Iterates unicodeScalars, not Characters.** In Swift "\r\n" is a
        // single Character equal to neither "\r" nor "\n", so a Character
        // loop lets a CRLF through untouched — and this function is the only
        // thing standing between a header value and header injection. Caught
        // by headerInjectionIsFlattened, which failed against exactly that.
        //
        // A *run* of breaks collapses to one space rather than one space each,
        // matching what the other clients emit for the same input.
        var out = String.UnicodeScalarView()
        var lastWasBreak = false
        for scalar in value.unicodeScalars {
            if scalar == "\r" || scalar == "\n" {
                if !lastWasBreak { out.append(" ") }
                lastWasBreak = true
            } else {
                out.append(scalar)
                lastWasBreak = false
            }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    private static func joinAddresses(_ addresses: [String]) -> String {
        addresses.map(sanitizeHeaderValue).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func wrapBase64(_ data: String) -> String {
        let compact = data.filter { $0 != "\r" && $0 != "\n" }
        var lines: [String] = []
        var index = compact.startIndex
        while index < compact.endIndex {
            let end = compact.index(index, offsetBy: base64LineLength, limitedBy: compact.endIndex)
                ?? compact.endIndex
            lines.append(String(compact[index..<end]))
            index = end
        }
        return lines.joined(separator: crlf)
    }
}
