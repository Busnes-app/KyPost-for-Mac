//
//  KeywordSettingsStore.swift
//  KyPost
//
//  UserDefaults-backed per-keyword tab visibility (spec §2 Keyword Settings).
//  Keywords with no stored override are visible by default.
//

import Foundation

final class KeywordSettingsStore {
    private static let visibilityKey = "keywords.visibility"
    private static let orderKey = "keywords.order"
    private static let allTabVisibleKey = "keywords.allTabVisible"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func isVisible(_ keyword: String) -> Bool {
        overrides()[keyword] ?? true
    }

    func setVisible(_ visible: Bool, for keyword: String) {
        var map = overrides()
        map[keyword] = visible
        defaults.set(map, forKey: Self.visibilityKey)
    }

    /// All stored visibility overrides (keywords never toggled are absent).
    func overrides() -> [String: Bool] {
        defaults.dictionary(forKey: Self.visibilityKey) as? [String: Bool] ?? [:]
    }

    /// Whether the inbox tab strip leads with All. Visible until the user
    /// hides it, like every keyword.
    var allTabVisible: Bool {
        get { defaults.object(forKey: Self.allTabVisibleKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.allTabVisibleKey) }
    }

    func order() -> [String] {
        defaults.stringArray(forKey: Self.orderKey) ?? []
    }

    func setOrder(_ keywords: [String]) {
        defaults.set(keywords, forKey: Self.orderKey)
    }
}
