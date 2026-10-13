//
//  KyPostTests.swift
//  KyPost Tests
//
//  Phase 1 tests: storage stores, Keychain round-trip, SwiftData DAO CRUD.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Helpers

/// Scratch UserDefaults that never touches the real domain.
private func scratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: "test.\(UUID().uuidString)")!
}

/// Keychain in a unique test service so runs never collide or pollute the app's items.
private func scratchKeychain() -> KeychainStorage {
    KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
}

private func makeEmail(
    serverId: String,
    folder: String = "INBOX",
    subject: String = "Subject",
    keywords: Set<String> = [],
    receivedAt: Date = Date(),
    read: Bool = false
) -> Email {
    Email(
        serverId: serverId,
        folder: folder,
        senderName: "Sender",
        senderEmail: "sender@example.com",
        subject: subject,
        body: "Body of \(subject)",
        keywords: keywords,
        receivedAt: receivedAt,
        read: read,
        starred: false
    )
}

// MARK: - KeywordSettingsStore

@Suite struct KeywordSettingsStoreTests {
    @Test func keywordsVisibleByDefault() {
        let store = KeywordSettingsStore(defaults: scratchDefaults())
        #expect(store.isVisible("Important"))
    }

    @Test func visibilityToggleRoundTrip() {
        let store = KeywordSettingsStore(defaults: scratchDefaults())
        store.setVisible(false, for: "Work")
        #expect(!store.isVisible("Work"))
        #expect(store.isVisible("Important"))
        store.setVisible(true, for: "Work")
        #expect(store.isVisible("Work"))
    }

    @Test func keywordOrderRoundTrips() {
        let store = KeywordSettingsStore(defaults: scratchDefaults())
        #expect(store.order().isEmpty)
        store.setOrder(["Work", "Important"])
        #expect(store.order() == ["Work", "Important"])
    }
}

// MARK: - NotificationCursorStore

@Suite struct NotificationCursorStoreTests {
    @Test func cursorOnlyAdvancesForward() {
        let store = NotificationCursorStore(defaults: scratchDefaults())
        #expect(store.lastCursor == 0)
        store.advance(to: 5)
        #expect(store.lastCursor == 5)
        store.advance(to: 3) // behind current position: ignored
        #expect(store.lastCursor == 5)
        store.advance(to: 9)
        #expect(store.lastCursor == 9)
    }
}

// MARK: - Keychain & SecurePairingStore

@Suite struct KeychainTests {
    @Test func keychainRoundTrip() throws {
        let keychain = scratchKeychain()
        let key = "roundTripKey"
        defer { try? keychain.remove(key) }

        #expect(try keychain.string(forKey: key) == nil)
        try keychain.set("secret-value", forKey: key)
        #expect(try keychain.string(forKey: key) == "secret-value")
        try keychain.set("updated-value", forKey: key) // update path
        #expect(try keychain.string(forKey: key) == "updated-value")
        try keychain.remove(key)
        #expect(try keychain.string(forKey: key) == nil)
        try keychain.remove(key) // removing a missing key is not an error
    }

    @Test func pairingStoreRoundTrip() throws {
        let store = SecurePairingStore(keychain: scratchKeychain())
        defer { try? store.clear() }

        #expect(try store.loadPairing() == nil)
        #expect(!store.isPaired)

        let pairing = Pairing(
            sub: "user-sub",
            deviceSecret: "auth-hash",
            srv: "https://relay.example.com",
            registrationUrl: nil,
            pairingToken: "pt-token",
            lastDeviceId: "device-1",
            pairedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try store.savePairing(pairing)
        let loaded = try #require(try store.loadPairing())
        #expect(loaded == pairing)
        #expect(store.isPaired)

        try store.clear()
        #expect(try store.loadPairing() == nil)
    }
}

// MARK: - EmailDAO

@Suite struct EmailDAOTests {
    @Test func folderSnapshotReplaceAndPaging() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = EmailDAO(modelContainer: db.container)

