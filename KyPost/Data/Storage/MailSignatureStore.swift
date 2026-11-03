//
//  MailSignatureStore.swift
//  KyPost
//
//  The mobile signature: one plain-text signature kept on this device, in
//  UserDefaults, separate from the web signatures KyPost-Server stores
//  (owner decision 2026-11-03). Never fetched from or sent to the server
//  except as part of a message body.
//
//  Account data: unpair, the failed-unlock reset and the security wipe all
//  clear it. It is a setting the user typed rather than something derived
//  from their mail, so Hostile Location Protection leaves it alone.
//

import Foundation

/// What Settings → Signature holds. Off until the user turns it on.
struct MailSignatureSettings: Equatable, Sendable {
    var isOn = false
    var text = ""
    var addToReplies = true
    var addToForwards = true

    /// The text compose inserts for `kind`, or "" for none. A stored text
    /// that no longer passes `MailSignatureStore.problem` is not inserted.
    nonisolated func text(for kind: ComposeKind) -> String {
        guard isOn else { return "" }
        switch kind {
        case .new: break
        case .reply: guard addToReplies else { return "" }
        case .forward: guard addToForwards else { return "" }
        case .draft: return ""
        }
        guard MailSignatureStore.problem(in: text) == nil else { return "" }
        return MailSignatureStore.normalized(text)
    }
}

/// Why a signature text is refused. Same rules as KyPost-Server's
/// `config/signatures.go` for a web signature's text.
enum MailSignatureProblem: Equatable, Sendable {
    case tooLong
    case controlCharacter
    case directionControl

    var message: String {
        switch self {
        case .tooLong:
            String(localized: "A signature can be at most 2,000 characters. Shorten it to save your changes.")
        case .controlCharacter:
            String(localized: "A signature can’t contain control characters. Remove them to save your changes.")
        case .directionControl:
            String(localized: "A signature can’t contain invisible text-direction characters. Remove them to save your changes.")
        }
    }
}

final class MailSignatureStore {
    /// Unicode scalars, which is what the server counts (Go runes).
    nonisolated static let maxCharacters = 2000
    static let key = "compose.signature"
    static let isOnKey = "compose.signature.on"
    static let addToRepliesKey = "compose.signature.replies"
    static let addToForwardsKey = "compose.signature.forwards"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The stored text, "" for none.
    var signature: String {
        defaults.string(forKey: Self.key) ?? ""
    }

    /// A signature saved before the switch existed was always inserted, so
    /// with no saved switch it reads as on exactly when there is text.
    var settings: MailSignatureSettings {
        MailSignatureSettings(
            isOn: defaults.object(forKey: Self.isOnKey) as? Bool ?? !signature.isEmpty,
            text: signature,
            addToReplies: defaults.object(forKey: Self.addToRepliesKey) as? Bool ?? true,
            addToForwards: defaults.object(forKey: Self.addToForwardsKey) as? Bool ?? true
        )
    }

    /// Saves everything, or nothing and the reason when the text is refused.
    @discardableResult
    func save(_ settings: MailSignatureSettings) -> MailSignatureProblem? {
        if let problem = Self.problem(in: settings.text) { return problem }
        let text = Self.normalized(settings.text)
        if text.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(text, forKey: Self.key)
        }
        defaults.set(settings.isOn, forKey: Self.isOnKey)
        defaults.set(settings.addToReplies, forKey: Self.addToRepliesKey)
        defaults.set(settings.addToForwards, forKey: Self.addToForwardsKey)
        return nil
    }

    func clear() {
        for key in [Self.key, Self.isOnKey, Self.addToRepliesKey, Self.addToForwardsKey] {
            defaults.removeObject(forKey: key)
        }
    }

    /// `\r\n` folded to `\n` (as the server stores it) and blank lines at
    /// either end dropped. All whitespace is no signature.
    nonisolated static func normalized(_ text: String) -> String {
        let folded = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !folded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return folded.trimmingCharacters(in: .newlines)
    }

    /// Nil when `text` may be saved. Iterates `unicodeScalars`: a Swift
    /// `Character` can hold several scalars (`"\r\n"` is one), and the limit
    /// counts scalars as the server counts runes.
    nonisolated static func problem(in text: String) -> MailSignatureProblem? {
        let scalars = text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars
        if scalars.count > maxCharacters { return .tooLong }
        for scalar in scalars {
            switch scalar.value {
            // Explicit embeddings and overrides, then the isolates: invisible
            // and reordering, so a recipient could read something other than
            // what Settings shows.
            case 0x202A...0x202E, 0x2066...0x2069:
                return .directionControl
            // Newline and tab are text; the rest of Cc (Go's IsControl) is not.
            case 0x0A, 0x09:
                continue
            default:
                if scalar.properties.generalCategory == .control { return .controlCharacter }
            }
        }
        return nil
    }
}

/// The body with `signature` placed as the web composer places it
/// (KyPost-Server `docs/SIGNATURES.md`): below the line the user types on and
/// above any quote, with one blank line before it and one between it and the
/// quote. No `-- ` delimiter. A blank signature leaves the body untouched.
///
/// Plain text in, plain text out. Compose builds its `AttributedString` from
/// this verbatim, so markup typed into a signature is shown as the characters
/// typed — it is never interpreted.
nonisolated func withSignature(_ body: String, signature: String) -> String {
    let signature = MailSignatureStore.normalized(signature)
    guard !signature.isEmpty else { return body }
    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "\n\n\(signature)"
    }
    // A reply's or forward's body opens with the typing line and a blank
    // line; the quote's own blank line then follows the signature.
    if body.hasPrefix("\n\n") {
        return "\n\n\(signature)\(body)"
    }
    return "\(body)\n\n\(signature)"
}
