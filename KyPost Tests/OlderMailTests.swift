//
//  OlderMailTests.swift
//  KyPost Tests
//
//  "Load older mail" and reliable deltas (KyPost-for-Android #183, against
//  KyPost-Server `before=` paging and `agedOut`/`hasMore`/`nextBefore`):
//  mail outside the relay's window survives every resync, a delta overflow is
//  stored whole or not at all, an old server is refused, and bodies of
//  out-of-window rows are never cached.
//

import Foundation
import SwiftData
import Testing
@testable import KyPost

// MARK: - A scriptable relay

/// Answers `/api/inbox` and `/api/mail/body` from closures over the request's
/// query, and records every query it saw.
nonisolated final class ScriptedRelay: @unchecked Sendable {
    typealias Answer = @Sendable ([String: String]) -> (Int, String)

    let queries = Box<[[String: String]]>([])
    let inbox = Box<Answer>({ _ in (200, #"{"byTab":{}}"#) })
    let body = Box<Answer>({ _ in (200, #"{"body":"","bodyMode":""}"#) })
    /// Awaited before answering, so a test can hold a request in flight.
    let beforeAnswer = Box<(@Sendable ([String: String]) async -> Void)?>(nil)

    var client: HTTPClient {
        HTTPClient { [self] request in
            let url = request.url!
            var query: [String: String] = ["path": url.path]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
            queries.mutate { $0.append(query) }
            await beforeAnswer.value?(query)
            let (status, json): (Int, String) = switch url.path {
            case "/api/inbox": inbox.value(query)
            case "/api/mail/body": body.value(query)
            default: (404, "")
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
    }

    var inboxQueries: [[String: String]] { queries.value.filter { $0["path"] == "/api/inbox" } }
    var pageQueries: [[String: String]] { inboxQueries.filter { $0["before"] != nil } }
}

nonisolated private let base = 1_790_000_000.0

/// One wire row, `minutesAgo` before a fixed instant.
nonisolated private func wire(_ id: String, minutesAgo: Int, body: String? = "body \(UUID().uuidString.prefix(4))", status: String = "unread") -> String {
    let stamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: base - Double(minutesAgo) * 60))
    let bodyField = body.map { #","body":"\#($0)""# } ?? ""
    return #"{"messageId":"\#(id)","subject":"\#(id)","atUtc":"\#(stamp)","status":"\#(status)"\#(bodyField)}"#
}

nonisolated private func inboxJSON(_ rows: [String], extra: String = "") -> String {
    #"{"byTab":{"Inbox":[\#(rows.joined(separator: ","))]}\#(extra.isEmpty ? "" : "," + extra)}"#
}

private func row(_ id: String, minutesAgo: Int, body: String = "cached") -> Email {
    Email(
        serverId: id, folder: "INBOX", senderName: "A", senderEmail: "a@x",
        subject: id, body: body, keywords: [],
        receivedAt: Date(timeIntervalSince1970: base - Double(minutesAgo) * 60),
        read: false, starred: false
    )
}

private struct Harness {
    let relay = ScriptedRelay()
    let dao: EmailDAO
    let cursors: MailCursorStore
    let pairingStore: SecurePairingStore
    let repository: MailRepository

    init() throws {
        dao = EmailDAO(modelContainer: try AppDatabase(inMemory: true).container)
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        cursors = MailCursorStore(defaults: defaults, hostileLocation: HostileLocationProtectionStore(defaults: defaults))
        pairingStore = try makePairedStore()
        repository = MailRepository(
            securePairingStore: pairingStore,
            emailDAO: dao,
            httpClient: relay.client,
            cursorStore: cursors
        )
    }

    /// The folder holds `rows` and a cursor, so the next refresh is a delta.
    func seed(_ rows: [Email], cursor: String = "10") async throws {
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: rows)
        cursors.saveCursor(pairingId: "u1", folder: "INBOX", cursor: cursor)
        cursors.recordFullResync(pairingId: "u1", folder: "INBOX")
    }

    func stored(_ id: String) async throws -> Email? {
        try await dao.getEmail(folder: "INBOX", serverId: id)
    }

    var cursor: String { cursors.cursor(pairingId: "u1", folder: "INBOX") }

    /// The next account's pairing, stored over the forgotten one.
    func pairNextAccount() throws {
        try pairingStore.savePairing(Pairing(
            sub: "u2", deviceSecret: "s2", srv: server, registrationUrl: nil,
            pairingToken: "pt2", lastDeviceId: nil, pairedAt: Date().addingTimeInterval(1)
        ))
    }
}

// MARK: - The window and what lies outside it

@Suite struct OlderMailWindowTests {
    @Test func anAgedOutRowIsKeptAndSurvivesTheNextSnapshot() async throws {
        let h = try Harness()
        try await h.seed([row("new", minutesAgo: 1), row("aging", minutesAgo: 5)])
        h.relay.inbox.value = { _ in
            (200, inboxJSON([], extra: #""delta":true,"cursor":"11","agedOut":["aging"]"#))
        }
        try await h.repository.refreshFolder("INBOX")
        #expect(try await h.stored("aging")?.inWindow == false)

        // The daily snapshot no longer lists it; within its date range or
        // not, an out-of-window row is not the snapshot's to prune.
        h.relay.inbox.value = { _ in (200, inboxJSON([wire("new", minutesAgo: 1), wire("older", minutesAgo: 9)])) }
        try await h.repository.refreshFolder("INBOX", forceFullResync: true)

        #expect(try await h.stored("aging") != nil)
        #expect(try await h.stored("aging")?.body == "cached")
    }

    @Test func removedStillDeletesARowOutsideTheWindow() async throws {
        let h = try Harness()
        try await h.seed([row("new", minutesAgo: 1)])
        h.relay.inbox.value = { _ in (200, inboxJSON([wire("old", minutesAgo: 90)], extra: #""hasMore":false"#)) }
        _ = await h.repository.loadOlder(folder: "INBOX", frontier: nil)
        #expect(try await h.stored("old")?.inWindow == false)

        h.relay.inbox.value = { _ in (200, inboxJSON([], extra: #""delta":true,"cursor":"11","removed":["old"]"#)) }
        try await h.repository.refreshFolder("INBOX")

        #expect(try await h.stored("old") == nil)
    }

    @Test func pagedInMailSurvivesTheDailySnapshot() async throws {
        let h = try Harness()
        try await h.seed([row("w1", minutesAgo: 1), row("w2", minutesAgo: 2)])
        h.relay.inbox.value = { query in
            query["before"] != nil
                ? (200, inboxJSON([wire("p1", minutesAgo: 60, body: nil), wire("p2", minutesAgo: 61, body: nil)], extra: #""hasMore":true,"nextBefore":"p2""#))
                : (200, inboxJSON([wire("w1", minutesAgo: 1), wire("w2", minutesAgo: 2)]))
        }
        #expect(await h.repository.loadOlder(folder: "INBOX", frontier: nil) == .loaded(nextBefore: "p2"))

        let rows = try await h.repository.refreshFolder("INBOX", forceFullResync: true)

        #expect(rows.map(\.serverId) == ["w1", "w2", "p1", "p2"])
        #expect(try await h.stored("p1")?.inWindow == false)
    }

    /// A page is metadata only: a row already held keeps its body and flags
    /// and takes only its read state and labels.
    @Test func anOlderPageRefreshesReadStateButKeepsWhatOnlyTheWindowCarries() async throws {
        let h = try Harness()
        var held = row("w", minutesAgo: 3, body: "<p>kept</p>")
        held.pgpEncrypted = true
        held.hasAttachments = true
        try await h.seed([held])
        h.relay.inbox.value = { _ in
            (200, inboxJSON([wire("w", minutesAgo: 3, body: nil, status: "read")], extra: #""hasMore":false"#))
        }

        _ = await h.repository.loadOlder(folder: "INBOX", frontier: nil)

        let stored = try #require(try await h.stored("w"))
        #expect(stored.read)
        #expect(stored.keywords.contains("Inbox"))
        #expect(stored.body == "<p>kept</p>")
        #expect(stored.pgpEncrypted)
        #expect(stored.hasAttachments)
        #expect(stored.inWindow)
    }

    /// A forgotten cursor (or an older relay) lets mail age out unreported.
    /// The snapshot is the newest mail: absent rows older than all of it still
    /// exist, so they leave the window; absent rows inside its range are gone.
    @Test func aSnapshotKeepsOlderAbsentRowsAndPrunesOnlyAbsentNewerOnes() async throws {
        let h = try Harness()
        try await h.dao.replaceFolderSnapshot(folder: "INBOX", emails: [
            row("deletedOnTheWeb", minutesAgo: 2), row("w", minutesAgo: 3), row("agedOut", minutesAgo: 30),
        ])
        h.relay.inbox.value = { _ in (200, inboxJSON([wire("fresh", minutesAgo: 1), wire("w", minutesAgo: 3)])) }

        try await h.repository.refreshFolder("INBOX", forceFullResync: true)

        #expect(try await h.stored("deletedOnTheWeb") == nil)
        #expect(try await h.stored("agedOut")?.inWindow == false)
        #expect(try await h.stored("w")?.inWindow == true)
    }

    @Test func theWindowAndEveryPageAskForTheSameLimit() async throws {
        let h = try Harness()
        try await h.seed([row("held", minutesAgo: 100)])
        h.relay.inbox.value = { query in
            query["before"] != nil
                ? (200, inboxJSON([wire("held", minutesAgo: 100, body: nil)], extra: #""hasMore":true,"nextBefore":"held""#))
                : (200, inboxJSON([wire("n", minutesAgo: 1)], extra: #""delta":true,"cursor":"11","hasMore":true,"nextBefore":"n""#))
        }
        try await h.repository.refreshFolder("INBOX")
        _ = await h.repository.loadOlder(folder: "INBOX", frontier: nil)

        #expect(h.relay.inboxQueries.count == 3)
        #expect(h.relay.inboxQueries.allSatisfy { $0["limit"] == String(MailRepository.windowLimit) })
        #expect(MailRepository.windowLimit == 50)
    }
}

// MARK: - Delta overflow

@Suite struct DeltaOverflowTests {
    @Test func anOverflowPagesDownToHeldMailBeforeCommittingTheCursor() async throws {
        let h = try Harness()
        try await h.seed([row("held", minutesAgo: 500)])
        h.relay.inbox.value = { query in
            switch query["before"] {
            case nil: (200, inboxJSON([wire("n1", minutesAgo: 1)], extra: #""delta":true,"cursor":"20","hasMore":true,"nextBefore":"n1""#))
            case "n1": (200, inboxJSON([wire("p1", minutesAgo: 100, body: nil)], extra: #""hasMore":true,"nextBefore":"p1""#))
            default: (200, inboxJSON([wire("p2", minutesAgo: 200, body: nil), wire("held", minutesAgo: 500, body: nil)], extra: #""hasMore":true,"nextBefore":"held""#))
            }
        }

        let rows = try await h.repository.refreshFolder("INBOX")

        #expect(rows.map(\.serverId) == ["n1", "p1", "p2", "held"])
        #expect(h.relay.pageQueries.map { $0["before"] } == ["n1", "p1"])
        #expect(h.relay.pageQueries.allSatisfy { $0["since"] == nil && $0["bodies"] == "0" })
        #expect(try await h.stored("p1")?.inWindow == false)
        #expect(h.cursor == "20")
    }

    /// Nothing from a failed walk is stored — not even the window: any stored
    /// row would count as held, and a retry would stop at it and commit past
    /// the pages that never arrived.
    @Test func aFailedPageStoresNothingKeepsTheCursorAndTheRetryWalksEveryPage() async throws {
        let h = try Harness()
        try await h.seed([row("held", minutesAgo: 500)])
        let failSecondPage = Box(true)
        h.relay.inbox.value = { query in
            switch query["before"] {
            case nil: (200, inboxJSON([wire("n1", minutesAgo: 1)], extra: #""delta":true,"cursor":"20","hasMore":true,"nextBefore":"n1""#))
            case "n1": (200, inboxJSON([wire("p1", minutesAgo: 100, body: nil)], extra: #""hasMore":true,"nextBefore":"p1""#))
            default:
                failSecondPage.value
                    ? (502, "upstream")
                    : (200, inboxJSON([wire("held", minutesAgo: 500, body: nil)], extra: #""hasMore":true,"nextBefore":"held""#))
            }
        }

        await #expect(throws: (any Error).self) { try await h.repository.refreshFolder("INBOX") }
        #expect(try await h.stored("n1") == nil)
        #expect(try await h.stored("p1") == nil)
        #expect(h.cursor == "10")

        failSecondPage.value = false
        h.relay.queries.value = []
        try await h.repository.refreshFolder("INBOX")

        #expect(h.relay.pageQueries.map { $0["before"] } == ["n1", "p1"])
        #expect(try await h.stored("n1") != nil)
        #expect(try await h.stored("p1") != nil)
        #expect(h.cursor == "20")
    }

    @Test(arguments: [
        // No nextBefore at all.
        #""delta":true,"cursor":"20","hasMore":true"#,
        // A page that drops hasMore contradicts the announced overflow.
        #""delta":true,"cursor":"20","hasMore":true,"nextBefore":"n1""#,
    ])
    func aContradictoryOverflowKeepsTheCursorAndStoresNothing(windowExtra: String) async throws {
        let h = try Harness()
        try await h.seed([row("held", minutesAgo: 500)])
        h.relay.inbox.value = { query in
            query["before"] == nil
                ? (200, inboxJSON([wire("n1", minutesAgo: 1)], extra: windowExtra))
                : (200, inboxJSON([wire("p1", minutesAgo: 100, body: nil)]))
        }

        await #expect(throws: MailSourceError.overflowUnreachable) {
            try await h.repository.refreshFolder("INBOX")
        }
        #expect(try await h.stored("n1") == nil)
        #expect(h.cursor == "10")
    }

    @Test func aFullWindowNeverWalks() async throws {
        let h = try Harness()
        h.relay.inbox.value = { _ in
            (200, inboxJSON([wire("n1", minutesAgo: 1)], extra: #""cursor":"20","hasMore":true,"nextBefore":"n1""#))
        }
        try await h.repository.refreshFolder("INBOX")
        #expect(h.relay.pageQueries.isEmpty)
    }
}

// MARK: - Load older mail

@Suite struct LoadOlderMailTests {
    @Test func theFirstPageStartsAtTheOldestRowHeldThenFollowsNextBefore() async throws {
        let h = try Harness()
        try await h.seed([row("w1", minutesAgo: 1), row("w2", minutesAgo: 2)])
        h.relay.inbox.value = { query in
            query["before"] == "w2"
                ? (200, inboxJSON([wire("p1", minutesAgo: 60, body: nil)], extra: #""hasMore":true,"nextBefore":"p1""#))
                : (200, inboxJSON([wire("p2", minutesAgo: 70, body: nil)], extra: #""hasMore":false"#))
        }

        #expect(await h.repository.loadOlder(folder: "INBOX", frontier: nil) == .loaded(nextBefore: "p1"))
        #expect(await h.repository.loadOlder(folder: "INBOX", frontier: "p1") == .loaded(nextBefore: nil))
        #expect(h.relay.pageQueries.map { $0["before"] } == ["w2", "p1"])
        #expect(try await h.dao.getFolder(folder: "INBOX").map(\.serverId) == ["w1", "w2", "p1", "p2"])
    }

    /// A server without `before=` paging ignores it and answers with its
    /// newest window, which is not older mail.
    @Test func aServerThatIgnoresBeforeIsRefusedAndNothingIsStored() async throws {
        let h = try Harness()
        try await h.seed([row("w1", minutesAgo: 1)])
        h.relay.inbox.value = { _ in (200, inboxJSON([wire("w1", minutesAgo: 1), wire("w0", minutesAgo: 0)])) }

        let outcome = await h.repository.loadOlder(folder: "INBOX", frontier: nil)

        #expect(outcome == .unsupported("This server can't load older mail. Update KyPost Server to use this."))
        #expect(try await h.stored("w0") == nil)
    }

    @Test func aStaleAnchorIsTheServersBadRequest() async throws {
        let h = try Harness()
        try await h.seed([row("w1", minutesAgo: 1)])
        h.relay.inbox.value = { _ in (400, "invalid before message reference; refresh the mailbox") }

        let outcome = await h.repository.loadOlder(folder: "INBOX", frontier: "gone")

        #expect(outcome == .failed("invalid before message reference; refresh the mailbox", staleAnchor: true))
    }

    @Test func anEmptyFolderHasNothingToPageFrom() async throws {
        let h = try Harness()
        #expect(await h.repository.loadOlder(folder: "INBOX", frontier: nil) == .nothingToPageFrom)
        #expect(h.relay.inboxQueries.isEmpty)
    }

    @Test @MainActor func theFooterHidesWhenNothingOlderIsLeftOrTheServerCannotPage() async throws {
        let h = try Harness()
        h.relay.inbox.value = { query in
            query["before"] == nil
                ? (200, inboxJSON([wire("w1", minutesAgo: 1)]))
                : (200, inboxJSON([wire("p1", minutesAgo: 60, body: nil)], extra: #""hasMore":false"#))
        }
        let viewModel = InboxViewModel(
            mailRepository: h.repository,
            keywordRepository: KeywordRepository(
                settingsStore: KeywordSettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
            )
        )
        await viewModel.load()
        #expect(viewModel.showsLoadOlder)

        await viewModel.loadOlderMail()

        #expect(viewModel.emails.map(\.serverId) == ["w1", "p1"])
        #expect(!viewModel.showsLoadOlder)

        // A second folder on an old server: refused, said so, footer gone.
        h.relay.inbox.value = { query in
            query["before"] == nil
                ? (200, inboxJSON([wire("j1", minutesAgo: 1)]))
                : (200, inboxJSON([wire("j1", minutesAgo: 1)]))
        }
        await viewModel.selectFolder("Junk")
        #expect(viewModel.showsLoadOlder)
        await viewModel.loadOlderMail()
        #expect(!viewModel.showsLoadOlder)
        #expect(viewModel.notice == "This server can't load older mail. Update KyPost Server to use this.")

        // Leaving the account forgets it all: the rows, and the Junk folder's
        // "cannot page" verdict with them.
        viewModel.forgetAccount()
        #expect(viewModel.emails.isEmpty)
        await viewModel.selectFolder("Junk")
        #expect(viewModel.showsLoadOlder)
    }
}

// MARK: - Leaving the account

/// Holds the first request it is handed until `open()`; later ones pass.
private actor HeldRequest {
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

@MainActor
private func makeViewModel(_ h: Harness) -> InboxViewModel {
    InboxViewModel(
        mailRepository: h.repository,
        keywordRepository: KeywordRepository(
            settingsStore: KeywordSettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        )
    )
}

@MainActor
@Suite struct ForgetAccountTests {
    /// Unpair, then pair the next account: mail aged out of the old window
    /// is never pruned by a refresh, so only the erase removes it.
    @Test func theNextAccountNeverSeesThePreviousAccountsAgedOutMail() async throws {
        let h = try Harness()
        try await h.seed([row("new", minutesAgo: 1), row("aging", minutesAgo: 5, body: "previous account's text")])
        h.relay.inbox.value = { _ in
            (200, inboxJSON([], extra: #""delta":true,"cursor":"11","agedOut":["aging"]"#))
        }
        let viewModel = makeViewModel(h)
        await viewModel.load()
        #expect(try await h.stored("aging")?.inWindow == false)
        #expect(viewModel.emails.map(\.serverId).contains("aging"))

        try await h.repository.forgetAccount()
        viewModel.forgetAccount()
        #expect(viewModel.emails.isEmpty)
        #expect(h.cursor == "")

        // The next account's whole window, dated after the aged-out row.
        try h.pairNextAccount()
        h.relay.inbox.value = { _ in (200, inboxJSON([wire("theirs", minutesAgo: 2)])) }
        await viewModel.load()

        #expect(try await h.stored("aging") == nil)
        #expect(try await h.stored("new") == nil)
        #expect(try await h.repository.cachedFolder("INBOX").map(\.serverId) == ["theirs"])
        #expect(viewModel.emails.map(\.serverId) == ["theirs"])
    }

    @Test func aRefreshInFlightWhenTheAccountIsForgottenStoresAndPaintsNothing() async throws {
        let h = try Harness()
        let held = HeldRequest()
        h.relay.beforeAnswer.value = { _ in await held.hold() }
        h.relay.inbox.value = { _ in (200, inboxJSON([wire("old", minutesAgo: 1)], extra: #""cursor":"9""#)) }
        let viewModel = makeViewModel(h)

        let refresh = Task { await viewModel.refresh() }
        await held.waitUntilHolding()
        try await h.repository.forgetAccount()
        viewModel.forgetAccount()
        #expect(!viewModel.isRefreshing)
        await held.open()
        await refresh.value

        #expect(try await h.stored("old") == nil)
        #expect(h.cursor == "")
        #expect(viewModel.emails.isEmpty)
        #expect(viewModel.connectionNotice == nil)
    }

    /// Code review: a page answered after `forgetAccount` must not hide the
    /// footer or leave its spinner running.
    @Test func aPageInFlightWhenTheAccountIsForgottenNeitherHidesTheFooterNorSpins() async throws {
        let h = try Harness()
        let held = HeldRequest()
        h.relay.beforeAnswer.value = { query in
            if query["before"] != nil { await held.hold() }
        }
        h.relay.inbox.value = { query in
            // An old server: the page is its newest window, without hasMore.
            (200, inboxJSON([wire(query["before"] == nil ? "w1" : "x", minutesAgo: 1)]))
        }
        let viewModel = makeViewModel(h)
        await viewModel.load()

        let page = Task { await viewModel.loadOlderMail() }
        await held.waitUntilHolding()
        #expect(viewModel.isLoadingOlder)
        viewModel.forgetAccount()
        #expect(!viewModel.isLoadingOlder)
        await viewModel.load()
        await held.open()
        await page.value

        #expect(viewModel.showsLoadOlder)
        #expect(!viewModel.isLoadingOlder)
        #expect(viewModel.notice == nil)
    }

    /// Replacing the account erases its mail before the next pairing is
    /// stored, so the previous one is still readable for a moment. A
    /// refresh, page or body fetch started in that moment goes nowhere.
    @Test func theForgottenPairingStillStoredReachesNoMail() async throws {
        let h = try Harness()
        h.relay.inbox.value = { _ in (200, inboxJSON([wire("old", minutesAgo: 1)], extra: #""cursor":"9""#)) }
        h.relay.body.value = { _ in (200, #"{"body":"previous account's text","bodyMode":"plain"}"#) }
        try await h.repository.forgetAccount()

        await #expect(throws: MailSourceError.self) { try await h.repository.refreshFolder("INBOX") }
        #expect(await h.repository.loadOlder(folder: "INBOX", frontier: "a1") != .loaded(nextBefore: nil))
        await #expect(throws: MailSourceError.self) {
            try await h.repository.loadBody(for: row("w1", minutesAgo: 1, body: ""))
        }
        #expect(h.relay.queries.value.isEmpty)
        #expect(try await h.stored("old") == nil)
        #expect(h.cursor == "")

        // The next account's pairing is served normally.
        try h.pairNextAccount()
        try await h.repository.refreshFolder("INBOX")
        #expect(try await h.stored("old") != nil)
    }

    /// Code review: a list action held when the account is left is dropped
    /// before teardown's first suspension, so an undo deadline that passes
    /// while a later step awaits sends nothing.
    @Test func teardownDropsHeldActionsBeforeItsFirstSuspension() async throws {
        let h = try Harness()
        try await h.seed([row("w1", minutesAgo: 1)])
        let viewModel = InboxViewModel(
            mailRepository: h.repository,
            keywordRepository: KeywordRepository(
                settingsStore: KeywordSettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
            ),
            undoWindow: .milliseconds(20)
        )
        viewModel.delete(serverIds: ["w1"])
        #expect(viewModel.undoMessage != nil)

        // Whether the mail erase had happened yet when the inbox was told.
        let cursorAtFirstCall = Box<[String]>([])
        let complete = await AccountTeardown(
            mailRepository: h.repository,
            forgetInbox: {
                cursorAtFirstCall.mutate { $0.append(h.cursor) }
                viewModel.forgetAccount()
            }
        ).run()
        try await Task.sleep(for: .milliseconds(100))

        #expect(complete)
        #expect(cursorAtFirstCall.value.first == "10")
        #expect(viewModel.undoMessage == nil)
        #expect(!h.relay.queries.value.contains { ($0["path"] ?? "").contains("actions") })
    }

    @Test func aBodyFetchedAfterTheAccountIsForgottenIsNotCached() async throws {
        let h = try Harness()
        try await h.seed([row("w1", minutesAgo: 1, body: "")])
        let held = HeldRequest()
        h.relay.beforeAnswer.value = { query in
            if query["path"] == "/api/mail/body" { await held.hold() }
        }
        h.relay.body.value = { _ in (200, #"{"body":"previous account's text","bodyMode":"plain"}"#) }
        let stored = try #require(try await h.stored("w1"))

        let fetch = Task { try await h.repository.loadBody(for: stored) }
        await held.waitUntilHolding()
        try await h.repository.forgetAccount()
        // The next account holds a message under the same id.
        try await h.seed([row("w1", minutesAgo: 1, body: "")])
        await held.open()
        _ = try await fetch.value

        #expect(try await h.stored("w1")?.body == "")
    }
}

// MARK: - Bodies on open

@Suite struct BodyOnOpenTests {
    @Test func anOutOfWindowRowFetchesItsBodyEveryTimeAndNeverCachesIt() async throws {
        let h = try Harness()
        try await h.seed([row("w1", minutesAgo: 1)])
        h.relay.inbox.value = { _ in (200, inboxJSON([wire("p1", minutesAgo: 60, body: nil)], extra: #""hasMore":false"#)) }
        h.relay.body.value = { _ in (200, #"{"body":"<p>old</p>","bodyMode":"html"}"#) }
        _ = await h.repository.loadOlder(folder: "INBOX", frontier: nil)
        let paged = try #require(try await h.stored("p1"))
        #expect(MailRepository.needsBodyFetch(paged))

        let fetched = try await h.repository.loadBody(for: paged)

        #expect(fetched == MailMessageBody(body: "<p>old</p>", bodyMode: "html"))
        #expect(try await h.stored("p1")?.body == "")
        let bodyQuery = try #require(h.relay.queries.value.last)
        #expect(bodyQuery["path"] == "/api/mail/body")
        #expect(bodyQuery["mailbox"] == "INBOX")
        #expect(bodyQuery["messageId"] == "p1")
    }

    @Test func aWindowRowCachesTheBodyItFetched() async throws {
        let h = try Harness()
        try await h.seed([row("w1", minutesAgo: 1, body: "")])
        h.relay.body.value = { _ in (200, #"{"body":"filled","bodyMode":"plain"}"#) }
        let stored = try #require(try await h.stored("w1"))

        _ = try await h.repository.loadBody(for: stored)

        #expect(try await h.stored("w1")?.body == "filled")
        #expect(try await h.stored("w1")?.bodyMode == "plain")
    }

    /// Code review: Reply/Forward wait for the body a paged row fetches on
    /// open, then quote it.
    @Test func replyAndForwardWaitForTheFetchedBodyThenQuoteIt() {
        let paged = row("p1", minutesAgo: 60, body: "")
        #expect(draftBodyReadiness(for: paged, fetchedBody: nil, fetchFailed: false) == .loading)
        #expect(draftBodyReadiness(for: paged, fetchedBody: nil, fetchFailed: true) == .failed)

        let fetched = MailMessageBody(body: "the fetched text", bodyMode: "plain")
        #expect(draftBodyReadiness(for: paged, fetchedBody: fetched, fetchFailed: false) == .ready)
        let shown = emailWithFetchedBody(paged, fetched)
        #expect(ComposeDraft.reply(to: shown).body.contains("the fetched text"))
        #expect(ComposeDraft.replyAll(to: shown, ownAddress: nil).body.contains("the fetched text"))
        #expect(ComposeDraft.forward(shown).body.contains("the fetched text"))

        // A row that arrived with its body never waits.
        #expect(draftBodyReadiness(for: row("w", minutesAgo: 1), fetchedBody: nil, fetchFailed: false) == .ready)
    }

    /// A blank body on an encrypted row is the client-protected shape; it has
    /// its own decrypt path, and fetching would hide it.
    @Test func aClientProtectedRowIsNeverFetched() {
        var protected = row("e", minutesAgo: 1, body: "")
        protected.pgpEncrypted = true
        #expect(!MailRepository.needsBodyFetch(protected))
        #expect(!MailRepository.needsBodyFetch(row("w", minutesAgo: 1, body: "text")))
    }

    @Test(arguments: [
        (404, "This message is no longer on the server."),
        (413, "This message is too large for the server to open."),
    ])
    func aDefinitiveRefusalSaysWhyRatherThanBlamingTheConnection(status: Int, message: String) async throws {
        let h = try Harness()
        h.relay.body.value = { _ in (status, #"{"error":"x"}"#) }
        do {
            _ = try await h.repository.loadBody(for: row("gone", minutesAgo: 1, body: ""))
            Issue.record("expected a failure")
        } catch {
            #expect(MailOutcome.from(error).userMessage == message)
        }
    }
}

// MARK: - Wire and schema

@Suite struct OlderMailWireTests {
    @Test func aDeltaCarriesAgedOutAndOverflow() async throws {
        let client = stubClient(json: inboxJSON([], extra: #""delta":true,"cursor":"5","agedOut":["a"],"hasMore":true,"nextBefore":"n""#))
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: RelayAuth(pairing: try #require(try makePairedStore().loadPairing())))

        let result = try await source.fetchEmails(folder: "INBOX", from: 0, to: 50, since: "4")

        #expect(result.agedOutIds == ["a"])
        #expect(result.hasMore)
        #expect(result.nextBefore == "n")
    }

    @Test func anOlderRelayReportsNoOverflow() async throws {
        let client = stubClient(json: inboxJSON([], extra: #""delta":true,"cursor":"5""#))
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: RelayAuth(pairing: try #require(try makePairedStore().loadPairing())))

        let result = try await source.fetchEmails(folder: "INBOX", from: 0, to: 50, since: "4")
        let page = try await source.fetchOlder(folder: "INBOX", limit: 50, before: "x")

        #expect(result.agedOutIds.isEmpty)
        #expect(!result.hasMore)
        #expect(page.hasMore == nil)
    }

    @Test func aV7StoreMigratesWithEveryRowInTheWindow() async throws {
        let url = URL.temporaryDirectory.appending(path: "window-migration-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        do {
            let v7 = Schema(versionedSchema: AppSchemaV7.self)
            let container = try ModelContainer(for: v7, configurations: [ModelConfiguration(schema: v7, url: url)])
            let context = ModelContext(container)
            context.insert(AppSchemaV7.EmailEntity(
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
        let stored = try #require(try await EmailDAO(modelContainer: container).getEmail(folder: "INBOX", serverId: "42"))

        #expect(stored.inWindow)
        #expect(stored.body == "kept")
    }
}
