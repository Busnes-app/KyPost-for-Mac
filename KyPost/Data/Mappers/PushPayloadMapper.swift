//
//  PushPayloadMapper.swift
//  KyPost
//
//  Maps APNs userInfo dictionaries to domain payloads (spec §3, §5).
//  Binding contract with Android — exact keys: messageId, senderName,
//  emailSubject, Keywords (capital K); MFA: type == "mfa_challenge",
//  challengeId.
//

import Foundation

/// An email arrival announced via push; becomes a PushNotification history
/// entry once a seq is assigned (push mode has no server seq).
struct MailPushPayload: Equatable, Sendable {
    var messageId: String
    var senderName: String
    var emailSubject: String
    var keywords: [String]

    static let maxMessageIdLength = 256
    static let maxHeaderLength = 512
    static let maxKeywords = 32
    static let maxKeywordLength = 64

    /// The one place relay-supplied strings get bounded, for every delivery
    /// path: the APNs userInfo (`PushPayloadMapper.map`) and the pull queue
    /// (`PullNotificationDTO.routed`). Both write to the same history table,
    /// so an unbounded path is the one a hostile relay would pick. Bounds
    /// match Android's `PushPayloadParser.sanitize`.
    func sanitized() -> MailPushPayload {
        MailPushPayload(
            messageId: String(messageId.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxMessageIdLength)),
            senderName: String(senderName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxHeaderLength)),
            emailSubject: String(emailSubject.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxHeaderLength)),
            keywords: Array(
                keywords.lazy
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0.count <= Self.maxKeywordLength }
                    .prefix(Self.maxKeywords)
            )
        )
    }

    func toNotification(seq: Int, receivedAt: Date) -> PushNotification {
        PushNotification(
            seq: seq,
            messageId: messageId,
            senderName: senderName,
            emailSubject: emailSubject,
            keywords: keywords,
            receivedAt: receivedAt,
            read: false
        )
    }
}

enum PushPayload: Equatable, Sendable {
    case mail(MailPushPayload)
    case mfaChallenge(MfaChallenge)
}

enum PushPayloadMapper {
    /// Returns nil for payloads that are neither a mail arrival nor an MFA
    /// challenge (missing required keys).
    static func map(userInfo: [AnyHashable: Any], receivedAt: Date = Date()) -> PushPayload? {
        if userInfo["type"] as? String == MfaChallenge.payloadType {
            guard let challengeId = userInfo["challengeId"] as? String, !challengeId.isEmpty else {
                return nil
            }
            return .mfaChallenge(MfaChallenge(
                challengeId: challengeId,
                receivedAt: receivedAt,
                matchDigits: matchDigits(from: userInfo["matchDigits"]),
                decoyDigits: decoyDigits(from: userInfo["decoyDigits"])
            ))
        }

        guard let messageId = userInfo["messageId"] as? String, !messageId.isEmpty else {
            return nil
        }
        let payload = MailPushPayload(
            messageId: messageId,
            senderName: userInfo["senderName"] as? String ?? "",
            emailSubject: userInfo["emailSubject"] as? String ?? "",
            keywords: keywords(from: userInfo["Keywords"])
        ).sanitized()
        return payload.messageId.isEmpty ? nil : .mail(payload)
    }

    /// Only well-formed digit runs survive: these drive tap targets on a
    /// security screen, so neither the server nor anyone who can reach the push
    /// channel gets to put arbitrary text on a button. A malformed value is
    /// treated as absent, which leaves the screen with no way to approve.
    ///
    /// Width is validated as a range, not against a literal 2 — see
    /// `MfaChallenge.matchDigitsLengthRange`. Whether the widths in one
    /// challenge agree with each other is `MfaNumberMatch.options`' decision,
    /// not this one's.
    private static func matchDigits(from value: Any?) -> String {
        guard let raw = value as? String else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // `isValidMatchDigits` is ASCII-only: `isNumber` alone also accepts
        // other Unicode numerals, and a tile reading "٤٧" would never match
        // what the browser displays.
        return MfaChallenge.isValidMatchDigits(trimmed) ? trimmed : ""
    }

    /// Comma-joined by the backend, same as Keywords — APNs data values are strings.
    private static func decoyDigits(from value: Any?) -> [String] {
        guard let joined = value as? String else { return [] }
        var seen: [String] = []
        for part in joined.split(separator: ",") {
            let candidate = matchDigits(from: String(part))
            if !candidate.isEmpty && !seen.contains(candidate) {
                seen.append(candidate)
            }
        }
        return seen
    }

    /// APNs data values are strings, so the backend sends Keywords
    /// comma-joined; local (pull-mode) notifications carry a real array.
    private static func keywords(from value: Any?) -> [String] {
        if let array = value as? [String] {
            return array
        }
        if let joined = value as? String {
            return joined.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}
