//
//  InviteCardModel.swift
//  KyPost
//
//  The calendar-invite card on the reader: loads and parses the invite,
//  hands it to the calendar on a tap, and runs the RSVP confirm-and-send.
//  Port of kypost-android EmailDetailActivity's invite card (#172, #176).
//
//  RSVP state lives in `RsvpTracker`, not here: this object dies with the
//  screen, and a send started from it must still land somewhere.
//

import Foundation
import Observation

/// An RSVP waiting on its confirmation. Everything it sends is fixed here:
/// the session and account it is bound to are read when the user asked, not
/// when they confirmed.
struct PendingRsvp: Identifiable {
    let id = UUID()
    let key: String
    let event: CalendarEvent
    let answer: Rsvp
    let attendee: String
    let sendAs: String
    let account: MailAccountBinding
    let session: Int
    let message: String
}

/// A calendar handoff, bound to the session the user tapped in. A wipe or
/// unpair ends that session, and the event is then never written.
struct PendingHandoff: Identifiable {
    let id = UUID()
    let event: CalendarEvent
    let session: Int
}

@Observable
@MainActor
final class InviteCardModel {
    private(set) var invite: CalendarInvite?
    private(set) var listedMethod = ""
    /// Drives the RSVP confirmation.
    var pendingRsvp: PendingRsvp?
    /// Drives the Hostile Location Protection confirmation before a handoff.
    var pendingHandoff: PendingHandoff?
    private(set) var isAdding = false
    private(set) var handoffMessage: String?
    /// Said when an RSVP could not even be offered for confirmation.
    private(set) var rsvpProblem: String?

    private let tracker: RsvpTracker
    /// Confirmations answered by a button, so a dismissal racing the button
    /// does not release a revision that is being sent.
    private var settled: Set<UUID> = []
    private let accountAddresses: @MainActor () async -> [String]?
    private let currentAccount: @MainActor () -> MailAccountBinding?
    private let send: @MainActor (CalendarReplyDraft, MailAccountBinding) async -> (result: RsvpResult, reason: String)?
    private let now: () -> Date
    private let calendarStore: @MainActor () -> any CalendarStoring
    private let isLocked: @MainActor () -> Bool

    /// The defaults re-read `SingletonGraph.shared` on every call, so nothing
    /// here outlives a graph rebuild.
    init(
        tracker: RsvpTracker = .shared,
        accountAddresses: @escaping @MainActor () async -> [String]? = {
            await SingletonGraph.shared.pgpSendService.fetchAccountAddresses()
        },
        currentAccount: @escaping @MainActor () -> MailAccountBinding? = {
            SingletonGraph.shared.mailRepository.currentAccount()
        },
        send: @escaping @MainActor (CalendarReplyDraft, MailAccountBinding) async -> (result: RsvpResult, reason: String)? = {
            await SingletonGraph.shared.mailRepository.sendCalendarReply($0, as: $1)
        },
        now: @escaping () -> Date = Date.init,
        calendarStore: @escaping @MainActor () -> any CalendarStoring = { EventKitCalendarStore() },
        isLocked: @escaping @MainActor () -> Bool = { SingletonGraph.shared.appLockManager.isLocked }
    ) {
        self.tracker = tracker
        self.accountAddresses = accountAddresses
        self.currentAccount = currentAccount
        self.send = send
        self.now = now
        self.calendarStore = calendarStore
        self.isLocked = isLocked
    }

    // MARK: - Prompts

    /// What the RSVP alert shows. The card's alerts render above the lock
    /// cover on macOS, so a prompt is presented only while the app is
    /// unlocked and the session it was raised in is still current.
    var presentedRsvp: PendingRsvp? {
        pendingRsvp.flatMap { tracker.isCurrent($0.session) && !isLocked() ? $0 : nil }
    }

    /// What the Hostile Location Protection alert shows; gated like
    /// `presentedRsvp`.
    var presentedHandoff: PendingHandoff? {
        pendingHandoff.flatMap { tracker.isCurrent($0.session) && !isLocked() ? $0 : nil }
    }

    /// The lock engaged: withdraw both prompts. The RSVP revision is
    /// released, so the user asks again after unlocking.
    func lockEngaged() {
        if let pending = pendingRsvp { cancelRsvp(pending) }
        pendingHandoff = nil
    }

    /// Downloads and parses the listed invite part, if there is one. A
    /// refusal, a failed download or a throw only means no card.
    func load(listing: [EmailAttachment], fetch: (EmailAttachment) async -> Data?) async {
        guard let part = inviteAttachment(listing),
              let bytes = await fetch(part),
              let parsed = parseCalendarInvite(bytes, localZone: .current)
        else { return }
        invite = parsed
        listedMethod = part.calendarMethod
        // Opening the invite is the user's deliberate retry of an unsure send.
        tracker.opened(rsvpKey(parsed.primary), freshOpen: true)
    }

