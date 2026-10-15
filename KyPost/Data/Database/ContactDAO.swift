//
//  ContactDAO.swift
//  KyPost
//
//  Data access for synced contacts (spec §8 ContactDAO).
//

import Foundation
import SwiftData

@ModelActor
actor ContactDAO {
    /// Inserts new contacts or updates existing ones, matched by localId first,
    /// then by server uid (sync deltas reference contacts by uid).
    func upsert(contacts: [Contact]) throws {
        for contact in contacts {
            if let existing = try fetchEntity(localId: contact.localId)
                ?? fetchEntity(uid: contact.uid) {
                // A server-driven sync write (needsSync == false) must not
                // clobber a local edit that landed more recently than this
                // write's own snapshot — otherwise an in-flight, now-stale
                // sync response can silently discard a user's correction
                // (e.g. re-attaching a PGP key after noticing a bad one) and
                // mark it as already synced, so it's never re-pushed either.
                // The local edit stays queued and reconciles on the next sync.
                if !contact.needsSync, existing.needsSync, existing.updatedAt > contact.updatedAt {
                    continue
                }
                existing.uid = contact.uid ?? existing.uid
                existing.rev = contact.rev
                existing.name = contact.name
                existing.applyFields(from: contact)
                existing.updatedAt = contact.updatedAt
                existing.needsSync = contact.needsSync
            } else {
                modelContext.insert(ContactEntity(from: contact))
            }
        }
        try modelContext.save()
    }

    /// One-time V1→V2 backfill: the legacy single email/phone strings become
    /// the first labeled value of the new arrays. Idempotent — rows already
    /// carrying arrays (or with empty legacy fields) are untouched, and the
    /// legacy fields are cleared once copied. Filters in memory because
    /// #Predicate can't see inside the encoded array columns.
    func migrateLegacyFields() throws {
        let entities = try modelContext.fetch(FetchDescriptor<ContactEntity>())
        var changed = false
        for entity in entities {
            if entity.emails.isEmpty, !entity.legacyEmail.isEmpty {
                entity.emails = [ContactLabeledValue(label: nil, value: entity.legacyEmail)]
                entity.legacyEmail = ""
                changed = true
            }
            if entity.phones.isEmpty, !entity.legacyPhone.isEmpty {
                entity.phones = [ContactLabeledValue(label: nil, value: entity.legacyPhone)]
                entity.legacyPhone = ""
                changed = true
            }
        }
        if changed {
            try modelContext.save()
        }
    }

    // MARK: - Sync support (spec §4)

    /// Local creates/edits waiting to be pushed.
    func listPendingSync() throws -> [Contact] {
        let descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.needsSync },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(descriptor).map(\.toDomain)
    }

    /// Reconciliation result: attach the server-assigned uid to a local
    /// contact. Refuses a uid another row already holds — two rows sharing a
    /// uid is how mis-reconciled creates turn into local duplicates.
    ///
    /// `pushedUpdatedAt` is the `updatedAt` of the snapshot that was sent.
    /// A row edited since keeps `needsSync`, so the edit goes out as an
    /// update on the next sync instead of being marked synced unsent (the
    /// same rule as `clearNeedsSync`). Nil clears it unconditionally.
    func assignUid(localId: UUID, uid: String, pushedUpdatedAt: Date? = nil) throws {
        guard try fetchEntity(uid: uid) == nil,
              let entity = try fetchEntity(localId: localId) else { return }
        entity.uid = uid
        if pushedUpdatedAt.map({ entity.updatedAt <= $0 }) ?? true {
            entity.needsSync = false
        }
        try modelContext.save()
    }

    /// Whether any contact is stored. A sync cursor describes rows this
    /// device holds; with none held it must not be trusted.
    func hasRows() throws -> Bool {
        var descriptor = FetchDescriptor<ContactEntity>()
        descriptor.fetchLimit = 1
        return try modelContext.fetchCount(descriptor) > 0
    }

    /// One-time cleanup of rows damaged by the old order-based reconciler
    /// (the local-only duplication bug; the server copy is authoritative and
    /// was never affected).
    /// - Rows sharing a uid: keep the oldest, drop the rest — the next sync
    ///   delta refreshes the survivor's fields from the server.
    /// - Nameless uid-less rows (imports the server silently dropped): give
    ///   them a derived name and re-queue them; unnameable ones stay local.
    func repairReconciliationArtifacts() throws {
        let entities = try modelContext.fetch(FetchDescriptor<ContactEntity>())
        var changed = false

        var keptByUid: [String: ContactEntity] = [:]
        for entity in entities.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let uid = entity.uid, !uid.isEmpty else { continue }
            if keptByUid[uid] == nil {
                keptByUid[uid] = entity
            } else {
                modelContext.delete(entity)
                changed = true
            }
        }

        for entity in entities
        where entity.uid == nil
            && entity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallback = entity.toDomain.derivedDisplayName
            guard !fallback.isEmpty else { continue }
            entity.name = fallback
            entity.needsSync = true
            changed = true
        }

        if changed {
            try modelContext.save()
        }
    }

    /// One-time cleanup of duplicates created by the system-contacts
    /// sync-back import: unified card identifiers drift when macOS re-links
    /// cards (our own exports trigger that), and every drift re-imported the
    /// address book as fresh uid-less rows. Rows group by identity (primary
    /// email, else name+phone, else display name); each group keeps its best
    /// row — a synced one when present, else the oldest — and only ever
    /// deletes uid-less rows still waiting to sync, the only kind the import
    /// path creates. Returns how many rows were removed.
    func repairImportedDuplicates() throws -> Int {
        let entities = try modelContext.fetch(FetchDescriptor<ContactEntity>())

        // Connected components over *every* shared identity, not one key per
        // row. Grouping by primary email alone could not see the duplicates
        // the match-key asymmetry produced: the imported row's primary email
        // is precisely the address the original row did not lead with, so the
        // pair landed in two different groups and survived the cleanup.
        var components: [Int: [ContactEntity]] = [:]
        var componentOfKey: [String: Int] = [:]
        var nextComponent = 0

        for entity in entities {
            let contact = entity.toDomain
            var keys = SystemContactMapper.matchKeys(for: contact)
            if keys.isEmpty {
                let name = contact.name
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !name.isEmpty else { continue }
                keys = ["name:\(name)"]
            }

            // Merge every component these keys already reach into the lowest.
            let existing = Set(keys.compactMap { componentOfKey[$0] }).sorted()
            let target: Int
            if let first = existing.first {
                target = first
                for other in existing.dropFirst() {
                    components[target, default: []] += components[other] ?? []
                    // Value semantics: this iterates a copy, so rewriting
                    // entries while walking it is safe.
                    for (key, owner) in componentOfKey where owner == other {
                        componentOfKey[key] = target
                    }
                    components[other] = nil
                }
            } else {
                target = nextComponent
                nextComponent += 1
            }
            components[target, default: []].append(entity)
            for key in keys { componentOfKey[key] = target }
        }

        var removed = 0
        for group in components.values where group.count > 1 {
            let ordered = group.sorted { lhs, rhs in
                let lhsSynced = !(lhs.uid ?? "").isEmpty
                let rhsSynced = !(rhs.uid ?? "").isEmpty
                if lhsSynced != rhsSynced { return lhsSynced }
                return lhs.createdAt < rhs.createdAt
            }
            for entity in ordered.dropFirst()
            where entity.needsSync && (entity.uid ?? "").isEmpty {
                modelContext.delete(entity)
                removed += 1
            }
        }
        if removed > 0 {
            try modelContext.save()
        }
        return removed
    }

    /// Confirms the contacts a push actually sent.
    ///
    /// Takes the pushed *snapshots*, not their ids, and clears the flag only
    /// where the row has not been edited since. A push reads its payload
    /// before the network call, so an edit landing while it is in flight is
    /// not in what was sent — clearing by id alone marked that edit synced and
    /// it was never pushed at all. Android avoids this structurally by
    /// queueing a payload snapshot per edit; the same guarantee falls out of
    /// comparing `updatedAt`, which `upsert` already relies on for the
    /// mirror-image case (a stale server write landing after a local edit).
    func clearNeedsSync(pushed: [Contact]) throws {
        for contact in pushed {
            guard let entity = try fetchEntity(localId: contact.localId) else { continue }
            guard entity.updatedAt <= contact.updatedAt else { continue }
            entity.needsSync = false
        }
        try modelContext.save()
    }

    func delete(uid: String) throws {
        try modelContext.delete(
            model: ContactEntity.self,
            where: #Predicate { $0.uid == uid }
        )
        try modelContext.save()
    }

    /// Removes a contact that never reached the server (no uid yet).
    func deleteLocal(localId: UUID) throws {
        try modelContext.delete(
            model: ContactEntity.self,
            where: #Predicate { $0.localId == localId }
        )
        try modelContext.save()
    }

    /// Full wipe (Mobile_Contact_Sync.md).
    func clearAll() throws {
        try modelContext.delete(model: ContactEntity.self)
        try modelContext.save()
    }

    /// The `tooOld` wipe: drops every row the server already has and keeps
    /// the ones still waiting to sync — creates, edits and nameless contacts
    /// alike, with their localIds, so the re-pull reconciles against them and
    /// their Apple Contacts links stay intact. One save, so a crash cannot
    /// land between the wipe and a restore.
    func clearSynced() throws {
        try modelContext.delete(
            model: ContactEntity.self,
            where: #Predicate { !$0.needsSync }
        )
        try modelContext.save()
    }

    func listAll() throws -> [Contact] {
        let descriptor = FetchDescriptor<ContactEntity>(
            sortBy: [SortDescriptor(\.name)]
        )
        return try modelContext.fetch(descriptor).map(\.toDomain)
    }

    func getContact(uid: String) throws -> Contact? {
        try fetchEntity(uid: uid)?.toDomain
    }

    // MARK: - Private

    private func fetchEntity(localId: UUID) throws -> ContactEntity? {
        var descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.localId == localId }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchEntity(uid: String?) throws -> ContactEntity? {
        guard let uid else { return nil }
        var descriptor = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.uid == uid }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
