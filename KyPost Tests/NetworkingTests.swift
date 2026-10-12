//
//  NetworkingTests.swift
//  KyPost Tests
//
//  Phase 2 tests: deep-link parsing, endpoint resolution, status mapping,
//  response decoding, and client outcome mapping via a stub transport.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Helpers

/// HTTPClient whose transport returns a canned response; `onRequest` lets
/// tests assert on the outgoing request.

private let validPairingLink = URL(
    string: "kypost://native-pair?sub=user1&srv=https://relay.example.com&pt=token9"
)!

// MARK: - Pairing link parsing

@Suite struct PairingLinkParserTests {
    @Test func parsesValidLink() throws {
        let params = try PairingLinkParser.parse(validPairingLink)
        #expect(params.sub == "user1")
        #expect(params.srv == "https://relay.example.com")
        #expect(params.pt == "token9")
        #expect(params.reg == nil)
    }

    /// `reg` must be same-origin with `srv` — it is where the device secret is
    /// minted, while the confirmation dialog names `srv`. A cross-origin `reg`
    /// is refused; see `refusesRegOnAForeignHost`. This case is the accepted
    /// one: a custom *path* on the paired origin.
    @Test func parsesOptionalRegParameter() throws {
        let url = URL(string: validPairingLink.absoluteString + "&reg=https://relay.example.com/custom")!
        let params = try PairingLinkParser.parse(url)
        #expect(params.reg == "https://relay.example.com/custom")
    }

    /// A stale cached QR image from before the per-device-secret migration
    /// may still carry a hash= param; it must simply be ignored, not
    /// rejected, since it's harmless and the pairingToken alone is what
    /// actually gates registration.
    @Test func ignoresLegacyHashParamIfPresent() throws {
        let url = URL(string: validPairingLink.absoluteString + "&hash=stale-value")!
        let params = try PairingLinkParser.parse(url)
        #expect(params.sub == "user1")
    }

    @Test(arguments: ["sub", "srv", "pt"])
    func rejectsMissingRequiredParameter(missing: String) {
        let all = ["sub": "u", "srv": "https://s.example.com", "pt": "p"]
        let query = all
            .filter { $0.key != missing }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        let url = URL(string: "kypost://native-pair?\(query)")!
        #expect(throws: PairingLinkError.missingParameter(missing)) {
            try PairingLinkParser.parse(url)
        }
    }

    @Test func rejectsEmptyRequiredParameter() {
        let url = URL(string: "kypost://native-pair?sub=&srv=https://s.example.com&pt=p")!
        #expect(throws: PairingLinkError.missingParameter("sub")) {
            try PairingLinkParser.parse(url)
        }
    }

    @Test func rejectsWrongSchemeOrHost() {
        let wrongScheme = URL(string: "https://native-pair?sub=u&srv=s&pt=p")!
        let wrongHost = URL(string: "kypost://other-host?sub=u&srv=s&pt=p")!
        #expect(throws: PairingLinkError.notAPairingLink) {
            try PairingLinkParser.parse(wrongScheme)
        }
        #expect(throws: PairingLinkError.notAPairingLink) {
            try PairingLinkParser.parse(wrongHost)
        }
    }

    /// A crafted link pointing `srv` at a plaintext host must be rejected
    /// before it can exfiltrate the device's push token / pairing token.
    @Test func rejectsNonHttpsServerURL() {
        let url = URL(string: "kypost://native-pair?sub=u&srv=http://relay.example.com&pt=p")!
        #expect(throws: PairingLinkError.insecureServerURL) {
            try PairingLinkParser.parse(url)
        }
    }

    @Test func rejectsNonHttpsRegParameter() {
        let url = URL(
            string: "kypost://native-pair?sub=u&srv=https://relay.example.com&pt=p"
                + "&reg=http://evil.example.com/register"
        )!
        #expect(throws: PairingLinkError.insecureServerURL) {
            try PairingLinkParser.parse(url)
        }
    }

    @Test func deepLinkHandlerRoutesPairingLinks() throws {
        let handler = DeepLinkHandler()
        let action = handler.handle(validPairingLink)
        let expected = NavigationAction.openPairingFlow(try PairingLinkParser.parse(validPairingLink))
        #expect(action == expected)
        #expect(handler.handle(URL(string: "https://example.com")!) == nil)
    }
}

