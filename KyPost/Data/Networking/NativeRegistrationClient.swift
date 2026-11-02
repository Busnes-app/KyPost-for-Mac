//
//  NativeRegistrationClient.swift
//  KyPost
//
//  Registers this device's push token with the backend (spec §3).
//  The /register endpoint is provider agnostic: the raw APNs device token is
//  sent directly, no FCM bridging required.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct RegistrationResponse: Decodable, Equatable, Sendable {
    enum DeliveryMode: String, Decodable, Sendable {
        case push
        case pull

        /// Lenient wire read for the pull response: anything that is not an
        /// explicit "pull" is push, the safe default (matches Android's
        /// `DeliveryMode.fromWire`). Nil only for a missing value.
        static func wire(_ value: String) -> DeliveryMode? {
            let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty else { return nil }
            return trimmed == "pull" ? .pull : .push
        }
    }

    var ok: Bool
    var synced: Bool?
    var deviceId: String?
    /// The raw per-device pairing secret, minted fresh on every successful
    /// registration and returned only in this response — never retrievable
    /// again afterward. Callers must persist it unconditionally, overwriting
    /// any prior value (see DeviceRegistrationService.performPair).
    var deviceSecret: String?
    var deliveryMode: DeliveryMode?
    /// Optional; derived as {srv}/api/notifications/native/pull if absent (spec §3).
    var pullEndpoint: String?
    /// The 202 pending answer's fields (KyPost-Server `docs/device-approval.md`);
    /// absent from a 200.
    var approvalCode: String?
    var expiresAt: String?
    var statusEndpoint: String?
    var pollIntervalSeconds: Int?

    func resolvedPullEndpoint(srv: String) -> URL? {
        if let pullEndpoint, !pullEndpoint.isEmpty {
            return URL(string: pullEndpoint)
        }
        return URL(string: srv)?.appending(path: "api/notifications/native/pull")
    }
}

/// A device the server created **pending** (202 from `native/register`): its
/// credentials work for `native/pairing-status` and nothing else until the
/// user approves it on the web page that showed the code. Held in memory by
/// `DeviceRegistrationService` only; never written to the Keychain.
struct PendingRegistration: Equatable, Sendable {
    var auth: RelayAuth
    var approvalCode: String
    var expiresAt: Date?
    var statusEndpoint: URL
    var pollInterval: Duration

    /// Nil when the 202 lacks what polling needs (id, secret, code).
    init?(_ response: RegistrationResponse, params: PairingParams) {
        guard let deviceId = response.deviceId, !deviceId.isEmpty,
              let secret = response.deviceSecret, !secret.isEmpty,
              let code = response.approvalCode, !code.isEmpty,
              let statusEndpoint = Self.statusEndpoint(response.statusEndpoint, srv: params.srv)
        else { return nil }
        auth = RelayAuth(deviceId: deviceId, deviceSecret: secret)
        approvalCode = code
        expiresAt = response.expiresAt.flatMap(Self.parseDate)
        self.statusEndpoint = statusEndpoint
        // The contract says 3 s. Clamped so a relay cannot set a hot loop
        // or a poll so slow the user gives up before it sees the approval.
        pollInterval = .seconds(min(max(response.pollIntervalSeconds ?? 3, 1), 30))
    }

    /// The server's `statusEndpoint` only when it is same-origin with the
    /// paired server: the pending secret goes to the relay and nowhere else.
    /// Otherwise `srv` + `/api/notifications/native/pairing-status`.
    static func statusEndpoint(_ advertised: String?, srv: String) -> URL? {
        let derived = URL(string: srv)?.appending(path: "api/notifications/native/pairing-status")
        guard let advertised, let url = URL(string: advertised), let derived else { return derived }
        let sameOrigin = url.scheme?.lowercased() == "https"
            && url.scheme?.lowercased() == derived.scheme?.lowercased()
            && url.host()?.lowercased() == derived.host()?.lowercased()
            && url.port == derived.port
            && url.user == nil
        return sameOrigin ? url : derived
    }

