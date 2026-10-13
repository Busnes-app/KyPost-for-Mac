//
//  VCard.swift
//  KyPost
//
//  RFC 6350 (4.0) / RFC 2426 (3.0) text for contacts, for "Share as vCard"
//  and "Export All". Swift port of kypost-android's contacts/VCard.kt.
//
//  Covers name, nickname, org, title, email, phone, address, URL, birthday and
//  note. IMs, relations, events, custom fields, pronouns, phonetic names, PGP
//  keys, photos, groups and the server uid are not exported.
//
//  Every value is escaped and stripped of control characters, iterating
//  **unicode scalars**: in Swift "\r\n" is one Character equal to neither "\r"
//  nor "\n", so a Character loop lets CRLF through and a field could end the
//  card and start another (the same trap as `sanitizeHeaderValue`).
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated enum VCardVersion: String, CaseIterable, Sendable {
    case v4 = "4.0"
    case v3 = "3.0"
}

nonisolated enum VCardWriter {
    static let mimeType = "text/vcard"

    static func write(_ contacts: [Contact], version: VCardVersion) -> String {
        var out = ""
        for contact in contacts { appendCard(contact, version: version, to: &out) }
        return out
    }

    private static func appendCard(_ c: Contact, version: VCardVersion, to out: inout String) {
        line("BEGIN:VCARD", &out)
        line("VERSION:\(version.rawValue)", &out)
        line("FN:\(escapeText(c.name))", &out)
        line("N:" + [c.familyName, c.givenName, c.middleName, c.prefix, c.suffix].map(escapeText).joined(separator: ";"), &out)
        if isPresent(c.nickname) { line("NICKNAME:\(escapeText(c.nickname))", &out) }
        if isPresent(c.org) || isPresent(c.department) {
            let unit = isPresent(c.department) ? ";" + escapeText(c.department) : ""
            line("ORG:\(escapeText(c.org))\(unit)", &out)
        }
        if isPresent(c.title) { line("TITLE:\(escapeText(c.title))", &out) }
        for email in c.emails where isPresent(email.value) {
            line("EMAIL\(typeParam(email.label)):\(escapeText(email.value))", &out)
        }
        for phone in c.phones where isPresent(phone.value) {
            line("TEL\(phoneTypeParam(phone.label)):\(escapeText(phone.value))", &out)
        }
        for address in c.addresses {
            let parts = ["", "", address.street, address.city, address.region, address.postalCode, address.country]
            if parts.contains(where: { isPresent($0 ?? "") }) {
                line("ADR\(typeParam(address.label)):" + parts.map { escapeText($0 ?? "") }.joined(separator: ";"), &out)
            }
        }
        for site in c.websites where isPresent(site.value) {
            line("URL\(typeParam(site.label)):\(stripControls(site.value))", &out)
        }
        if isCalendarDate(c.birthday) {
            line("BDAY:" + (version == .v4 ? c.birthday.replacingOccurrences(of: "-", with: "") : c.birthday), &out)
        }
        if isPresent(c.notes) { line("NOTE:\(escapeText(c.notes))", &out) }
        line("END:VCARD", &out)
    }

    /// YYYY-MM-DD that is a real date: `2025-02-29`, `2026-13-01` and
    /// `+10000-01-01` are refused.
    static func isCalendarDate(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 10, scalars[4] == "-", scalars[7] == "-" else { return false }
        let digits = scalars.enumerated().filter { $0.offset != 4 && $0.offset != 7 }.map(\.element)
        guard digits.allSatisfy({ ("0"..."9").contains($0) }) else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return components.isValidDate(in: Calendar(identifier: .gregorian))
    }

    private static func isPresent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The fax labels map to two TYPE tokens on purpose; everything else is
    /// one free-text value.
    private static func phoneTypeParam(_ label: String?) -> String {
        switch label?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "mobile": ";TYPE=cell"
        case "work fax": ";TYPE=work,fax"
        case "home fax": ";TYPE=home,fax"
        default: typeParam(label)
        }
    }

    /// A free-text label becomes one TYPE value, quoted when it holds a
    /// parameter delimiter.
    private static func typeParam(_ label: String?) -> String {
        let clean = stripControls(label ?? "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !clean.isEmpty else { return "" }
        let bare = clean.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        return bare ? ";TYPE=\(clean)" : ";TYPE=\"\(clean)\""
    }

    /// C0, DEL, C1, and the Unicode line/paragraph separators — anything a
    /// reader might take as the end of a line.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            || scalar.value == 0x2028 || scalar.value == 0x2029
    }

    static func stripControls(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars where !isControl(scalar) { out.append(scalar) }
        return String(out)
    }

    static func escapeText(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in value.unicodeScalars {
            // CRLF, CR and LF all become one escaped newline.
            if scalar == "\n" && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = scalar == "\r"
            switch scalar {
            case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
            case ",": out.append(contentsOf: "\\,".unicodeScalars)
            case ";": out.append(contentsOf: "\\;".unicodeScalars)
            case "\n", "\r": out.append(contentsOf: "\\n".unicodeScalars)
            default: if !isControl(scalar) { out.append(scalar) }
            }
        }
        return String(out)
    }

    /// Folds at 75 octets (RFC 6350 §3.2) on scalar boundaries,
    /// CRLF-terminated.
    private static func line(_ content: String, _ out: inout String) {
        var octets = 0
        var folded = String.UnicodeScalarView()
        for scalar in content.unicodeScalars {
            let size = String(scalar).utf8.count
            if octets + size > 75 {
                folded.append(contentsOf: "\r\n ".unicodeScalars)
                octets = 1
            }
            folded.append(scalar)
            octets += size
        }
        out += String(folded)
        out += "\r\n"
    }

    /// A share-sheet file name: the contact's name (or "Contacts"), with path
    /// separators and control characters removed.
    static func fileName(for contacts: [Contact]) -> String {
        let base = contacts.count == 1 ? contacts[0].name : "Contacts"
        let cleaned = stripControls(base)
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Contact" : String(cleaned.prefix(80))) + ".vcf"
    }
}

/// What a ShareLink hands the system: the bytes, produced on demand.
///
/// `DataRepresentation`, never `FileRepresentation`: this app writes no file
/// for an export, so there is nothing on disk to forget to delete. Where the
/// receiving app puts the card is its business — which is exactly why export
/// is refused under Hostile Location Protection.
nonisolated struct VCardExport: Transferable {
    var contacts: [Contact]
    var version: VCardVersion

    var fileName: String { VCardWriter.fileName(for: contacts) }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .vCard) { export in
            Data(VCardWriter.write(export.contacts, version: export.version).utf8)
        }
        .suggestedFileName { $0.fileName }
    }
}
