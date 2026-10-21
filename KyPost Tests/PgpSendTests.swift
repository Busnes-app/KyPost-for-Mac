//
//  PgpSendTests.swift
//  KyPost Tests
//
//  Encrypted send from a paired client (Client_Encrypted_Send.md): the key
//  custody rule, the two /api/pgp preflight calls, and compose's keyless
//  confirmation and webmail handoff. Relay send/draft wire tests live in
//  MailTests.swift with the other relay tests.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Key custody

@Suite struct PgpKeyCustodyTests {
    @Test func serverProtectionIsTheOnlyNativeSendMode() {
        #expect(pgpKeyCustody(hasIdentity: true, protection: "server") == .serverHeld)
        #expect(pgpKeyCustody(hasIdentity: true, protection: "client") == .clientHeld)
    }

    @Test func noIdentityMeansPlaintextOnly() {
        #expect(pgpKeyCustody(hasIdentity: false, protection: "server") == .noIdentity)
        #expect(pgpKeyCustody(hasIdentity: nil, protection: nil) == .noIdentity)
        // An identity-less account reports protection "" (the spec's table).
        #expect(pgpKeyCustody(hasIdentity: true, protection: "") == .noIdentity)
    }

    /// Degrade, never guess: an unknown mode must not promise an encrypted
    /// send this app cannot deliver.
    @Test func unknownProtectionDegradesToClientHeld() {
        #expect(pgpKeyCustody(hasIdentity: true, protection: "hsm") == .clientHeld)
        #expect(pgpKeyCustody(hasIdentity: true, protection: nil) == .clientHeld)
    }

    @Test func protectionIsReadTolerantly() {
        #expect(pgpKeyCustody(hasIdentity: true, protection: " Server ") == .serverHeld)
        #expect(pgpKeyCustody(hasIdentity: true, protection: "SERVER") == .serverHeld)
    }
}

// MARK: - PgpSendClient

@Suite struct PgpSendClientTests {
    private let auth = RelayAuth(deviceId: "u1", deviceSecret: "h1")

    @Test func bootstrapReadsOnlyTheTwoFieldsThisClientNeeds() async throws {
        // The real response also carries wrappedPrivateKey, unlockRequired,
        // signerPublicKeys, payloadEndpoint … — all ignorable here.
        let json = """
        {"hasIdentity": true, "protection": "server", "fingerprint": "AB", "keyId": "CD",
         "publicKey": "-----BEGIN PGP PUBLIC KEY BLOCK----- x", "keySource": "generated",
         "wrappedPrivateKey": "zzz", "unlockRequired": true, "signerPublicKeys": ["a"]}
        """
        let client = PgpSendClient(httpClient: stubClient(json: json) { request in
            #expect(request.url!.absoluteString == "\(server)/api/pgp/bootstrap")
            #expect(request.httpMethod == nil || request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
        })

        let response = try await client.fetchBootstrap(serverUrl: server, auth: auth)
        #expect(response.hasIdentity == true)
        #expect(response.protection == "server")
        #expect(pgpKeyCustody(
            hasIdentity: response.hasIdentity,
            protection: response.protection
        ) == .serverHeld)
    }

    @Test func bootstrapWithNoFieldsDecodesRatherThanThrowing() async throws {
        let client = PgpSendClient(httpClient: stubClient(json: "{}"))
        let response = try await client.fetchBootstrap(serverUrl: server, auth: auth)
        #expect(response.hasIdentity == nil)
        #expect(pgpKeyCustody(
            hasIdentity: response.hasIdentity,
            protection: response.protection
        ) == .noIdentity)
    }

    @Test func checkPostsEveryAddressToTheCheckEndpoint() async throws {
        let json = """
        {"results": [
          {"address": "alice@example.com", "hasKey": true, "revoked": false, "expired": false, "tier": "contact-verified"},
          {"address": "bob@example.com", "hasKey": false, "revoked": false, "expired": false, "tier": "none"}
        ]}
        """
        let client = PgpSendClient(httpClient: stubClient(json: json) { request in
            // Never /resolve: it hands over recipients' keys and 409s for any
            // account that is not client-protected (trap 1).
            #expect(request.url!.absoluteString == "\(server)/api/pgp/recipients/check")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""addresses":["alice@example.com","bob@example.com"]"#))
        })

        let results = try await client.checkRecipients(
            ["alice@example.com", "bob@example.com"],
            serverUrl: server,
            auth: auth
        )
        #expect(results.count == 2)
        #expect(keylessAddresses(in: results) == ["bob@example.com"])
    }

    @Test func missingResultsIsAnEmptyListNotAFailure() async throws {
        let client = PgpSendClient(httpClient: stubClient(json: "{}"))
        let results = try await client.checkRecipients(["a@x.com"], serverUrl: server, auth: auth)
        #expect(results.isEmpty)
        #expect(keylessAddresses(in: results).isEmpty)
    }

    /// "revoked but present" is never sendable, whatever `hasKey` claims.
    @Test func revokedOrExpiredKeysAreNotUsable() {
        let revoked = PgpRecipientCheckDTO(
            address: "r@x.com", hasKey: true, revoked: true, expired: false, tier: "contact"
        )
        let expired = PgpRecipientCheckDTO(
            address: "e@x.com", hasKey: true, revoked: false, expired: true, tier: "contact"
        )
        let good = PgpRecipientCheckDTO(
            address: "g@x.com", hasKey: true, revoked: nil, expired: nil, tier: "contact"
        )
        #expect(keylessAddresses(in: [revoked, expired, good]) == ["r@x.com", "e@x.com"])
    }

    @Test func aBadServerUrlFailsBeforeAnyRequest() async {
        let client = PgpSendClient(httpClient: stubClient())
        await #expect(throws: NetworkError.invalidURL) {
            try await client.fetchBootstrap(serverUrl: "", auth: auth)
        }
    }
}

