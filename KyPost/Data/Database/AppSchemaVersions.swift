//
//  AppSchemaVersions.swift
//  KyPost
//
//  Versioned SwiftData schemas + migration plan. V1 is the shipped shape
//  (single email/phone strings on ContactEntity); V2 adds full contactPayload
//  parity incl. pgpKey (Client_Contact_Update.md); V3 adds pendingPgpKey to
//  ContactEntity and the five pgp columns to EmailEntity
//  (Client_PGP_Update.md); V4 adds bodyMode/hasAttachments to EmailEntity;
//  V5 adds GroupEntity; V6 adds isSelf to ContactEntity; V7 keys EmailEntity
//  on (folder, serverId) instead of serverId alone; V8 adds inWindow to
//  EmailEntity; V9 adds wokenAt/sortDate to EmailEntity (sortDate backfilled
//  by EmailDAO.backfillSortDates).
//  The stages are lightweight: V2 renames email/phone
//  to legacyEmail/legacyPhone via originalName and adds every new field with a
//  default. The legacy→array data copy happens in app code
//  (ContactDAO.migrateLegacyFields), not in the migration machinery.
//
//  IMPORTANT: with a staged migration plan, SwiftData identifies the on-disk
//  store by matching its model hashes against these versioned schemas. Any
//  change to a live @Model — even an additive one with a default — therefore
//  needs a snapshot of the old shape here plus a new version and stage, or
//  every existing store fails to open with "Cannot use staged migration with
//  an unknown model version" and the app crashes at launch.
//

import Foundation
import SwiftData

enum AppSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [EmailEntity.self, ContactEntity.self, PushNotificationEntity.self, KeywordEntity.self]
    }

    /// Snapshot of EmailEntity as shipped before the pgp columns (V3). The
    /// nested class keeps the entity name "EmailEntity" so migration identity
    /// matches stores written at V1 and V2.
    @Model
    final class EmailEntity {
        @Attribute(.unique) var serverId: String
        var folder: String
        var senderName: String
        var senderEmail: String
        var subject: String
        var body: String
        var sentTo: String = ""
        var cc: String = ""
        var keywords: [String]
        var receivedAt: Date
        var read: Bool
        var starred: Bool
        var createdAt: Date

        init(
            serverId: String,
            folder: String,
            senderName: String,
            senderEmail: String,
            subject: String,
            body: String,
            sentTo: String = "",
            cc: String = "",
            keywords: [String],
            receivedAt: Date,
            read: Bool,
            starred: Bool,
            createdAt: Date = Date()
        ) {
            self.serverId = serverId
            self.folder = folder
            self.senderName = senderName
            self.senderEmail = senderEmail
            self.subject = subject
            self.body = body
            self.sentTo = sentTo
            self.cc = cc
            self.keywords = keywords
            self.receivedAt = receivedAt
            self.read = read
            self.starred = starred
            self.createdAt = createdAt
        }
    }

    /// Snapshot of ContactEntity as shipped before field parity. The nested
    /// class keeps the entity name "ContactEntity" so migration identity
    /// matches the live model.
    @Model
    final class ContactEntity {
        @Attribute(.unique) var localId: UUID
        var uid: String?
        var rev: Int = 0
        var name: String
        var email: String
        var phone: String
        var avatarUrl: String?
        var createdAt: Date
        var updatedAt: Date
        var needsSync: Bool

        init(
            localId: UUID,
            uid: String?,
            rev: Int = 0,
            name: String,
            email: String,
            phone: String,
            avatarUrl: String?,
            createdAt: Date,
            updatedAt: Date,
            needsSync: Bool = false
        ) {
            self.localId = localId
            self.uid = uid
            self.rev = rev
            self.name = name
            self.email = email
            self.phone = phone
            self.avatarUrl = avatarUrl
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.needsSync = needsSync
        }
    }
}

enum AppSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        // EmailEntity was unchanged between V1 and V2, so V2 shares V1's
        // pre-pgp snapshot. ContactEntity is the V2 snapshot below.
        [AppSchemaV1.EmailEntity.self, ContactEntity.self, PushNotificationEntity.self, KeywordEntity.self]
    }

    /// Snapshot of ContactEntity at contactPayload parity (with pgpKey,
    /// before V3's pendingPgpKey). The nested class keeps the entity name
    /// "ContactEntity" so migration identity matches stores written at V2.
    @Model
    final class ContactEntity {
        @Attribute(.unique) var localId: UUID
        var uid: String?
        var rev: Int = 0
        var name: String
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
        var ims: [ContactIM] = []
        var websites: [ContactLabeledValue] = []
        var relations: [ContactRelation] = []
        var events: [ContactEvent] = []
        var phoneticGivenName: String = ""
        var phoneticFamilyName: String = ""
        var department: String = ""
        var customFields: [ContactCustomField] = []
        var pronouns: String = ""
        var avatarUrl: String?
        var createdAt: Date
        var updatedAt: Date
        var needsSync: Bool

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
}

