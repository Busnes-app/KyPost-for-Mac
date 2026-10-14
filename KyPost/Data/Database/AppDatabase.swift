//
//  AppDatabase.swift
//  KyPost
//
//  Owns the SwiftData ModelContainer for the local cache (spec §8).
//

import CoreData
import Foundation
import SwiftData

final class AppDatabase: Sendable {
    static let schema = Schema([
        EmailEntity.self,
        ContactEntity.self,
        PushNotificationEntity.self,
        KeywordEntity.self,
        GroupEntity.self,
    ])

    let container: ModelContainer
    /// True for tests and for Hostile Location Protection mode.
    let isInMemory: Bool

    /// - Parameter inMemory: no data is written to disk (tests, Hostile
    ///   Location Protection).
    /// - Parameter url: the store file; the default location when nil. Tests
    ///   pass a scratch file to open a store written at an older version.
    init(inMemory: Bool = false, url: URL? = nil) throws {
        isInMemory = inMemory
        let configuration = if let url, !inMemory {
            ModelConfiguration(schema: Self.schema, url: url)
        } else {
            ModelConfiguration(schema: Self.schema, isStoredInMemoryOnly: inMemory)
        }
        container = try ModelContainer(
            for: Self.schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [configuration]
        )
    }

    /// What to do with a store file that would not open.
    enum OpenFailureDisposition: Equatable {
        /// The store cannot be read by this build at all: an unknown model
        /// version, a migration that failed, or a file that is not a database.
        /// Deleting it is the only way out, and the cache refills from the
        /// server.
        case discard
        /// Anything else — a full disk, a locked or unreadable file, an I/O
        /// error, or a failure we cannot classify. The file is kept and this
        /// session runs in memory; the next launch tries it again.
        case keep
    }

    /// Decides whether a store that failed to open may be deleted.
    ///
    /// Deleting on *any* error used to turn a full disk or a file another
    /// process held locked into a lost address book — and every Apple
    /// Contacts card linked to it went with the next reconcile. SwiftData
    /// reports most open failures as one opaque `loadIssueModelContainer`, so
    /// this asks the file itself: a store already at the current model version
    /// that will not open has a storage problem, not a migration problem.
    static func openFailureDisposition(for error: Error, storeURL: URL = storeURL) -> OpenFailureDisposition {
        let chain = errorChain(error)
        if chain.contains(where: isStorageFault) { return .keep }
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return .keep }