// MARK: - PgpSendService

@Suite @MainActor struct PgpSendServiceTests {
    private func makeService(
        paired: Bool = true,
        status: Int = 200,
        json: String = #"{"hasIdentity":true,"protection":"server"}"#,
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) throws -> PgpSendService {
        PgpSendService(
            client: PgpSendClient(httpClient: stubClient(status: status, json: json, onRequest: onRequest)),
            securePairingStore: try makePairedStore(paired: paired)
        )
    }

    @Test func loadCachesCustodyForTheSession() async throws {
        let calls = Box(0)
        let service = try makeService { _ in calls.mutate { $0 += 1 } }

        #expect(service.custody == nil)
        await service.loadIfNeeded()
        #expect(service.custody == .serverHeld)

        // The mode is chosen at key creation and has no downgrade path, so one
        // fetch per session is the contract, not an optimisation.
        await service.loadIfNeeded()
        #expect(calls.value == 1)
    }

    /// An unreachable bootstrap must never block a plaintext send: custody
    /// stays nil and compose simply offers no PGP toggles.
    @Test func aFailedBootstrapLeavesCustodyUnknown() async throws {
        let service = try makeService(status: 503, json: "pairing secret unset")
        await service.loadIfNeeded()
        #expect(service.custody == nil)
    }

    @Test func withoutAPairingNothingIsFetched() async throws {
        let calls = Box(0)
        let service = try makeService(paired: false) { _ in calls.mutate { $0 += 1 } }
        await service.loadIfNeeded()
        #expect(service.custody == nil)
        #expect(calls.value == 0)
    }

    @Test func preflightReturnsTheAddressesWithNoUsableKey() async throws {
        let json = """
        {"results": [
          {"address": "alice@example.com", "hasKey": true},
          {"address": "bob@example.com", "hasKey": false}
        ]}
        """
        let service = try makeService(json: json)
        let keyless = await service.keylessRecipients(
            among: ["alice@example.com", "bob@example.com"]
        )
        #expect(keyless == ["bob@example.com"])
    }

    /// The preflight is advisory. A failure warns about nothing rather than
    /// blocking the send — the relay's 409 is the real gate.
    @Test func aFailedPreflightWarnsAboutNothing() async throws {
        let service = try makeService(status: 500, json: "boom")
        #expect(await service.keylessRecipients(among: ["bob@example.com"]).isEmpty)
    }

    @Test func anEmptyAddressListSkipsTheCallEntirely() async throws {
        let calls = Box(0)
        let service = try makeService { _ in calls.mutate { $0 += 1 } }
        #expect(await service.keylessRecipients(among: []).isEmpty)
        #expect(calls.value == 0)
    }
}

// MARK: - PgpSendService across an account teardown

@Suite @MainActor struct PgpSendServiceTeardownTests {
    private let json = #"{"hasIdentity":true,"protection":"server","suggestedUserIDs":["me@x.com","alias@y.com"]}"#

    private func pairNextAccount(_ store: SecurePairingStore) throws {
        try store.savePairing(Pairing(
            sub: "u2",
            deviceSecret: "s2",
            srv: server,
            registrationUrl: nil,
            pairingToken: "pt2",
            lastDeviceId: nil,
            pairedAt: Date().addingTimeInterval(1)
        ))
    }

    /// The next account's replies must not leave out this one's aliases.
    @Test func teardownForgetsTheBootstrapAndTheNextAccountRefetches() async throws {
        let calls = Box(0)
        let store = try makePairedStore()
        let service = PgpSendService(
            client: PgpSendClient(httpClient: stubClient(json: json) { _ in calls.mutate { $0 += 1 } }),
            securePairingStore: store
        )
        await service.loadIfNeeded()
        #expect(service.ownAddresses == ["u1", "me@x.com", "alias@y.com"])

        #expect(await AccountTeardown(erasePreservedStore: nil, pgpSendService: service).run())
        #expect(service.custody == nil)
        #expect(service.accountAddress.isEmpty)
        #expect(service.ownAddresses.isEmpty)
        // The pairing being left is retired: no fetch with its credentials.
        await service.loadIfNeeded()
        #expect(calls.value == 1)

        try pairNextAccount(store)
        #expect(service.ownAddresses == ["u2"])
        await service.loadIfNeeded()
        #expect(calls.value == 2)
        #expect(service.custody == .serverHeld)
    }

    @Test func aBootstrapInFlightAcrossTheTeardownIsDropped() async throws {
        let gate = RequestGate()
        let json = json
        let service = PgpSendService(
            client: PgpSendClient(httpClient: HTTPClient(transport: { request in
                await gate.hold()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(json.utf8), response)
            })),
            securePairingStore: try makePairedStore()
        )