// MARK: - Endpoint resolution

@Suite struct EndpointResolutionTests {
    @Test func registrationEndpointDerivedFromSrv() {
        let params = PairingParams(sub: "u", srv: "https://relay.example.com", pt: "p")
        #expect(
            params.registrationEndpoint?.absoluteString
            == "https://relay.example.com/api/notifications/native/register"
        )
    }

    @Test func regParameterOverridesDerivedEndpointOnTheSameHost() {
        let params = PairingParams(
            sub: "u", srv: "https://relay.example.com", pt: "p",
            reg: "https://relay.example.com/custom/register"
        )
        #expect(
            params.registrationEndpoint?.absoluteString
            == "https://relay.example.com/custom/register"
        )
    }

    @Test func regParameterOnAForeignHostIsIgnored() {
        // The confirmation screen names srv's host while the credential POST
        // followed reg, so a cross-host override showed one server and
        // contacted another. Enforced here as well as at parse time because
        // reg is persisted and replayed on every re-registration.
        let params = PairingParams(
            sub: "u", srv: "https://relay.example.com", pt: "p",
            reg: "https://evil.test/register"
        )
        #expect(
            params.registrationEndpoint?.absoluteString
            == "https://relay.example.com/api/notifications/native/register"
        )
    }

    @Test func aCrossHostRegParameterIsRejectedAtParseTime() throws {
        let url = try #require(URL(
            string: "kypost://native-pair?sub=u&pt=p"
                + "&srv=https%3A%2F%2Frelay.example.com"
                + "&reg=https%3A%2F%2Fevil.test%2Fregister"
        ))
        #expect(throws: PairingLinkError.registrationHostMismatch) {
            try PairingLinkParser.parse(url)
        }
    }

    @Test func pullEndpointDerivedWhenAbsent() {
        let response = RegistrationResponse(ok: true, deliveryMode: .pull, pullEndpoint: nil)
        #expect(
            response.resolvedPullEndpoint(srv: "https://relay.example.com")?.absoluteString
            == "https://relay.example.com/api/notifications/native/pull"
        )
    }

    @Test func explicitPullEndpointWins() {
        let response = RegistrationResponse(
            ok: true,
            pullEndpoint: "https://pull.example.com/notifications"
        )
        #expect(
            response.resolvedPullEndpoint(srv: "https://relay.example.com")?.absoluteString
            == "https://pull.example.com/notifications"
        )
    }
}

// MARK: - Status mapping

