//
//  SignOnHandoff.swift
//  KyPost
//
//  Consumer half of the KyAuth iOS sign-on handoff. Binding contract:
//  KyAuth-iOS docs/specs/2026-10-11-ios-signon-handoff.md.
//
//  Requests and responses travel through the App Group container
//  `group.org.kysecurity.signon`, which only apps of team TATYN4X57D can open;
//  URLs carry only a single-use nonce. KyPost writes `SignOn/requests/` and
//  reads and deletes `SignOn/responses/`. It sweeps stale files only in the
//  directory it reads; KyAuth sweeps `requests/`.
//
//  The ID token in a response is never logged and never persisted by KyPost:
//  the response file is deleted as it is read.
//

import Foundation
import Security

nonisolated struct SignOnRequestFile: Encodable, Equatable, Sendable {
    let v: Int
    let nonce: String
    let consumer: String
    let clientId: String
    let origin: String
    let issuer: String
    let createdAtMs: Int64
}

nonisolated enum SignOnHandoffResponse: Equatable, Sendable, CustomStringConvertible {
    case ok(idToken: String)
    case cancelled
    case error(message: String)

    /// Never prints the token.
    var description: String {
        switch self {
        case .ok: "ok(redacted)"
        case .cancelled: "cancelled"
        case .error(let message): "error(\(message))"
        }
    }
}

nonisolated enum SignOnHandoff {
    static let appGroup = "group.org.kysecurity.signon"
    /// This app's bundle ID; KyAuth's `TrustedConsumers` maps it to "KyPost"
    /// and the `kypost` return scheme.
    static let consumer = "org.kysecurity.mail"
    static let returnHost = "kyidentity-signon"
    /// How long KyPost waits for KyAuth before abandoning the nonce.
    static let pendingTimeout: TimeInterval = 180
    /// Files older than this in `responses/` are swept.
    static let staleAfter: TimeInterval = 5 * 60
    /// The message cap the contract sets for `error` responses.
    static let maxMessageLength = 200
    /// An ID token is a few KB; anything far beyond that is not a response.
    static let maxResponseBytes = 64 * 1024

    // MARK: Nonce

    /// 32 random bytes, base64url without padding: 43 characters.
    static func makeNonce() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return base64url(Data(bytes))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isValidNonce(_ nonce: String) -> Bool {
        nonce.utf8.count == 43 && nonce.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }

    /// `[A-Za-z0-9._:-]{1,128}`, the shape KyAuth accepts.
    static func isValidClientId(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0))
        }
    }

    // MARK: URLs

    static func kyAuthURL(nonce: String) -> URL? {
        guard isValidNonce(nonce) else { return nil }
        return URL(string: "kyauth://signon?nonce=\(nonce)")
    }

    /// The nonce from `kypost://kyidentity-signon?nonce=…`, or nil when the
    /// URL is not a sign-on return. Says nothing about whether the nonce is
    /// the one KyPost is waiting for.
    static func returnNonce(from url: URL) -> String? {
        guard
            url.scheme?.lowercased() == Config.deepLinkScheme,
            url.host()?.lowercased() == returnHost,
            let nonce = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "nonce" })?.value,
            isValidNonce(nonce)
        else { return nil }
        return nonce
    }

    // MARK: Encoding

    static func encode(_ request: SignOnRequestFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }

    /// Decodes a response file for `nonce`. Nil when it is not a v1 response
    /// for exactly that nonce with a known status.
    static func decodeResponse(_ data: Data, nonce: String) -> SignOnHandoffResponse? {
        guard
            data.count <= maxResponseBytes,
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            (json["v"] as? NSNumber)?.intValue == 1,
            json["nonce"] as? String == nonce,
            let status = json["status"] as? String
        else { return nil }
        switch status {
        case "ok":
            return .ok(idToken: json["idToken"] as? String ?? "")
        case "cancelled":
            return .cancelled
        case "error":
            let message = (json["message"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .error(message: String(message.prefix(maxMessageLength)))
        default:
            return nil
        }
    }
}

/// The App Group directory pair. `root` is injectable so tests use a scratch
/// directory instead of the group container.
nonisolated struct SignOnHandoffStore: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// Nil when the App Group is not provisioned for this build.
    init?() {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SignOnHandoff.appGroup)
        else { return nil }
        root = container.appending(path: "SignOn", directoryHint: .isDirectory)
    }

    var requestsDirectory: URL { root.appending(path: "requests", directoryHint: .isDirectory) }
    var responsesDirectory: URL { root.appending(path: "responses", directoryHint: .isDirectory) }

    func requestFile(_ nonce: String) -> URL { requestsDirectory.appending(path: "\(nonce).json") }
    func responseFile(_ nonce: String) -> URL { responsesDirectory.appending(path: "\(nonce).json") }

    /// Atomic, `FileProtectionType.complete`.
    func writeRequest(_ request: SignOnRequestFile) throws {
        guard SignOnHandoff.isValidNonce(request.nonce) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(
            at: requestsDirectory,
            withIntermediateDirectories: true,
            attributes: Self.directoryAttributes
        )
        try SignOnHandoff.encode(request).write(
            to: requestFile(request.nonce),
            options: Self.writeOptions
        )
    }

    /// Withdraws a request nobody will read (KyAuth could not be opened).
    /// The file is this app's own; this is not a sweep of `requests/`.
    func withdrawRequest(_ nonce: String) {
        guard SignOnHandoff.isValidNonce(nonce) else { return }
        try? FileManager.default.removeItem(at: requestFile(nonce))
    }

    /// Reads and deletes the response for `nonce`. Nil when there is none
    /// yet; `.some(nil)` when a file was there but was not a valid response
    /// for this nonce (it is deleted either way).
    func takeResponse(_ nonce: String) -> SignOnHandoffResponse?? {
        guard SignOnHandoff.isValidNonce(nonce) else { return nil }
        let file = responseFile(nonce)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= SignOnHandoff.maxResponseBytes, let data = try? Data(contentsOf: file) else {
            return .some(nil)
        }
        return .some(SignOnHandoff.decodeResponse(data, nonce: nonce))
    }

    /// Deletes responses older than five minutes — only in `responses/`,
    /// the directory this app reads.
    func sweepStaleResponses(now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: responsesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, now.timeIntervalSince(modified) > SignOnHandoff.staleAfter {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // The handoff runs on iOS only. macOS volumes refuse data-protection
    // classes, and the store compiles there only so its tests run.
#if os(iOS)
    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    private static var directoryAttributes: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.complete]
    }
#else
    private static let writeOptions: Data.WritingOptions = [.atomic]
    private static var directoryAttributes: [FileAttributeKey: Any] { [:] }
#endif
}
