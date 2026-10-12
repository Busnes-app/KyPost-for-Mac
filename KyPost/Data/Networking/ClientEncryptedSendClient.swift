//
//  ClientEncryptedSendClient.swift
//  KyPost
//
//  POST {srv}/api/mail/send-pgp — the client-custody send. This device already
//  encrypted and signed; the relay only forwards the bytes.
//
//  Swift port of the sendClientEncrypted half of kypost-android's
//  RelayMailSource.
//

import Foundation

private struct RelayDeliveryDTO: Encodable {
    var recipients: [String]
    var ciphertext: String
}

private struct RelayClientEncryptedRequest: Encodable {
    var from: String
    var subject: String
    var mode: String
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var deliveries: [RelayDeliveryDTO]
    var sentCopy: String
    var sentCopyEncrypted: Bool
    /// Omitted when nil (synthesised `encodeIfPresent`): a legacy account must
    /// not see a made-up generation.
    var materialGeneration: UInt64?
}

/// The two converted-account refusals of KyPost-Server #210, told apart by
/// JSON field — never by the prose, which is user-facing copy and may change.
private struct GenerationConflictBody: Decodable {
    var reenrollmentRequired: Bool?
    var pgpStateChanged: Bool?
}

final class ClientEncryptedSendClient: ClientEncryptedTransport {
    private let httpClient: HTTPClient
    private let serverUrl: String
    private let auth: RelayAuth

    init(httpClient: HTTPClient, serverUrl: String, auth: RelayAuth) {
        self.httpClient = httpClient
        self.serverUrl = serverUrl
        self.auth = auth
    }

    func send(_ message: ClientEncryptedMessage) async -> Result<ClientSendResult, MailSendFailure> {
        guard let base = URL(string: serverUrl) else {
            return .failure(MailSendFailure(message: "the server address is not a valid URL"))
        }

        // `subject` and `sentCopyEncrypted` are fixed here rather than taken
        // from the caller. The subject is the placeholder because the real one
        // travels inside the ciphertext; the flag is true because `sentCopy`
        // is *defined* to be ciphertext, and a copy that does not claim it is
        // silently dropped server-side.
        let request = RelayClientEncryptedRequest(
            from: message.from,
            subject: outerPlaceholderSubject,
            mode: message.mode,
            to: message.to,
            cc: message.cc,
            bcc: message.bcc,
            deliveries: message.deliveries.map {
                RelayDeliveryDTO(recipients: $0.recipients, ciphertext: $0.ciphertext)
            },
            sentCopy: message.sentCopy,
            sentCopyEncrypted: true,
            materialGeneration: message.materialGeneration
        )

        do {
            let response = try await httpClient.post(
                RelaySendResponse.self,
                url: base.appending(path: "api/mail/send-pgp"),
                headers: auth.headerFields,
                jsonBody: request
            )
            return .success(ClientSendResult(
                sentSaved: response.sentSaved ?? false,
                warning: response.warning ?? ""
            ))
        } catch {
            return .failure(MailSendFailure(message: Self.message(for: error), kind: Self.kind(for: error)))
        }
    }

    /// `reenrollmentRequired` is checked first: it is the more specific of the
    /// two, and the server never sets both.
    static func kind(for error: Error) -> MailSendFailure.Kind {
        guard case let NetworkError.conflict(body) = error,
              let parsed = try? JSONDecoder().decode(GenerationConflictBody.self, from: Data(body.utf8))
        else { return .other }
        if parsed.reenrollmentRequired == true { return .reenrollmentRequired }
        if parsed.pgpStateChanged == true { return .pgpStateChanged }
        return .other
    }

    /// Sentences rather than a forwarded status code.
    ///
    /// 403 is the one worth naming: the relay compares every delivery's own
    /// `From` header against the account address and refuses a mismatch, so it
    /// means the composed envelope disagreed with bootstrap — not that the
    /// user lacks permission.
    static func message(for error: Error) -> String {
        switch error {
        case NetworkError.unauthorized:
            "this device is no longer paired"
        case NetworkError.server(statusCode: 403):
            "the server refused this message's sender address"
        case NetworkError.conflict:
            "this account is not set up for on-device encryption"
        case NetworkError.server(statusCode: 413), NetworkError.responseTooLarge:
            "this message is too large to send"
        case let NetworkError.badRequest(body):
            body.isEmpty ? "the server refused this message" : body
        case NetworkError.serviceUnavailable:
            "the server is unavailable"
        case let NetworkError.transport(description):
            description
        default:
            "this message could not be sent"
        }
    }
}