@Suite struct NetworkErrorMappingTests {
    @Test func statusCodeMapping() {
        #expect(NetworkError.from(statusCode: 200) == nil)
        #expect(NetworkError.from(statusCode: 204) == nil)
        #expect(NetworkError.from(statusCode: 401) == .unauthorized)
        #expect(NetworkError.from(statusCode: 403) == .unauthorized)
        #expect(NetworkError.from(statusCode: 409) == .conflict(body: ""))
        #expect(
            NetworkError.from(statusCode: 409, body: Data(#"{"clientSideNeeded":true}"#.utf8))
                == .conflict(body: #"{"clientSideNeeded":true}"#)
        )
        #expect(NetworkError.from(statusCode: 503) == .serviceUnavailable)
        #expect(NetworkError.from(statusCode: 500) == .server(statusCode: 500))
    }
}

// MARK: - Response decoding

@Suite struct ResponseDecodingTests {
    @Test func registrationResponseDecodesSpecSample() async throws {
        // Sample from spec §3.
        let json = """
        {
          "ok": true,
          "synced": true,
          "deviceId": "dev-42",
          "deliveryMode": "push",
          "pullEndpoint": "https://relay.example.com/api/notifications/native/pull"
        }
        """
        let client = stubClient(status: 200, json: json)
        let response = try await client.get(
            RegistrationResponse.self,
            url: URL(string: "https://relay.example.com/register")!
        )
        #expect(response.ok)
        #expect(response.synced == true)
        #expect(response.deviceId == "dev-42")
        #expect(response.deliveryMode == .push)
    }

    /// The legacy top-level shape is still accepted (current servers nest it
    /// in `data`; see PullWireShapeTests).
    @Test func pullResponseDecodesCapitalKKeywords() async throws {
        let json = """
        {
          "notifications": [
            {
              "seq": 7,
              "messageId": "m-7",
              "senderName": "Ada",
              "emailSubject": "Hello",
              "Keywords": ["Important", "Work"]
            }
          ],
          "cursor": 8
        }
        """
        let client = stubClient(status: 200, json: json)
        let response = try await PushNotificationClient(httpClient: client).pull(
            endpoint: URL(string: "https://relay.example.com/api/notifications/native/pull")!,
            auth: RelayAuth(deviceId: "u", deviceSecret: "h"),
            after: 6
        )
        #expect(response.cursor == 8)
        let dto = try #require(response.notifications.first)
        #expect(dto.keywords == ["Important", "Work"])

        guard case .mail(let domain) = dto.routed() else {
            Issue.record("expected mail")
            return
        }
        #expect(domain.seq == 7)
        #expect(domain.messageId == "m-7")
        #expect(domain.keywords == ["Important", "Work"])
        #expect(!domain.read)
    }
}

// MARK: - Client outcome mapping

@Suite struct NativeRegistrationClientTests {
    private let params = PairingParams(sub: "u1", srv: "https://relay.example.com", pt: "p1")

    @Test func successCarriesResponseAndSendsNoAuthHeaders() async {
        let client = stubClient(
            status: 200,
            json: #"{"ok": true, "deviceId": "d1", "deviceSecret": "s1"}"#
        ) { request in
            let url = request.url!.absoluteString
            #expect(url == "https://relay.example.com/api/notifications/native/register")
            // No header-based auth on this endpoint — the backend never
            // reads one here, and a device has no deviceSecret yet at
            // register time anyway.
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Subscriber-Id") == nil)
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Subscriber-Hash") == nil)
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == nil)
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == nil)
            #expect(request.httpMethod == "POST")
            // Body fields are a binding contract with the live backend:
            // subscriberId, pairingToken, and deviceToken are required.
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""subscriberId":"u1""#))
            #expect(body.contains(#""pairingToken":"p1""#))
            #expect(body.contains(#""deviceToken":"apns-token""#))
            // deviceName is what the server's paired-device list displays;
            // without it the UI falls back to the platform string.
            #expect(body.contains(#""deviceName":""#))
        }
        let outcome = await NativeRegistrationClient(httpClient: client)
            .register(deviceToken: "apns-token", params: params)
        guard case .success(let response) = outcome else {
            Issue.record("Expected success, got \(outcome)")
            return
        }
        #expect(response.deviceId == "d1")
        #expect(response.deviceSecret == "s1")
    }

    @Test func unauthorizedPromptsRescan() async {
        let outcome = await NativeRegistrationClient(httpClient: stubClient(status: 403))
            .register(deviceToken: "t", params: params)
        #expect(outcome == .unauthorized)
    }

    @Test func serviceUnavailableIsPersistentError() async {
        let outcome = await NativeRegistrationClient(httpClient: stubClient(status: 503))
            .register(deviceToken: "t", params: params)
        #expect(outcome == .backendMisconfigured)
    }
}

@Suite struct MfaResponseClientTests {
    private let auth = RelayAuth(deviceId: "dev-1", deviceSecret: "secret-1")

