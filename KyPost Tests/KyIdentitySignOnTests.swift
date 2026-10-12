//
//  KyIdentitySignOnTests.swift
//  KyPost Tests
//
//  KyIdentity sign-on via the KyAuth handoff. Mirrors KyPost Android's
//  RelayOriginTest, IssuerMatchTest and KyIdentitySignOnClientTest, plus the
//  iOS handoff file contract (KyAuth-iOS docs/specs/2026-10-11-ios-signon-handoff.md).
//

import Foundation
import Testing
@testable import KyPost

@Suite struct RelayOriginTests {
    @Test func stripsPathAndTrailingSlash() {
        #expect(RelayOrigin.origin("  https://mail.example.com/x/\n") == "https://mail.example.com")
    }

    @Test func lowercasesHost() {
        #expect(RelayOrigin.origin("https://Mail.EXAMPLE.com") == "https://mail.example.com")
    }

    @Test func dropsExplicit443() {
        #expect(RelayOrigin.origin("https://mail.example.com:443/") == "https://mail.example.com")
    }

    @Test func keepsNonDefaultPort() {
        #expect(RelayOrigin.origin("https://mail.example.com:8443/a") == "https://mail.example.com:8443")
    }

    @Test func punycodesIdn() {
        #expect(RelayOrigin.origin("https://bücher.example/") == "https://xn--bcher-kva.example")
    }

    @Test func refusesHttp() {
        #expect(RelayOrigin.origin("http://mail.example.com") == nil)
    }

    @Test func refusesUserinfoQueryFragmentAndBadPort() {
        #expect(RelayOrigin.origin("https://u:p@mail.example.com") == nil)
        #expect(RelayOrigin.origin("https://mail.example.com/?x=1") == nil)
        #expect(RelayOrigin.origin("https://mail.example.com/#f") == nil)
        #expect(RelayOrigin.origin("https://mail.example.com:0") == nil)
        #expect(RelayOrigin.origin("mail.example.com") == nil)
        #expect(RelayOrigin.origin("") == nil)
    }

    @Test func refusesOverlongOrigin() {
        let host = String(repeating: "a", count: 63) + "." + String(repeating: "b", count: 63) + "."
            + String(repeating: "c", count: 63) + "." + String(repeating: "d", count: 63) + ".example"
        #expect(RelayOrigin.origin("https://\(host)") == nil)
    }

    @Test func endpointKeepsBasePath() {
        #expect(RelayOrigin.endpoint("https://Mail.example.com/relay/", path: "/api/auth/sso-config")?.absoluteString
            == "https://mail.example.com/relay/api/auth/sso-config")
        #expect(RelayOrigin.endpoint("https://mail.example.com", path: "/api/auth/native/signon")?.absoluteString
            == "https://mail.example.com/api/auth/native/signon")
    }
}

@Suite struct IssuerCanonicalTests {
    @Test func trailingSlashDefaultPortAndCaseMatch() {
        #expect(RelayOrigin.canonicalIssuer("https://Id.Example.com/")
            == RelayOrigin.canonicalIssuer("https://id.example.com:443"))
    }

    @Test func pathSchemePortAndHostDiffer() {
        let base = RelayOrigin.canonicalIssuer("https://id.example.com")
        #expect(RelayOrigin.canonicalIssuer("https://id.example.com/a") != base)
        #expect(RelayOrigin.canonicalIssuer("http://id.example.com") != base)
        #expect(RelayOrigin.canonicalIssuer("https://id.example.com:8443") != base)
        #expect(RelayOrigin.canonicalIssuer("https://evil.example.com") != base)
    }

    @Test func unparseableIsNil() {
        #expect(RelayOrigin.canonicalIssuer(nil) == nil)
        #expect(RelayOrigin.canonicalIssuer("not a url") == nil)
        #expect(RelayOrigin.canonicalIssuer("ftp://x") == nil)
    }

    @Test func canonicalIncludesPort() {
        #expect(RelayOrigin.canonicalIssuer("https://ID.example.com/base/") == "https://id.example.com:443/base")
    }
}

