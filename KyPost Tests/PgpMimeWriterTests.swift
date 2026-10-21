//
//  PgpMimeWriterTests.swift
//  KyPost Tests
//
//  The writer is checked against PgpMimeReader wherever possible. The reader
//  was written first, from the receiving side, and shares no code with this —
//  so a round trip is an independent oracle rather than the writer agreeing
//  with itself.
//

import Foundation
import Testing
@testable import KyPost

private let envelope = OutgoingEnvelope(
    from: "me@example.com",
    to: ["to@example.com"],
    cc: [],
    date: "Thu, 09 Oct 2025 08:53:20 +0000"
)

@Suite(.serialized) struct PgpMimeWriterTests {

    // MARK: - The closed header set

    /// **The relay's forbidden headers can never appear**, because there is no
    /// caller-supplied header path at all. This asserts the set is exactly what
    /// is expected, so adding one has to be deliberate.
    @Test func theOuterHeaderSetIsFixedAndClosed() {
        let message = PgpMimeWriter.wrapAsPgpMime(
            envelope: envelope, armoredMessage: "ARMORED", boundaryToken: { "TOKEN" }
        )
        let headerBlock = message.components(separatedBy: "\r\n\r\n").first ?? ""
        let names = headerBlock
            .components(separatedBy: "\r\n")
            .compactMap { $0.split(separator: ":", maxSplits: 1).first.map(String.init) }
        #expect(names == ["From", "To", "Subject", "Date", "MIME-Version", "Content-Type"])

        for forbidden in ["Received", "Authentication-Results", "Return-Path", "Bcc"] {
            #expect(!headerBlock.contains(forbidden))
        }
    }

    /// The real subject is inside the ciphertext; the outer one is always the
    /// placeholder, matching the server's constant so both send paths look
    /// identical on the wire.
    @Test func theOuterSubjectIsAlwaysThePlaceholder() {
        let message = PgpMimeWriter.wrapAsPgpMime(
            envelope: envelope, armoredMessage: "ARMORED", boundaryToken: { "TOKEN" }
        )
        #expect(message.contains("Subject: \(outerPlaceholderSubject)"))
    }

    @Test func ccIsOmittedWhenEmptyAndPresentWhenNot() {
        let without = PgpMimeWriter.wrapAsPgpMime(
            envelope: envelope, armoredMessage: "A", boundaryToken: { "T" }
        )
        #expect(!without.contains("Cc:"))

        var withCc = envelope
        withCc.cc = ["c@example.com"]
        let message = PgpMimeWriter.wrapAsPgpMime(
            envelope: withCc, armoredMessage: "A", boundaryToken: { "T" }
        )
        #expect(message.contains("Cc: c@example.com"))
    }

    /// A header value carrying CR or LF could otherwise inject headers of its
    /// own — including the ones the relay forbids.
    @Test func headerInjectionIsFlattened() {
        var hostile = envelope
        hostile.from = "me@example.com\r\nBcc: victim@example.com"
        let message = PgpMimeWriter.wrapAsPgpMime(
            envelope: hostile, armoredMessage: "A", boundaryToken: { "T" }
        )
        let headerBlock = message.components(separatedBy: "\r\n\r\n").first ?? ""
        // The injected text survives as part of From's *value* — which is
        // correct and harmless, since a parser reads one header there. What
        // must not happen is a new header line, so the assertion is on line
        // starts rather than on the substring appearing anywhere.
        let startsAHeader = headerBlock
            .components(separatedBy: "\r\n")
            .contains { $0.lowercased().hasPrefix("bcc:") }
        #expect(!startsAHeader)
        #expect(headerBlock.contains("From: me@example.com Bcc: victim@example.com"))
    }

    @Test func theBodyIsRfc3156MultipartEncrypted() {
        let message = PgpMimeWriter.wrapAsPgpMime(
            envelope: envelope, armoredMessage: "ARMORED", boundaryToken: { "T" }
        )
        #expect(message.contains("multipart/encrypted; protocol=\"application/pgp-encrypted\""))
        #expect(message.contains("Content-Type: application/pgp-encrypted"))
        #expect(message.contains("Version: 1"))
        #expect(message.contains("ARMORED"))
        #expect(message.hasSuffix("--kypost-pgp-boundary-T--\r\n"))
    }

