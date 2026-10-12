//
//  RelayOrigin.swift
//  KyPost
//
//  URL rules for KyIdentity sign-on, ported from KyPost Android's
//  `pairingUrl` / `pairingEndpoint` / `relayOrigin` / `canonicalOrigin`.
//  The origin string is part of the KyAuth handoff contract
//  (KyAuth-iOS docs/specs/2026-10-11-ios-signon-handoff.md): KyAuth refuses
//  a value that is not already canonical, so this must produce exactly
//  `https://host[:port]`, lowercase ASCII host, default port dropped.
//

import Foundation

nonisolated enum RelayOrigin {
    /// KyAuth's ceiling for the origin it binds into the assertion.
    static let maxLength = 256

    /// The relay base URL the user typed, or nil if KyPost may never send a
    /// credential to it: https only, no userinfo, a host, and no query or
    /// fragment (once a path is appended either would silently change which
    /// path is requested).
    static func baseComponents(_ serverUrl: String) -> URLComponents? {
        let trimmed = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == "https",
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            let host = components.encodedHost, !host.isEmpty,
            host.unicodeScalars.allSatisfy(\.isASCII)
        else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        return components
    }

    /// `path` resolved against the base URL's own path, never by string
    /// concatenation of the whole URL.
    static func endpoint(_ serverUrl: String, path: String) -> URL? {
        guard var components = baseComponents(serverUrl) else { return nil }
        components.scheme = "https"
        components.encodedHost = components.encodedHost?.lowercased()
        components.percentEncodedPath = trimmingTrailingSlashes(components.percentEncodedPath) + path
        return components.url
    }

    /// Lowercase ASCII host of the URL the client would connect to.
    static func host(_ serverUrl: String) -> String? {
        baseComponents(serverUrl)?.encodedHost?.lowercased()
    }

    /// Canonical origin of the relay URL (`https://host[:port]`), or nil if
    /// the client would refuse it.
    static func origin(_ serverUrl: String) -> String? {
        guard let components = baseComponents(serverUrl),
              let host = components.encodedHost?.lowercased()
        else { return nil }
        let origin: String
        if let port = components.port, port != 443 {
            origin = "https://\(host):\(port)"
        } else {
            origin = "https://\(host)"
        }
        return origin.count <= maxLength ? origin : nil
    }

    /// `scheme://host:port/path` with the default port made explicit and the
    /// trailing slash dropped; nil unless it is an http(s) URL with a host.
    /// Two values naming the same KyIdentity compare equal.
    static func canonicalIssuer(_ url: String?) -> String? {
        guard
            let url,
            let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.encodedHost?.lowercased(), !host.isEmpty
        else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)\(trimmingTrailingSlashes(components.percentEncodedPath))"
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = Substring(path)
        while path.hasSuffix("/") { path = path.dropLast() }
        return String(path)
    }
}
