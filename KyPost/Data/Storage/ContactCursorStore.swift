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

    /// Discards the cursor so the next sync is a full re-pull from 0: after a
    /// `tooOld` response (Mobile_Contact_Sync.md), when the contacts table is
    /// empty, and whenever the store files are deleted. A cursor describes
    /// rows this device holds; kept past them, the next pull is a delta and
    /// the address book stays empty.
    func reset() {
        defaults.removeObject(forKey: Self.key)
    }

    private static let accountKey = "contacts.account"

    /// The account (`sub` and `srv`) the contacts on this device were synced
    /// with, nil before any sync recorded one. A paired account that differs
    /// is a change of account (`ContactSyncRepository.performSync`).
    var account: String? {
        get { defaults.string(forKey: Self.accountKey) }
        set { defaults.set(newValue, forKey: Self.accountKey) }
    }

    private static let deletedCreatesKey = "contacts.deletedCreates"

    /// Creates deleted here while `createsInFlight` was set: the relay may
    /// hold them already, with no uid here to send a delete for. Kept until
    /// that push is accounted for, so reconciliation can find their uids and
    /// queue the deletes. Only the fields reconciliation matches on.
    var deletedCreates: [Contact] {
        get {
            guard let data = defaults.data(forKey: Self.deletedCreatesKey),
                  let stored = try? JSONDecoder().decode([DeletedCreate].self, from: data)
            else { return [] }
            return stored.map(\.contact)
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.deletedCreatesKey)
            } else {
                defaults.set(try? JSONEncoder().encode(newValue.map(DeletedCreate.init)), forKey: Self.deletedCreatesKey)
            }
        }
    }

    private struct DeletedCreate: Codable {
        var localId: UUID
        var name: String
        var org: String
        var emails: [String]
        var phones: [String]

        init(_ contact: Contact) {
            localId = contact.localId
            name = contact.name
            org = contact.org
            emails = contact.emails.map(\.value)
            phones = contact.phones.map(\.value)
        }

        var contact: Contact {
            var contact = Contact(localId: localId, uid: nil, name: name, avatarUrl: nil, createdAt: Date(), updatedAt: Date())
            contact.org = org
            contact.emails = emails.map { ContactLabeledValue(label: nil, value: $0) }
            contact.phones = phones.map { ContactLabeledValue(label: nil, value: $0) }
            return contact
        }
    }

    private static let submittedCreatesKey = "contacts.submittedCreates"

    /// The localIds of creates the unanswered push actually sent. Only these
    /// can be on the relay without a uid here, so only their deletion is
    /// remembered in `deletedCreates`.
    var submittedCreates: Set<UUID> {
        get { Set((defaults.stringArray(forKey: Self.submittedCreatesKey) ?? []).compactMap(UUID.init)) }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.submittedCreatesKey)
            } else {
                defaults.set(newValue.map(\.uuidString), forKey: Self.submittedCreatesKey)
            }
        }
    }

    private static let createsInFlightKey = "contacts.createsInFlight"

    /// Set while a push carrying creates has not been answered. A create the
    /// relay committed but whose response was lost has no uid here, so the
    /// next sync would send it again as a new contact; while this is set the
    /// next sync first pulls and reconciles pending creates against what the
    /// server already has (`ContactSyncRepository.reconcileUnansweredCreates`).
    var createsInFlight: Bool {
        get { defaults.bool(forKey: Self.createsInFlightKey) }
        set {
            if newValue {
                defaults.set(true, forKey: Self.createsInFlightKey)
            } else {
                defaults.removeObject(forKey: Self.createsInFlightKey)
                // Accounted for: nothing deleted meanwhile can still be on
                // the relay unknown to this device.
                deletedCreates = []
                submittedCreates = []
            }
        }
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
/// `{uid, deleted: true}` in the next sync request delta, then removed —
/// only the uids that request carried (`remove`), so a delete queued while it
/// was in flight is not dropped unsent. Not cleared by a `tooOld` wipe or by
/// deleting the store: the delete still has to reach the server.
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

    /// Removes the tombstones a sync actually sent. The queue's age is kept
    /// while anything remains: it may overstate the age, never hide it.
    func remove(_ sent: [String]) {
        let sent = Set(sent)
        let remaining = all().filter { !sent.contains($0) }
        if remaining.isEmpty {
            clear()
        } else {
            defaults.set(remaining, forKey: Self.key)
        }
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.sinceKey)
    }
}
