//
//  InboxParityTests.swift
//  KyPost Tests
//
//  The inbox-list rules ported from Android (#107, #120, #147, #150, #169,
//  #170, #173, #174, #175): freshness, row dates, the empty-folder gate,
//  Sent/Drafts resolution, move targets, relay-confirmed bulk actions, the
//  undo window, and new-mail announcements.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - A scriptable relay

/// Answers the three inbox endpoints from scripted state and records every
/// action request, so a test can assert both what the list shows and what —
/// if anything — reached the relay.
nonisolated final class FakeInboxRelay: @unchecked Sendable {
    /// mailbox → message ids, newest first.
    let mailboxes = Box<[String: [String]]>([:])
    /// parent ("" = top level) → folder paths.
    let folders = Box<[String: [String]]>([:])
    /// Every POST /api/inbox/actions body, decoded.
    let actions = Box<[[String: Any]]>([])
    /// Every GET /api/inbox query, as (mailbox, since).
    let inboxRequests = Box<[(String, String)]>([])
    /// Answer for an action request; defaults to "every id processed".
    let actionReply = Box<(@Sendable ([String]) -> (Int, String))?>(nil)
    let inboxFails = Box(false)
    /// Awaited before answering a request, so a test can hold one open.
    let gate = Box<(@Sendable (URLRequest) async -> Void)?>(nil)

    var client: HTTPClient {
        HTTPClient { [self] request in
            if let gate = gate.value { await gate(request) }
            return try handle(request)
        }
    }

    private func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        func reply(_ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        switch url.path {
        case "/api/inbox/actions":
            let object = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            actions.mutate { $0.append(object) }
            let ids = object["messageIds"] as? [String] ?? []
            if let script = actionReply.value {
                let (status, body) = script(ids)
                return reply(status, body)
            }
            return reply(200, #"{"ok":true,"processed":\#(ids.count),"failed":[]}"#)
        case "/api/inbox/folders":
            let paths = folders.value[value("parent") ?? ""] ?? []
            let list = paths.map { #"{"path":"\#($0)"}"# }.joined(separator: ",")
            return reply(200, #"{"folders":[\#(list)]}"#)
        case "/api/inbox":
            let mailbox = value("mailbox") ?? ""
            inboxRequests.mutate { $0.append((mailbox, value("since") ?? "")) }
            if inboxFails.value { throw URLError(.timedOut) }
            let ids = mailboxes.value[mailbox] ?? []
            // Newest first: each id is one minute older than the last.
            let rows = ids.enumerated().map { index, id in
                let date = Date(timeIntervalSince1970: 1_790_000_000 - Double(index) * 60)
                let stamp = ISO8601DateFormatter().string(from: date)
                return #"{"messageId":"\#(id)","subject":"\#(id)","atUtc":"\#(stamp)"}"#
            }.joined(separator: ",")
            return reply(200, #"{"byTab":{"":[\#(rows)]}}"#)
        default:
            return reply(404, "")
        }
    }

    var actionCount: Int { actions.value.count }
}

/// Holds requests until released; records whether any is waiting.
nonisolated final class RequestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            entered += 1
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered > 0 }

    func release() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private func makeInbox(
    relay: FakeInboxRelay,
    undoWindow: Duration = .milliseconds(150),
    pushTapRefreshWait: Duration = .seconds(30),
    appliesAllTabSetting: Bool = true,
    defaults: UserDefaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
) throws -> (InboxViewModel, EmailDAO) {
    let db = try AppDatabase(inMemory: true)
    let dao = EmailDAO(modelContainer: db.container)
    let repository = MailRepository(
        securePairingStore: try makePairedStore(),
        emailDAO: dao,
        httpClient: relay.client
    )
    let viewModel = InboxViewModel(
        mailRepository: repository,
        keywordRepository: KeywordRepository(settingsStore: KeywordSettingsStore(defaults: defaults)),
        undoWindow: undoWindow,
        pushTapRefreshWait: pushTapRefreshWait,
        appliesAllTabSetting: appliesAllTabSetting
    )
    return (viewModel, dao)
}

/// Polls instead of sleeping a fixed span: the work lands a scheduling hop
/// later even when it is immediate.
@MainActor
private func eventually(
    timeout: Duration = .seconds(3),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func ids(_ emails: [Email]) -> [String] { emails.map(\.serverId) }

// MARK: - Sent / Drafts resolution (#170)

@Suite struct SpecialFolderTests {
    @Test func resolvesTheFirstAliasInTheServersPreferenceOrder() {
        #expect(InboxRules.resolveSpecialFolder(.sent, in: ["Junk", "Sent Items", "Sent"]) == "Sent")
        #expect(InboxRules.resolveSpecialFolder(.sent, in: ["Sent Mail", "Sent Messages"]) == "Sent Messages")
        #expect(InboxRules.resolveSpecialFolder(.drafts, in: ["Draft", "Trash"]) == "Draft")
    }

    @Test func matchesTheLeafCaseInsensitivelyIncludingDovecotPaths() {
        #expect(InboxRules.resolveSpecialFolder(.sent, in: ["INBOX.Sent"]) == "INBOX.Sent")
        #expect(InboxRules.resolveSpecialFolder(.drafts, in: ["drafts"]) == "drafts")
        #expect(InboxRules.resolveSpecialFolder(.sent, in: ["SENT ITEMS"]) == "SENT ITEMS")
    }

    @Test func neverGuessesALookalikeOrAMissingFolder() {
        #expect(InboxRules.resolveSpecialFolder(.sent, in: ["Unsent", "Sentinel", "Gesendet"]) == nil)
        #expect(InboxRules.resolveSpecialFolder(.drafts, in: ["Draftsmanship"]) == nil)
        #expect(InboxRules.resolveSpecialFolder(.sent, in: []) == nil)
    }

    @Test func archivedCopiesBelongToArchive() {
        #expect(InboxRules.resolveSpecialFolder(.sent, in: ["Archive/Sent"]) == nil)
        #expect(InboxRules.resolveSpecialFolder(.drafts, in: ["Archive.Drafts", "Drafts"]) == "Drafts")
        #expect(InboxRules.specialFolder(of: "Archive/Sent") == nil)
        #expect(InboxRules.specialFolder(of: "Sent Items") == .sent)
        #expect(InboxRules.specialFolder(of: "drafts") == .drafts)
        #expect(InboxRules.specialFolder(of: "INBOX") == nil)
        #expect(InboxRules.specialFolder(of: "Junk") == nil)
    }

    @Test @MainActor func openingSentResolvesTheAccountsRealPath() async throws {
        let relay = FakeInboxRelay()
        relay.folders.value = ["": ["Junk", "Sent Items", "Trash"]]
        relay.mailboxes.value = ["Sent Items": ["s1"]]
        let (viewModel, _) = try makeInbox(relay: relay)

        #expect(await viewModel.openSpecialFolder(.sent))
        #expect(viewModel.folder == "Sent Items")
        #expect(viewModel.folderDisplayName == "Sent")
        #expect(ids(viewModel.emails) == ["s1"])
    }

    @Test @MainActor func aMissingDraftsFolderIsReportedAndNothingIsOpened() async throws {
        let relay = FakeInboxRelay()
        relay.folders.value = ["": ["Junk", "Trash"]]
        let (viewModel, _) = try makeInbox(relay: relay)

        #expect(await viewModel.openSpecialFolder(.drafts) == false)
        #expect(viewModel.folder == StandardFolder.inbox)
        #expect(viewModel.notice == "No Drafts folder on this account")
        // Nothing was created: only the listing was asked for.
        #expect(relay.actionCount == 0)
    }

    @Test @MainActor func aSentListingThatAnswersAfterANewerPickIsDiscarded() async throws {
        let relay = FakeInboxRelay()
        relay.folders.value = ["": ["Junk", "Sent", "Trash"]]
        relay.mailboxes.value = ["Sent": ["s1"], "Junk": ["j1"]]
        let latch = RequestLatch()
        relay.gate.value = { request in
            if request.url?.path == "/api/inbox/folders" { await latch.wait() }
        }
        let (viewModel, _) = try makeInbox(relay: relay)

        let sent = Task { await viewModel.openSpecialFolder(.sent) }
        #expect(await eventually { latch.hasEntered })
        await viewModel.selectFolder("Junk")
        latch.release()

        #expect(await sent.value == false)
        #expect(viewModel.folder == "Junk")
        #expect(ids(viewModel.emails) == ["j1"])
        #expect(!relay.inboxRequests.value.contains { $0.0 == "Sent" })
        #expect(viewModel.notice == nil)
    }
}

// MARK: - Move targets (#173)

@Suite struct MoveTargetTests {
    @Test func inboxTopLevelAndArchiveChildrenDedupedMinusTheOwnFolder() {
        let targets = InboxRules.moveTargets(
            current: "Junk",
            inboxChildren: ["INBOX/Receipts"],
            topLevel: ["junk", "Sent", "inbox", "Work"],
            archiveChildren: ["Archive/2025", "work"]
        )
        #expect(targets == ["INBOX", "INBOX/Receipts", "Sent", "Work", "Archive/2025"])
    }

    @Test func archiveItselfIsNeverATarget() {
        let targets = InboxRules.moveTargets(
            current: "INBOX", inboxChildren: [], topLevel: ["Archive", "Trash"], archiveChildren: []
        )
        #expect(targets == ["Trash"])
    }
}

// MARK: - Row date, freshness, empty state (#107, #169)

@Suite struct InboxRowStateTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private let locale = Locale(identifier: "en_US")

    @Test func todayShowsATimeAndEarlierDaysAMediumDate() throws {
        let calendar = calendar
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15)))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9, minute: 5)))
        let lastWeek = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9)))

        #expect(InboxRules.rowDate(morning, now: now, calendar: calendar, locale: locale).hasPrefix("9:05"))
        #expect(InboxRules.rowDate(lastWeek, now: now, calendar: calendar, locale: locale) == "Oct 3, 2026")
    }

    @Test func aRowRelabelsOnceTheDayChanges() throws {
        let calendar = calendar
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 23, minute: 50)))
        let afterMidnight = evening.addingTimeInterval(20 * 60)

        #expect(InboxRules.rowDate(evening, now: evening, calendar: calendar, locale: locale).hasPrefix("11:50"))
        #expect(InboxRules.rowDate(evening, now: afterMidnight, calendar: calendar, locale: locale) == "Oct 11, 2026")
    }

    @Test func aMissingDateIsBlankNeverNow() throws {
        #expect(InboxRules.rowDate(Email.unknownDate, now: Date(), calendar: calendar, locale: locale) == "")
        let dto = RelayEmailDTO(messageId: "1", atUtc: "not a date")
        let email = dto.toDomain(folder: "INBOX", tab: "")
        #expect(!Email.isKnownDate(email.receivedAt))
        let undated = RelayEmailDTO(messageId: "2").toDomain(folder: "INBOX", tab: "")
        #expect(!Email.isKnownDate(undated.receivedAt))
    }

    @Test func freshnessHasAPlaceholderBeforeTheFirstSuccess() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(InboxRules.freshnessText(refreshedAt: nil, now: now, locale: locale) == "Not updated yet")
        #expect(InboxRules.freshnessText(refreshedAt: now.addingTimeInterval(-20), now: now, locale: locale) == "Updated just now")
        let older = InboxRules.freshnessText(refreshedAt: now.addingTimeInterval(-300), now: now, locale: locale)
        #expect(older.hasPrefix("Updated"))
        #expect(older.contains("5 minutes"))
    }

    @Test func emptyOnlyOnceTheFolderOnScreenRefreshed() {
        #expect(InboxRules.showsEmptyFolder(shown: 0, loadedFolder: "INBOX", currentFolder: "INBOX"))
        #expect(!InboxRules.showsEmptyFolder(shown: 0, loadedFolder: nil, currentFolder: "INBOX"))
        #expect(!InboxRules.showsEmptyFolder(shown: 0, loadedFolder: "Junk", currentFolder: "INBOX"))
        #expect(!InboxRules.showsEmptyFolder(shown: 2, loadedFolder: "INBOX", currentFolder: "INBOX"))
    }

    @Test @MainActor func aFailedFolderWithAnEmptyCacheNeverReadsAsEmpty() async throws {
        let relay = FakeInboxRelay()
        relay.inboxFails.value = true
        let (viewModel, _) = try makeInbox(relay: relay)

        await viewModel.refresh()
        #expect(viewModel.filteredEmails.isEmpty)
        #expect(!viewModel.showsEmptyFolderState)
        #expect(viewModel.lastRefreshed == nil)

        relay.inboxFails.value = false
        await viewModel.refresh()
        #expect(viewModel.showsEmptyFolderState)
        #expect(viewModel.emptyFolderMessage == "No messages in Inbox")
        #expect(viewModel.lastRefreshed != nil)

        // A later failure un-confirms it again, but keeps the freshness stamp.
        relay.inboxFails.value = true
        await viewModel.refresh()
        #expect(!viewModel.showsEmptyFolderState)
        #expect(viewModel.lastRefreshed != nil)
    }

    @Test @MainActor func freshnessIsPerFolder() async throws {
        let relay = FakeInboxRelay()
        let (viewModel, _) = try makeInbox(relay: relay)
        await viewModel.refresh()
        #expect(viewModel.lastRefreshed != nil)

        relay.inboxFails.value = true
        await viewModel.selectFolder("Junk")
        #expect(viewModel.lastRefreshed == nil)
        #expect(!viewModel.showsEmptyFolderState)
    }
}

