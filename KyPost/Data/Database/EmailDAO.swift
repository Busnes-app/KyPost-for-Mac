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
    /// Replaces the cached snapshot of a folder with a fresh fetch result.
    func replaceFolderSnapshot(folder: String, emails: [Email]) throws {
        try modelContext.delete(
            model: EmailEntity.self,
            where: #Predicate { $0.folder == folder }
        )
        for email in emails {
            modelContext.insert(EmailEntity(from: email))
        }
        try modelContext.save()
    }

    /// Applies one delta response: upserts `emails`, dropping any that the
    /// server marked "updated" and we have no row for; deletes `removedIds`;
    /// and prunes the folder against `emails` only when told to.
    ///
    /// An "updated" entry never carries a body. With an existing row we merge
    /// and keep the body already held. With **no** existing row there is
    /// nothing to merge into, and storing the entry as-is created a row whose
    /// empty body was indistinguishable from a client-protected message — the
    /// reader then claimed end-to-end encryption for mail the server had
    /// decrypted. Skipping is correct: we do not have this message, and a
    /// metadata-only delta is not a delivery of it. The next full window
    /// brings it in properly.
    func applyDelta(
        folder: String,
        emails: [Email],
        updatedIds: Set<String>,
        removedIds: [String],
        pruneAgainstEmails: Bool
    ) throws {
        for email in emails {
            let existing = try fetchEntity(serverId: email.serverId)
            if updatedIds.contains(email.serverId) || email.bodyOmitted {
                guard let existing else { continue }
                apply(email, to: existing, preservingBodyOf: existing)
            } else if let existing {
                apply(email, to: existing, preservingBodyOf: nil)
            } else {
                modelContext.insert(EmailEntity(from: email))
            }
        }
        for id in removedIds {
            try modelContext.delete(
                model: EmailEntity.self,
                where: #Predicate { $0.serverId == id }
            )
        }
        if pruneAgainstEmails {
            let keep = Set(emails.map(\.serverId))
            let stale = try modelContext.fetch(
                FetchDescriptor<EmailEntity>(predicate: #Predicate { $0.folder == folder })
            )
            for entity in stale where !keep.contains(entity.serverId) {
                modelContext.delete(entity)
            }
        }
        try modelContext.save()
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
        entity.read = email.read
        entity.starred = email.starred
        entity.hasAttachments = email.hasAttachments
        entity.pgpEncrypted = email.pgpEncrypted
        entity.pgpSigned = email.pgpSigned
        entity.pgpVerified = email.pgpVerified
        entity.pgpSignerFingerprint = email.pgpSignerFingerprint
        entity.pgpDecryptError = email.pgpDecryptError
        if let preserving {
            entity.body = preserving.body
            entity.bodyMode = email.bodyMode.isEmpty ? preserving.bodyMode : email.bodyMode
        } else {
            entity.body = email.body
            entity.bodyMode = email.bodyMode
        }
    }

    private func fetchEntity(serverId: String) throws -> EmailEntity? {
        var descriptor = FetchDescriptor<EmailEntity>(
            predicate: #Predicate { $0.serverId == serverId }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Newest-first page of a folder.
    func getFolder(folder: String, limit: Int, offset: Int = 0) throws -> [Email] {
        var descriptor = FetchDescriptor<EmailEntity>(
            predicate: #Predicate { $0.folder == folder },
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return try modelContext.fetch(descriptor).map(\.toDomain)
    }

    func getEmail(serverId: String) throws -> Email? {
        var descriptor = FetchDescriptor<EmailEntity>(
            predicate: #Predicate { $0.serverId == serverId }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.toDomain
    }

    func updateEmail(serverId: String, read: Bool? = nil, starred: Bool? = nil) throws {
        var descriptor = FetchDescriptor<EmailEntity>(
            predicate: #Predicate { $0.serverId == serverId }
        )
        descriptor.fetchLimit = 1
        guard let entity = try modelContext.fetch(descriptor).first else { return }
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

    /// Local cache search over subject, sender, and body.
    func search(folder: String, query: String) throws -> [Email] {
        let descriptor = FetchDescriptor<EmailEntity>(
            predicate: #Predicate {
                $0.folder == folder && (
                    $0.subject.localizedStandardContains(query)
                    || $0.senderName.localizedStandardContains(query)
                    || $0.body.localizedStandardContains(query)
                )
            },
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(\.toDomain)
    }
}
