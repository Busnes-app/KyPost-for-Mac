//
//  SystemContactsExporter.swift
//  KyPost
//
//  Two-way sync with the system Contacts database, gated by the
//  ContactsSettingsStore toggle. Export: app contacts become cards. Import
//  (sync-back): cards added in Contacts.app after sync was first enabled
//  become app contacts queued for the next relay push; everything older is
//  baselined and left alone. Identity is link-based (localId -> CNContact
//  identifier via SystemContactsLinkStore): only linked cards are ever
//  updated or deleted. Best-effort: each card gets its own CNSaveRequest so
//  one failure never aborts the batch, and failed items stay retriable on
//  the next reconcile.
//

import Contacts
import Foundation
import os

struct SystemContactsExportPlan: Equatable, Sendable {
    struct Update: Equatable, Sendable {
        var contact: Contact
        var cnIdentifier: String
    }

    struct Relink: Equatable, Sendable {
        var contact: Contact
        var link: SystemContactLink
    }

    /// Contacts with no link yet.
    var creates: [Contact] = []
    /// Linked contacts edited since their last export, plus links whose card
    /// no longer exists (deleted in Contacts.app or its account was removed);
    /// the upsert path recreates those cards.
    var updates: [Update] = []
    /// Links whose contact is gone from the app; the only cards ever deleted.
    var deletes: [SystemContactLink] = []
    /// Orphaned links to user-authored cards: the link is dropped, the card is
    /// left in Contacts.app untouched.
    var forgets: [SystemContactLink] = []
    /// Links matched by server uid after a tooOld wipe replaced the localIds.
    var relinks: [Relink] = []
}

