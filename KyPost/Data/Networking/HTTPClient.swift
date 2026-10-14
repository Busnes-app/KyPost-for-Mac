//
//  HTTPClient.swift
//  KyPost
//
//  URLSession wrapper (spec Phase 2, OkHttp equivalent). Centralizes the
//  pairing-auth headers and HTTP status → error mapping so every client
//  shares one failure model (Ponytail principle #4).
//

import Foundation

/// Shared failure model for all backend calls.
enum NetworkError: Error, Equatable, LocalizedError {
    case invalidURL
    /// 401/403 — pairing credentials rejected; prompt re-scan (spec §3).
    case unauthorized
    /// 400 — the request was malformed, or the account has no mail configured
    /// yet. The relay answers plain text, and the body is the only way to tell
    /// those apart, so it is retained here exactly as 409's is. Deciding what
    /// the text *means* is the relay layer's job, not this one's.
    case badRequest(body: String)
    /// 409 — backend rejected the request state (e.g. expired MFA challenge).
    case conflict(body: String)
    /// 429 — rate limited (e.g. too many desktop pairing attempts, or the
    /// relay's per-device lockout after repeated bad credentials). `retryAfter`
    /// is the `Retry-After` header in seconds, or nil when it was absent or
    /// unparseable — callers must still back off rather than retrying at once.
    case rateLimited(retryAfter: Int?)
    /// The relay presented a different key than the one pinned at pairing
    /// (TOFU). Deliberately distinct from `.transport`: either a legitimate
    /// certificate rotation (clear the pairing and re-pair) or interception.
    case certificateMismatch
    /// 503 — backend config issue; persistent error, cannot retry (spec §3).
    case serviceUnavailable
    /// The response body exceeded the caller's cap. A hostile or broken relay
    /// must not be able to choose this app's memory footprint.
    case responseTooLarge
    case server(statusCode: Int)
    case transport(description: String)
    case decoding(description: String)

    /// Longest body kept for `badRequest` and `conflict`. The payload is a small JSON
    /// discriminator (RelayMailSource.conflictError); the rest is only ever
    /// interpolated into logs and toasts, so an unbounded body would be a free
    /// way to blow those up.
    static let maxConflictBodyBytes = 8 * 1024

    /// User-facing text for the errors that reach toasts/list banners via
    /// localizedDescription; the rest keep their default rendering.
    var errorDescription: String? {
        switch self {
        case .certificateMismatch:
            String(localized: "The server's security certificate changed and no longer matches this pairing. If you rotated your server's certificate, remove the pairing in Settings → Connection and re-pair; otherwise the connection may be intercepted.")
        case .responseTooLarge:
            String(localized: "The server sent more data than KyPost will accept for this request.")
        case .rateLimited(let retryAfter):
            retryAfter.map {
                String(localized: "Too many attempts — try again in \(NetworkError.formatRetryAfter($0)).")
            } ?? String(localized: "Too many attempts — try again later.")
        default:
            nil
        }
    }

    /// Whole minutes once past a minute: a Retry-After of 900 read back as
    /// "900 seconds" is not something a user can act on. Mirrors Android's
    /// `formatRetryAfter`.
    static func formatRetryAfter(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "\(seconds) seconds"
        case ..<120: "a minute"
        default: "\(seconds / 60) minutes"
        }
    }

    /// Maps a non-2xx HTTP status to its error. 2xx returns nil. `body` is
    /// retained only for 409, where the relay distinguishes a client-protected
    /// send refusal from an ordinary conflict by its payload.
    ///
    /// `retryAfter` is passed in rather than read here: this function sees a
    /// status code and a body, never the headers. Android hit the same wall
    /// and resolved it the same way — the seconds are parsed at the call site
    /// that holds the `HTTPURLResponse`.
    static func from(
        statusCode: Int,
        body: Data = Data(),
        retryAfter: Int? = nil
    ) -> NetworkError? {
        switch statusCode {
        case 200..<300: nil
        case 400: .badRequest(
            body: String(decoding: body.prefix(maxConflictBodyBytes), as: UTF8.self)
        )
        case 401, 403: .unauthorized
        case 409: .conflict(
            body: String(decoding: body.prefix(maxConflictBodyBytes), as: UTF8.self)
        )
        case 429: .rateLimited(retryAfter: retryAfter)
        case 503: .serviceUnavailable
        default: .server(statusCode: statusCode)
        }
    }

    /// `Retry-After` as whole seconds. RFC 9110 also allows an HTTP-date form;
    /// only the delta-seconds form is honoured, and anything else reads as
    /// absent rather than as zero — "retry immediately" is the one answer a
    /// malformed header must not produce.
    static func retryAfterSeconds(from response: HTTPURLResponse) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        guard let seconds = Int(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0 else {
            return nil
        }
        return seconds
    }
}

/// Per-device auth credentials, sent as X-Kypost-Device-Id/X-Kypost-Device-Secret
/// headers on every authenticated request. deviceSecret is minted server-side
/// once per successful registration and returned only in that response — see
/// DeviceRegistrationService.performPair.
struct RelayAuth: Equatable, Sendable {
    var deviceId: String
    var deviceSecret: String

    init(deviceId: String, deviceSecret: String) {
        self.deviceId = deviceId
        self.deviceSecret = deviceSecret
    }

    init(pairing: Pairing) {
        self.init(deviceId: pairing.lastDeviceId ?? "", deviceSecret: pairing.deviceSecret)
    }

    var headerFields: [String: String] {
        ["X-Kypost-Device-Id": deviceId, "X-Kypost-Device-Secret": deviceSecret]
    }
}