// MARK: - All tab (#120)

@Suite struct AllTabTests {
    @MainActor
    private func loaded(allVisible: Bool, hidden: [String] = [], applies: Bool = true) async throws -> InboxViewModel {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = KeywordSettingsStore(defaults: defaults)
        store.allTabVisible = allVisible
        for keyword in hidden { store.setVisible(false, for: keyword) }
        let json = #"{"byTab":{"Work":[{"messageId":"1"}],"News":[{"messageId":"2"}],"":[{"messageId":"3"}]}}"#
        let client = stubClient(json: json)
        let db = try AppDatabase(inMemory: true)
        let viewModel = InboxViewModel(
            mailRepository: MailRepository(
                securePairingStore: try makePairedStore(),
                emailDAO: EmailDAO(modelContainer: db.container),
                httpClient: client
            ),
            keywordRepository: KeywordRepository(settingsStore: store),
            appliesAllTabSetting: applies
        )
        await viewModel.load()
        return viewModel
    }

    @Test @MainActor func allIsVisibleByDefault() async throws {
        let viewModel = try await loaded(allVisible: true)
        #expect(viewModel.showsAllTab)
        #expect(viewModel.selectedTab == nil)
        #expect(viewModel.filteredEmails.count == 3)
    }

    @Test @MainActor func hidingAllFallsBackToTheFirstVisibleTab() async throws {
        let viewModel = try await loaded(allVisible: false)
        #expect(!viewModel.showsAllTab)
        #expect(viewModel.showsTabStrip)
        #expect(viewModel.selectedTab == "News")
        #expect(ids(viewModel.filteredEmails) == ["2"])
    }