enum SystemContactsDiff {
    static func plan(
        contacts: [Contact],
        links: [SystemContactLink],
        existingCardIdentifiers: Set<String>
    ) -> SystemContactsExportPlan {
        var plan = SystemContactsExportPlan()
        let contactsByLocalId = Dictionary(
            contacts.map { ($0.localId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var matchedLocalIds = Set<UUID>()
        var orphanedLinks: [SystemContactLink] = []

        for link in links {
            guard let contact = contactsByLocalId[link.localId] else {
                orphanedLinks.append(link)
                continue
            }
            // Must precede the userOwned guard below: skipping the insert would
            // drop the contact into plan.creates and duplicate the very card
            // adoption exists to prevent.
            matchedLocalIds.insert(contact.localId)

            // The user authored this card; we linked it only to avoid a
            // duplicate. Never push relay data into it.
            guard !link.userOwned else { continue }

            // A missing card is re-exported even when the contact itself is
            // unchanged; otherwise stale links mask externally deleted cards
            // forever and reconciles report "Exported 0".
            if contact.updatedAt > link.exportedUpdatedAt
                || !existingCardIdentifiers.contains(link.cnIdentifier) {
                plan.updates.append(.init(contact: contact, cnIdentifier: link.cnIdentifier))
            }
        }

        // Orphaned links first try their uid (post-tooOld re-pull kept the
        // server contact but gave it a fresh localId); only true orphans —
        // contacts really gone from the app — become deletes.
        for link in orphanedLinks {
            if let uid = link.uid,
               let contact = contacts.first(where: {
                   $0.uid == uid && !matchedLocalIds.contains($0.localId)
               }) {
                matchedLocalIds.insert(contact.localId)
                plan.relinks.append(.init(contact: contact, link: link))
            } else if link.userOwned {
                // The contact left the app, but the card was never ours to
                // delete. Forget the link and leave the card alone.
                plan.forgets.append(link)
            } else {
                plan.deletes.append(link)
            }
        }

        plan.creates = contacts.filter { !matchedLocalIds.contains($0.localId) }
        return plan
    }
}

final class SystemContactsExporter {
    struct Summary: Equatable, Sendable {
        var created = 0
        var updated = 0
        var deleted = 0
        var imported = 0
        var adopted = 0
        var failed = 0
        /// Card deletes a reconcile refused: they would have removed more
        /// than half of the linked cards in one pass.
        var withheldDeletes = 0
    }

    private let store: SystemContactStoring
    private let linkStore: SystemContactsLinkStore
    private let baselineStore: SystemContactsBaselineStore
    private let settings: ContactsSettingsStore
    private let contactDAO: ContactDAO
    /// Cached server photo bytes written onto cards; nil in tests that don't
    /// exercise photos.
    private let photoCache: ContactPhotoCache?

    init(
        store: SystemContactStoring,
        linkStore: SystemContactsLinkStore,
        baselineStore: SystemContactsBaselineStore,
        settings: ContactsSettingsStore,
        contactDAO: ContactDAO,
        photoCache: ContactPhotoCache? = nil,
        groupLinker: SystemContactGroupLinker? = nil,
        groupDAO: GroupDAO? = nil
    ) {
        self.store = store
        self.linkStore = linkStore
        self.baselineStore = baselineStore
        self.settings = settings
        self.contactDAO = contactDAO
        self.photoCache = photoCache
        self.groupLinker = groupLinker
        self.groupDAO = groupDAO
    }

    /// Mirrors backend groups onto CNGroups after a card is written. Nil in
    /// tests that don't exercise groups; the card export is unaffected.
    private let groupLinker: SystemContactGroupLinker?
    private let groupDAO: GroupDAO?

    /// Group membership for one card, best-effort.
    ///
    /// Runs after the card exists — a member cannot be added to a group before
    /// the contact it refers to has an identifier.
    private func syncGroups(for contact: Contact, cardIdentifier: String) async {
        guard let groupLinker, let groupDAO else { return }
        guard let groups = try? await groupDAO.listAll(), !groups.isEmpty else { return }
        let names = Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        await groupLinker.syncMembership(
            cardIdentifier: cardIdentifier,
            groupIDs: contact.groupIDs,
            groupNames: names
        )
    }

    // MARK: - Authorization

    var isAuthorized: Bool {
        store.authorizationStatus == .authorized
    }

    var isDenied: Bool {
        switch store.authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    /// Prompts on first use; returns whether export may proceed.
    func requestAccessIfNeeded() async -> Bool {
        switch store.authorizationStatus {
        case .authorized:
            return true
        case .notDetermined:
            return (try? await store.requestAccess()) ?? false
        default:
            return false
        }
    }

    func hasExportedContacts() -> Bool {
        !linkStore.all().isEmpty
    }

    // MARK: - Export

    /// Serializes every store-mutating pass (reconciles and the incremental
    /// upsert/delete hooks): two interleaved passes could both see a contact
    /// as unlinked and export it twice. Each caller chains its own pass after
    /// the in-flight one so it never acts on a stale plan. Chaining (instead
    /// of polling the in-flight task in a loop) matters: awaiting an
    /// already-completed task can resume without suspending, so a polling
    /// loop can spin on the main actor and deadlock the app.
    private var inFlightPass: Task<Summary, Never>?

    @discardableResult
    private func serialized(_ pass: @escaping () async -> Summary) async -> Summary {
        let previous = inFlightPass
        let task = Task { () -> Summary in
            _ = await previous?.value
            return await pass()
        }
        inFlightPass = task
        defer { if inFlightPass == task { inFlightPass = nil } }
        return await task.value
    }

    /// Sync-back import followed by a full export diff of app contacts
    /// against the link store; runs after every relay sync, on first enable,
    /// and when the system Contacts database changes.
    @discardableResult
    func reconcileAll() async -> Summary {
        await serialized { await self.performReconcile() }
    }

    private func performReconcile() async -> Summary {
        var summary = Summary()
        guard settings.exportToSystemContactsEnabled, isAuthorized else { return summary }
        // A failed read is not an empty Contacts database either: every
        // linked card would read as already gone, and its link be dropped.
        let cards: [CNContact]
        do {
            cards = try await store.listAll()
        } catch {
            Log.sync.error("Reconcile aborted: Contacts read failed: \(error.localizedDescription)")
            return summary
        }
        await adoptMatchingCards(cards, summary: &summary)
        await importNewCards(cards, summary: &summary)

        // A failed read is not an empty address book. Swallowing the throw here
        // made a locked store, a migration failure, or a container torn down
        // mid-rebuild indistinguishable from "the user has no contacts" — and
        // every link then looks orphaned, so the plan below deletes a card for
        // each one.
        let contacts: [Contact]
        do {
            contacts = try await contactDAO.listAll()
        } catch {
            Log.sync.error("Reconcile aborted: contact read failed: \(error.localizedDescription)")
            return summary
        }

        let links = linkStore.all()
        let plan = SystemContactsDiff.plan(
            contacts: contacts,
            links: links,
            existingCardIdentifiers: Set(cards.map(\.identifier))
        )

        // Routine reconciliation never legitimately empties the address book.
        // A tooOld wipe, the in-memory store after a Hostile Location
        // Protection rebuild, and a torn-down container all arrive here with an
        // empty contact list and a full link store. Keyed on the wipe shape
        // rather than on `contacts.isEmpty`, so a server deleting the user's
        // last remaining contact still removes that one card.
        if links.count > 1 && plan.deletes.count == links.count {
            Log.sync.error("""
            Reconcile aborted: \(plan.deletes.count) deletes would remove every \
            linked card. Treating this as a transient empty contact store.
            """)
            summary.withheldDeletes = plan.deletes.count
            return summary
        }
        // The same shape, partly: a store that lost most of its rows (a
        // discarded file, a re-pull that has not finished) orphans most links
        // at once, and each orphan deletes a real card in the user's own
        // Contacts database. A user deleting most of a small address book
        // hits this too, which is the safe direction: the cards stay, and the
        // contacts list says so (`ContactSyncHealth.withheldCardDeletes`).
        // Only cards still present count: a link to a card the user already
        // deleted removes nothing, so deleting them in Contacts clears this.
        let existing = Set(cards.map(\.identifier))
        let destructive = plan.deletes.filter { existing.contains($0.cnIdentifier) }.count
        if links.count > 1 && destructive * 2 > links.count {
            Log.sync.error("""
            Reconcile aborted: \(destructive) of \(links.count) linked cards \
            would be deleted, more than half.
            """)
            summary.withheldDeletes = destructive
            return summary
        }

        for link in plan.deletes {
            await deleteLinked(link, summary: &summary)
        }
        for link in plan.forgets {
            // The card is the user's; drop our bookkeeping only. Baseline it so
            // the import pass doesn't immediately pull it back in as a new
            // contact.
            baselineStore.add(link.cnIdentifier)
            linkStore.remove(localId: link.localId)
        }
        for relink in plan.relinks {
            linkStore.remove(localId: relink.link.localId)
            guard !relink.link.userOwned else {
                // Re-point the link at the contact's new localId, but don't
                // write to the card: a tooOld wipe must not become licence to
                // rewrite a card the user authored.
                linkStore.upsert(SystemContactLink(
                    localId: relink.contact.localId,
                    uid: relink.contact.uid,
                    cnIdentifier: relink.link.cnIdentifier,
                    exportedUpdatedAt: relink.contact.updatedAt,
                    imported: relink.link.imported,
                    userOwned: true
                ))
                continue
            }
            await upsertLinked(
                relink.contact,
                cnIdentifier: relink.link.cnIdentifier,
                importedOverride: relink.link.imported,
                userOwnedOverride: relink.link.userOwned,
                summary: &summary
            )
        }
        for update in plan.updates {
            await upsertLinked(update.contact, cnIdentifier: update.cnIdentifier, summary: &summary)
        }
        for contact in plan.creates {
            await create(contact, summary: &summary)
        }

        if summary != Summary() {
            Log.sync.info("""
            System contacts sync: \(summary.created) created, \
            \(summary.updated) updated, \(summary.deleted) deleted, \
            \(summary.imported) imported, \(summary.adopted) adopted, \
            \(summary.failed) failed
            """)
        }
        return summary
    }

    /// Incremental hook for a single save from ContactSyncRepository.
    func exportUpsert(_ contact: Contact) async {
        guard settings.exportToSystemContactsEnabled, isAuthorized else { return }
        await serialized {
            var summary = Summary()
            if let link = self.linkStore.link(localId: contact.localId) {
                // A card the user authored is linked for de-duplication only;
                // don't overwrite it from app data.
                guard !link.userOwned else { return summary }
                await self.upsertLinked(contact, cnIdentifier: link.cnIdentifier, summary: &summary)
            } else if let match = await self.adoptableCard(for: contact) {
                // Same person already has a card on this device. Adopt it so we
                // don't create a junk duplicate — but the card is the user's,
                // so record that and leave its contents alone. Overwriting it
                // here was the incremental-save flavour of the same defect the
                // reconcile path had.
                self.linkStore.upsert(SystemContactLink(
                    localId: contact.localId,
                    uid: contact.uid,
                    cnIdentifier: match.identifier,
                    exportedUpdatedAt: contact.updatedAt,
                    imported: false,
                    userOwned: true
                ))
                summary.adopted += 1
            } else {
                await self.create(contact, summary: &summary)
            }
            return summary
        }
    }

    /// Incremental hook for a single delete; only linked (app-created) cards.
    func exportDelete(localId: UUID) async {
        guard settings.exportToSystemContactsEnabled, isAuthorized else { return }
        await serialized {
            guard let link = self.linkStore.link(localId: localId) else { return Summary() }
            var summary = Summary()
            await self.deleteLinked(link, summary: &summary)
            return summary
        }
    }

    /// Destructive cleanup from Preferences: removes every card the app
    /// created and forgets the links. Cards the user created in Contacts.app
    /// (imports) are kept and baselined so they aren't re-imported. Works
    /// with the toggle off.
    ///
    /// Returns the whole `Summary`, not just the count removed. `deleteLinked`
    /// drops a link even when the provider refused the delete — so a caller
    /// that has to *report* whether anything survived cannot ask
    /// `hasExportedContacts` afterwards and get a truthful answer.
    /// `SecurityWipe` is that caller, and `failed` is what it reads.
    @discardableResult
    func removeAllExported() async -> Summary {
        guard isAuthorized else { return Summary() }
        let summary = await serialized {
            var summary = Summary()
            for link in self.linkStore.all() {
                // Imported cards the user made in Contacts.app, and cards the
                // app merely adopted to avoid a duplicate, are both the user's.
                // Only cards this app actually created are removed — checking
                // `imported` alone deleted adopted cards, contradicting the
                // button's own "cards the app created" description.
                if link.imported || link.userOwned {
                    self.baselineStore.add(link.cnIdentifier)
                    self.linkStore.remove(localId: link.localId)
                } else {
                    await self.deleteLinked(link, summary: &summary)
                }
            }
            return summary
        }
        return summary
    }

    // MARK: - Private

    /// De-dupe pass: an unlinked app contact and an unlinked card that match
    /// (same email, else same name+phone) are the same person — link them
    /// instead of exporting or importing a duplicate. This is what prevents
    /// junk duplicates when the relay and the device both already know a
    /// contact on first sync. The distantPast timestamp makes the export
    /// pass refresh the card's mapped fields from the app contact.
    private func adoptMatchingCards(_ cards: [CNContact], summary: inout Summary) async {
        let links = linkStore.all()
        // Unified-card identifiers aren't stable: macOS regenerates them when
        // it links or unlinks cards, which our own exports can trigger. A
        // link whose card identifier vanished must not keep claiming its
        // contact or its card slot — otherwise the contact can never re-match
        // its card and the card gets re-imported as a duplicate on every
        // pass. Contacts holding only a stale link re-adopt here by identity,
        // carrying the old link's bookkeeping over to the new identifier.
        let cardIdentifiers = Set(cards.map(\.identifier))
        let liveLinks = links.filter { cardIdentifiers.contains($0.cnIdentifier) }
        let staleLinks = Dictionary(
            links.filter { !cardIdentifiers.contains($0.cnIdentifier) }
                .map { ($0.localId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let linkedIdentifiers = Set(liveLinks.map(\.cnIdentifier))
        let linkedLocalIds = Set(liveLinks.map(\.localId))

        // A card is indexed under every identity it can match (one per email,
        // else name+phone); `consumed` keeps adoption one-to-one.
        var candidates: [String: [CNContact]] = [:]
        for card in cards where !linkedIdentifiers.contains(card.identifier) {
            for key in SystemContactMapper.matchKeys(for: card) {
                candidates[key, default: []].append(card)
            }
        }
        guard !candidates.isEmpty else { return }
        var consumed = Set<String>()

        let contacts = (try? await contactDAO.listAll()) ?? []
        for contact in contacts where !linkedLocalIds.contains(contact.localId) {
            // Every identity this contact has, not just its primary email:
            // the card is indexed under all of its own, and matching only on
            // the primary meant a card carrying the contact's *second*
            // address was never adopted, so both sides duplicated it.
            guard let card = SystemContactMapper.matchKeys(for: contact).lazy
                .compactMap({ key in
                    candidates[key]?.first { !consumed.contains($0.identifier) }
                })
                .first
            else { continue }
            consumed.insert(card.identifier)
            let stale = staleLinks[contact.localId]
            // A card with no prior link of ours is one the user authored: we
            // are adopting it purely so the export pass doesn't create a
            // duplicate. Marking it userOwned is what stops the same pass
            // rewriting every mapped field from relay data — writing
            // `imported: false` alone made adopted cards indistinguishable
            // from cards we created, so a sparse relay contact could strip a
            // real card's phones, addresses and birthday, and a later orphaned
            // link could delete it outright.
            //
            // A re-adoption (stale link present) is a card we already owned
            // whose unified identifier drifted, so it keeps its provenance and
            // its export timestamp — rewriting it would just churn Contacts.
            let isReadoption = stale != nil
            linkStore.upsert(SystemContactLink(
                localId: contact.localId,
                uid: contact.uid,
                cnIdentifier: card.identifier,
                // Fresh adoptions no longer need distantPast to force a
                // refresh: we are deliberately not refreshing them.
                exportedUpdatedAt: stale?.exportedUpdatedAt ?? contact.updatedAt,
                imported: stale?.imported ?? false,
                userOwned: stale?.userOwned ?? !isReadoption
            ))
            summary.adopted += 1
        }
    }

    /// Single-contact flavor of the adoption pass, for the incremental save
    /// hook: the first unlinked card matching this contact's identity.
    private func adoptableCard(for contact: Contact) async -> CNContact? {
        let keys = Set(SystemContactMapper.matchKeys(for: contact))
        guard !keys.isEmpty else { return nil }
        let linkedIdentifiers = Set(linkStore.all().map(\.cnIdentifier))
        let cards = (try? await store.listAll()) ?? []
        return cards.first {
            !linkedIdentifiers.contains($0.identifier)
                && SystemContactMapper.matchKeys(for: $0).contains(where: keys.contains)
        }
    }

    /// Cards added in Contacts.app after sync was enabled become app contacts
    /// queued (needsSync) for the next relay push. The very first pass only
    /// captures the baseline, so enabling sync doesn't import the user's
    /// whole pre-existing address book.
    private func importNewCards(_ cards: [CNContact], summary: inout Summary) async {
        guard baselineStore.isCaptured else {
            baselineStore.capture(identifiers: cards.map(\.identifier))
            return
        }
        let linked = Set(linkStore.all().map(\.cnIdentifier))
        let baseline = baselineStore.identifiers()
        // Identity guard: a card matching an app contact is never imported,
        // whatever its identifier says — drifted unified identifiers would
        // otherwise re-import the whole address book as duplicates. Matched
        // cards are baselined so they stay ignored even if their app contact
        // is deleted later.
        let contacts = (try? await contactDAO.listAll()) ?? []
        var knownKeys = Set(contacts.flatMap { SystemContactMapper.matchKeys(for: $0) })
        for card in cards
        where !linked.contains(card.identifier) && !baseline.contains(card.identifier) {
            let keys = SystemContactMapper.matchKeys(for: card)
            if keys.contains(where: knownKeys.contains) {
                baselineStore.add(card.identifier)
                continue
            }
            let contact = SystemContactMapper.contact(from: card)
            do {
                try await contactDAO.upsert(contacts: [contact])
                knownKeys.formUnion(keys)
                linkStore.upsert(SystemContactLink(
                    localId: contact.localId,
                    uid: nil,
                    cnIdentifier: card.identifier,
                    exportedUpdatedAt: contact.updatedAt,
                    imported: true
                ))
                summary.imported += 1
            } catch {
                summary.failed += 1
                Log.sync.error("System contacts import failed: \(error.localizedDescription)")
            }
        }
    }

    private func photoData(for contact: Contact) -> Data? {
        guard let photoRef = contact.photoRef, !photoRef.isEmpty else { return nil }
        return photoCache?.data(for: photoRef)
    }

    private func create(_ contact: Contact, summary: inout Summary) async {
        let cn = SystemContactMapper.makeContact(from: contact, photoData: photoData(for: contact))
        do {
            try await store.add(cn)
            linkStore.upsert(SystemContactLink(
                localId: contact.localId,
                uid: contact.uid,
                cnIdentifier: cn.identifier,
                exportedUpdatedAt: contact.updatedAt
            ))
            await syncGroups(for: contact, cardIdentifier: cn.identifier)
            summary.created += 1
        } catch {
            // No link written; retried as a create on the next reconcile.
            summary.failed += 1
            Log.sync.error("System contacts add failed: \(error.localizedDescription)")
        }
    }

    /// `importedOverride` keeps a link's imported flag across rewrites (the
    /// relink path removes the old link first, so the lookup here can't see
    /// it); everyone else inherits whatever the existing link says.
    private func upsertLinked(
        _ contact: Contact,
        cnIdentifier: String,
        importedOverride: Bool? = nil,
        userOwnedOverride: Bool? = nil,
        summary: inout Summary
    ) async {
        let existingLink = linkStore.link(localId: contact.localId)
        let imported = importedOverride ?? existingLink?.imported ?? false
        // Provenance has to survive a rewrite, or the next reconcile treats a
        // user-authored card as ours again.
        let userOwned = userOwnedOverride ?? existingLink?.userOwned ?? false
        do {
            if let existing = try await store.fetch(identifier: cnIdentifier),
               let mutable = existing.mutableCopy() as? CNMutableContact {
                SystemContactMapper.apply(contact, to: mutable, photoData: photoData(for: contact))
                try await store.update(mutable)
                linkStore.upsert(SystemContactLink(
                    localId: contact.localId,
                    uid: contact.uid,
                    cnIdentifier: cnIdentifier,
                    exportedUpdatedAt: contact.updatedAt,
                    imported: imported,
                    userOwned: userOwned
                ))
                await syncGroups(for: contact, cardIdentifier: cnIdentifier)
                summary.updated += 1
            } else {
                // Card deleted in Contacts.app: recreate and repair the link.
                linkStore.remove(localId: contact.localId)
                await create(contact, summary: &summary)
            }
        } catch {
            summary.failed += 1
            Log.sync.error("System contacts update failed: \(error.localizedDescription)")
        }
    }

    private func deleteLinked(_ link: SystemContactLink, summary: inout Summary) async {
        do {
            try await store.delete(identifier: link.cnIdentifier)
            summary.deleted += 1
        } catch {
            summary.failed += 1
            Log.sync.error("System contacts delete failed: \(error.localizedDescription)")
        }
        // The app contact is gone either way; a failed delete against this
        // identifier would never succeed later, so drop the link too.
        linkStore.remove(localId: link.localId)
    }
}
