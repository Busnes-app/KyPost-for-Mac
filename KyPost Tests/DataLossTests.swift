//
//  DataLossTests.swift
//  KyPost Tests
//
//  Paths that used to lose data or duplicate a send: recipient pins
//  overwritten after a decode failure, a folder pruned on one empty answer,
//  a timed-out send re-enabled for a second ⌘↩, and ⌘Q with list actions in
//  their undo window or a compose with unsent text.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Recipient pins

@Suite struct RecipientPinDecodeFailureTests {
    private func makeStore() -> (RecipientPinStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = RecipientPinStore(
            defaults: defaults, hostileLocation: HostileLocationProtectionStore(defaults: defaults)
        )
        return (store, defaults)
    }

    /// A pin write used to read an undecodable store as empty and write back
    /// a map holding only the new pin — every other verified key gone.
    @Test func anUnreadableStoreIsNeverOverwritten() {
        let (store, defaults) = makeStore()
        let garbage = Data("{not json".utf8)
        defaults.set(garbage, forKey: "contacts.recipientPins")

        #expect(store.persistedPinsUnreadable)
        #expect(!store.pin(addresses: ["a@example.invalid"], publicKey: PinnedKeyFixtures.alicePinned))
        store.replaceRevoked(address: "a@example.invalid", with: PinnedKeyFixtures.alicePinned)

        #expect(defaults.data(forKey: "contacts.recipientPins") == garbage)
    }

    @Test func aReadableStoreStillTakesPins() {
        let (store, _) = makeStore()
        #expect(!store.persistedPinsUnreadable)
        #expect(store.pin(addresses: ["a@example.invalid"], publicKey: PinnedKeyFixtures.alicePinned))
        #expect(store.pin(for: "a@example.invalid") != nil)
    }

    /// The QR save keeps the contact but says the verification was not
    /// recorded.
    @Test func theQrSaveReportsTheRefusal() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        defaults.set(Data("{not json".utf8), forKey: "contacts.recipientPins")
        let database = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: database.container)
        let repository = ContactSyncRepository(
            client: ContactSyncClient(httpClient: stubClient()),
            contactDAO: dao,
            cursorStore: ContactCursorStore(defaults: defaults),
            pendingDeletesStore: ContactPendingDeletesStore(defaults: defaults),
            securePairingStore: try makePairedStore(),
            recipientPins: RecipientPinStore(
                defaults: defaults, hostileLocation: HostileLocationProtectionStore(defaults: defaults)
            )
        )
        var alice = makeContact("Alice", "alice@example.invalid")
        alice.pgpKey = PinnedKeyFixtures.alicePinned

        await #expect(throws: RecipientPinStoreError.unreadable) {
            try await repository.saveContact(alice, verifiedInPerson: true)
        }
        #expect(try await dao.listAll().map(\.name) == ["Alice"])
    }
}

// MARK: - Empty full window

@Suite struct EmptyFullWindowTests {
    private static func inbox(_ ids: [String]) -> String {
        let rows = ids.map {
            #"{"messageId": "\#($0)", "subject": "S \#($0)"}"#
        }
        return #"{"byTab": {"Inbox": [\#(rows.joined(separator: ","))]}, "cursor": "c"}"#
    }

    /// One empty answer — a relay mid-restart, a proxy returning `{}` — used
    /// to empty the folder. It must be confirmed by the next full window.
    @Test func oneEmptyFullWindowDoesNotPruneTheFolder() async throws {
        let answer = Box(Self.inbox(["a", "b"]))
        let sinceSent = Box<[String]>([])
        let client = HTTPClient { request in
            let since = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "since" }?.value ?? ""
            sinceSent.mutate { $0.append(since) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(answer.value.utf8), response)
        }
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let dao = EmailDAO(modelContainer: try AppDatabase(inMemory: true).container)
        let repository = MailRepository(
            securePairingStore: try makePairedStore(),
            emailDAO: dao,
            httpClient: client,
            cursorStore: MailCursorStore(
                defaults: defaults, hostileLocation: HostileLocationProtectionStore(defaults: defaults)
            )
        )
        try await repository.refreshFolder("INBOX")
        #expect(try await dao.getFolder(folder: "INBOX").count == 2)

