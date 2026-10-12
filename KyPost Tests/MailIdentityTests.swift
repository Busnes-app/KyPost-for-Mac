//
//  MailIdentityTests.swift
//  KyPost Tests
//
//  Cached mail is keyed by (folder, messageId). The relay's id is a bare IMAP
//  UID on IMAP accounts, unique only within one mailbox, so INBOX and Sent can
//  both hold `42` — and caching one must never overwrite, move, mark, or
//  delete the other.
//

import Foundation
import SwiftData
import Testing
@testable import KyPost

private func row(_ id: String, folder: String, subject: String, body: String = "body") -> Email {
    Email(
        serverId: id, folder: folder, senderName: "A", senderEmail: "a@x",
        subject: subject, body: body, keywords: [],
        receivedAt: Date(timeIntervalSince1970: 1_000), read: false, starred: false
    )
}

@Suite struct MailIdentityTests {
    private func dao() throws -> EmailDAO {
        EmailDAO(modelContainer: try AppDatabase(inMemory: true).container)
    }

    /// The bug: `serverId` alone was unique, so caching Sent's 42 replaced
    /// (and refiled) the Inbox's 42.
    @Test func theSameUidInTwoFoldersIsTwoRows() async throws {
        let dao = try dao()
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [row("42", folder: "INBOX", subject: "In")])
        try await dao.replaceFolderSnapshot(folder: "Sent", emails: [row("42", folder: "Sent", subject: "Out")])