@Suite struct SignOnHandoffTests {
    private let nonce = String(repeating: "A", count: 42) + "_"

    @Test func nonceIs43Base64urlCharacters() throws {
        let made = try #require(SignOnHandoff.makeNonce())
        #expect(made.count == 43)
        #expect(SignOnHandoff.isValidNonce(made))
        #expect(made != SignOnHandoff.makeNonce())
    }

    @Test func nonceValidation() {
        #expect(SignOnHandoff.isValidNonce(nonce))
        #expect(!SignOnHandoff.isValidNonce(String(nonce.dropLast())))
        #expect(!SignOnHandoff.isValidNonce(nonce + "A"))
        #expect(!SignOnHandoff.isValidNonce(String(nonce.dropLast()) + "="))
        #expect(!SignOnHandoff.isValidNonce(String(nonce.dropLast()) + "/"))
        #expect(!SignOnHandoff.isValidNonce(String(nonce.dropLast()) + "é"))
        #expect(!SignOnHandoff.isValidNonce("../" + String(nonce.dropFirst(3))))
    }

    @Test func clientIdValidation() {
        #expect(SignOnHandoff.isValidClientId("kypost"))
        #expect(SignOnHandoff.isValidClientId("urn:kypost.mail_relay-1"))
        #expect(!SignOnHandoff.isValidClientId(""))
        #expect(!SignOnHandoff.isValidClientId("a b"))
        #expect(!SignOnHandoff.isValidClientId(String(repeating: "a", count: 129)))
    }

