//
//  PgpMimeReader.swift
//  KyPost
//
//  Parses decrypted PGP/MIME bytes into the parts the reader renders. Swift
//  port of kypost-android's pgp/PgpMimeReader.kt.
//
//  Android leaned on `angus.mail`. Foundation has no MIME parser and this app
//  has one external dependency already, so the subset PGP/MIME actually uses is
//  implemented here: headers, multipart boundaries, base64 and
//  quoted-printable, and RFC 2047 encoded-words in the protected subject.
//
//  Returns nil rather than throwing on anything unparseable. The caller renders
//  an exit-table row; putting unparsed bytes into a WebView is not a
//  degradation this accepts.
//

import Foundation

nonisolated enum PgpMimeReader {

    /// Guards against a pathological nesting depth in hostile input. Real
    /// PGP/MIME is two or three levels; this is only here so a crafted message
    /// cannot recurse until the stack gives out.
    private static let maxDepth = 12

    /// Total decoded attachment bytes retained from one message (Android
    /// `MemoryBudget.DECRYPTED_ATTACHMENT_BYTES`). They live for the life of
    /// the reader screen, so the sender does not get to choose how much.
    static let attachmentByteCap = 4 * 1024 * 1024

    /// A sender chooses the part count too; retained objects are capped as
    /// well as bytes (`DECRYPTED_ATTACHMENT_PART_COUNT`).
    static let attachmentPartCap = 50

    static func read(_ mime: Data) -> DecryptedBody? {
        let root = parse(mime)

        var walk = Walk()
        walk.noteSignature(root)
        if root.children.isEmpty {
            // A single-part message: its own content type decides, with RFC
            // 2045's text/plain default for a missing header.
            walk.takeLeaf(root)
        } else {
            walk.collect(root, depth: 0)
        }

        // A body with no recognised Content-Type is RFC 2045's default of
        // text/plain. An empty one there came from the default rather than
        // from anything parsed, so it is treated as absent — whereas an empty
        // body under a Content-Type header that *was* present is real content
        // ("no body, attachment only" is a legitimate message).
        if root.contentType == nil, walk.plain?.isEmpty == true, walk.html == nil {
            walk.plain = nil
        }

        // Attachments are content: a files-only message renders an empty body
        // and its files, rather than failing as unreadable.
        if walk.html == nil, walk.plain == nil {
            guard !walk.attachments.isEmpty else { return nil }
            walk.plain = ""
        }

        return DecryptedBody(
            html: walk.html,
            plain: walk.plain,
            bodyMode: walk.html != nil ? "html" : "plain",
            protectedSubject: root.headerValue("subject")
                .map(decodeEncodedWords)
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
            attachments: walk.attachments,
            attachmentsOmitted: walk.omitted,
            hasDetachedSignature: walk.hasDetachedSignature
        )
    }

    // MARK: - Walking

    private struct Walk {
        var html: String?
        var plain: String?
        var attachments: [DecryptedAttachment] = []
        var omitted = false
        var retained = 0
        var hasDetachedSignature = false

        /// A declared PGP/MIME signature wrapper, at the root or nested. It is
        /// detected, not verified: presence establishes neither validity nor a
        /// signer, only that "not signed" would be false.
        mutating func noteSignature(_ part: Part) {
            guard part.mimeType == "multipart/signed",
                  parameter("protocol", of: part.contentType)?
                      .caseInsensitiveCompare("application/pgp-signature") == .orderedSame
            else { return }
            hasDetachedSignature = true
        }

        /// Fills the html and plain slots and the attachment list from a
        /// multipart's children.
        ///
        /// A blank part is real content — a multipart whose only text part is
        /// empty must yield `""` rather than nil. But it must not *lock* the
        /// slot: a later sibling with actual content has to win, or the
        /// message renders blank with no error and nothing to explain it.
        mutating func collect(_ part: Part, depth: Int) {
            guard depth <= maxDepth else { return }
            let isSigned = part.mimeType == "multipart/signed"
            for child in part.children {
                noteSignature(child)
                // The detached signature of a multipart/signed is transport,
                // like the outer PGP/MIME parts — not a file the sender
                // attached for the reader.
                if isSigned, child.mimeType == "application/pgp-signature" { continue }
                if child.isAttachment {
                    keepAttachment(child)
                } else if !child.children.isEmpty {
                    collect(child, depth: depth + 1)
                } else {
                    takeLeaf(child)
                }
            }
        }

        mutating func takeLeaf(_ part: Part) {
            switch part.mimeType {
            case "text/html":
                if html == nil || html?.isEmpty == true { html = part.text }
            case "text/plain":
                if plain == nil || plain?.isEmpty == true { plain = part.text }
            default:
                // A multipart that would not split (no boundary) has nothing
                // this reader can show; anything else non-text is a file.
                if !part.mimeType.hasPrefix("multipart/") { keepAttachment(part) }
            }
        }

        /// Keeps one attachment within the part and byte caps. A part that
        /// would cross the byte ceiling is dropped whole rather than
        /// truncated — a partial file is worse than a missing one — and the
        /// drop is recorded so the screen can say so.
        mutating func keepAttachment(_ part: Part) {
            guard attachments.count < attachmentPartCap else {
                omitted = true
                return
            }
            let bytes = part.decodedBody
            guard bytes.count <= attachmentByteCap - retained else {
                omitted = true
                return
            }
            retained += bytes.count
            attachments.append(DecryptedAttachment(
                name: part.fileName ?? "attachment",
                mimeType: part.contentType == nil ? "application/octet-stream" : part.mimeType,
                data: bytes,
                contentId: part.contentId
            ))
        }
    }

    // MARK: - Parsing

    private struct Part {
        var headers: [(name: String, value: String)] = []
        var body: Data = Data()
        var children: [Part] = []
        var contentType: String?

        func headerValue(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var mimeType: String {
            guard let contentType else { return "text/plain" }
            return contentType
                .split(separator: ";", maxSplits: 1)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        }

        /// A `text/html` or `text/plain` leaf is a body candidate unless its
        /// disposition says attachment: a `name=` parameter or a `Content-ID`
        /// on a text part never makes it a file — many mailers stamp both on
        /// every part, the body included. Non-text, non-multipart leaves are
        /// attachments whatever their headers say.
        var isAttachment: Bool {
            if headerValue("content-disposition")?.lowercased().hasPrefix("attachment") == true {
                return true
            }
            if mimeType == "text/html" || mimeType == "text/plain" { return false }
            return children.isEmpty && !mimeType.hasPrefix("multipart/")
        }

        /// The transfer-decoded bytes of a leaf part.
        var decodedBody: Data {
            decodeTransfer(
                body,
                encoding: headerValue("content-transfer-encoding")?
                    .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            )
        }

        /// The decoded, charset-interpreted text of a leaf part.
        var text: String {
            decodeText(decodedBody, charset: parameter("charset", of: contentType))
        }

        /// The sender's filename: Content-Disposition `filename` (RFC 2231
        /// `filename*` included), else Content-Type `name`. Display text only
        /// — every sink that writes a file sanitises it itself.
        var fileName: String? {
            let disposition = headerValue("content-disposition")
            let raw = parameter("filename", of: disposition)
                ?? parameter("filename*", of: disposition).map(decodeRFC2231)
                ?? parameter("name", of: contentType)
            let name = raw.map(decodeEncodedWords)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return name?.isEmpty == false ? name : nil
        }

        /// `Content-ID` without its angle brackets, for `cid:` references.
        var contentId: String? {
            guard var value = headerValue("content-id")?.trimmingCharacters(in: .whitespaces)
            else { return nil }
            if value.hasPrefix("<") { value.removeFirst() }
            if value.hasSuffix(">") { value.removeLast() }
            value = value.trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }

    private static func parse(_ data: Data) -> Part {
        var part = Part()
        let (headerBytes, bodyBytes) = splitHeaders(data)
        part.headers = parseHeaders(headerBytes)
        part.body = bodyBytes
        part.contentType = part.headerValue("content-type")

        guard part.mimeType.hasPrefix("multipart/"),
              let boundary = parameter("boundary", of: part.contentType), !boundary.isEmpty
        else { return part }

        part.children = splitMultipart(bodyBytes, boundary: boundary).map(parse)
        return part
    }

    /// Splits at the first blank line, tolerating both CRLF and bare LF —
    /// decrypted output has been through a compressor and a mail chain, and
    /// insisting on CRLF here loses real messages.
    private static func splitHeaders(_ data: Data) -> (Data, Data) {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                // \n\n
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    return (Data(bytes[0..<index]), Data(bytes[(index + 2)...]))
                }
                // \n\r\n
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    return (Data(bytes[0..<index]), Data(bytes[(index + 3)...]))
                }
            }
            index += 1
        }
        return (data, Data())
    }

    private static func parseHeaders(_ data: Data) -> [(name: String, value: String)] {
        // CRLF is normalised away *before* splitting, because in Swift "\r\n"
        // is a single Character — one grapheme cluster — so
        // `split(separator: "\n")` does not split it at all. Without this a
        // two-header block parses as one header whose value swallows every
        // line after the first, and the Content-Type ends up unrecognisable.
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var headers: [(name: String, value: String)] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty { continue }
            // A continuation line: folded headers belong to the previous one.
            if line.first == " " || line.first == "\t" {
                guard !headers.isEmpty else { continue }
                headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((
                name: String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces),
                value: String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            ))
        }
        return headers
    }

    /// Splits a multipart body on its boundary.
    private static func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var searchFrom = data.startIndex
        var currentStart: Int?

        while let found = data.range(of: delimiter, in: searchFrom..<data.endIndex) {
            // Only a boundary at the start of a line counts; the same bytes
            // inside a body are content.
            let atLineStart = found.lowerBound == data.startIndex
                || data[data.index(before: found.lowerBound)] == 0x0A
            if atLineStart {
                if let start = currentStart {
                    var end = found.lowerBound
                    // Drop the CRLF that belongs to the delimiter, not the part.
                    if end > start, data[data.index(before: end)] == 0x0A { end = data.index(before: end) }
                    if end > start, data[data.index(before: end)] == 0x0D { end = data.index(before: end) }
                    parts.append(data[start..<end])
                }
                // The closing delimiter is `--boundary--`.
                let after = found.upperBound
                if after < data.endIndex,
                   data[after] == 0x2D,
                   data.index(after: after) < data.endIndex,
                   data[data.index(after: after)] == 0x2D {
                    return parts
                }
                currentStart = skipToLineStart(data, from: after)
            }
            searchFrom = found.upperBound
        }

        if let start = currentStart, start < data.endIndex {
            parts.append(data[start..<data.endIndex])
        }
        return parts
    }

    private static func skipToLineStart(_ data: Data, from index: Data.Index) -> Data.Index {
        var cursor = index
        while cursor < data.endIndex, data[cursor] != 0x0A { cursor = data.index(after: cursor) }
        return cursor < data.endIndex ? data.index(after: cursor) : data.endIndex
    }

    // MARK: - Decoding

    private static func parameter(_ name: String, of headerValue: String?) -> String? {
        guard let headerValue else { return nil }
        for piece in headerValue.split(separator: ";").dropFirst() {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            guard key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            var value = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    /// RFC 2231 `charset'language'percent-encoded` — single-segment only;
    /// continuations (`filename*0*=`) are rare enough to fall back to the
    /// Content-Type name or "attachment".
    private static func decodeRFC2231(_ value: String) -> String {
        let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return value }
        let charset = String(pieces[0])
        var bytes: [UInt8] = []
        var scalars = Array(pieces[2].utf8)[...]
        while let byte = scalars.popFirst() {
            if byte == 0x25, scalars.count >= 2,
               let high = hexValue(scalars[scalars.startIndex]),
               let low = hexValue(scalars[scalars.startIndex + 1]) {
                bytes.append(high << 4 | low)
                scalars = scalars.dropFirst(2)
            } else {
                bytes.append(byte)
            }
        }
        return decodeText(Data(bytes), charset: charset)
    }

    private static func decodeTransfer(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            // Ignoring line breaks is required, not lenient: base64 in MIME is
            // wrapped at 76 columns by definition.
            let text = String(decoding: data, as: UTF8.self)
                .components(separatedBy: .whitespacesAndNewlines).joined()
            return Data(base64Encoded: text) ?? data
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            return data
        }
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x3D else {  // '='
                out.append(bytes[index])
                index += 1
                continue
            }
            // A soft line break: '=' at end of line means "no break here".
            if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                index += 2
                continue
            }
            if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                index += 3
                continue
            }
            if index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]),
               let low = hexValue(bytes[index + 2]) {
                out.append(high << 4 | low)
                index += 3
                continue
            }
            // A stray '=' that decodes to nothing is kept rather than dropped.
            out.append(bytes[index])
            index += 1
        }
        return Data(out)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private static func decodeText(_ data: Data, charset: String?) -> String {
        let name = (charset ?? "utf-8").lowercased()
        switch name {
        case "utf-8", "utf8", "us-ascii", "ascii", "":
            return String(decoding: data, as: UTF8.self)
        case "iso-8859-1", "latin1", "iso8859-1":
            return String(data: data, encoding: .isoLatin1)
                ?? String(decoding: data, as: UTF8.self)
        case "windows-1252", "cp1252":
            return String(data: data, encoding: .windowsCP1252)
                ?? String(decoding: data, as: UTF8.self)
        default:
            // Unknown charset: UTF-8 is the only sane guess, and its decoder
            // substitutes rather than failing, so nothing is lost outright.
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Decodes RFC 2047 `=?charset?B?...?=` / `?Q?...?=` words.
    ///
    /// Only for the protected subject. A subject is the one header this reader
    /// surfaces, and non-ASCII subjects arrive encoded far more often than not.
    static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        var result = ""
        var rest = Substring(value)

        // An explicit scan rather than splitting on "?": the payload of a
        // B-encoded word ends in "=" padding, so a split-and-index approach
        // mistakes the padding for a delimiter and hands back the raw word.
        while let open = rest.range(of: "=?") {
            result += rest[rest.startIndex..<open.lowerBound]
            let after = rest[open.upperBound...]

            guard let charsetEnd = after.firstIndex(of: "?"),
                  case let afterCharset = after[after.index(after: charsetEnd)...],
                  let encodingEnd = afterCharset.firstIndex(of: "?"),
                  let close = afterCharset.range(of: "?=")
            else {
                // Not a well-formed encoded word; keep it verbatim rather than
                // dropping text the user was meant to read.
                result += rest[open.lowerBound...]
                return result
            }

            let charset = String(after[after.startIndex..<charsetEnd])
            let encoding = afterCharset[afterCharset.startIndex..<encodingEnd]
            let payload = afterCharset[afterCharset.index(after: encodingEnd)..<close.lowerBound]

            let decoded: Data? = switch encoding.first {
            case "B", "b":
                Data(base64Encoded: String(payload))
            case "Q", "q":
                // RFC 2047 Q-encoding differs from quoted-printable in exactly
                // one place: "_" means a space.
                decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            default:
                nil
            }

            result += decoded.map { decodeText($0, charset: charset) } ?? String(payload)
            rest = afterCharset[close.upperBound...]
        }
        result += rest
        return result
    }
}
