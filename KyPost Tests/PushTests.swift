//
//  PushTests.swift
//  KyPost Tests
//
//  Phase 5 tests: payload mapping, pull dedupe + cursor handoff, synthesized
//  seqs for push-mode arrivals, registration persistence, MFA use case.
//

import Foundation
import Testing
import UserNotifications
@testable import KyPost

// MARK: - Helpers



private func scratchStores() -> (defaults: UserDefaults, keychain: KeychainStorage) {
    (
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
        KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
    )
}

private func makePairing(lastDeviceId: String? = "dev-1", deviceSecret: String = "s1") -> Pairing {
    Pairing(
        sub: "u1", deviceSecret: deviceSecret, srv: server, registrationUrl: nil,
        pairingToken: "pt", lastDeviceId: lastDeviceId, pairedAt: Date()
    )
}

// MARK: - Payload mapping

@Suite struct PushPayloadMapperTests {
    @Test func mapsMailPayloadWithContractKeys() throws {
        // Exact keys from spec §3, including capital-K Keywords.
        let userInfo: [AnyHashable: Any] = [
            "messageId": "m-1",
            "senderName": "Ada",
            "emailSubject": "Hello",
            "Keywords": ["Important", "Work"],
        ]
        guard case .mail(let mail)? = PushPayloadMapper.map(userInfo: userInfo) else {
            Issue.record("Expected mail payload")
            return
        }
        #expect(mail.messageId == "m-1")
        #expect(mail.senderName == "Ada")
        #expect(mail.emailSubject == "Hello")
        #expect(mail.keywords == ["Important", "Work"])
    }

    @Test func mapsCommaJoinedKeywordsFromApnsData() throws {
        // APNs data values are strings; the backend comma-joins Keywords.
        let userInfo: [AnyHashable: Any] = [
            "messageId": "m-3",
            "Keywords": "Important, Work,,Receipts",
        ]
        guard case .mail(let mail)? = PushPayloadMapper.map(userInfo: userInfo) else {
            Issue.record("Expected mail payload")
            return
        }
        #expect(mail.keywords == ["Important", "Work", "Receipts"])
    }

    @Test func mapsMinimalMailPayload() {
        let payload = PushPayloadMapper.map(userInfo: ["messageId": "m-2"])
        #expect(payload == .mail(MailPushPayload(
            messageId: "m-2", senderName: "", emailSubject: "", keywords: []
        )))
    }

    @Test func mapsMfaChallenge() throws {
        let received = Date(timeIntervalSince1970: 1_750_000_000)
        let payload = PushPayloadMapper.map(
            userInfo: ["type": "mfa_challenge", "challengeId": "c-1"],
            receivedAt: received
        )
        #expect(payload == .mfaChallenge(MfaChallenge(challengeId: "c-1", receivedAt: received)))
    }

    @Test func mapsMfaChallengeNumberMatchFields() throws {
        let received = Date(timeIntervalSince1970: 1_750_000_000)
        let payload = PushPayloadMapper.map(
            userInfo: [
                "type": "mfa_challenge",
                "challengeId": "c-1",
                "matchDigits": "47",
                // Comma-joined, same convention as Keywords.
                "decoyDigits": "08,91",
            ],
            receivedAt: received
        )
        #expect(payload == .mfaChallenge(MfaChallenge(
            challengeId: "c-1",
            receivedAt: received,
            matchDigits: "47",
            decoyDigits: ["08", "91"]
        )))
    }

    @Test func dropsMalformedMatchDigits() throws {
        // These drive tap targets on a security screen, so anything that is not
        // a digit run is treated as absent rather than rendered. Width is
        // checked as a range, not against a literal 2 — the mapper validates
        // shape, and whether a set of these adds up to an approvable challenge
        // is MfaNumberMatch.options' decision.
        for bad in ["4x", "", " ", "1234567", "٤٧", "-1"] {
            let payload = PushPayloadMapper.map(
                userInfo: ["type": "mfa_challenge", "challengeId": "c-1", "matchDigits": bad]
            )
            guard case .mfaChallenge(let challenge) = payload else {
                Issue.record("Expected an MFA challenge for matchDigits \(bad.debugDescription)")
                return
            }
            #expect(challenge.matchDigits == "")
        }
    }

    @Test func dropsMalformedDecoyDigitsAndDuplicates() throws {
        let payload = PushPayloadMapper.map(
            userInfo: [
                "type": "mfa_challenge",
                "challengeId": "c-1",
                "matchDigits": "47",
                "decoyDigits": "08,bad,08,,91,1234567",
            ]
        )
        guard case .mfaChallenge(let challenge) = payload else {
            Issue.record("Expected an MFA challenge")
            return
        }
        // Non-digits, blanks, duplicates and over-width values are dropped.
        // A well-formed value of a *different* width than the answer is not
        // dropped here — that mismatch is a whole-challenge judgement, and
        // MfaNumberMatch.options refuses the set rather than quietly rendering
        // a tile that is visibly the odd one out.
        #expect(challenge.decoyDigits == ["08", "91"])
    }

    @Test func keepsWellFormedDigitsOfAnyServerWidth() throws {
        let payload = PushPayloadMapper.map(
            userInfo: [
                "type": "mfa_challenge",
                "challengeId": "c-1",
                "matchDigits": "0471",
                "decoyDigits": "0812,0913",
            ]
        )
        guard case .mfaChallenge(let challenge) = payload else {
            Issue.record("Expected an MFA challenge")
            return
        }
        #expect(challenge.matchDigits == "0471")
        #expect(challenge.decoyDigits == ["0812", "0913"])
    }

    @Test func rejectsUnrecognizedPayloads() {
        #expect(PushPayloadMapper.map(userInfo: [:]) == nil)
        #expect(PushPayloadMapper.map(userInfo: ["foo": "bar"]) == nil)
        // MFA without a challengeId is invalid, not a mail fallback.
        #expect(PushPayloadMapper.map(userInfo: ["type": "mfa_challenge"]) == nil)
        #expect(PushPayloadMapper.map(userInfo: ["messageId": ""]) == nil)
    }
}

// MARK: - Number matching

@Suite struct MfaNumberMatchTests {
    @Test func returnsNilWithoutAUsableNumber() {
        // No number from the server means number matching is unavailable, and
        // the screen then offers Deny only — never a plain Approve button, which
        // is the tap an MFA-fatigue attack is trying to collect.
        #expect(MfaNumberMatch.options(correct: "", serverDecoys: ["08", "91"]) == nil)
        #expect(MfaNumberMatch.options(correct: "4x", serverDecoys: ["08", "91"]) == nil)
        #expect(MfaNumberMatch.options(correct: "1234567", serverDecoys: ["08", "91"]) == nil)
        // Non-ASCII numerals would render a tile that can never match what the
        // browser shows.
        #expect(MfaNumberMatch.options(correct: "٤٧", serverDecoys: ["08", "91"]) == nil)
    }