    private static func parseDate(_ raw: String) -> Date? {
        (try? Date(raw, strategy: .iso8601))
            ?? (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}

/// What the pending screen shows: no credentials, only what the user
/// compares and where the request went.
struct PendingApproval: Equatable, Sendable {
    /// The six digits the web prompt shows too.
    var approvalCode: String
    /// The relay host the device is waiting on.
    var server: String

    /// "048213" as "048 213", the way the web page groups it.
    var groupedCode: String {
        guard approvalCode.count == 6 else { return approvalCode }
        return "\(approvalCode.prefix(3)) \(approvalCode.suffix(3))"
    }
}

/// One answer from `native/pairing-status`.
enum PairingStatusOutcome: Equatable, Sendable {
    /// 202: keep polling.
    case pending
    /// 200: paired. Carries `deviceId`, `deliveryMode` and `pullEndpoint`;
    /// the secret is the one the 202 handed over.
    case approved(RegistrationResponse)
    /// 410 (denied, expired or unknown) or 401/403: final.
    case rejected
    /// Transient (transport, 429, 5xx, unreadable body): back off and poll
    /// again. `retryAfter` is the server's `Retry-After`, when it sent one.
    case retry(retryAfter: Int?)
}

/// Registration result mapped to the spec §3 handling rules.
enum RegistrationOutcome: Equatable, Sendable {
    case success(RegistrationResponse)
    /// 202 from `native/register`: the client's answer, carrying the pending
    /// credentials. `DeviceRegistrationService` keeps those and never passes
    /// this case on.
    case approvalRequired(PendingRegistration)
    /// What `DeviceRegistrationService.pair` returns for a 202: the screen
    /// shows the code and calls `awaitApproval`.
    case awaitingApproval(PendingApproval)
    /// The pending device was denied, expired, or the wait was cancelled.
    /// The pending credentials are already gone.
    case notApproved
    /// 401/403 — show error, prompt re-scan.
    case unauthorized
    /// 503 — persistent error, backend config issue, cannot retry.
    case backendMisconfigured
    case failure(String)
}

final class NativeRegistrationClient: Sendable {
    private struct RegisterRequest: Encodable {
        // Binding contract (backend nativeRegisterRequest in server.go):
        // subscriberId, pairingToken, and deviceToken are required (400 if
        // missing); platform, deviceName, and deviceId are optional.
        // deviceName is what the server's paired-device list displays —
        // without it the UI falls back to platform, and unknown platforms
        // normalize to "android". deviceId makes the server update the
        // existing device row instead of appending a duplicate; omitted on
        // first pairing (the server mints one).
        var subscriberId: String
        var pairingToken: String
        var deviceToken: String
        var deviceId: String?
        var platform: String
        var deviceName: String
        /// Shown in the web approval prompt (device-approval contract).
        var osVersion: String
    }

    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    /// Registers a push token. Called on first launch, token refresh, pairing
    /// success, and app foreground (spec §3). Pass the stored deviceId when
    /// re-registering so the server updates that device instead of adding one.
    func register(
        deviceToken: String,
        params: PairingParams,
        deviceId: String? = nil
    ) async -> RegistrationOutcome {
        guard let endpoint = params.registrationEndpoint else {
            return .failure("Invalid registration URL")
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionNumber = "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
#if os(macOS)
        let platform = "macos"
        let deviceName = Host.current().localizedName ?? "Mac"
        let osVersion = "macOS \(versionNumber)"
#else
        let platform = "ios"
        // Without the user-assigned-device-name entitlement this is the
        // generic model name ("iPhone"), which still beats the platform
        // fallback the server shows otherwise.
        let deviceName = await MainActor.run { UIDevice.current.name }
        let osVersion = await MainActor.run { UIDevice.current.systemName } + " \(versionNumber)"
#endif
        do {
            // No header-based auth on this endpoint — the backend has never
            // read one here, only the pairingToken in the body below, and a
            // device has no deviceSecret yet at register time anyway (that's
            // the whole point of this call).
            let (status, response) = try await httpClient.postWithStatus(
                RegistrationResponse.self,
                url: endpoint,
                jsonBody: RegisterRequest(
                    subscriberId: params.sub,
                    pairingToken: params.pt,
                    deviceToken: deviceToken,
                    deviceId: deviceId,
                    platform: platform,
                    deviceName: deviceName,
                    osVersion: osVersion
                )
            )
            // 202 is a pending device, not a pairing: its secret works only
            // for the status endpoint. Before 0.6.0 every 2xx decoded as
            // success, so the status code decides, never the body.
            guard status == 202 else { return .success(response) }
            guard let pending = PendingRegistration(response, params: params) else {
                return .failure(String(localized: "The server asked to approve this device but sent no approval code. Nothing was saved."))
            }
            return .approvalRequired(pending)
        } catch NetworkError.unauthorized {
            return .unauthorized
        } catch NetworkError.serviceUnavailable {
            return .backendMisconfigured
        } catch NetworkError.conflict(let body) {
            // The 409 body is relay-supplied text; the other clients already
            // peel this off rather than render it verbatim in app chrome. Only
            // the phrases the device-approval contract names are recognised.
            return .failure(Self.conflictMessage(body))
        } catch let error as NetworkError {
            // "\(error)" resolves through String(describing:), which never
            // consults LocalizedError — so certificateMismatch printed as the
            // bare case name and its "the connection may be intercepted"
            // warning never reached the user.
            return .failure(MailOutcome.message(for: error))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func conflictMessage(_ body: String) -> String {
        let text = body.lowercased()
        if text.contains("pairing token already used") {
            return String(localized: "This code was already used. If you did not use it, deny the request on the web page.")
        }
        if text.contains("already waiting for approval") {
            return String(localized: "This device is already waiting for approval. Approve it on the web page, or wait five minutes and scan a new code.")
        }
        if text.contains("too many devices are waiting for approval") {
            return String(localized: "Too many devices are waiting for approval. Approve or deny them on the web page, then scan a new code.")
        }
        return String(localized: "The server rejected this pairing request.")
    }

    /// One poll of `native/pairing-status` with the pending credentials.
    func pairingStatus(_ pending: PendingRegistration) async -> PairingStatusOutcome {
        do {
            let (status, response) = try await httpClient.getWithStatus(
                RegistrationResponse.self,
                url: pending.statusEndpoint,
                headers: pending.auth.headerFields
            )
            return status == 200 ? .approved(response) : .pending
        } catch NetworkError.server(statusCode: 410), NetworkError.unauthorized {
            return .rejected
        } catch NetworkError.rateLimited(let retryAfter) {
            return .retry(retryAfter: retryAfter)
        } catch {
            return .retry(retryAfter: nil)
        }
    }
}
