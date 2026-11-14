//
//  RsvpTracker.swift
//  KyPost
//
//  RSVP progress per invite revision, outliving any one screen. Port of
//  kypost-android's mail/RsvpTracker.kt.
//
//  A send finishes on whichever screen is current, and screens derive their
//  buttons from `phases`, so closing the reader mid-send can neither
//  double-send nor lose the outcome. Keyed by `rsvpKey` (UID + RECURRENCE-ID +
//  SEQUENCE): a raised SEQUENCE is a new invite to answer.
//
//  **Session-bound.** `session` advances, and every phase and message is
//  dropped, on `.kyPostSessionReset` (security wipe, failed-unlock reset,
//  unpair). A send confirmed under an ended session does no I/O, and a
//  completion from one records nothing and says nothing.
//
//  It also remembers which revision of each event was answered, so a newer
//  REQUEST can say what changed (KyPost-Server docs/NATIVE-RSVP.md
//  "Updates"). Digests only, in memory only, dropped with the session.
//

import CryptoKit
import Foundation
import Observation

nonisolated enum RsvpPhase: Equatable, Sendable {
    case pending, sent, unsure
}

nonisolated enum RsvpResult: Equatable, Sendable {
    /// The relay answered `"calendarReply": true`: an RSVP went out.
    case sent
    /// A 200 without the acknowledgement: a relay that ignored the field, so
    /// the organizer got only the plain body. Never retried, never counted.
    case sentAsPlainMail
    /// The relay answered and refused: nothing went out.
    case refused
    /// A timeout, a 5xx, an unreadable answer: it may have been sent.
    case maybeSent
}

nonisolated enum InviteChange: String, Sendable {
    case time, place, title
}

/// What the user answered for an earlier revision of this event.
nonisolated enum PriorAnswer: Equatable, Sendable {
    case unanswered
    /// This revision, or a later one, was answered.
    case same(Rsvp)
    /// A newer revision than the one answered: higher SEQUENCE, or the same
    /// SEQUENCE with a later DTSTAMP.
    case newer(Rsvp, changed: [InviteChange])
}

@Observable
@MainActor
final class RsvpTracker {
    private struct AnswerRecord {
        var sequence: Int
        var stamp: Date?
        var when: SHA256.Digest
        var title: SHA256.Digest
        var place: SHA256.Digest
        var answer: Rsvp
    }
    static let shared = RsvpTracker()

    private(set) var phases: [String: RsvpPhase] = [:]
    /// The last outcome sentence per key, for whichever screen shows it.
    private(set) var messages: [String: String] = [:]
    /// The current session. Captured when a send is confirmed.
    private(set) var session = 0

    @ObservationIgnored private var answers: [SHA256.Digest: AnswerRecord] = [:]
    @ObservationIgnored private var resetObservation: NotificationObservation?

    init(center: NotificationCenter = .default) {
        resetObservation = NotificationObservation(center: center, name: .kyPostSessionReset) { [weak self] in
            self?.endSession()
        }
    }

    /// False when `key` already has a send pending, sent, or unsure.
    func begin(_ key: String) -> Bool {
        guard phases[key] == nil else { return false }
        phases[key] = .pending
        messages[key] = nil
        return true
    }

    /// Releases a send the user backed out of before it left.
    func cancel(_ key: String) {
        if phases[key] == .pending { phases[key] = nil }
    }

    /// Only a definite refusal frees the key; anything else may already have
    /// gone out.
    func finish(_ key: String, result: RsvpResult) {
        switch result {
        case .sent: phases[key] = .sent
        case .refused: phases[key] = nil
        case .sentAsPlainMail, .maybeSent: phases[key] = .unsure
        }
    }

    /// A fresh open of the invite is the user's deliberate retry of an
    /// unsure send (Android's rule): the buttons re-arm, but the outcome
    /// sentence stays, so the retry is made beside "may have been sent" or
    /// "the organizer got a plain email" — and still goes through the
    /// confirmation. A confirmed RSVP stays sent.
    func opened(_ key: String, freshOpen: Bool) {
        if freshOpen, phases[key] == .unsure {
            phases[key] = nil
        }
    }

    func isCurrent(_ session: Int) -> Bool { session == self.session }

    /// `finish` for a send started in `session`, with its sentence. False,
    /// recording nothing, once that session has ended — so a reset tracker
    /// is not repopulated and the caller shows no feedback.
    @discardableResult
    func complete(_ key: String, result: RsvpResult, message: String? = nil, session: Int) -> Bool {
        guard isCurrent(session) else { return false }
        finish(key, result: result)
        messages[key] = message
        return true
    }

    func canAnswer(_ key: String) -> Bool { phases[key] == nil }

    /// Remembers that this revision was answered, for a session still current.
    func recordAnswer(_ event: CalendarEvent, _ answer: Rsvp, session: Int) {
        guard isCurrent(session) else { return }
        let f = Self.fingerprint(event)
        answers[f.key] = AnswerRecord(
            sequence: event.sequence, stamp: event.stamp, when: f.when, title: f.title, place: f.place, answer: answer
        )
    }

    func priorAnswer(_ event: CalendarEvent) -> PriorAnswer {
        let f = Self.fingerprint(event)
        guard event.canReply, let record = answers[f.key] else { return .unanswered }
        let newer = event.sequence > record.sequence
            || (event.sequence == record.sequence
                && (event.stamp ?? .distantPast) > (record.stamp ?? .distantPast))
        guard newer else { return .same(record.answer) }
        var changed: [InviteChange] = []
        if record.when != f.when { changed.append(.time) }
        if record.place != f.place { changed.append(.place) }
        if record.title != f.title { changed.append(.title) }
        return .newer(record.answer, changed: changed)
    }

    private static func fingerprint(_ e: CalendarEvent)
        -> (key: SHA256.Digest, when: SHA256.Digest, title: SHA256.Digest, place: SHA256.Digest) {
        func digest(_ value: String) -> SHA256.Digest { SHA256.hash(data: Data(value.utf8)) }
        return (
            digest("\(e.organizer.lowercased())\u{0}\(e.uid)"),
            digest("\(e.begin.timeIntervalSince1970)|\(e.end.timeIntervalSince1970)|\(e.allDay)"),
            digest(e.summary),
            digest(e.location)
        )
    }

    func clear() {
        phases = [:]
        messages = [:]
        answers = [:]
    }

    /// The session boundary: advance first, so work racing the reset already
    /// reads as expired, then drop everything.
    func endSession() {
        session += 1
        clear()
    }
}