    var key: String? { invite.map { rsvpKey($0.primary) } }

    var offersRsvp: Bool { invite?.offersRsvp(listedMethod: listedMethod) ?? false }

    var canAnswer: Bool { key.map(tracker.canAnswer) ?? false }

    /// The last RSVP outcome for this revision, from whichever screen sent it.
    var rsvpMessage: String? { key.flatMap { tracker.messages[$0] } }

    // MARK: - RSVP

    /// Claims the revision and prepares the confirmation. The session and the
    /// account are captured before the addresses are looked up, so a later
    /// pairing can never receive this account's reply.
    func requestRsvp(_ answer: Rsvp, senderEmail: String) async {
        guard let invite, offersRsvp, !isLocked() else { return }
        let event = invite.primary
        let key = rsvpKey(event)
        // Process-wide: two screens on the same invite cannot both answer.
        guard tracker.begin(key) else { return }
        rsvpProblem = nil

        let session = tracker.session
        let account = currentAccount()
        let addresses = await accountAddresses()
        // Locked during the lookup: release quietly, nothing to say behind
        // the cover.
        if isLocked() {
            tracker.cancel(key)
            return
        }
        guard tracker.isCurrent(session), let account, let addresses,
              let attendee = rsvpAttendee(event, accountAddresses: addresses)
        else {
            tracker.cancel(key)
            if tracker.isCurrent(session) {
                rsvpProblem = String(localized: "Couldn't confirm your account address, so no RSVP was sent. Try again.")
            }
            return
        }
        // Answering as an alias must also send from it, or the organizer
        // sees a stranger reply.
        let primary = addresses.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let sendAs = attendee.caseInsensitiveCompare(primary) == .orderedSame ? "" : attendee
        pendingRsvp = PendingRsvp(
            key: key,
            event: event,
            answer: answer,
            attendee: attendee,
            sendAs: sendAs,
            account: account,
            session: session,
            message: rsvpConfirmMessage(
                answer: answer,
                organizer: event.organizer,
                attendee: attendee,
                organizerIsSender: event.organizer.caseInsensitiveCompare(senderEmail) == .orderedSame
            )
        )
    }

    /// The user backed out: release the revision for another answer.
    func cancelRsvp(_ pending: PendingRsvp) {
        settled.insert(pending.id)
        if pendingRsvp?.id == pending.id { pendingRsvp = nil }
        tracker.cancel(pending.key)
    }

    /// The prompt went away. SwiftUI clears an alert's binding *before* the
    /// tapped button's action runs, so releasing here directly would free a
    /// revision "Send" is about to claim and let a second answer through.
    /// One hop later the button has run; release only if neither did.
    func rsvpPromptDismissed(_ pending: PendingRsvp) {
        if pendingRsvp?.id == pending.id { pendingRsvp = nil }
        Task { @MainActor in
            if !settled.contains(pending.id) { cancelRsvp(pending) }
        }
    }

    /// Sends in an unstructured task, so leaving the screen does not cancel a
    /// reply already on its way; the outcome lands in the tracker.
    @discardableResult
    func confirmRsvp(_ pending: PendingRsvp) -> Task<Void, Never>? {
        guard !settled.contains(pending.id) else { return nil }
        settled.insert(pending.id)
        if pendingRsvp?.id == pending.id { pendingRsvp = nil }
        // A prompt answered while locked sends nothing.
        guard !isLocked() else {
            tracker.cancel(pending.key)
            return nil
        }
        guard let draft = rsvpDraft(
            pending.event, attendee: pending.attendee, answer: pending.answer, now: now(), sendAs: pending.sendAs
        ) else {
            tracker.cancel(pending.key)
            return nil
        }
        let tracker = self.tracker
        let send = self.send
        return Task { @MainActor in
            // An ended session sends nothing at all.
            guard tracker.isCurrent(pending.session) else { return }
            guard let outcome = await send(draft, pending.account) else {
                // The pairing went away under it: nothing left this device.
                tracker.cancel(pending.key)
                return
            }
            tracker.complete(
                pending.key,
                result: outcome.result,
                message: rsvpOutcomeMessage(outcome.result, reason: outcome.reason),
                session: pending.session
            )
        }
    }

    // MARK: - Calendar

    /// Never automatic. Under Hostile Location Protection the event is about
    /// to leave for a store a wipe cannot reach, so that is confirmed first.
    /// The session is read at the tap, so a confirmation answered after a
    /// wipe or unpair writes nothing.
    func requestAdd(hostileLocationProtection: Bool) async {
        guard let invite, invite.offersAdd, !isLocked() else { return }
        let pending = PendingHandoff(event: invite.primary, session: tracker.session)
        if hostileLocationProtection {
            pendingHandoff = pending
        } else {
            await add(pending)
        }
    }