    @Test func includesTheCorrectValueAmongThreeDistinctOptions() throws {
        let options = try #require(
            MfaNumberMatch.options(correct: "47", serverDecoys: ["08", "91"])
        )
        #expect(options.count == MfaNumberMatch.choiceCount)
        #expect(options.contains("47"))
        #expect(Set(options).count == MfaNumberMatch.choiceCount)
    }

    @Test func refusesToInventDecoysWhenTheServerSendsTooFew() {
        // The client used to fill the gap from an LCG seeded on the challenge
        // id, which made the wrong answers derivable by anyone holding the id
        // — and so the right one derivable by elimination. An incomplete
        // challenge is now simply not approvable from here.
        #expect(MfaNumberMatch.options(correct: "47", serverDecoys: []) == nil)
        #expect(MfaNumberMatch.options(correct: "47", serverDecoys: ["08"]) == nil)
        // A decoy colliding with the answer leaves the set incomplete rather
        // than producing two correct-looking tiles.
        #expect(MfaNumberMatch.options(correct: "47", serverDecoys: ["47", "47"]) == nil)
        #expect(MfaNumberMatch.options(correct: "47", serverDecoys: ["08", "08"]) == nil)
    }

    @Test func refusesMoreDecoysThanTheChoiceShapeAllows() {
        // More than CHOICE_COUNT - 1 means the server and this client disagree
        // about the shape of the choice; silently dropping the extras would
        // hide that.
        #expect(MfaNumberMatch.options(correct: "47", serverDecoys: ["08", "91", "13"]) == nil)
    }

    @Test func rejectsDecoysOfADifferentWidthThanTheAnswer() {
        // A tile that is visibly a different shape from the others gives the
        // answer away without the user ever looking at the browser.
        #expect(MfaNumberMatch.options(correct: "47", serverDecoys: ["8", "91"]) == nil)
        #expect(MfaNumberMatch.options(correct: "47", serverDecoys: ["123", "91"]) == nil)
    }

    @Test func acceptsWhateverDigitWidthTheServerUsed() throws {
        // Width is not pinned to 2: widening the server's value space must not
        // silently disable approval on an already-deployed client.
        for correct in ["4", "047", "004700"] {
            let decoys = ["1", "2"].map { String(repeating: $0, count: correct.count) }
            let options = try #require(
                MfaNumberMatch.options(correct: correct, serverDecoys: decoys)
            )
            #expect(options.count == MfaNumberMatch.choiceCount)
            #expect(options.contains(correct))
        }
    }

    @Test func orderDoesNotPinTheAnswerToOnePosition() {
        // The previous ordering sorted on a hash of (challengeId, value). That
        // expands to H(challengeId) * 31^n + f(value), and since every tile has
        // the same width the challenge-id term is an identical offset on all
        // three and cancels out of every comparison — leaving a plain numeric
        // sort, so the answer sat in the same slot on every challenge.
        let positions = (0..<200).compactMap { _ in
            MfaNumberMatch.options(correct: "47", serverDecoys: ["08", "91"])?
                .firstIndex(of: "47")
        }
        #expect(positions.count == 200)
        #expect(Set(positions).count == MfaNumberMatch.choiceCount)
    }

    @Test func shuffleIsInjectableSoACallerCanPinTheOrder() throws {
        // Callers must shuffle once and keep the result for the life of the
        // challenge; the seam exists so that is testable.
        let options = try #require(
            MfaNumberMatch.options(correct: "47", serverDecoys: ["08", "91"]) { $0.sorted() }
        )
        #expect(options == ["08", "47", "91"])
    }
}

// MARK: - Notification categories

@MainActor
@Suite struct PushNotificationDispatcherCategoryTests {
    @Test func mfaCategoryOffersNoApproveAction() throws {
        // Approving requires the number the browser is showing, which the
        // backend verifies and a banner cannot present. An Approve button here
        // could only send a blind approval — the exact tap an MFA-fatigue
        // attack harvests, and one the server now refuses anyway.
        let mfa = try #require(
            PushNotificationDispatcher.categories.first { $0.identifier == PushNotificationDispatcher.mfaCategoryId }
        )
        #expect(!mfa.actions.contains { $0.identifier == PushNotificationDispatcher.approveActionId })
    }

    @Test func denyActionRemainsDestructiveAndUnauthenticated() throws {
        // Denying isn't a sensitive action, so no reason to gate it — this
        // pins the deny action's options so a future edit can't silently
        // change them alongside the approve fix.
        let mfa = try #require(
            PushNotificationDispatcher.categories.first { $0.identifier == PushNotificationDispatcher.mfaCategoryId }
        )
        let deny = try #require(
            mfa.actions.first { $0.identifier == PushNotificationDispatcher.denyActionId }
        )
        #expect(deny.options == [.destructive])
    }
}

// MARK: - PushRepository

@Suite struct PushRepositoryTests {
    private struct Environment {
        var repository: PushRepository
        var cursorStore: NotificationCursorStore
        var settings: PushSettingsStore
        var pairingStore: SecurePairingStore
    }

