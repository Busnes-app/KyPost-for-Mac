//
//  PushNotificationClient.swift
//  KyPost
//
//  Pull-mode notification polling (spec §3) and the push-mode heartbeat.
//  Items carry a strictly-increasing seq used for de-duplication.
//
//  Wire shape is the server's `state.PullNotification`:
//  `{ seq, title, body, data: {string: string}, createdAt }`, with the mail
//  fields (messageId, senderName/sender, emailSubject/subject, Keywords) or
//  the MFA fields (type, challengeId, matchDigits, decoyDigits) inside `data`.
//  The top-level messageId/senderName/emailSubject/Keywords shape this client
//  was first written against is still accepted, but no current server sends
//  it — requiring it made every non-empty pull a decode failure.
//

import Foundation

struct PullResponse: Decodable, Equatable, Sendable {
    var notifications: [PullNotificationDTO]
    /// Updated cursor position; persist via NotificationCursorStore.advance
    /// only after notifications are handed off.
    var cursor: Int
    /// The server's delivery mode for this account. Authoritative: the server
    /// never flips it on its own, but an admin can.
    var deliveryMode: String?

    private enum CodingKeys: String, CodingKey {
        case notifications, cursor, deliveryMode
    }

    init(notifications: [PullNotificationDTO], cursor: Int, deliveryMode: String? = nil) {
        self.notifications = notifications
        self.cursor = cursor
        self.deliveryMode = deliveryMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notifications = try container.decodeIfPresent([PullNotificationDTO].self, forKey: .notifications) ?? []
        cursor = try container.decodeIfPresent(Int.self, forKey: .cursor) ?? 0
        deliveryMode = try container.decodeIfPresent(String.self, forKey: .deliveryMode)
    }
}

struct PullNotificationDTO: Decodable, Equatable, Sendable {
    var seq: Int
    var title: String?
    var body: String?
    var data: [String: String]?
    var createdAt: String?
    // Legacy top-level fields.
    var messageId: String?
    var senderName: String?
    var emailSubject: String?
    var keywords: [String]?

    private enum CodingKeys: String, CodingKey {
        case seq, title, body, data, createdAt
        case messageId
        case senderName
        case emailSubject
        // Binding contract with Android: capital K.
        case keywords = "Keywords"
    }

    init(
        seq: Int, title: String? = nil, body: String? = nil,
        data: [String: String]? = nil, createdAt: String? = nil
    ) {
        self.seq = seq
        self.title = title
        self.body = body
        self.data = data
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        // A data value that is not a string is dropped, not fatal: one odd
        // field must not fail the batch and stall the cursor behind it.
        let lossy = try? container.decodeIfPresent([String: LossyString].self, forKey: .data)
        data = lossy?.compactMapValues(\.value)
        createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
        messageId = try? container.decodeIfPresent(String.self, forKey: .messageId)
        senderName = try? container.decodeIfPresent(String.self, forKey: .senderName)
        emailSubject = try? container.decodeIfPresent(String.self, forKey: .emailSubject)
        keywords = try? container.decodeIfPresent([String].self, forKey: .keywords)
    }

    /// When the server queued it, if it said. RFC 3339.
    var createdDate: Date? {
        guard let raw = createdAt?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let date = try? Date(raw, strategy: .iso8601) { return date }
        return try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

private struct LossyString: Decodable, Equatable, Sendable {
    var value: String?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(String.self)
    }
}

/// What a pulled entry turned out to be.
enum PulledItem: Equatable, Sendable {
    case mail(PushNotification)
    case mfaChallenge(MfaChallenge, userInfo: [String: String])
}

// MARK: - Mapping (PayloadMapper equivalent)

extension PullNotificationDTO {
    /// MFA first, as on the push path: a challenge misread as mail would show
    /// the sign-in context as a sender and subject with no way to answer it.
    /// Mail synthesizes `pull-<seq>` when the server sent no message id, and
    /// goes through the same bounds as a pushed payload.
    func routed(now: Date = Date()) -> PulledItem? {
        let fields = data ?? [:]
        let receivedAt = createdDate ?? now
        if case .mfaChallenge(let challenge) = PushPayloadMapper.map(userInfo: fields, receivedAt: receivedAt) {
            return .mfaChallenge(challenge, userInfo: fields)
        }
        let id = [fields["messageId"], messageId]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "pull-\(seq)"
        let keywordList: [String]
        if let joined = fields["Keywords"] ?? fields["keywords"] {
            keywordList = joined.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            keywordList = keywords ?? []
        }
        let payload = MailPushPayload(
            messageId: id,
            senderName: firstNonBlank(fields["senderName"], senderName, title, fields["sender"]),
            emailSubject: firstNonBlank(fields["emailSubject"], emailSubject, body, fields["subject"]),
            keywords: keywordList
        ).sanitized()
        return .mail(payload.toNotification(seq: seq, receivedAt: receivedAt))
    }

    private func firstNonBlank(_ values: String?...) -> String {
        values.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }
}

final class PushNotificationClient: Sendable {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    /// GET {pullEndpoint}?after={cursor}, with pairing auth as headers
    func pull(endpoint: URL, auth: RelayAuth, after cursor: Int) async throws -> PullResponse {
        try await httpClient.get(
            PullResponse.self,
            url: endpoint,
            query: [URLQueryItem(name: "after", value: String(cursor))],
            headers: auth.headerFields
        )
    }
}