    @Test func requestHasExactlyTheContractFields() throws {
        let request = SignOnRequestFile(
            v: 1, nonce: nonce, consumer: SignOnHandoff.consumer, clientId: "kypost",
            origin: "https://mail.example.com", issuer: "https://id.example.com",
            createdAtMs: 1_760_000_000_000
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: SignOnHandoff.encode(request)) as? [String: Any]
        )
        #expect(Set(json.keys) == ["v", "nonce", "consumer", "clientId", "origin", "issuer", "createdAtMs"])
        #expect(json["v"] as? Int == 1)
        #expect(json["consumer"] as? String == "org.kysecurity.mail")
        #expect(json["origin"] as? String == "https://mail.example.com")
        #expect((json["createdAtMs"] as? NSNumber)?.int64Value == 1_760_000_000_000)
    }

    @Test func urls() throws {
        #expect(SignOnHandoff.kyAuthURL(nonce: nonce)?.absoluteString == "kyauth://signon?nonce=\(nonce)")
        #expect(SignOnHandoff.kyAuthURL(nonce: "bad") == nil)
        let back = try #require(URL(string: "kypost://kyidentity-signon?nonce=\(nonce)"))
        #expect(SignOnHandoff.returnNonce(from: back) == nonce)
        #expect(SignOnHandoff.returnNonce(from: URL(string: "kypost://kyidentity-signon?nonce=x")!) == nil)
        #expect(SignOnHandoff.returnNonce(from: URL(string: "kypost://native-pair?nonce=\(nonce)")!) == nil)
        #expect(SignOnHandoff.returnNonce(from: URL(string: "other://kyidentity-signon?nonce=\(nonce)")!) == nil)
    }

    @Test func returnLinkIsNotAPairingLink() throws {
        let back = try #require(URL(string: "kypost://kyidentity-signon?nonce=\(nonce)"))
        #expect(DeepLinkHandler().handle(back) == nil)
    }

    @Test func decodesEachStatus() {
        func decode(_ json: String) -> SignOnHandoffResponse? {
            SignOnHandoff.decodeResponse(Data(json.utf8), nonce: nonce)
        }
        #expect(decode(#"{"v":1,"nonce":"\#(nonce)","status":"ok","idToken":"eyJ.a.b"}"#) == .ok(idToken: "eyJ.a.b"))
        #expect(decode(#"{"v":1,"nonce":"\#(nonce)","status":"cancelled"}"#) == .cancelled)
        #expect(decode(#"{"v":1,"nonce":"\#(nonce)","status":"error","message":"Nope"}"#) == .error(message: "Nope"))
        let long = String(repeating: "x", count: 500)
        #expect(decode(#"{"v":1,"nonce":"\#(nonce)","status":"error","message":"\#(long)"}"#)
            == .error(message: String(repeating: "x", count: 200)))
    }

    @Test func refusesOtherNonceVersionOrStatus() {
        func decode(_ json: String) -> SignOnHandoffResponse? {
            SignOnHandoff.decodeResponse(Data(json.utf8), nonce: nonce)
        }
        let other = String(repeating: "B", count: 43)
        #expect(decode(#"{"v":1,"nonce":"\#(other)","status":"cancelled"}"#) == nil)
        #expect(decode(#"{"v":2,"nonce":"\#(nonce)","status":"cancelled"}"#) == nil)
        #expect(decode(#"{"v":1,"nonce":"\#(nonce)","status":"maybe"}"#) == nil)
        #expect(decode("not json") == nil)
    }

    @Test func responseDescriptionRedactsToken() {
        #expect(String(describing: SignOnHandoffResponse.ok(idToken: "secret")) == "ok(redacted)")
    }

    @Test func storeWritesRequestAndTakesResponseOnce() throws {
        let store = SignOnHandoffStore(root: try scratchDirectory())
        let request = SignOnRequestFile(
            v: 1, nonce: nonce, consumer: SignOnHandoff.consumer, clientId: "kypost",
            origin: "https://mail.example.com", issuer: "https://id.example.com", createdAtMs: 1
        )
        try store.writeRequest(request)
        let written = try Data(contentsOf: store.requestFile(nonce))
        #expect(written == (try SignOnHandoff.encode(request)))

        #expect(store.takeResponse(nonce) == nil)
        try FileManager.default.createDirectory(at: store.responsesDirectory, withIntermediateDirectories: true)
        try Data(#"{"v":1,"nonce":"\#(nonce)","status":"cancelled"}"#.utf8).write(to: store.responseFile(nonce))
        #expect(store.takeResponse(nonce) == .some(.cancelled))
        #expect(!FileManager.default.fileExists(atPath: store.responseFile(nonce).path))
        #expect(store.takeResponse(nonce) == nil)

        store.withdrawRequest(nonce)
        #expect(!FileManager.default.fileExists(atPath: store.requestFile(nonce).path))
    }

    @Test func invalidResponseFileIsDeleted() throws {
        let store = SignOnHandoffStore(root: try scratchDirectory())
        try FileManager.default.createDirectory(at: store.responsesDirectory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.responseFile(nonce))
        #expect(store.takeResponse(nonce) == .some(nil))
        #expect(!FileManager.default.fileExists(atPath: store.responseFile(nonce).path))
    }

    @Test func sweepTouchesOnlyStaleResponses() throws {
        let store = SignOnHandoffStore(root: try scratchDirectory())
        let fm = FileManager.default
        try fm.createDirectory(at: store.responsesDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: store.requestsDirectory, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-6 * 60)
        let stale = store.responseFile(String(repeating: "S", count: 43))
        let fresh = store.responseFile(String(repeating: "F", count: 43))
        let request = store.requestFile(String(repeating: "R", count: 43))
        for file in [stale, fresh, request] { try Data("{}".utf8).write(to: file) }
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: request.path)

        store.sweepStaleResponses()

        #expect(!fm.fileExists(atPath: stale.path))
        #expect(fm.fileExists(atPath: fresh.path))
        // requests/ belongs to KyAuth's sweep.
        #expect(fm.fileExists(atPath: request.path))
    }
}

@Suite struct KyIdentitySignOnClientTests {
    private let server = "https://mail.example.com"