    private func makeEnvironment(client: HTTPClient, paired: Bool = true) throws -> Environment {
        let (defaults, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        if paired {
            try pairingStore.savePairing(makePairing())
        }
        let db = try AppDatabase(inMemory: true)
        let cursorStore = NotificationCursorStore(defaults: defaults)
        let settings = PushSettingsStore(defaults: defaults)
        let repository = PushRepository(
            dao: PushNotificationDAO(modelContainer: db.container),
            cursorStore: cursorStore,
            client: PushNotificationClient(httpClient: client),
            securePairingStore: pairingStore,
            pushSettingsStore: settings
        )
        return Environment(
            repository: repository, cursorStore: cursorStore, settings: settings, pairingStore: pairingStore
        )
    }

    /// Pairing another account over this one stores the new pairing only
    /// after the teardown, so the previous one is still readable meanwhile.
    /// A pull started in that window must not use it: no request, no rows,
    /// no cursor. Once the new pairing is saved, pulls work again.
    @MainActor
    @Test func aPullAfterTheTeardownNeverUsesThePairingBeingLeft() async throws {
        let json = #"{"notifications":[{"seq":4,"messageId":"m-4","senderName":"A","emailSubject":"s4"}],"cursor":4}"#
        let requests = Box(0)
        let env = try makeEnvironment(client: stubClient(json: json) { _ in requests.mutate { $0 += 1 } })

        #expect(await AccountTeardown(erasePreservedStore: nil, pushRepository: env.repository).run())
        #expect(try env.pairingStore.loadPairing()?.sub == "u1")

        await #expect(throws: MailSourceError.notPaired) { try await env.repository.pullOnce() }
        #expect(requests.value == 0)
        #expect(try await env.repository.history().isEmpty)
        #expect(env.cursorStore.lastCursor == 0)

        try env.pairingStore.savePairing(Pairing(
            sub: "u2", deviceSecret: "s2", srv: server, registrationUrl: nil,
            pairingToken: "pt2", lastDeviceId: "dev-2", pairedAt: Date().addingTimeInterval(1)
        ))
        try await env.repository.pullOnce()
        #expect(requests.value == 1)
        #expect(try await env.repository.history().map(\.messageId) == ["m-4"])
        #expect(env.cursorStore.lastCursor == 4)
    }

    @Test func pushArrivalsGetUniqueSynthesizedSeqs() async throws {
        let env = try makeEnvironment(client: stubClient())
        let payload = MailPushPayload(
            messageId: "m-1", senderName: "Ada", emailSubject: "Hi", keywords: []
        )
        var other = payload
        other.messageId = "m-2"
        let sameInstant = Date()
        let first = try #require(try await env.repository.recordPushArrival(payload, receivedAt: sameInstant))
        let second = try #require(try await env.repository.recordPushArrival(other, receivedAt: sameInstant))

        #expect(first.seq != second.seq)
        #expect(try await env.repository.history().count == 2)
    }

    /// The same message pushed twice (or pulled by the heartbeat first) is
    /// one history entry, and the second arrival reports nothing new.
    @Test func aRepeatedMessageIdIsRecordedOnce() async throws {
        let env = try makeEnvironment(client: stubClient())
        let payload = MailPushPayload(
            messageId: "m-1", senderName: "Ada", emailSubject: "Hi", keywords: []
        )
        let sameInstant = Date()
        #expect(try await env.repository.recordPushArrival(payload, receivedAt: sameInstant) != nil)
        #expect(try await env.repository.recordPushArrival(payload, receivedAt: sameInstant) == nil)
        #expect(try await env.repository.history().count == 1)
    }

    @Test func pullDeduplicatesBySeqAndAdvancesCursorAfterHandoff() async throws {
        let json = """
        {
          "notifications": [
            { "seq": 3, "messageId": "m-3", "senderName": "A", "emailSubject": "s3" },
            { "seq": 5, "messageId": "m-5", "senderName": "B", "emailSubject": "s5" }
          ],
          "cursor": 5
        }
        """
        let client = stubClient(json: json) { request in
            let url = request.url!.absoluteString
            #expect(url.hasPrefix("\(server)/api/notifications/native/pull?"))
            #expect(url.contains("after=3"))
            #expect(!url.contains("sub="))
            #expect(!url.contains("hash="))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "dev-1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") != nil)
        }
        let env = try makeEnvironment(client: client)
        env.cursorStore.advance(to: 3)

        let delivered = try await env.repository.pullOnce()
        // seq 3 <= cursor: deduped; only seq 5 is new.
        #expect(delivered.mail.map(\.seq) == [5])
        #expect(env.cursorStore.lastCursor == 5)
        #expect(try await env.repository.history().map(\.seq) == [5])
    }

    @Test func storedPullEndpointOverridesDerivedOne() async throws {
        let client = stubClient(json: #"{"notifications": [], "cursor": 0}"#) { request in
            #expect(request.url!.absoluteString.hasPrefix("https://pull.example.com/custom?"))
        }
        let env = try makeEnvironment(client: client)
        env.settings.pullEndpoint = "https://pull.example.com/custom"
        _ = try await env.repository.pullOnce()
    }

    @Test func pullWithoutPairingThrows() async throws {
        let env = try makeEnvironment(client: stubClient(), paired: false)
        await #expect(throws: MailSourceError.notPaired) {
            try await env.repository.pullOnce()
        }
    }
}

// MARK: - DeviceRegistrationService

// DeviceRegistrationService is @MainActor: `inFlight` is unsynchronised
// mutable state, and every production caller already runs there.
@MainActor
@Suite struct DeviceRegistrationServiceTests {
    private struct Environment {
        var service: DeviceRegistrationService
        var pairingStore: SecurePairingStore
        var settings: PushSettingsStore
        /// Every pairing connection the service opened, in order.
        var connections: StubPairingConnections
    }

    private func makeEnvironment(
        client: HTTPClient,
        paired: Bool = false,
        observed: String? = "hash-observed"
    ) throws -> Environment {
        let (defaults, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        if paired {
            try pairingStore.savePairing(makePairing())
        }
        let settings = PushSettingsStore(defaults: defaults)
        let connections = StubPairingConnections(client: client, observed: observed)
        let service = makeRegistrationService(
            client: client, pairingStore: pairingStore, settings: settings, connections: connections
        )
        return Environment(service: service, pairingStore: pairingStore, settings: settings, connections: connections)
    }


    private let params = PairingParams(sub: "u1", srv: server, pt: "pt-1")

    @Test func successfulPairingPersistsEverything() async throws {
        let json = #"{"ok": true, "deviceId": "dev-7", "deviceSecret": "s-7", "deliveryMode": "pull"}"#
        let env = try makeEnvironment(client: stubClient(json: json))

        let outcome = await env.service.pair(params: params, deviceToken: "apns-token")
        guard case .success = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }

        let pairing = try #require(try env.pairingStore.loadPairing())
        #expect(pairing.sub == "u1")
        #expect(pairing.lastDeviceId == "dev-7")
        #expect(pairing.deviceSecret == "s-7")
        #expect(env.settings.deliveryMode == .pull)
        // pullEndpoint absent in response → derived from srv (spec §3).
        #expect(env.settings.pullEndpoint == "\(server)/api/notifications/native/pull")
    }

    /// Pairing another account over this one, with no unpair in between,
    /// erases the previous account's state first; re-pairing the same one
    /// does not.
    @Test func pairingAnotherAccountRunsTheReplacementHookFirst() async throws {
        let json = #"{"ok": true, "deviceId": "dev-7", "deviceSecret": "s-7"}"#
        let env = try makeEnvironment(client: stubClient(json: json), paired: true)
        let subsSeen = Box<[String?]>([])
        env.service.onAccountReplaced = { [pairingStore = env.pairingStore] in
            // Still the previous pairing: the hook runs before the save.
            subsSeen.mutate { $0.append(try? pairingStore.loadPairing()?.sub) }
            return true
        }

        _ = await env.service.pair(params: params, deviceToken: "t1")
        #expect(subsSeen.value.isEmpty)

        _ = await env.service.pair(params: PairingParams(sub: "u2", srv: server, pt: "pt-2"), deviceToken: "t1")
        #expect(subsSeen.value == ["u1"])
        #expect(try env.pairingStore.loadPairing()?.sub == "u2")

        _ = await env.service.pair(params: PairingParams(sub: "u2", srv: "https://other.example", pt: "pt-3"), deviceToken: "t1")
        #expect(subsSeen.value == ["u1", "u2"])
    }

