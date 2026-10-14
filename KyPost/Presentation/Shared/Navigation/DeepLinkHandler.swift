//
//  DeepLinkHandler.swift
//  KyPost
//
//  Deep-link parsing and routing (spec §1, §10). Binding contract: the pairing
//  scheme is exactly kypost://native-pair with required params
//  sub, srv, pt and optional reg. There is no credential in the link itself —
//  the per-device pairing secret is issued only via the registration
//  response, never carried in the deep link/QR.
//

import Foundation

/// Parameters carried by a pairing deep link / QR code.
struct PairingParams: Equatable, Sendable {
    var sub: String
    /// Relay server URL; becomes Pairing.srv, never edited by the user.
    var srv: String
    /// Pairing token.
    var pt: String
    /// Optional registration URL override.
    var reg: String?
    /// Server-published leaf SPKI pin, already normalised to the lowercase
    /// hex `PinnedSessionDelegate` compares against (see `SpkiPin`). Nil
    /// means the link carried none, and this pairing is trust-on-first-use —
    /// never that one was present and discarded, which the parser refuses.
    var pin: String?

    /// Registration endpoint: a `reg` override on the same host as `srv` wins,
    /// otherwise derived from srv (mirrors the pull-endpoint derivation rule in
    /// spec §3).
    ///
    /// The same-host rule is enforced here as well as at parse time, because
    /// `reg` is persisted as `Pairing.registrationUrl` and replayed on every
    /// foreground and APNs-token refresh. Validating only at parse time would
    /// leave a device that was already pointed at a foreign host re-sending its
    /// push token there forever, even after the parser was fixed.
    var registrationEndpoint: URL? {
        let derived = URL(string: srv)?.appending(path: "api/notifications/native/register")
        guard let reg, !reg.isEmpty, let override = URL(string: reg) else { return derived }
        guard let overrideHost = override.host()?.lowercased(),
              let srvHost = URL(string: srv)?.host()?.lowercased(),
              overrideHost == srvHost
        else { return derived }
        return override
    }
}

enum PairingLinkError: Error, Equatable {
    case notAPairingLink
    case missingParameter(String)
    /// `srv`/`reg` must be `https` — the pairing exchange sends the device's
    /// real push token and (on success) mints the per-device secret, so a
    /// plaintext destination could have both intercepted in transit.
    case insecureServerURL
    /// `reg` names a different host than `srv`. The confirmation screen shows
    /// the user `srv`, but the credential POST goes to `reg` — so a link
    /// pairing a trusted-looking `srv` with an attacker-controlled `reg`
    /// displayed one host and contacted another. The relay always emits both
    /// on the same host, so requiring that costs nothing.
    case registrationHostMismatch
    /// `pin=` was present but is not a base64 SHA-256 SPKI hash. Refused
    /// rather than ignored: a link that carries a pin is a link whose author
    /// intended the registration POST to be pinned, and silently downgrading
    /// that to trust-on-first-use hands the pairing token to whoever mangled
    /// it. Android refuses the same case.
    case malformedCertificatePin
}

