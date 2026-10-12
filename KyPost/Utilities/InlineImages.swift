//
//  InlineImages.swift
//  KyPost
//
//  Resolves `cid:` image references in a decrypted HTML body to bounded
//  `data:` URIs from the message's own parts. Port of kypost-android's
//  pgp/InlineImages.kt (#109).
//
//  Android rewrites a parsed jsoup document; Foundation has no HTML parser, so
//  this scans `<img>` tags outside comments and rewrites only their `src`
//  attribute. Anything it does not recognise is left exactly as it was — an
//  unresolved `cid:` stays in place and simply never loads, because the reader
//  fetches no subresource other than a `data:` image (see
//  `EmailBodyWebView.makeConfiguration`).
//

import Foundation

nonisolated enum InlineImages {
    /// Allowlist of *declared* raster MIME types. This does not inspect the
    /// bytes; it keeps an SVG (a document, with its own script and fetch
    /// surface) and anything stranger out of the rendered body.
    static let inlineableTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// Decoded-byte allowance for CID expansion in one message (Android
    /// `MemoryBudget.INLINE_IMAGE_BYTES`). A base64 image in an HTML string
    /// costs several times its bytes, and the sender chooses the size; larger
    /// parts remain available as attachments.
    static let byteBudget = 128 * 1024

    /// Rewrites `<img src="cid:…">` to a `data:` URI from the matching inline
    /// part, until `byteBudget` is spent. An image past the budget keeps its
    /// `cid:` source and renders as a broken image; the part is still listed
    /// as an attachment.
    static func inlineCidImages(html: String, attachments: [DecryptedAttachment]) -> String {
        let byId = Dictionary(
            attachments.compactMap { part -> (String, DecryptedAttachment)? in
                guard let id = part.contentId, inlineableTypes.contains(part.mimeType) else { return nil }
                return (id, part)
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard !html.isEmpty, !byId.isEmpty else { return html }

        let source = html as NSString
        var output = ""
        var cursor = 0
        var budget = byteBudget

        for match in imgTagOrComment.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            // A comment is matched only so its contents are skipped: markup
            // inside one is not an element and must not spend the budget.
            let tag = match.range(at: 1)
            guard tag.location != NSNotFound, let src = srcAttribute(in: source, tag: tag) else { continue }
            let value = source.substring(with: src.value).trimmingCharacters(in: .whitespaces)
            guard value.count > 4, value.prefix(4).lowercased() == "cid:" else { continue }
            let reference = String(value.dropFirst(4))
            guard let part = byId[reference] ?? reference.removingPercentEncoding.flatMap({ byId[$0] }),
                  part.data.count <= budget
            else { continue }
            budget -= part.data.count

            // Replace the whole attribute value, quotes included, with a
            // double-quoted data URI: base64 contains no quote to escape.
            let attributeValue = src.quoted
            output += source.substring(with: NSRange(location: cursor, length: attributeValue.location - cursor))
            output += "\"data:\(part.mimeType);base64,\(part.data.base64EncodedString())\""
            cursor = attributeValue.location + attributeValue.length
        }
        guard cursor > 0 else { return html }
        output += source.substring(from: cursor)
        return output
    }

    /// An HTML comment, or (capture group 1) an `<img …>` start tag whose
    /// quoted attribute values may contain `>`. A comment ends at `-->` or
    /// `--!>`, `<!-->` and `<!--->` close at once, and an unterminated one
    /// runs to the end of the input, as in HTML parsing.
    private static let imgTagOrComment = try! NSRegularExpression(
        pattern: #"<!--(?:-?>|[\s\S]*?(?:--!?>|\z))|(<img\b(?:[^>"']|"[^"]*"|'[^']*')*>)"#,
        options: [.caseInsensitive]
    )

    /// The tag's `src` attribute: `quoted` is the value with its quotes,
    /// `value` without. Walks the attributes in order, so text inside another
    /// attribute's quoted value (`alt='src="cid:x"'`) is never mistaken for
    /// one, and `data-src` is a different name. The first `src` wins, as in
    /// HTML parsing.
    private static func srcAttribute(
        in source: NSString, tag: NSRange
    ) -> (quoted: NSRange, value: NSRange)? {
        let end = tag.location + tag.length - 1  // the closing ">"
        var index = tag.location + 4             // past "<img"
        func char(_ at: Int) -> unichar { source.character(at: at) }
        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D }
        func skipSpace() { while index < end, isSpace(char(index)) { index += 1 } }

        while index < end {
            skipSpace()
            guard index < end else { break }
            if char(index) == 0x2F { index += 1; continue }  // "/"
            let nameStart = index
            while index < end, !isSpace(char(index)), char(index) != 0x3D, char(index) != 0x2F {
                index += 1
            }
            let name = source.substring(with: NSRange(location: nameStart, length: index - nameStart))
            skipSpace()
            guard index < end, char(index) == 0x3D else { continue }  // no value
            index += 1
            skipSpace()
            guard index < end else { break }
            let quoted: NSRange
            let value: NSRange
            let quote = char(index)
            if quote == 0x22 || quote == 0x27 {
                let open = index
                index += 1
                while index < end, char(index) != quote { index += 1 }
                guard index < end else { return nil }  // unterminated: leave it alone
                index += 1
                quoted = NSRange(location: open, length: index - open)
                value = NSRange(location: open + 1, length: index - open - 2)
            } else {
                let start = index
                while index < end, !isSpace(char(index)) { index += 1 }
                quoted = NSRange(location: start, length: index - start)
                value = quoted
            }
            if name.caseInsensitiveCompare("src") == .orderedSame { return (quoted, value) }
        }
        return nil
    }
}