    @Test @MainActor func everythingHiddenShowsEverythingWithNoStrip() async throws {
        let viewModel = try await loaded(allVisible: false, hidden: ["Work", "News"])
        #expect(!viewModel.showsTabStrip)
        #expect(viewModel.selectedTab == nil)
        #expect(viewModel.filteredEmails.count == 3)
    }

    @Test @MainActor func theMacSidebarIgnoresTheSetting() async throws {
        let viewModel = try await loaded(allVisible: false, applies: false)
        #expect(viewModel.selectedTab == nil)
        #expect(viewModel.filteredEmails.count == 3)
    }

    @Test func aRelayLabelSpeltAllIsNotASecondAllTab() {
        let repository = KeywordRepository(
            settingsStore: KeywordSettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        )
        let email = Email(
            serverId: "1", folder: "INBOX", senderName: "", senderEmail: "", subject: "", body: "",
            keywords: ["all", "Work", "$Phishing"], receivedAt: Date(), read: false, starred: false
        )
        #expect(repository.visibleTabs(from: [email]).map(\.name) == ["Work"])
    }
}

// MARK: - New mail (#147)

@Suite struct NewMailTests {
    private func email(_ id: String) -> Email {
        Email(
            serverId: id, folder: "INBOX", senderName: "", senderEmail: "", subject: "", body: "",
            keywords: [], receivedAt: Date(), read: false, starred: false
        )
    }