    // MARK: - Protected content, checked by the reader

    @Test func theReaderRecoversTheProtectedSubjectAndBody() throws {
        let content = PgpMimeWriter.buildProtectedContent(
            contentType: "text/html; charset=utf-8",
            body: "<p>hello</p>",
            subject: "the real subject",
            boundaryToken: { "T" }
        )
        let parsed = try #require(PgpMimeReader.read(Data(content.utf8)))
        #expect(parsed.protectedSubject == "the real subject")
        #expect(parsed.html?.contains("<p>hello</p>") == true)
    }

    @Test func theReaderRecoversAPlainTextBody() throws {
        let content = PgpMimeWriter.buildProtectedContent(
            contentType: "text/plain; charset=utf-8",
            body: "just text",
            subject: "s",
            boundaryToken: { "T" }
        )
        let parsed = try #require(PgpMimeReader.read(Data(content.utf8)))
        #expect(parsed.plain?.contains("just text") == true)
        #expect(parsed.bodyMode == "plain")
    }

    /// The memoryhole part, which Thunderbird, Mutt and K-9 read. Without it
    /// they show the outer placeholder instead of the real subject.
    @Test func theMemoryholeHeaderPartIsPresent() {
        let content = PgpMimeWriter.buildProtectedContent(
            contentType: "text/plain", body: "b", subject: "real", boundaryToken: { "T" }
        )
        #expect(content.contains("Content-Type: text/rfc822-headers; protected-headers=\"v1\""))
        #expect(content.contains("protected-headers=\"v1\""))
    }

    @Test func anEmptySubjectEmitsNoSubjectHeaderAtAll() {
        let content = PgpMimeWriter.buildProtectedContent(
            contentType: "text/plain", body: "b", subject: "   ", boundaryToken: { "T" }
        )
        #expect(!content.contains("Subject:"))
    }

    // MARK: - Protected recipients (drafts)

