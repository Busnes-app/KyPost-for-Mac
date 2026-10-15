//
//  PgpPayloadClient.swift
//  KyPost
//
//  GET {srv}/api/mail/pgp-payload — one client-protected message's OpenPGP
//  material. Swift port of kypost-android's pgp/PgpPayloadClient.kt.
//
//  The three specific status codes map to distinct results rather than one
//  failure, because each is a different row of the reader's exit table and a
//  different sentence to the user. Collapsing them would tell someone whose
//  message is merely too large that the server could not be reached.
//

import Foundation

/// Wire shape. Every field defaults, and the defaults **are** the contract for
/// an older server: each is `omitempty` server-side.
private struct PgpPayloadDTO: Decodable {
    var encryptedPayload: String = ""
    var signaturePayload: String = ""
    var body: String = ""
    var signedPartBase64: String = ""
    var signerKeys: [SignerKeyDTO] = []
    var sender: String = ""
    var resolvedSender: String = ""

    private enum CodingKeys: String, CodingKey {
        case encryptedPayload, signaturePayload, body, signedPartBase64
        case signerKeys, sender, resolvedSender
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        encryptedPayload = try values.decodeIfPresent(String.self, forKey: .encryptedPayload) ?? ""
        signaturePayload = try values.decodeIfPresent(String.self, forKey: .signaturePayload) ?? ""
        body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        signedPartBase64 = try values.decodeIfPresent(String.self, forKey: .signedPartBase64) ?? ""
        signerKeys = try values.decodeIfPresent([SignerKeyDTO].self, forKey: .signerKeys) ?? []
        sender = try values.decodeIfPresent(String.self, forKey: .sender) ?? ""
        resolvedSender = try values.decodeIfPresent(String.self, forKey: .resolvedSender) ?? ""
    }
}

private struct SignerKeyDTO: Decodable {
    var addresses: [String] = []
    var publicKey: String = ""
    var source: String = ""
    /// Can only ever add a warning (`signatureState`). A missing one is the
    /// ordinary case, and nothing reads its absence as reassurance.
    var conflict: Bool = false

    // The relay's `verified` is deliberately not decoded: whether a key is
    // confirmed is decided on this device (`RecipientPinStore`), and a field
    // that is never read cannot be turned into a trust input by a later edit.
    private enum CodingKeys: String, CodingKey {
        case addresses, publicKey, source, conflict
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        addresses = try values.decodeIfPresent([String].self, forKey: .addresses) ?? []
        publicKey = try values.decodeIfPresent(String.self, forKey: .publicKey) ?? ""
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? ""
        conflict = try values.decodeIfPresent(Bool.self, forKey: .conflict) ?? false
    }
}

final class PgpPayloadClient: PgpPayloadSource {
    private let httpClient: HTTPClient
    private let serverUrl: String
    private let auth: RelayAuth

    init(httpClient: HTTPClient, serverUrl: String, auth: RelayAuth) {
        self.httpClient = httpClient
        self.serverUrl = serverUrl
        self.auth = auth
    }

    /// - Returns: a result for every documented outcome. Only an undocumented
    ///   status or a transport error becomes `.failed`.
    func fetch(mailbox: String, messageId: String) async throws -> PgpPayloadResult {
        // `URL(string:).appending(path:)`, matching RelayMailSource.endpoint and
        // every other mail call. The previous URLComponents + NSString path build
        // produced a nil URL for a bare-host `srv` — the stored form has no
        // trailing slash, so `components.path` came out without a leading slash,
        // which is not a valid absolute path when a host is present. That failed
        // every read before the request left the device.
        guard let url = URL(string: serverUrl)?.appending(path: "api/mail/pgp-payload") else {
            return .failed("the server address is not a valid URL")
        }

        do {
            let dto = try await httpClient.get(
                PgpPayloadDTO.self,
                url: url,
                query: [
                    URLQueryItem(name: "mailbox", value: mailbox),
                    // The server reads `messageId` (an IMAP UID) and 400s without
                    // it — see attachmentRequestParams, the same parser every
                    // other mail call hits (RelayMailSource.listAttachments). A
                    // bare `message` reached it as an empty UID and surfaced as
                    // "this message could not be fetched".
                    URLQueryItem(name: "messageId", value: messageId),
                ],
                headers: auth.headerFields
            )
            return .success(PgpPayload(
                encryptedPayload: dto.encryptedPayload,
                signaturePayload: dto.signaturePayload,
                body: dto.body,
                signedPartBase64: dto.signedPartBase64,
                signerKeys: dto.signerKeys.map {
                    SignerKey(
                        addresses: $0.addresses,
                        publicKey: $0.publicKey,
                        source: $0.source,
                        conflict: $0.conflict
                    )
                },
                resolvedSender: dto.resolvedSender,
                rawSender: dto.sender
            ))
        } catch {
            return Self.result(for: error)
        }
    }

    /// Maps transport failures onto the exit table.
    ///
    /// `.conflict` (409) means this account's key is not client-protected —
    /// reaching here at all is a bug, but it gets its own row rather than a
    /// generic failure so the bug is legible when it happens.
    static func result(for error: Error) -> PgpPayloadResult {
        switch error {
        case NetworkError.server(statusCode: 404):
            .noPayload
        case NetworkError.conflict:
            .notClientProtected
        case NetworkError.server(statusCode: 413), NetworkError.responseTooLarge:
            .tooLarge
        case NetworkError.unauthorized:
            .failed("this device is no longer paired")
        case NetworkError.serviceUnavailable:
            .failed("the server is unavailable")
        case let NetworkError.transport(description):
            .failed(description)
        default:
            .failed("this message could not be fetched")
        }
    }
}
