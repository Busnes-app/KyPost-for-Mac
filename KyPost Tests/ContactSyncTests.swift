//
//  ContactSyncTests.swift
//  KyPost Tests
//
//  Phase 4 tests: reconciliation matching, cursor/tombstone stores, the
//  full sync flow through a stub transport, and contactPayload field parity
//  (Client_Contact_Update.md).
//

import Foundation
import SwiftData
import Testing
@testable import KyPost

// MARK: - Helpers


private func makeContact(
    uid: String? = nil,
    name: String,
    email: String = "",
    needsSync: Bool = false
) -> Contact {
    var contact = Contact(
        uid: uid,
        name: name,
        avatarUrl: nil,
        createdAt: Date(),
        updatedAt: Date(),
        needsSync: needsSync
    )
    if !email.isEmpty {
        contact.emails = [ContactLabeledValue(label: nil, value: email)]
    }
    // A queued row stands for one made in KyPost (`saveContact` marks it).
    if needsSync { contact.importConsent = Contact.createdInKyPost }
    return contact
}

// MARK: - Reconciliation

private func makeDTO(
    uid: String? = nil,
    fn: String,
    email: String,
    deleted: Bool? = nil
) -> ContactDTO {
    ContactDTO(
        uid: uid,
        rev: 1,
        deleted: deleted,
        fn: fn,
        emails: [ContactFieldDTO(label: nil, value: email)],
        phones: []
    )
}

@Suite struct ContactSyncReconciliationTests {
    @Test func matchesByContentRegardlessOfOrder() {
        let local = [
            makeContact(name: "Ada", email: "ada@example.com"),
            makeContact(name: "Grace", email: "grace@example.com"),
        ]
        let response = [
            makeDTO(uid: "srv-g", fn: "Grace", email: "grace@example.com"),
            makeDTO(uid: "srv-a", fn: "Ada", email: "ada@example.com"),
        ]
        let assignments = ContactSyncReconciliation.reconcile(
            localPending: local,
            responseChanged: response
        )
        #expect(assignments.count == 2)
        #expect(assignments.first { $0.localId == local[0].localId }?.uid == "srv-a")
        #expect(assignments.first { $0.localId == local[1].localId }?.uid == "srv-g")
    }

    @Test func unmatchedContentIsNeverPairedByOrder() {
        // A push response carries every change since baseCursor, including
        // other devices' edits. The old positional fallback paired those with
        // leftover local creates, stamping a foreign uid onto them — the
        // iOS/macOS local-duplication bug. Unmatched creates stay pending.
        let local = [
            makeContact(name: "", email: ""), // fn-less import the server dropped
            makeContact(name: "ada lovelace", email: "ada@example.com"), // name differs
        ]
        let response = [
            makeDTO(uid: "srv-1", fn: "Zoe Kim", email: "zoe@example.com"),
            makeDTO(uid: "srv-2", fn: "Ada Lovelace", email: "ada@example.com"),
        ]
        let assignments = ContactSyncReconciliation.reconcile(
            localPending: local,
            responseChanged: response
        )
        #expect(assignments.isEmpty)
    }

    @Test func matchesFullContentNotJustNameAndFirstEmail() {
        var local = makeContact(name: "Ada", email: "ada@example.com")
        local.org = "Analytical Engines Ltd"
        local.phones = [ContactLabeledValue(label: nil, value: "555")]

        var wrongOrg = makeDTO(uid: "srv-wrong", fn: "Ada", email: "ada@example.com")
        wrongOrg.phones = [ContactFieldDTO(label: nil, value: "555")]
        var exact = makeDTO(uid: "srv-right", fn: "Ada", email: "ada@example.com")
        exact.org = "Analytical Engines Ltd"
        exact.phones = [ContactFieldDTO(label: nil, value: "555")]

        let assignments = ContactSyncReconciliation.reconcile(
            localPending: [local],
            responseChanged: [wrongOrg, exact]
        )
        #expect(assignments == [
            ContactSyncReconciliation.Assignment(localId: local.localId, uid: "srv-right")
        ])
    }

    @Test func ignoresDeletedAndUidlessCandidatesAndLeavesExtrasPending() {
        let local = [
            makeContact(name: "Ada", email: "ada@example.com"),
            makeContact(name: "Grace", email: "grace@example.com"),
        ]
        let response = [
            makeDTO(uid: "srv-x", fn: "Someone", email: "x@example.com", deleted: true),
            makeDTO(fn: "No uid", email: "nouid@example.com"),
            makeDTO(uid: "srv-a", fn: "Ada", email: "ada@example.com"),
        ]
        let assignments = ContactSyncReconciliation.reconcile(
            localPending: local,
            responseChanged: response
        )
        // Only Ada matches; Grace stays pending for the next sync.
        #expect(assignments == [
            ContactSyncReconciliation.Assignment(localId: local[0].localId, uid: "srv-a")
        ])
    }

    @Test func alreadySyncedContactsAreNotReassigned() {
        let local = [makeContact(uid: "srv-existing", name: "Ada", email: "ada@example.com")]
        let response = [makeDTO(uid: "srv-new", fn: "Ada", email: "ada@example.com")]
        let assignments = ContactSyncReconciliation.reconcile(
            localPending: local,
            responseChanged: response
        )
        #expect(assignments.isEmpty)
    }
}

// MARK: - Stores

@Suite struct ContactStoresTests {
    @Test func cursorOnlyAdvancesForward() {
        let store = ContactCursorStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        #expect(store.lastCursor == 0)
        store.advance(to: 7)
        store.advance(to: 4)
        #expect(store.lastCursor == 7)
    }

    @Test func pendingDeletesDeduplicateAndClear() {
        let store = ContactPendingDeletesStore(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        )
        store.add("srv-1")
        store.add("srv-1")
        store.add("srv-2")
        #expect(store.all() == ["srv-1", "srv-2"])
        store.clear()
        #expect(store.all().isEmpty)
    }
}

// MARK: - DAO write-ordering guard (race with an in-flight sync)

@Suite struct ContactDAOStaleSyncWriteTests {
    @Test func staleServerWriteDoesNotClobberANewerLocalCorrection() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: db.container)
        let localId = UUID()

        let original = Contact(
            localId: localId, uid: "srv-1", name: "Bob",
            pgpKey: "attacker-key",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            needsSync: false
        )
        try await dao.upsert(contacts: [original])

        // User notices the bad key and re-attaches the correct one — a local
        // edit landing after the stale sync response was fetched.
        var corrected = original
        corrected.pgpKey = "verified-key"
        corrected.needsSync = true
        corrected.updatedAt = Date(timeIntervalSince1970: 2_000)
        try await dao.upsert(contacts: [corrected])

        // The in-flight sync's response (fetched before the correction) now
        // applies, carrying the old key with needsSync: false and an
        // updatedAt older than the correction.
        var staleFromSync = original
        staleFromSync.updatedAt = Date(timeIntervalSince1970: 1_500)
        try await dao.upsert(contacts: [staleFromSync])

        let stored = try #require(try await dao.getContact(uid: "srv-1"))
        #expect(stored.pgpKey == "verified-key")
        #expect(stored.needsSync == true)
    }

    @Test func ordinaryServerSyncStillOverwritesWhenNoPendingLocalEditExists() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: db.container)
        let localId = UUID()

        let original = Contact(
            localId: localId, uid: "srv-1", name: "Bob", pgpKey: "old-key",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            needsSync: false
        )
        try await dao.upsert(contacts: [original])

        var fromServer = original
        fromServer.pgpKey = "new-key"
        fromServer.updatedAt = Date(timeIntervalSince1970: 2_000)
        try await dao.upsert(contacts: [fromServer])

        let stored = try #require(try await dao.getContact(uid: "srv-1"))
        #expect(stored.pgpKey == "new-key")
    }
}

