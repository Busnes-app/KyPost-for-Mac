//
//  HeaderText.swift
//  KyPost
//
//  Display-only flattening for sender-written header values. Port of
//  kypost-android's mail/AddressText.kt `displayHeaderText` (#119).
//

import Foundation

/// One header, one line: a display name carrying CR/LF or a bidi override
/// could otherwise forge a labelled line ("Cc: ceo@…") or reverse the shown
/// address. Controls, format characters, and the Unicode line and paragraph
/// separators become a single space, and the result is trimmed.
///
/// Iterates `unicodeScalars`, never `Character`s: in Swift `"\r\n"` is one
/// `Character` whose category is neither, so a `Character` loop lets the very
/// line break this exists to remove straight through.
nonisolated func displayHeaderText(_ raw: String) -> String {
    var out = String.UnicodeScalarView()
    var pendingSpace = false
    for scalar in raw.unicodeScalars {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            pendingSpace = true
        default:
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(scalar)
        }
    }
    return String(out).trimmingCharacters(in: .whitespaces)
}

/// The reader's To/Cc lines, flattened. A field with nothing left after
/// flattening is nil rather than an empty "To:", which reads as a bug — so a
/// row carrying no recipients shows no line at all.
nonisolated func detailRecipientLines(to: String, cc: String) -> (to: String?, cc: String?) {
    func line(_ raw: String) -> String? {
        let text = displayHeaderText(raw)
        return text.isEmpty ? nil : text
    }
    return (line(to), line(cc))
}
