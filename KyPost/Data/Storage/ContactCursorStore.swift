//
//  ContactCursorStore.swift
//  KyPost
//
//  Contact sync cursor + pending-delete tombstones (spec §4). Both are
//  UserDefaults-backed; like the notification cursor, the sync cursor only
//  ever advances.
//

import Foundation

final class ContactCursorStore {
    private static let key = "contacts.lastCursor"

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

    /// Discards the cursor after a `tooOld` response so the next sync is a
    /// full re-pull from 0 (Mobile_Contact_Sync.md).
    func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// PGP keys the user verified out of band, keyed by server uid.
///
/// UserDefaults-backed for the same reason SystemContactsLinkStore is: it has
/// to survive the SwiftData wipe a `tooOld` response triggers. Without it the
/// wipe laundered a key substitution — every contact came back with no prior
/// key, so the relay's key was applied as trusted and the user's in-person
/// fingerprint check was silently voided. This is a memory of what the user
/// verified, not a cache of what the server said.
final class VerifiedPgpKeyStore {
    private static let key = "contacts.verifiedPgpKeys"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func all() -> [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func key(forUid uid: String) -> String? {
        all()[uid]
    }

    /// Records a non-empty key against a uid; an empty key or a nil uid is a
    /// no-op, so this never stores a withdrawal as if it were a key.
    func remember(uid: String?, key: String?) {
        guard let uid, !uid.isEmpty, let key, !key.isEmpty else { return }
        var keys = all()
        guard keys[uid] != key else { return }
        keys[uid] = key
        defaults.set(keys, forKey: Self.key)
    }

    /// Called when the user themselves removes or replaces a key.
    func forget(uid: String?) {
        guard let uid, !uid.isEmpty else { return }
        var keys = all()
        guard keys.removeValue(forKey: uid) != nil else { return }
        defaults.set(keys, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// Uids of contacts deleted locally while unsynced; included as
/// `{uid, deleted: true}` in the next sync request delta, then cleared.
final class ContactPendingDeletesStore {
    private static let key = "contacts.pendingDeletes"
    /// When the oldest tombstone still queued was added — the outbox age the
    /// contacts list reports as "stuck".
    private static let sinceKey = "contacts.pendingDeletes.since"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func all() -> [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    func add(_ uid: String, now: Date = Date()) {
        var uids = all()
        guard !uids.contains(uid) else { return }
        if uids.isEmpty { defaults.set(now, forKey: Self.sinceKey) }
        uids.append(uid)
        defaults.set(uids, forKey: Self.key)
    }

    var oldestQueuedAt: Date? {
        all().isEmpty ? nil : defaults.object(forKey: Self.sinceKey) as? Date
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.sinceKey)
    }
}