@Suite struct ContactDAORepairImportedDuplicatesTests {
    private func contact(
        uid: String?,
        name: String,
        emails: [String],
        needsSync: Bool,
        createdAt: TimeInterval
    ) -> Contact {
        var contact = Contact(
            localId: UUID(), uid: uid, name: name,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: createdAt),
            needsSync: needsSync
        )
        contact.emails = emails.map { ContactLabeledValue(label: nil, value: $0) }
        return contact
    }

    /// The rows the match-key asymmetry left behind: the synced original
    /// leads with one address, the imported duplicate leads with the other,
    /// so grouping on primary email alone never put them side by side.
    @Test func mergesRowsSharingANonPrimaryEmail() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: db.container)
        try await dao.upsert(contacts: [
            contact(
                uid: "srv-1", name: "Grace Hopper",
                emails: ["grace@home.example", "grace@work.example"],
                needsSync: false, createdAt: 1_000
            ),
            contact(
                uid: nil, name: "Grace Hopper",
                emails: ["grace@work.example"],
                needsSync: true, createdAt: 2_000
            ),
        ])

        let removed = try await dao.repairImportedDuplicates()
        #expect(removed == 1)
        let remaining = try await dao.listAll()
        #expect(remaining.count == 1)
        #expect(remaining.first?.uid == "srv-1")
    }

    /// Two people who genuinely share nothing must not be merged just
    /// because the pass now looks at more than one key.
    @Test func leavesDistinctPeopleAlone() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: db.container)
        try await dao.upsert(contacts: [
            contact(
                uid: "srv-1", name: "Grace Hopper",
                emails: ["grace@example.com"], needsSync: false, createdAt: 1_000
            ),
            contact(
                uid: nil, name: "Ada Lovelace",
                emails: ["ada@example.com"], needsSync: true, createdAt: 2_000
            ),
        ])

        let removed = try await dao.repairImportedDuplicates()
        #expect(removed == 0)
        #expect(try await dao.listAll().count == 2)
    }

    /// Only uid-less pending rows are ever removed — a row the server knows
    /// about is never deleted by a local cleanup pass.
    @Test func neverRemovesASyncedRow() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: db.container)
        try await dao.upsert(contacts: [
            contact(
                uid: "srv-1", name: "Grace Hopper",
                emails: ["grace@home.example"], needsSync: false, createdAt: 1_000
            ),
            contact(
                uid: "srv-2", name: "Grace Hopper",
                emails: ["grace@home.example"], needsSync: false, createdAt: 2_000
            ),
        ])

        let removed = try await dao.repairImportedDuplicates()
        #expect(removed == 0)
        #expect(try await dao.listAll().count == 2)
    }
}

// MARK: - Repository

@Suite struct ContactSyncRepositoryTests {
    private struct Environment {
        var repository: ContactSyncRepository
        var dao: ContactDAO
        var database: AppDatabase
        var cursorStore: ContactCursorStore
        var pendingDeletes: ContactPendingDeletesStore
    }

