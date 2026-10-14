//
//  ContactSyncDataLossTests.swift
//  KyPost Tests
//
//  The contact sync paths that used to lose or duplicate the user's work: a
//  cursor outliving its rows, tombstones cleared wholesale, an edit made
//  during a push overwritten, `tooOld` discarding unsynced work, a create
//  whose response was lost pushed twice.
//

import Foundation
import SwiftData
import Testing
@testable import KyPost

/// A transport answering each request from `respond`, which may await (to
/// make a local edit land while the request is "on the wire").
private func scripted(
    _ respond: @escaping @Sendable (URLRequest) async throws -> (status: Int, json: String)
) -> HTTPClient {
    HTTPClient { request in
        let (status, json) = try await respond(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(json.utf8), response)
    }
}

private func body(_ request: URLRequest) -> String {
    request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
}

private func contact(
    uid: String? = nil,
    name: String,
    email: String = "",
    needsSync: Bool = false,
    updatedAt: Date = Date(timeIntervalSince1970: 1_000)
) -> Contact {
    var contact = Contact(
        uid: uid, name: name, avatarUrl: nil,
        createdAt: updatedAt, updatedAt: updatedAt, needsSync: needsSync
    )
    if !email.isEmpty { contact.emails = [ContactLabeledValue(label: nil, value: email)] }
    return contact
}

@Suite struct ContactSyncDataLossTests {
    private struct Environment {
        var repository: ContactSyncRepository
        var dao: ContactDAO
        var database: AppDatabase
        var cursorStore: ContactCursorStore
        var pendingDeletes: ContactPendingDeletesStore
    }