        answer.value = #"{"byTab": {}, "cursor": "c2"}"#
        try await repository.refreshFolder("INBOX", forceFullResync: true)
        #expect(try await dao.getFolder(folder: "INBOX").count == 2, "one empty answer must not prune")
        #expect(await dao.awaitsEmptyWindowConfirmation(folder: "INBOX"))

        // The next refresh asks for the whole window again, without forcing,
        // and a second empty answer is believed.
        try await repository.refreshFolder("INBOX")
        #expect(sinceSent.value.last == "0")
        #expect(try await dao.getFolder(folder: "INBOX").isEmpty)
        #expect(await !dao.awaitsEmptyWindowConfirmation(folder: "INBOX"))
    }

    @Test func aNonEmptyAnswerClearsAnUnconfirmedEmptyOne() async throws {
        let dao = EmailDAO(modelContainer: try AppDatabase(inMemory: true).container)
        let mail = { (id: String) in
            Email(
                serverId: id, folder: "INBOX", senderName: "A", senderEmail: "a@x",
                subject: id, body: "b", keywords: [],
                receivedAt: Date(timeIntervalSince1970: 1_000_000), read: false, starred: false
            )
        }
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [mail("a"), mail("b")])
        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [])
        #expect(await dao.awaitsEmptyWindowConfirmation(folder: "INBOX"))

        try await dao.replaceFolderSnapshot(folder: "INBOX", emails: [mail("a")])
        #expect(await !dao.awaitsEmptyWindowConfirmation(folder: "INBOX"))
        #expect(try await dao.getFolder(folder: "INBOX").map(\.serverId) == ["a"])

        // Empty over an empty cache is simply empty.
        let empty = EmailDAO(modelContainer: try AppDatabase(inMemory: true).container)
        try await empty.replaceFolderSnapshot(folder: "INBOX", emails: [])
        #expect(await !empty.awaitsEmptyWindowConfirmation(folder: "INBOX"))
    }
}

// MARK: - Sends whose outcome is unknown

@MainActor
@Suite struct UncertainSendTests {
    private struct Sent: Sendable {
        var idempotencyKey: String?
        var timeout: TimeInterval
    }

