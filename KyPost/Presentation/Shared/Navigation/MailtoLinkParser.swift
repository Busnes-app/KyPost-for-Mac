//
//  MailtoLinkParser.swift
//  KyPost
//
//  RFC 6068 `mailto:` URLs into a compose prefill. Port of kypost-android's
//  ComposeIntentParser.kt (#105) for the one external entry point this app
//  has: macOS hands `mailto:` links to the default mail app, and iOS hands
//  them here if anything opens one in this app.
//

import Foundation

enum MailtoLinkParser {
    /// Generous for any real link and small enough that a crafted one cannot
    /// stall compose by pasting megabytes into the editor.
    static let maxBodyCharacters = 100_000

    /// Nil for anything that is not a `mailto:` URL.
    ///
    /// Every value is plain text. The body becomes the compose body verbatim
    /// (compose builds an `AttributedString` from it, so markup is shown, not
    /// interpreted), and is flagged `bodyIsExternal` so no signature is placed
    /// above text another app asked to send. Header fields are flattened to
    /// one line. Only `to`, `cc`, `bcc`, `subject` and `body` are read; RFC
    /// 6068 calls other headers unsafe, and `in-reply-to` or `from` from a web
    /// page has no business steering this app.
    static func parse(_ url: URL) -> ComposeDraft? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        // Split on the encoded form: decoding the whole query first turns an
        // encoded `&` or `=` inside a value into a separator (the bug Android
        // hit with `MailTo.parse` on older releases).
        let raw = url.absoluteString
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let rest = raw[raw.index(after: colon)...]
        let path: Substring
        let query: Substring
        if let questionMark = rest.firstIndex(of: "?") {
            path = rest[rest.startIndex..<questionMark]
            query = rest[rest.index(after: questionMark)...]
        } else {
            path = rest
            query = ""
        }

        var to = [decode(path)]
        var cc: [String] = []
        var bcc: [String] = []
        var subject = ""
        var body = ""
        for field in query.split(separator: "&") {
            guard let equals = field.firstIndex(of: "=") else { continue }
            let name = decode(field[field.startIndex..<equals]).lowercased()
            let value = decode(field[field.index(after: equals)...])
            switch name {
            case "to": to.append(value)
            case "cc": cc.append(value)
            case "bcc": bcc.append(value)
            // First wins: a repeated subject or body is not a second message.
            case "subject": if subject.isEmpty { subject = value }
            case "body": if body.isEmpty { body = value }
            default: continue
            }
        }

        return ComposeDraft(
            to: addressList(to),
            cc: addressList(cc),
            bcc: addressList(bcc),
            subject: displayHeaderText(subject),
            body: String(
                body.replacingOccurrences(of: "\r\n", with: "\n").prefix(maxBodyCharacters)
            ),
            bodyIsExternal: true
        )
    }

    private static func decode(_ value: Substring) -> String {
        String(value).removingPercentEncoding ?? String(value)
    }

    /// Comma-joined, one line, blanks dropped. Validation stays with compose,
    /// which turns anything unparseable into a token `send()` refuses.
    private static func addressList(_ values: [String]) -> String {
        values.map(displayHeaderText).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