        let metadata: [String: Any]
        do {
            metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                type: .sqlite, at: storeURL
            )
        } catch {
            // Unreadable metadata is only a reason to delete when the file is
            // demonstrably not a database; a permission or I/O error is not.
            return errorChain(error).contains(where: isCorruption) ? .discard : .keep
        }
        guard let stored = metadata[NSStoreModelVersionHashesKey] as? [String: Data],
              let current = currentVersionHashes()
        else { return .keep }
        // At the current version, nothing needed migrating: whatever failed
        // was not the schema.
        return stored == current ? .keep : .discard
    }

    // MARK: - A kept store and leaving the account

    /// Set while a store kept by `openFailureDisposition` (`.keep`) still
    /// holds an account the user has since left. That session ran in memory,
    /// so the account teardown erased only the in-memory copy; the file holds
    /// the old account's mail, bodies and contacts, and must not open again.
    static let pendingEraseKey = "store.pendingErase"

    /// Account teardown on a session running in memory over a kept store:
    /// mark the file first (a crash or a failed delete leaves the mark, and
    /// the next launch erases it before opening), then delete it now — this
    /// process does not have it open.
    @discardableResult
    static func erasePreservedStore(defaults: UserDefaults, at url: URL = storeURL) -> Bool {
        defaults.set(true, forKey: pendingEraseKey)
        do {
            try deleteStoreFiles(at: url)
        } catch {
            return false
        }
        defaults.removeObject(forKey: pendingEraseKey)
        return true
    }

    /// Whether the store at `url` may be opened. With an erase pending it is
    /// deleted first; if that fails the answer is no, and the session runs in
    /// memory rather than show a left account's data.
    static func storeMayOpen(defaults: UserDefaults, at url: URL = storeURL) -> Bool {
        guard defaults.bool(forKey: pendingEraseKey) else { return true }
        return erasePreservedStore(defaults: defaults, at: url)
    }

    /// The model version hashes a store written by this build carries, read
    /// from a scratch store. Nil when even that cannot be built (a full disk).
    private static func currentVersionHashes() -> [String: Data]? {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kypost-schema-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "probe.store")
            // Scoped so the container closes before the metadata read.
            try {
                _ = try AppDatabase(url: url)
            }()
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
            return metadata[NSStoreModelVersionHashesKey] as? [String: Data]
        } catch {
            return nil
        }
    }

    /// The error and everything it wraps.
    private static func errorChain(_ error: Error) -> [NSError] {
        var result: [NSError] = []
        var queue: [NSError] = [error as NSError]
        while let next = queue.popLast(), result.count < 32 {
            result.append(next)
            if let underlying = next.userInfo[NSUnderlyingErrorKey] as? NSError {
                queue.append(underlying)
            }
            if let detailed = next.userInfo[NSDetailedErrorsKey] as? [NSError] {
                queue.append(contentsOf: detailed)
            }
            queue.append(contentsOf: next.underlyingErrors.map { $0 as NSError })
        }
        return result
    }

    /// SQLite result codes (low byte; extended codes keep it).
    private static let sqliteStorageFaults: Set<Int> = [
        3, // SQLITE_PERM
        5, // SQLITE_BUSY
        6, // SQLITE_LOCKED
        7, // SQLITE_NOMEM
        8, // SQLITE_READONLY
        10, // SQLITE_IOERR
        13, // SQLITE_FULL
        14, // SQLITE_CANTOPEN
    ]
    private static let sqliteCorruption: Set<Int> = [
        11, // SQLITE_CORRUPT
        26, // SQLITE_NOTADB
    ]

    private static func sqliteCode(_ error: NSError) -> Int? {
        if error.domain == NSSQLiteErrorDomain { return error.code & 0xFF }
        return (error.userInfo[NSSQLiteErrorDomain] as? Int).map { $0 & 0xFF }
    }

    private static func isStorageFault(_ error: NSError) -> Bool {
        if let code = sqliteCode(error), sqliteStorageFaults.contains(code) { return true }
        switch error.domain {
        case NSPOSIXErrorDomain:
            return [Int(ENOSPC), Int(EDQUOT), Int(EACCES), Int(EPERM), Int(EIO), Int(EROFS), Int(EBUSY)]
                .contains(error.code)
        case NSCocoaErrorDomain:
            return [
                NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError,
                NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError,
                NSFileLockingError,
            ].contains(error.code)
        default:
            return false
        }
    }

    private static func isCorruption(_ error: NSError) -> Bool {
        if let code = sqliteCode(error), sqliteCorruption.contains(code) { return true }
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadCorruptFileError
    }

    /// Where the on-disk store lives (the default ModelConfiguration URL,
    /// under Application Support).
    static var storeURL: URL {
        ModelConfiguration(schema: Self.schema, isStoredInMemoryOnly: false).url
    }

    /// Excludes the store files from iCloud/Finder backups — Apple has no
    /// allowBackup=false equivalent; it's per-file. Best effort: a failure
    /// is logged upstream, never fatal. Re-run after Hostile Location
    /// Protection recreates the file. Keychain items need nothing — the
    /// ThisDeviceOnly class is already excluded by construction.
    static func excludeStoreFromBackup(at url: URL = storeURL) throws {
        for suffix in ["", "-wal", "-shm"] {
            var file = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
        }
    }

    /// Removes the SQLite store plus its -wal/-shm siblings so nothing
    /// pre-toggle survives a Hostile Location Protection switch. Plain
    /// delete, not a secure overwrite (explicitly out of scope in the
    /// design). Missing files are not an error.
    ///
    /// Removes directly and forgives only "not found". Checking `fileExists`
    /// first read a directory that cannot be traversed as "no file", so the
    /// delete reported success over a store still on disk — and an erase
    /// marker cleared on that success let the store reopen later.
    static func deleteStoreFiles(at url: URL = storeURL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            do {
                try FileManager.default.removeItem(at: file)
            } catch let error as NSError where isNotFound(error) {
                continue
            }
        }
    }

    private static func isNotFound(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)
        }
        return false
    }
}
