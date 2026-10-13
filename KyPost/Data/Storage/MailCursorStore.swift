//
//  MailCursorStore.swift
//  KyPost
//
//  Durable per-pairing, per-folder delta-sync cursor for GET /api/inbox.
//  Swift port of kypost-android's mail/MailCursorStore.kt.
//

import CryptoKit
import Foundation

/// Once a day, a folder is refetched as a whole window regardless of its
/// cursor. That is the documented self-heal for a removal notification this
/// device never saw — see `MailFetchResult.isFullWindow`.
private let fullResyncInterval: TimeInterval = 24 * 60 * 60

protocol MailCursorProviding: Sendable {
    /// "" means no cursor yet for this pairing+folder — fetch the whole window.
    func cursor(pairingId: String, folder: String) -> String
    func saveCursor(pairingId: String, folder: String, cursor: String)
    func shouldForceFullResync(pairingId: String, folder: String) -> Bool
    func recordFullResync(pairingId: String, folder: String)
    /// Forgets every cursor and resync stamp.
    func clear()
}

/// Scoped to pairing + folder so re-pairing, or switching mailboxes, cannot
/// apply a stale or foreign cursor. Cursors are opaque server-issued strings;
/// nothing here assumes they are numeric or ordered.
final class MailCursorStore: MailCursorProviding, @unchecked Sendable {
    private let defaults: UserDefaults
    private let hostileLocation: HostileLocationProtectionStore
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    /// Under Hostile Location Protection nothing about the user's mail may
    /// touch disk, and these keys encode which folders exist and when each was
    /// last read. Held in memory instead — a cold process just starts from the
    /// whole window, which is correct, only less efficient.
    private var memoryCursors: [String: String] = [:]
    private var memoryResyncAt: [String: Date] = [:]

    init(
        defaults: UserDefaults,
        hostileLocation: HostileLocationProtectionStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.hostileLocation = hostileLocation
        self.now = now
    }

    private var isInMemory: Bool { hostileLocation.enabled }

    func cursor(pairingId: String, folder: String) -> String {
        let key = memoryKey(pairingId, folder)
        if isInMemory {
            lock.lock(); defer { lock.unlock() }
            return memoryCursors[key] ?? ""
        }
        guard scopeMatches(cursorScopeKey(folder), pairingId) else { return "" }
        return defaults.string(forKey: cursorValueKey(folder)) ?? ""
    }

    func saveCursor(pairingId: String, folder: String, cursor: String) {
        guard !cursor.isEmpty else { return }
        if isInMemory {
            lock.lock(); defer { lock.unlock() }
            memoryCursors[memoryKey(pairingId, folder)] = cursor
            return
        }
        defaults.set(pairingId, forKey: cursorScopeKey(folder))
        defaults.set(cursor, forKey: cursorValueKey(folder))
    }

    func shouldForceFullResync(pairingId: String, folder: String) -> Bool {
        let last: Date?
        if isInMemory {
            lock.lock()
            last = memoryResyncAt[memoryKey(pairingId, folder)]
            lock.unlock()
        } else if scopeMatches(resyncScopeKey(folder), pairingId) {
            // `object(forKey:)`, not `double(forKey:)`: the latter answers 0
            // for a missing key, which is indistinguishable from a real stamp
            // and makes "absent" depend on what the clock happened to read.
            last = (defaults.object(forKey: resyncValueKey(folder)) as? Double)
                .map(Date.init(timeIntervalSince1970:))
        } else {
            last = nil
        }
        guard let last else { return true }
        return now().timeIntervalSince(last) >= fullResyncInterval
    }

    func recordFullResync(pairingId: String, folder: String) {
        if isInMemory {
            lock.lock(); defer { lock.unlock() }
            memoryResyncAt[memoryKey(pairingId, folder)] = now()
            return
        }
        defaults.set(pairingId, forKey: resyncScopeKey(folder))
        defaults.set(now().timeIntervalSince1970, forKey: resyncValueKey(folder))
    }

    /// Forgets everything, for an unpair or a Hostile Location Protection
    /// wipe. A kept cursor after either would be put on the wire to a server
    /// that never issued it.
    func clear() {
        lock.lock()
        memoryCursors.removeAll()
        memoryResyncAt.removeAll()
        lock.unlock()
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Key.cursorScope) || key.hasPrefix(Key.cursorValue)
            || key.hasPrefix(Key.resyncScope) || key.hasPrefix(Key.resyncValue) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Keys

    private enum Key {
        // Deliberately non-prefixing of one another. Android shipped
        // `inbox_cursor_` and `inbox_cursor_sub_`, where a folder literally
        // named `sub_INBOX` produced a key identical to INBOX's scope marker,
        // silently corrupting both folders' cursors.
        static let cursorScope = "mail.cursorScope."
        static let cursorValue = "mail.cursorValue."
        static let resyncScope = "mail.resyncScope."
        static let resyncValue = "mail.resyncStamp."
    }

    /// The resync stamp keeps its **own** scope key, never the cursor's.
    /// Sharing one meant writing the stamp re-stamped the scope over a stale
    /// cursor and re-authorised it for the new pairing — the exact opposite of
    /// what scoping is for. After re-pairing, a relay that answered the first
    /// fetch with a blank cursor then got the *previous* relay's token.
    private func cursorScopeKey(_ folder: String) -> String { Key.cursorScope + folderKey(folder) }
    private func cursorValueKey(_ folder: String) -> String { Key.cursorValue + folderKey(folder) }
    private func resyncScopeKey(_ folder: String) -> String { Key.resyncScope + folderKey(folder) }
    private func resyncValueKey(_ folder: String) -> String { Key.resyncValue + folderKey(folder) }

    private func scopeMatches(_ scopeKey: String, _ pairingId: String) -> Bool {
        defaults.string(forKey: scopeKey) == pairingId
    }

    private func memoryKey(_ pairingId: String, _ folder: String) -> String {
        "\(pairingId)\u{0}\(folder)"
    }

    /// Hashed rather than interpolated, so the key names cannot spell out the
    /// user's folder taxonomy ("Archive/Legal/Asylum-Case") in a plaintext
    /// defaults file, and so an unvalidated server-supplied folder name cannot
    /// collide with another folder's key.
    private func folderKey(_ folder: String) -> String {
        SHA256.hash(data: Data(folder.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
