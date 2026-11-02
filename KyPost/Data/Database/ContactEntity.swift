//
//  ContactEntity.swift
//  KyPost
//
//  SwiftData entity for the contacts table (spec §8), schema V2: full
//  contactPayload parity (Client_Contact_Update.md). Array fields are Codable
//  composites — fine for storage, but #Predicate can't see inside them; all
//  queries stay on localId/uid/needsSync.
//

import Foundation
import SwiftData

@Model
final class ContactEntity {
    @Attribute(.unique) var localId: UUID
    /// Server-assigned UID from sync; nil until reconciliation assigns one.
    /// Uniqueness of non-nil uids is enforced by upsert logic, not the schema
    /// (SwiftData unique attributes don't allow multiple nils).
    var uid: String?
    /// Server revision for sync conflict detection; 0 until first sync.
    var rev: Int = 0
    var name: String
    /// V1 single-value columns, kept only so the V1→V2 migration stays
    /// lightweight. ContactDAO.migrateLegacyFields() backfills them into
    /// `emails`/`phones` once at startup; drop in V3.
    @Attribute(originalName: "email") var legacyEmail: String = ""
    @Attribute(originalName: "phone") var legacyPhone: String = ""
    var givenName: String = ""
    var familyName: String = ""
    var middleName: String = ""
    var prefix: String = ""
    var suffix: String = ""
    var nickname: String = ""
    var org: String = ""
    var title: String = ""
    var emails: [ContactLabeledValue] = []
    var phones: [ContactLabeledValue] = []
    var addresses: [ContactPostalAddress] = []
    var notes: String = ""
    var birthday: String = ""
    var photoRef: String?
    var groupIDs: [String] = []
    var pgpKey: String?
    /// A key from sync awaiting review before it replaces `pgpKey` — see
    /// Contact.pendingPgpKey.
    var pendingPgpKey: String?
    var ims: [ContactIM] = []
    var websites: [ContactLabeledValue] = []
    var relations: [ContactRelation] = []
    var events: [ContactEvent] = []
    var phoneticGivenName: String = ""
    var phoneticFamilyName: String = ""
    var department: String = ""
    var customFields: [ContactCustomField] = []
    var pronouns: String = ""
    /// Read-only mirror of the server's flag; added in AppSchemaV6.
    var isSelf: Bool = false
    var avatarUrl: String?
    var createdAt: Date
    var updatedAt: Date
    /// Local create/edit not yet pushed to the server.
    var needsSync: Bool
    /// See Contact.importConsent; added in AppSchemaV10.
    var importConsent: String?

    init(
        localId: UUID,
        uid: String?,
        rev: Int = 0,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        needsSync: Bool = false
    ) {
        self.localId = localId
        self.uid = uid
        self.rev = rev
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.needsSync = needsSync
    }
}

// MARK: - Mapping (ContactMapper equivalent)

extension ContactEntity {
    convenience init(from contact: Contact) {
        self.init(
            localId: contact.localId,
            uid: contact.uid,
            rev: contact.rev,
            name: contact.name,
            createdAt: contact.createdAt,
            updatedAt: contact.updatedAt,
            needsSync: contact.needsSync
        )
        applyFields(from: contact)
    }

    /// Copies every payload field from the domain contact; shared by the
    /// insert path above and ContactDAO.upsert's update path.
    func applyFields(from contact: Contact) {
        givenName = contact.givenName
        familyName = contact.familyName
        middleName = contact.middleName
        prefix = contact.prefix
        suffix = contact.suffix
        nickname = contact.nickname
        org = contact.org
        title = contact.title
        emails = contact.emails
        phones = contact.phones
        addresses = contact.addresses
        notes = contact.notes
        birthday = contact.birthday
        photoRef = contact.photoRef
        groupIDs = contact.groupIDs
        pgpKey = contact.pgpKey
        pendingPgpKey = contact.pendingPgpKey
        ims = contact.ims
        websites = contact.websites
        relations = contact.relations
        events = contact.events
        phoneticGivenName = contact.phoneticGivenName
        phoneticFamilyName = contact.phoneticFamilyName
        department = contact.department
        customFields = contact.customFields
        pronouns = contact.pronouns
        isSelf = contact.isSelf
        avatarUrl = contact.avatarUrl
        // Cleared only by `ContactDAO.assignUid`: a write that does not carry
        // it (a server copy) keeps it, and an edit in KyPost
        // (`Contact.createdInKyPost`) never turns an import into a KyPost
        // contact.
        if let incoming = contact.importConsent,
           incoming != Contact.createdInKyPost || !Contact.isImportStamp(importConsent) {
            importConsent = incoming
        }
    }

    var toDomain: Contact {
        Contact(
            localId: localId,
            uid: uid,
            rev: rev,
            name: name,
            givenName: givenName,
            familyName: familyName,
            middleName: middleName,
            prefix: prefix,
            suffix: suffix,
            nickname: nickname,
            org: org,
            title: title,
            emails: emails,
            phones: phones,
            addresses: addresses,
            notes: notes,
            birthday: birthday,
            photoRef: photoRef,
            groupIDs: groupIDs,
            isSelf: isSelf,
            pgpKey: pgpKey,
            pendingPgpKey: pendingPgpKey,
            ims: ims,
            websites: websites,
            relations: relations,
            events: events,
            phoneticGivenName: phoneticGivenName,
            phoneticFamilyName: phoneticFamilyName,
            department: department,
            customFields: customFields,
            pronouns: pronouns,
            avatarUrl: avatarUrl,
            createdAt: createdAt,
            updatedAt: updatedAt,
            needsSync: needsSync,
            importConsent: importConsent
        )
    }
}