enum PairingLinkParser {
    /// Parses and validates a pairing link. All required params must be
    /// present and non-empty (spec §1), and `srv`/`reg` must be `https` URLs
    /// (mirrors the same check already applied to the PGP QR-key flow in
    /// PgpQrClient.scannedKeyCode(fromPayload:)).
    static func parse(_ url: URL) throws -> PairingParams {
        guard
            url.scheme?.lowercased() == Config.deepLinkScheme,
            url.host()?.lowercased() == Config.pairingHost
        else {
            throw PairingLinkError.notAPairingLink
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = (components?.queryItems ?? []).reduce(into: [String: String]()) {
            $0[$1.name] = $1.value
        }

        func required(_ name: String) throws -> String {
            guard let value = query[name], !value.isEmpty else {
                throw PairingLinkError.missingParameter(name)
            }
            return value
        }

        let srv = try required("srv")
        guard URL(string: srv)?.scheme?.lowercased() == "https" else {
            throw PairingLinkError.insecureServerURL
        }
        let reg = query["reg"].flatMap { $0.isEmpty ? nil : $0 }
        if let reg {
            guard let regURL = URL(string: reg),
                  regURL.scheme?.lowercased() == "https"
            else {
                throw PairingLinkError.insecureServerURL
            }
            // The confirmation screen names srv's host, but the registration
            // POST — which carries the push token and receives the device
            // secret — goes to reg. Letting them differ meant the one control
            // on this path described a host the credentials never reached.
            guard let regHost = regURL.host()?.lowercased(),
                  let srvHost = URL(string: srv)?.host()?.lowercased(),
                  regHost == srvHost
            else {
                throw PairingLinkError.registrationHostMismatch
            }
        }

        // Absent is fine (TOFU, and what every 0.3.x relay emits). Present
        // but unreadable is not — see PairingLinkError.malformedCertificatePin.
        var pin: String?
        if let rawPin = query["pin"], !rawPin.isEmpty {
            guard let normalized = SpkiPin.normalizedHex(fromLinkValue: rawPin) else {
                throw PairingLinkError.malformedCertificatePin
            }
            pin = normalized
        }

        return PairingParams(
            sub: try required("sub"),
            srv: srv,
            pt: try required("pt"),
            reg: reg,
            pin: pin
        )
    }
}

/// Parameters carried by a desktop pairing deep link (Desktop Pairing guide).
struct DesktopPairingParams: Equatable, Sendable {
    /// One-time pairing code: 32 characters, 5-minute TTL, single use.
    var code: String
    /// Server base URL from the `srv` param.
    var srv: String

    /// Registration endpoint, derived from srv per the guide's Step 3.
    var registerEndpoint: URL? {
        URL(string: srv)?.appending(path: "api/notifications/desktop/register")
    }
}

enum DesktopPairingLinkParser {
    /// Parses kypost://desktop-pair?code=…&srv=… links. Both params are
    /// required and non-empty, and `srv` must be an `https` URL (see
    /// PairingLinkError.insecureServerURL).
    static func parse(_ url: URL) throws -> DesktopPairingParams {
        guard
            url.scheme?.lowercased() == Config.deepLinkScheme,
            url.host()?.lowercased() == Config.desktopPairingHost
        else {
            throw PairingLinkError.notAPairingLink
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = (components?.queryItems ?? []).reduce(into: [String: String]()) {
            $0[$1.name] = $1.value
        }

        guard let code = query["code"], !code.isEmpty else {
            throw PairingLinkError.missingParameter("code")
        }
        guard let srv = query["srv"], !srv.isEmpty else {
            throw PairingLinkError.missingParameter("srv")
        }
        guard URL(string: srv)?.scheme?.lowercased() == "https" else {
            throw PairingLinkError.insecureServerURL
        }
        return DesktopPairingParams(code: code, srv: srv)
    }
}

/// Where a deep link or notification tap should take the user (spec §10).
enum NavigationAction: Equatable, Sendable {
    case openPairingFlow(PairingParams)
    case openDesktopPairingFlow(DesktopPairingParams)
    case openEmail(messageId: String)
    /// Carries the whole challenge, not just its id: the approval screen needs
    /// the number-match digits, and they arrive on the same push payload.
    case openMfaApproval(MfaChallenge)
    /// A `mailto:` link, already reduced to plain-text compose fields.
    case composeMail(ComposeDraft)
}

struct DeepLinkHandler: Sendable {
    /// Nonisolated so `DeepLinkHandler()` can appear as a default argument
    /// (evaluated in a nonisolated context) without an isolation hop.
    nonisolated init() {}

    /// Maps an incoming URL to a navigation action; nil for unrecognized URLs.
    func handle(_ url: URL) -> NavigationAction? {
        if let params = try? PairingLinkParser.parse(url) {
            return .openPairingFlow(params)
        }
        if let params = try? DesktopPairingLinkParser.parse(url) {
            return .openDesktopPairingFlow(params)
        }
        if let draft = MailtoLinkParser.parse(url) {
            return .composeMail(draft)
        }
        return nil
    }
}
