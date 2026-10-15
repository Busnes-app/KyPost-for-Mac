//
//  PinnedSessionDelegate.swift
//  KyPost
//
//  TOFU certificate pinning for the relay connection (security-hardening
//  plan, Task 9). kypost is self-hosted with a per-user srv URL captured
//  at pairing, so a hardcoded pin can't work; instead the leaf SPKI
//  SHA-256 seen during the pairing handshake is stored, bound to the host
//  it was seen on, and every later request to that host must present the
//  same key.
//
//  Scope and limits, same as Android's: a pairing link without `pin=`
//  trusts the srv URL it carried on its first handshake (system trust, and
//  the key that handshake presented becomes the pin). Pin checks apply only
//  to the pinned host — scanned foreign key-exchange URLs (ScanPgpKeyView)
//  get default TLS handling.
//
//  Once a host is pinned the check fails closed: anything this delegate
//  cannot hash is refused rather than waved through, because the party
//  choosing the certificate is exactly the party a pin is meant to stop.
//  So does a pin lookup that fails: a Keychain read error is not "no pin".
//
//  The shared relay session's delegate (`SingletonGraph`) takes its pins
//  from the Keychain only. A pairing attempt never arms a pin there; it
//  gets its own session and delegate (`RelayPairingConnection`), so a pin a
//  link or probe supplied never reaches background sync.
//
//  The delegate also refuses every cross-origin redirect. Requests carry the
//  device secret in X-Kypost-Device-Secret, and URLSession only strips
//  `Authorization` across origins — a custom header rides along. Without
//  this, a relay answering `302 Location: https://elsewhere/` hands the
//  credential to a host the pin does not cover, since `decision` returns
//  .proceed for anything that is not the paired relay.
//

import CryptoKit
import Foundation
import os
import Security

