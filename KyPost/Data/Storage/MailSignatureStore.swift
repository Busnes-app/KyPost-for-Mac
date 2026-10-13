//
//  MailSignatureStore.swift
//  KyPost
//
//  The paired account's plain-text email signature. Port of kypost-android's
//  MailSignature.kt (#177).
//
//  Account data: unpair, the failed-unlock reset and the security wipe all
//  clear it. It is a setting the user typed rather than something derived
//  from their mail, so Hostile Location Protection leaves it alone.
//

import Foundation

final class MailSignatureStore {
    /// Characters, not bytes — the limit the Settings field shows.
    nonisolated static let maxCharacters = 1000
    static let key = "compose.signature"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var signature: String {
        defaults.string(forKey: Self.key) ?? ""
    }

    /// Trimmed and capped on the way in, so every reader sees the same text.
    /// A blank signature is no signature: the key is removed.
    func save(_ signature: String) {
        let cleaned = Self.normalized(signature)
        if cleaned.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(cleaned, forKey: Self.key)
        }
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    nonisolated static func normalized(_ signature: String) -> String {
        String(signature.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCharacters))
    }
}

/// The body with the signature placed after an RFC 3676 `-- ` delimiter and
/// **above** any quote: a reply's or forward's quoted text follows it. A blank
/// signature leaves the body untouched.
///
/// Plain text in, plain text out. Compose builds its `AttributedString` from
/// this verbatim, so markup typed into a signature is shown as the characters
/// typed — it is never interpreted.
nonisolated func withSignature(_ body: String, signature: String) -> String {
    let signature = MailSignatureStore.normalized(signature)
    guard !signature.isEmpty else { return body }
    return "\n\n-- \n\(signature)\(body)"
}