enum AppSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        // EmailEntity gained the five pgp columns here and the V4 columns
        // later, so it needs its own snapshot below. ContactEntity gained
        // pendingPgpKey here and has not changed since, so V3 shares the live
        // model.
        [
            AppSchemaV3.EmailEntity.self, ContactEntity.self,
            PushNotificationEntity.self, KeywordEntity.self,
        ]
    }

    /// Snapshot of EmailEntity with the pgp columns but before V4's
    /// `bodyMode`/`hasAttachments`. The nested class keeps the entity name
    /// "EmailEntity" so migration identity matches stores written at V3.
    @Model
    final class EmailEntity {
        @Attribute(.unique) var serverId: String
        var folder: String
        var senderName: String
        var senderEmail: String
        var subject: String
        var body: String
        var sentTo: String = ""
        var cc: String = ""
        var keywords: [String]
        var receivedAt: Date
        var read: Bool
        var starred: Bool
        var pgpEncrypted: Bool = false
        var pgpSigned: Bool = false
        var pgpVerified: Bool = false
        var pgpSignerFingerprint: String = ""
        var pgpDecryptError: String = ""
        var createdAt: Date

        init(
            serverId: String,
            folder: String,
            senderName: String,
            senderEmail: String,
            subject: String,
            body: String,
            sentTo: String = "",
            cc: String = "",
            keywords: [String],
            receivedAt: Date,
            read: Bool,
            starred: Bool,
            createdAt: Date = Date()
        ) {
            self.serverId = serverId
            self.folder = folder
            self.senderName = senderName
            self.senderEmail = senderEmail
            self.subject = subject
            self.body = body
            self.sentTo = sentTo
            self.cc = cc
            self.keywords = keywords
            self.receivedAt = receivedAt
            self.read = read
            self.starred = starred
            self.createdAt = createdAt
        }
    }
}

enum AppSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        // EmailEntity gained bodyMode and hasAttachments. GroupEntity does not
        // exist yet at this version — adding a model is as much a schema change
        // as adding a column.
        [
            AppSchemaV6.EmailEntity.self, AppSchemaV5.ContactEntity.self,
            PushNotificationEntity.self, KeywordEntity.self,
        ]
    }
}

enum AppSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        // Adds GroupEntity (GET /api/groups). ContactEntity gains isSelf at
        // V6, so it needs its own snapshot there rather than here.
        [
            AppSchemaV6.EmailEntity.self, AppSchemaV5.ContactEntity.self,
            PushNotificationEntity.self, KeywordEntity.self, GroupEntity.self,
        ]
    }

    /// Snapshot of ContactEntity before `isSelf`. Nested so the entity name
    /// stays "ContactEntity" and migration identity matches stores at V3–V5.
    @Model
    final class ContactEntity {
        @Attribute(.unique) var localId: UUID
        var uid: String?
        var rev: Int = 0
        var name: String
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
        var avatarUrl: String?
        var createdAt: Date
        var updatedAt: Date
        var needsSync: Bool

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
}

enum AppSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

    static var models: [any PersistentModel.Type] {
        // ContactEntity gains isSelf.
        [
            AppSchemaV6.EmailEntity.self, ContactEntity.self, PushNotificationEntity.self,
            KeywordEntity.self, GroupEntity.self,
        ]
    }

    /// Snapshot of EmailEntity from V4 to V6: every column up to
    /// `bodyMode`/`hasAttachments`, unique on `serverId` alone. Nested so the
    /// entity name stays "EmailEntity" and migration identity matches stores
    /// written at V4–V6.
    @Model
    final class EmailEntity {
        @Attribute(.unique) var serverId: String
        var folder: String
        var senderName: String
        var senderEmail: String
        var subject: String
        var body: String
        var sentTo: String = ""
        var cc: String = ""
        var keywords: [String]
        var receivedAt: Date
        var read: Bool
        var starred: Bool
        var bodyMode: String = ""
        var hasAttachments: Bool = false
        var pgpEncrypted: Bool = false
        var pgpSigned: Bool = false
        var pgpVerified: Bool = false
        var pgpSignerFingerprint: String = ""
        var pgpDecryptError: String = ""
        var createdAt: Date

        init(
            serverId: String,
            folder: String,
            senderName: String,
            senderEmail: String,
            subject: String,
            body: String,
            keywords: [String],
            receivedAt: Date,
            read: Bool,
            starred: Bool,
            createdAt: Date = Date()
        ) {
            self.serverId = serverId
            self.folder = folder
            self.senderName = senderName
            self.senderEmail = senderEmail
            self.subject = subject
            self.body = body
            self.keywords = keywords
            self.receivedAt = receivedAt
            self.read = read
            self.starred = starred
            self.createdAt = createdAt
        }
    }
}