    @Test func successOn200() async {
        let client = stubClient(status: 200, json: #"{"ok": true}"#) { request in
            #expect(
                request.url!.absoluteString
                    .hasPrefix("https://relay.example.com/api/mfa/push/respond")
            )
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "dev-1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "secret-1")
            // Contract: device identity travels in the headers, not the
            // body, and the boolean field is "approve" (not "approved").
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""challengeId":"c1""#))
            #expect(!body.contains("subscriberId"))
            #expect(!body.contains("subscriberHash"))
            #expect(!body.contains("deviceId"))
            #expect(body.contains(#""approve":true"#))
            // The backend verifies this itself and refuses an approval without
            // it, so it has to be on the wire.
            #expect(body.contains(#""matchDigits":"47""#))
        }
        let outcome = await MfaResponseClient(httpClient: client).respond(
            serverUrl: "https://relay.example.com",
            auth: auth,
            challengeId: "c1",
            approved: true,
            matchDigits: "47"
        )
        #expect(outcome == .success)
    }

    @Test func denySendsNoNumber() async {
        // Deny must never require the number: the person most likely to press
        // it is someone being fatigued, looking at a number they cannot match.
        let client = stubClient(status: 200, json: #"{"ok": true}"#) { request in
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""approve":false"#))
            #expect(body.contains(#""matchDigits":"""#))
        }
        let outcome = await MfaResponseClient(httpClient: client).respond(
            serverUrl: "https://relay.example.com",
            auth: auth,
            challengeId: "c1",
            approved: false,
            matchDigits: "47"
        )
        #expect(outcome == .success)
    }

    @Test func wrongNumberIsAFailureNotARejection() async {
        // 400 means the credentials were fine and the challenge is still live —
        // a re-prompt, not a re-pair, so it must not map to .rejected.
        let outcome = await MfaResponseClient(httpClient: stubClient(status: 400)).respond(
            serverUrl: "https://relay.example.com",
            auth: auth,
            challengeId: "c1",
            approved: true,
            matchDigits: "11"
        )
        #expect(outcome == .failure("That is not the number shown in the browser"))
    }

    @Test func exhaustedAttemptsAreReported() async {
        let outcome = await MfaResponseClient(httpClient: stubClient(status: 429)).respond(
            serverUrl: "https://relay.example.com",
            auth: auth,
            challengeId: "c1",
            approved: true,
            matchDigits: "11"
        )
        #expect(outcome == .failure("Too many incorrect attempts — start the sign-in again"))
    }

    @Test(arguments: [403, 409])
    func backendRejectionIsRejected(status: Int) async {
        let outcome = await MfaResponseClient(httpClient: stubClient(status: status)).respond(
            serverUrl: "https://relay.example.com",
            auth: auth,
            challengeId: "c1",
            approved: false
        )
        #expect(outcome == .rejected)
    }

    @Test func transportErrorIsFailure() async {
        let client = HTTPClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let outcome = await MfaResponseClient(httpClient: client).respond(
            serverUrl: "https://relay.example.com",
            auth: auth,
            challengeId: "c1",
            approved: true
        )
        guard case .failure = outcome else {
            Issue.record("Expected failure, got \(outcome)")
            return
        }
    }
}

@Suite struct ContactSyncClientTests {
    @Test func pullSendsSinceAndDecodesResponse() async throws {
        let client = stubClient(
            status: 200,
            json: #"{"cursor": 456, "changed": [{"uid": "srv-1", "rev": 2, "fn": "Ada"}], "deleted": []}"#
        ) { request in
            let url = request.url!.absoluteString
            #expect(url.hasPrefix("https://relay.example.com/api/contacts/sync"))
            #expect(url.contains("since=123"))
            #expect(!url.contains("sub="))
            #expect(!url.contains("hash="))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h")
            #expect(request.httpMethod == "GET")
        }
        let response = try await ContactSyncClient(httpClient: client).pull(
            serverUrl: "https://relay.example.com",
            auth: RelayAuth(deviceId: "u", deviceSecret: "h"),
            since: 123
        )
        #expect(response.cursor == 456)
        #expect(response.changed?.first?.uid == "srv-1")
        #expect(response.changed?.first?.fn == "Ada")
    }

    @Test func pushSendsBaseCursorAndChanges() async throws {
        let client = stubClient(status: 200, json: #"{"cursor": 7}"#) { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://relay.example.com/api/contacts/sync")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""baseCursor":123"#))
            #expect(body.contains(#""fn":"Ada""#))
            #expect(body.contains(#""value":"ada@example.com""#))
        }
        let response = try await ContactSyncClient(httpClient: client).push(
            serverUrl: "https://relay.example.com",
            auth: RelayAuth(deviceId: "u", deviceSecret: "h"),
            baseCursor: 123,
            changes: [ContactDTO(
                uid: "",
                rev: 0,
                deleted: nil,
                fn: "Ada",
                emails: [ContactFieldDTO(label: nil, value: "ada@example.com")],
                phones: []
            )]
        )
        #expect(response.cursor == 7)
    }