    /// `respond` answers each `/api/mail/send` in turn.
    private func makeCompose(
        sent: Box<[Sent]>,
        respond: @escaping @Sendable (Int) throws -> (status: Int, json: String)
    ) throws -> ComposeViewModel {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let pairingStore = try makePairedStore()
        let database = try AppDatabase(inMemory: true)
        let client = HTTPClient { request in
            let index = sent.value.count
            sent.mutate {
                $0.append(Sent(
                    idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key"),
                    timeout: request.timeoutInterval
                ))
            }
            let (status, json) = try respond(index)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
        let contacts = ContactsViewModel(repository: ContactSyncRepository(
            client: ContactSyncClient(httpClient: stubClient()),
            contactDAO: ContactDAO(modelContainer: database.container),
            cursorStore: ContactCursorStore(defaults: defaults),
            pendingDeletesStore: ContactPendingDeletesStore(defaults: defaults),
            securePairingStore: pairingStore
        ), settingsStore: ContactsSettingsStore(defaults: defaults))
        let model = ComposeViewModel(
            sendEmail: SendEmailUseCase(repository: MailRepository(
                securePairingStore: pairingStore,
                emailDAO: EmailDAO(modelContainer: database.container),
                httpClient: client
            )),
            contacts: contacts,
            pgp: PgpSendService(
                client: PgpSendClient(httpClient: stubClient()),
                securePairingStore: pairingStore
            ),
            isLocked: { false },
            debounceInterval: .zero
        )
        model.to = [RecipientToken(address: "grace@example.com")]
        model.subject = "Hello"
        return model
    }

    private let noTraits: RichTextHTML.FontTraits = { _ in (false, false) }

    @Test func aTimeoutKeepsSendDisabledAndSaysItMayHaveGone() async throws {
        let sent = Box<[Sent]>([])
        let compose = try makeCompose(sent: sent) { _ in throw URLError(.timedOut) }

        await compose.send(fontTraits: noTraits)

        #expect(compose.sendOutcomeUnknown)
        #expect(compose.errorMessage?.contains("may have been sent") == true)
        #expect(!compose.didSend)
        // A second ⌘↩ does nothing.
        await compose.send(fontTraits: noTraits)
        #expect(sent.value.count == 1)
        // Nothing went out, as far as anyone knows: closing still asks.
        #expect(compose.closingNeedsConfirmation)
    }

    @Test(arguments: [500, 502, 503, 504])
    func a5xxIsAnUnknownOutcome(status: Int) async throws {
        let sent = Box<[Sent]>([])
        let compose = try makeCompose(sent: sent) { _ in (status, "upstream gone") }

        await compose.send(fontTraits: noTraits)

        #expect(compose.sendOutcomeUnknown)
    }

    @Test func theDeliberateRetryReusesTheKey() async throws {
        let sent = Box<[Sent]>([])
        let compose = try makeCompose(sent: sent) { index in
            if index == 0 { throw URLError(.networkConnectionLost) }
            return (200, #"{"ok": true}"#)
        }

        await compose.send(fontTraits: noTraits)
        await compose.sendAgainAfterUncertainOutcome(fontTraits: noTraits)

        #expect(compose.didSend)
        #expect(sent.value.count == 2)
        let first = try #require(sent.value[0].idempotencyKey)
        #expect(!first.isEmpty)
        #expect(sent.value[1].idempotencyKey == first)
    }

    /// A blank subject was confirmed before the first attempt; the retry is
    /// the same request and does not ask again.
    @Test func theRetryOfABlankSubjectDoesNotAskAgain() async throws {
        let sent = Box<[Sent]>([])
        let compose = try makeCompose(sent: sent) { index in
            if index == 0 { throw URLError(.timedOut) }
            return (200, #"{"ok": true}"#)
        }
        compose.subject = " "

        await compose.send(fontTraits: noTraits)
        #expect(compose.confirmingBlankSubject)
        await compose.sendWithoutSubject(fontTraits: noTraits)
        #expect(compose.sendOutcomeUnknown)
        await compose.sendAgainAfterUncertainOutcome(fontTraits: noTraits)

        #expect(!compose.confirmingBlankSubject)
        #expect(compose.didSend)
        #expect(sent.value.count == 2)
        #expect(sent.value[1].idempotencyKey == sent.value[0].idempotencyKey)
    }

    /// After a definite refusal the corrected message is a new request: a
    /// relay remembering keys must not answer it with the refusal.
    @Test func aDefiniteAnswerStartsANewKey() async throws {
        let sent = Box<[Sent]>([])
        let compose = try makeCompose(sent: sent) { index in
            index == 0 ? (400, "bad recipient") : (200, #"{"ok": true}"#)
        }

        await compose.send(fontTraits: noTraits)
        #expect(!compose.sendOutcomeUnknown)
        await compose.send(fontTraits: noTraits)

        #expect(sent.value.count == 2)
        #expect(sent.value[0].idempotencyKey != sent.value[1].idempotencyKey)
    }

    @Test func aSendWithAttachmentsWaitsLonger() async throws {
        let sent = Box<[Sent]>([])
        let compose = try makeCompose(sent: sent) { _ in (200, #"{"ok": true}"#) }
        compose.attachments = [ComposeAttachment(name: "a.pdf", mimeType: "application/pdf", data: Data(count: 10))]

        await compose.send(fontTraits: noTraits)

        #expect(sent.value.first?.timeout == RelayMailSource.sendWithAttachmentsTimeout)
    }

    @Test func aDecodingFailureAfterA2xxIsUnknownNotFailed() {
        #expect(MailOutcome.sendOutcomeUnknown(NetworkError.decoding(description: "x")))
        #expect(MailOutcome.sendOutcomeUnknown(NetworkError.transport(description: "x")))
        #expect(!MailOutcome.sendOutcomeUnknown(NetworkError.badRequest(body: "x")))
        #expect(!MailOutcome.sendOutcomeUnknown(NetworkError.unauthorized))
        #expect(!MailOutcome.sendOutcomeUnknown(NetworkError.rateLimited(retryAfter: nil)))
        #expect(!MailOutcome.sendOutcomeUnknown(NetworkError.server(statusCode: 404)))
    }
}

// MARK: - Quitting

@MainActor
@Suite struct QuitPreparationTests {
    @Test func keepEditingCancelsTheQuitAndSendsNothing() {
        var committed = false
        let reply = QuitPreparation.begin(
            unsentComposes: 2,
            confirmDiscard: { #expect($0 == 2); return false },
            commitHeldActions: { committed = true; return nil },
            finish: {}
        )
        #expect(reply == .cancel)
        #expect(!committed, "held actions stay undoable when the quit is cancelled")
    }

    @Test func nothingUnsentAndNothingHeldQuitsAtOnceWithoutAsking() {
        var asked = false
        let reply = QuitPreparation.begin(
            unsentComposes: 0,
            confirmDiscard: { _ in asked = true; return true },
            commitHeldActions: { nil },
            finish: {}
        )
        #expect(reply == .now)
        #expect(!asked)
    }

    @Test func heldActionsAreSentBeforeTheProcessGoes() async {
        var finished = false
        let sent = Box(false)
        let commit = Task { sent.value = true }
        let reply = QuitPreparation.begin(
            unsentComposes: 1,
            confirmDiscard: { _ in true },
            commitHeldActions: { commit },
            finish: { finished = true }
        )
        #expect(reply == .later)
        while !finished { await Task.yield() }
        #expect(sent.value)
    }

    @Test func anUnresponsiveRelayDoesNotHoldTheQuitHostage() async {
        var finished = false
        let never = Task<Void, Never> { try? await Task.sleep(for: .seconds(600)) }
        defer { never.cancel() }
        let reply = QuitPreparation.begin(
            unsentComposes: 0,
            confirmDiscard: { _ in true },
            commitHeldActions: { never },
            timeout: .milliseconds(50),
            finish: { finished = true }
        )
        #expect(reply == .later)
        let deadline = Date().addingTimeInterval(5)
        while !finished, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(finished)
    }

    @Test func theRegistryCountsOnlyComposesWithSomethingToLose() throws {
        let registry = OpenComposeRegistry()
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let pairingStore = try makePairedStore()
        let database = try AppDatabase(inMemory: true)
        func compose() -> ComposeViewModel {
            ComposeViewModel(
                sendEmail: SendEmailUseCase(repository: MailRepository(
                    securePairingStore: pairingStore,
                    emailDAO: EmailDAO(modelContainer: database.container),
                    httpClient: stubClient()
                )),
                contacts: ContactsViewModel(repository: ContactSyncRepository(
                    client: ContactSyncClient(httpClient: stubClient()),
                    contactDAO: ContactDAO(modelContainer: database.container),
                    cursorStore: ContactCursorStore(defaults: defaults),
                    pendingDeletesStore: ContactPendingDeletesStore(defaults: defaults),
                    securePairingStore: pairingStore
                ), settingsStore: ContactsSettingsStore(defaults: defaults)),
                pgp: PgpSendService(client: PgpSendClient(httpClient: stubClient()), securePairingStore: pairingStore),
                isLocked: { false },
                debounceInterval: .zero
            )
        }
        let blank = compose()
        let written = compose()
        written.subject = "Draft"
        registry.register(blank)
        registry.register(written)
        #expect(registry.unsentCount == 1)

        registry.unregister(written)
        #expect(registry.unsentCount == 0)
    }
}
