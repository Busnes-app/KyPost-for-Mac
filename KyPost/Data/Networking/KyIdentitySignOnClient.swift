//
//  KyIdentitySignOnClient.swift
//  KyPost
//
//  Reads the relay's KyIdentity sign-in settings and swaps a KyIdentity ID
//  token for a `kypost://native-pair` link. Port of KyPost Android's
//  `KyIdentitySignOnClient`; status mapping and user-facing texts mirror it.
//
//  Every body is read bounded. The ID token lives in the request body for one
//  call and is never logged or stored.
//

import Foundation

nonisolated struct SignOnConfig: Equatable, Sendable {
    let issuerUrl: String
    let clientId: String
}

nonisolated enum SignOnConfigResult: Equatable, Sendable {
    case ready(SignOnConfig)
    case unavailable(String)
}

enum SignOnExchangeResult: Equatable, Sendable {
    case success(PairingParams)
    case failure(String)
}

final class KyIdentitySignOnClient: Sendable {
    /// Status code and body, the body already cut to at most `maxBytes`.
    typealias Transport = @Sendable (_ request: URLRequest, _ maxBytes: Int) async throws -> (Int, Data)

    static let maxErrorBytes = 4 * 1024
    static let maxOkBytes = 64 * 1024
    static let maxRefusalChars = 200
    static let timeout: Duration = .seconds(15)
    static let refused = "KyIdentity sign-in was refused"

    private let transport: Transport

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    func config(serverUrl: String) async -> SignOnConfigResult {
        guard let endpoint = RelayOrigin.endpoint(serverUrl, path: "/api/auth/sso-config") else {
            return .unavailable("Server URL must use https")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        guard let (code, raw) = await perform(request) else {
            return .unavailable(Self.unreachable)
        }
        return Self.mapConfig(code: code, body: raw)
    }

    func signOn(serverUrl: String, idToken: String) async -> SignOnExchangeResult {
        guard let endpoint = RelayOrigin.endpoint(serverUrl, path: "/api/auth/native/signon"),
              let host = endpoint.host()?.lowercased()
        else {
            return .failure("Server URL must use https")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["idToken": idToken])
        guard let (code, raw) = await perform(request) else {
            return .failure(Self.unreachable)
        }
        return Self.mapSignOn(code: code, body: raw, host: host)
    }

    // MARK: Pure mapping (tested directly)

    static func mapConfig(code: Int, body: Data) -> SignOnConfigResult {
        let notSignOn = "This server does not use KyIdentity sign-in"
        if code == 404 { return .unavailable(notSignOn) }
        if code != 200 { return .unavailable("Could not read the server's sign-in settings (\(code))") }
        guard let json = (try? JSONSerialization.jsonObject(with: body.prefix(maxOkBytes))) as? [String: Any] else {
            return .unavailable("The server returned an unreadable sign-in configuration")
        }
        let enabled = json["enabled"] as? Bool ?? false
        let issuer = trimmingTrailingSlashes(json["issuerUrl"] as? String ?? "")
        let clientId = json["clientId"] as? String ?? ""
        if !enabled || issuer.trimmingCharacters(in: .whitespaces).isEmpty
            || clientId.trimmingCharacters(in: .whitespaces).isEmpty {
            return .unavailable(notSignOn)
        }
        // KyAuth refuses these; saying so here is clearer than its error.
        guard RelayOrigin.canonicalIssuer(issuer) != nil, SignOnHandoff.isValidClientId(clientId) else {
            return .unavailable("The server returned an unreadable sign-in configuration")
        }
        return .ready(SignOnConfig(issuerUrl: issuer, clientId: clientId))
    }

    static func mapSignOn(code: Int, body: Data, host: String) -> SignOnExchangeResult {
        if code != 200 {
            let raw = String(decoding: body.prefix(maxErrorBytes), as: UTF8.self)
            let message = switch code {
            case 403: refusalText(raw)
            case 429: "Too many attempts. Try again later"
            case 503: "\(host) is not set up for KyIdentity sign-in or pairing"
            default: "Could not sign in to \(host) (\(code))"
            }
            return .failure(message)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: body.prefix(maxOkBytes))) as? [String: Any] else {
            return .failure("The server returned an unreadable pairing response")
        }
        let configured = json["configured"] as? Bool ?? false
        let deepLink = (json["deepLink"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard configured, !deepLink.isEmpty else {
            let error = (json["configurationError"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(error.isEmpty ? "Pairing is not configured on the server" : error)
        }
        let params: PairingParams
        do {
            guard let url = URL(string: deepLink) else { throw PairingLinkError.notAPairingLink }
            params = try PairingLinkParser.parse(url)
        } catch {
            return .failure(PushPairingViewModel.message(for: error))
        }
        let linkHost = URL(string: params.srv)?.host()?.lowercased() ?? ""
        guard linkHost == host else {
            return .failure("The server returned a pairing link for a different host (\(linkHost), not \(host))")
        }
        return .success(params)
    }

    /// The relay's 403 wording when it is plain text; anything else (a
    /// proxy's HTML page) is not ours.
    static func refusalText(_ raw: String) -> String {
        if raw.contains("<") { return refused }
        let first = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let text = String(first.prefix(maxRefusalChars)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? refused : text
    }

    // MARK: Transport

    private static let unreachable = "Could not reach the server"

    /// Nil on any transport failure, so the caller shows one sentence rather
    /// than a raw `URLError`.
    private func perform(_ request: URLRequest) async -> (Int, Data)? {
        var request = request
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let transport = self.transport
        // The whole call is bounded, not just each idle gap between bytes.
        return await withTaskGroup(of: (Int, Data)?.self) { group in
            group.addTask { try? await transport(request, Self.maxOkBytes) }
            group.addTask {
                try? await Task.sleep(for: Self.timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Production transport over the relay session: its delegate refuses
    /// cross-host redirects and enforces the SPKI pin when the host is the
    /// already-paired relay. Reads at most `maxBytes` and then stops.
    nonisolated static func sessionTransport(_ session: URLSession) -> Transport {
        { request, maxBytes in
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            var data = Data()
            for try await byte in bytes {
                if data.count >= maxBytes { break }
                data.append(byte)
            }
            return (http.statusCode, data)
        }
    }

    private static func trimmingTrailingSlashes(_ value: String) -> String {
        var value = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
        while value.hasSuffix("/") { value = value.dropLast() }
        return String(value)
    }
}