        let load = Task { await service.loadIfNeeded() }
        await gate.waitUntilHolding()
        #expect(await AccountTeardown(erasePreservedStore: nil, pgpSendService: service).run())
        await gate.open()
        await load.value

        #expect(service.custody == nil)
        #expect(service.accountAddresses.isEmpty)
    }
}

// MARK: - Compose: encrypted send flow

/// Holds the *first* request that reaches it until `open()`, so a test can act
/// while a request is genuinely in flight. Later callers pass straight
/// through, so a regression shows up as an extra recorded request rather than
/// as a hang.
private actor RequestGate {
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

/// Answers by URL path, so one stub can serve a compose flow that hits
/// bootstrap, the preflight, and two sends. `sends` and `drafts` record every
/// body posted to /api/mail/send and /api/mail/draft in order.
@MainActor
private final class ComposeStub {
    let sends = Box<[String]>([])
    let drafts = Box<[String]>([])
    private let bootstrap: String
    private let check: String
    private let sendResponses: [(status: Int, json: String)]
    private let sendIndex = Box(0)
    private let draftResponse: (status: Int, json: String)
    /// Optional per-path delay hook, for tests that need a request parked.
    private let beforeResponse: (@Sendable (String) async -> Void)?

    init(
        bootstrap: String = #"{"hasIdentity":true,"protection":"server"}"#,
        check: String = #"{"results":[]}"#,
        sendResponses: [(status: Int, json: String)] = [(200, #"{"ok":true,"sentSaved":true}"#)],
        draftResponse: (status: Int, json: String) = (200, #"{"ok":true}"#),
        beforeResponse: (@Sendable (String) async -> Void)? = nil
    ) {
        self.bootstrap = bootstrap
        self.check = check
        self.sendResponses = sendResponses
        self.draftResponse = draftResponse
        self.beforeResponse = beforeResponse
    }

    func makeClient() -> HTTPClient {
        let sends = sends
        let drafts = drafts
        let sendIndex = sendIndex
        let bootstrap = bootstrap
        let check = check
        let sendResponses = sendResponses
        let draftResponse = draftResponse
        let beforeResponse = beforeResponse
        return HTTPClient { request in
            let path = request.url?.path ?? ""
            await beforeResponse?(path)
            let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            var status = 200
            var json = "{}"
            switch path {
            case "/api/pgp/bootstrap":
                json = bootstrap
            case "/api/pgp/recipients/check":
                json = check
            case "/api/mail/draft":
                drafts.mutate { $0.append(body) }
                status = draftResponse.status
                json = draftResponse.json
            case "/api/mail/send":
                sends.mutate { $0.append(body) }
                // Walks the script and then repeats its last entry. An empty
                // script answers 200 {} rather than trapping on the index.
                if !sendResponses.isEmpty {
                    var current = 0
                    sendIndex.mutate {
                        current = min($0, sendResponses.count - 1)
                        $0 = current + 1
                    }
                    status = sendResponses[current].status
                    json = sendResponses[current].json
                }
            default:
                json = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(json.utf8), response)
        }
    }
}

@MainActor
private func makeCompose(
    stub: ComposeStub,
    paired: Bool = true,
    enrolled: Bool = false,
    draftOpener: VaultOpenOutcome = .opened(privateKey: Data("PRIVATE".utf8))
) throws -> ComposeViewModel {
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let pairingStore = try makePairedStore(paired: paired)
    let db = try AppDatabase(inMemory: true)
    let client = stub.makeClient()
    let contacts = ContactsViewModel(repository: ContactSyncRepository(
        client: ContactSyncClient(httpClient: client),
        contactDAO: ContactDAO(modelContainer: db.container),
        cursorStore: ContactCursorStore(defaults: defaults),
        pendingDeletesStore: ContactPendingDeletesStore(defaults: defaults),
        securePairingStore: pairingStore
    ), settingsStore: ContactsSettingsStore(defaults: defaults))
    let mailRepository = MailRepository(
        securePairingStore: pairingStore,
        emailDAO: EmailDAO(modelContainer: db.container),
        httpClient: client
    )
    return ComposeViewModel(
        sendEmail: SendEmailUseCase(repository: mailRepository),
        contacts: contacts,
        pgp: PgpSendService(
            client: PgpSendClient(httpClient: client),
            securePairingStore: pairingStore
        ),
        isLocked: { false },
        isEnrolled: { enrolled },
        makeDraftSaver: { address in
            ClientEncryptedDraftSaver(
                opener: StubDraftOpener(outcome: draftOpener),
                transport: ClientEncryptedDraftClient(
                    httpClient: client, serverUrl: server, auth: RelayAuth(deviceId: "d", deviceSecret: "s")
                ),
                crypto: StubDraftCrypto(),
                accountAddress: address,
                session: EnrollmentSession()
            )
        },
        debounceInterval: .zero
    )
}

private struct StubDraftOpener: VaultOpening {
    var outcome: VaultOpenOutcome
    func open() async -> VaultOpenOutcome { outcome }
}

private struct StubDraftCrypto: PgpEncrypting {
    func encryptAndSign(plaintext: Data, recipientKeys: [String], privateKey: Data) throws -> String {
        "-----BEGIN PGP MESSAGE-----\nOPAQUE\n-----END PGP MESSAGE-----"
    }
    func ownPublicKey(privateKey: Data) throws -> String { "OWN" }
}

/// Compose shows notices verbatim: a lost line continuation shows up as a run
/// of spaces mid-sentence.
private func expectReadable(_ text: String?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(text?.isEmpty == false, sourceLocation: sourceLocation)
    #expect(text?.contains("  ") == false, sourceLocation: sourceLocation)
    #expect(text?.contains("\n") == false, sourceLocation: sourceLocation)
}

private let noTraits: RichTextHTML.FontTraits = { _ in (false, false) }

/// A recorded request body as its parsed JSON fields, so assertions compare
/// what was sent rather than how the encoder happened to order it.
private func fields(_ body: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
}

@Suite @MainActor struct ComposeEncryptedSendTests {
    /// The in-flight guard has to close before the first `await`, not inside
    /// `deliver`. With Encrypt on, the recipient preflight is a live network
    /// round-trip sitting between the two — a second ⌘↩ in that window used to
    /// pass the guard and post the message again.
    @Test func aSecondSendDuringTheRecipientPreflightPostsNothingExtra() async throws {
        let gate = RequestGate()
        let stub = ComposeStub(beforeResponse: { path in
            if path == "/api/pgp/recipients/check" { await gate.hold() }
        })
        let compose = try makeCompose(stub: stub)
        compose.toInput = "alice@example.com"
        compose.encrypt = true

        let first = Task { await compose.send(fontTraits: noTraits) }
        await gate.waitUntilHolding()
        #expect(compose.isSending)

        // A send is not a draft save: Send keeps the spinner.
        #expect(!compose.isSavingDraft)

        // The second ⌘↩, while the first send is parked in its preflight.
        await compose.send(fontTraits: noTraits)

        await gate.open()
        await first.value

        #expect(stub.sends.value.count == 1)
    }

    @Test func encryptAndSignTravelOnTheSendBody() async throws {
        let stub = ComposeStub()
        let compose = try makeCompose(stub: stub)
        compose.toInput = "alice@example.com"
        compose.encrypt = true
        compose.sign = true

        await compose.send(fontTraits: noTraits)

        #expect(compose.didSend)
        #expect(stub.sends.value.count == 1)
        #expect(stub.sends.value[0].contains(#""encrypt":true"#))
        #expect(stub.sends.value[0].contains(#""sign":true"#))
        // The first send never volunteers consent.
        #expect(!stub.sends.value[0].contains("allowPickupFallback"))
    }

    @Test func theKeylessPreflightWarnsWithoutBlocking() async throws {
        let stub = ComposeStub(
            check: #"{"results":[{"address":"bob@example.com","hasKey":false}]}"#
        )
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"
        compose.encrypt = true

        await compose.send(fontTraits: noTraits)

        #expect(compose.keylessWarning == ["bob@example.com"])
        // Warned, and sent anyway: the preflight is contacts-only, so the send
        // path's WKD/keyserver discovery may still find a key.
        #expect(stub.sends.value.count == 1)
        #expect(compose.didSend)
    }

    @Test func noPreflightWhenEncryptIsOff() async throws {
        let stub = ComposeStub(
            check: #"{"results":[{"address":"bob@example.com","hasKey":false}]}"#
        )
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"

        await compose.send(fontTraits: noTraits)

        #expect(compose.keylessWarning.isEmpty)
        #expect(compose.didSend)
    }

    @Test func theKeylessConflictAsksBeforeSendingAnyLink() async throws {
        let conflict = #"{"keylessRecipients":["bob@example.com"],"pickupFallbackAvailable":true}"#
        let stub = ComposeStub(sendResponses: [(409, conflict)])
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"
        compose.encrypt = true

        await compose.send(fontTraits: noTraits)

        // Nothing was delivered and nothing was auto-confirmed.
        #expect(!compose.didSend)
        #expect(compose.pendingPickup?.addresses == ["bob@example.com"])
        #expect(compose.errorMessage == nil)
        let message = compose.pickupConfirmationMessage(for: try #require(compose.pendingPickup))
        #expect(message.contains("bob@example.com"))
        #expect(message.contains("one-time link"))
        #expect(message.contains("unencrypted"))
        #expect(message.contains("7 days"))
        #expect(!message.contains("some recipients"))
    }

    @Test func cancellingSendsNothingMore() async throws {
        let conflict = #"{"keylessRecipients":["bob@example.com"],"pickupFallbackAvailable":true}"#
        let stub = ComposeStub(sendResponses: [(409, conflict)])
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"
        compose.encrypt = true
        await compose.send(fontTraits: noTraits)

        compose.cancelPickupFallback()

        #expect(compose.pendingPickup == nil)
        #expect(stub.sends.value.count == 1)
        #expect(!compose.didSend)
    }

    /// The re-send must be the refused request with one flag flipped — not a
    /// rebuild, which risks a subtly different message.
    @Test func confirmingResendsTheIdenticalBodyPlusTheFlag() async throws {
        let conflict = #"{"keylessRecipients":["bob@example.com"],"pickupFallbackAvailable":true}"#
        let stub = ComposeStub(sendResponses: [
            (409, conflict),
            (200, #"{"ok":true,"sentSaved":true}"#),
        ])
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"
        compose.subject = "Quarterly"
        compose.body = AttributedString("plain words")
        compose.encrypt = true
        compose.sign = true
        await compose.send(fontTraits: noTraits)

        await compose.confirmPickupFallback(try #require(compose.pendingPickup))

        #expect(stub.sends.value.count == 2)
        let first = stub.sends.value[0]
        let second = stub.sends.value[1]
        // Identical apart from the flag. Compared as parsed objects, not as
        // strings: JSON key order is no part of Encodable's contract, and a
        // spurious red on the branch's most load-bearing assertion is exactly
        // the pressure that gets the re-send rule weakened instead. Do not
        // simplify this back to a string comparison.
        var secondFields = try fields(second)
        #expect(secondFields.removeValue(forKey: "allowPickupFallback") as? Bool == true)
        #expect(NSDictionary(dictionary: secondFields) == NSDictionary(dictionary: try fields(first)))
        #expect(compose.didSend)
        #expect(compose.pendingPickup == nil)
    }

    /// Regression test for Critical 1 (whole-branch review): the original bug
    /// was that `confirmPickupFallback()` read `pendingPickup` off `self`, and
    /// SwiftUI's confirmationDialog `isPresented` binding setter clears that
    /// property (via `cancelPickupFallback`) *synchronously* on dismissal,
    /// before the tapped button's own `Task { }` action body ever ran — so
    /// "Send link anyway" silently sent nothing.
    ///
    /// The fix takes the pickup as a required parameter instead of consulting
    /// `pendingPickup`, which makes that exact race structurally impossible:
    /// there is no longer any code path where confirming reads state that a
    /// concurrent cancel could have nilled out from under it. This test pins
    /// that decoupling directly — a `cancelPickupFallback()` call sitting
    /// between capturing the pickup and confirming it must have zero effect on
    /// the confirm, because the confirm never looks at the property cancel
    /// touches.
    @Test func cancellingDoesNotPoisonAConfirmHoldingItsOwnCapturedPickup() async throws {
        let conflict = #"{"keylessRecipients":["bob@example.com"],"pickupFallbackAvailable":true}"#
        let stub = ComposeStub(sendResponses: [
            (409, conflict),
            (200, #"{"ok":true,"sentSaved":true}"#),
        ])
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"
        compose.encrypt = true
        await compose.send(fontTraits: noTraits)
        let pickup = try #require(compose.pendingPickup)

        // Simulates the interleaving that broke the old implementation: the
        // dialog's binding setter (cancel) fires before the button's action
        // body, which already holds its own copy of the value.
        compose.cancelPickupFallback()
        #expect(compose.pendingPickup == nil)

        await compose.confirmPickupFallback(pickup)

        #expect(stub.sends.value.count == 2)
        #expect(compose.didSend)
    }

    @Test func aServerWithPickupLinksOffExplainsInsteadOfAsking() async throws {
        let conflict = #"{"keylessRecipients":["bob@example.com"],"pickupFallbackAvailable":false}"#
        let stub = ComposeStub(sendResponses: [(409, conflict)])
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"
        compose.encrypt = true

        await compose.send(fontTraits: noTraits)

        #expect(compose.pendingPickup == nil)
        #expect(compose.errorMessage?.contains("bob@example.com") == true)
        #expect(!compose.didSend)
    }

    @Test func aWarningIsShownWithoutOfferingARetry() async throws {
        let stub = ComposeStub(sendResponses: [
            (200, #"{"ok":true,"sentSaved":false,"warning":"sent copy not saved"}"#),
        ])
        let compose = try makeCompose(stub: stub)
        compose.toInput = "alice@example.com"

        await compose.send(fontTraits: noTraits)

        #expect(compose.noticeMessage == "sent copy not saved")
        #expect(compose.errorMessage == nil)
        // Sent: the window must not offer a send that would duplicate it, and
        // must not slam shut over the notice.
        #expect(compose.isSent)
        #expect(!compose.didSend)

        await compose.send(fontTraits: noTraits)
        #expect(stub.sends.value.count == 1)
    }

    /// The relay says this account encrypts on the client, and this device
    /// is not enrolled: nothing is uploaded — never a plaintext draft — and
    /// webmail opens with the message still here.
    @Test func theClientSideConflictOnAnUnenrolledDeviceUploadsNoDraft() async throws {
        let stub = ComposeStub(
            bootstrap: #"{"hasIdentity":true,"protection":"client"}"#,
            sendResponses: [(409, #"{"clientSideNeeded":true}"#)]
        )
        let compose = try makeCompose(stub: stub)
        await compose.loadPgpIdentityIfNeeded()
        compose.toInput = "alice@example.com"
        compose.subject = "Quarterly"
        compose.encrypt = true

        await compose.send(fontTraits: noTraits)

        #expect(stub.sends.value.count == 1)
        #expect(stub.drafts.value.isEmpty)
        #expect(compose.webmailHandoffURL?.absoluteString == "\(server)/read?mailbox=Drafts")
        expectReadable(compose.noticeMessage)
        #expect(compose.errorMessage == nil)
        #expect(!compose.isSent)
        #expect(compose.closingNeedsConfirmation)
    }

    /// A clientSideNeeded 409 on an account whose bootstrap said `server` is a
    /// contradiction: refuse, and upload nothing.
    @Test func theClientSideConflictOnAServerCustodyAccountIsRefused() async throws {
        for enrolled in [false, true] {
            let stub = ComposeStub(
                bootstrap: #"{"hasIdentity":true,"protection":"server","suggestedUserIDs":["me@example.com"]}"#,
                sendResponses: [(409, #"{"clientSideNeeded":true}"#)]
            )
            let compose = try makeCompose(stub: stub, enrolled: enrolled)
            await compose.loadPgpIdentityIfNeeded()
            compose.toInput = "alice@example.com"

            await compose.send(fontTraits: noTraits)

            #expect(stub.drafts.value.isEmpty)
            #expect(compose.errorMessage?.isEmpty == false)
            #expect(compose.webmailHandoffURL == nil)
            #expect(!compose.isSent)
        }
    }

    @Test func custodyDrivesWhetherTogglesAreOfferedAtAll() async throws {
        let serverHeld = try makeCompose(stub: ComposeStub())
        await serverHeld.loadPgpIdentityIfNeeded()
        #expect(serverHeld.pgpCustody == .serverHeld)

        let clientHeld = try makeCompose(stub: ComposeStub(
            bootstrap: #"{"hasIdentity":true,"protection":"client"}"#
        ))
        await clientHeld.loadPgpIdentityIfNeeded()
        #expect(clientHeld.pgpCustody == .clientHeld)

        let none = try makeCompose(stub: ComposeStub(bootstrap: #"{"hasIdentity":false}"#))
        await none.loadPgpIdentityIfNeeded()
        #expect(none.pgpCustody == .noIdentity)
    }

    /// The opt-in is per message. A fresh compose never starts consented.
    @Test func consentIsNeverRemembered() async throws {
        let compose = try makeCompose(stub: ComposeStub())
        #expect(!compose.encrypt)
        #expect(!compose.sign)
        #expect(compose.pendingPickup == nil)
    }

    /// The handoff button on an unenrolled device posts nothing at all.
    @Test func theHandoffButtonOnAnUnenrolledDeviceOpensWebmailWithoutUploading() async throws {
        let stub = ComposeStub(bootstrap: #"{"hasIdentity":true,"protection":"client"}"#)
        let compose = try makeCompose(stub: stub)
        await compose.loadPgpIdentityIfNeeded()
        compose.toInput = "alice@example.com"
        compose.subject = "Quarterly"

        await compose.handOffToWebmail(fontTraits: noTraits)

        #expect(stub.drafts.value.isEmpty)
        #expect(stub.sends.value.isEmpty)
        #expect(compose.webmailHandoffURL?.absoluteString == "\(server)/read?mailbox=Drafts")
        expectReadable(compose.noticeMessage)
        #expect(!compose.isSent)
        #expect(compose.closingNeedsConfirmation)

        // The view clears it after opening, so it can't reopen on redraw.
        compose.didOpenWebmail()
        #expect(compose.webmailHandoffURL == nil)
    }

    /// Custody never loaded: the handoff refuses rather than guess.
    @Test func theHandoffWithUnknownCustodyUploadsNothing() async throws {
        let stub = ComposeStub(bootstrap: #"{"hasIdentity":true,"protection":"client"}"#)
        let compose = try makeCompose(stub: stub, enrolled: true)
        compose.toInput = "alice@example.com"

        await compose.handOffToWebmail(fontTraits: noTraits)

        #expect(stub.drafts.value.isEmpty)
        expectReadable(compose.errorMessage)
        #expect(compose.webmailHandoffURL == nil)
    }

    /// An enrolled device saves the draft encrypted, and only `to` and
    /// `pgpDraft` reach the relay.
    @Test func theHandoffOnAnEnrolledDeviceSavesAnEncryptedDraft() async throws {
        let stub = ComposeStub(
            bootstrap: #"{"hasIdentity":true,"protection":"client","suggestedUserIDs":["me@example.com"]}"#
        )
        let compose = try makeCompose(stub: stub, enrolled: true)
        await compose.loadPgpIdentityIfNeeded()
        compose.toInput = "alice@example.com"
        compose.ccInput = "carol@example.com"
        compose.subject = "Quarterly"

        await compose.handOffToWebmail(fontTraits: noTraits)

        #expect(stub.sends.value.isEmpty)
        #expect(stub.drafts.value.count == 1)
        let body = try fields(try #require(stub.drafts.value.first))
        #expect(Set(body.keys) == ["to", "pgpDraft"])
        #expect(body["to"] as? String == "alice@example.com")
        let pgpDraft = try #require(body["pgpDraft"] as? String)
        #expect(!pgpDraft.contains("Quarterly"))
        #expect(!pgpDraft.contains("carol@example.com"))
        #expect(compose.isSent)
        #expect(compose.errorMessage == nil)
        expectReadable(compose.noticeMessage)
        #expect(compose.webmailHandoffURL?.absoluteString == "\(server)/read?mailbox=Drafts")
    }

    /// A failed unlock uploads nothing and leaves the message as it was.
    @Test func aFailedUnlockDuringTheHandoffUploadsNothing() async throws {
        let stub = ComposeStub(
            bootstrap: #"{"hasIdentity":true,"protection":"client","suggestedUserIDs":["me@example.com"]}"#
        )
        let compose = try makeCompose(stub: stub, enrolled: true, draftOpener: .failed("bad seal"))
        await compose.loadPgpIdentityIfNeeded()
        compose.toInput = "alice@example.com"
        compose.subject = "Quarterly"

        await compose.handOffToWebmail(fontTraits: noTraits)

        #expect(stub.drafts.value.isEmpty)
        expectReadable(compose.errorMessage)
        #expect(!compose.isSent)
        #expect(compose.subject == "Quarterly")
        #expect(compose.webmailHandoffURL == nil)

        // A dismissed prompt is not an error.
        let cancelled = try makeCompose(stub: stub, enrolled: true, draftOpener: .cancelled)
        await cancelled.loadPgpIdentityIfNeeded()
        cancelled.toInput = "alice@example.com"
        await cancelled.handOffToWebmail(fontTraits: noTraits)
        #expect(stub.drafts.value.isEmpty)
        #expect(cancelled.errorMessage == nil)
        #expect(!cancelled.isSent)
    }
}

// MARK: - Compose: Save Draft

private let clientBootstrap = #"{"hasIdentity":true,"protection":"client","suggestedUserIDs":["me@example.com"]}"#

extension ComposeEncryptedSendTests {
    /// Server custody: the relay reads this account's sends anyway, so the
    /// draft goes up as it is, and the window may close.
    @Test func saveDraftOnServerCustodyPostsOnePlainDraft() async throws {
        let stub = ComposeStub()
        let compose = try makeCompose(stub: stub)
        await compose.loadPgpIdentityIfNeeded()
        #expect(compose.draftSaveControls == .plain)
        compose.toInput = "alice@example.com"
        compose.ccInput = "carol@example.com"
        compose.subject = "Quarterly"
        compose.body = AttributedString("Numbers attached.")

        await compose.saveDraft(fontTraits: noTraits)

        #expect(stub.drafts.value.count == 1)
        let body = try fields(try #require(stub.drafts.value.first))
        #expect(body["subject"] as? String == "Quarterly")
        #expect((body["cc"] as? String)?.contains("carol@example.com") == true)
        #expect(stub.sends.value.isEmpty)
        #expect(compose.didSaveDraft)
        #expect(!compose.isSent)
        #expect(compose.webmailHandoffURL == nil)
        #expect(compose.errorMessage == nil)
        #expect(!compose.closingNeedsConfirmation)
    }

    /// No PGP identity: a draft needs no recipient.
    @Test func saveDraftWithNoIdentityNeedsNoRecipient() async throws {
        let stub = ComposeStub(bootstrap: #"{"hasIdentity":false}"#)
        let compose = try makeCompose(stub: stub)
        await compose.loadPgpIdentityIfNeeded()
        compose.subject = "Ideas"

        await compose.saveDraft(fontTraits: noTraits)

        #expect(stub.drafts.value.count == 1)
        #expect(compose.didSaveDraft)
        #expect(compose.errorMessage == nil)
    }

    /// Client custody on an enrolled device: only `{to, pgpDraft}` leaves.
    @Test func saveDraftOnClientCustodySavesItEncrypted() async throws {
        let stub = ComposeStub(bootstrap: clientBootstrap)
        let compose = try makeCompose(stub: stub, enrolled: true)
        await compose.loadPgpIdentityIfNeeded()
        #expect(compose.draftSaveControls == .encrypted)
        compose.toInput = "alice@example.com"
        compose.ccInput = "carol@example.com"
        compose.subject = "Quarterly"

        await compose.saveDraft(fontTraits: noTraits)

        #expect(stub.sends.value.isEmpty)
        #expect(stub.drafts.value.count == 1)
        let body = try fields(try #require(stub.drafts.value.first))
        #expect(Set(body.keys) == ["to", "pgpDraft"])
        let pgpDraft = try #require(body["pgpDraft"] as? String)
        #expect(!pgpDraft.contains("Quarterly"))
        #expect(!pgpDraft.contains("carol@example.com"))
        #expect(compose.didSaveDraft)
        #expect(!compose.isSent)
        #expect(compose.webmailHandoffURL == nil)
    }

    /// Nothing may be uploaded where the device holds no key or custody is
    /// not known: the button is hidden, and a call anyway posts nothing.
    @Test func saveDraftUploadsNothingWhenUnavailable() async throws {
        let unenrolled = ComposeStub(bootstrap: clientBootstrap)
        let notLoaded = ComposeStub()
        let failed = ComposeStub(bootstrap: "not json")
        for (stub, load) in [(unenrolled, true), (notLoaded, false), (failed, true)] {
            let compose = try makeCompose(stub: stub)
            if load { await compose.loadPgpIdentityIfNeeded() }
            #expect(compose.draftSaveControls == .unavailable)
            compose.toInput = "alice@example.com"
            compose.subject = "Quarterly"

            await compose.saveDraft(fontTraits: noTraits)

            #expect(stub.drafts.value.isEmpty)
            #expect(stub.sends.value.isEmpty)
            #expect(!compose.didSaveDraft)
            expectReadable(compose.errorMessage)
            #expect(compose.closingNeedsConfirmation)
        }
    }

    @Test func anEncryptedDraftNeedsARecipientInTo() async throws {
        let stub = ComposeStub(bootstrap: clientBootstrap)
        let compose = try makeCompose(stub: stub, enrolled: true)
        await compose.loadPgpIdentityIfNeeded()
        compose.subject = "Quarterly"

        await compose.saveDraft(fontTraits: noTraits)

        #expect(stub.drafts.value.isEmpty)
        #expect(!compose.didSaveDraft)
        #expect(compose.errorMessage == "Add a recipient in To before saving this to Drafts.")
    }

    /// A failed unlock keeps everything; a dismissed one says nothing.
    @Test func aFailedOrCancelledUnlockSavesNothing() async throws {
        let stub = ComposeStub(bootstrap: clientBootstrap)
        let compose = try makeCompose(stub: stub, enrolled: true, draftOpener: .failed("bad seal"))
        await compose.loadPgpIdentityIfNeeded()
        compose.toInput = "alice@example.com"
        compose.subject = "Quarterly"
        compose.attachments = [ComposeAttachment(name: "a.txt", mimeType: "text/plain", data: Data("a".utf8))]

        await compose.saveDraft(fontTraits: noTraits)

        #expect(stub.drafts.value.isEmpty)
        #expect(stub.sends.value.isEmpty)
        expectReadable(compose.errorMessage)
        #expect(!compose.didSaveDraft)
        #expect(!compose.isSent)
        #expect(compose.to.map(\.address) == ["alice@example.com"])
        #expect(compose.subject == "Quarterly")
        #expect(compose.attachments.count == 1)

        let cancelled = try makeCompose(stub: stub, enrolled: true, draftOpener: .cancelled)
        await cancelled.loadPgpIdentityIfNeeded()
        cancelled.toInput = "alice@example.com"
        await cancelled.saveDraft(fontTraits: noTraits)
        #expect(stub.drafts.value.isEmpty)
        #expect(cancelled.errorMessage == nil)
        #expect(!cancelled.didSaveDraft)
    }

    /// Attack path: a stale custody cache, or a relay claiming custody
    /// changed. A refused plain draft is shown as an error and is never
    /// retried, encrypted or otherwise.
    @Test func aRefusedPlainDraftIsNeverRetried() async throws {
        let answers: [(status: Int, json: String)] = [
            (409, #"{"clientSideNeeded":true}"#), (200, "{}"), (502, ""),
        ]
        for answer in answers {
            let stub = ComposeStub(
                bootstrap: #"{"hasIdentity":true,"protection":"server","suggestedUserIDs":["me@example.com"]}"#,
                draftResponse: answer
            )
            let compose = try makeCompose(stub: stub, enrolled: true)
            await compose.loadPgpIdentityIfNeeded()
            compose.toInput = "alice@example.com"
            compose.subject = "Quarterly"

            await compose.saveDraft(fontTraits: noTraits)

            #expect(stub.drafts.value.count == 1, "\(answer.status)")
            #expect(try fields(stub.drafts.value[0])["pgpDraft"] == nil)
            #expect(stub.sends.value.isEmpty)
            expectReadable(compose.errorMessage)
            #expect(!compose.didSaveDraft)
            #expect(compose.subject == "Quarterly")
            #expect(compose.closingNeedsConfirmation)
        }
    }

    @Test func invalidUncommittedRecipientTextSavesNothing() async throws {
        let stub = ComposeStub()
        let compose = try makeCompose(stub: stub)
        await compose.loadPgpIdentityIfNeeded()
        compose.toInput = "not-an-address"

        await compose.saveDraft(fontTraits: noTraits)

        #expect(stub.drafts.value.isEmpty)
        #expect(compose.errorMessage?.isEmpty == false)
        #expect(!compose.didSaveDraft)
    }

    /// A double ⌘S, or ⌘S then ⌘↩, while the first save is in flight posts
    /// nothing extra; nor does a save after one succeeded.
    @Test func aSaveInFlightBlocksASecondSaveAndASend() async throws {
        let gate = RequestGate()
        let stub = ComposeStub(beforeResponse: { path in
            if path == "/api/mail/draft" { await gate.hold() }
        })
        let compose = try makeCompose(stub: stub)
        await compose.loadPgpIdentityIfNeeded()
        compose.toInput = "alice@example.com"

        let first = Task { await compose.saveDraft(fontTraits: noTraits) }
        await gate.waitUntilHolding()
        #expect(compose.isSending)
        // The spinner belongs to Save Draft, not Send.
        #expect(compose.isSavingDraft)

        await compose.saveDraft(fontTraits: noTraits)
        await compose.send(fontTraits: noTraits)

        await gate.open()
        await first.value

        #expect(stub.drafts.value.count == 1)
        #expect(stub.sends.value.isEmpty)
        #expect(compose.didSaveDraft)
        #expect(!compose.isSavingDraft)

        await compose.saveDraft(fontTraits: noTraits)
        #expect(stub.drafts.value.count == 1)
    }
}