    /// A teardown that could not erase the previous account's data leaves
    /// the new pairing unsaved, and the previous one in place so a retry
    /// runs the teardown again.
    @Test func anIncompleteTeardownLeavesTheNewPairingUnsaved() async throws {
        let json = #"{"ok": true, "deviceId": "dev-7", "deviceSecret": "s-7"}"#
        let env = try makeEnvironment(client: stubClient(json: json), paired: true)
        let runs = Box(0)
        env.service.onAccountReplaced = {
            runs.mutate { $0 += 1 }
            return runs.value > 1
        }
        let other = PairingParams(sub: "u2", srv: server, pt: "pt-2")

        let first = await env.service.pair(params: other, deviceToken: "t1")
        guard case .failure = first else {
            Issue.record("Expected failure, got \(first)")
            return
        }
        #expect(try env.pairingStore.loadPairing()?.sub == "u1")

        _ = await env.service.pair(params: other, deviceToken: "t1")
        #expect(runs.value == 2)
        #expect(try env.pairingStore.loadPairing()?.sub == "u2")
    }

    @Test func failedPairingSavesNothing() async throws {
        let env = try makeEnvironment(client: stubClient(status: 403))
        let outcome = await env.service.pair(params: params, deviceToken: "t")
        #expect(outcome == .unauthorized)
        #expect(try env.pairingStore.loadPairing() == nil)
        #expect(env.settings.deliveryMode == nil)
    }