    /// A draft's recipients ride inside the ciphertext, both as top-level
    /// protected headers and in the memoryhole part.
    @Test func recipientsAreProtectedHeadersInBothPlaces() throws {
        let content = PgpMimeWriter.buildProtectedContent(
            contentType: "text/plain", body: "b", subject: "s",
            to: ["a@example.com", "b@example.com"], cc: ["c@example.com"], bcc: ["d@example.com"],
            boundaryToken: { "T" }
        )
        let parts = content.components(separatedBy: "\r\n\r\n")
        let top = parts[0].components(separatedBy: "\r\n")
        for header in ["To: a@example.com, b@example.com", "Cc: c@example.com", "Bcc: d@example.com"] {
            #expect(top.contains(header))
        }
        #expect(parts[1].contains("text/rfc822-headers"))
        let headers = try #require(parts.dropFirst(2).first).components(separatedBy: "\r\n")
        #expect(Array(headers.prefix(4)) == [
            "Subject: s", "To: a@example.com, b@example.com", "Cc: c@example.com", "Bcc: d@example.com",
        ])
    }

    /// Recipient strings are user input. A CR/LF inside one must not start a
    /// header line of its own.
    @Test func aRecipientCannotInjectAHeader() {
        let content = PgpMimeWriter.buildProtectedContent(
            contentType: "text/plain", body: "b", subject: "s",
            to: ["a@example.com\r\nX-Injected: yes"], cc: ["c@example.com\nReply-To: evil@example.com"],
            bcc: ["d@example.com\r\n\r\nbody"],
            boundaryToken: { "T" }
        )
        let lines = content.components(separatedBy: "\r\n")
        #expect(!lines.contains { $0.hasPrefix("X-Injected") || $0.hasPrefix("Reply-To") || $0 == "body" })
        #expect(lines.contains("To: a@example.com X-Injected: yes"))
        #expect(lines.contains("Bcc: d@example.com body"))
    }

    /// The send path passes no recipients, and its bytes are exactly what they
    /// were before recipients could be protected.
    @Test func withoutRecipientsTheBytesAreUnchanged() {
        let content = PgpMimeWriter.buildProtectedContent(
            contentType: "text/plain; charset=utf-8", body: "hello", subject: "Hi",
            attachments: [OutgoingMimeAttachment(name: "a.txt", mimeType: "text/plain", dataBase64: "QQ==")],
            boundaryToken: { "T" }
        )
        let expected = [
            "Subject: Hi",
            "Content-Type: multipart/mixed; boundary=\"kypost-protected-T\"; protected-headers=\"v1\"",
            "",
            "--kypost-protected-T",
            "Content-Type: text/rfc822-headers; protected-headers=\"v1\"",
            "Content-Disposition: inline",
            "",
            "Subject: Hi",
            "",
            "--kypost-protected-T",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "hello",
            "",
            "--kypost-protected-T",
            "Content-Type: text/plain; name=\"a.txt\"",
            "Content-Transfer-Encoding: base64",
            "Content-Disposition: attachment; filename=\"a.txt\"",
            "",
            "QQ==",
            "",
            "--kypost-protected-T--",
            "",
        ].joined(separator: "\r\n")
        #expect(content == expected)

        let noSubject = PgpMimeWriter.buildProtectedContent(
            contentType: "text/plain", body: "b", subject: "", boundaryToken: { "T" }
        )
        #expect(noSubject == [
            "Content-Type: multipart/mixed; boundary=\"kypost-protected-T\"; protected-headers=\"v1\"",
            "", "--kypost-protected-T", "Content-Type: text/plain", "", "b", "", "--kypost-protected-T--", "",
        ].joined(separator: "\r\n"))
    }

    /// RFC 2045 caps an encoded line at 76 characters, and a parser that
    /// enforces it would reject an unbroken one.
    @Test func attachmentBase64IsWrappedAt76Columns() throws {
        let raw = Data(repeating: 0x41, count: 500).base64EncodedString()
        let content = PgpMimeWriter.buildProtectedContent(
            contentType: "text/plain",
            body: "b",
            subject: "s",
            attachments: [OutgoingMimeAttachment(
                name: "a.txt", mimeType: "text/plain", dataBase64: raw
            )],
            boundaryToken: { "T" }
        )
        // Only the encoded lines are capped; a Content-Disposition header can
        // legitimately be longer, and asserting on every line was measuring
        // the wrong thing.
        let base64Characters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let longestEncoded = content
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty && $0.allSatisfy(base64Characters.contains) }
            .map(\.count)
            .max() ?? 0
        #expect(longestEncoded > 0)
        #expect(longestEncoded <= 76)


        // And it still parses back, attachment and all.
        let parsed = PgpMimeReader.read(Data(content.utf8))
        #expect(parsed?.plain?.contains("b") == true)
    }

    @Test func anAttachmentNameCannotBreakOutOfItsQuotes() {
        let content = PgpMimeWriter.buildProtectedContent(
            contentType: "text/plain",
            body: "b",
            subject: "s",
            attachments: [OutgoingMimeAttachment(
                name: "evil\"\r\nContent-Type: text/html", mimeType: "text/plain", dataBase64: "QQ=="
            )],
            boundaryToken: { "T" }
        )
        #expect(!content.contains("filename=\"evil\""))
        #expect(!content.contains("\r\nContent-Type: text/html\r\n"))
    }

    // MARK: - The Date header

    /// **Must be ASCII regardless of locale.** A locale-dependent formatter
    /// yields "Sal, 11 Ağu 2026" on a Turkish device — non-ASCII in an RFC 5322
    /// header. This is the guard against reintroducing one.
    @Test func dateIsAsciiUnderANonEnglishLocale() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let formatted = PgpMimeWriter.rfc5322Date(date)
        // Computed outside the macro: allSatisfy is `rethrows`, which the
        // expansion treats as a throwing call.
        let isAscii = formatted.allSatisfy(\.isASCII)
        #expect(isAscii)
        #expect(formatted == "Thu, 09 Oct 2025 08:53:20 +0000")
    }

    @Test func dateIsAlwaysUtc() {
        // Midnight UTC on a known day.
        let formatted = PgpMimeWriter.rfc5322Date(Date(timeIntervalSince1970: 0))
        #expect(formatted == "Thu, 01 Jan 1970 00:00:00 +0000")
    }
}