    private func makeEnvironment(client: HTTPClient, paired: Bool = true) throws -> Environment {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let pairingStore = try makePairedStore(paired: paired)
        let db = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: db.container)
        let cursorStore = ContactCursorStore(defaults: defaults)
        let pendingDeletes = ContactPendingDeletesStore(defaults: defaults)
        let repository = ContactSyncRepository(
            client: ContactSyncClient(httpClient: client),
            contactDAO: dao,
            cursorStore: cursorStore,
            pendingDeletesStore: pendingDeletes,
            securePairingStore: pairingStore
        )
        return Environment(
            repository: repository,
            dao: dao,
            database: db,
            cursorStore: cursorStore,
            pendingDeletes: pendingDeletes
        )
    }

    @Test func syncWithoutPairingThrows() async throws {
        let env = try makeEnvironment(client: stubClient(), paired: false)
        await #expect(throws: ContactSyncError.notPaired) {
            try await env.repository.sync()
        }
    }

    @Test func saveContactMarksPending() async throws {
        let env = try makeEnvironment(client: stubClient())
        try await env.repository.saveContact(makeContact(name: "Ada", email: "ada@example.com"))
        let pending = try await env.dao.listPendingSync()
        #expect(pending.count == 1)
        #expect(pending.first?.needsSync == true)
    }

    @Test func concurrentSyncsPushPendingContactOnlyOnce() async throws {
        let log = Box<[String]>([])
        // The echo lets the first sync reconcile the create; a response
        // without it would leave the create pending (retried by design).
        let json = """
        {
          "cursor": 1,
          "changed": [
            { "uid": "srv-ada", "rev": 1, "fn": "Ada", "emails": [{ "value": "ada@example.com" }] }
          ]
        }
        """
        let env = try makeEnvironment(client: stubClient(json: json) { request in
            log.mutate { $0.append(request.httpMethod ?? "") }
        })
        try await env.repository.saveContact(makeContact(name: "Ada", email: "ada@example.com"))

        async let first = env.repository.sync()
        async let second = env.repository.sync()
        _ = try await [first, second]

        // Serialized: the first sync pushes the pending create; the second
        // runs after it and has nothing queued, so it pulls. Overlapping
        // syncs would push the same contact twice (server-side duplicate).
        #expect(log.value == ["POST", "GET"])
    }

    // MARK: - 500-change paging

    /// The relay answers 413 above 500 changes in one request. This bit
    /// hardest on the very first sync of an existing address book, which is
    /// the worst possible moment for contact sync to start failing.
    @Test func aPushOverTheRelayLimitIsSplitIntoPages() async throws {
        let pageSizes = Box<[Int]>([])
        let env = try makeEnvironment(client: stubClient(json: #"{"cursor": 1}"#) { request in
            guard request.httpMethod == "POST", let body = request.httpBody else { return }
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            pageSizes.mutate { $0.append((json?["changes"] as? [Any])?.count ?? -1) }
        })

        for index in 0..<501 {
            try await env.repository.saveContact(
                makeContact(name: "C\(index)", email: "c\(index)@example.com")
            )
        }
        _ = try await env.repository.sync()

        #expect(pageSizes.value == [500, 1])
    }

    /// Exactly the limit is one request, not two — an off-by-one here would
    /// send an empty second page on every 500-change sync.
    @Test func aPushExactlyAtTheLimitIsASingleRequest() async throws {
        let posts = Box<Int>(0)
        let env = try makeEnvironment(client: stubClient(json: #"{"cursor": 1}"#) { request in
            if request.httpMethod == "POST" { posts.mutate { $0 += 1 } }
        })

        for index in 0..<500 {
            try await env.repository.saveContact(
                makeContact(name: "C\(index)", email: "c\(index)@example.com")
            )
        }
        _ = try await env.repository.sync()

        #expect(posts.value == 1)
    }

    /// Every page carries the SAME baseCursor. The server computes each delta
    /// from the cursor the request carries, so holding it still is what makes
    /// the final response a superset of the earlier ones.
    @Test func everyPageSendsTheSameBaseCursor() async throws {
        let cursors = Box<[Int]>([])
        let env = try makeEnvironment(client: stubClient(json: #"{"cursor": 9}"#) { request in
            guard request.httpMethod == "POST", let body = request.httpBody else { return }
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            cursors.mutate { $0.append((json?["baseCursor"] as? Int) ?? -1) }
        })
        env.cursorStore.advance(to: 4)

        for index in 0..<501 {
            try await env.repository.saveContact(
                makeContact(name: "C\(index)", email: "c\(index)@example.com")
            )
        }
        _ = try await env.repository.sync()

        #expect(cursors.value == [4, 4])
    }

    @Test func fullSyncAssignsUidWithoutDuplicating() async throws {
        let json = """
        {
          "cursor": 456,
          "changed": [
            {
              "uid": "srv-ada",
              "rev": 1,
              "fn": "Ada",
              "emails": [{ "value": "ada@example.com" }]
            }
          ],
          "deleted": []
        }
        """
        let client = stubClient(json: json) { request in
            #expect(
                request.url!.absoluteString == "https://relay.example.com/api/contacts/sync"
            )
            // Queued local changes go out as a push (POST {baseCursor, changes});
            // creates carry an empty uid (Android contract).
            #expect(request.httpMethod == "POST")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""baseCursor":0"#))
            #expect(body.contains(#""fn":"Ada""#))
            #expect(body.contains(#""uid":"""#))
        }
        let env = try makeEnvironment(client: client)
        try await env.repository.saveContact(makeContact(name: "Ada", email: "ada@example.com"))

        let summary = try await env.repository.sync()
        #expect(summary.pushed == 1)
        #expect(summary.applied == 1)
        #expect(summary.newCursor == 456)

        let all = try await env.dao.listAll()
        #expect(all.count == 1) // reconciled in place, not duplicated
        #expect(all.first?.uid == "srv-ada")
        #expect(all.first?.needsSync == false)
        #expect(try await env.dao.listPendingSync().isEmpty)
        #expect(env.cursorStore.lastCursor == 456)
    }

    @Test func createWithConcurrentServerChangesGetsItsOwnUid() async throws {
        // Another device's edit rides along in the push response (it changed
        // after our baseCursor). The old order-based fallback stamped its uid
        // onto the local create, duplicating the contact locally.
        let json = """
        {
          "cursor": 20,
          "changed": [
            { "uid": "srv-zoe", "rev": 9, "fn": "Zoe", "emails": [{ "value": "zoe@example.com" }] },
            { "uid": "srv-ada", "rev": 1, "fn": "Ada", "emails": [{ "value": "ada@example.com" }] }
          ]
        }
        """
        let env = try makeEnvironment(client: stubClient(json: json))
        try await env.repository.saveContact(makeContact(name: "Ada", email: "ada@example.com"))

        try await env.repository.sync()
        let all = try await env.dao.listAll()
        #expect(all.count == 2)
        #expect(all.first { $0.name == "Ada" }?.uid == "srv-ada")
        #expect(all.first { $0.name == "Zoe" }?.uid == "srv-zoe")
    }

    @Test func namelessContactIsNeverPushed() async throws {
        // The server silently drops creates without an fn, so pushing one
        // strands it (no echo to reconcile). It stays local and pending
        // until it gets a name; with nothing else queued the sync is a pull.
        let json = #"{"cursor": 4, "changed": [{"uid": "srv-x", "rev": 1, "fn": "Someone Else"}]}"#
        let env = try makeEnvironment(client: stubClient(json: json) { request in
            #expect(request.httpMethod == "GET")
        })
        try await env.repository.saveContact(makeContact(name: "", email: "acme@corp.example"))

        try await env.repository.sync()
        let all = try await env.dao.listAll()
        #expect(all.count == 2)
        let stranded = try #require(all.first { $0.uid == nil })
        #expect(stranded.needsSync == true)
        #expect(all.contains { $0.uid == "srv-x" })
    }

    @Test func unmatchedCreateStaysPendingForRetry() async throws {
        // No echo in the response: the create keeps needsSync so a later
        // sync can still reconcile it, instead of being stranded uid-less.
        let env = try makeEnvironment(client: stubClient(json: #"{"cursor": 5}"#))
        try await env.repository.saveContact(makeContact(name: "Ada", email: "ada@example.com"))

        try await env.repository.sync()
        let pending = try await env.dao.listPendingSync()
        #expect(pending.count == 1)
        #expect(pending.first?.uid == nil)
    }

    @Test func assignUidRefusesUidAlreadyOnAnotherRow() async throws {
        let env = try makeEnvironment(client: stubClient())
        let existing = makeContact(uid: "srv-1", name: "Ada")
        let create = makeContact(name: "Junk", needsSync: true)
        try await env.dao.upsert(contacts: [existing, create])

        try await env.dao.assignUid(localId: create.localId, uid: "srv-1")
        let rows = try await env.dao.listAll()
        #expect(rows.filter { $0.uid == "srv-1" }.count == 1)
        // The refused create stays pending instead of shadowing srv-1.
        #expect(try await env.dao.listPendingSync().count == 1)
    }

    @Test func repairDropsDuplicateUidRowsAndRevivesNamelessImports() async throws {
        let env = try makeEnvironment(client: stubClient())
        let context = ModelContext(env.database.container)
        // Two rows stamped with the same uid by the old order-based reconciler.
        let original = ContactEntity(
            localId: UUID(), uid: "srv-1", name: "Ada",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(), needsSync: false
        )
        let duplicate = ContactEntity(
            localId: UUID(), uid: "srv-1", name: "Ada",
            createdAt: Date(timeIntervalSince1970: 2_000),
            updatedAt: Date(), needsSync: false
        )
        // A company-card import the server silently dropped, then stranded.
        let stranded = ContactEntity(
            localId: UUID(), uid: nil, name: "",
            createdAt: Date(), updatedAt: Date(), needsSync: false
        )
        stranded.org = "Acme Corp"
        context.insert(original)
        context.insert(duplicate)
        context.insert(stranded)
        try context.save()
        let originalLocalId = original.localId

        try await env.dao.repairReconciliationArtifacts()

        let rows = try await env.dao.listAll()
        #expect(rows.filter { $0.uid == "srv-1" }.count == 1)
        #expect(rows.first { $0.uid == "srv-1" }?.localId == originalLocalId)
        let revived = try #require(rows.first { $0.uid == nil })
        #expect(revived.name == "Acme Corp")
        #expect(revived.needsSync == true)
    }

    @Test func serverDeleteRemovesLocalContactViaPull() async throws {
        let json = #"{"cursor": 2, "changed": [], "deleted": [{"uid": "srv-1", "deleted": true}]}"#
        let env = try makeEnvironment(client: stubClient(json: json) { request in
            // Nothing queued locally, so the sync is a pull (GET ...&since=).
            #expect(request.httpMethod == "GET")
            #expect(request.url!.absoluteString.contains("since=0"))
        })
        try await env.dao.upsert(contacts: [makeContact(uid: "srv-1", name: "Old")])

        try await env.repository.sync()
        #expect(try await env.dao.listAll().isEmpty)
    }

    @Test func localDeleteOfSyncedContactSendsTombstone() async throws {
        let client = stubClient(json: #"{"cursor": 3, "changed": [], "deleted": []}"#) { request in
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""uid":"srv-9""#))
            #expect(body.contains(#""deleted":true"#))
        }
        let env = try makeEnvironment(client: client)
        let contact = makeContact(uid: "srv-9", name: "Grace")
        try await env.dao.upsert(contacts: [contact])

        try await env.repository.deleteContact(contact)
        #expect(try await env.dao.listAll().isEmpty)
        #expect(env.pendingDeletes.all() == ["srv-9"])

        try await env.repository.sync()
        #expect(env.pendingDeletes.all().isEmpty) // tombstone cleared after push
    }

    /// Council pass 2: a create deleted while its push was on the wire came
    /// back from the push's own answer, and the server kept it.
    @Test func aCreateDeletedDuringItsPushIsDeletedOnTheServerToo() async throws {
        let gate = ParkedPush()
        let json = """
        {
          "cursor": 1,
          "changed": [
            { "uid": "srv-ada", "rev": 1, "fn": "Ada", "emails": [{ "value": "ada@example.com" }] }
          ]
        }
        """
        let client = HTTPClient { request in
            if request.httpMethod == "POST" { await gate.hold() }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
        let env = try makeEnvironment(client: client)
        try await env.repository.saveContact(makeContact(name: "Ada", email: "ada@example.com"))
        let created = try #require(try await env.dao.listAll().first)

        let sync = Task { try await env.repository.sync() }
        await gate.waitUntilHolding()
        try await env.repository.deleteContact(created)
        await gate.open()
        _ = try await sync.value

        #expect(try await env.dao.listAll().isEmpty)
        #expect(env.pendingDeletes.all() == ["srv-ada"])
    }

    /// Sol certification: the same, when the push's answer is lost. The
    /// next sync's reconcile still finds the uid and sends the delete.
    @Test func aCreateDeletedDuringAPushWhoseAnswerIsLostIsDeletedOnTheServerToo() async throws {
        let gate = ParkedPush()
        let posts = Box<[String]>([])
        let ada = #"{ "uid": "srv-ada", "rev": 1, "fn": "Ada", "emails": [{ "value": "ada@example.com" }] }"#
        let client = HTTPClient { request in
            var status = 200
            var json = #"{"cursor": 1, "changed": [\#(ada)]}"#
            if request.httpMethod == "POST" {
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                let first = posts.value.isEmpty
                posts.mutate { $0.append(body) }
                if first {
                    await gate.hold()
                    status = 502 // committed, but the answer never arrives
                } else {
                    json = #"{"cursor": 2}"#
                }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
        let env = try makeEnvironment(client: client)
        try await env.repository.saveContact(makeContact(name: "Ada", email: "ada@example.com"))
        let created = try #require(try await env.dao.listAll().first)

        let sync = Task { try await env.repository.sync() }
        await gate.waitUntilHolding()
        try await env.repository.deleteContact(created)
        await gate.open()
        _ = try? await sync.value

        try await env.repository.sync()

        #expect(try await env.dao.listAll().isEmpty)
        let resend = try #require(posts.value.last)
        #expect(posts.value.count == 2)
        #expect(resend.contains(#""uid":"srv-ada""#))
        #expect(resend.contains(#""deleted":true"#))
    }

    /// Opus certification: a deleted create the reconcile does not find is
    /// dropped after that one reconcile; it never holds the flag open for a
    /// later, unrelated contact to match.
    @Test func anUnmatchedDeletedCreateIsForgottenAfterOneReconcile() async throws {
        let env = try makeEnvironment(client: stubClient(json: #"{"cursor": 1, "changed": []}"#))
        env.cursorStore.createsInFlight = true
        env.cursorStore.deletedCreates = [makeContact(name: "Alex", email: "alex@example.com")]

        try await env.repository.sync()

        #expect(env.cursorStore.deletedCreates.isEmpty)
        #expect(!env.cursorStore.createsInFlight)
        #expect(env.pendingDeletes.all().isEmpty)
    }

    @Test func unsyncedLocalDeleteLeavesNoTombstone() async throws {
        let env = try makeEnvironment(client: stubClient(json: #"{"cursor": 1}"#))
        let contact = makeContact(name: "Draft Person", needsSync: true)
        try await env.dao.upsert(contacts: [contact])

        try await env.repository.deleteContact(contact)
        #expect(try await env.dao.listAll().isEmpty)
        #expect(env.pendingDeletes.all().isEmpty)
    }

    @Test func serverEditReplacesContactWholesale() async throws {
        let json = """
        {
          "cursor": 9,
          "changed": [
            { "uid": "srv-1", "rev": 4, "fn": "Ada L.", "phones": [{ "value": "555" }] }
          ]
        }
        """
        let env = try makeEnvironment(client: stubClient(json: json))
        try await env.dao.upsert(contacts: [
            makeContact(uid: "srv-1", name: "Ada", email: "ada@example.com"),
        ])

        try await env.repository.sync()
        let all = try await env.dao.listAll()
        #expect(all.count == 1)
        #expect(all.first?.name == "Ada L.")
        #expect(all.first?.primaryPhone == "555")
        #expect(all.first?.rev == 4)
        // Server `changed` entries are complete contacts: a field absent from
        // the payload is empty server-side, so it clears locally too (keeping
        // it would resurrect fields deleted on another device).
        #expect(all.first?.emails.isEmpty == true)
    }

    @Test func tooOldResetsCursorAndCache() async throws {
        let env = try makeEnvironment(client: stubClient(json: #"{"cursor": 0, "tooOld": true}"#))
        env.cursorStore.advance(to: 99)
        try await env.dao.upsert(contacts: [makeContact(uid: "srv-1", name: "Stale")])

        let summary = try await env.repository.sync()
        #expect(summary.newCursor == 0)
        #expect(env.cursorStore.lastCursor == 0)
        #expect(try await env.dao.listAll().isEmpty)
    }

    // MARK: - Field parity (Client_Contact_Update.md)

    @Test func pullDecodesEveryPayloadField() async throws {
        let json = """
        {
          "cursor": 5,
          "changed": [
            {
              "uid": "srv-full",
              "rev": 3,
              "fn": "Ada Lovelace",
              "givenName": "Ada",
              "familyName": "Lovelace",
              "middleName": "M.",
              "prefix": "Dr.",
              "suffix": "PhD",
              "nickname": "Addie",
              "org": "Analytical Engines Ltd",
              "title": "Chief Mathematician",
              "emails": [
                { "label": "home", "value": "ada@example.com" },
                { "label": "work", "value": "ada@engines.example" }
              ],
              "phones": [{ "label": "mobile", "value": "+44 555 0100" }],
              "addresses": [{
                "label": "home", "street": "1 Byron Row", "city": "London",
                "region": "LDN", "postalCode": "E1 1AA", "country": "UK"
              }],
              "notes": "Met at the salon.",
              "birthday": "1815-12-10",
              "photoRef": "abc123.jpg",
              "groupIDs": ["g-1", "g-2"],
              "pgpKey": "-----BEGIN PGP PUBLIC KEY BLOCK-----\\nxyz\\n-----END PGP PUBLIC KEY BLOCK-----",
              "ims": [{ "service": "signal", "value": "+445550100" }],
              "websites": [{ "label": "homepage", "value": "https://ada.example" }],
              "relations": [{ "label": "spouse", "name": "William King" }],
              "events": [{ "label": "anniversary", "date": "1835-07-08" }],
              "phoneticGivenName": "AY-duh",
              "phoneticFamilyName": "LUV-lace",
              "department": "Research",
              "customFields": [{ "label": "Callsign", "value": "Enchantress" }],
              "pronouns": "she/her",
              "mergedUIDs": ["ignored-1"],
              "mergedInto": "ignored-2"
            }
          ]
        }
        """
        let env = try makeEnvironment(client: stubClient(json: json))
        try await env.repository.sync()

        let contact = try #require(try await env.dao.getContact(uid: "srv-full"))
        #expect(contact.name == "Ada Lovelace")
        #expect(contact.givenName == "Ada")
        #expect(contact.familyName == "Lovelace")
        #expect(contact.middleName == "M.")
        #expect(contact.prefix == "Dr.")
        #expect(contact.suffix == "PhD")
        #expect(contact.nickname == "Addie")
        #expect(contact.org == "Analytical Engines Ltd")
        #expect(contact.title == "Chief Mathematician")
        #expect(contact.emails == [
            ContactLabeledValue(label: "home", value: "ada@example.com"),
            ContactLabeledValue(label: "work", value: "ada@engines.example"),
        ])
        #expect(contact.phones == [ContactLabeledValue(label: "mobile", value: "+44 555 0100")])
        #expect(contact.addresses == [ContactPostalAddress(
            label: "home", street: "1 Byron Row", city: "London",
            region: "LDN", postalCode: "E1 1AA", country: "UK"
        )])
        #expect(contact.notes == "Met at the salon.")
        #expect(contact.birthday == "1815-12-10")
        #expect(contact.photoRef == "abc123.jpg")
        #expect(contact.groupIDs == ["g-1", "g-2"])
        #expect(contact.pgpKey?.contains("BEGIN PGP PUBLIC KEY BLOCK") == true)
        #expect(contact.ims == [ContactIM(service: "signal", label: nil, value: "+445550100")])
        #expect(contact.websites == [
            ContactLabeledValue(label: "homepage", value: "https://ada.example")
        ])
        #expect(contact.relations == [ContactRelation(label: "spouse", name: "William King")])
        #expect(contact.events == [ContactEvent(label: "anniversary", date: "1835-07-08")])
        #expect(contact.phoneticGivenName == "AY-duh")
        #expect(contact.phoneticFamilyName == "LUV-lace")
        #expect(contact.department == "Research")
        #expect(contact.customFields == [ContactCustomField(label: "Callsign", value: "Enchantress")])
        #expect(contact.pronouns == "she/her")
    }

    @Test func pushBodyCarriesEveryPayloadField() async throws {
        let capture = Box<String>("")
        let env = try makeEnvironment(client: stubClient(json: #"{"cursor": 1}"#) { request in
            capture.value = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
        })

        var contact = makeContact(name: "Ada Lovelace", email: "ada@example.com")
        contact.givenName = "Ada"
        contact.familyName = "Lovelace"
        contact.middleName = "M."
        contact.prefix = "Dr."
        contact.suffix = "PhD"
        contact.nickname = "Addie"
        contact.org = "Analytical Engines Ltd"
        contact.title = "Chief Mathematician"
        contact.phones = [ContactLabeledValue(label: "mobile", value: "+44 555 0100")]
        contact.addresses = [ContactPostalAddress(label: "home", street: "1 Byron Row")]
        contact.notes = "Met at the salon."
        contact.birthday = "1815-12-10"
        contact.photoRef = "abc123.jpg"
        contact.groupIDs = ["g-1"]
        contact.pgpKey = "-----BEGIN PGP PUBLIC KEY BLOCK-----"
        contact.ims = [ContactIM(service: "signal", label: nil, value: "+445550100")]
        contact.websites = [ContactLabeledValue(label: "homepage", value: "https://ada.example")]
        contact.relations = [ContactRelation(label: "spouse", name: "William King")]
        contact.events = [ContactEvent(label: "anniversary", date: "1835-07-08")]
        contact.phoneticGivenName = "AY-duh"
        contact.phoneticFamilyName = "LUV-lace"
        contact.department = "Research"
        contact.customFields = [ContactCustomField(label: "Callsign", value: "Enchantress")]
        contact.pronouns = "she/her"
        try await env.repository.saveContact(contact)
        try await env.repository.sync()

        // The server replaces the whole contact on push, so every payload key
        // must be on the wire or an edit here wipes web-entered data.
        let body = capture.value
        for fragment in [
            #""fn":"Ada Lovelace""#,
            #""givenName":"Ada""#,
            #""familyName":"Lovelace""#,
            #""middleName":"M.""#,
            #""prefix":"Dr.""#,
            #""suffix":"PhD""#,
            #""nickname":"Addie""#,
            #""org":"Analytical Engines Ltd""#,
            #""title":"Chief Mathematician""#,
            #""value":"ada@example.com""#,
            #""label":"mobile""#,
            #""street":"1 Byron Row""#,
            #""notes":"Met at the salon.""#,
            #""birthday":"1815-12-10""#,
            #""photoRef":"abc123.jpg""#,
            #""groupIDs":["g-1"]"#,
            #""pgpKey":"-----BEGIN PGP PUBLIC KEY BLOCK-----""#,
            #""service":"signal""#,
            #""value":"https:\/\/ada.example""#,
            #""name":"William King""#,
            #""date":"1835-07-08""#,
            #""phoneticGivenName":"AY-duh""#,
            #""phoneticFamilyName":"LUV-lace""#,
            #""department":"Research""#,
            #""label":"Callsign""#,
            #""pronouns":"she\/her""#,
        ] {
            #expect(body.contains(fragment), "push body missing \(fragment)")
        }
    }

    @Test func v1StoreMigratesOnDiskAndBackfills() async throws {
        let url = URL.temporaryDirectory
            .appending(path: "migration-test-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: url.path + suffix)
                )
            }
        }

        // Seed a store exactly as the shipped V1 schema wrote it.
        do {
            let v1Schema = Schema(versionedSchema: AppSchemaV1.self)
            let container = try ModelContainer(
                for: v1Schema,
                configurations: [ModelConfiguration(schema: v1Schema, url: url)]
            )
            let context = ModelContext(container)
            context.insert(AppSchemaV1.ContactEntity(
                localId: UUID(), uid: "srv-1", rev: 1, name: "Ada",
                email: "ada@example.com", phone: "555", avatarUrl: nil,
                createdAt: Date(), updatedAt: Date(), needsSync: false
            ))
            try context.save()
        }

        // Reopen through the migration plan (what AppDatabase does at launch).
        let container = try ModelContainer(
            for: AppDatabase.schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [ModelConfiguration(schema: AppDatabase.schema, url: url)]
        )
        let dao = ContactDAO(modelContainer: container)
        try await dao.migrateLegacyFields()

        let contact = try #require(try await dao.getContact(uid: "srv-1"))
        #expect(contact.name == "Ada")
        #expect(contact.emails == [ContactLabeledValue(label: nil, value: "ada@example.com")])
        #expect(contact.phones == [ContactLabeledValue(label: nil, value: "555")])
    }

    @Test func migrateLegacyFieldsBackfillsOnceAndIsIdempotent() async throws {
        let env = try makeEnvironment(client: stubClient())

        // A V1-era row: legacy single-value columns set, arrays empty.
        let context = ModelContext(env.database.container)
        let legacy = ContactEntity(
            localId: UUID(),
            uid: "srv-legacy",
            rev: 1,
            name: "Grace",
            createdAt: Date(),
            updatedAt: Date(),
            needsSync: false
        )
        legacy.legacyEmail = "grace@example.com"
        legacy.legacyPhone = "555"
        context.insert(legacy)
        try context.save()

        try await env.dao.migrateLegacyFields()
        var contact = try #require(try await env.dao.getContact(uid: "srv-legacy"))
        #expect(contact.emails == [ContactLabeledValue(label: nil, value: "grace@example.com")])
        #expect(contact.phones == [ContactLabeledValue(label: nil, value: "555")])

        // Second run must not duplicate the backfilled entries.
        try await env.dao.migrateLegacyFields()
        contact = try #require(try await env.dao.getContact(uid: "srv-legacy"))
        #expect(contact.emails.count == 1)
        #expect(contact.phones.count == 1)
    }

    // MARK: - Dedupe (Mobile_Contacts_DEDupe.md)

    @Test func dedupeWithoutPairingThrows() async throws {
        let env = try makeEnvironment(client: stubClient(), paired: false)
        await #expect(throws: ContactSyncError.notPaired) {
            try await env.repository.dedupe()
        }
    }

    @Test func dedupeSendsEmptyJSONBodyToTheDedupeEndpoint() async throws {
        let client = stubClient(json: #"{"mergedCount": 0, "groups": []}"#) { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://relay.example.com/api/contacts/dedupe")
            // makePairedStore()'s fixture has no lastDeviceId — RelayAuth(pairing:)
            // resolves that to an empty string, still sent as the header value
            // (contacts sync/dedupe never required deviceId, unlike MFA respond).
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "s1")
            // The backend never reads the body, but does expect valid JSON.
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body == "{}")
        }
        let env = try makeEnvironment(client: client)
        let report = try await env.repository.dedupe()
        #expect(report == ContactDedupeReport(mergedCount: 0, groups: []))
    }

    @Test func dedupeDecodesReportWithGroups() async throws {
        let json = """
        {
          "mergedCount": 3,
          "groups": [
            { "survivor": "srv-1", "absorbed": ["srv-2", "srv-3"] },
            { "survivor": "srv-8", "absorbed": ["srv-9"] }
          ]
        }
        """
        let env = try makeEnvironment(client: stubClient(json: json))
        let report = try await env.repository.dedupe()
        #expect(report.mergedCount == 3)
        #expect(report.groups?.count == 2)
        #expect(report.groups?.first == ContactDedupeGroup(
            survivor: "srv-1",
            absorbed: ["srv-2", "srv-3"]
        ))
    }

    @Test func dedupeMapsRejectedCredentialsTo401() async throws {
        let env = try makeEnvironment(client: stubClient(status: 401))
        await #expect(throws: NetworkError.unauthorized) {
            try await env.repository.dedupe()
        }
    }

    @Test func dedupeThenSyncDropsAbsorbedAndKeepsSurvivorsUnionedEmails() async throws {
        // Dedupe POST first, then the caller's follow-up sync (a GET pull,
        // nothing queued): the merge only lands locally via the sync delta.
        let dedupeJSON = #"""
        {"mergedCount": 1, "groups": [{"survivor": "srv-1", "absorbed": ["srv-2"]}]}
        """#
        let syncJSON = """
        {
          "cursor": 12,
          "changed": [
            {
              "uid": "srv-1",
              "rev": 2,
              "fn": "Ada Lovelace",
              "emails": [
                { "label": "work", "value": "ada@example.com" },
                { "label": "home", "value": "ada@home.example.com" }
              ]
            }
          ],
          "deleted": [{ "uid": "srv-2", "deleted": true }]
        }
        """
        let responses = ResponseQueue([dedupeJSON, syncJSON])
        let env = try makeEnvironment(client: HTTPClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(responses.next().utf8), response)
        })
        try await env.dao.upsert(contacts: [
            makeContact(uid: "srv-1", name: "Ada Lovelace", email: "ada@example.com"),
            makeContact(uid: "srv-2", name: "Ada Lovelace", email: "ada@home.example.com"),
        ])

        let report = try await env.repository.dedupe()
        #expect(report.mergedCount == 1)
        try await env.repository.sync()

        let all = try await env.dao.listAll()
        #expect(all.count == 1)
        let survivor = try #require(all.first)
        #expect(survivor.uid == "srv-1")
        // Phase A regression: pre-array clients collapsed a merged contact to
        // one email (the documented Mac data-loss gap). Both survive now.
        #expect(survivor.emails == [
            ContactLabeledValue(label: "work", value: "ada@example.com"),
            ContactLabeledValue(label: "home", value: "ada@home.example.com"),
        ])
    }
}

// MARK: - PGP key change review (fix for silent overwrite of a verified key)

@Suite struct PgpKeyChangeReviewTests {
    private struct Environment {
        var repository: ContactSyncRepository
        var dao: ContactDAO
    }

    private func makeEnvironment(client: HTTPClient) throws -> Environment {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: db.container)
        let repository = ContactSyncRepository(
            client: ContactSyncClient(httpClient: client),
            contactDAO: dao,
            cursorStore: ContactCursorStore(defaults: defaults),
            pendingDeletesStore: ContactPendingDeletesStore(defaults: defaults),
            securePairingStore: pairingStore
        )
        return Environment(repository: repository, dao: dao)
    }

    @Test func serverKeyChangeIsHeldForReviewInsteadOfOverwritingAVerifiedKey() async throws {
        let json = #"""
        {"cursor": 2, "changed": [{"uid": "srv-1", "rev": 2, "fn": "Bob", "pgpKey": "attacker-key"}]}
        """#
        let env = try makeEnvironment(client: stubClient(json: json))
        var seeded = makeContact(uid: "srv-1", name: "Bob")
        seeded.pgpKey = "verified-key"
        try await env.dao.upsert(contacts: [seeded])

        try await env.repository.sync()

        let stored = try #require(try await env.dao.getContact(uid: "srv-1"))
        #expect(stored.pgpKey == "verified-key")
        #expect(stored.pendingPgpKey == "attacker-key")
    }

    @Test func omittingTheKeyDoesNotClearAVerifiedOne() async throws {
        // Step one of the bypass: treating a missing key as "apply
        // immediately" erased the verified key with no banner, so step two had
        // no prior key to compare against and sailed straight in.
        let json = #"""
        {"cursor": 2, "changed": [{"uid": "srv-1", "rev": 2, "fn": "Bob"}]}
        """#
        let env = try makeEnvironment(client: stubClient(json: json))
        var seeded = makeContact(uid: "srv-1", name: "Bob")
        seeded.pgpKey = "verified-key"
        try await env.dao.upsert(contacts: [seeded])

        try await env.repository.sync()

        let stored = try #require(try await env.dao.getContact(uid: "srv-1"))
        #expect(stored.pgpKey == "verified-key")
        #expect(stored.pendingPgpKey == nil)
    }

    @Test func clearThenReplaceInOneResponseStillHoldsTheNewKeyForReview() async throws {
        // The whole bypass in a single sync: each entry is saved before the
        // next is read, so one response could clear and then replace.
        let json = #"""
        {"cursor": 2, "changed": [
          {"uid": "srv-1", "rev": 2, "fn": "Bob"},
          {"uid": "srv-1", "rev": 3, "fn": "Bob", "pgpKey": "attacker-key"}
        ]}
        """#
        let env = try makeEnvironment(client: stubClient(json: json))
        var seeded = makeContact(uid: "srv-1", name: "Bob")
        seeded.pgpKey = "verified-key"
        try await env.dao.upsert(contacts: [seeded])

        try await env.repository.sync()

        let stored = try #require(try await env.dao.getContact(uid: "srv-1"))
        #expect(stored.pgpKey == "verified-key")
        #expect(stored.pendingPgpKey == "attacker-key")
    }

    @Test func aPendingReviewSurvivesTheServerWithdrawingTheKey() async throws {
        let json = #"""
        {"cursor": 3, "changed": [{"uid": "srv-1", "rev": 3, "fn": "Bob"}]}
        """#
        let env = try makeEnvironment(client: stubClient(json: json))
        var seeded = makeContact(uid: "srv-1", name: "Bob")
        seeded.pgpKey = "verified-key"
        seeded.pendingPgpKey = "attacker-key"
        try await env.dao.upsert(contacts: [seeded])

        try await env.repository.sync()

        // Otherwise the same trick clears the banner rather than the key.
        let stored = try #require(try await env.dao.getContact(uid: "srv-1"))
        #expect(stored.pgpKey == "verified-key")
        #expect(stored.pendingPgpKey == "attacker-key")
    }

    @Test func newlyReceivedKeyAppliesImmediatelyWhenNoneExistedBefore() async throws {
        let json = #"""
        {"cursor": 2, "changed": [{"uid": "srv-1", "rev": 2, "fn": "Bob", "pgpKey": "first-key"}]}
        """#
        let env = try makeEnvironment(client: stubClient(json: json))
        try await env.dao.upsert(contacts: [makeContact(uid: "srv-1", name: "Bob")])

        try await env.repository.sync()

        let stored = try #require(try await env.dao.getContact(uid: "srv-1"))
        #expect(stored.pgpKey == "first-key")
        #expect(stored.pendingPgpKey == nil)
    }

    @Test func matchingKeyAppliesWithoutFlaggingForReview() async throws {
        let json = #"""
        {"cursor": 2, "changed": [{"uid": "srv-1", "rev": 2, "fn": "Bob", "pgpKey": "same-key"}]}
        """#
        let env = try makeEnvironment(client: stubClient(json: json))
        var seeded = makeContact(uid: "srv-1", name: "Bob")
        seeded.pgpKey = "same-key"
        try await env.dao.upsert(contacts: [seeded])

        try await env.repository.sync()

        let stored = try #require(try await env.dao.getContact(uid: "srv-1"))
        #expect(stored.pgpKey == "same-key")
        #expect(stored.pendingPgpKey == nil)
    }

    @Test func acceptingAPendingKeyReplacesTheStoredKey() async throws {
        let env = try makeEnvironment(client: stubClient())
        var contact = makeContact(uid: "srv-1", name: "Bob")
        contact.pgpKey = "verified-key"
        contact.pendingPgpKey = "new-key"
        try await env.dao.upsert(contacts: [contact])

        try await env.repository.acceptPendingPgpKey(for: contact)

        let stored = try #require(try await env.dao.getContact(uid: "srv-1"))
        #expect(stored.pgpKey == "new-key")
        #expect(stored.pendingPgpKey == nil)
    }

    @Test func dismissingAPendingKeyKeepsTheExistingKey() async throws {
        let env = try makeEnvironment(client: stubClient())
        var contact = makeContact(uid: "srv-1", name: "Bob")
        contact.pgpKey = "verified-key"
        contact.pendingPgpKey = "attacker-key"
        try await env.dao.upsert(contacts: [contact])

        try await env.repository.dismissPendingPgpKey(for: contact)

        let stored = try #require(try await env.dao.getContact(uid: "srv-1"))
        #expect(stored.pgpKey == "verified-key")
        #expect(stored.pendingPgpKey == nil)
    }
}

/// Hands back queued response bodies in order, repeating the last one — for
/// flows that issue several requests with different responses.
private final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String]

    init(_ bodies: [String]) {
        self.bodies = bodies
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return bodies.count > 1 ? bodies.removeFirst() : bodies[0]
    }
}

// MARK: - Contact groups (Phase 5)

@Suite struct GroupSyncTests {
    private func dao() throws -> GroupDAO {
        GroupDAO(modelContainer: try AppDatabase(inMemory: true).container)
    }

    @Test func decodesTheWrappedListShape() async throws {
        // GET /api/groups responds {"groups": [...]}, not a bare array.
        let client = GroupsSyncClient(httpClient: stubClient(json: """
        {"groups": [
            {"id": "g1", "name": "Family", "rev": 3},
            {"id": "g2", "name": "Work"}
        ]}
        """))
        let groups = try await client.pull(
            serverUrl: "https://relay.test",
            auth: RelayAuth(deviceId: "d", deviceSecret: "s")
        )
        #expect(groups == [
            ContactGroup(id: "g1", name: "Family", rev: 3),
            ContactGroup(id: "g2", name: "Work", rev: 0),
        ])
    }

    @Test func dropsAGroupWithNoId() async throws {
        // It cannot be matched to Contact.groupIDs or stored under a unique
        // key, so inventing one would only create a row nothing can reference.
        let client = GroupsSyncClient(httpClient: stubClient(json: """
        {"groups": [{"name": "Nameless"}, {"id": "", "name": "Blank"}, {"id": "ok", "name": "Fine"}]}
        """))
        let groups = try await client.pull(
            serverUrl: "https://relay.test",
            auth: RelayAuth(deviceId: "d", deviceSecret: "s")
        )
        #expect(groups.map(\.id) == ["ok"])
    }

    /// There is no delta cursor, so every pull is the whole truth: a group
    /// absent from the response no longer exists.
    @Test func aFullRefreshRemovesGroupsTheServerNoLongerSends() async throws {
        let dao = try dao()
        try await dao.replaceAll([
            ContactGroup(id: "g1", name: "Family"),
            ContactGroup(id: "gone", name: "Deleted On The Web"),
        ])
        try await dao.replaceAll([ContactGroup(id: "g1", name: "Family")])
        #expect(try await dao.listAll().map(\.id) == ["g1"])
    }

    @Test func aFullRefreshUpdatesARenamedGroupInPlace() async throws {
        let dao = try dao()
        try await dao.replaceAll([ContactGroup(id: "g1", name: "Old", rev: 1)])
        try await dao.replaceAll([ContactGroup(id: "g1", name: "New", rev: 2)])
        let stored = try await dao.listAll()
        #expect(stored.count == 1)
        #expect(stored.first?.name == "New")
        #expect(stored.first?.rev == 2)
    }

    @Test func resolvesIdsToNamesAndDropsUnknownOnes() async throws {
        // A bare UUID on a contact card is noise, and an unknown id only means
        // the groups cache is behind.
        let dao = try dao()
        try await dao.replaceAll([
            ContactGroup(id: "g1", name: "Family"),
            ContactGroup(id: "g2", name: "Work"),
        ])
        #expect(try await dao.names(forIDs: ["g2", "g1"]) == ["Family", "Work"])
        #expect(try await dao.names(forIDs: ["g1", "not-pulled-yet"]) == ["Family"])
        #expect(try await dao.names(forIDs: []).isEmpty)
    }
}

// MARK: - Self flag and PGP identity badge (Phase 5b/5c)

@Suite struct PgpIdentityBadgeTests {
    private func contact(isSelf: Bool = false, pgpKey: String? = nil) -> Contact {
        var contact = Contact(
            localId: UUID(), uid: "u1", name: "Ada",
            createdAt: Date(), updatedAt: Date()
        )
        contact.isSelf = isSelf
        contact.pgpKey = pgpKey
        return contact
    }

    /// Nil is not false. A failed or not-yet-made check must leave the caller
    /// showing what it already showed, never assert "no key".
    @Test func anUnknownCustodyAnswersUnknown() {
        #expect(pgpIdentityPresent(custody: nil) == nil)
        #expect(pgpIdentityPresent(custody: .noIdentity) == false)
        #expect(pgpIdentityPresent(custody: .serverHeld) == true)
        #expect(pgpIdentityPresent(custody: .clientHeld) == true)
    }

    /// The account's own identity is never in the contacts database.
    /// `Contact.pgpKey` on the self-contact is empty for essentially every
    /// user, so reading it here is why the badge never appeared for the one
    /// contact guaranteed to have a key.
    @Test func theSelfContactsBadgeComesFromTheAccountNotItsPgpKeyColumn() {
        #expect(contactHasLinkedPgpKey(
            contact: contact(isSelf: true), accountIdentityPresent: true
        ) == true)
        #expect(contactHasLinkedPgpKey(
            contact: contact(isSelf: true), accountIdentityPresent: false
        ) == false)
        #expect(contactHasLinkedPgpKey(
            contact: contact(isSelf: true), accountIdentityPresent: nil
        ) == nil)
    }

    /// A user who scanned their own key onto their self-contact should not
    /// see the badge vanish because the server check failed.
    @Test func anAttachedKeyOnTheSelfContactStillCounts() {
        #expect(contactHasLinkedPgpKey(
            contact: contact(isSelf: true, pgpKey: "-----BEGIN PGP PUBLIC KEY BLOCK-----"),
            accountIdentityPresent: nil
        ) == true)
    }

    @Test func anOrdinaryContactIsJudgedOnItsOwnKeyAlone() {
        #expect(contactHasLinkedPgpKey(
            contact: contact(pgpKey: "-----BEGIN PGP PUBLIC KEY BLOCK-----"),
            accountIdentityPresent: false
        ) == true)
        #expect(contactHasLinkedPgpKey(
            contact: contact(), accountIdentityPresent: true
        ) == false)
        // An empty string is not a key.
        #expect(contactHasLinkedPgpKey(
            contact: contact(pgpKey: ""), accountIdentityPresent: nil
        ) == false)
    }
}

@Suite struct ContactSelfFlagWireTests {
    @Test func isSelfArrivesOnSyncButIsNeverPushedBack() throws {
        let json = #"{"uid": "u1", "fn": "Me", "isSelf": true}"#
        let dto = try JSONDecoder().decode(ContactDTO.self, from: Data(json.utf8))
        #expect(dto.isSelf == true)

        // Setting the flag is a web-only action, so a contact this app pushes
        // must not carry a claim to it either way.
        var contact = Contact(localId: UUID(), uid: "u1", name: "Me",
                              createdAt: Date(), updatedAt: Date())
        contact.isSelf = true
        let encoded = String(
            decoding: try JSONEncoder().encode(ContactSyncRepository.wireDTOForTesting(contact)),
            as: UTF8.self
        )
        #expect(!encoded.contains("isSelf"))
    }

    @Test func anOlderServerWithoutTheFieldReadsAsNotSelf() throws {
        let dto = try JSONDecoder().decode(
            ContactDTO.self, from: Data(#"{"uid": "u1", "fn": "Someone"}"#.utf8)
        )
        #expect(dto.isSelf == nil)
    }
}

// MARK: - 5d: is the pending-change queue a real gap?

@Suite struct ContactEditDuringPushTests {
    /// Android queues a snapshot per edit; this app carries a `needsSync` flag
    /// and clears it after a push. The question that decides whether the queue
    /// is needed here is what happens to an edit made *while* a push is in
    /// flight: the flag is cleared against a snapshot taken before the network
    /// call, so an edit that landed in between would be marked synced without
    /// ever having been sent.
    @Test func anEditDuringAnInFlightPushIsNotMarkedSynced() async throws {
        let db = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: db.container)
        let localId = UUID()

        // Queued, and captured into the push's snapshot.
        var contact = Contact(
            localId: localId, uid: "srv-1", name: "Before",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            needsSync: true
        )
        try await dao.upsert(contacts: [contact])
        let snapshot = try await dao.listPendingSync()
        #expect(snapshot.count == 1)

        // The user edits again while the push is on the wire.
        contact.name = "After"
        contact.updatedAt = Date(timeIntervalSince1970: 2_000)
        contact.needsSync = true
        try await dao.upsert(contacts: [contact])

        // The push returns and confirms what it sent.
        try await dao.clearNeedsSync(pushed: snapshot)

        let stored = try #require(try await dao.getContact(uid: "srv-1"))
        #expect(stored.name == "After")
        #expect(stored.needsSync, "the newer edit must stay queued for the next sync")
    }
}

/// Parks the first held request until the test opens it.
private actor ParkedPush {
    private var entered = false
    private var opened = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        guard !entered else { return }
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !opened else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilHolding() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func open() {
        opened = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

// MARK: - Contacts across accounts (owner Q1)

@MainActor
@Suite struct ContactAccountChangeTests {
    private struct Environment {
        var repository: ContactSyncRepository
        var dao: ContactDAO
        var cursorStore: ContactCursorStore
        var pendingDeletes: ContactPendingDeletesStore
        var pairingStore: SecurePairingStore
        var requests: Box<[URLRequest]>
    }

    private func makeEnvironment(json: String = #"{"cursor": 1}"#) throws -> Environment {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: db.container)
        let cursorStore = ContactCursorStore(defaults: defaults)
        let pendingDeletes = ContactPendingDeletesStore(defaults: defaults)
        let requests = Box<[URLRequest]>([])
        let repository = ContactSyncRepository(
            client: ContactSyncClient(httpClient: stubClient(json: json) { request in
                requests.mutate { $0.append(request) }
            }),
            contactDAO: dao,
            cursorStore: cursorStore,
            pendingDeletesStore: pendingDeletes,
            securePairingStore: pairingStore
        )
        return Environment(
            repository: repository, dao: dao, cursorStore: cursorStore,
            pendingDeletes: pendingDeletes, pairingStore: pairingStore, requests: requests
        )
    }

    private func pairAnotherAccount(_ env: Environment, sub: String = "u2") throws {
        try env.pairingStore.savePairing(Pairing(
            sub: sub, deviceSecret: "s2", srv: server, registrationUrl: nil,
            pairingToken: "pt-2", lastDeviceId: nil, pairedAt: Date()
        ))
    }

    /// A's contacts, one synced and one created offline, are held when B is
    /// paired: nothing is sent or pulled until the user answers, and the
    /// cursor (a position in A's history) is gone.
    @Test func anotherAccountAsksBeforeSendingAnything() async throws {
        let env = try makeEnvironment()
        try await env.repository.sync()
        try await env.dao.upsert(contacts: [makeContact(uid: "a-1", name: "Synced")])
        try await env.repository.saveContact(makeContact(name: "Offline", email: "o@example.com"))
        env.cursorStore.advance(to: 7)
        env.pendingDeletes.add("a-2")
        try pairAnotherAccount(env)
        env.requests.value = []

        await #expect(throws: ContactSyncError.awaitingAccountChoice) {
            try await env.repository.sync()
        }

        #expect(env.requests.value.isEmpty, "nothing reaches the new account unasked")
        #expect(env.repository.health.keptFromAnotherAccount == 2)
        #expect(env.cursorStore.lastCursor == 0)
        #expect(env.repository.health.failures.count == 0, "a question, not a failure")
    }

    @Test func reSyncingTheSameAccountAsksNothing() async throws {
        let env = try makeEnvironment()
        try await env.repository.sync()
        try await env.dao.upsert(contacts: [makeContact(uid: "a-1", name: "Synced")])

        try await env.repository.sync()

        #expect(env.repository.health.keptFromAnotherAccount == nil)
    }

    /// Bring them: each goes to B as a new contact, with A's uids and
    /// deletes dropped.
    @Test func bringingThemSendsThemAsNewContacts() async throws {
        let env = try makeEnvironment()
        try await env.repository.sync()
        try await env.dao.upsert(contacts: [makeContact(uid: "a-1", name: "Synced", email: "s@example.com")])
        env.pendingDeletes.add("a-2")
        try pairAnotherAccount(env)
        _ = try? await env.repository.sync()
        env.requests.value = []

        try await env.repository.bringKeptContactsToPairedAccount()
        try await env.repository.sync()

        #expect(env.repository.health.keptFromAnotherAccount == nil)
        let push = try #require(env.requests.value.first { $0.httpMethod == "POST" })
        let body = String(decoding: push.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("Synced"))
        #expect(!body.contains("a-1"), "the other server's uid never reaches this one")
        #expect(!body.contains("a-2"), "nor its deletes")
    }

    /// The answer is the consent: an import stamped for the old server goes
    /// up too; a row of unknown origin still never does.
    @Test func bringingThemSendsImportsButNeverUnknownOrigin() async throws {
        let env = try makeEnvironment()
        try await env.repository.sync()
        var imported = makeContact(name: "Imported", email: "i@example.com", needsSync: true)
        imported.importConsent = "old-relay-stamp"
        var unknown = makeContact(name: "Unknown", email: "u@example.com", needsSync: true)
        unknown.importConsent = Contact.quarantined
        try await env.dao.upsert(contacts: [imported, unknown])
        try pairAnotherAccount(env)
        _ = try? await env.repository.sync()
        env.requests.value = []

        try await env.repository.bringKeptContactsToPairedAccount()
        try await env.repository.sync()

        let push = try #require(env.requests.value.first { $0.httpMethod == "POST" })
        let body = String(decoding: push.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("Imported"))
        #expect(!body.contains("Unknown"))
    }

    /// Remove them: the book is emptied and B's own contacts pull from 0.
    @Test func removingThemEmptiesTheBookForTheNewAccount() async throws {
        let env = try makeEnvironment()
        try await env.repository.sync()
        try await env.dao.upsert(contacts: [makeContact(uid: "a-1", name: "Synced")])
        env.pendingDeletes.add("a-2")
        try pairAnotherAccount(env)
        _ = try? await env.repository.sync()
        env.requests.value = []

        try await env.repository.removeContactsFromThisDevice()
        try await env.repository.sync()

        #expect(try await env.dao.listAll().isEmpty)
        #expect(env.pendingDeletes.all().isEmpty)
        let pull = try #require(env.requests.value.first)
        #expect(pull.httpMethod == "GET")
        #expect(pull.url?.absoluteString.contains("since=0") == true)
    }

    /// An install from before the record existed adopts the paired account
    /// rather than asking about its own contacts.
    @Test func noRecordAdoptsThePairedAccount() async throws {
        let env = try makeEnvironment()
        try await env.dao.upsert(contacts: [makeContact(uid: "a-1", name: "Synced")])

        try await env.repository.sync()

        #expect(env.repository.health.keptFromAnotherAccount == nil)
        #expect(env.cursorStore.account != nil)
    }
}

/// Sol certification: an in-memory cache (the demo, Hostile Location
/// Protection) never deletes the directory it would otherwise use.
@Suite struct ContactPhotoCacheRemovalTests {
    @Test func anInMemoryCacheRemovesNothingOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "photos-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(ContactPhotoCache(directory: directory, inMemory: true).removeAll())
        #expect(FileManager.default.fileExists(atPath: directory.path))

        #expect(ContactPhotoCache(directory: directory).removeAll())
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