    @Test func reregisterUsesStoredPairing() async throws {
        let client = stubClient(json: #"{"ok": true, "deviceId": "dev-8"}"#) { request in
            #expect(
                request.url!.absoluteString
                    == "\(server)/api/notifications/native/register"
            )
            // Register sends no header-based auth at all, initial or
            // re-registration alike — see NativeRegistrationClient.register.
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == nil)
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == nil)
        }
        let env = try makeEnvironment(client: client, paired: true)
        let outcome = await env.service.reregisterIfPaired(deviceToken: "t2")
        #expect(outcome != nil)
        #expect(try env.pairingStore.loadPairing()?.lastDeviceId == "dev-8")
    }

    /// Routine re-registration does not restart the heartbeat's quiet clock:
    /// hourly foregrounds with no push must not postpone the heartbeat past
    /// three hours from the original registration.
    @Test func reregistrationKeepsTheHeartbeatQuietClock() async throws {
        let client = stubClient(json: #"{"ok": true, "deviceId": "dev-8", "deviceSecret": "s-8"}"#)
        let env = try makeEnvironment(client: client)
        // A new pairing starts the clock.
        guard case .success = await env.service.pair(params: params, deviceToken: "t1") else {
            Issue.record("pairing failed")
            return
        }
        #expect(env.settings.lastRegisteredAt != nil)

        let paired = try makeEnvironment(client: client, paired: true)
        let initial = Date().addingTimeInterval(-3 * 60 * 60)
        paired.settings.lastRegisteredAt = initial
        for _ in 0..<3 {
            _ = await paired.service.reregisterIfPaired(deviceToken: "t2")
        }
        #expect(paired.settings.lastRegisteredAt == initial)
        #expect(PullHeartbeatPolicy.decide(
            mode: .push, lastPushReceivedAt: nil,
            lastRegisteredAt: paired.settings.lastRegisteredAt, lastPulledAt: nil, now: Date()
        ) == .poll(heartbeat: true))
    }

    /// Every successful register mints a brand-new secret, invalidating the
    /// previous one — the stored value must be overwritten, not kept.
    @Test func reregisterOverwritesStoredDeviceSecret() async throws {
        let client = stubClient(json: #"{"ok": true, "deviceId": "dev-8", "deviceSecret": "new-secret"}"#)
        let env = try makeEnvironment(client: client, paired: true)
        let before = try #require(try env.pairingStore.loadPairing())
        #expect(before.deviceSecret == "s1")

        let outcome = await env.service.reregisterIfPaired(deviceToken: "t2")

        #expect(outcome != nil)
        #expect(try env.pairingStore.loadPairing()?.deviceSecret == "new-secret")
    }

    @Test func reregisterWithoutPairingIsNoOp() async throws {
        let env = try makeEnvironment(client: stubClient(), paired: false)
        let outcome = await env.service.reregisterIfPaired(deviceToken: "t")
        #expect(outcome == nil)
    }

    // MARK: - Certificate pinning at pairing

    private let relayHost = "relay.example.com"

    /// Trust on first use, tied to the pairing's own connection: the probe's
    /// hash becomes the pin before the registration goes out, and that is
    /// the pin stored.
    @Test func theFirstPairingPinsTheProbedKeyBeforeRegistering() async throws {
        let json = #"{"ok": true, "deviceId": "dev-7", "deviceSecret": "s-7"}"#
        let env = try makeEnvironment(client: stubClient(json: json), observed: "hash-first")

        let outcome = await env.service.pair(params: params, deviceToken: "t")

        guard case .success = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }
        let connection = try #require(env.connections.last)
        #expect(connection.host == relayHost)
        #expect(connection.initialPin == nil)
        #expect(connection.pinAtRegister == .some("hash-first"))
        #expect(connection.isClosed)
        #expect(try env.pairingStore.pinnedSpkiHash(forHost: relayHost) == "hash-first")
    }

    /// No hash, no pairing. Pairing unpinned and hoping a later handshake
    /// supplies one is exactly the capture this replaces.
    @Test func aPairingWithNoObservableHandshakeFails() async throws {
        let posts = Box<Int>(0)
        let env = try makeEnvironment(client: stubClient { request in
            if request.httpMethod == "POST" { posts.mutate { $0 += 1 } }
        }, observed: nil)

        let outcome = await env.service.pair(params: params, deviceToken: "t")

        guard case .failure = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(posts.value == 0)
        #expect(try env.pairingStore.loadPairing() == nil)
        #expect(env.connections.last?.isClosed == true)
    }

    /// The registration rides the pairing's connection, never the shared
    /// session background sync uses — that is where a pin the link supplied
    /// would otherwise have leaked.
    @Test func aPairingNeverRidesTheSharedSession() async throws {
        let sharedRequests = Box<Int>(0)
        let shared = stubClient { _ in sharedRequests.mutate { $0 += 1 } }
        let (defaults, keychain) = scratchStores()
        let connections = StubPairingConnections(
            client: stubClient(json: #"{"ok": true, "deviceId": "dev-7"}"#)
        )
        let service = makeRegistrationService(
            client: shared,
            pairingStore: SecurePairingStore(keychain: keychain),
            settings: PushSettingsStore(defaults: defaults),
            connections: connections
        )
        var pinned = params
        pinned.pin = "hash-observed"

        _ = await service.pair(params: pinned, deviceToken: "t")

        #expect(sharedRequests.value == 0)
        #expect(connections.last?.registrations == 1)
    }

    /// Re-registration runs on every foreground and APNs token refresh. A
    /// pin captured there would be whatever that network presented.
    @Test func reregistrationNeverCapturesAFirstPin() async throws {
        let env = try makeEnvironment(client: stubClient(json: #"{"ok": true, "deviceId": "dev-8"}"#), paired: true)

        _ = await env.service.reregisterIfPaired(deviceToken: "t2")

        #expect(env.connections.opened.isEmpty)
        #expect(try env.pairingStore.pinnedSpkiHash(forHost: relayHost) == nil)
    }

    @Test func reregistrationKeepsTheStoredPin() async throws {
        let env = try makeEnvironment(client: stubClient(json: #"{"ok": true, "deviceId": "dev-8"}"#), paired: true)
        try env.pairingStore.setPinnedSpkiHash("hash-first", forHost: relayHost)

        _ = await env.service.reregisterIfPaired(deviceToken: "t2")

        #expect(env.connections.opened.isEmpty)
        #expect(try env.pairingStore.pinnedSpkiHash(forHost: relayHost) == "hash-first")
        #expect(PairingParams(pairing: makePairing()).pin == nil)
    }

    // MARK: - Server-published pin (`pin=`)

    /// The registration POST discloses the pairing token and the push
    /// endpoint and receives the device secret, so the link's pin must hold
    /// the connection from its first handshake, not from after the response.
    @Test func theLinkPinHoldsThePairingConnectionFromItsFirstHandshake() async throws {
        let json = #"{"ok": true, "deviceId": "dev-7", "deviceSecret": "s-7"}"#
        let env = try makeEnvironment(client: stubClient(json: json), observed: "hash-from-link")

        var pinned = params
        pinned.pin = "hash-from-link"
        _ = await env.service.pair(params: pinned, deviceToken: "t")

        let connection = try #require(env.connections.last)
        #expect(connection.initialPin == "hash-from-link")
        #expect(connection.pinAtRegister == .some("hash-from-link"))
        #expect(try env.pairingStore.pinnedSpkiHash(forHost: relayHost) == "hash-from-link")
    }

    /// The pairing token must not leave until a live handshake has shown the
    /// relay actually presents the link's key.
    @Test func aRelayPresentingTheWrongKeyIsRefusedBeforeAnythingIsSent() async throws {
        let posts = Box<Int>(0)
        let env = try makeEnvironment(client: stubClient { request in
            if request.httpMethod == "POST" { posts.mutate { $0 += 1 } }
        }, observed: "hash-the-relay-really-has")

        var pinned = params
        pinned.pin = "hash-from-link"
        let outcome = await env.service.pair(params: pinned, deviceToken: "t")

        guard case .failure = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(posts.value == 0, "the pairing token must not be sent to a relay failing the pin")
        #expect(env.connections.last?.registrations == 0)
        #expect(try env.pairingStore.loadPairing() == nil)
        #expect(try env.pairingStore.pinnedSpkiHash(forHost: relayHost) == nil)
    }

    @Test func anUnobservableHandshakeRefusesRatherThanPairingUnpinned() async throws {
        let posts = Box<Int>(0)
        let env = try makeEnvironment(client: stubClient { request in
            if request.httpMethod == "POST" { posts.mutate { $0 += 1 } }
        }, observed: nil)

        var pinned = params
        pinned.pin = "hash-from-link"
        let outcome = await env.service.pair(params: pinned, deviceToken: "t")

        guard case .failure = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(posts.value == 0)
        #expect(try env.pairingStore.loadPairing() == nil)
    }

    /// A link cannot replace a pin this device already holds for the host.
    /// Removing the pairing is the documented rotation recovery; a link that
    /// swapped the pin in would let whoever crafts links re-pin the relay.
    @Test func aLinkPinThatDiffersFromTheStoredPinIsRefused() async throws {
        let env = try makeEnvironment(client: stubClient(), paired: true, observed: "hash-renewed")
        try env.pairingStore.setPinnedSpkiHash("hash-old", forHost: relayHost)

        var pinned = params
        pinned.pin = "hash-renewed"
        let outcome = await env.service.pair(params: pinned, deviceToken: "t")

        guard case .failure(let message) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(message.contains("Settings → Connection"))
        #expect(env.connections.opened.isEmpty, "refused before any connection")
        #expect(try env.pairingStore.pinnedSpkiHash(forHost: relayHost) == "hash-old")
        #expect(try env.pairingStore.loadPairing()?.pairingToken == "pt")
    }

    @Test func aLinkPinMatchingTheStoredPinPairs() async throws {
        let json = #"{"ok": true, "deviceId": "dev-9", "deviceSecret": "s-9"}"#
        let env = try makeEnvironment(client: stubClient(json: json), paired: true, observed: "hash-same")
        try env.pairingStore.setPinnedSpkiHash("hash-same", forHost: relayHost)

        var pinned = params
        pinned.pin = "hash-same"
        let outcome = await env.service.pair(params: pinned, deviceToken: "t")

        guard case .success = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }
        #expect(env.connections.last?.initialPin == "hash-same")
        #expect(try env.pairingStore.pinnedSpkiHash(forHost: relayHost) == "hash-same")
    }

    /// A link without a pin to an already pinned host is held to the stored
    /// pin, not re-trusted on first use.
    @Test func aStoredPinGovernsALinkWithoutOne() async throws {
        let posts = Box<Int>(0)
        let env = try makeEnvironment(client: stubClient { request in
            if request.httpMethod == "POST" { posts.mutate { $0 += 1 } }
        }, paired: true, observed: "hash-attacker")
        try env.pairingStore.setPinnedSpkiHash("hash-real-relay", forHost: relayHost)

        let outcome = await env.service.pair(params: params, deviceToken: "t")

        guard case .failure(let message) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(message.contains("Settings → Connection"))
        #expect(env.connections.last?.initialPin == "hash-real-relay")
        #expect(posts.value == 0)
        #expect(try env.pairingStore.pinnedSpkiHash(forHost: relayHost) == "hash-real-relay")
    }

    /// Moving to another server leaves the old server's pin behind and pins
    /// the new one on its own first handshake.
    @Test func pairingAnotherServerReplacesTheOldHostsPin() async throws {
        let json = #"{"ok": true, "deviceId": "dev-9", "deviceSecret": "s-9"}"#
        let env = try makeEnvironment(client: stubClient(json: json), paired: true, observed: "hash-other")
        try env.pairingStore.setPinnedSpkiHash("hash-old", forHost: relayHost)

        let outcome = await env.service.pair(
            params: PairingParams(sub: "u1", srv: "https://other.example.com", pt: "pt-2"),
            deviceToken: "t"
        )

        guard case .success = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }
        #expect(env.connections.last?.initialPin == nil)
        #expect(try env.pairingStore.pinnedSpkiHash(forHost: "other.example.com") == "hash-other")
        #expect(try env.pairingStore.pinnedSpkiHash(forHost: relayHost) == nil)
    }

    /// Clearing the pairing is the documented rotation recovery, so the next
    /// pairing must be free to pin again.
    @Test func pinningResumesAfterThePairingIsCleared() async throws {
        let json = #"{"ok": true, "deviceId": "dev-7", "deviceSecret": "s-7"}"#
        let env = try makeEnvironment(client: stubClient(json: json), paired: true, observed: "hash-rotated")
        try env.pairingStore.setPinnedSpkiHash("hash-first", forHost: relayHost)

        try env.pairingStore.clear()
        _ = await env.service.pair(params: params, deviceToken: "t")

        #expect(try env.pairingStore.pinnedSpkiHash(forHost: relayHost) == "hash-rotated")
    }

    // MARK: - Announcing a pairing

    /// Screens showing "not paired" load as soon as a pairing lands; a
    /// routine re-registration is not a new pairing and stays quiet.
    @Test func onlyANewPairingIsAnnounced() async throws {
        let json = #"{"ok": true, "deviceId": "dev-7", "deviceSecret": "s-7"}"#
        let env = try makeEnvironment(client: stubClient(json: json))
        let announced = Box(0)
        let observation = NotificationObservation(center: .default, name: .kyPostPaired) {
            announced.mutate { $0 += 1 }
        }

        _ = await env.service.pair(params: params, deviceToken: "t")
        #expect(announced.value == 1)

        _ = await env.service.reregisterIfPaired(deviceToken: "t2")
        #expect(announced.value == 1)
        withExtendedLifetime(observation) {}
    }

    // MARK: - A reset ends registrations in flight

    /// A registration held in flight across a session reset (wipe,
    /// failed-unlock reset, unpair) must not put the erased pairing back
    /// when its answer finally lands — the reset also left the app unlocked.
    @Test func aPairingAnsweredAfterASessionResetStoresNothing() async throws {
        let requested = Box(false)
        let released = Box(false)
        let held = HTTPClient { request in
            requested.value = true
            while !released.value { try await Task.sleep(for: .milliseconds(5)) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"ok": true, "deviceId": "dev-7", "deviceSecret": "s-7"}"#.utf8), response)
        }
        let (defaults, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        let center = NotificationCenter()
        // The connection registers over `held`, so the answer can be delayed.
        let heldConnections = StubPairingConnections(client: held)
        let service = DeviceRegistrationService(
            client: NativeRegistrationClient(httpClient: stubClient()),
            securePairingStore: pairingStore,
            pushSettingsStore: PushSettingsStore(defaults: defaults),
            notificationCenter: center,
            makePairingConnection: { heldConnections.make(host: $0, pin: $1) }
        )
        let announced = Box(0)
        let observation = NotificationObservation(center: .default, name: .kyPostPaired) {
            announced.mutate { $0 += 1 }
        }

        let attempt = Task { await service.pair(params: params, deviceToken: "t") }
        while !requested.value { try await Task.sleep(for: .milliseconds(5)) }
        center.post(name: .kyPostSessionReset, object: nil)
        #expect(heldConnections.last?.isClosed == true, "the reset closes the pairing connection")
        released.value = true
        let outcome = await attempt.value

        guard case .failure = outcome else {
            Issue.record("expected the cancelled pairing to fail, got \(outcome)")
            return
        }
        #expect(try pairingStore.loadPairing() == nil)
        #expect(try pairingStore.pinnedSpkiHash(forHost: relayHost) == nil)
        #expect(announced.value == 0)
        withExtendedLifetime(observation) {}
    }

    /// Same for a re-registration: an unpair that lands while it is in
    /// flight must not be undone by its answer.
    @Test func aReregistrationAnsweredAfterCancelAllStoresNothing() async throws {
        let requested = Box(false)
        let released = Box(false)
        let held = HTTPClient { request in
            requested.value = true
            while !released.value { try await Task.sleep(for: .milliseconds(5)) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"ok": true, "deviceId": "dev-8", "deviceSecret": "s-8"}"#.utf8), response)
        }
        let env = try makeEnvironment(client: held, paired: true)

        let attempt = Task { await env.service.reregisterIfPaired(deviceToken: "t2") }
        while !requested.value { try await Task.sleep(for: .milliseconds(5)) }
        try env.pairingStore.clear()
        env.service.cancelAll()
        released.value = true
        _ = await attempt.value

        #expect(try env.pairingStore.loadPairing() == nil)
    }

    /// Graph shutdown cancels `relaySession`, which pairing does not ride,
    /// so it must reach the pairing service itself.
    @Test func graphShutdownCancelsPairingInFlight() async throws {
        let requested = Box(false)
        let released = Box(false)
        let held = HTTPClient { request in
            requested.value = true
            while !released.value { try await Task.sleep(for: .milliseconds(5)) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"ok": true, "deviceId": "dev-7", "deviceSecret": "s-7"}"#.utf8), response)
        }
        let graph = try SingletonGraph(
            userDefaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!,
            keychain: KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)"),
            database: AppDatabase(inMemory: true)
        )
        let connections = StubPairingConnections(client: held)
        let service = graph.deviceRegistrationService
        service.makePairingConnection = { connections.make(host: $0, pin: $1) }

        let attempt = Task { await service.pair(params: params, deviceToken: "t") }
        while !requested.value { try await Task.sleep(for: .milliseconds(5)) }
        graph.shutdown()
        #expect(connections.last?.isClosed == true)
        released.value = true
        _ = await attempt.value

        #expect(try graph.securePairingStore.loadPairing() == nil)
    }

    @Test func aRefusedPairingIsNotAnnounced() async throws {
        let env = try makeEnvironment(client: stubClient(), observed: nil)
        let announced = Box(0)
        let observation = NotificationObservation(center: .default, name: .kyPostPaired) {
            announced.mutate { $0 += 1 }
        }

        _ = await env.service.pair(params: params, deviceToken: "t")

        #expect(announced.value == 0)
        withExtendedLifetime(observation) {}
    }

    /// Re-registration must carry the stored deviceId so the server updates
    /// the existing device row instead of pairing the computer again.
    @Test func reregisterSendsStoredDeviceId() async throws {
        let client = stubClient(json: #"{"ok": true, "deviceId": "dev-1"}"#) { request in
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""deviceId":"dev-1""#))
        }
        let env = try makeEnvironment(client: client, paired: true)
        let outcome = await env.service.reregisterIfPaired(deviceToken: "t2")
        #expect(outcome != nil)
    }

    /// First pairing has no deviceId yet — the server mints one.
    @Test func initialPairingOmitsDeviceId() async throws {
        let client = stubClient(json: #"{"ok": true, "deviceId": "dev-9"}"#) { request in
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(!body.contains(#""deviceId""#))
        }
        let env = try makeEnvironment(client: client)
        let outcome = await env.service.pair(params: params, deviceToken: "t")
        guard case .success = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }
    }
}

// MARK: - PushPairingViewModel confirmation flow (pairing-hijack fix)

@MainActor
@Suite struct PushPairingViewModelTests {
    private func makeViewModel(paired: Bool = false) throws -> PushPairingViewModel {
        let (defaults, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        if paired {
            try pairingStore.savePairing(makePairing())
        }
        return PushPairingViewModel(
            registrationService: makeRegistrationService(
                client: stubClient(),
                pairingStore: pairingStore,
                settings: PushSettingsStore(defaults: defaults)
            ),
            pushSettingsStore: PushSettingsStore(defaults: defaults),
            securePairingStore: pairingStore
        )
    }

    private let params = PairingParams(sub: "u1", srv: "https://relay.example.com", pt: "pt-1")

    @Test func presentShowsTheDestinationHostBeforeAnyNetworkCall() throws {
        let viewModel = try makeViewModel(paired: false)
        viewModel.present(params: params)
        #expect(viewModel.state == .confirming(
            PendingPairingConfirmation(params: params, existingHost: nil)
        ))
    }

    @Test func presentWarnsWhenAcceptingWouldReplaceAnExistingPairing() throws {
        let viewModel = try makeViewModel(paired: true)
        viewModel.present(params: params)
        #expect(viewModel.state == .confirming(
            PendingPairingConfirmation(params: params, existingHost: URL(string: server)?.host)
        ))
    }

    @Test func pairFromPastedLinkAsksForConfirmationInsteadOfPairingImmediately() async throws {
        let viewModel = try makeViewModel()
        viewModel.pastedLink = "kypost://native-pair?sub=u1&srv=https://relay.example.com&pt=pt-1"
        await viewModel.pairFromPastedLink()
        guard case .confirming(let confirmation) = viewModel.state else {
            Issue.record("Expected .confirming, got \(viewModel.state)")
            return
        }
        #expect(confirmation.params == params)
    }

    @Test func pairFromScannedCodeAsksForConfirmationInsteadOfPairingImmediately() async throws {
        let viewModel = try makeViewModel()
        await viewModel.pairFromScannedCode("kypost://native-pair?sub=u1&srv=https://relay.example.com&pt=pt-1")
        guard case .confirming(let confirmation) = viewModel.state else {
            Issue.record("Expected .confirming, got \(viewModel.state)")
            return
        }
        #expect(confirmation.params == params)
    }

    @Test func confirmingThenPairStillCompletesRegistration() async throws {
        let (defaults, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        let viewModel = PushPairingViewModel(
            registrationService: makeRegistrationService(
                client: stubClient(json: #"{"ok": true, "deviceId": "dev-7"}"#),
                pairingStore: pairingStore,
                settings: PushSettingsStore(defaults: defaults)
            ),
            pushSettingsStore: PushSettingsStore(defaults: defaults),
            securePairingStore: pairingStore
        )
        viewModel.present(params: params)
        await viewModel.pair(params: params)
        guard case .paired = viewModel.state else {
            Issue.record("Expected .paired, got \(viewModel.state)")
            return
        }
    }

    @Test func resetReturnsToIdleFromConfirming() throws {
        let viewModel = try makeViewModel()
        viewModel.present(params: params)
        viewModel.reset()
        #expect(viewModel.state == .idle)
    }
}

// MARK: - What an unpaired device says

@Suite struct PairingInstructionsTests {
    /// Mail needs the native pairing, and the web's "Pair this device" button
    /// is what emits its link; the Mac says exactly that.
    @Test func theMacNamesTheWebPageAndTheNativePairLink() {
        #if os(macOS)
        for text in [PairingInstructions.inbox, PairingInstructions.macConnection] {
            #expect(text.contains("Settings → Security → Devices"))
            #expect(text.contains("Pair this device"))
            #expect(text.contains("kypost://native-pair"))
            #expect(!text.contains("desktop-pair"))
        }
        #endif
    }
}

// MARK: - DeviceRegistrationService dedupe (one registration per click)

@MainActor
@Suite struct DeviceRegistrationServiceDedupeTests {
    private let params = PairingParams(sub: "u1", srv: server, pt: "pt-1")

    private func makeService(counter: Box<Int>) -> DeviceRegistrationService {
        let client = HTTPClient { request in
            counter.mutate { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(10))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"ok": true, "deviceId": "dev-7"}"#.utf8), response)
        }
        let (defaults, keychain) = scratchStores()
        return makeRegistrationService(
            client: client,
            pairingStore: SecurePairingStore(keychain: keychain),
            settings: PushSettingsStore(defaults: defaults)
        )
    }

    /// The pairing deep link is delivered to every open main window and each
    /// auto-pairs; concurrent calls with one pairing token + device token
    /// must collapse into a single registration.
    @Test func concurrentPairsWithSameTokensRegisterOnce() async {
        let counter = Box<Int>(0)
        let service = makeService(counter: counter)
        async let first = service.pair(params: params, deviceToken: "t")
        async let second = service.pair(params: params, deviceToken: "t")
        _ = await [first, second]
        #expect(counter.value == 1)
    }

    /// A refreshed APNs token is a different registration and must not be
    /// swallowed by the dedupe guard.
    @Test func newDeviceTokenRegistersAgain() async {
        let counter = Box<Int>(0)
        let service = makeService(counter: counter)
        _ = await service.pair(params: params, deviceToken: "t1")
        _ = await service.pair(params: params, deviceToken: "t2")
        #expect(counter.value == 2)
    }
}

// MARK: - ApproveMfaChallengeUseCase

@Suite struct ApproveMfaChallengeUseCaseTests {
    private func makeUseCase(client: HTTPClient, paired: Bool) throws -> ApproveMfaChallengeUseCase {
        let (_, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        if paired {
            try pairingStore.savePairing(makePairing())
        }
        return ApproveMfaChallengeUseCase(
            client: MfaResponseClient(httpClient: client),
            securePairingStore: pairingStore
        )
    }

    @Test func approvesThroughPairedServer() async throws {
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString.hasPrefix("\(server)/api/mfa/push/respond"))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "dev-1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "s1")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""challengeId":"c-1""#))
            #expect(!body.contains("subscriberId"))
            #expect(!body.contains("subscriberHash"))
            #expect(!body.contains("deviceId"))
            #expect(body.contains(#""approve":true"#))
            // Threaded from the approval screen through to the wire — the
            // backend refuses an approval that does not carry it.
            #expect(body.contains(#""matchDigits":"47""#))
        }
        let useCase = try makeUseCase(client: client, paired: true)
        let outcome = await useCase(challengeId: "c-1", approved: true, matchDigits: "47")
        #expect(outcome == .success)
    }

    @Test func failsWhenUnpaired() async throws {
        let useCase = try makeUseCase(client: stubClient(), paired: false)
        let outcome = await useCase(challengeId: "c-1", approved: false)
        #expect(outcome == .failure("Device is not paired"))
    }

    @Test func failsWithoutDeviceId() async throws {
        let (_, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        try pairingStore.savePairing(makePairing(lastDeviceId: nil))
        let useCase = ApproveMfaChallengeUseCase(
            client: MfaResponseClient(httpClient: stubClient()),
            securePairingStore: pairingStore
        )
        let outcome = await useCase(challengeId: "c-1", approved: true)
        guard case .failure = outcome else {
            Issue.record("Expected failure without a device ID, got \(outcome)")
            return
        }
    }

    @Test func failsWithoutDeviceSecret() async throws {
        let (_, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        try pairingStore.savePairing(makePairing(deviceSecret: ""))
        let useCase = ApproveMfaChallengeUseCase(
            client: MfaResponseClient(httpClient: stubClient()),
            securePairingStore: pairingStore
        )
        let outcome = await useCase(challengeId: "c-1", approved: true)
        guard case .failure = outcome else {
            Issue.record("Expected failure without a device secret, got \(outcome)")
            return
        }
    }
}

@Suite struct DeregisterDeviceUseCaseTests {
    private func makeUseCase(client: HTTPClient, pairing: Pairing?) throws -> DeregisterDeviceUseCase {
        let (_, keychain) = scratchStores()
        let pairingStore = SecurePairingStore(keychain: keychain)
        if let pairing {
            try pairingStore.savePairing(pairing)
        }
        return DeregisterDeviceUseCase(
            client: DeregisterClient(httpClient: client),
            securePairingStore: pairingStore
        )
    }

    @Test func succeedsThroughPairedServer() async throws {
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString.hasPrefix("\(server)/api/notifications/native/deregister"))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "dev-1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "s1")
        }
        let useCase = try makeUseCase(client: client, pairing: makePairing())
        let outcome = await useCase()
        #expect(outcome == .success)
    }

    @Test func failsWhenUnpaired() async throws {
        let useCase = try makeUseCase(client: stubClient(), pairing: nil)
        let outcome = await useCase()
        #expect(outcome == .failure("Device is not registered"))
    }

    @Test func skipsNetworkCallForPreMigrationPairingWithNoSecret() async throws {
        let requestFired = Box(false)
        let client = stubClient { _ in requestFired.value = true }
        let useCase = try makeUseCase(client: client, pairing: makePairing(deviceSecret: ""))
        let outcome = await useCase()
        #expect(!requestFired.value)
        #expect(outcome == .failure("Device is not registered"))
    }

    @Test func unauthorizedFrom401() async throws {
        let client = stubClient(status: 401)
        let useCase = try makeUseCase(client: client, pairing: makePairing())
        let outcome = await useCase()
        #expect(outcome == .unauthorized)
    }
}