    @Test func fetchPhotoSendsPairingAuthAsHeaders() async throws {
        let client = stubClient(status: 200, json: "photo-bytes") { request in
            #expect(request.httpMethod == "GET")
            #expect(
                request.url?.absoluteString
                    == "https://relay.example.com/api/contacts/c-1/photo"
            )
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h")
        }
        let data = try await ContactSyncClient(httpClient: client).fetchPhoto(
            serverUrl: "https://relay.example.com",
            auth: RelayAuth(deviceId: "u", deviceSecret: "h"),
            uid: "c-1"
        )
        #expect(String(decoding: data, as: UTF8.self) == "photo-bytes")
    }
}

@Suite struct DeregisterClientTests {
    private let auth = RelayAuth(deviceId: "device-1", deviceSecret: "secret-1")

    @Test func success200SendsDeviceHeadersAndEmptyBody() async {
        let client = stubClient(status: 200, json: #"{"ok": true}"#) { request in
            #expect(
                request.url!.absoluteString
                    == "https://relay.example.com/api/notifications/native/deregister"
            )
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "device-1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "secret-1")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body == "{}")
        }
        let outcome = await DeregisterClient(httpClient: client)
            .deregister(serverUrl: "https://relay.example.com", auth: auth)
        #expect(outcome == .success)
    }

    @Test func unauthorizedFrom401() async {
        let outcome = await DeregisterClient(httpClient: stubClient(status: 401))
            .deregister(serverUrl: "https://relay.example.com", auth: auth)
        #expect(outcome == .unauthorized)
    }

    @Test func transportErrorIsFailure() async {
        let client = HTTPClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let outcome = await DeregisterClient(httpClient: client)
            .deregister(serverUrl: "https://relay.example.com", auth: auth)
        guard case .failure = outcome else {
            Issue.record("Expected failure, got \(outcome)")
            return
        }
    }
}

@Suite struct RelayAuthTests {
    @Test func headerFieldsReturnsDeviceIdAndSecretAsNamedHeaders() {
        let auth = RelayAuth(deviceId: "device-1", deviceSecret: "secret-1")

        let fields = auth.headerFields

        #expect(fields == [
            "X-Kypost-Device-Id": "device-1",
            "X-Kypost-Device-Secret": "secret-1",
        ])
    }
}

// MARK: - Response size limits

/// `session.data(for:)` buffers the whole body before returning, so an
/// attachment download let the relay choose this app's memory footprint.
@Suite struct ResponseSizeLimitTests {
    private let url = URL(string: "https://relay.example.com/api/mail/attachment")!

    @Test func anOversizedBodyIsRefused() async {
        let client = HTTPClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(repeating: 0x41, count: 4096), response)
        }
        await #expect(throws: NetworkError.responseTooLarge) {
            try await client.getData(url: url, maxBytes: 1024)
        }
    }

    @Test func aBodyWithinTheCapIsReturned() async throws {
        let payload = Data(repeating: 0x41, count: 512)
        let client = HTTPClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (payload, response)
        }
        let data = try await client.getData(url: url, maxBytes: 1024)
        #expect(data == payload)
    }

    /// The default cap has to clear a real attachment; a limit that rejects
    /// ordinary mail is an outage, not a control.
    @Test func theDefaultCapAllowsARealisticAttachment() {
        #expect(HTTPClient.maxAttachmentBytes >= 25 * 1024 * 1024)
    }

    /// The 409 body is interpolated into logs and toasts, so it is bounded.
    @Test func theConflictBodyIsTruncated() throws {
        let huge = String(repeating: "x", count: NetworkError.maxConflictBodyBytes * 4)
        let error = try #require(
            NetworkError.from(statusCode: 409, body: Data(huge.utf8))
        )
        guard case .conflict(let body) = error else {
            Issue.record("expected .conflict, got \(error)")
            return
        }
        #expect(body.count == NetworkError.maxConflictBodyBytes)
    }

    /// Truncation must not break the discriminator the send path reads.
    @Test func aSmallConflictBodyStillDecodes() throws {
        let error = try #require(NetworkError.from(
            statusCode: 409,
            body: Data(#"{"clientSideNeeded": true}"#.utf8)
        ))
        guard case .conflict(let body) = error else {
            Issue.record("expected .conflict, got \(error)")
            return
        }
        #expect(RelayMailSource.conflictError(body: body) == .clientSideNeeded)
    }
}

