//
//  ContactPhotoCache.swift
//  KyPost
//
//  Disk cache for contact photo bytes, keyed by the server's photoRef.
//  photoRef filenames are content-hashed server-side, so an entry is
//  immutable — nothing is ever invalidated, new refs just add new files
//  (Client_Contact_Update.md Part 3).
//

import Foundation

final class ContactPhotoCache: Sendable {
    private let directory: URL
    /// Hostile Location Protection: photographs of the user's contacts are
    /// exactly the kind of thing that mode promises isn't on the device, so
    /// with it on nothing is written and reads always miss. Previously this
    /// cache had no idea the mode existed and kept writing faces to disk
    /// *after* the erase.
    private let inMemory: Bool

    /// - Parameters:
    ///   - directory: override for tests; defaults to
    ///     Application Support/ContactPhotos.
    ///   - inMemory: when true, nothing touches disk.
    init(directory: URL? = nil, inMemory: Bool = false) {
        self.directory = directory ?? Self.defaultDirectory
        self.inMemory = inMemory
    }

    static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ContactPhotos", directoryHint: .isDirectory)
    }

    func data(for photoRef: String) -> Data? {
        guard !inMemory, let url = fileURL(for: photoRef) else { return nil }
        return try? Data(contentsOf: url)
    }

    func hasData(for photoRef: String) -> Bool {
        guard !inMemory, let url = fileURL(for: photoRef) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func store(_ data: Data, for photoRef: String) {
        guard !inMemory, let url = fileURL(for: photoRef) else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        // The mail store and the attachment staging area are both excluded
        // from backups; contact photos were not, so they reached iCloud and
        // Time Machine while the rest of the cache deliberately didn't.
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    /// Removes the whole cache directory. Called when Hostile Location
    /// Protection is toggled (either direction) and at launch while it is on,
    /// so an interrupted toggle can't leave faces behind.
    static func deleteAll(directory: URL? = nil) throws {
        let target = directory ?? defaultDirectory
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }

    /// Removes every cached photo (removing this device's contacts).
    func removeAll() {
        try? Self.deleteAll(directory: directory)
    }

    /// photoRef is a server-generated "<sha256>.<ext>" filename, but never
    /// trust it as a path: anything that isn't a plain filename is rejected.
    private func fileURL(for photoRef: String) -> URL? {
        guard !photoRef.isEmpty,
              !photoRef.contains("/"),
              !photoRef.contains("..")
        else { return nil }
        return directory.appending(path: photoRef, directoryHint: .notDirectory)
    }
}
