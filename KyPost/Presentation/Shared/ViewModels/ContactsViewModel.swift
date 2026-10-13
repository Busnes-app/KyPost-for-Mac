//
//  ContactsViewModel.swift
//  KyPost
//
//  Contact list + editing + sync trigger (spec §4).
//

import Foundation
import Observation

@Observable
@MainActor
final class ContactsViewModel {
    private let repository: ContactSyncRepository

    /// Whether the paired account has a PGP identity on the server, or nil
    /// while unknown. Nil must not render as "no key" — see
    /// `pgpIdentityPresent`.
    private(set) var accountIdentityPresent: Bool?

    /// True until the user has been told what contact sync does. Explained
    /// before the first sync, not after — the point is to say what is about to
    /// leave the device while that is still a choice.
    var shouldExplainSync: Bool { !settingsStore.syncExplained }

    func markSyncExplained() { settingsStore.syncExplained = true }

    /// Reads the cached bootstrap custody. Cheap and idempotent: the service
    /// fetches once per session.
    func loadAccountIdentity(from service: PgpSendService) async {
        await service.loadIfNeeded()
        accountIdentityPresent = pgpIdentityPresent(custody: service.custody)
    }

    /// Group names for one contact, resolved against the pulled group list.
    func groupNames(for contact: Contact) async -> [String] {
        await repository.groupNames(for: contact)
    }

    private(set) var contacts: [Contact] = []
    /// Compose's autocomplete and the address book search this instead of the
    /// store; see ContactSearch. Rebuilt in `load()` — the one place
    /// `contacts` changes — so the two can't drift.
    private(set) var searchIndex = ContactSearchIndex()
    private(set) var isSyncing = false
    private(set) var statusMessage: String?

    private let settingsStore: ContactsSettingsStore

    init(repository: ContactSyncRepository, settingsStore: ContactsSettingsStore) {
        self.settingsStore = settingsStore
        self.repository = repository
    }

    func load() async {
        contacts = (try? await repository.contacts()) ?? []
        searchIndex = ContactSearchIndex(contacts: contacts)
        await repository.refreshPendingSummary()
    }

    // MARK: - Sync status

    /// The repository's count, refreshed after every write and sync —
    /// including the ones the change monitor runs without this view model.
    var pendingSummary: ContactPendingSummary { repository.health.pending }

    /// The banner's state at `now`. Time-dependent (a change becomes "stuck"
    /// after an hour), so the view re-asks on a timer rather than caching it.
    func syncStatus(now: Date = Date()) -> ContactSyncStatus {
        ContactSyncStatus.of(pending: pendingSummary, failures: repository.health.failures, now: now)
    }

    /// For callers that need contacts but aren't the contact list. On iOS
    /// nothing loads them until the Contacts tab is opened, so compose would
    /// otherwise autocomplete against an empty book on a fresh launch.
    func loadIfNeeded() async {
        guard contacts.isEmpty else { return }
        await load()
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await performSync()
    }

    /// Asks the server to merge duplicates, then syncs to pull the merges in.
    func dedupe() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let report = try await repository.dedupe()
            let message = Self.dedupeMessage(for: report)
            // The follow-up sync is what actually removes the absorbed
            // contacts locally; it overwrites statusMessage, so the report
            // is re-asserted afterwards as the outcome worth reading.
            await performSync()
            statusMessage = message
        } catch ContactSyncError.notPaired {
            statusMessage = "Pair this device to sync contacts."
        } catch NetworkError.unauthorized {
            // The endpoint takes pairing auth (backend withMailAuth), so a 401
            // is a credentials problem rather than a missing feature.
            statusMessage = "Couldn't merge duplicates — try pairing this device again."
        } catch {
            statusMessage = "Find Duplicates failed: \(error.localizedDescription)"
        }
    }

    private static func dedupeMessage(for report: ContactDedupeReport) -> String {
        let groups = report.groups ?? []
        guard report.mergedCount > 0 else { return "No duplicates found" }
        return "Merged \(report.mergedCount) duplicate contacts into \(groups.count) groups"
    }

    /// Shared by `sync()` and `dedupe()`'s follow-up pass — calling `sync()`
    /// from `dedupe()` would hit the `isSyncing` guard and silently no-op.
    private func performSync() async {
        do {
            let summary = try await repository.sync()
            statusMessage = "Synced — pushed \(summary.pushed), received \(summary.applied)"
            await load()
        } catch ContactSyncError.notPaired {
            statusMessage = "Pair this device to sync contacts."
        } catch {
            statusMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    func save(_ contact: Contact) async {
        try? await repository.saveContact(contact)
        await load()
    }

    /// Trusts a PGP key that arrived via sync, after the user has
    /// independently re-verified it out-of-band.
    func acceptPendingPgpKey(for contact: Contact) async {
        try? await repository.acceptPendingPgpKey(for: contact)
        await load()
    }

    /// Discards a PGP key that arrived via sync, keeping the key on file.
    func dismissPendingPgpKey(for contact: Contact) async {
        try? await repository.dismissPendingPgpKey(for: contact)
        await load()
    }

    func delete(_ contact: Contact) async {
        try? await repository.deleteContact(contact)
        await load()
    }
}