    func add(_ pending: PendingHandoff) async {
        if pendingHandoff?.id == pending.id { pendingHandoff = nil }
        guard !isAdding, tracker.isCurrent(pending.session), !isLocked() else { return }
        isAdding = true
        defer { isAdding = false }
        let tracker = self.tracker
        let isLocked = self.isLocked
        // The lock engaging while the permission prompt is up also stops the
        // save: the user asks again after unlocking.
        let outcome = await CalendarHandoff.add(pending.event, store: calendarStore()) {
            tracker.isCurrent(pending.session) && !isLocked()
        }
        // An ended session says nothing either.
        guard outcome != .sessionEnded, tracker.isCurrent(pending.session) else { return }
        handoffMessage = calendarHandoffMessage(outcome)
    }
}

// MARK: - Wording

/// The card's notices, most important first. The organizer is the sender's
/// own claim, so the card says when the From address disagrees.
nonisolated func inviteNotices(_ invite: CalendarInvite, senderEmail: String, phishing: Bool) -> [String] {
    let event = invite.primary
    var notices: [String] = []
    if phishing {
        notices.append(String(localized: "This message is flagged as phishing. Check the invite before you add it."))
    }
    if !event.organizer.isEmpty, event.organizer.caseInsensitiveCompare(senderEmail) != .orderedSame {
        notices.append(String(localized: "The organizer (\(event.organizer)) is not the sender of this email. Anyone can name any organizer."))
    }
    if invite.isCancelled {
        notices.append(String(localized: "This event was cancelled. Check your calendar."))
    }
    if invite.isUpdate {
        notices.append(String(localized: "This invite was updated. Check your calendar."))
    }
    if let zone = event.unknownZone {
        notices.append(String(localized: "Time zone \"\(zone)\" isn't recognised, so this time is read as your own zone and may be wrong."))
    }
    if event.isFloating {
        notices.append(String(localized: "This invite gives no time zone, so this time is read as your own zone."))
    }
    return notices
}

/// When the invite happens, in `zone`. All-day ends are exclusive, so the
/// last day shown is the day before `end`.
nonisolated func inviteWhenText(_ event: CalendarEvent, zone: TimeZone, locale: Locale) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var dates = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar)
    dates.timeZone = zone
    if event.allDay {
        let last = calendar.date(byAdding: .day, value: -1, to: event.end) ?? event.end
        guard calendar.startOfDay(for: last) > calendar.startOfDay(for: event.begin) else {
            return event.begin.formatted(dates)
        }
        return "\(event.begin.formatted(dates)) – \(last.formatted(dates))"
    }
    var dateTime = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar)
    dateTime.timeZone = zone
    var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
    time.timeZone = zone
    if event.end == event.begin { return event.begin.formatted(dateTime) }
    if calendar.isDate(event.end, inSameDayAs: event.begin) {
        return "\(event.begin.formatted(dateTime)) – \(event.end.formatted(time))"
    }
    return "\(event.begin.formatted(dateTime)) – \(event.end.formatted(dateTime))"
}

/// Every RSVP is confirmed, and the confirmation says it goes unencrypted.
nonisolated func rsvpConfirmMessage(
    answer: Rsvp,
    organizer: String,
    attendee: String,
    organizerIsSender: Bool
) -> String {
    var message = String(localized: "Reply \"\(answer.subjectPrefix)\" to \(organizer) as \(attendee).\n\nRSVPs are always sent unencrypted and unsigned, because the organizer's calendar can't read an encrypted reply. The reply carries your answer, your address and the event's ID.")
    if !organizerIsSender {
        message += "\n\n" + String(localized: "The organizer is not the sender of this email, so this reply goes to an address the sender chose.")
    }
    return message
}

nonisolated func rsvpOutcomeMessage(_ result: RsvpResult, reason: String) -> String {
    switch result {
    case .sent:
        String(localized: "RSVP sent")
    case .sentAsPlainMail:
        String(localized: "Your server didn't send this as a calendar reply. The organizer got a plain email; update your server.")
    case .refused:
        String(localized: "RSVP not sent: \(reason)")
    case .maybeSent:
        String(localized: "RSVP may not have been sent: \(reason). Check your Sent folder before trying again.")
    }
}

@MainActor
func calendarHandoffMessage(_ outcome: CalendarHandoff.Outcome) -> String {
    switch outcome {
    case .added(let calendar, false):
        String(localized: "Added to \(calendar).")
    case .added(let calendar, true):
        String(localized: "Added to \(calendar). This event repeats in a way your calendar can't express, so only its first occurrence was added.")
    case .denied:
        String(localized: "KyPost can't add events without calendar access. Allow it in Settings → Privacy & Security → Calendars.")
    case .noCalendar:
        String(localized: "There's no calendar to add this event to.")
    case .failed(let message):
        String(localized: "Couldn't add this event: \(message)")
    case .sessionEnded:
        String(localized: "This event wasn't added.")
    }
}