nonisolated final class PinnedSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Why the last handshake with a host was refused.
    enum PinFailure: Equatable, Sendable {
        /// The host presented a key other than the pinned one, or one this
        /// delegate cannot hash.
        case mismatch
        /// The pin could not be read, so nothing could be checked.
        case unreadable
    }

    /// The pin to enforce for a host, or nil when that host has none. Throws
    /// when the lookup itself failed, and the handshake is then refused.
    private let pinnedHash: @Sendable (_ host: String) throws -> String?

    private let lock = NSLock()
    private var lastSeenByHost: [String: String] = [:]
    /// Hosts whose last handshake was refused, and why, so HTTPClient can map
    /// the resulting URLError.cancelled to the right error. Per-host rather
    /// than one session-wide flag: one delegate backs one URLSession backing
    /// every client, and a task cancelled for an ordinary reason (a view
    /// tearing down its request) also surfaces as URLError.cancelled — with a
    /// single Bool it would consume an unrelated host's pin failure and
    /// report interception on the wrong request.
    private var failureByHost: [String: PinFailure] = [:]

    init(pinnedHash: @escaping @Sendable (_ host: String) throws -> String?) {
        self.pinnedHash = pinnedHash
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            // Not a server-trust challenge: the system's normal evaluation.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let observed = Self.spkiSHA256(of: trust)
        // Read outside the lock: `pinnedHash` goes to the Keychain, and
        // holding a lock across that buys nothing.
        let failure = Self.failure(lookup: Result { try pinnedHash(host) }, observed: observed)

        lock.lock()
        if let observed { lastSeenByHost[host] = observed }
        // A handshake that satisfies the pin clears any earlier failure, so a
        // repaired certificate stops reporting a mismatch without needing a
        // relaunch.
        failureByHost[host] = failure
        lock.unlock()

        if failure == nil {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - Redirects

    /// Refuses any redirect that leaves the host the request was authenticated
    /// to. Passing nil to the completion handler stops the redirect and returns
    /// the 3xx response body to the caller, which decodes as a failure — the
    /// credential never moves.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // `originalRequest`, not `currentRequest`: on a redirect chain every
        // hop must stay on the host the caller chose, otherwise a two-step
        // relay → relay → attacker chain walks off the origin one hop at a
        // time while each individual hop looks same-host.
        guard Self.allowsRedirect(from: task.originalRequest?.url, to: request.url) else {
            Log.app.error("Refused a cross-host redirect to a foreign relay host")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    /// Pure so the rule is testable without a live redirect. Same host and
    /// same effective port, still https, both parseable — anything else is
    /// refused. Another port on the same host is another server, and the
    /// device secret was not meant for it.
    static func allowsRedirect(from origin: URL?, to destination: URL?) -> Bool {
        guard
            let origin, let destination,
            destination.scheme?.lowercased() == "https",
            let originHost = origin.host()?.lowercased(),
            let destinationHost = destination.host()?.lowercased(),
            let originPort = effectivePort(of: origin),
            let destinationPort = effectivePort(of: destination)
        else { return false }
        return originHost == destinationHost && originPort == destinationPort
    }

    /// The URL's explicit port, else its scheme's default; nil for a scheme
    /// with neither.
    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    enum PinDecision: Equatable {
        /// Hand off to the system's normal TLS evaluation.
        case proceed
        case refuse
    }

    /// The pinning rule, pure so it is directly testable — a real handshake
    /// can't be staged in a unit test, and this is the part that must not be
    /// wrong.
    ///
    /// `observed` is nil when the leaf's key shape has no SPKI header in the
    /// table below, so no hash can be computed. For a pinned host that MUST
    /// refuse: the attacker picks the algorithm of the certificate they
    /// present, so treating "unsupported shape" as "nothing to check" would
    /// hand a free bypass to anyone who can already get a system-trusted cert
    /// for the host — which is the entire threat pinning exists to cover.
    /// Unpinned hosts (scanned foreign key-exchange URLs) are unaffected.
    static func decision(pinned: String?, observed: String?) -> PinDecision {
        guard let pinned, !pinned.isEmpty else { return .proceed }
        guard let observed, observed == pinned else { return .refuse }
        return .proceed
    }

    /// The rule including the lookup. A pin that could not be read refuses:
    /// reading a Keychain error as "no pin" would hand the connection to
    /// system trust, which is exactly what a pin exists to override. Only a
    /// lookup that answered "nothing stored for this host" proceeds unpinned.
    static func failure(lookup: Result<String?, any Error>, observed: String?) -> PinFailure? {
        switch lookup {
        case .failure:
            .unreadable
        case .success(let pinned):
            decision(pinned: pinned, observed: observed) == .refuse ? .mismatch : nil
        }
    }

    /// The SPKI hash observed on the most recent handshake with `host`.
    func lastSeenHash(forHost host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastSeenByHost[host]
    }

    /// Why the last handshake with `host` was refused, or nil. Sticky until a
    /// handshake there succeeds — every request to a pin-failing host is
    /// genuinely refused, so there is nothing to consume.
    func pinFailure(forHost host: String) -> PinFailure? {
        lock.lock()
        defer { lock.unlock() }
        return failureByHost[host]
    }

    // MARK: - Sessions

    /// The configuration every relay session uses: ephemeral, with no
    /// response cache and no cookie store. Relay responses carry mail,
    /// contacts and key material; `.default` wrote them to the app's shared
    /// on-disk `URLCache`, where they outlived an unpair and the security
    /// wipe.
    static func relaySessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return configuration
    }

    /// Removes what relay sessions built from `.default` by earlier builds
    /// left in the process-wide stores: cached responses in
    /// `URLCache.shared` and cookies in `HTTPCookieStorage.shared`. Nothing
    /// else in this app reads either, so both are emptied whole. Run on
    /// unpair, on pairing another account, and by the wipe.
    static func purgeLegacySharedHTTPState(
        cache: URLCache = .shared,
        cookies: HTTPCookieStorage = .shared
    ) {
        cache.removeAllCachedResponses()
        cookies.removeCookies(since: .distantPast)
    }

    /// Maps a refused handshake's `URLError.cancelled` onto the reason it was
    /// refused, scoped to the request's host so an unrelated cancellation
    /// never inherits another host's failure.
    func mapPinFailure(_ request: URLRequest, _ error: any Error) -> any Error {
        guard let urlError = error as? URLError, urlError.code == .cancelled,
              let failure = pinFailure(forHost: request.url?.host() ?? "")
        else { return error }
        switch failure {
        case .mismatch: return NetworkError.certificateMismatch
        case .unreadable: return NetworkError.pinUnreadable
        }
    }

    // MARK: - SPKI hashing

    static func spkiSHA256(of trust: SecTrust) -> String? {
        guard
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return nil }
        return spkiSHA256(ofCertificate: leaf)
    }

    /// Lowercase hex SHA-256 over the DER SubjectPublicKeyInfo — the same
    /// value `openssl x509 -pubkey | openssl pkey -pubin -outform DER |
    /// openssl dgst -sha256` prints. SecKeyCopyExternalRepresentation
    /// returns the raw key (PKCS#1/X9.63), so the fixed ASN.1 header for
    /// the key's type and size is prepended to reconstruct the SPKI.
    static func spkiSHA256(ofCertificate certificate: SecCertificate) -> String? {
        if let key = SecCertificateCopyKey(certificate),
           let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
           let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?,
           let header = spkiHeader(
               keyType: attributes[kSecAttrKeyType] as? String,
               keySizeInBits: attributes[kSecAttrKeySizeInBits] as? Int
           ) {
            var spki = Data(header)
            spki.append(keyData)
            return SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
        }

        // Fall back to reading the SubjectPublicKeyInfo straight out of the
        // certificate. The header table only covers six key shapes, and an
        // unhashable shape (Ed25519, RSA-1024, RSA-8192…) meant the observed
        // hash was never recorded — so the pin silently never armed at all,
        // while the docs said pinning was always on. The enforcement path is
        // fail-closed; it was *arming* that failed open.
        guard let spki = subjectPublicKeyInfo(
            ofCertificateDER: SecCertificateCopyData(certificate) as Data
        ) else { return nil }
        return SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
    }

    /// One DER TLV: its tag, header width, and content length.
    private static func readTLV(_ bytes: Data, at index: Int) -> (tag: UInt8, header: Int, length: Int)? {
        guard index >= 0, index + 1 < bytes.count else { return nil }
        let tag = bytes[bytes.startIndex + index]
        var cursor = index + 1
        let first = Int(bytes[bytes.startIndex + cursor])
        cursor += 1
        let length: Int
        if first & 0x80 == 0 {
            length = first
        } else {
            let width = first & 0x7F
            // Long-form lengths beyond 4 bytes don't occur in certificates and
            // would risk overflow; refuse rather than guess.
            guard width > 0, width <= 4, cursor + width <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<width {
                value = (value << 8) | Int(bytes[bytes.startIndex + cursor + offset])
            }
            length = value
            cursor += width
        }
        guard length >= 0, cursor + length <= bytes.count else { return nil }
        return (tag, cursor - index, length)
    }

    /// The SubjectPublicKeyInfo bytes of an X.509 certificate, hashed as-is —
    /// the same value `openssl x509 -pubkey | openssl pkey -pubin -outform DER
    /// | openssl dgst -sha256` prints, verified against RSA-2048, EC P-256 and
    /// Ed25519 certificates.
    ///
    /// Certificate ::= SEQUENCE { tbsCertificate, … }, and TBSCertificate ::=
    /// SEQUENCE { [0] version OPTIONAL, serialNumber, signature, issuer,
    /// validity, subject, subjectPublicKeyInfo, … } — so skip an optional
    /// context-0 element then five fields.
    static func subjectPublicKeyInfo(ofCertificateDER der: Data) -> Data? {
        guard let certificate = readTLV(der, at: 0), certificate.tag == 0x30 else { return nil }
        let certificateContent = certificate.header
        guard let tbs = readTLV(der, at: certificateContent), tbs.tag == 0x30 else { return nil }

        var index = certificateContent + tbs.header
        let tbsEnd = index + tbs.length

        guard let version = readTLV(der, at: index) else { return nil }
        if version.tag == 0xA0 {
            index += version.header + version.length
        }
        for _ in 0..<5 {
            guard let field = readTLV(der, at: index) else { return nil }
            index += field.header + field.length
            guard index <= tbsEnd else { return nil }
        }

        guard let spki = readTLV(der, at: index), spki.tag == 0x30 else { return nil }
        let total = spki.header + spki.length
        guard index + total <= tbsEnd else { return nil }
        let start = der.startIndex + index
        return der[start..<(start + total)]
    }

    /// Fixed SPKI prefixes per key shape (the TrustKit table, plus P-521).
    /// Unknown shapes return nil — never a wrong hash — and the challenge
    /// handler turns that nil into a *refusal* for any pinned host rather
    /// than a fallback, so a gap here costs availability, never protection.
    /// Every entry is a known-answer test in PinnedSessionTests.
    private static func spkiHeader(keyType: String?, keySizeInBits: Int?) -> [UInt8]? {
        let rsa = kSecAttrKeyTypeRSA as String
        let ec = kSecAttrKeyTypeECSECPrimeRandom as String
        switch (keyType, keySizeInBits) {
        case (rsa, 2048):
            return [
                0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
            ]
        case (rsa, 3072):
            return [
                0x30, 0x82, 0x01, 0xa2, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x8f, 0x00,
            ]
        case (rsa, 4096):
            return [
                0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00,
            ]
        case (ec, 256):
            return [
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
                0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
                0x42, 0x00,
            ]
        case (ec, 384):
            return [
                0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
                0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
            ]
        case (ec, 521):
            return [
                0x30, 0x81, 0x9b, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d,
                0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23, 0x03, 0x81, 0x86,
                0x00,
            ]
        default:
            return nil
        }
    }
}