    @Test func countsRowsAboveTheOldTop() {
        let old = ["c", "d"].map(email)
        #expect(InboxRules.newRowsAbove(old: old, new: ["a", "b", "c", "d"].map(email)) == 2)
        #expect(InboxRules.newRowsAbove(old: old, new: ["c", "d"].map(email)) == 0)
        #expect(InboxRules.newRowsAbove(old: [], new: ["a"].map(email)) == 0)
        // The old top left: everything before the first survivor counts.
        #expect(InboxRules.newRowsAbove(old: old, new: ["a", "d"].map(email)) == 1)
    }

    @Test @MainActor func atTheTopNewRowsAreScrolledToScrolledAwayTheyAreCounted() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["c"]]
        let (viewModel, _) = try makeInbox(relay: relay)
        await viewModel.load()
        // A first paint announces nothing.
        #expect(viewModel.newMailCount == 0)
        #expect(viewModel.scrollToTopRequest == 0)

        relay.mailboxes.value = ["INBOX": ["b", "c"]]
        await viewModel.refresh()
        #expect(viewModel.scrollToTopRequest == 1)
        #expect(viewModel.newMailCount == 0)

        viewModel.listScrolled(atTop: false)
        relay.mailboxes.value = ["INBOX": ["a", "b", "c"]]
        await viewModel.refresh()
        relay.mailboxes.value = ["INBOX": ["z", "y", "a", "b", "c"]]
        await viewModel.refresh()
        #expect(viewModel.newMailCount == 3)

        viewModel.listScrolled(atTop: true)
        #expect(viewModel.newMailCount == 0)
    }

    @Test @MainActor func aFolderSwitchNeverAnnounces() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["a"], "Junk": ["j1", "j2"]]
        let (viewModel, _) = try makeInbox(relay: relay)
        await viewModel.load()
        viewModel.listScrolled(atTop: false)
        await viewModel.selectFolder("Junk")
        #expect(viewModel.newMailCount == 0)
        #expect(viewModel.scrollToTopRequest == 0)
    }

    @Test @MainActor func aPushTapSwitchesToInboxAndForcesAFullResync() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["n1"], "Junk": []]
        let (viewModel, _) = try makeInbox(relay: relay)
        await viewModel.selectFolder("Junk")
        relay.inboxRequests.value = []

        let target = await viewModel.prepareForPushTap(messageId: "n1")
        #expect(target?.serverId == "n1")
        #expect(viewModel.folder == StandardFolder.inbox)
        #expect(relay.inboxRequests.value.last.map { $0.0 } == "INBOX")
        #expect(relay.inboxRequests.value.last.map { $0.1 } == "0")
    }

    @Test @MainActor func aPushTapNeverReturnsTheCachedRowWhileARefreshOutlastsTheWait() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["n1"]]
        let (viewModel, _) = try makeInbox(relay: relay, pushTapRefreshWait: .milliseconds(200))
        await viewModel.load()
        #expect(viewModel.email(withServerId: "n1") != nil)

        let latch = RequestLatch()
        relay.gate.value = { request in
            if request.url?.path == "/api/inbox" { await latch.wait() }
        }
        relay.inboxRequests.value = []
        let stuck = Task { await viewModel.refresh() }
        #expect(await eventually { latch.hasEntered })

        let target = await viewModel.prepareForPushTap(messageId: "n1")
        #expect(target == nil)
        #expect(viewModel.notice == "Unable to connect to the mail server.")
        // No forced resync was issued behind the held refresh.
        #expect(latch.entered == 1)

        latch.release()
        _ = await stuck.value
    }

    @Test @MainActor func aPushTapWaitsOutARefreshThenRunsTheForcedResync() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["n1"]]
        let (viewModel, _) = try makeInbox(relay: relay)
        await viewModel.load()

        let latch = RequestLatch()
        relay.gate.value = { request in
            if request.url?.path == "/api/inbox" { await latch.wait() }
        }
        relay.inboxRequests.value = []
        let stuck = Task { await viewModel.refresh() }
        #expect(await eventually { latch.hasEntered })

        let tap = Task { await viewModel.prepareForPushTap(messageId: "n1") }
        try await Task.sleep(for: .milliseconds(300))
        latch.release()

        #expect(await tap.value?.serverId == "n1")
        _ = await stuck.value
        #expect(latch.entered == 2)
        #expect(relay.inboxRequests.value.last.map { $0.1 } == "0")
    }
}

