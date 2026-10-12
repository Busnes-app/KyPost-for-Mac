//
//  InlineImages.swift
//  KyPost
//
//  Resolves `cid:` image references in a decrypted HTML body to bounded
//  `data:` URIs from the message's own parts. Port of kypost-android's
//  pgp/InlineImages.kt (#109).
//
//  Android rewrites a parsed jsoup document; Foundation has no HTML parser, so
//  this scans `<img>` tags and rewrites only their `src` attribute. Anything it
//  does not recognise is left exactly as it was — an unresolved `cid:` stays in
//  place and simply never loads, because the reader fetches no subresource
//  other than a `data:` image (see `EmailBodyWebView.makeConfiguration`).
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

        for tag in imgTag.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            guard let src = srcAttribute.firstMatch(in: html, range: tag.range) else { continue }
            let valueRange = (2...4).map { src.range(at: $0) }.first { $0.location != NSNotFound }
            guard let valueRange else { continue }
            let value = source.substring(with: valueRange).trimmingCharacters(in: .whitespaces)
            guard value.count > 4, value.prefix(4).lowercased() == "cid:" else { continue }
            let reference = String(value.dropFirst(4))
            guard let part = byId[reference] ?? reference.removingPercentEncoding.flatMap({ byId[$0] }),
                  part.data.count <= budget
            else { continue }
            budget -= part.data.count

            // Replace the whole attribute value, quotes included, with a
            // double-quoted data URI: base64 contains no quote to escape.
            let attributeValue = src.range(at: 1)
            output += source.substring(with: NSRange(location: cursor, length: attributeValue.location - cursor))
            output += "\"data:\(part.mimeType);base64,\(part.data.base64EncodedString())\""
            cursor = attributeValue.location + attributeValue.length
        }
        guard cursor > 0 else { return html }
        output += source.substring(from: cursor)
        return output
    }

    /// An `<img …>` start tag; quoted attribute values may contain `>`.
    private static let imgTag = try! NSRegularExpression(
        pattern: #"<img\b(?:[^>"']|"[^"]*"|'[^']*')*>"#,
        options: [.caseInsensitive]
    )

    /// A `src` attribute — preceded by whitespace, so `data-src` is not it.
    /// Group 1 is the whole value with its quotes; 2–4 are the bare value.
    private static let srcAttribute = try! NSRegularExpression(
        pattern: #"\ssrc\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))"#,
        options: [.caseInsensitive]
    )
}