        let now = Date()
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [
            makeEmail(serverId: "1", subject: "Oldest", receivedAt: now.addingTimeInterval(-200)),
            makeEmail(serverId: "2", subject: "Middle", receivedAt: now.addingTimeInterval(-100)),
            makeEmail(serverId: "3", subject: "Newest", receivedAt: now),
        ])

        let page = try await dao.getFolder(folder: "INBOX", limit: 2)
        #expect(page.map(\.serverId) == ["3", "2"]) // newest first
        let rest = try await dao.getFolder(folder: "INBOX", limit: 2, offset: 2)
        #expect(rest.map(\.serverId) == ["1"])

        // A fresh snapshot replaces stale rows inside its date range, for that
        // folder only.
        try await dao.replaceFolderSnapshot(folder: "Archive", emails: [
            makeEmail(serverId: "a1", folder: "Archive"),
        ])
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [
            makeEmail(serverId: "3", subject: "Newest", receivedAt: now.addingTimeInterval(-300)),
        ])
        #expect(try await dao.getFolder(folder: "INBOX", limit: 10).count == 1)
        #expect(try await dao.getFolder(folder: "Archive", limit: 10).count == 1)
    }

    @Test func updateAndFetchEmail() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = EmailDAO(modelContainer: db.container)
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [makeEmail(serverId: "42")])

        try await dao.updateEmail(folder: "INBOX", serverId: "42", read: true, starred: true)
        let email = try #require(try await dao.getEmail(folder: "INBOX", serverId: "42"))
        #expect(email.read)
        #expect(email.starred)
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "missing") == nil)
    }

    @Test func keywordsSurviveRoundTrip() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = EmailDAO(modelContainer: db.container)
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [
            makeEmail(serverId: "1", keywords: ["Important", "Work"]),
        ])
        let email = try #require(try await dao.getEmail(folder: "INBOX", serverId: "1"))
        #expect(email.keywords == ["Important", "Work"])
    }
}

// MARK: - ContactDAO

@Suite struct ContactDAOTests {
    @Test func upsertInsertsThenUpdates() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: db.container)

        var contact = Contact(
            uid: nil,
            name: "Ada Lovelace",
            emails: [ContactLabeledValue(label: nil, value: "ada@example.com")],
            avatarUrl: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try await dao.upsert(contacts: [contact])
        #expect(try await dao.listAll().count == 1)

        // Reconciliation assigns a server uid to the same local contact.
        contact.uid = "srv-1"
        contact.name = "Ada L."
        try await dao.upsert(contacts: [contact])

        let all = try await dao.listAll()
        #expect(all.count == 1)
        #expect(all.first?.uid == "srv-1")
        #expect(all.first?.name == "Ada L.")
        #expect(try await dao.getContact(uid: "srv-1") != nil)
    }

    @Test func deleteByUid() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: db.container)
        let contact = Contact(
            uid: "srv-9",
            name: "Grace Hopper",
            emails: [ContactLabeledValue(label: nil, value: "grace@example.com")],
            avatarUrl: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        try await dao.upsert(contacts: [contact])
        try await dao.delete(uid: "srv-9")
        #expect(try await dao.listAll().isEmpty)
    }
}

// MARK: - PushNotificationDAO

@Suite struct PushNotificationDAOTests {
    @Test func insertDeduplicatesBySeq() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = PushNotificationDAO(modelContainer: db.container)

        let notification = PushNotification(
            seq: 1,
            messageId: "m-1",
            senderName: "Sender",
            emailSubject: "Hello",
            keywords: ["Important"],
            receivedAt: Date(),
            read: false
        )
        try await dao.insert(notification: notification)
        try await dao.insert(notification: notification) // duplicate seq: skipped
        var sameMessage = notification
        sameMessage.seq = 99
        // Same message, new seq (push then pull): one entry, not two.
        #expect(try await !dao.insert(notification: sameMessage))
        var second = notification
        second.seq = 2
        second.messageId = "m-2"
        try await dao.insert(notification: second)

        let history = try await dao.listHistory(limit: 10)
        #expect(history.map(\.seq) == [2, 1]) // newest first

        try await dao.markRead(seq: 1)
        let updated = try await dao.listHistory(limit: 10)
        #expect(updated.first { $0.seq == 1 }?.read == true)
    }
}