    private final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
        var limits: [Int] = []
    }

    private func client(_ code: Int, _ body: String, recorder: Recorder = Recorder()) -> KyIdentitySignOnClient {
        KyIdentitySignOnClient { request, limit in
            recorder.requests.append(request)
            recorder.limits.append(limit)
            return (code, Data(body.utf8))
        }
    }

    @Test func configReady() async throws {
        let recorder = Recorder()
        let result = await client(200, #"{"enabled":true,"issuerUrl":"https://id.example.com/","clientId":"kypost"}"#,
                                  recorder: recorder).config(serverUrl: server)
        #expect(result == .ready(SignOnConfig(issuerUrl: "https://id.example.com", clientId: "kypost")))
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "\(server)/api/auth/sso-config")
        #expect(request.httpMethod == "GET")
        #expect(recorder.limits == [KyIdentitySignOnClient.maxOkBytes])
    }

    @Test func configDisabled() async {
        guard case .unavailable = await client(200, #"{"enabled":false,"issuerUrl":""}"#).config(serverUrl: server)
        else { Issue.record("expected unavailable"); return }
        guard case .unavailable = await client(200, #"{"enabled":true,"issuerUrl":"https://id.example.com"}"#)
            .config(serverUrl: server)
        else { Issue.record("expected unavailable"); return }
    }

    @Test func configRefusesHttpServer() async {
        let recorder = Recorder()
        let result = await client(200, "{}", recorder: recorder).config(serverUrl: "http://mail.example.com")
        #expect(result == .unavailable("Server URL must use https"))
        #expect(recorder.requests.isEmpty)
    }

    @Test func config404MeansNoSignOn() async {
        #expect(await client(404, "").config(serverUrl: server) == .unavailable("This server does not use KyIdentity sign-in"))
    }

    @Test func configOtherStatusAndGarbage() async {
        #expect(await client(500, "").config(serverUrl: server)
            == .unavailable("Could not read the server's sign-in settings (500)"))
        #expect(await client(200, "<html>").config(serverUrl: server)
            == .unavailable("The server returned an unreadable sign-in configuration"))
        #expect(await client(200, #"{"enabled":true,"issuerUrl":"https://id.example.com","clientId":"bad id"}"#)
            .config(serverUrl: server) == .unavailable("The server returned an unreadable sign-in configuration"))
    }

    @Test func transportFailureIsOneSentence() async {
        let failing = KyIdentitySignOnClient { _, _ in throw URLError(.notConnectedToInternet) }
        #expect(await failing.config(serverUrl: server) == .unavailable("Could not reach the server"))
        #expect(await failing.signOn(serverUrl: server, idToken: "t") == .failure("Could not reach the server"))
    }

    @Test func signOnParsesDeepLink() async throws {
        let link = "kypost://native-pair?sub=s1&srv=https%3A%2F%2Fmail.example.com&reg=https%3A%2F%2Fmail.example.com%2Fapi%2Fnotifications%2Fnative%2Fregister&pt=tok"
        let recorder = Recorder()
        let result = await client(200, #"{"configured":true,"deepLink":"\#(link)"}"#, recorder: recorder)
            .signOn(serverUrl: server, idToken: "eyJ.a.b")
        guard case .success(let params) = result else { Issue.record("\(result)"); return }
        #expect(params.pt == "tok")
        #expect(params.srv == "https://mail.example.com")
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "\(server)/api/auth/native/signon")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        #expect((try JSONSerialization.jsonObject(with: body)) as? [String: String] == ["idToken": "eyJ.a.b"])
    }

    @Test func signOnMapsStatuses() {
        func at(_ code: Int, _ body: String = "") -> String {
            guard case .failure(let message) = KyIdentitySignOnClient.mapSignOn(
                code: code, body: Data(body.utf8), host: "mail.example.com"
            ) else { return "" }
            return message
        }
        #expect(at(503).contains("mail.example.com"))
        #expect(at(403, "Access denied: this token was already used.").contains("already used"))
        #expect(at(429).contains("Try again"))
        #expect(at(500) == "Could not sign in to mail.example.com (500)")
        #expect(at(200, #"{"configured":false,"configurationError":"set PAIRING_SECRET"}"#).contains("PAIRING_SECRET"))
        #expect(at(200, #"{"configured":false}"#) == "Pairing is not configured on the server")
        #expect(at(200, "nope") == "The server returned an unreadable pairing response")
    }

    @Test func refusalTextIsSanitised() {
        func at(_ body: String) -> String {
            guard case .failure(let message) = KyIdentitySignOnClient.mapSignOn(
                code: 403, body: Data(body.utf8), host: "mail.example.com"
            ) else { return "" }
            return message
        }
        #expect(at("<html><body>Blocked by WAF</body></html>") == "KyIdentity sign-in was refused")
        #expect(at("") == "KyIdentity sign-in was refused")
        let long = "Access denied: this token was already used." + String(repeating: "x", count: 300)
            + "\n" + String(repeating: "y", count: 10 * 1024)
        let message = at(long)
        #expect(message.count <= 200)
        #expect(message.hasPrefix("Access denied: this token was already used."))
    }

    @Test func errorBodyIsBoundedBeforeItIsRead() {
        // Past the 4 KiB error cap, a '<' is never seen.
        let body = String(repeating: "a", count: KyIdentitySignOnClient.maxErrorBytes) + "<html>"
        guard case .failure(let message) = KyIdentitySignOnClient.mapSignOn(
            code: 403, body: Data(body.utf8), host: "mail.example.com"
        ) else { Issue.record("expected failure"); return }
        #expect(message == String(repeating: "a", count: 200))
    }

    @Test func signOnRejectsLinkForOtherHost() {
        let link = "kypost://native-pair?sub=s1&srv=https%3A%2F%2Fevil.example.net&reg=https%3A%2F%2Fevil.example.net%2Fapi%2Fnotifications%2Fnative%2Fregister&pt=tok"
        let result = KyIdentitySignOnClient.mapSignOn(
            code: 200, body: Data(#"{"configured":true,"deepLink":"\#(link)"}"#.utf8), host: "mail.example.com"
        )
        guard case .failure(let message) = result else { Issue.record("expected failure"); return }
        #expect(message.contains("different host"))
    }

    @Test func signOnRejectsInsecureLink() {
        let link = "kypost://native-pair?sub=s1&srv=http%3A%2F%2Fmail.example.com&pt=tok"
        let result = KyIdentitySignOnClient.mapSignOn(
            code: 200, body: Data(#"{"configured":true,"deepLink":"\#(link)"}"#.utf8), host: "mail.example.com"
        )
        #expect(result == .failure("This pairing link points at a server over plain http. KyPost refused it."))
    }
}

#if os(iOS)
@MainActor
@Suite struct KyIdentitySignOnCoordinatorTests {
    private let server = "https://mail.example.com"
    private let link = "kypost://native-pair?sub=s1&srv=https%3A%2F%2Fmail.example.com&pt=tok"

    private final class Harness {
        /// Private, so a real reset elsewhere in the host app cannot reach it.
        let center = NotificationCenter()
        let coordinator: KyIdentitySignOnCoordinator
        let store: SignOnHandoffStore
        /// Stands in for locked / startup verdict pending / abandoned wipe.
        var gated = false
        var opened: [URL] = []
        var delivered: [PairingParams] = []
        var exchangedTokens: [String] = []
        var now = Date(timeIntervalSince1970: 1_760_000_000)

        @MainActor
        init(openSucceeds: Bool = true, signOnBody: String) throws {
            coordinator = KyIdentitySignOnCoordinator(notificationCenter: center)
            store = SignOnHandoffStore(root: try scratchDirectory())
            let store = store
            let tokens = TokenLog()
            coordinator.makeStore = { store }
            coordinator.makeClient = {
                KyIdentitySignOnClient { request, _ in
                    if request.url?.path().hasSuffix("sso-config") == true {
                        return (200, Data(#"{"enabled":true,"issuerUrl":"https://id.example.com/","clientId":"kypost"}"#.utf8))
                    }
                    tokens.append(request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                    return (200, Data(signOnBody.utf8))
                }
            }
            coordinator.openURL = { [unowned self] url in
                self.opened.append(url)
                return openSucceeds
            }
            coordinator.now = { [unowned self] in self.now }
            coordinator.deliver = { [unowned self] in self.delivered.append($0) }
            coordinator.isGated = { [unowned self] in self.gated }
            self.tokenLog = tokens
        }

        var tokenLog: TokenLog?

        var nonce: String? {
            opened.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first?.value }
        }

        func respond(_ json: String) throws {
            try FileManager.default.createDirectory(at: store.responsesDirectory, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: store.responseFile(nonce!))
        }
    }

    private final class TokenLog: @unchecked Sendable {
        var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func fullFlowWritesRequestOpensKyAuthAndDelivers() async throws {
        let h = try Harness(signOnBody: #"{"configured":true,"deepLink":"\#(link)"}"#)
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.phase == .waitingForKyAuth }
        let nonce = try #require(h.nonce)
        #expect(h.opened.first?.absoluteString == "kyauth://signon?nonce=\(nonce)")

        let request = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: h.store.requestFile(nonce))) as? [String: Any]
        )
        #expect(request["origin"] as? String == "https://mail.example.com")
        #expect(request["issuer"] as? String == "https://id.example.com")
        #expect(request["clientId"] as? String == "kypost")
        #expect(request["consumer"] as? String == "org.kysecurity.mail")
        #expect((request["createdAtMs"] as? NSNumber)?.int64Value == 1_760_000_000_000)

        try h.respond(#"{"v":1,"nonce":"\#(nonce)","status":"ok","idToken":"eyJ.a.b"}"#)
        #expect(h.coordinator.handleReturn(URL(string: "kypost://kyidentity-signon?nonce=\(nonce)")!))
        await waitUntil { !h.delivered.isEmpty }
        #expect(h.delivered.first?.pt == "tok")
        #expect(h.tokenLog?.values == [#"{"idToken":"eyJ.a.b"}"#])
        #expect(!FileManager.default.fileExists(atPath: h.store.responseFile(nonce).path))
        #expect(h.coordinator.phase == .idle)
        #expect(h.coordinator.status == nil)
    }

    @Test func liveScreenReceivesTheLinkInsteadOfTheRouter() async throws {
        let h = try Harness(signOnBody: #"{"configured":true,"deepLink":"\#(link)"}"#)
        h.coordinator.pairingScreenAppeared()
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.phase == .waitingForKyAuth }
        let nonce = try #require(h.nonce)
        try h.respond(#"{"v":1,"nonce":"\#(nonce)","status":"ok","idToken":"t"}"#)
        h.coordinator.checkForResponse()
        await waitUntil { h.coordinator.completed != nil }
        #expect(h.delivered.isEmpty)
        #expect(h.coordinator.takeCompleted()?.pt == "tok")
        #expect(h.coordinator.takeCompleted() == nil)
    }

    @Test func kyAuthMissingWithdrawsTheRequest() async throws {
        let h = try Harness(openSucceeds: false, signOnBody: "")
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.status != nil }
        #expect(h.coordinator.status == "Install KyAuth to sign in with KyIdentity.")
        #expect(h.coordinator.phase == .idle)
        let nonce = try #require(h.nonce)
        #expect(!FileManager.default.fileExists(atPath: h.store.requestFile(nonce).path))
    }

    @Test func ignoresOtherNonceAndKeepsWaiting() async throws {
        let h = try Harness(signOnBody: "")
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.phase == .waitingForKyAuth }
        let other = String(repeating: "B", count: 43)
        #expect(h.coordinator.handleReturn(URL(string: "kypost://kyidentity-signon?nonce=\(other)")!))
        #expect(h.coordinator.phase == .waitingForKyAuth)
        // No response yet: becoming active keeps waiting.
        h.coordinator.checkForResponse()
        #expect(h.coordinator.phase == .waitingForKyAuth)
    }

    @Test func cancelledAndErrorResponses() async throws {
        let h = try Harness(signOnBody: "")
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.phase == .waitingForKyAuth }
        try h.respond(#"{"v":1,"nonce":"\#(h.nonce!)","status":"cancelled"}"#)
        h.coordinator.checkForResponse()
        #expect(h.coordinator.phase == .idle)
        #expect(h.coordinator.status == nil)

        h.opened.removeAll()
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.phase == .waitingForKyAuth }
        try h.respond(#"{"v":1,"nonce":"\#(h.nonce!)","status":"error","message":"KyAuth is not paired with KyIdentity."}"#)
        h.coordinator.checkForResponse()
        #expect(h.coordinator.status == "KyAuth is not paired with KyIdentity.")
        #expect(h.delivered.isEmpty)
    }

    @Test func abandonsAfter180Seconds() async throws {
        let h = try Harness(signOnBody: "")
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.phase == .waitingForKyAuth }
        let nonce = try #require(h.nonce)
        h.now = h.now.addingTimeInterval(181)
        try h.respond(#"{"v":1,"nonce":"\#(nonce)","status":"ok","idToken":"late"}"#)
        h.coordinator.checkForResponse()
        #expect(h.coordinator.phase == .idle)
        #expect(h.coordinator.status == "KyAuth did not answer. Try again.")
        #expect(h.tokenLog?.values.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: h.store.responseFile(nonce).path))
    }

    @Test func refusesHttpBeforeAnyRequest() throws {
        let h = try Harness(signOnBody: "")
        h.coordinator.start(serverUrl: "http://mail.example.com")
        #expect(h.coordinator.status == "Server URL must use https")
        #expect(h.opened.isEmpty)
    }

    // MARK: Security gates

    /// Returning from KyAuth lands on the lock screen. The response must stay
    /// unread — no token in memory, no relay call — until the user unlocks.
    @Test func gatedAppLeavesTheResponseUnreadUntilUnlock() async throws {
        let h = try Harness(signOnBody: #"{"configured":true,"deepLink":"\#(link)"}"#)
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.phase == .waitingForKyAuth }
        let nonce = try #require(h.nonce)
        try h.respond(#"{"v":1,"nonce":"\#(nonce)","status":"ok","idToken":"eyJ.a.b"}"#)

        h.gated = true
        #expect(h.coordinator.handleReturn(URL(string: "kypost://kyidentity-signon?nonce=\(nonce)")!))
        h.coordinator.checkForResponse()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.coordinator.phase == .waitingForKyAuth)
        #expect(FileManager.default.fileExists(atPath: h.store.responseFile(nonce).path))
        #expect(h.tokenLog?.values.isEmpty == true)
        #expect(h.delivered.isEmpty)

        // Unlocking (KyPostApp re-checks when the gate clears).
        h.gated = false
        h.coordinator.checkForResponse()
        await waitUntil { !h.delivered.isEmpty }
        #expect(h.delivered.count == 1)
        #expect(h.tokenLog?.values == [#"{"idToken":"eyJ.a.b"}"#])
        #expect(!FileManager.default.fileExists(atPath: h.store.responseFile(nonce).path))
    }

    /// Still gated at the deadline: the response is discarded and never
    /// sent to the relay.
    @Test func gatedPastTheDeadlineAbandonsWithoutExchanging() async throws {
        let h = try Harness(signOnBody: "")
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.phase == .waitingForKyAuth }
        let nonce = try #require(h.nonce)
        try h.respond(#"{"v":1,"nonce":"\#(nonce)","status":"ok","idToken":"late"}"#)
        h.gated = true
        h.now = h.now.addingTimeInterval(181)
        h.coordinator.checkForResponse()
        #expect(h.coordinator.phase == .idle)
        #expect(h.coordinator.status == "KyAuth did not answer. Try again.")
        #expect(h.tokenLog?.values.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: h.store.responseFile(nonce).path))
    }

    // MARK: Session reset

    /// A wipe, failed-unlock reset or unpair posts `.kyPostSessionReset`; a
    /// pending sign-on must not survive it and re-pair the erased device.
    @Test func sessionResetWithdrawsTheRequestAndDiscardsTheResponse() async throws {
        let h = try Harness(signOnBody: #"{"configured":true,"deepLink":"\#(link)"}"#)
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.phase == .waitingForKyAuth }
        let nonce = try #require(h.nonce)
        try h.respond(#"{"v":1,"nonce":"\#(nonce)","status":"ok","idToken":"t"}"#)

        h.center.post(name: .kyPostSessionReset, object: nil)
        #expect(h.coordinator.phase == .idle)
        #expect(h.coordinator.status == nil)
        #expect(!FileManager.default.fileExists(atPath: h.store.requestFile(nonce).path))
        #expect(!FileManager.default.fileExists(atPath: h.store.responseFile(nonce).path))

        try h.respond(#"{"v":1,"nonce":"\#(nonce)","status":"ok","idToken":"t"}"#)
        #expect(h.coordinator.handleReturn(URL(string: "kypost://kyidentity-signon?nonce=\(nonce)")!))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.tokenLog?.values.isEmpty == true)
        #expect(h.delivered.isEmpty)
    }

    @Test func sessionResetDropsAFinishedLink() async throws {
        let h = try Harness(signOnBody: #"{"configured":true,"deepLink":"\#(link)"}"#)
        h.coordinator.pairingScreenAppeared()
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.phase == .waitingForKyAuth }
        try h.respond(#"{"v":1,"nonce":"\#(h.nonce!)","status":"ok","idToken":"t"}"#)
        h.coordinator.checkForResponse()
        await waitUntil { h.coordinator.completed != nil }

        h.center.post(name: .kyPostSessionReset, object: nil)
        #expect(h.coordinator.completed == nil)
        h.coordinator.pairingScreenDisappeared()
        #expect(h.delivered.isEmpty)
    }

    /// Reset after the response was taken but before the exchange ran: the
    /// token is never sent and nothing is delivered.
    @Test func sessionResetCancelsAScheduledExchange() async throws {
        let h = try Harness(signOnBody: #"{"configured":true,"deepLink":"\#(link)"}"#)
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.phase == .waitingForKyAuth }
        try h.respond(#"{"v":1,"nonce":"\#(h.nonce!)","status":"ok","idToken":"t"}"#)
        h.coordinator.checkForResponse()
        #expect(h.coordinator.phase == .exchanging)
        h.coordinator.reset()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.tokenLog?.values.isEmpty == true)
        #expect(h.delivered.isEmpty)
        #expect(h.coordinator.phase == .idle)
    }

    // MARK: Pairing screen presence

    /// The exchange finished for a live screen, which then went away (the lock
    /// dismissed it) before taking the link: it goes to the router, once.
    @Test func lastScreenDisappearingHandsAnUntakenLinkToTheRouter() async throws {
        let h = try Harness(signOnBody: #"{"configured":true,"deepLink":"\#(link)"}"#)
        h.coordinator.pairingScreenAppeared()
        h.coordinator.start(serverUrl: server)
        await waitUntil { h.coordinator.phase == .waitingForKyAuth }
        try h.respond(#"{"v":1,"nonce":"\#(h.nonce!)","status":"ok","idToken":"t"}"#)
        h.coordinator.checkForResponse()
        await waitUntil { h.coordinator.completed != nil }
        #expect(h.delivered.isEmpty)

        h.coordinator.pairingScreenDisappeared()
        #expect(h.delivered.count == 1)
        #expect(h.delivered.first?.pt == "tok")
        #expect(h.coordinator.completed == nil)
        #expect(h.coordinator.takeCompleted() == nil)

        h.coordinator.pairingScreenDisappeared()
        #expect(h.delivered.count == 1)
    }

    @Test func nonReturnURLsFallThrough() {
        let coordinator = KyIdentitySignOnCoordinator()
        #expect(!coordinator.handleReturn(URL(string: "kypost://native-pair?sub=a&srv=https%3A%2F%2Fx&pt=t")!))
        #expect(!coordinator.handleReturn(URL(string: "kypost://desktop-pair?code=a&srv=https%3A%2F%2Fx")!))
    }
}
#endif

@MainActor
@Suite struct RouterSessionResetTests {
    /// The router outlives graph rebuilds; an action deferred behind the lock
    /// must not replay into the app a wipe just erased.
    @Test func sessionResetDiscardsTheDeferredAction() {
        let center = NotificationCenter()
        let router = NavigationRouter(notificationCenter: center)
        var locked = true
        router.isLocked = { locked }
        router.handle(.openMfaApproval(MfaChallenge(challengeId: "c1", receivedAt: Date(), matchDigits: "47")))

        center.post(name: .kyPostSessionReset, object: nil)
        locked = false
        router.resumeDeferredAction()
        #expect(router.mfaRoute == nil)
    }
}

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "kypost-signon-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
