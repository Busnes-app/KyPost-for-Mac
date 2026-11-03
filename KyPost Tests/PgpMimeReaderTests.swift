//
//  PgpMimeReaderTests.swift
//  KyPost Tests
//
//  This parser is hand-written rather than borrowed, so it carries the burden
//  of proof: every rule the Android original documented gets a case here,
//  including the ones that only matter for adversarial or malformed input.
//

import Foundation
import Testing
@testable import KyPost

private func read(_ text: String) -> DecryptedBody? {
    PgpMimeReader.read(Data(text.utf8))
}

@Suite(.serialized) struct PgpMimeReaderTests {

    @Test func readsAPlainTextMessage() throws {
        let body = try #require(read("Content-Type: text/plain\r\n\r\nhello there\r\n"))
        #expect(body.plain?.contains("hello there") == true)
        #expect(body.html == nil)
        #expect(body.bodyMode == "plain")
    }

    @Test func readsAnHtmlMessage() throws {
        let body = try #require(read("Content-Type: text/html\r\n\r\n<p>hi</p>\r\n"))
        #expect(body.html?.contains("<p>hi</p>") == true)
        #expect(body.bodyMode == "html")
    }

    /// Bare LF, not just CRLF. Decrypted output has been through a compressor
    /// and a mail chain; insisting on CRLF loses real messages.
    @Test func acceptsBareLineFeeds() throws {
        let body = try #require(read("Content-Type: text/plain\n\nunix line endings\n"))
        #expect(body.plain?.contains("unix line endings") == true)
    }

