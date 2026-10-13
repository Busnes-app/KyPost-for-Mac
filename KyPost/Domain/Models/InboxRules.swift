//
//  InboxRules.swift
//  KyPost
//
//  Pure inbox-list rules ported from Android (InboxActivity.kt,
//  MoveToFolder.kt): Sent/Drafts resolution, move targets, row dates, the
//  freshness line, the empty-folder gate, and new-mail counting. Kept free of
//  view and network types so each is a plain unit test.
//

import Foundation

/// The two mailboxes the folder pickers open by *resolving* a server path
/// rather than by a hardcoded name. Real accounts spell them `Sent`,
/// `Sent Items`, `INBOX.Sent` and so on, and the relay's `mailbox` parameter
/// is used verbatim.
nonisolated enum SpecialFolder: String, CaseIterable, Hashable, Sendable {
    case sent
    case drafts

    /// The server's own fallback leaf names (`special_folders.go`
    /// `folderNameAliases`), in its preference order.
    var aliases: [String] {
        switch self {
        case .sent: ["Sent", "Sent Items", "Sent Messages", "Sent Mail"]
        case .drafts: ["Drafts", "Draft"]
        }
    }

    var label: String {
        switch self {
        case .sent: String(localized: "Sent")
        case .drafts: String(localized: "Drafts")
        }
    }

    var systemImage: String {
        switch self {
        case .sent: "paperplane"
        case .drafts: "doc.text"
        }
    }
}

nonisolated enum InboxRules {
    /// The last hierarchy segment. The backend treats both "/" and "." as
    /// delimiters (Dovecot spells `INBOX.Sent`).
    static func mailboxLeaf(_ path: String) -> String {
        (path.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init) ?? path)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isUnderArchive(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("archive/") || lower.hasPrefix("archive.")
    }

    /// Which special folder `path` is, by leaf. Nil under Archive:
    /// `Archive/Sent` is an archived folder, which the Archive entry owns.
    static func specialFolder(of path: String) -> SpecialFolder? {
        guard !isUnderArchive(path) else { return nil }
        let leaf = mailboxLeaf(path)
        return SpecialFolder.allCases.first { kind in
            kind.aliases.contains { $0.caseInsensitiveCompare(leaf) == .orderedSame }
        }
    }

    /// The first of `paths` (the relay's top-level folders) whose leaf matches
    /// `kind`'s aliases, trying aliases in the server's preference order.
    /// Never guesses and never creates: nil means the account has no such
    /// folder as far as this client can tell.
    static func resolveSpecialFolder(_ kind: SpecialFolder, in paths: [String]) -> String? {
        let candidates = paths.filter { !isUnderArchive($0) }
        for alias in kind.aliases {
            if let match = candidates.first(where: {
                mailboxLeaf($0).caseInsensitiveCompare(alias) == .orderedSame
            }) {
                return match
            }
        }
        return nil
    }

    /// Where a message in `current` can be moved: INBOX, Inbox children, the
    /// top-level folders, then Archive children — de-duplicated
    /// case-insensitively, minus the message's own folder. "Archive" itself is
    /// never a target: the Archive action resolves the account's real archive
    /// server-side, and a literal `Archive` move could file mail into a folder
    /// no other client uses.
    static func moveTargets(
        current: String,
        inboxChildren: [String],
        topLevel: [String],
        archiveChildren: [String]
    ) -> [String] {
        var seen = Set<String>()
        return ([StandardFolder.inbox] + inboxChildren + topLevel + archiveChildren)
            .filter { path in
                let key = path.lowercased()
                guard !path.isEmpty,
                      key != current.lowercased(),
                      key != StandardFolder.archive.lowercased(),
                      !seen.contains(key)
                else { return false }
                seen.insert(key)
                return true
            }
    }

    /// The label a move picker shows: the raw path, which is honest about
    /// which of two same-leaf folders is meant. Only INBOX is prettied.
    static func moveTargetLabel(_ path: String) -> String {
        path == StandardFolder.inbox ? String(localized: "Inbox") : path
    }

    /// A row's date in the device zone: the time for today's mail, a medium
    /// date otherwise, and blank when the relay sent no usable date.
    static func rowDate(
        _ date: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard Email.isKnownDate(date) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }

    /// The freshness line for the folder on screen. A placeholder rather than
    /// an empty row before the first success, so the list does not shift.
    static func freshnessText(refreshedAt: Date?, now: Date, locale: Locale = .current) -> String {
        guard let refreshedAt else { return String(localized: "Not updated yet") }
        if now.timeIntervalSince(refreshedAt) < 60 {
            return String(localized: "Updated just now")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: refreshedAt, relativeTo: now)
        return String(localized: "Updated \(relative)")
    }

    /// "No messages in …" is only true once the folder on screen has
    /// refreshed successfully. A loading or unreachable folder with an empty
    /// cache is unknown, not empty.
    static func showsEmptyFolder(shown: Int, loadedFolder: String?, currentFolder: String) -> Bool {
        shown == 0 && loadedFolder == currentFolder
    }

    /// Rows `new` puts above the first row `old` already had. Zero on a first
    /// load, so a folder switch never announces anything.
    static func newRowsAbove(old: [Email], new: [Email]) -> Int {
        guard !old.isEmpty else { return 0 }
        let oldIds = Set(old.map(\.serverId))
        return new.prefix { !oldIds.contains($0.serverId) }.count
    }
}
