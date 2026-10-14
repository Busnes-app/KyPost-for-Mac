//
//  SchemaMigrationTests.swift
//  KyPost Tests
//
//  A store written at every historical schema version opens with the current
//  migration plan, contacts intact; and a store that will not open is deleted
//  only when this build can never read it (AppDatabase.openFailureDisposition).
//

import CoreData
import Foundation
import SwiftData
import Testing
@testable import KyPost

@Suite(.serialized) struct SchemaMigrationTests {
    /// A scratch directory per test, removed afterwards by the caller.
    private func scratchStore() throws -> (directory: URL, store: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kypost-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appending(path: "store.sqlite"))
    }

    /// Writes one contact into a fresh store at `version`, then closes it.
    private func writeStore(
        at url: URL,
        version: any VersionedSchema.Type,
        insert: (ModelContext) -> Void
    ) throws {
        let schema = Schema(versionedSchema: version)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url)]
        )
        let context = ModelContext(container)
        insert(context)
        try context.save()
    }

    private static let created = Date(timeIntervalSince1970: 1_700_000_000)

    /// Every version in the plan, each with the ContactEntity shape it had.
    private var versions: [(any VersionedSchema.Type, (ModelContext) -> Void)] {
        let id = UUID()
        let v1: (ModelContext) -> Void = {
            $0.insert(AppSchemaV1.ContactEntity(
                localId: id, uid: "u1", name: "Ada", email: "ada@example.com", phone: "",
                avatarUrl: nil, createdAt: Self.created, updatedAt: Self.created
            ))
        }
        let v2: (ModelContext) -> Void = {
            $0.insert(AppSchemaV2.ContactEntity(
                localId: id, uid: "u1", name: "Ada", createdAt: Self.created, updatedAt: Self.created
            ))
        }
        let v3to5: (ModelContext) -> Void = {
            $0.insert(AppSchemaV5.ContactEntity(
                localId: id, uid: "u1", name: "Ada", createdAt: Self.created, updatedAt: Self.created
            ))
        }
        let live: (ModelContext) -> Void = {
            $0.insert(ContactEntity(
                localId: id, uid: "u1", name: "Ada", createdAt: Self.created, updatedAt: Self.created
            ))
        }
        return [
            (AppSchemaV1.self, v1), (AppSchemaV2.self, v2), (AppSchemaV3.self, v3to5),
            (AppSchemaV4.self, v3to5), (AppSchemaV5.self, v3to5), (AppSchemaV6.self, live),
            (AppSchemaV7.self, live), (AppSchemaV8.self, live), (AppSchemaV9.self, live),
        ]
    }

    @Test func everyVersionInThePlanIsCovered() {
        #expect(versions.count == AppMigrationPlan.schemas.count)
        let covered = versions.map { "\($0.0.versionIdentifier)" }
        let planned = AppMigrationPlan.schemas.map { "\($0.versionIdentifier)" }
        #expect(covered == planned)
    }

    /// The bug this guards: V3 listed the live ContactEntity (which gained
    /// `isSelf` at V6), so a V3 store matched no version, failed with
    /// "unknown model version", and was deleted at launch — taking every
    /// unsynced contact and, at the next reconcile, the Apple Contacts cards
    /// linked to the rest.
    @Test(arguments: 0..<9)
    func aStoreFromEachVersionOpensWithItsContact(index: Int) throws {
        let (version, insert) = versions[index]
        let (directory, url) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeStore(at: url, version: version, insert: insert)

        let database = try AppDatabase(url: url)
        let contacts = try ModelContext(database.container).fetch(FetchDescriptor<ContactEntity>())
        #expect(contacts.count == 1, "V\(version.versionIdentifier) store lost its contact")
        #expect(contacts.first?.uid == "u1")
        #expect(contacts.first?.name == "Ada")
    }

    // MARK: - Open failures

    @Test func aStoreOfAnUnknownModelVersionIsDiscarded() throws {
        let (directory, url) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A model no version in the plan describes.
        let schema = Schema([UnknownShape.self])
        _ = try {
            let container = try ModelContainer(
                for: schema, configurations: [ModelConfiguration(schema: schema, url: url)]
            )
            let context = ModelContext(container)
            context.insert(UnknownShape(value: "x"))
            try context.save()
        }()

        let error = try #require(throws: (any Error).self) { try AppDatabase(url: url) }
        #expect(AppDatabase.openFailureDisposition(for: error, storeURL: url) == .discard)
    }

    @Test func aFileThatIsNotADatabaseIsDiscarded() throws {
        let (directory, url) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0x41, count: 8192).write(to: url)

        let error = try #require(throws: (any Error).self) { try AppDatabase(url: url) }
        #expect(AppDatabase.openFailureDisposition(for: error, storeURL: url) == .discard)
    }

    /// A store already at the current version that fails to open has a
    /// storage problem, not a migration problem: keep it.
    @Test func aCurrentVersionStoreIsKeptWhateverTheError() throws {
        let (directory, url) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try { _ = try AppDatabase(url: url) }()

        let opaque = NSError(domain: "SwiftData.SwiftDataError", code: 1)
        #expect(AppDatabase.openFailureDisposition(for: opaque, storeURL: url) == .keep)
    }

    @Test func aFullDiskOrLockedFileIsKeptEvenForAnOldStore() throws {
        let (directory, url) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeStore(at: url, version: AppSchemaV8.self) { _ in }

        for fault in [
            NSError(domain: NSSQLiteErrorDomain, code: 13), // SQLITE_FULL
            NSError(domain: NSSQLiteErrorDomain, code: 5), // SQLITE_BUSY
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
        ] {
            let wrapped = NSError(
                domain: NSCocoaErrorDomain, code: 134_060,
                userInfo: [NSUnderlyingErrorKey: fault]
            )
            #expect(AppDatabase.openFailureDisposition(for: wrapped, storeURL: url) == .keep)
        }
    }

    @Test func aStoreThatCannotBeReadForPermissionIsKept() throws {
        let (directory, url) = try scratchStore()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try writeStore(at: url, version: AppSchemaV8.self) { _ in }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let opaque = NSError(domain: "SwiftData.SwiftDataError", code: 1)
        #expect(AppDatabase.openFailureDisposition(for: opaque, storeURL: url) == .keep)
    }

    // MARK: - A kept store and leaving the account

    private func storeWithMail(at url: URL) throws {
        _ = try {
            let database = try AppDatabase(url: url)
            let context = ModelContext(database.container)
            context.insert(EmailEntity(from: Email(
                serverId: "a-1", folder: "INBOX", senderName: "A", senderEmail: "a@x",
                subject: "Account A's mail", body: "A's body", keywords: [],
                receivedAt: Self.created, read: false, starred: false
            )))
            try context.save()
        }()
    }

    /// Account A's store was kept while the session ran in memory; replacing
    /// A with B cleared only the in-memory copy. Reopening the file must not
    /// show A's mail to B.
    @MainActor
    @Test func leavingTheAccountErasesAKeptStoreBeforeItReopens() async throws {
        let (directory, url) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        try storeWithMail(at: url)

        let complete = await AccountTeardown(
            erasePreservedStore: { AppDatabase.erasePreservedStore(defaults: defaults, at: url) }
        ).run()

        #expect(complete)
        #expect(AppDatabase.storeMayOpen(defaults: defaults, at: url))
        let reopened = try AppDatabase(url: url)
        #expect(try ModelContext(reopened.container).fetch(FetchDescriptor<EmailEntity>()).isEmpty)
    }

    /// The file could not be deleted at teardown (a read-only directory): it
    /// stays shut until it can be, then is erased before it opens.
    @MainActor
    @Test func aKeptStoreThatCannotBeErasedYetStaysShut() async throws {
        let (directory, url) = try scratchStore()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        try storeWithMail(at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        await AccountTeardown(
            erasePreservedStore: { AppDatabase.erasePreservedStore(defaults: defaults, at: url) }
        ).run()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!AppDatabase.storeMayOpen(defaults: defaults, at: url))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(AppDatabase.storeMayOpen(defaults: defaults, at: url))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(AppDatabase.storeMayOpen(defaults: defaults, at: url), "the mark is cleared once erased")
    }

    @Test func noFileMeansNothingToDiscard() throws {
        let (directory, url) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let opaque = NSError(domain: "SwiftData.SwiftDataError", code: 1)
        #expect(AppDatabase.openFailureDisposition(for: opaque, storeURL: url) == .keep)
    }
}

@Model
final class UnknownShape {
    var value: String

    init(value: String) {
        self.value = value
    }
}