final class HTTPClient: Sendable {
    /// Injectable transport so clients are unit-testable without a network.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    /// Transport for bodies of unknown size, capped at `limit` bytes.
    typealias StreamTransport = @Sendable (_ request: URLRequest, _ limit: Int) async throws
        -> (Data, URLResponse)

    /// Cap for attachment downloads — the only path that reads an
    /// attacker-sized body. Comfortably above any mail provider's attachment
    /// limit, far below what would jetsam an iPhone.
    static let maxAttachmentBytes = 64 * 1024 * 1024

    private let transport: Transport
    private let streamTransport: StreamTransport
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        transport = { try await session.data(for: $0) }
        streamTransport = Self.streamTransport(session: session)
    }

    init(transport: @escaping Transport) {
        self.transport = transport
        streamTransport = Self.cappingStreamTransport(wrapping: transport)
    }

    /// Both seams supplied. The pinned relay client needs this: it wraps every
    /// call to map a pin failure onto `certificateMismatch`, and building it
    /// from `init(transport:)` alone silently left attachment downloads on the
    /// buffering fallback — which is exactly the path the cap exists for.
    init(transport: @escaping Transport, streamTransport: @escaping StreamTransport) {
        self.transport = transport
        self.streamTransport = streamTransport
    }

    /// Streams a response and refuses one that exceeds `limit`.
    ///
    /// `session.data(for:)` buffers the whole body before returning, so a size
    /// check there arrives after the memory was already spent. AsyncBytes hands
    /// back the response headers first, which lets an over-sized body be
    /// refused before a byte of it is retained.
    static func streamTransport(session: URLSession) -> StreamTransport {
        { request, limit in
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse,
               http.expectedContentLength > Int64(limit) {
                throw NetworkError.responseTooLarge
            }
            var data = Data()
            if let http = response as? HTTPURLResponse, http.expectedContentLength > 0 {
                data.reserveCapacity(Int(min(http.expectedContentLength, Int64(limit))))
            }
            // A chunked response can lie about (or omit) its length, so the
            // running total is enforced too.
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw NetworkError.responseTooLarge }
            }
            return (data, response)
        }
    }

    /// Fallback for a buffering transport (tests): the cap still applies, it
    /// just cannot be enforced before the stub has produced its body.
    static func cappingStreamTransport(wrapping transport: @escaping Transport) -> StreamTransport {
        { request, limit in
            let (data, response) = try await transport(request)
            guard data.count <= limit else { throw NetworkError.responseTooLarge }
            return (data, response)
        }
    }

    // MARK: - Requests

    func get<Response: Decodable>(
        _ type: Response.Type,
        url: URL,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:]
    ) async throws -> Response {
        var request = URLRequest(url: try url.appending(queryOrThrow: query))
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await decode(execute(request))
    }

    /// GET returning the raw response body (attachment downloads), capped so
    /// the relay cannot choose how much memory this app allocates.
    func getData(
        url: URL,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        maxBytes: Int = HTTPClient.maxAttachmentBytes
    ) async throws -> Data {
        var request = URLRequest(url: try url.appending(queryOrThrow: query))
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await execute(request, streamingUpTo: maxBytes)
    }

    /// - Parameter timeout: this request's idle timeout; the session's
    ///   (60 s) when nil.
    func post<Response: Decodable>(
        _ type: Response.Type,
        url: URL,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        jsonBody: some Encodable,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        try await send(
            type, method: "POST", url: url, query: query, headers: headers,
            jsonBody: jsonBody, timeout: timeout
        )
    }

    func put<Response: Decodable>(
        _ type: Response.Type,
        url: URL,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        jsonBody: some Encodable
    ) async throws -> Response {
        try await send(type, method: "PUT", url: url, query: query, headers: headers, jsonBody: jsonBody)
    }

    /// DELETE with no request body — the relay identifies the target with a
    /// query parameter, not a payload.
    func delete<Response: Decodable>(
        _ type: Response.Type,
        url: URL,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:]
    ) async throws -> Response {
        var request = URLRequest(url: try url.appending(queryOrThrow: query))
        request.httpMethod = "DELETE"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await decode(execute(request))
    }

    // MARK: - Private

    private func send<Response: Decodable>(
        _ type: Response.Type,
        method: String,
        url: URL,
        query: [URLQueryItem],
        headers: [String: String],
        jsonBody: some Encodable,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        var request = URLRequest(url: try url.appending(queryOrThrow: query))
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            request.httpBody = try encoder.encode(jsonBody)
        } catch {
            throw NetworkError.decoding(description: "Encoding request body: \(error)")
        }
        return try await decode(execute(request))
    }

    /// `streamingUpTo` routes through the capped streaming transport; nil uses
    /// the buffering one (JSON endpoints, whose bodies the relay's own handlers
    /// bound).
    private func execute(_ request: URLRequest, streamingUpTo limit: Int? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            if let limit {
                (data, response) = try await streamTransport(request, limit)
            } else {
                (data, response) = try await transport(request)
            }
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.transport(description: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.transport(description: "Non-HTTP response")
        }
        if let error = NetworkError.from(
            statusCode: http.statusCode,
            body: data,
            retryAfter: NetworkError.retryAfterSeconds(from: http)
        ) {
            throw error
        }
        return data
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw NetworkError.decoding(description: "\(error)")
        }
    }
}

extension URL {
    /// Appends query items, preserving any existing ones.
    func appending(queryOrThrow items: [URLQueryItem]) throws -> URL {
        guard !items.isEmpty else { return self }
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL
        }
        components.queryItems = (components.queryItems ?? []) + items
        guard let url = components.url else { throw NetworkError.invalidURL }
        return url
    }
}