enum AppSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)

    static var models: [any PersistentModel.Type] {
        // EmailEntity is unique on (folder, serverId). The stage carries every
        // cached row over: under the old key every id was already unique, so
        // every (folder, id) pair is too. Should a store still refuse to open,
        // AppEnvironment discards it — mail lives on the server, and the cache
        // refills from an empty folder (MailRepository.refreshFolder).
        [
            AppSchemaV7.EmailEntity.self, ContactEntity.self, PushNotificationEntity.self,
            KeywordEntity.self, GroupEntity.self,
        ]
    }

    /// Snapshot of EmailEntity keyed on (folder, serverId), before V8's
    /// `inWindow`. Nested so the entity name stays "EmailEntity".
    @Model
    final class EmailEntity {
        #Unique<EmailEntity>([\.folder, \.serverId])

        var serverId: String
        var folder: String
        var senderName: String
        var senderEmail: String
        var subject: String
        var body: String
        var sentTo: String = ""
        var cc: String = ""
        var keywords: [String]
        var receivedAt: Date
        var read: Bool
        var starred: Bool
        var bodyMode: String = ""
        var hasAttachments: Bool = false
        var pgpEncrypted: Bool = false
        var pgpSigned: Bool = false
        var pgpVerified: Bool = false
        var pgpSignerFingerprint: String = ""
        var pgpDecryptError: String = ""
        var createdAt: Date

        init(
            serverId: String,
            folder: String,
            senderName: String,
            senderEmail: String,
            subject: String,
            body: String,
            keywords: [String],
            receivedAt: Date,
            read: Bool,
            starred: Bool,
            createdAt: Date = Date()
        ) {
            self.serverId = serverId
            self.folder = folder
            self.senderName = senderName
            self.senderEmail = senderEmail
            self.subject = subject
            self.body = body
            self.keywords = keywords
            self.receivedAt = receivedAt
            self.read = read
            self.starred = starred
            self.createdAt = createdAt
        }
    }
}

enum AppSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)

    static var models: [any PersistentModel.Type] {
        // EmailEntity gains inWindow, defaulting to true: every row cached
        // before it came from the window.
        [
            AppSchemaV8.EmailEntity.self, ContactEntity.self, PushNotificationEntity.self,
            KeywordEntity.self, GroupEntity.self,
        ]
    }

    /// Snapshot of EmailEntity at V8: keyed on (folder, serverId) with
    /// `inWindow`, before V9's `wokenAt`/`sortDate`. Nested so the entity
    /// name stays "EmailEntity".
    @Model
    final class EmailEntity {
        #Unique<EmailEntity>([\.folder, \.serverId])

        var serverId: String
        var folder: String
        var senderName: String
        var senderEmail: String
        var subject: String
        var body: String
        var sentTo: String = ""
        var cc: String = ""
        var keywords: [String]
        var receivedAt: Date
        var read: Bool
        var starred: Bool
        var bodyMode: String = ""
        var hasAttachments: Bool = false
        var pgpEncrypted: Bool = false
        var pgpSigned: Bool = false
        var pgpVerified: Bool = false
        var pgpSignerFingerprint: String = ""
        var pgpDecryptError: String = ""
        var inWindow: Bool = true
        var createdAt: Date

        init(
            serverId: String,
            folder: String,
            senderName: String,
            senderEmail: String,
            subject: String,
            body: String,
            keywords: [String],
            receivedAt: Date,
            read: Bool,
            starred: Bool,
            createdAt: Date = Date()
        ) {
            self.serverId = serverId
            self.folder = folder
            self.senderName = senderName
            self.senderEmail = senderEmail
            self.subject = subject
            self.body = body
            self.keywords = keywords
            self.receivedAt = receivedAt
            self.read = read
            self.starred = starred
            self.createdAt = createdAt
        }
    }
}

enum AppSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)

    static var models: [any PersistentModel.Type] {
        // EmailEntity gains wokenAt and sortDate. Rows from before V9 get
        // sortDate's default and are backfilled by EmailDAO.backfillSortDates.
        [
            EmailEntity.self, ContactEntity.self, PushNotificationEntity.self,
            KeywordEntity.self, GroupEntity.self,
        ]
    }
}

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            AppSchemaV1.self, AppSchemaV2.self, AppSchemaV3.self,
            AppSchemaV4.self, AppSchemaV5.self, AppSchemaV6.self,
            AppSchemaV7.self, AppSchemaV8.self, AppSchemaV9.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: AppSchemaV1.self, toVersion: AppSchemaV2.self),
            .lightweight(fromVersion: AppSchemaV2.self, toVersion: AppSchemaV3.self),
            .lightweight(fromVersion: AppSchemaV3.self, toVersion: AppSchemaV4.self),
            .lightweight(fromVersion: AppSchemaV4.self, toVersion: AppSchemaV5.self),
            .lightweight(fromVersion: AppSchemaV5.self, toVersion: AppSchemaV6.self),
            .lightweight(fromVersion: AppSchemaV6.self, toVersion: AppSchemaV7.self),
            .lightweight(fromVersion: AppSchemaV7.self, toVersion: AppSchemaV8.self),
            .lightweight(fromVersion: AppSchemaV8.self, toVersion: AppSchemaV9.self),
        ]
    }
}
