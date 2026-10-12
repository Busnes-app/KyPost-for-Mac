//
//  EmailDAO.swift
//  KyPost
//
//  Data access for cached emails (spec §8 EmailDAO). A @ModelActor so all
//  SwiftData work happens off the main thread.
//

import Foundation
import SwiftData

@ModelActor
actor EmailDAO {
    /// Thrown by a write that carries an epoch older than `accountEpoch`.
    struct AccountForgotten: Error {}

    /// Bumped by `forgetAccount`. A refresh, page or body fetch captures it
    /// before going to the network and hands it back with its write; one that
    /// started under an account since forgotten is refused rather than
    /// stored. In memory only: a fresh DAO starts with nothing in flight.
    private(set) var accountEpoch = 0

    /// Erases every cached row, window and older mail, bodies included, for
    /// an unpair or a pairing to another account. Bumps the epoch first, so
    /// a write already in flight cannot land after the erase.
    func forgetAccount() throws {
        accountEpoch += 1
        try saving {
            for entity in try modelContext.fetch(FetchDescriptor<EmailEntity>()) {
                modelContext.delete(entity)
            }
        }
    }

    /// Nil skips the check (tests and callers with no network step).
    private func requireEpoch(_ epoch: Int?) throws {
        if let epoch, epoch != accountEpoch { throw AccountForgotten() }
    }

    /// Applies a non-delta answer — the relay's whole window. See `snapshot`.
    func replaceFolderSnapshot(folder: String, emails: [Email], epoch: Int? = nil) throws {
        try requireEpoch(epoch)
        try saving { try snapshot(folder: folder, emails: emails) }
    }

    /// Applies one delta response. See `delta`.
    func applyDelta(
        folder: String,
        emails: [Email],
        updatedIds: Set<String>,
        removedIds: [String],
        agedOutIds: [String] = [],
        pruneAgainstEmails: Bool
    ) throws {
        try saving {
            try delta(
                folder: folder, emails: emails, updatedIds: updatedIds,
                removedIds: removedIds, agedOutIds: agedOutIds,
                pruneAgainstEmails: pruneAgainstEmails
            )
        }
    }

    /// One refresh, all or nothing: the window answer and the pages of a
    /// delta overflow walk land in one save. A row stored from a partial walk
    /// would count as held, and the retry would stop at it and skip the gap.
    func reconcile(folder: String, result: MailFetchResult, overflow: [Email], epoch: Int? = nil) throws {
        try requireEpoch(epoch)
        try saving {
            if result.isDelta {
                try delta(
                    folder: folder, emails: result.emails, updatedIds: result.updatedIds,
                    removedIds: result.removedIds, agedOutIds: result.agedOutIds,
                    pruneAgainstEmails: result.isFullWindow
                )
            } else {
                try snapshot(folder: folder, emails: result.emails)
            }
            try older(folder: folder, emails: overflow)
        }
    }

    /// Stores one page of mail older than the window. See `older`.
    func storeOlderMail(folder: String, emails: [Email], epoch: Int? = nil) throws {
        try requireEpoch(epoch)
        try saving { try older(folder: folder, emails: emails) }
    }

    /// Runs `body` and saves, or rolls every change back: a context left
    /// holding half a write would hand it to the next unrelated save.
    private func saving(_ body: () throws -> Void) throws {
        do {
            try body()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// The relay's whole window: upsert it, take absent rows older than all of
    /// it out of the window, and prune absent **window** rows only. Rows
    /// outside the window (paged in, aged out) are not this answer's to judge.
    private func snapshot(folder: String, emails: [Email]) throws {
        for email in emails {
            if let existing = try fetchEntity(folder: folder, serverId: email.serverId) {
                apply(email, to: existing, preservingBodyOf: nil)
            } else {
                modelContext.insert(EmailEntity(from: windowRow(email)))
            }
        }
        try ageOutAndPrune(folder: folder, window: emails)
    }

    /// Upserts `emails`, dropping any that the server marked "updated" and we
    /// have no row for; deletes `removedIds` from `folder` (an id names a
    /// message only within its folder, and `removed` deletes a row in or out
    /// of the window); takes `agedOutIds` out of the window; and prunes the
    /// folder against `emails` only when told to.
    ///
    /// An "updated" entry never carries a body. With an existing row we merge
    /// and keep the body already held. With **no** existing row there is
    /// nothing to merge into, and storing the entry as-is created a row whose
    /// empty body was indistinguishable from a client-protected message — the
    /// reader then claimed end-to-end encryption for mail the server had
    /// decrypted. Skipping is correct: we do not have this message, and a
    /// metadata-only delta is not a delivery of it. The next full window
    /// brings it in properly.
    private func delta(
        folder: String,
        emails: [Email],
        updatedIds: Set<String>,
        removedIds: [String],
        agedOutIds: [String],
        pruneAgainstEmails: Bool
    ) throws {
        for email in emails {
            let existing = try fetchEntity(folder: folder, serverId: email.serverId)
            if updatedIds.contains(email.serverId) || email.bodyOmitted {
                guard let existing else { continue }
                apply(email, to: existing, preservingBodyOf: existing)
            } else if let existing {
                apply(email, to: existing, preservingBodyOf: nil)
            } else {
                modelContext.insert(EmailEntity(from: windowRow(email)))
            }
        }
        for id in removedIds {
            try modelContext.delete(
                model: EmailEntity.self,
                where: #Predicate { $0.serverId == id && $0.folder == folder }
            )
        }
        for id in agedOutIds {
            try fetchEntity(folder: folder, serverId: id)?.inWindow = false
        }
        if pruneAgainstEmails {
            try ageOutAndPrune(folder: folder, window: emails)
        }
    }

    /// A full window is the newest mail. An absent row dated before all of it
    /// aged out unreported (a forgotten cursor, an older relay) and still
    /// exists, so it leaves the window rather than the cache; only absent rows
    /// inside the window's range are pruned.
    private func ageOutAndPrune(folder: String, window emails: [Email]) throws {
        let keep = Set(emails.map(\.serverId))
        let oldest = emails.map(\.receivedAt).filter(Email.isKnownDate).min()
        let rows = try modelContext.fetch(
            FetchDescriptor<EmailEntity>(predicate: #Predicate { $0.folder == folder && $0.inWindow })
        )
        for entity in rows where !keep.contains(entity.serverId) {
            if let oldest, entity.receivedAt < oldest {
                entity.inWindow = false
            } else {
                modelContext.delete(entity)
            }
        }
    }

    /// Mail older than the window. A held row keeps what only the window
    /// carries — body, attachment and PGP flags — and takes just its read
    /// state and labels; a new one is stored out of the window, without a
    /// body (the reader fetches it on open).
    private func older(folder: String, emails: [Email]) throws {
        for email in emails {
            if let existing = try fetchEntity(folder: folder, serverId: email.serverId) {
                existing.read = email.read
                existing.keywords = email.keywords.sorted()
            } else {
                var row = email
                row.folder = folder
                row.body = ""
                row.bodyMode = ""
                row.inWindow = false
                modelContext.insert(EmailEntity(from: row))
            }
        }
    }

    private func windowRow(_ email: Email) -> Email {
        var row = email
        row.inWindow = true
        return row
    }

    /// Copies the wire row onto an existing entity. When `preserving` is
    /// non-nil the body and its mode are kept — a blank incoming bodyMode
    /// never overwrites a known one either.
    private func apply(_ email: Email, to entity: EmailEntity, preservingBodyOf preserving: EmailEntity?) {
        entity.folder = email.folder
        entity.senderName = email.senderName
        entity.senderEmail = email.senderEmail
        entity.subject = email.subject
        entity.sentTo = email.sentTo
        entity.cc = email.cc
        entity.keywords = email.keywords.sorted()
        entity.receivedAt = email.receivedAt
        // Written even when nil: an updated row without `wokenAt` unpins.
        entity.wokenAt = email.wokenAt
        entity.sortDate = email.sortDate
        entity.read = email.read
        entity.starred = email.starred
        entity.hasAttachments = email.hasAttachments
        entity.pgpEncrypted = email.pgpEncrypted
        entity.pgpSigned = email.pgpSigned
        entity.pgpVerified = email.pgpVerified
        entity.pgpSignerFingerprint = email.pgpSignerFingerprint
        entity.pgpDecryptError = email.pgpDecryptError
        // Whatever the window answer names is in the window.
        entity.inWindow = true
        if let preserving {
            entity.body = preserving.body
            entity.bodyMode = email.bodyMode.isEmpty ? preserving.bodyMode : email.bodyMode
        } else {
            entity.body = email.body
            entity.bodyMode = email.bodyMode
        }
    }

    private func fetchEntity(folder: String, serverId: String) throws -> EmailEntity? {
        var descriptor = FetchDescriptor<EmailEntity>(
            predicate: #Predicate { $0.serverId == serverId && $0.folder == folder }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// List order, newest first. `receivedAt` breaks ties, including rows
    /// still awaiting `backfillSortDates`.
    private static var listOrder: [SortDescriptor<EmailEntity>] {
        [
            SortDescriptor(\.sortDate, order: .reverse),
            SortDescriptor(\.receivedAt, order: .reverse),
        ]
    }

    /// Sets `sortDate` on rows stored before AppSchemaV9 added it. None of
    /// them can be woken, so `receivedAt` is exact. Safe to call every launch.
    func backfillSortDates() throws {
        let unset = Date.distantPast
        let rows = try modelContext.fetch(
            FetchDescriptor<EmailEntity>(predicate: #Predicate { $0.sortDate == unset })
        )
        guard !rows.isEmpty else { return }
        for row in rows { row.sortDate = row.receivedAt }
        try modelContext.save()
    }

    /// Newest-first rows of a folder — every row, window and older mail,
    /// unless `limit` says otherwise.
    func getFolder(folder: String, limit: Int? = nil, offset: Int = 0) throws -> [Email] {
        var descriptor = FetchDescriptor<EmailEntity>(
            predicate: #Predicate { $0.folder == folder },
            sortBy: Self.listOrder
        )
        if let limit { descriptor.fetchLimit = limit }
        descriptor.fetchOffset = offset
        return try modelContext.fetch(descriptor).map(\.toDomain)
    }

    /// Every id the folder holds, in or out of the window.
    func heldIds(folder: String) throws -> Set<String> {
        let rows = try modelContext.fetch(
            FetchDescriptor<EmailEntity>(predicate: #Predicate { $0.folder == folder })
        )
        return Set(rows.map(\.serverId))
    }

    /// The oldest row's id, where "Load older mail" starts its first page.
    /// Oldest by date, not by UID: a message moved into the folder can make
    /// the first page repeat rows already held, which merge harmlessly.
    func oldestRowId(folder: String) throws -> String? {
        var descriptor = FetchDescriptor<EmailEntity>(
            predicate: #Predicate { $0.folder == folder },
            sortBy: [SortDescriptor(\.receivedAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.serverId
    }

    /// Fills in a body fetched on open. Scoped to the columns the fetch
    /// answers for; the caller decides whether the row may cache one at all.
    func updateBody(folder: String, serverId: String, body: String, bodyMode: String, epoch: Int? = nil) throws {
        try requireEpoch(epoch)
        guard let entity = try fetchEntity(folder: folder, serverId: serverId) else { return }
        entity.body = body
        if !bodyMode.isEmpty { entity.bodyMode = bodyMode }
        try modelContext.save()
    }

    /// Whether the folder holds any cached row at all.
    func hasRows(folder: String) throws -> Bool {
        var descriptor = FetchDescriptor<EmailEntity>(
            predicate: #Predicate { $0.folder == folder }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetchCount(descriptor) > 0
    }

    func getEmail(folder: String, serverId: String) throws -> Email? {
        try fetchEntity(folder: folder, serverId: serverId)?.toDomain
    }

    func updateEmail(folder: String, serverId: String, read: Bool? = nil, starred: Bool? = nil) throws {
        guard let entity = try fetchEntity(folder: folder, serverId: serverId) else { return }
        if let read { entity.read = read }
        if let starred { entity.starred = starred }
        try modelContext.save()
    }

    /// Drops the cached rows the relay confirmed it moved out of `folder`.
    /// Scoped by folder as well as id: a late answer must not remove a row the
    /// cache has since filed elsewhere.
    func deleteEmails(serverIds: [String], folder: String) throws {
        for id in serverIds {
            try modelContext.delete(
                model: EmailEntity.self,
                where: #Predicate { $0.serverId == id && $0.folder == folder }
            )
        }
        try modelContext.save()
    }
}