// MARK: - The number-match downgrade

@MainActor
@Suite struct MfaApprovalViewModelTests {
    private func makeUseCase(_ client: HTTPClient) -> ApproveMfaChallengeUseCase {
        let (_, keychain) = scratchStores()
        let store = SecurePairingStore(keychain: keychain)
        try? store.savePairing(makePairing())
        return ApproveMfaChallengeUseCase(
            client: MfaResponseClient(httpClient: client),
            securePairingStore: store
        )
    }

    /// A payload with no usable number leaves no way to approve. The plain
    /// Approve fallback handed the whole anti-fatigue control to whoever shapes
    /// the push payload — and the server refuses a numberless approval anyway,
    /// so it could only ever produce a failure.
    @Test func aChallengeWithoutANumberOffersNoOptions() {
        let viewModel = MfaApprovalViewModel(
            challengeId: "c1",
            approveMfaChallenge: makeUseCase(stubClient())
        )
        #expect(viewModel.matchOptions == nil)
    }

    @Test func approvingWithoutANumberIsRefusedBeforeAnyRequest() async {
        let sent = Box(0)
        let client = stubClient { _ in sent.mutate { $0 += 1 } }
        let viewModel = MfaApprovalViewModel(
            challengeId: "c1",
            approveMfaChallenge: makeUseCase(client)
        )
        await viewModel.respond(approved: true)
        #expect(sent.value == 0)
        guard case .failed = viewModel.state else {
            Issue.record("expected .failed, got \(viewModel.state)")
            return
        }
    }