        #expect(try await dao.getEmail(folder: "INBOX", serverId: "42")?.subject == "In")
        #expect(try await dao.getEmail(folder: "Sent", serverId: "42")?.subject == "Out")
        #expect(try await dao.getFolder(folder: "INBOX", limit: 10).map(\.subject) == ["In"])
        #expect(try await dao.getFolder(folder: "Sent", limit: 10).map(\.subject) == ["Out"])
    }

    @Test func aDeltaMergesIntoItsOwnFolderOnly() async throws {
        let dao = try dao()
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [row("42", folder: "INBOX", subject: "In", body: "inbox body")])

        // A new Sent row with the same id is an insert, not a merge into INBOX.
        try await dao.applyDelta(
            folder: "Sent", emails: [row("42", folder: "Sent", subject: "Out", body: "sent body")],
            updatedIds: [], removedIds: [], pruneAgainstEmails: false
        )
        // An "updated" Sent entry with no Sent row is skipped, even though
        // INBOX holds the id.
        var updated = row("7", folder: "Sent", subject: "Edited", body: "")
        updated.bodyOmitted = true
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [
            row("42", folder: "INBOX", subject: "In", body: "inbox body"),
            row("7", folder: "INBOX", subject: "Seven", body: "seven"),
        ])
        try await dao.applyDelta(
            folder: "Sent", emails: [updated], updatedIds: ["7"], removedIds: [], pruneAgainstEmails: false
        )

        #expect(try await dao.getEmail(folder: "INBOX", serverId: "42")?.body == "inbox body")
        #expect(try await dao.getEmail(folder: "Sent", serverId: "42")?.body == "sent body")
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "7")?.subject == "Seven")
        #expect(try await dao.getEmail(folder: "Sent", serverId: "7") == nil)
    }

    @Test func aRemovalNamesAMessageOnlyInItsOwnFolder() async throws {
        let dao = try dao()
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [row("42", folder: "INBOX", subject: "In")])
        try await dao.replaceFolderSnapshot(folder: "Sent", emails: [row("42", folder: "Sent", subject: "Out")])

        try await dao.applyDelta(
            folder: "Sent", emails: [], updatedIds: [], removedIds: ["42"], pruneAgainstEmails: false
        )

        #expect(try await dao.getEmail(folder: "Sent", serverId: "42") == nil)
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "42") != nil)
    }

    @Test func markingReadHitsTheRowInTheFolderItWasReadIn() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = EmailDAO(modelContainer: db.container)
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [row("42", folder: "INBOX", subject: "In")])
        try await dao.replaceFolderSnapshot(folder: "Sent", emails: [row("42", folder: "Sent", subject: "Out")])
        let body = Box("")
        let repository = MailRepository(
            securePairingStore: try makePairedStore(),
            emailDAO: dao,
            httpClient: stubClient(json: #"{"ok":true,"processed":1}"#) { request in
                body.value = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            }
        )

        try await repository.markRead(serverId: "42", folder: "Sent")

        #expect(try await dao.getEmail(folder: "Sent", serverId: "42")?.read == true)
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "42")?.read == false)
        #expect(body.value.contains(#""mailbox":"Sent""#))
    }

    @Test func aConfirmedActionDropsOnlyTheRowInTheActedFolder() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = EmailDAO(modelContainer: db.container)
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [row("42", folder: "INBOX", subject: "In")])
        try await dao.replaceFolderSnapshot(folder: "Sent", emails: [row("42", folder: "Sent", subject: "Out")])
        let repository = MailRepository(
            securePairingStore: try makePairedStore(),
            emailDAO: dao,
            httpClient: stubClient(json: #"{"ok":true,"processed":1,"failed":[]}"#)
        )

        let result = await repository.applyAction(.delete, messageIds: ["42"], from: "Sent")

        #expect(result.confirmedIds == ["42"])
        #expect(try await dao.getEmail(folder: "Sent", serverId: "42") == nil)
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "42") != nil)
    }

    @Test func rowsInDifferentFoldersHaveDifferentIdentities() {
        let inbox = row("42", folder: "INBOX", subject: "In")
        let sent = row("42", folder: "Sent", subject: "Out")
        #expect(inbox.id != sent.id)
        #expect(inbox.id == MailRowKey(folder: "INBOX", serverId: "42"))
        // An attachment preview of one must not overwrite the other's.
        #expect(
            InboxViewModel.attachmentCacheComponent(for: inbox)
                != InboxViewModel.attachmentCacheComponent(for: sent)
        )
        #expect(InboxViewModel.attachmentCacheComponent(for: row("../x", folder: "INBOX", subject: "")) == nil)
    }

    /// A push names an Inbox message by id alone; the same id in the folder
    /// that happened to be on screen is a different message.
    @Test @MainActor func aPushTapOpensTheInboxRowNotASameIdRowElsewhere() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["42"], "Sent": ["42"]]
        let db = try AppDatabase(inMemory: true)
        let viewModel = InboxViewModel(
            mailRepository: MailRepository(
                securePairingStore: try makePairedStore(),
                emailDAO: EmailDAO(modelContainer: db.container),
                httpClient: relay.client
            ),
            keywordRepository: KeywordRepository(
                settingsStore: KeywordSettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
            )
        )
        await viewModel.selectFolder("Sent")
        #expect(viewModel.email(for: MailRowKey(folder: "Sent", serverId: "42")) != nil)

        let target = await viewModel.prepareForPushTap(messageId: "42")

        #expect(target?.folder == "INBOX")
    }

    /// A folder with no cached row cannot use a cursor: a delta lists only
    /// what changed, and the folder would stay empty until the daily resync.
    /// This is what lets the store be discarded (or re-keyed) safely.
    @Test func anEmptyFolderIgnoresItsCursorAndFetchesTheWholeWindow() async throws {
        let db = try AppDatabase(inMemory: true)
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let cursors = MailCursorStore(
            defaults: defaults,
            hostileLocation: HostileLocationProtectionStore(defaults: defaults)
        )
        cursors.saveCursor(pairingId: "u1", folder: "INBOX", cursor: "99")
        cursors.recordFullResync(pairingId: "u1", folder: "INBOX")
        let sent = Box<[String]>([])
        let repository = MailRepository(
            securePairingStore: try makePairedStore(),
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: stubClient(json: #"{"byTab":{"":[{"messageId":"1","body":"b"}]},"cursor":"100","delta":false}"#) { request in
                let since = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "since" }?.value ?? ""
                sent.mutate { $0.append(since) }
            },
            cursorStore: cursors
        )

        try await repository.refreshFolder("INBOX")
        try await repository.refreshFolder("INBOX")

        #expect(sent.value == ["0", "100"])
    }

    /// A store written before V7 (unique on the id alone) opens through the
    /// migration plan with its rows intact, and then accepts the same id in a
    /// second folder.
    @Test func aV6StoreMigratesAndThenHoldsTheSameUidTwice() async throws {
        let url = URL.temporaryDirectory.appending(path: "identity-migration-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        do {
            let v6 = Schema(versionedSchema: AppSchemaV6.self)
            let container = try ModelContainer(for: v6, configurations: [ModelConfiguration(schema: v6, url: url)])
            let context = ModelContext(container)
            context.insert(AppSchemaV6.EmailEntity(
                serverId: "42", folder: "INBOX", senderName: "A", senderEmail: "a@x",
                subject: "In", body: "kept", keywords: [], receivedAt: Date(), read: false, starred: false
            ))
            try context.save()
        }

        let container = try ModelContainer(
            for: AppDatabase.schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [ModelConfiguration(schema: AppDatabase.schema, url: url)]
        )
        let dao = EmailDAO(modelContainer: container)
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "42")?.body == "kept")

        try await dao.replaceFolderSnapshot(folder: "Sent", emails: [row("42", folder: "Sent", subject: "Out")])

        #expect(try await dao.getEmail(folder: "INBOX", serverId: "42")?.subject == "In")
        #expect(try await dao.getEmail(folder: "Sent", serverId: "42")?.subject == "Out")
    }
}
