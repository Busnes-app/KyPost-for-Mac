//
//  NotificationCursorStore.swift
//  KyPost
//
//  Last-read notification cursor for pull mode (spec §3). Cursor only ever
//  advances: max(lastCursor, response.cursor), applied after notifications
//  are handed off.
//

import Foundation

final class NotificationCursorStore {
    private static let key = "notifications.lastCursor"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var lastCursor: Int {
        defaults.integer(forKey: Self.key)
    }

    /// Advances the cursor; ignores values behind the current position.
    func advance(to cursor: Int) {
        guard cursor > lastCursor else { return }
        defaults.set(cursor, forKey: Self.key)
    }

    /// The only way the cursor moves backwards: unpair. Server seqs are per
    /// account, so a cursor carried into a different account's pairing would
    /// silently skip every notification below it.
    func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}
