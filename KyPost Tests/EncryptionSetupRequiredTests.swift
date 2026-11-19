//
//  EncryptionSetupRequiredTests.swift
//  KyPost Tests
//
//  KyPost-Server #666: a mailbox route answers 403 encryption_setup_required
//  while the account owes first sign-in encryption setup. Decoded once, held
//  without retrying, lifted by one successful re-check, and never a sign-out.
//

import Foundation
import Testing
@testable import KyPost

nonisolated private let setupBody =
    #"{"error":"encryption_setup_required","message":"Finish email encryption setup in KyPost on the web before using mail here."}"#
nonisolated private let serverMessage = "Finish email encryption setup in KyPost on the web before using mail here."

@Suite struct EncryptionSetupDecodingTests {
    @Test func theSetupRefusalIsItsOwnErrorWithTheServersMessage() {
        let error = NetworkError.from(statusCode: 403, body: Data(setupBody.utf8))
        #expect(error == .encryptionSetupRequired(message: serverMessage))
        #expect(error?.errorDescription == serverMessage)
    }

    @Test func withoutAMessageTheAppsOwnSentenceIsUsed() {
        let error = NetworkError.from(statusCode: 403, body: Data(#"{"error":"encryption_setup_required"}"#.utf8))
        #expect(error == .encryptionSetupRequired(message: nil))
        #expect(error?.errorDescription == "Finish email encryption setup in KyPost on the web, then come back.")
    }

    @Test func anyOther403Or401StaysUnauthorized() {
        #expect(NetworkError.from(statusCode: 403) == .unauthorized)
        #expect(NetworkError.from(statusCode: 403, body: Data("forbidden".utf8)) == .unauthorized)
        #expect(NetworkError.from(statusCode: 403, body: Data(#"{"error":"forbidden"}"#.utf8)) == .unauthorized)
        // Only 403 carries it; the code on another status is not trusted.
        #expect(NetworkError.from(statusCode: 401, body: Data(setupBody.utf8)) == .unauthorized)
    }

    @Test func everyClientSeesItThroughTheSharedHTTPClient() async {
        let client = stubClient(status: 403, json: setupBody)
        await #expect(throws: NetworkError.encryptionSetupRequired(message: serverMessage)) {
            _ = try await client.get([String: String].self, url: URL(string: "\(server)/api/inbox")!)
        }
    }

    @Test func callersReportTheServersSentenceNotARePair() {
        let outcome = MailOutcome.from(NetworkError.encryptionSetupRequired(message: serverMessage))
        #expect(outcome.userMessage == serverMessage)
        #expect(MailOutcome.sendOutcomeUnknown(NetworkError.encryptionSetupRequired(message: nil)) == false)
    }

    @Test func theButtonOpensTheServersSetupPage() {
        #expect(webmailEncryptionSetupURL(serverUrl: "https://relay.example.com/")?.absoluteString
            == "https://relay.example.com/setup/encryption")
        #expect(webmailEncryptionSetupURL(serverUrl: "https://relay.example.com/kypost")?.absoluteString
            == "https://relay.example.com/kypost/setup/encryption")
        #expect(webmailEncryptionSetupURL(serverUrl: "not a url") == nil)
    }
}

/// `/api/inbox` answering the setup refusal until `held` is cleared.
nonisolated private final class SetupRelay: @unchecked Sendable {
    let held = Box(true)
    let inboxRequests = Box(0)

    var client: HTTPClient {
        HTTPClient { [self] request in
            let url = request.url!
            func reply(_ status: Int, _ body: String) -> (Data, URLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            guard url.path == "/api/inbox" else {
                return held.value ? reply(403, setupBody) : reply(200, #"{"folders":[]}"#)
            }
            inboxRequests.mutate { $0 += 1 }
            if held.value { return reply(403, setupBody) }
            return reply(200, #"{"byTab":{"":[{"messageId":"m1","subject":"Hello","atUtc":"2026-11-19T10:00:00Z"}]}}"#)
        }
    }
}

@MainActor
@Suite struct EncryptionSetupHoldTests {
    private func makeInbox(_ relay: SetupRelay) throws -> (InboxViewModel, SecurePairingStore) {
        let store = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        let viewModel = InboxViewModel(
            mailRepository: MailRepository(
                securePairingStore: store,
                emailDAO: EmailDAO(modelContainer: db.container),
                httpClient: relay.client
            ),
            keywordRepository: KeywordRepository(
                settingsStore: KeywordSettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
            ),
            initialRefreshErrorDelay: .milliseconds(20),
            initialRefreshRetryDelay: .milliseconds(20)
        )
        return (viewModel, store)
    }

    @Test func theRefusalHoldsTheInboxWithoutABannerOrARetry() async throws {
        let relay = SetupRelay()
        let (viewModel, _) = try makeInbox(relay)

        await viewModel.refresh(delaysTransientError: true)
        #expect(viewModel.encryptionSetupMessage == serverMessage)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.connectionNotice == nil)
        #expect(viewModel.encryptionSetupURL?.absoluteString == "\(server)/setup/encryption")

        // Neither the initial-refresh retry nor the cadence asks again.
        try await Task.sleep(for: .milliseconds(120))
        #expect(await viewModel.refresh() == false)
        #expect(relay.inboxRequests.value == 1)
        #expect(viewModel.connectionNotice == nil)
    }

    @Test func aRecheckIsOneRequestAndSuccessLiftsTheHold() async throws {
        let relay = SetupRelay()
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.refresh()

        await viewModel.recheckEncryptionSetup()
        #expect(relay.inboxRequests.value == 2)
        #expect(viewModel.encryptionSetupMessage == serverMessage)

        relay.held.value = false
        await viewModel.recheckEncryptionSetup()
        #expect(relay.inboxRequests.value == 3)
        #expect(viewModel.encryptionSetupMessage == nil)
        #expect(viewModel.filteredEmails.map(\.serverId) == ["m1"])

        // Normal refresh is back.
        #expect(await viewModel.refresh())
        #expect(relay.inboxRequests.value == 4)
    }

    @Test func aRecheckWhenNotHeldSendsNothing() async throws {
        let relay = SetupRelay()
        relay.held.value = false
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.recheckEncryptionSetup()
        #expect(relay.inboxRequests.value == 0)
    }

    @Test func theHoldIsNotASignOut() async throws {
        let relay = SetupRelay()
        relay.held.value = false
        let (viewModel, store) = try makeInbox(relay)
        let before = try store.loadPairing()
        await viewModel.refresh()

        relay.held.value = true
        await viewModel.refresh(forceFullResync: true)
        #expect(viewModel.encryptionSetupMessage != nil)
        // Credentials and the mail already on this device stay.
        #expect(try store.loadPairing() == before)
        #expect(try store.loadActivePairing() != nil)
        #expect(viewModel.filteredEmails.map(\.serverId) == ["m1"])
    }

    @Test func forgettingTheAccountDropsTheHold() async throws {
        let relay = SetupRelay()
        let (viewModel, _) = try makeInbox(relay)
        await viewModel.refresh()
        viewModel.forgetAccount()
        #expect(viewModel.encryptionSetupMessage == nil)
    }
}
