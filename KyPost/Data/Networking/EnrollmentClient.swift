//
//  EnrollmentClient.swift
//  KyPost
//
//  The three device-authenticated enrollment calls. Swift port of
//  kypost-android's pgp/EnrollmentClients.kt.
//

import Foundation
import os

private struct PublishEnrollmentKeyRequest: Encodable {
    var publicKey: String
    /// Omitting the list resets the server's claim to `[2]`, and the browser
    /// then refuses to seal v3.
    var envelopeVersions: [Int]
}

/// The three metadata fields go together: absent for the legacy boolean, all
/// present for a keyring acknowledgement. The server answers 400 to any other
/// combination. Optionals encode as absent, never as null.
private struct EnrollmentStateRequest: Encodable {
    var encryptionEnrolled: Bool
    var envelopeVersion: Int?
    var materialGeneration: UInt64?
    var fingerprint: String?

    init(_ report: EnrollmentReport) {
        switch report {
        case .notEnrolled:
            encryptionEnrolled = false
        case .legacy:
            encryptionEnrolled = true
        case let .keyring(generation, fingerprint):
            encryptionEnrolled = true
            envelopeVersion = envelopeVersionKeyring
            materialGeneration = generation
            self.fingerprint = fingerprint
        }
    }
}

private struct KeyringStateDTO: Decodable {
    var primaryFingerprints: [String]?
    var keyFingerprints: [String]?
}

/// Every field beside `envelope` arrived with KyPost-Server #210 and is absent
/// from older servers, hence `decodeIfPresent` throughout.
private struct DeviceEnvelopeResponse: Decodable {
    var envelope: String?
    var version: Int?
    var fingerprint: String?
    var materialGeneration: UInt64?
    var keyring: KeyringStateDTO?

    private enum CodingKeys: String, CodingKey {
        case envelope, version, fingerprint, materialGeneration, keyring
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        envelope = try container.decodeIfPresent(String.self, forKey: .envelope)
        version = try? container.decodeIfPresent(Int.self, forKey: .version)
        fingerprint = try? container.decodeIfPresent(String.self, forKey: .fingerprint)
        materialGeneration = try? container.decodeIfPresent(UInt64.self, forKey: .materialGeneration)
        keyring = try? container.decodeIfPresent(KeyringStateDTO.self, forKey: .keyring)
    }

    var delivery: DeliveryMetadata? {
        guard let version, let fingerprint else { return nil }
        return DeliveryMetadata(
            version: version,
            fingerprint: fingerprint,
            materialGeneration: materialGeneration,
            primaryFingerprints: keyring?.primaryFingerprints,
            keyFingerprints: keyring?.keyFingerprints
        )
    }
}

/// Talks to `/api/pgp/device/{enrollment-key,envelope,enrollment-state}`.
///
/// Every URL is built from the **paired origin**, never from a server-supplied
/// one — the same rule the PGP QR path follows, and for the same reason: a
/// tampered response must not be able to point an authenticated call at another
/// host, outside the TLS pin.
struct EnrollmentClient: EnrollmentTransport {
    private let httpClient: HTTPClient
    private let bootstrapClient: PgpSendClient
    private let serverUrl: String
    private let auth: RelayAuth

    init(
        httpClient: HTTPClient,
        bootstrapClient: PgpSendClient,
        serverUrl: String,
        auth: RelayAuth
    ) {
        self.httpClient = httpClient
        self.bootstrapClient = bootstrapClient
        self.serverUrl = serverUrl
        self.auth = auth
    }

    /// The account's fingerprint, computed locally from bootstrap's public key
    /// bytes.
    ///
    /// **Hashed here rather than read from the response's `fingerprint`
    /// field**, which is a claim beside the key with no cryptographic tie to
    /// it. The same rule the QR exchange follows: a fingerprint that binds an
    /// envelope must describe the key material actually in hand.
    func identityFingerprint() async -> String? {
        guard let response = try? await bootstrapClient.fetchBootstrap(
            serverUrl: serverUrl,
            auth: auth
        ) else { return nil }
        guard response.hasIdentity == true,
              let publicKey = response.publicKey, !publicKey.isEmpty
        else { return nil }
        return PgpFingerprint.compute(fromArmored: publicKey)
    }

    func publish(publicKey: Data) async -> EnrollmentPublishResult {
        do {
            _ = try await httpClient.post(
                RelayActionResponse.self,
                url: try endpoint("api/pgp/device/enrollment-key"),
                headers: auth.headerFields,
                jsonBody: PublishEnrollmentKeyRequest(
                    publicKey: publicKey.base64EncodedString(),
                    envelopeVersions: supportedEnvelopeVersions
                )
            )
            return .ok
        } catch NetworkError.unauthorized {
            return .unauthorized
        } catch NetworkError.badRequest(let body) {
            return .rejected(body.isEmpty ? "The server refused this device's key." : body)
        } catch NetworkError.conflict(let body) {
            return .rejected(body.isEmpty ? "This device is already enrolled." : body)
        } catch {
            return .failed(MailOutcome.message(for: networkError(error)))
        }
    }

    /// No slot parameter: the server builds it from the verified credential.
    func fetchEnvelope() async -> EnrollmentEnvelopeResult {
        do {
            let response = try await httpClient.get(
                DeviceEnvelopeResponse.self,
                url: try endpoint("api/pgp/device/envelope"),
                headers: auth.headerFields
            )
            guard let envelope = response.envelope, !envelope.isEmpty else {
                return .failed("The server sent an envelope this app couldn't read.")
            }
            return .sealed(envelope, delivery: response.delivery)
        } catch NetworkError.unauthorized {
            return .unauthorized
        } catch NetworkError.server(statusCode: 404) {
            // 404 covers "never sealed" and "expired" alike — indistinguishable
            // by design, and both mean keep waiting or re-run.
            return .notSealed
        } catch {
            return .failed(MailOutcome.message(for: networkError(error)))
        }
    }

    /// Always written explicitly: this route requires the field, so an absent
    /// value is a 400 rather than "no opinion".
    func report(_ report: EnrollmentReport) async -> EnrollmentReportResult {
        do {
            _ = try await httpClient.post(
                RelayActionResponse.self,
                url: try endpoint("api/pgp/device/enrollment-state"),
                headers: auth.headerFields,
                jsonBody: EnrollmentStateRequest(report)
            )
            return .ok
        } catch NetworkError.conflict {
            return .conflict
        } catch NetworkError.unauthorized {
            return .unauthorized
        } catch NetworkError.server(statusCode: 404) {
            return .notFound
        } catch {
            Log.app.error("Reporting enrollment state failed: \(error.localizedDescription)")
            return .failed(MailOutcome.message(for: networkError(error)))
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: serverUrl) else {
            throw MailSourceError.invalidServerURL
        }
        return url.appending(path: path)
    }

    private func networkError(_ error: Error) -> NetworkError {
        (error as? NetworkError) ?? .transport(description: error.localizedDescription)
    }
}
