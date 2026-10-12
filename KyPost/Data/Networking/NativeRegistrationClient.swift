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

    func resolvedPullEndpoint(srv: String) -> URL? {
        if let pullEndpoint, !pullEndpoint.isEmpty {
            return URL(string: pullEndpoint)
        }
        return URL(string: srv)?.appending(path: "api/notifications/native/pull")
    }
}

/// Registration result mapped to the spec §3 handling rules.
enum RegistrationOutcome: Equatable, Sendable {
    case success(RegistrationResponse)
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
#if os(macOS)
        let platform = "macos"
        let deviceName = Host.current().localizedName ?? "Mac"
#else
        let platform = "ios"
        // Without the user-assigned-device-name entitlement this is the
        // generic model name ("iPhone"), which still beats the platform
        // fallback the server shows otherwise.
        let deviceName = await MainActor.run { UIDevice.current.name }
#endif
        do {
            // No header-based auth on this endpoint — the backend has never
            // read one here, only the pairingToken in the body below, and a
            // device has no deviceSecret yet at register time anyway (that's
            // the whole point of this call).
            let response = try await httpClient.post(
                RegistrationResponse.self,
                url: endpoint,
                jsonBody: RegisterRequest(
                    subscriberId: params.sub,
                    pairingToken: params.pt,
                    deviceToken: deviceToken,
                    deviceId: deviceId,
                    platform: platform,
                    deviceName: deviceName
                )
            )
            return .success(response)
        } catch NetworkError.unauthorized {
            return .unauthorized
        } catch NetworkError.serviceUnavailable {
            return .backendMisconfigured
        } catch NetworkError.conflict {
            // The 409 body is relay-supplied text; the other clients already
            // peel this off rather than render it verbatim in app chrome.
            return .failure(String(localized: "The server rejected this pairing request."))
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
}
