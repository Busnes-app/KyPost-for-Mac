//
//  EmailEntity.swift
//  KyPost
//
//  SwiftData entity for the emails table (spec §8).
//

import Foundation
import SwiftData

@Model
final class EmailEntity {
    /// Unique per (folder, id), not per id: the relay's id is an IMAP UID,
    /// unique only within one mailbox (see `MailRowKey`). Keyed on the id
    /// alone, caching Sent overwrote the Inbox row with the same UID. Changed
    /// in AppSchemaV7.
    #Unique<EmailEntity>([\.folder, \.serverId])

    /// Relay message id — meaningful only together with `folder`.
    var serverId: String
    var folder: String
    var senderName: String
    var senderEmail: String
    var subject: String
    var body: String
    /// Raw To/Cc header strings (see Email.sentTo/cc); default "" keeps
    /// stores created before these columns migrating cleanly.
    var sentTo: String = ""
    var cc: String = ""
    var keywords: [String]
    var receivedAt: Date
    var read: Bool
    var starred: Bool
    /// Relay `bodyMode`/`hasAttachments`; added in AppSchemaV4.
    var bodyMode: String = ""
    var hasAttachments: Bool = false
    /// Relay OpenPGP state; added in AppSchemaV3. Any further column here
    /// needs a new versioned schema + stage in AppSchemaVersions.swift —
    /// defaults alone are not enough under a staged migration plan.
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
        bodyMode: String = "",
        hasAttachments: Bool = false,
        pgpEncrypted: Bool = false,
        pgpSigned: Bool = false,
        pgpVerified: Bool = false,
        pgpSignerFingerprint: String = "",
        pgpDecryptError: String = "",
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
        self.bodyMode = bodyMode
        self.hasAttachments = hasAttachments
        self.pgpEncrypted = pgpEncrypted
        self.pgpSigned = pgpSigned
        self.pgpVerified = pgpVerified
        self.pgpSignerFingerprint = pgpSignerFingerprint
        self.pgpDecryptError = pgpDecryptError
        self.createdAt = createdAt
    }
}

// MARK: - Mapping (EmailMapper equivalent)

extension EmailEntity {
    convenience init(from email: Email) {
        self.init(
            serverId: email.serverId,
            folder: email.folder,
            senderName: email.senderName,
            senderEmail: email.senderEmail,
            subject: email.subject,
            body: email.body,
            sentTo: email.sentTo,
            cc: email.cc,
            keywords: email.keywords.sorted(),
            receivedAt: email.receivedAt,
            read: email.read,
            starred: email.starred,
            bodyMode: email.bodyMode,
            hasAttachments: email.hasAttachments,
            pgpEncrypted: email.pgpEncrypted,
            pgpSigned: email.pgpSigned,
            pgpVerified: email.pgpVerified,
            pgpSignerFingerprint: email.pgpSignerFingerprint,
            pgpDecryptError: email.pgpDecryptError
        )
    }

    var toDomain: Email {
        Email(
            serverId: serverId,
            folder: folder,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject,
            body: body,
            sentTo: sentTo,
            cc: cc,
            keywords: Set(keywords),
            receivedAt: receivedAt,
            read: read,
            starred: starred,
            bodyMode: bodyMode,
            hasAttachments: hasAttachments,
            pgpEncrypted: pgpEncrypted,
            pgpSigned: pgpSigned,
            pgpVerified: pgpVerified,
            pgpSignerFingerprint: pgpSignerFingerprint,
            pgpDecryptError: pgpDecryptError
        )
    }
}