    /// Deny must never depend on reading a number off another screen.
    @Test func denyingWithoutANumberStillWorks() async {
        let viewModel = MfaApprovalViewModel(
            challengeId: "c1",
            approveMfaChallenge: makeUseCase(stubClient(json: #"{"ok": true}"#))
        )
        await viewModel.respond(approved: false)
        #expect(viewModel.state == .done("Sign-in denied"))
    }

    @Test func aWrongNumberDeniesRatherThanRetries() async {
        let body = Box("")
        let client = stubClient(json: #"{"ok": true}"#) { request in
            body.mutate { $0 = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }
        }
        let viewModel = MfaApprovalViewModel(
            challengeId: "c1",
            matchDigits: "47",
            decoyDigits: ["11", "22"],
            approveMfaChallenge: makeUseCase(client)
        )
        await viewModel.choose("11")
        #expect(body.value.contains(#""approve":false"#))
        guard case .done(let message) = viewModel.state else {
            Issue.record("expected .done, got \(viewModel.state)")
            return
        }
        #expect(message.contains("not the number"))
    }
}

@Suite struct MfaNumberlessRejectionMessageTests {
    /// A 400 on a numberless approve is not "you picked the wrong number" —
    /// telling the user they mistyped a number they were never shown sent them
    /// round a loop with no exit.
    @Test func aNumberlessRejectionDoesNotBlameTheNumber() async {
        let outcome = await MfaResponseClient(httpClient: stubClient(status: 400)).respond(
            serverUrl: "https://relay.example.com",
            auth: RelayAuth(deviceId: "d1", deviceSecret: "s1"),
            challengeId: "c1",
            approved: true,
            matchDigits: ""
        )
        guard case .failure(let message) = outcome else {
            Issue.record("expected .failure, got \(outcome)")
            return
        }
        #expect(!message.contains("not the number"))
    }

    @Test func aWrongNumberStillBlamesTheNumber() async {
        let outcome = await MfaResponseClient(httpClient: stubClient(status: 400)).respond(
            serverUrl: "https://relay.example.com",
            auth: RelayAuth(deviceId: "d1", deviceSecret: "s1"),
            challengeId: "c1",
            approved: true,
            matchDigits: "47"
        )
        #expect(outcome == .failure("That is not the number shown in the browser"))
    }
}
