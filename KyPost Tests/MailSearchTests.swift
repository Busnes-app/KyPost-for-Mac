//
//  MailSearchTests.swift
//  KyPost Tests
//
//  Server-side search of the folder on screen (KyPost-for-Android #171 and
//  its follow-ups; KyPost-Server `handleMailSearch`): the request, the
//  stale-result guards, results that never touch the cache, and actions and
//  opening that address the searched folder.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - A scriptable relay

/// The folder listing, search, actions and body endpoints. A search can be
/// held at a gate so a test can supersede it before it answers.
nonisolated final class SearchRelay: @unchecked Sendable {
    typealias Answer = @Sendable ([String: String]) -> (Int, String)

    let queries = Box<[[String: String]]>([])
    let folders = Box<[String: String]>([:])
    let search = Box<Answer>({ _ in (200, #"{"results":[]}"#) })
    /// Searches for these queries wait until the gate opens.
    let gated = Box<Set<String>>([])
    let actionCount = Box(0)
    let actionMailbox = Box("")

    var client: HTTPClient {
        HTTPClient { [self] request in
            let url = request.url!
            var query: [String: String] = ["path": url.path]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
            queries.mutate { $0.append(query) }
            var answer: (Int, String)
            switch url.path {
            case "/api/inbox":
                answer = (200, folders.value[query["mailbox"] ?? ""] ?? #"{"byTab":{}}"#)
            case "/api/mail/search":
                while gated.value.contains(query["q"] ?? "") {
                    try await Task.sleep(for: .milliseconds(5))
                }
                answer = search.value(query)
            case "/api/inbox/actions":
                actionCount.mutate { $0 += 1 }
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                actionMailbox.value = body?["mailbox"] as? String ?? ""
                let ids = body?["messageIds"] as? [String] ?? []
                answer = (200, #"{"ok":true,"processed":\#(ids.count),"failed":[]}"#)
            case "/api/mail/body":
                answer = (200, #"{"body":"fetched body","bodyMode":"plain"}"#)
            default:
                answer = (404, "")
            }
            let response = HTTPURLResponse(url: url, statusCode: answer.0, httpVersion: nil, headerFields: nil)!
            return (Data(answer.1.utf8), response)
        }
    }

    var searchQueries: [[String: String]] { queries.value.filter { $0["path"] == "/api/mail/search" } }
}

nonisolated private func results(_ ids: [String]) -> String {
    let rows = ids.map {
        #"{"messageId":"\#($0)","subject":"Found \#($0)","sender":"Ada <ada@example.com>","sentTo":"me@example.com, bo@example.com","cc":"cy@example.com","label":"Work","status":"unread","atUtc":"2026-10-01T10:00:00Z"}"#
    }
    return #"{"results":[\#(rows.joined(separator: ","))]}"#
}

nonisolated private func folder(_ ids: [String]) -> String {
    let rows = ids.map { #"{"messageId":"\#($0)","subject":"\#($0)","body":"b","atUtc":"2026-10-02T10:00:00Z"}"# }
    return #"{"byTab":{"Personal":[\#(rows.joined(separator: ","))]}}"#
}

@MainActor
private func makeInbox(_ relay: SearchRelay) throws -> (InboxViewModel, EmailDAO) {
    let dao = EmailDAO(modelContainer: try AppDatabase(inMemory: true).container)
    let viewModel = InboxViewModel(
        mailRepository: MailRepository(
            securePairingStore: try makePairedStore(),
            emailDAO: dao,
            httpClient: relay.client
        ),
        keywordRepository: KeywordRepository(
            settingsStore: KeywordSettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        ),
        undoWindow: .milliseconds(100)
    )
    return (viewModel, dao)
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: - The request

@Suite struct MailSearchRequestTests {
    private func source(_ client: HTTPClient) throws -> RelayMailSource {
        RelayMailSource(
            httpClient: client, serverUrl: server,
            auth: RelayAuth(pairing: try #require(try makePairedStore().loadPairing()))
        )
    }

    @Test func searchesOneFolderEveryFieldWithThisDevicesCredentials() async throws {
        let seen = Box<URLRequest?>(nil)
        let client = stubClient(json: #"{"results":[]}"#) { seen.value = $0 }

        _ = try await source(client).searchMail(folder: "INBOX/Receipts", query: "invoice & co", limit: 50)

        let request = try #require(seen.value)
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/mail/search")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == ["q": "invoice & co", "mailbox": "INBOX/Receipts", "limit": "50"])
        #expect(items["field"] == nil)
        #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") != nil)
        #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") != nil)
    }

    @Test func resultsAreStampedWithTheSearchedFolderAndCarryNoBody() async throws {
        let found = try await source(stubClient(json: results(["7"])))
            .searchMail(folder: "Archive", query: "x", limit: 50)

        let email = try #require(found.first)
        #expect(email.folder == "Archive")
        #expect(email.id == MailRowKey(folder: "Archive", serverId: "7"))
        #expect(email.keywords.contains("Work"))
        #expect(email.senderEmail == "ada@example.com")
        #expect(email.sentTo == "me@example.com, bo@example.com")
        #expect(email.cc == "cy@example.com")
        #expect(email.body.isEmpty)
        #expect(MailRepository.needsBodyFetch(email))
    }

    @Test(arguments: [
        (503, "search failed: imap down", "The server is temporarily unavailable."),
        (400, "q parameter is required", "q parameter is required"),
        (401, "", "Not authorized — re-pair the device or check credentials."),
        (200, "<html>", "Malformed search response"),
        (200, "{}", "Malformed search response"),
    ])
    func failuresUseTheRelayMapping(status: Int, body: String, message: String) async throws {
        do {
            _ = try await source(stubClient(status: status, json: body))
                .searchMail(folder: "INBOX", query: "x", limit: 50)
            Issue.record("expected a failure")
        } catch {
            #expect(MailOutcome.from(error).userMessage == message)
        }
    }

    @Test func resultsAreNeverWrittenToTheCacheAndTheQueryIsTrimmed() async throws {
        let relay = SearchRelay()
        relay.search.value = { _ in (200, results(["1", "2"])) }
        let dao = EmailDAO(modelContainer: try AppDatabase(inMemory: true).container)
        let repository = MailRepository(securePairingStore: try makePairedStore(), emailDAO: dao, httpClient: relay.client)

        let found = try await repository.search("  report \n", in: "INBOX")

        #expect(found.map(\.serverId) == ["1", "2"])
        #expect(relay.searchQueries.first?["q"] == "report")
        #expect(relay.searchQueries.first?["limit"] == "50")
        #expect(try await dao.getFolder(folder: "INBOX").isEmpty)
    }
}

// MARK: - The list

@Suite struct InboxSearchTests {
    @Test @MainActor func resultsReplaceTheListUntilTheSearchEnds() async throws {
        let relay = SearchRelay()
        relay.folders.value = ["INBOX": folder(["a", "b"])]
        relay.search.value = { _ in (200, results(["7"])) }
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.load()
        #expect(viewModel.showsTabStrip)
        #expect(viewModel.showsLoadOlder)
        let selectionResets = viewModel.selectionResetRequest

        await viewModel.submitSearch("found")

        #expect(viewModel.filteredEmails.map(\.serverId) == ["7"])
        #expect(!viewModel.showsTabStrip)
        #expect(!viewModel.showsLoadOlder)
        #expect(viewModel.newMailCount == 0)
        // Starting the search and its results landing each end the selection.
        #expect(viewModel.selectionResetRequest == selectionResets + 2)

        viewModel.endSearch()

        #expect(Set(viewModel.filteredEmails.map(\.serverId)) == ["a", "b"])
        #expect(viewModel.showsTabStrip)
    }

    @Test @MainActor func aBlankQueryIsIgnored() async throws {
        let relay = SearchRelay()
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.submitSearch("   ")
        #expect(relay.searchQueries.isEmpty)
        #expect(!viewModel.isSearchActive)
    }

    @Test @MainActor func noResultsSaysSoInsteadOfCallingTheFolderEmpty() async throws {
        let relay = SearchRelay()
        relay.folders.value = ["INBOX": folder(["a"])]
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.load()

        await viewModel.submitSearch("nothing")

        #expect(viewModel.filteredEmails.isEmpty)
        #expect(viewModel.showsEmptyFolderState)
        #expect(viewModel.emptyFolderMessage == "No matching messages")
    }

    @Test @MainActor func resultsForASupersededQueryNeverLand() async throws {
        let relay = SearchRelay()
        relay.search.value = { query in (200, results([query["q"] == "old" ? "old-hit" : "new-hit"])) }
        relay.gated.value = ["old"]
        let (viewModel, _) = try makeInbox(relay)

        let first = Task { await viewModel.submitSearch("old") }
        #expect(await eventually { relay.searchQueries.count == 1 })
        await viewModel.submitSearch("new")
        relay.gated.value = []
        await first.value

        #expect(viewModel.searchQuery == "new")
        #expect(viewModel.filteredEmails.map(\.serverId) == ["new-hit"])
    }

    @Test @MainActor func resultsForAFolderNoLongerOnScreenNeverLand() async throws {
        let relay = SearchRelay()
        relay.folders.value = ["Junk": folder(["j"])]
        relay.search.value = { _ in (200, results(["7"])) }
        relay.gated.value = ["slow"]
        let (viewModel, _) = try makeInbox(relay)

        let search = Task { await viewModel.submitSearch("slow") }
        #expect(await eventually { relay.searchQueries.count == 1 })
        let dismissals = viewModel.searchDismissRequest
        await viewModel.selectFolder("Junk")
        relay.gated.value = []
        await search.value

        #expect(!viewModel.isSearchActive)
        #expect(viewModel.searchDismissRequest == dismissals + 1)
        #expect(viewModel.filteredEmails.map(\.serverId) == ["j"])
    }

    /// A failure must not leave an earlier query's results under this one.
    @Test @MainActor func aFailedSearchSaysWhyAndRestoresTheFolderList() async throws {
        let relay = SearchRelay()
        relay.folders.value = ["INBOX": folder(["a"])]
        relay.search.value = { query in
            query["q"] == "works" ? (200, results(["7"])) : (503, "search failed")
        }
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.load()
        await viewModel.submitSearch("works")
        #expect(viewModel.filteredEmails.map(\.serverId) == ["7"])

        await viewModel.submitSearch("breaks")

        #expect(viewModel.filteredEmails.map(\.serverId) == ["a"])
        #expect(viewModel.notice == "The server is temporarily unavailable.")
    }

    @Test @MainActor func editingTheTextAwayFromTheSubmittedQueryEndsTheSearch() async throws {
        let relay = SearchRelay()
        relay.search.value = { _ in (200, results(["7"])) }
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.submitSearch("invoice")

        viewModel.searchTextChanged("invoice ")
        #expect(viewModel.isSearchActive)

        viewModel.searchTextChanged("invoices")
        #expect(!viewModel.isSearchActive)
        #expect(viewModel.searchResults == nil)
    }

    @Test @MainActor func aNotificationTapEndsTheSearch() async throws {
        let relay = SearchRelay()
        relay.folders.value = ["INBOX": folder(["42"])]
        relay.search.value = { _ in (200, results(["7"])) }
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.load()
        await viewModel.submitSearch("x")

        let target = await viewModel.prepareForPushTap(messageId: "42")

        #expect(target?.serverId == "42")
        #expect(!viewModel.isSearchActive)
    }

    /// Held rows are hidden by (folder, id) in results exactly as in the
    /// folder, and a confirmed action takes the row out of the results.
    @Test @MainActor func listActionsOnResultsAddressTheSearchedFolder() async throws {
        let relay = SearchRelay()
        relay.search.value = { _ in (200, results(["7", "8"])) }
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.selectFolder("Archive")
        await viewModel.submitSearch("x")

        viewModel.archive(serverIds: ["7"])
        #expect(viewModel.filteredEmails.map(\.serverId) == ["8"])

        #expect(await eventually { relay.actionCount.value == 1 && viewModel.undoMessage == nil })
        #expect(await eventually { viewModel.searchResults?.map(\.serverId) == ["8"] })
        #expect(relay.actionMailbox.value == "Archive")
    }

    @Test @MainActor func anOpenedResultRemovedFromTheReaderLeavesTheResults() async throws {
        let relay = SearchRelay()
        relay.search.value = { _ in (200, results(["7", "8"])) }
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.submitSearch("x")
        let opened = try #require(viewModel.searchResults?.first)

        let failure = await viewModel.performNow(.delete, on: opened)

        #expect(failure == nil)
        #expect(viewModel.searchResults?.map(\.serverId) == ["8"])
    }

    @Test @MainActor func leavingTheAccountForgetsTheSearch() async throws {
        let relay = SearchRelay()
        relay.search.value = { _ in (200, results(["7"])) }
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.submitSearch("secret")

        viewModel.forgetAccount()

        #expect(viewModel.searchQuery == nil)
        #expect(viewModel.searchResults == nil)
    }

    /// A search still in flight when the account is forgotten answers with
    /// the forgotten account's mail: it never lands.
    @Test @MainActor func aSearchInFlightAcrossLeavingTheAccountNeverLands() async throws {
        let relay = SearchRelay()
        relay.search.value = { _ in (200, results(["7"])) }
        relay.gated.value = ["slow"]
        let (viewModel, _) = try makeInbox(relay)

        let search = Task { await viewModel.submitSearch("slow") }
        #expect(await eventually { relay.searchQueries.count == 1 })
        viewModel.forgetAccount()
        relay.gated.value = []
        await search.value

        #expect(viewModel.searchQuery == nil)
        #expect(viewModel.searchResults == nil)
        #expect(!viewModel.isSearchInFlight)
        #expect(!viewModel.filteredEmails.contains { $0.serverId == "7" })
    }
}

// MARK: - Opening a result

@Suite struct SearchResultOpeningTests {
    @Test @MainActor func anUncachedResultFetchesItsBodyAndIsNeverCached() async throws {
        let relay = SearchRelay()
        relay.search.value = { _ in (200, results(["7"])) }
        let (viewModel, dao) = try makeInbox(relay)
        await viewModel.submitSearch("x")
        let result = try #require(viewModel.searchResults?.first)

        let body = try await viewModel.loadBody(for: result)

        #expect(body == MailMessageBody(body: "fetched body", bodyMode: "plain"))
        let fetch = try #require(relay.queries.value.last)
        #expect(fetch["path"] == "/api/mail/body")
        #expect(fetch["mailbox"] == "INBOX")
        #expect(fetch["messageId"] == "7")
        #expect(try await dao.getEmail(folder: "INBOX", serverId: "7") == nil)
    }

    @Test @MainActor func aResultAlreadyCachedOpensFromTheCache() async throws {
        let relay = SearchRelay()
        relay.folders.value = ["INBOX": folder(["7"])]
        relay.search.value = { _ in (200, results(["7"])) }
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.load()
        await viewModel.submitSearch("x")
        let result = try #require(viewModel.searchResults?.first)

        let body = try await viewModel.loadBody(for: result)

        #expect(body?.body == "b")
        #expect(!relay.queries.value.contains { $0["path"] == "/api/mail/body" })
    }

    /// The result's own To/Cc are the only copy for an uncached message.
    @Test func replyAllToAResultKeepsItsRecipients() async throws {
        let found = try await RelayMailSource(
            httpClient: stubClient(json: results(["7"])), serverUrl: server,
            auth: RelayAuth(pairing: try #require(try makePairedStore().loadPairing()))
        ).searchMail(folder: "INBOX", query: "x", limit: 50)

        let draft = ComposeDraft.replyAll(to: try #require(found.first), ownAddresses: ["me@example.com"])

        #expect(draft.to == "ada@example.com")
        #expect(draft.cc == "bo@example.com, cy@example.com")
    }
}

// MARK: - Review fixes

@Suite struct SearchReviewFixTests {
    /// A folder refresh while a search is pending must not leave a new-mail
    /// pill over the results.
    @Test @MainActor func aRefreshDuringASearchNeverRaisesTheNewMailPill() async throws {
        let relay = SearchRelay()
        relay.folders.value = ["INBOX": folder(["1"])]
        relay.search.value = { _ in (200, results(["7"])) }
        relay.gated.value = ["x"]
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.load()
        viewModel.listScrolled(atTop: false)

        let search = Task { await viewModel.submitSearch("x") }
        #expect(await eventually { relay.searchQueries.count == 1 })
        relay.folders.value = ["INBOX": #"{"byTab":{"Personal":[{"messageId":"2","subject":"2","body":"b","atUtc":"2026-10-03T10:00:00Z"},{"messageId":"1","subject":"1","body":"b","atUtc":"2026-10-02T10:00:00Z"}]}}"#]
        await viewModel.refresh()
        #expect(viewModel.emails.map(\.serverId) == ["2", "1"])
        relay.gated.value = []
        await search.value

        #expect(viewModel.searchResults?.map(\.serverId) == ["7"])
        #expect(viewModel.newMailCount == 0)
    }

    /// A pop-out reader resolves through `email(for:)`; a cached row without
    /// recipients must not cost the result its To/Cc.
    @Test @MainActor func aPopOutOfACachedResultKeepsTheResultsRecipients() async throws {
        let relay = SearchRelay()
        relay.folders.value = ["INBOX": #"{"byTab":{"Personal":[{"messageId":"7","subject":"s","sender":"Ada <ada@example.com>","body":"b","atUtc":"2026-10-02T10:00:00Z"}]}}"#]
        relay.search.value = { _ in (200, results(["7"])) }
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.load()
        #expect(viewModel.emails.first?.sentTo == "")
        #expect(viewModel.emails.first?.cc == "")
        await viewModel.submitSearch("x")

        let resolved = try #require(viewModel.email(for: MailRowKey(folder: "INBOX", serverId: "7")))
        let draft = ComposeDraft.replyAll(to: resolved, ownAddresses: ["me@example.com"])

        #expect(resolved.body == "b")
        #expect(draft.to == "ada@example.com")
        #expect(draft.cc == "bo@example.com, cy@example.com")
    }

    /// Opening a result that is cached keeps the cached OpenPGP state, so an
    /// unverified signature is still reported as such.
    @Test @MainActor func aCachedResultKeepsItsSignatureState() async throws {
        let relay = SearchRelay()
        relay.folders.value = ["INBOX": #"{"byTab":{"Personal":[{"messageId":"7","subject":"s","body":"server plaintext","atUtc":"2026-10-02T10:00:00Z","pgpEncrypted":true,"pgpSigned":true,"pgpVerified":false}]}}"#]
        relay.search.value = { _ in (200, results(["7"])) }
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.load()
        await viewModel.submitSearch("x")
        let result = try #require(viewModel.searchResults?.first)
        #expect(!result.pgpEncrypted && !result.pgpSigned)

        let body = try #require(try await viewModel.loadBody(for: result))
        let shown = body.applied(to: result)
        let state = pgpMessageState(
            pgpEncrypted: shown.pgpEncrypted, pgpDecryptError: shown.pgpDecryptError, body: shown.body
        )

        #expect(shown.body == "server plaintext")
        #expect(state == .decryptedByServer)
        #expect(showsSignaturePill(state: state, signed: shown.pgpSigned))
        #expect(!shown.pgpVerified)
    }

    /// A cached client-protected row (encrypted, no body) opened from the
    /// results stays client-protected rather than fetching the server's body.
    @Test @MainActor func aCachedClientProtectedResultStaysClientProtected() async throws {
        let relay = SearchRelay()
        relay.folders.value = ["INBOX": #"{"byTab":{"Personal":[{"messageId":"7","subject":"s","body":"","atUtc":"2026-10-02T10:00:00Z","pgpEncrypted":true}]}}"#]
        relay.search.value = { _ in (200, results(["7"])) }
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.load()
        await viewModel.submitSearch("x")
        let result = try #require(viewModel.searchResults?.first)

        let shown = try #require(try await viewModel.loadBody(for: result)).applied(to: result)

        #expect(pgpMessageState(
            pgpEncrypted: shown.pgpEncrypted, pgpDecryptError: shown.pgpDecryptError, body: shown.body
        ) == .clientProtected)
        #expect(!relay.queries.value.contains { $0["path"] == "/api/mail/body" })
    }
}