    @Test func foldedHeadersAreJoined() throws {
        let body = try #require(read(
            "Content-Type: multipart/alternative;\r\n boundary=\"xyz\"\r\n\r\n"
            + "--xyz\r\nContent-Type: text/plain\r\n\r\nfolded worked\r\n"
            + "--xyz--\r\n"
        ))
        #expect(body.plain?.contains("folded worked") == true)
    }

    @Test func prefersHtmlAndPlainTogetherFromMultipartAlternative() throws {
        let body = try #require(read(
            "Content-Type: multipart/alternative; boundary=\"b\"\r\n\r\n"
            + "--b\r\nContent-Type: text/plain\r\n\r\nthe plain one\r\n"
            + "--b\r\nContent-Type: text/html\r\n\r\n<b>the html one</b>\r\n"
            + "--b--\r\n"
        ))
        #expect(body.plain?.contains("the plain one") == true)
        #expect(body.html?.contains("the html one") == true)
        #expect(body.bodyMode == "html")
    }

    /// **A blank part must not lock the slot.** A later sibling with real
    /// content has to win, or the message renders blank with no error and
    /// nothing to explain it.
    @Test func aBlankPartDoesNotLockOutARealOneLater() throws {
        let body = try #require(read(
            "Content-Type: multipart/alternative; boundary=\"b\"\r\n\r\n"
            + "--b\r\nContent-Type: text/html\r\n\r\n\r\n"
            + "--b\r\nContent-Type: text/html\r\n\r\n<i>real content</i>\r\n"
            + "--b--\r\n"
        ))
        #expect(body.html?.contains("real content") == true)
    }

    /// The other half of that rule: an all-blank multipart is still a message,
    /// so it yields empty rather than nil.
    @Test func anAllBlankMultipartIsEmptyRatherThanAbsent() throws {
        let body = try #require(read(
            "Content-Type: multipart/alternative; boundary=\"b\"\r\n\r\n"
            + "--b\r\nContent-Type: text/plain\r\n\r\n\r\n"
            + "--b--\r\n"
        ))
        #expect(body.plain == "")
    }

    @Test func decodesBase64Parts() throws {
        let encoded = Data("base64 decoded fine".utf8).base64EncodedString()
        let body = try #require(read(
            "Content-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\n\(encoded)\r\n"
        ))
        #expect(body.plain?.contains("base64 decoded fine") == true)
    }

    @Test func decodesQuotedPrintableIncludingSoftLineBreaks() throws {
        let body = try #require(read(
            "Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
            + "caf=C3=A9 and a soft=\r\n break\r\n"
        ))
        #expect(body.plain?.contains("café") == true)
        // The soft break joins the line rather than appearing in it.
        #expect(body.plain?.contains("soft break") == true)
    }

    @Test func honoursACharsetOtherThanUtf8() throws {
        var raw = Data("Content-Type: text/plain; charset=iso-8859-1\r\n\r\n".utf8)
        raw.append(0xE9)  // é in Latin-1
        let body = try #require(PgpMimeReader.read(raw))
        #expect(body.plain?.contains("é") == true)
    }

    /// The header subject of an encrypted message is plaintext on the wire, so
    /// the real one travels inside.
    @Test func readsAProtectedSubject() throws {
        let body = try #require(read(
            "Content-Type: text/plain\r\nSubject: the real subject\r\n\r\nbody\r\n"
        ))
        #expect(body.protectedSubject == "the real subject")
    }

    @Test func decodesAnEncodedWordSubject() throws {
        let encoded = Data("café meeting".utf8).base64EncodedString()
        let body = try #require(read(
            "Content-Type: text/plain\r\nSubject: =?utf-8?B?\(encoded)?=\r\n\r\nbody\r\n"
        ))
        #expect(body.protectedSubject == "café meeting")
    }

    @Test func aBlankSubjectIsNoSubject() throws {
        let body = try #require(read("Content-Type: text/plain\r\nSubject:   \r\n\r\nbody\r\n"))
        #expect(body.protectedSubject == nil)
    }

    /// An attachment is not the body, however textual it is.
    @Test func anAttachmentIsNotTreatedAsTheBody() throws {
        let body = try #require(read(
            "Content-Type: multipart/mixed; boundary=\"b\"\r\n\r\n"
            + "--b\r\nContent-Type: text/plain\r\n\r\nthe actual body\r\n"
            + "--b\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=\"a.txt\"\r\n\r\n"
            + "attachment contents\r\n"
            + "--b--\r\n"
        ))
        #expect(body.plain?.contains("the actual body") == true)
        #expect(body.plain?.contains("attachment contents") != true)
    }

    @Test func walksNestedMultiparts() throws {
        let body = try #require(read(
            "Content-Type: multipart/mixed; boundary=\"outer\"\r\n\r\n"
            + "--outer\r\nContent-Type: multipart/alternative; boundary=\"inner\"\r\n\r\n"
            + "--inner\r\nContent-Type: text/html\r\n\r\n<p>nested</p>\r\n"
            + "--inner--\r\n"
            + "--outer--\r\n"
        ))
        #expect(body.html?.contains("nested") == true)
    }

    // MARK: - Refusals

    /// Random bytes are not a message. Putting unparsed input into a WebView is
    /// not a degradation this accepts, so the caller gets nil and renders an
    /// exit-table row instead.
    @Test func bytesWithNoContentTypeAndNoContentAreNotAMessage() {
        #expect(PgpMimeReader.read(Data([0x00, 0x01, 0x02, 0x03])) == nil)
        #expect(PgpMimeReader.read(Data()) == nil)
    }

    /// The distinction the Android original drew: an empty body under a
    /// Content-Type that really was present is real ("no body, attachment
    /// only" is a legitimate message), while an empty body with no header at
    /// all came from RFC 2045's default and means nothing.
    @Test func anEmptyBodyUnderARealContentTypeIsKept() throws {
        let body = try #require(read("Content-Type: text/plain\r\n\r\n"))
        #expect(body.plain == "")
    }

    /// Hostile input must not be able to recurse until the stack gives out.
    @Test func deeplyNestedMultipartsTerminate() {
        var text = ""
        for depth in 0..<40 {
            text += "Content-Type: multipart/mixed; boundary=\"b\(depth)\"\r\n\r\n--b\(depth)\r\n"
        }
        text += "Content-Type: text/plain\r\n\r\ntoo deep\r\n"
        // The assertion is that this returns at all rather than crashing.
        _ = PgpMimeReader.read(Data(text.utf8))
    }

    /// Deep enough to exhaust a thread's stack if parsing recursed past the
    /// depth the walk reads: about 60 bytes a level, so any sender can. The
    /// trailing `x` keeps one level's boundary from being a prefix of a
    /// deeper one's (`b1` of `b10`), which would split the nesting into
    /// siblings instead.
    @Test func thousandsOfNestedMultipartsDoNotExhaustTheStack() {
        var text = ""
        for depth in 0..<10_000 {
            text += "Content-Type: multipart/mixed; boundary=\"b\(depth)x\"\r\n\r\n--b\(depth)x\r\n"
        }
        text += "Content-Type: text/plain\r\n\r\ntoo deep\r\n"
        _ = PgpMimeReader.read(Data(text.utf8))
    }

    /// A flat flood of empty parts is a few bytes each; parsing stops at the
    /// part budget instead of building one value per delimiter, and says
    /// that something was left out.
    @Test func aFloodOfEmptyPartsIsCut() throws {
        let text = "Content-Type: multipart/mixed; boundary=\"a\"\r\n\r\n"
            + "--a\r\nContent-Type: text/plain\r\n\r\nfirst\r\n"
            + String(repeating: "--a\r\n", count: 500_000)
        let body = try #require(PgpMimeReader.read(Data(text.utf8)))
        #expect(body.plain == "first")
        #expect(body.attachmentsOmitted)
    }
}