// MARK: - Relay-confirmed actions (#173, #174)

@Suite struct ConfirmedActionTests {
    @MainActor
    private func makeRepository(relay: FakeInboxRelay, rows: [String], folder: String = "INBOX") async throws -> (MailRepository, EmailDAO) {
        let db = try AppDatabase(inMemory: true)
        let dao = EmailDAO(modelContainer: db.container)
        try await dao.replaceFolderSnapshot(folder: folder, emails: rows.map {
            Email(serverId: $0, folder: folder, senderName: "", senderEmail: "", subject: "", body: "",
                  keywords: [], receivedAt: Date(), read: false, starred: false)
        })
        return (MailRepository(securePairingStore: try makePairedStore(), emailDAO: dao, httpClient: relay.client), dao)
    }

    @Test func theReportDecodesTheServersShape() throws {
        let json = #"{"ok":false,"action":"move","processed":2,"failed":[{"messageId":"3","error":"no such message"}],"targetMailbox":"Work"}"#
        let response = try JSONDecoder().decode(RelayActionResponse.self, from: Data(json.utf8))
        #expect(response.report == MailActionReport(
            processed: 2, failed: [.init(messageId: "3", error: "no such message")]
        ))
        // A bare {"ok":true} confirms nothing.
        let bare = try JSONDecoder().decode(RelayActionResponse.self, from: Data(#"{"ok":true}"#.utf8))
        #expect(bare.report.processed == 0)
    }

    @Test @MainActor func aPartialFailureDropsOnlyTheConfirmedRows() async throws {
        let relay = FakeInboxRelay()
        relay.actionReply.value = { _ in
            (200, #"{"ok":false,"processed":2,"failed":[{"messageId":"2","error":"locked"}]}"#)
        }
        let (repository, dao) = try await makeRepository(relay: relay, rows: ["1", "2", "3"])

        let result = await repository.applyAction(.archive, messageIds: ["1", "2", "3"], from: "INBOX")
        #expect(result.confirmedIds == ["1", "3"])
        #expect(result.failureMessage == "1 of 3 not changed: locked")
        #expect(ids(try await dao.getFolder(folder: "INBOX", limit: 10)) == ["2"])
    }

    @Test @MainActor func aShortfallFailedDoesNotExplainConfirmsNothing() async throws {
        let relay = FakeInboxRelay()
        relay.actionReply.value = { _ in (200, #"{"ok":true,"processed":1,"failed":[]}"#) }
        let (repository, dao) = try await makeRepository(relay: relay, rows: ["1", "2"])

        let result = await repository.applyAction(.delete, messageIds: ["1", "2"], from: "INBOX")
        #expect(result.confirmedIds.isEmpty)
        #expect(result.failureMessage != nil)
        #expect(try await dao.getFolder(folder: "INBOX", limit: 10).count == 2)
    }

    @Test @MainActor func aTransportFailureKeepsEveryRow() async throws {
        let relay = FakeInboxRelay()
        relay.actionReply.value = { _ in (502, "upstream") }
        let (repository, dao) = try await makeRepository(relay: relay, rows: ["1"])

        let result = await repository.applyAction(.spam, messageIds: ["1"], from: "INBOX")
        #expect(result.confirmedIds.isEmpty)
        #expect(result.failureMessage != nil)
        #expect(try await dao.getFolder(folder: "INBOX", limit: 10).count == 1)
    }

    @Test @MainActor func moveSendsTheTargetAndDuplicatesAreSentOnce() async throws {
        let relay = FakeInboxRelay()
        let (repository, dao) = try await makeRepository(relay: relay, rows: ["1", "2"])

        let result = await repository.applyAction(.move, messageIds: ["1", "1", " 2 "], from: "INBOX", to: "Work")
        #expect(result == MailActionResult(confirmedIds: ["1", "2"]))
        let body = try #require(relay.actions.value.first)
        #expect(body["action"] as? String == "move")
        #expect(body["targetMailbox"] as? String == "Work")
        #expect(body["messageIds"] as? [String] == ["1", "2"])
        #expect(try await dao.getFolder(folder: "INBOX", limit: 10).isEmpty)
    }

    @Test @MainActor func moreThanTheRelayCapIsRefusedWithoutARequest() async throws {
        let relay = FakeInboxRelay()
        let (repository, _) = try await makeRepository(relay: relay, rows: [])
        let many = (0...MailRepository.maxActionIds).map(String.init)

        let result = await repository.applyAction(.archive, messageIds: many, from: "INBOX")
        #expect(result.confirmedIds.isEmpty)
        #expect(result.failureMessage == "Up to 500 messages at a time")
        #expect(relay.actionCount == 0)
    }

    @Test @MainActor func aRejectedDetailActionKeepsTheRowAndSaysWhy() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1"]]
        relay.actionReply.value = { _ in
            (200, #"{"ok":false,"processed":0,"failed":[{"messageId":"1","error":"read-only mailbox"}]}"#)
        }
        let (viewModel, _) = try makeInbox(relay: relay)
        await viewModel.load()
        let email = try #require(viewModel.emails.first)

        let failure = await viewModel.performNow(.move, on: email, to: "Work")
        #expect(failure == "1 of 1 not changed: read-only mailbox")
        #expect(ids(viewModel.filteredEmails) == ["1"])
        #expect(viewModel.undoMessage == nil)
    }

    @Test @MainActor func aConfirmedDetailActionRunsAtOnceWithoutUndo() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1", "2"]]
        let (viewModel, _) = try makeInbox(relay: relay)
        await viewModel.load()
        let email = try #require(viewModel.emails.first { $0.serverId == "1" })

        #expect(await viewModel.performNow(.archive, on: email) == nil)
        #expect(relay.actionCount == 1)
        #expect(ids(viewModel.filteredEmails) == ["2"])
        #expect(viewModel.undoMessage == nil)
    }
}

// MARK: - Undo window (#175)

@Suite struct UndoWindowTests {
    @Test func heldActionsLeaveExactlyOnce() {
        var pending = PendingMailActions()
        pending.hold(HeldMailAction(action: .delete, serverIds: ["1"], folder: "INBOX"))
        #expect(pending.summary == "Delete: 1 message")
        pending.hold(HeldMailAction(action: .archive, serverIds: ["2", "3"], folder: "INBOX"))
        #expect(pending.summary == "3 messages changed")
        #expect(pending.heldKeys == [
            MailRowKey(folder: "INBOX", serverId: "1"),
            MailRowKey(folder: "INBOX", serverId: "2"),
            MailRowKey(folder: "INBOX", serverId: "3"),
        ])

        let sent = pending.takeAll()
        #expect(sent.count == 2)
        // A timer firing after the flush finds nothing; undo has nothing left.
        let late = pending.takeAll()
        #expect(late.isEmpty)
        let undoneAfterFlush = pending.undoAll()
        #expect(!undoneAfterFlush)

        pending.hold(HeldMailAction(action: .spam, serverIds: ["4"], folder: "INBOX"))
        let undone = pending.undoAll()
        #expect(undone)
        let afterUndo = pending.takeAll()
        #expect(afterUndo.isEmpty)
    }

    @Test @MainActor func rowsHideAtOnceAndNothingIsSentUntilTheWindowCloses() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1", "2", "3"]]
        let (viewModel, dao) = try makeInbox(relay: relay, undoWindow: .milliseconds(300))
        await viewModel.load()

        viewModel.archive(serverIds: ["1", "2"])
        #expect(ids(viewModel.filteredEmails) == ["3"])
        #expect(viewModel.undoMessage == "Archive: 2 messages")
        #expect(relay.actionCount == 0)

        #expect(await eventually { relay.actionCount == 1 })
        #expect(await eventually { viewModel.emails.count == 1 })
        #expect(viewModel.undoMessage == nil)
        #expect(ids(try await dao.getFolder(folder: "INBOX", limit: 10)) == ["3"])
    }

    @Test @MainActor func aDropOntoArchiveIsTheArchiveActionAndOtherFoldersMove() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1", "2", "3"]]
        let (viewModel, _) = try makeInbox(relay: relay, undoWindow: .milliseconds(60))
        await viewModel.load()

        viewModel.drop(serverIds: ["1"], onto: StandardFolder.archive)
        #expect(await eventually { relay.actionCount == 1 })
        let archived = relay.actions.value[0]
        #expect(archived["action"] as? String == "archive")
        #expect(archived["targetMailbox"] == nil)

        viewModel.drop(serverIds: ["2"], onto: "Work")
        #expect(await eventually { relay.actionCount == 2 })
        let moved = relay.actions.value[1]
        #expect(moved["action"] as? String == "move")
        #expect(moved["targetMailbox"] as? String == "Work")
    }

    @Test @MainActor func undoRestoresTheRowsAndNothingIsEverSent() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1", "2"]]
        let (viewModel, _) = try makeInbox(relay: relay, undoWindow: .milliseconds(80))
        await viewModel.load()

        viewModel.delete(serverIds: ["1"])
        viewModel.undoHeldActions()
        #expect(ids(viewModel.filteredEmails) == ["1", "2"])
        try await Task.sleep(for: .milliseconds(250))
        #expect(relay.actionCount == 0)
    }

    @Test @MainActor func aSecondActionExtendsTheWindowAndOneUndoTakesBothBack() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1", "2", "3"]]
        let (viewModel, _) = try makeInbox(relay: relay, undoWindow: .milliseconds(200))
        await viewModel.load()

        viewModel.delete(serverIds: ["1"])
        try await Task.sleep(for: .milliseconds(120))
        viewModel.markJunk(serverIds: ["2"])
        #expect(viewModel.undoMessage == "2 messages changed")
        // Past the first action's own deadline, nothing has been sent.
        try await Task.sleep(for: .milliseconds(120))
        #expect(relay.actionCount == 0)

        viewModel.undoHeldActions()
        #expect(ids(viewModel.filteredEmails) == ["1", "2", "3"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(relay.actionCount == 0)
    }

    @Test @MainActor func leavingTheScreenCommitsEachActionOnce() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1", "2"]]
        let (viewModel, _) = try makeInbox(relay: relay, undoWindow: .milliseconds(150))
        await viewModel.load()

        viewModel.delete(serverIds: ["1"])
        viewModel.archive(serverIds: ["2"])
        viewModel.leaveInbox()
        #expect(await eventually { relay.actionCount == 2 })
        // The window's own timer, firing later, sends nothing more.
        try await Task.sleep(for: .milliseconds(300))
        #expect(relay.actionCount == 2)
        #expect(relay.actions.value.map { $0["action"] as? String } == ["delete", "archive"])
    }

    @Test @MainActor func discardingForAWipeNeverSends() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1"]]
        let (viewModel, _) = try makeInbox(relay: relay, undoWindow: .milliseconds(60))
        await viewModel.load()

        viewModel.delete(serverIds: ["1"])
        viewModel.discardHeldActions()
        #expect(viewModel.commitHeldActions() == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(relay.actionCount == 0)
        #expect(viewModel.undoMessage == nil)
    }

    @Test @MainActor func heldRowsStayHiddenAcrossARefresh() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1", "2"]]
        let (viewModel, _) = try makeInbox(relay: relay, undoWindow: .seconds(5))
        await viewModel.load()

        viewModel.archive(serverIds: ["1"])
        await viewModel.refresh()
        #expect(ids(viewModel.filteredEmails) == ["2"])
        viewModel.discardHeldActions()
    }

    @Test @MainActor func aWindowClosingAfterAFolderSwitchActsOnThePinnedFolder() async throws {
        let relay = FakeInboxRelay()
        // The same id in two folders: IMAP UIDs repeat across mailboxes.
        relay.mailboxes.value = ["INBOX": ["7"], "Junk": ["7"]]
        let (viewModel, _) = try makeInbox(relay: relay, undoWindow: .milliseconds(150))
        await viewModel.load()

        viewModel.move(serverIds: ["7"], to: "Work")
        await viewModel.selectFolder("Junk")
        // Held by (INBOX, 7), so Junk's row 7 stays visible.
        #expect(ids(viewModel.filteredEmails) == ["7"])

        #expect(await eventually { relay.actionCount == 1 })
        let body = try #require(relay.actions.value.first)
        #expect(body["mailbox"] as? String == "INBOX")
        #expect(body["targetMailbox"] as? String == "Work")
        #expect(await eventually { viewModel.undoMessage == nil })
        #expect(ids(viewModel.filteredEmails) == ["7"])
    }

    @Test @MainActor func aRejectedCommitBringsTheRowBackAndSaysWhy() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1", "2", "3"]]
        relay.actionReply.value = { _ in
            (200, #"{"ok":false,"processed":2,"failed":[{"messageId":"3","error":"locked"}]}"#)
        }
        let (viewModel, _) = try makeInbox(relay: relay, undoWindow: .milliseconds(60))
        await viewModel.load()

        viewModel.delete(serverIds: ["1", "2", "3"])
        #expect(viewModel.filteredEmails.isEmpty)
        #expect(await eventually { viewModel.notice != nil })
        #expect(viewModel.notice == "1 of 3 not changed: locked")
        #expect(ids(viewModel.filteredEmails) == ["3"])
    }

    @Test @MainActor func aMoveToTheFolderOnScreenIsIgnored() async throws {
        let relay = FakeInboxRelay()
        relay.mailboxes.value = ["INBOX": ["1"]]
        let (viewModel, _) = try makeInbox(relay: relay)
        await viewModel.load()

        viewModel.move(serverIds: ["1"], to: "inbox")
        #expect(viewModel.undoMessage == nil)
        #expect(ids(viewModel.filteredEmails) == ["1"])
    }
}
