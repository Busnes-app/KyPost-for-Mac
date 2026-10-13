//
//  InlineImages.swift
//  KyPost
//
//  Resolves `cid:` image references in a decrypted HTML body to bounded
//  `data:` URIs from the message's own parts. Port of kypost-android's
//  pgp/InlineImages.kt (#109).
//
//  Android rewrites a parsed jsoup document; Foundation has no HTML parser, so
//  this scans `<img>` tags outside comments and raw-text elements, and
//  rewrites only their `src` attribute. Anything it does not recognise is left
//  exactly as it was — an unresolved `cid:` stays in place and simply never
//  loads, because the reader fetches no subresource other than a `data:` image
//  (see `EmailBodyWebView.makeConfiguration`).
//
//  The scan is linear in the length of the body, however malformed it is: see
//  `MarkupScanner`.
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

    /// Longest HTML body, in UTF-16 code units, that is scanned for `cid:`
    /// images. A longer one renders as it came, without inline images (their
    /// parts are still listed as attachments). 1 Mi units is several times
    /// the largest ordinary HTML mail; it bounds the scan's own memory (about
    /// 10 bytes per unit) and its running time on any input.
    static let maxScannedLength = 1 << 20

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
        guard !html.isEmpty, !byId.isEmpty, html.utf16.count <= maxScannedLength else { return html }

        let source = html as NSString
        var output = ""
        var cursor = 0
        var budget = byteBudget

        // Comments and raw-text elements are skipped by the scanner: markup
        // inside them is text, not an element, and must not spend the budget.
        for tag in imageTags(in: source) {
            guard let src = srcAttribute(in: source, tag: tag) else { continue }
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

    /// The `<img …>` start tags of `source`, in document order, as an HTML
    /// parser would find them: not inside a comment, `<plaintext>`, or a
    /// raw-text/RCDATA element. Internal for tests.
    static func imageTags(in source: NSString) -> [NSRange] {
        var units = [unichar](repeating: 0, count: source.length)
        source.getCharacters(&units, range: NSRange(location: 0, length: source.length))
        var scanner = MarkupScanner(units: units)
        return scanner.imageTags()
    }

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

/// Finds, in document order, the regions an HTML parser reads as text and the
/// `<img>` start tags outside them:
/// - a comment. It ends at `-->` or `--!>`, `<!-->` and `<!--->` close at
///   once, and an unterminated one runs to the end of the input;
/// - `<plaintext>`, whose contents run to the end of the input;
/// - a raw-text or RCDATA element (`script`, `style`, `textarea`, `title`,
///   `xmp`, `iframe`, `noembed`, `noframes`), from its start tag to its own
///   end tag, or to the end of the input when there is none;
/// - an `<img …>` start tag; quoted attribute values may contain `>`.
///
/// Every step is linear. Tag names are compared by hand while they are ASCII,
/// and otherwise by a fixed-length pattern on a short window, so ICU's
/// case-insensitive matching (full case folding: `<ſcript>` is a script) and
/// its `\s` and `\b` apply exactly as they always have. The open-ended
/// parts are walked by hand: a start tag's attributes up to its `>`, memoised
/// per position so that start tags which never close cost nothing extra, and
/// comment and element bodies, which are consumed once.
private nonisolated struct MarkupScanner {
    private let units: [unichar]
    /// `tagEnds[p]`: the index of the `>` that ends a start tag whose
    /// attributes are walked from `p`, or -1 when none does. Built on first
    /// use.
    private var tagEnds: [Int] = []

    init(units: [unichar]) { self.units = units }

    private static let lt: unichar = 0x3C, gt: unichar = 0x3E, slash: unichar = 0x2F
    private static let bang: unichar = 0x21, dash: unichar = 0x2D
    private static let doubleQuote: unichar = 0x22, singleQuote: unichar = 0x27

    /// The raw-text and RCDATA element names, in the order both patterns
    /// list them. A capture group per name tells which one matched.
    private static let rawTextNames = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"]
    private static let rawTextGroups = rawTextNames.map { "(\($0))" }.joined(separator: "|")

    /// Group 1 a comment, 2 `<plaintext>`, 3...10 a raw-text element, 11 an
    /// `<img>`. No repetition, so each attempt reads at most `window` units.
    private static let openingTag = try! NSRegularExpression(
        pattern: #"<(?:(!--)|(plaintext)(?=[\s/>])|(?:"# + rawTextGroups + #")(?=[\s/>])|(img)\b)"#,
        options: [.caseInsensitive]
    )
    /// Groups 1...8 match `rawTextNames`.
    private static let closingTag = try! NSRegularExpression(
        pattern: #"</(?:"# + rawTextGroups + #")(?=[\s/>])"#,
        options: [.caseInsensitive]
    )
    /// Enough for `<`, `/`, the longest name and a surrogate pair after it.
    /// Case folding only ever makes the matched text shorter than the name.
    private static let window = 16

    private enum Opening {
        case comment, plaintext, rawText(Int), image
    }

    mutating func imageTags() -> [NSRange] {
        let count = units.count
        var tags: [NSRange] = []
        var index = 0
        while index < count {
            guard units[index] == Self.lt, let (opening, length) = opening(at: index) else {
                index += 1
                continue
            }
            switch opening {
            case .comment:
                index = commentEnd(from: index + length)
            case .plaintext:
                index = count
            case .rawText(let name):
                // A start tag that never closes is not an element; carry on
                // from the next character, as for anything else unrecognised.
                guard let close = tagEnd(from: index + length) else { index += 1; continue }
                index = rawTextEnd(name: name, from: close + 1)
            case .image:
                guard let close = tagEnd(from: index + length) else { index += 1; continue }
                tags.append(NSRange(location: index, length: close + 1 - index))
                index = close + 1
            }
        }
        return tags
    }

    /// Which construct opens at `index` (a `<`), and how many units its `<`
    /// and name take.
    private func opening(at index: Int) -> (Opening, Int)? {
        guard index + 1 < units.count else { return nil }
        if units[index + 1] == Self.bang {
            let isComment = index + 3 < units.count && units[index + 2] == Self.dash && units[index + 3] == Self.dash
            return isComment ? (.comment, 4) : nil
        }
        // Decided by hand while every unit read is ASCII, which is nearly
        // all real markup; ICU decides anything else.
        if let decided = asciiOpening(at: index) { return decided }
        guard let match = firstMatch(Self.openingTag, at: index) else { return nil }
        let length = match.range.length
        if match.range(at: 1).location != NSNotFound { return (.comment, length) }
        if match.range(at: 2).location != NSNotFound { return (.plaintext, length) }
        for name in Self.rawTextNames.indices where match.range(at: 3 + name).location != NSNotFound {
            return (.rawText(name), length)
        }
        return (.image, length)
    }

    /// The length of the end tag for raw-text element `name` at `index`, up
    /// to its name, or nil when there is none.
    private func closingTagLength(name: Int, at index: Int) -> Int? {
        if let decided = asciiMatch(Self.asciiNames[name], at: index + 2, then: .delimiter) {
            return decided ? 2 + Self.asciiNames[name].count : nil
        }
        guard let match = firstMatch(Self.closingTag, at: index),
              match.range(at: 1 + name).location != NSNotFound
        else { return nil }
        return match.range.length
    }

    /// What follows a name: `(?=[\s/>])`, or `\b` after `img`.
    private enum Follow { case delimiter, wordBoundary }

    private static let asciiNames = rawTextNames.map { Array($0.utf8) }
    private static let plaintextName = Array("plaintext".utf8), imgName = Array("img".utf8)

    /// `opening(at:)` decided without ICU: `.some(nil)` is no match, and nil
    /// means a non-ASCII unit was reached and ICU must decide. Tries the
    /// names in the patterns' own order.
    private func asciiOpening(at index: Int) -> (Opening, Int)?? {
        let start = index + 1
        guard let plaintext = asciiMatch(Self.plaintextName, at: start, then: .delimiter) else { return nil }
        if plaintext { return .some((.plaintext, 1 + Self.plaintextName.count)) }
        for name in Self.asciiNames.indices {
            guard let raw = asciiMatch(Self.asciiNames[name], at: start, then: .delimiter) else { return nil }
            if raw { return .some((.rawText(name), 1 + Self.asciiNames[name].count)) }
        }
        guard let image = asciiMatch(Self.imgName, at: start, then: .wordBoundary) else { return nil }
        return image ? .some((.image, 1 + Self.imgName.count)) : .some(nil)
    }

    /// Whether lowercase ASCII `name` starts at `start`, compared
    /// case-insensitively, and is followed as `follow` requires; nil as soon
    /// as a unit it must read is not ASCII. Up to then every unit is one
    /// letter, so ICU's full case folding cannot shift the comparison, and on
    /// ASCII its `\s` is tab through carriage return plus space and its `\w`
    /// is letters, digits and `_`.
    private func asciiMatch(_ name: [UInt8], at start: Int, then follow: Follow) -> Bool? {
        for (offset, letter) in name.enumerated() {
            guard start + offset < units.count else { return false }
            let unit = units[start + offset]
            guard unit < 0x80 else { return nil }
            guard unit | 0x20 == unichar(letter) else { return false }
        }
        let after = start + name.count
        guard after < units.count else { return follow == .wordBoundary }  // `\b` holds at the end
        let unit = units[after]
        guard unit < 0x80 else { return nil }
        switch follow {
        case .delimiter:
            return (0x09...0x0D).contains(unit) || unit == 0x20 || unit == Self.slash || unit == Self.gt
        case .wordBoundary:
            let isWord = (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit)
                || (0x61...0x7A).contains(unit) || unit == 0x5F
            return !isWord
        }
    }

    private func firstMatch(_ pattern: NSRegularExpression, at index: Int) -> NSTextCheckingResult? {
        let length = min(Self.window, units.count - index)
        let text = units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress! + index, length: length) }
        return pattern.firstMatch(in: text as String, options: .anchored, range: NSRange(location: 0, length: length))
    }

    /// Where a start tag's attributes, walked from `start`, end: the index of
    /// its `>`, or nil when it never closes. A quoted value runs to the next
    /// matching quote and may contain `>`; an unterminated one means the tag
    /// never closes.
    private mutating func tagEnd(from start: Int) -> Int? {
        if tagEnds.isEmpty { tagEnds = Self.tagEnds(units) }
        let end = tagEnds[start]
        return end < 0 ? nil : end
    }

    /// `tagEnds` for every position, right to left, so each is computed once.
    private static func tagEnds(_ units: [unichar]) -> [Int] {
        var ends = [Int](repeating: -1, count: units.count + 1)
        var nextDouble = -1, nextSingle = -1  // the next quote after the current position
        for index in stride(from: units.count - 1, through: 0, by: -1) {
            switch units[index] {
            case gt:
                ends[index] = index
            case doubleQuote:
                ends[index] = nextDouble < 0 ? -1 : ends[nextDouble + 1]
                nextDouble = index
            case singleQuote:
                ends[index] = nextSingle < 0 ? -1 : ends[nextSingle + 1]
                nextSingle = index
            default:
                ends[index] = ends[index + 1]
            }
        }
        return ends
    }

    /// Just past a comment whose `<!--` ends at `start`.
    private func commentEnd(from start: Int) -> Int {
        let count = units.count
        if start < count, units[start] == Self.gt { return start + 1 }  // <!-->
        if start + 1 < count, units[start] == Self.dash, units[start + 1] == Self.gt { return start + 2 }  // <!--->
        var index = start
        while index + 2 < count {
            if units[index] == Self.dash, units[index + 1] == Self.dash {
                if units[index + 2] == Self.gt { return index + 3 }
                if units[index + 2] == Self.bang, index + 3 < count, units[index + 3] == Self.gt { return index + 4 }
            }
            index += 1
        }
        return count
    }

    /// Just past the end tag of raw-text element `name` whose contents begin
    /// at `start`, or the end of the input when it has none.
    private func rawTextEnd(name: Int, from start: Int) -> Int {
        let count = units.count
        var index = start
        while index + 1 < count {
            if units[index] == Self.lt, units[index + 1] == Self.slash,
               let length = closingTagLength(name: name, at: index) {
                var close = index + length
                while close < count, units[close] != Self.gt { close += 1 }
                return close < count ? close + 1 : count
            }
            index += 1
        }
        return count
    }
}