// MARK: - PgpPayloadClient request shape and decoding

@Suite struct PgpPayloadClientTests {
    private let auth = RelayAuth(deviceId: "dev-1", deviceSecret: "secret-1")

    /// The request contract, none of which was covered before — and every part
    /// of which had a live bug:
    ///
    ///   * the URL must be built so a bare-host `srv` (the stored form, with no
    ///     trailing slash) yields a valid absolute path. The old URLComponents
    ///     build produced a nil URL here and failed every read on the device;
    ///   * the mailbox and message travel as query items named `mailbox` and
    ///     `messageId`. The server parses `messageId` as an IMAP UID and 400s on
    ///     anything else, so a stray `message` broke every client-protected read;
    ///   * device identity travels in the pairing headers.
    @Test func requestTargetsThePayloadEndpointWithMailboxAndMessageId() async throws {
        let client = stubClient(status: 200, json: "{}") { request in
            let url = request.url!
            #expect(url.scheme == "https")
            #expect(url.host == "relay.example.com")
            #expect(url.path == "/api/mail/pgp-payload")

            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.contains(URLQueryItem(name: "mailbox", value: "INBOX")))
            #expect(items.contains(URLQueryItem(name: "messageId", value: "42")))
            #expect(!items.contains { $0.name == "message" })

            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "dev-1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "secret-1")
        }
        _ = try await PgpPayloadClient(
            httpClient: client, serverUrl: "https://relay.example.com", auth: auth
        ).fetch(mailbox: "INBOX", messageId: "42")
    }

    /// The signed-only wire fields decode. `signedPartBase64` is the octets the
    /// detached signature covers; if it silently dropped, signed-only mail would
    /// read blank — the very drift that motivated this path.
    @Test func decodesTheSignedOnlyWireFields() async throws {
        let json = """
        {
          "encryptedPayload": "",
          "signaturePayload": "-----BEGIN PGP SIGNATURE-----",
          "signedPartBase64": "aGk=",
          "body": "",
          "signerKeys": [],
          "sender": "Bob <bob@example.com>",
          "resolvedSender": "bob@example.com"
        }
        """
        let client = stubClient(status: 200, json: json)
        let outcome = try await PgpPayloadClient(
            httpClient: client, serverUrl: "https://relay.example.com", auth: auth
        ).fetch(mailbox: "INBOX", messageId: "42")
        guard case .success(let payload) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(payload.signedPartBase64 == "aGk=")
        #expect(payload.signaturePayload == "-----BEGIN PGP SIGNATURE-----")
        #expect(payload.resolvedSender == "bob@example.com")
        #expect(payload.rawSender == "Bob <bob@example.com>")
    }

    @Test func decodesTheServersOmittedSignerKeyDefaults() async throws {
        let json = """
        {
          "encryptedPayload": "ciphertext",
          "signerKeys": [{
            "addresses": ["bob@example.com"],
            "publicKey": "public-key"
          }]
        }
        """
        let outcome = try await PgpPayloadClient(
            httpClient: stubClient(status: 200, json: json),
            serverUrl: "https://relay.example.com",
            auth: auth
        ).fetch(mailbox: "INBOX", messageId: "42")

        guard case .success(let payload) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(payload.signerKeys == [SignerKey(
            addresses: ["bob@example.com"],
            publicKey: "public-key"
        )])
    }

    /// The three status codes each map to their own row rather than a generic
    /// failure, because each is a different sentence to the reader.
    @Test(arguments: [
        (404, PgpPayloadResult.noPayload),
        (409, PgpPayloadResult.notClientProtected),
        (413, PgpPayloadResult.tooLarge),
    ]) func statusCodesMapToTheirOwnRow(testCase: (status: Int, expected: PgpPayloadResult)) async throws {
        let outcome = try await PgpPayloadClient(
            httpClient: stubClient(status: testCase.status),
            serverUrl: "https://relay.example.com",
            auth: auth
        ).fetch(mailbox: "INBOX", messageId: "42")
        #expect(outcome == testCase.expected)
    }
}
