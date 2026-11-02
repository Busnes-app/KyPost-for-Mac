//
//  SystemContactsLinkStore.swift
//  KyPost
//
//  Mapping between app contacts and the CNContact cards the app created in
//  the system Contacts database. UserDefaults-backed (not a ContactEntity
//  field) so the mapping survives the SwiftData wipe on a tooOld re-pull;
//  `uid` lets contacts re-link after the re-pull assigns new localIds.
//

import Foundation

struct SystemContactLink: Codable, Equatable, Sendable {
    var localId: UUID
    /// Server uid at export time; used to re-link after a tooOld wipe.
    var uid: String?
    /// Identifier of the CNContact this app created.
    var cnIdentifier: String
    /// `updatedAt` of the contact when last exported; unchanged contacts skip.
    var exportedUpdatedAt: Date
    /// True when the card originated in Contacts.app (sync-back import);
    /// "Remove Exported Contacts" keeps these cards.
    var imported: Bool
    /// True when the card already existed in Contacts.app and was adopted
    /// purely to avoid creating a duplicate. The app did not author it, so it
    /// is never rewritten from relay data and never deleted — adoption is a
    /// de-duplication device, not a claim of ownership.
    var userOwned: Bool

    init(
        localId: UUID,
        uid: String?,
        cnIdentifier: String,
        exportedUpdatedAt: Date,
        imported: Bool = false,
        userOwned: Bool = false
    ) {
        self.localId = localId
        self.uid = uid
        self.cnIdentifier = cnIdentifier
        self.exportedUpdatedAt = exportedUpdatedAt
        self.imported = imported
        self.userOwned = userOwned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localId = try container.decode(UUID.self, forKey: .localId)
        uid = try container.decodeIfPresent(String.self, forKey: .uid)
        cnIdentifier = try container.decode(String.self, forKey: .cnIdentifier)
        exportedUpdatedAt = try container.decode(Date.self, forKey: .exportedUpdatedAt)
        // Links written before sync-back existed are all exports.
        imported = try container.decodeIfPresent(Bool.self, forKey: .imported) ?? false
        // decodeIfPresent, not decode: this array is JSON in UserDefaults and
        // `all()` swallows a decode failure with try?, so a throwing decoder
        // would silently return [] and make the exporter re-adopt or duplicate
        // the entire address book. Pre-upgrade links default to false, which
        // preserves today's behaviour for cards the app really did create.
        userOwned = try container.decodeIfPresent(Bool.self, forKey: .userOwned) ?? false
    }
}

final class SystemContactsLinkStore {
    private static let key = "contacts.systemLinks"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func all() -> [SystemContactLink] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([SystemContactLink].self, from: data)) ?? []
    }

    func link(localId: UUID) -> SystemContactLink? {
        all().first { $0.localId == localId }
    }

    func upsert(_ link: SystemContactLink) {
        var links = all()
        if let index = links.firstIndex(where: { $0.localId == link.localId }) {
            links[index] = link
        } else {
            links.append(link)
        }
        save(links)
    }

    func remove(localId: UUID) {
        save(all().filter { $0.localId != localId })
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    private func save(_ links: [SystemContactLink]) {
        guard let data = try? JSONEncoder().encode(links) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Card identifiers that already existed when contacts sync first ran; those
/// are never auto-imported, so enabling sync-back doesn't pull the user's
/// whole address book into the app.
final class SystemContactsBaselineStore {
    private static let key = "contacts.systemBaseline"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Captured once, on the first reconcile with access; an empty capture is
    /// still a capture (user with no contacts yet).
    var isCaptured: Bool {
        defaults.object(forKey: Self.key) != nil
    }

    func capture(identifiers: [String]) {
        defaults.set(identifiers, forKey: Self.key)
    }

    func identifiers() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    /// Forgets the capture entirely; the next reconcile recaptures from the
    /// cards present at that moment.
    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    /// Marks a card as never-import again (used when an imported link is
    /// forgotten but the user's card is kept).
    func add(_ identifier: String) {
        var identifiers = defaults.stringArray(forKey: Self.key) ?? []
        guard !identifiers.contains(identifier) else { return }
        identifiers.append(identifier)
        defaults.set(identifiers, forKey: Self.key)
    }
}
