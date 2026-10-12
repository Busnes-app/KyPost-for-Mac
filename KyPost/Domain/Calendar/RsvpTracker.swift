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

@Observable
@MainActor
final class RsvpTracker {
    static let shared = RsvpTracker()

    private(set) var phases: [String: RsvpPhase] = [:]
    /// The last outcome sentence per key, for whichever screen shows it.
    private(set) var messages: [String: String] = [:]
    /// The current session. Captured when a send is confirmed.
    private(set) var session = 0

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
    /// unsure send. A confirmed RSVP stays sent.
    func opened(_ key: String, freshOpen: Bool) {
        if freshOpen, phases[key] == .unsure {
            phases[key] = nil
            messages[key] = nil
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

    func clear() {
        phases = [:]
        messages = [:]
    }

    /// The session boundary: advance first, so work racing the reset already
    /// reads as expired, then drop everything.
    func endSession() {
        session += 1
        clear()
    }
}
