//
//  CalendarHandoff.swift
//  KyPost
//
//  "Add to Calendar" for an invite. Android hands an ACTION_INSERT intent to
//  the calendar app; here EventKit writes the event into the user's default
//  calendar. KyPost syncs no calendar and reads none.
//
//  Only ever a tap: calendar access is requested on that tap and nowhere
//  else, and it is write-only — this app never needs to read the calendar.
//  Under Hostile Location Protection the caller confirms first: the event
//  leaves for a store a wipe cannot reach.
//

import EventKit
import Foundation

/// The subset of an RFC 5545 RRULE EventKit can express. Nil for anything
/// else, and the event is then added as a single occurrence — the caller says
/// so rather than adding a series that repeats differently.
nonisolated struct RecurrenceSpec: Equatable, Sendable {
    enum Frequency: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
    enum End: Equatable, Sendable {
        case never
        case count(Int)
        /// UNTIL, as an instant. A date-only UNTIL is the end of that day in
        /// `zone`.
        case until(Date)
    }

    /// 1 = Sunday … 7 = Saturday, EventKit's numbering; `week` 0 = every.
    struct Day: Equatable, Sendable {
        var weekday: Int
        var week: Int
    }

    var frequency: Frequency
    var interval = 1
    var days: [Day] = []
    var monthDays: [Int] = []
    var months: [Int] = []
    var setPositions: [Int] = []
    var end: End = .never

    init?(_ rrule: String, zone: TimeZone) {
        var parts: [String: String] = [:]
        for piece in rrule.split(separator: ";") {
            let pair = piece.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, parts[pair[0].uppercased()] == nil else { return nil }
            parts[pair[0].uppercased()] = pair[1].uppercased()
        }
        guard let raw = parts.removeValue(forKey: "FREQ"), let frequency = Frequency(rawValue: raw) else { return nil }
        self.frequency = frequency
        // RFC 5545's default week start is Monday.
        var weekStart = 2
        if let raw = parts.removeValue(forKey: "WKST") {
            guard let day = Self.weekdays[raw] else { return nil }
            weekStart = day
        }
        if let raw = parts.removeValue(forKey: "INTERVAL") {
            guard let n = Int(raw), (1...1_000).contains(n) else { return nil }
            interval = n
        }
        switch (parts.removeValue(forKey: "COUNT"), parts.removeValue(forKey: "UNTIL")) {
        case (nil, nil):
            break
        case (let count?, nil):
            guard let n = Int(count), (1...10_000).contains(n) else { return nil }
            end = .count(n)
        case (nil, let until?):
            guard let date = Self.untilDate(until, zone: zone) else { return nil }
            end = .until(date)
        default:
            return nil
        }
        if let raw = parts.removeValue(forKey: "BYDAY") {
            guard let parsed = Self.days(raw) else { return nil }
            days = parsed
        }
        if let raw = parts.removeValue(forKey: "BYMONTHDAY") {
            guard let parsed = Self.integers(raw, allowed: -31...31) else { return nil }
            monthDays = parsed
        }
        if let raw = parts.removeValue(forKey: "BYMONTH") {
            guard let parsed = Self.integers(raw, allowed: 1...12) else { return nil }
            months = parsed
        }
        if let raw = parts.removeValue(forKey: "BYSETPOS") {
            guard let parsed = Self.integers(raw, allowed: -366...366) else { return nil }
            setPositions = parsed
        }
        // BYHOUR, BYWEEKNO, BYYEARDAY and the rest have no EventKit form.
        guard parts.isEmpty else { return nil }
        // EventKit takes no week start, so a rule whose occurrences depend on
        // it would be saved as a different series.
        if frequency == .weekly, interval > 1,
           !Self.weekGroupingHolds(Set(days.map(\.weekday)), weekStart: weekStart) {
            return nil
        }
    }

    /// The week starts a calendar may apply in place of WKST: EventKit's own
    /// choice is not public, and CLDR gives every region one of these.
    private static let possibleWeekStarts = [6, 7, 1, 2]

    /// Whether `days` fall into the same weeks whichever of
    /// `possibleWeekStarts` replaces `weekStart`. Two starts group them alike
    /// unless the days from one start up to the other hold some, not all, of
    /// them.
    private static func weekGroupingHolds(_ days: Set<Int>, weekStart: Int) -> Bool {
        possibleWeekStarts.allSatisfy { other in
            var between: Set<Int> = []
            var day = weekStart
            while day != other {
                between.insert(day)
                day = day % 7 + 1
            }
            let inside = days.intersection(between)
            return inside.isEmpty || inside == days
        }
    }

    private static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    private static func days(_ raw: String) -> [Day]? {
        var out: [Day] = []
        for item in raw.split(separator: ",") {
            let code = String(item.suffix(2))
            guard let weekday = weekdays[code] else { return nil }
            let prefix = String(item.dropLast(2))
            if prefix.isEmpty {
                out.append(Day(weekday: weekday, week: 0))
            } else {
                guard let week = Int(prefix), week != 0, (-53...53).contains(week) else { return nil }
                out.append(Day(weekday: weekday, week: week))
            }
        }
        return out.isEmpty ? nil : out
    }

    private static func integers(_ raw: String, allowed: ClosedRange<Int>) -> [Int]? {
        let values = raw.split(separator: ",").map { Int($0) }
        guard !values.isEmpty, values.allSatisfy({ $0.map { $0 != 0 && allowed.contains($0) } ?? false })
        else { return nil }
        return values.compactMap { $0 }
    }

    private static func untilDate(_ raw: String, zone: TimeZone) -> Date? {
        // Reuse the invite parser's strict date rules through a one-event ICS.
        let line = raw.count == 8 ? "DTSTART;VALUE=DATE:\(raw)" : "DTSTART:\(raw)"
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n\(line)\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        guard let event = parseCalendarInvite(Data(ics.utf8), localZone: zone)?.primary else { return nil }
        // A date-only UNTIL includes that whole day.
        return event.allDay ? event.end.addingTimeInterval(-1) : event.begin
    }

    func rule() -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency = switch self.frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
        let end: EKRecurrenceEnd? = switch self.end {
        case .never: nil
        case .count(let n): EKRecurrenceEnd(occurrenceCount: n)
        case .until(let date): EKRecurrenceEnd(end: date)
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: days.isEmpty ? nil : days.compactMap { day in
                EKWeekday(rawValue: day.weekday).map {
                    day.week == 0 ? EKRecurrenceDayOfWeek($0) : EKRecurrenceDayOfWeek($0, weekNumber: day.week)
                }
            },
            daysOfTheMonth: monthDays.isEmpty ? nil : monthDays.map { NSNumber(value: $0) },
            monthsOfTheYear: months.isEmpty ? nil : months.map { NSNumber(value: $0) },
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: setPositions.isEmpty ? nil : setPositions.map { NSNumber(value: $0) },
            end: end
        )
    }
}

