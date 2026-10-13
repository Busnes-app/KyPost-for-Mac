//
//  KeywordRepository.swift
//  KyPost
//
//  Derives inbox tabs from email keywords (spec §2 Inbox Tabs): the relay's
//  server-assigned tab/label fields arrive on Email.keywords. Visibility
//  toggles come from KeywordSettingsStore. The 90-second foreground refresh
//  is driven by the inbox view model on Config.foregroundRefreshInterval.
//

import Foundation

/// One inbox tab with the number of emails carrying its keyword.
struct KeywordTab: Equatable, Sendable {
    var name: String
    var count: Int
}

final class KeywordRepository {
    private let settingsStore: KeywordSettingsStore

    init(settingsStore: KeywordSettingsStore) {
        self.settingsStore = settingsStore
    }

    /// All keywords present in the given emails, alphabetical with counts.
    static func computeTabs(from emails: [Email]) -> [KeywordTab] {
        var counts: [String: Int] = [:]
        for email in emails {
            for keyword in email.keywords where !keyword.isEmpty {
                counts[keyword, default: 0] += 1
            }
        }
        return counts
            .map { KeywordTab(name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The name of the app-owned "everything" tab. A relay label spelt the
    /// same must not become a second one.
    static let allTabName = "All"

    static func isAllTabName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(allTabName) == .orderedSame
    }

    /// Tabs to show in the inbox tab bar (hidden keywords filtered out).
    func visibleTabs(from emails: [Email]) -> [KeywordTab] {
        orderedTabs(from: emails)
            .filter { settingsStore.isVisible($0.name) }
    }

    /// Whether the All tab leads the strip. Hideable like any keyword; with
    /// every tab hidden the inbox shows everything and no strip at all.
    var isAllTabVisible: Bool {
        get { settingsStore.allTabVisible }
        set { settingsStore.allTabVisible = newValue }
    }

    /// All keywords with their visibility, for KeywordSettingsView.
    func allSettings(from emails: [Email]) -> [KeywordSetting] {
        // System keywords are not offered here either: there is nothing
        // useful to toggle, and the phishing warning must not be hideable.
        orderedTabs(from: emails).map {
            KeywordSetting(name: $0.name, visible: settingsStore.isVisible($0.name))
        }
    }

    func setVisible(_ visible: Bool, for keyword: String) {
        settingsStore.setVisible(visible, for: keyword)
    }

    func setOrder(_ keywords: [String]) {
        settingsStore.setOrder(keywords)
    }

    private func orderedTabs(from emails: [Email]) -> [KeywordTab] {
        let ranks = Dictionary(
            settingsStore.order().enumerated().map { ($1, $0) },
            uniquingKeysWith: min
        )
        return Self.computeTabs(from: emails)
            .filter { !isSystemKeyword($0.name) && !Self.isAllTabName($0.name) }
            .sorted { left, right in
                switch (ranks[left.name], ranks[right.name]) {
                case let (leftRank?, rightRank?): leftRank < rightRank
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil):
                    left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                }
            }
    }
}