    /// `client` is built after the DAO so a script can write through it.
    private func makeEnvironment(_ makeClient: (ContactDAO, ContactPendingDeletesStore) -> HTTPClient) throws -> Environment {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let database = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: database.container)
        let cursorStore = ContactCursorStore(defaults: defaults)
        let pendingDeletes = ContactPendingDeletesStore(defaults: defaults)
        let repository = ContactSyncRepository(
            client: ContactSyncClient(httpClient: makeClient(dao, pendingDeletes)),
            contactDAO: dao,
            cursorStore: cursorStore,
            pendingDeletesStore: pendingDeletes,
            securePairingStore: try makePairedStore()
        )
        return Environment(
            repository: repository, dao: dao, database: database,
            cursorStore: cursorStore, pendingDeletes: pendingDeletes
        )
    }

    // MARK: - Cursor without rows

    /// The store was deleted (or this is an in-memory session) but the cursor
    /// lives in defaults: a delta from it would leave the book empty.
    @Test func aCursorWithNoRowsIsResetAndThePullStartsFromZero() async throws {
        let queries = Box<[String]>([])
        let env = try makeEnvironment { _, _ in
            scripted { request in
                queries.mutate { $0.append(request.url?.query ?? "") }
                return (200, #"{"cursor": 7, "changed": [{"uid": "srv-1", "rev": 1, "fn": "Ada"}]}"#)
            }
        }
        env.cursorStore.advance(to: 99)

        try await env.repository.sync()

        #expect(queries.value == ["since=0"])
        #expect(try await env.dao.listAll().map(\.name) == ["Ada"])
        #expect(env.cursorStore.lastCursor == 7)
    }

    @Test func aCursorOverHeldRowsIsKept() async throws {
        let queries = Box<[String]>([])
        let env = try makeEnvironment { _, _ in
            scripted { request in
                queries.mutate { $0.append(request.url?.query ?? "") }
                return (200, #"{"cursor": 120}"#)
            }
        }
        try await env.dao.upsert(contacts: [contact(uid: "srv-1", name: "Ada")])
        env.cursorStore.advance(to: 99)

        try await env.repository.sync()

        #expect(queries.value == ["since=99"])
    }

    // MARK: - Tombstones

    /// A delete queued while the push was in flight was not in it, and used
    /// to be cleared with the rest — never reaching the server.
    @Test func onlyTheTombstonesASyncSentAreRemoved() async throws {
        let sentBodies = Box<[String]>([])
        let env = try makeEnvironment { _, pending in
            scripted { request in
                sentBodies.mutate { $0.append(body(request)) }
                // The user deletes another contact while this is on the wire.
                pending.add("srv-late")
                return (200, #"{"cursor": 3}"#)
            }
        }
        env.pendingDeletes.add("srv-early")

        try await env.repository.sync()

        #expect(sentBodies.value.first?.contains("srv-early") == true)
        #expect(sentBodies.value.first?.contains("srv-late") == false)
        #expect(env.pendingDeletes.all() == ["srv-late"])
        #expect(env.pendingDeletes.oldestQueuedAt != nil)
    }

    @Test func removingEveryTombstoneClearsTheQueueAge() {
        let store = ContactPendingDeletesStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        store.add("a")
        store.add("b")
        store.remove(["a", "b"])
        #expect(store.all().isEmpty)
        #expect(store.oldestQueuedAt == nil)
    }

    // MARK: - Edit during a push

    /// The server's copy used to be stamped "now", always newer than an edit
    /// made while the request was out, so `ContactDAO.upsert`'s newer-wins
    /// guard never fired and the edit was overwritten and marked synced.
    @Test func anEditMadeDuringThePushSurvivesTheServerCopy() async throws {
        let localId = UUID()
        let env = try makeEnvironment { dao, _ in
            scripted { request in
                if request.httpMethod == "POST" {
                    var edited = Contact(
                        localId: localId, uid: "srv-1", rev: 1, name: "Edited mid-push",
                        createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(), needsSync: true
                    )
                    edited.emails = []
                    try await dao.upsert(contacts: [edited])
                }
                return (200, #"{"cursor": 5, "changed": [{"uid": "srv-1", "rev": 2, "fn": "First edit"}]}"#)
            }
        }
        try await env.dao.upsert(contacts: [Contact(
            localId: localId, uid: "srv-1", rev: 1, name: "First edit",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000), needsSync: true
        )])

        try await env.repository.sync()

        let stored = try #require(try await env.dao.getContact(uid: "srv-1"))
        #expect(stored.name == "Edited mid-push")
        #expect(stored.needsSync, "the edit made mid-push still has to go out")
    }

    @Test func aServerCopyStillReplacesAnUneditedRow() async throws {
        let env = try makeEnvironment { _, _ in
            scripted { _ in (200, #"{"cursor": 5, "changed": [{"uid": "srv-1", "rev": 2, "fn": "Server"}]}"#) }
        }
        try await env.dao.upsert(contacts: [contact(uid: "srv-1", name: "Local", needsSync: true)])

        try await env.repository.sync()

        let stored = try #require(try await env.dao.getContact(uid: "srv-1"))
        #expect(stored.name == "Server")
        #expect(!stored.needsSync)
    }

    /// A create edited while its push was out keeps its flag when the uid is
    /// assigned, so the edit goes out as an update.
    @Test func assigningAUidKeepsAnEditMadeAfterThePushedSnapshot() async throws {
        let database = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: database.container)
        var created = contact(name: "Ada", needsSync: true, updatedAt: Date(timeIntervalSince1970: 1_000))
        try await dao.upsert(contacts: [created])
        let pushedAt = created.updatedAt
        created.name = "Ada L."
        created.updatedAt = Date(timeIntervalSince1970: 2_000)
        try await dao.upsert(contacts: [created])

        try await dao.assignUid(localId: created.localId, uid: "srv-a", pushedUpdatedAt: pushedAt)

        let stored = try #require(try await dao.getContact(uid: "srv-a"))
        #expect(stored.needsSync)
        #expect(stored.name == "Ada L.")
    }

    // MARK: - tooOld

    /// `tooOld` used to wipe the table and the delete queue, unsynced work
    /// included (the `ponytail:` admitted it). Now only synced rows go, the
    /// re-pull runs at once, a create the refused push already applied is
    /// reconciled rather than re-created, and edits and deletes go out again.
    @Test func tooOldKeepsUnsyncedWorkAndRepullsAtOnce() async throws {
        let requests = Box<[(method: String, query: String, body: String)]>([])
        let env = try makeEnvironment { _, _ in
            scripted { request in
                let count = requests.value.count
                requests.mutate { $0.append((request.httpMethod ?? "", request.url?.query ?? "", body(request))) }
                switch count {
                case 0:
                    // The push is applied server-side, but the cursor is too old.
                    return (200, #"{"cursor": 0, "tooOld": true}"#)
                case 1:
                    // The re-pull's pre-push pull from 0: the server already
                    // holds the create and the edit from that push.
                    return (200, """
                    {"cursor": 40, "changed": [
                      {"uid": "srv-new", "rev": 1, "fn": "New Person", "emails": [{"value": "new@example.com"}]},
                      {"uid": "srv-2", "rev": 3, "fn": "Edited"},
                      {"uid": "srv-other", "rev": 1, "fn": "From another device"}
                    ]}
                    """)
                default:
                    return (200, """
                    {"cursor": 41, "changed": [
                      {"uid": "srv-new", "rev": 1, "fn": "New Person", "emails": [{"value": "new@example.com"}]},
                      {"uid": "srv-2", "rev": 4, "fn": "Edited"},
                      {"uid": "srv-other", "rev": 1, "fn": "From another device"}
                    ]}
                    """)
                }
            }
        }
        env.cursorStore.advance(to: 99)
        try await env.dao.upsert(contacts: [
            contact(uid: "srv-stale", name: "Synced, server forgot"),
            contact(uid: "srv-2", name: "Edited", needsSync: true),
            contact(name: "New Person", email: "new@example.com", needsSync: true),
            contact(name: "", email: "nameless@example.com", needsSync: true),
        ])
        env.pendingDeletes.add("srv-gone")

        try await env.repository.sync()

        let log = requests.value
        #expect(log.map(\.method) == ["POST", "GET", "POST"])
        #expect(log[1].query == "since=0")
        // The create was reconciled from the pull, so it was not sent twice.
        #expect(!log[2].body.contains("New Person"))
        #expect(log[2].body.contains("srv-2"))
        #expect(log[2].body.contains("srv-gone"))

        let all = try await env.dao.listAll()
        #expect(all.first { $0.name == "New Person" }?.uid == "srv-new")
        #expect(all.filter { $0.name == "New Person" }.count == 1)
        #expect(all.contains { $0.uid == "srv-other" })
        #expect(!all.contains { $0.uid == "srv-stale" })
        let nameless = try #require(all.first { $0.emails.first?.value == "nameless@example.com" })
        #expect(nameless.needsSync, "a nameless contact is not the server's to discard")
        #expect(env.pendingDeletes.all().isEmpty)
        #expect(env.cursorStore.lastCursor == 41)
    }

    @Test func aSecondTooOldDoesNotLoop() async throws {
        let count = Box(0)
        let env = try makeEnvironment { _, _ in
            scripted { _ in
                count.mutate { $0 += 1 }
                return (200, #"{"cursor": 0, "tooOld": true}"#)
            }
        }
        try await env.dao.upsert(contacts: [contact(uid: "srv-2", name: "Edit", needsSync: true)])

        let summary = try await env.repository.sync()

        #expect(count.value == 2)
        #expect(summary.newCursor == 0)
        #expect(try await env.dao.listPendingSync().map(\.name) == ["Edit"])
    }

    // MARK: - Lost create responses

    /// The relay committed the create but the response never arrived: the
    /// next sync must find it on the server instead of creating it again.
    @Test func aCreateWhoseResponseWasLostIsNotPushedTwice() async throws {
        let requests = Box<[(method: String, body: String)]>([])
        let env = try makeEnvironment { _, _ in
            scripted { request in
                let count = requests.value.count
                requests.mutate { $0.append((request.httpMethod ?? "", body(request))) }
                switch count {
                case 0:
                    throw URLError(.timedOut)
                default:
                    return (200, """
                    {"cursor": 8, "changed": [
                      {"uid": "srv-ada", "rev": 1, "fn": "Ada", "emails": [{"value": "ada@example.com"}]}
                    ]}
                    """)
                }
            }
        }
        try await env.repository.saveContact(contact(name: "Ada", email: "ada@example.com"))

        await #expect(throws: NetworkError.self) { try await env.repository.sync() }
        #expect(env.cursorStore.createsInFlight)

        try await env.repository.sync()

        // Lost POST, then the reconciling pull and an ordinary pull — never a
        // second POST carrying the create.
        #expect(requests.value.map(\.method) == ["POST", "GET", "GET"])
        let all = try await env.dao.listAll()
        #expect(all.count == 1)
        #expect(all.first?.uid == "srv-ada")
        #expect(all.first?.needsSync == false)
        #expect(!env.cursorStore.createsInFlight)
    }

    @Test func anAnsweredPushLeavesNoCreatesInFlight() async throws {
        let env = try makeEnvironment { _, _ in
            scripted { _ in
                (200, #"{"cursor": 2, "changed": [{"uid": "srv-ada", "rev": 1, "fn": "Ada"}]}"#)
            }
        }
        try await env.repository.saveContact(contact(name: "Ada"))
        try await env.repository.sync()
        #expect(!env.cursorStore.createsInFlight)
    }

    // MARK: - Client correlation id

    @Test func aCreateCarriesItsLocalIdAsClientRefAndAnEditDoesNot() async throws {
        let sent = Box<String>("")
        let env = try makeEnvironment { _, _ in
            scripted { request in
                sent.value = body(request)
                return (200, #"{"cursor": 2}"#)
            }
        }
        let create = contact(name: "Ada", needsSync: true)
        try await env.dao.upsert(contacts: [create, contact(uid: "srv-9", name: "Grace", needsSync: true)])

        try await env.repository.sync()

        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(sent.value.utf8)) as? [String: Any]
        )
        let changes = try #require(json["changes"] as? [[String: Any]])
        let ada = try #require(changes.first { $0["fn"] as? String == "Ada" })
        let grace = try #require(changes.first { $0["fn"] as? String == "Grace" })
        #expect(ada["clientRef"] as? String == create.localId.uuidString.lowercased())
        #expect(grace["clientRef"] == nil)
    }

    @Test func anEchoedClientRefMatchesExactlyEvenWhenTheServerRewroteTheContent() {
        let local = contact(name: "ada", email: "ADA@example.com", needsSync: true)
        var echoed = ContactDTO(uid: "srv-a", rev: 1, fn: "Ada", emails: [ContactFieldDTO(label: nil, value: "ada@example.com")])
        echoed.clientRef = ContactSyncReconciliation.clientRef(for: local)

        let assignments = ContactSyncReconciliation.reconcile(localPending: [local], responseChanged: [echoed])

        #expect(assignments == [.init(localId: local.localId, uid: "srv-a")])
    }

    /// Another device's create with identical content names its own create;
    /// it is never claimed by content for ours.
    @Test func anEntryNamingAnotherCreateIsNeverAContentMatch() {
        let local = contact(name: "Ada", email: "ada@example.com", needsSync: true)
        var theirs = ContactDTO(uid: "srv-theirs", rev: 1, fn: "Ada", emails: [ContactFieldDTO(label: nil, value: "ada@example.com")])
        theirs.clientRef = UUID().uuidString.lowercased()
        let ours = ContactDTO(uid: "srv-ours", rev: 1, fn: "Ada", emails: [ContactFieldDTO(label: nil, value: "ada@example.com")])

        let assignments = ContactSyncReconciliation.reconcile(localPending: [local], responseChanged: [theirs, ours])

        #expect(assignments == [.init(localId: local.localId, uid: "srv-ours")])
    }
}