/// The calendar store the handoff writes to. A protocol so the permission
/// wait and the save can be observed in tests without touching a calendar.
@MainActor
protocol CalendarStoring {
    var authorization: EKAuthorizationStatus { get }
    /// Asks for write-only access; true when granted.
    func requestWriteOnlyAccess() async -> Bool
    /// Builds and saves an event in the default calendar, returning that
    /// calendar's title; nil, saving nothing, when there is no calendar.
    func saveToDefaultCalendar(_ configure: (EKEvent) -> Void) throws -> String?
}

@MainActor
struct EventKitCalendarStore: CalendarStoring {
    var store = EKEventStore()

    var authorization: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    func requestWriteOnlyAccess() async -> Bool {
        (try? await store.requestWriteOnlyAccessToEvents()) == true
    }

    func saveToDefaultCalendar(_ configure: (EKEvent) -> Void) throws -> String? {
        guard let calendar = store.defaultCalendarForNewEvents else { return nil }
        let item = EKEvent(eventStore: store)
        item.calendar = calendar
        configure(item)
        try store.save(item, span: .thisEvent, commit: true)
        return calendar.title
    }
}

@MainActor
enum CalendarHandoff {
    enum Outcome: Equatable {
        /// Added to `calendar`. `repeatsDropped` when the invite repeats in a
        /// way EventKit cannot express, so only its first occurrence went in.
        case added(calendar: String, repeatsDropped: Bool)
        case denied
        case noCalendar
        case failed(String)
        /// The session the tap belonged to ended (wipe, failed-unlock reset,
        /// unpair) before the event was written, so nothing was.
        case sessionEnded
    }

    /// Writes the event. Asks for write-only calendar access the first time,
    /// which is why this must only ever run from the user's tap.
    ///
    /// `isCurrent` is the session the tap was made in. It is checked again
    /// after the permission prompt, which can stay up indefinitely, and
    /// immediately before the save: content from an ended session must not
    /// reach a store outside KyPost.
    static func add(
        _ event: CalendarEvent,
        store: some CalendarStoring,
        isCurrent: () -> Bool
    ) async -> Outcome {
        guard isCurrent() else { return .sessionEnded }
        switch store.authorization {
        case .writeOnly, .fullAccess:
            break
        case .denied, .restricted:
            return .denied
        default:
            guard await store.requestWriteOnlyAccess() else { return .denied }
        }
        guard isCurrent() else { return .sessionEnded }

        let spec = event.rrule.isEmpty ? nil : RecurrenceSpec(event.rrule, zone: event.timeZone ?? .current)
        do {
            guard let calendar = try store.saveToDefaultCalendar({ configure($0, from: event, recurrence: spec) })
            else { return .noCalendar }
            return .added(calendar: calendar, repeatsDropped: !event.rrule.isEmpty && spec == nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Fills `item` from the invite. The event's own zone goes with it, so a
    /// series repeats at the organizer's wall-clock time; a floating or
    /// all-day event stays zoneless, as the card reads it.
    static func configure(_ item: EKEvent, from event: CalendarEvent, recurrence spec: RecurrenceSpec?) {
        item.title = event.summary.isEmpty ? String(localized: "Untitled event") : event.summary
        item.isAllDay = event.allDay
        item.timeZone = event.allDay ? nil : event.timeZone
        item.startDate = event.begin
        // All-day ends are exclusive in the invite; EventKit's are the last
        // day itself, so an exclusive midnight would add a day.
        item.endDate = event.allDay ? max(event.begin, event.end.addingTimeInterval(-1)) : event.end
        if !event.location.isEmpty { item.location = event.location }
        if !event.notes.isEmpty { item.notes = event.notes }
        if let spec { item.addRecurrenceRule(spec.rule()) }
    }
}
