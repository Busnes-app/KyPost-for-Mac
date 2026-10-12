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
        parts["WKST"] = nil
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

@MainActor
enum CalendarHandoff {
    enum Outcome: Equatable {
        /// Added to `calendar`. `repeatsDropped` when the invite repeats in a
        /// way EventKit cannot express, so only its first occurrence went in.
        case added(calendar: String, repeatsDropped: Bool)
        case denied
        case noCalendar
        case failed(String)
    }

    /// Writes the event. Asks for write-only calendar access the first time,
    /// which is why this must only ever run from the user's tap.
    static func add(_ event: CalendarEvent, store: EKEventStore = EKEventStore()) async -> Outcome {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .writeOnly, .fullAccess:
            break
        case .denied, .restricted:
            return .denied
        default:
            guard (try? await store.requestWriteOnlyAccessToEvents()) == true else { return .denied }
        }
        guard let calendar = store.defaultCalendarForNewEvents else { return .noCalendar }

        let item = EKEvent(eventStore: store)
        item.calendar = calendar
        item.title = event.summary.isEmpty ? String(localized: "Untitled event") : event.summary
        item.isAllDay = event.allDay
        item.startDate = event.begin
        // All-day ends are exclusive in the invite; EventKit's are the last
        // day itself, so an exclusive midnight would add a day.
        item.endDate = event.allDay ? max(event.begin, event.end.addingTimeInterval(-1)) : event.end
        if !event.location.isEmpty { item.location = event.location }
        if !event.notes.isEmpty { item.notes = event.notes }
        let spec = event.rrule.isEmpty ? nil : RecurrenceSpec(event.rrule, zone: .current)
        if let spec { item.addRecurrenceRule(spec.rule()) }

        do {
            try store.save(item, span: .thisEvent, commit: true)
            return .added(calendar: calendar.title, repeatsDropped: !event.rrule.isEmpty && spec == nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
