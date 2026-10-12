//
//  CalendarInvite.swift
//  KyPost
//
//  A strict, bounded parser for the subset of RFC 5545 an invite card needs,
//  and the RFC 5546 REPLY an RSVP sends. Port of kypost-android's
//  mail/CalendarInvite.kt (#172, #176 and follow-ups).
//
//  The bytes are sender-controlled. Every rule here refuses rather than
//  repairs: an invite past either bound, with a structural error, or without
//  a series master does not parse, and the card simply does not appear. No
//  platform imports, so the whole table is a unit test.
//

import Foundation

nonisolated enum CalendarInviteLimits {
    /// Refused whole, before any parsing.
    static let maxInviteBytes = 256 * 1024
    static let maxEvents = 50
    /// Bounds the card and what is handed to the calendar.
    static let maxDescriptionCharacters = 16_000
    static let maxTzidCharacters = 128
}

/// One VEVENT. All-day events carry midnight in the zone they were parsed
/// for, end exclusive.
nonisolated struct CalendarEvent: Equatable, Sendable, CustomStringConvertible {
    /// Verbatim — untrimmed — for the REPLY; empty when missing or unusable.
    var uid: String
    var sequence: Int
    var summary: String
    var location: String
    /// The event's DESCRIPTION, unescaped and stripped.
    var notes: String
    /// The bare address from `mailto:`, **never the sender-chosen CN**. Empty
    /// when unusable.
    var organizer: String
    var begin: Date
    var end: Date
    var allDay: Bool
    var rrule: String
    /// A DTSTART or DTEND TZID that resolved to nothing, so the floating
    /// fallback was used. At most 64 characters.
    var unknownZone: String?
    /// The zone DTSTART names: its resolved TZID, or UTC for a `Z` time. Nil
    /// for an all-day date, a floating time, or an unresolved TZID — all read
    /// in the viewer's zone, which is also how a calendar treats a zoneless
    /// event. A series repeats in this zone, not the viewer's.
    var timeZone: TimeZone? = nil
    /// Bare addresses of every ATTENDEE that has a usable one.
    var attendees: [String] = []
    /// An override's RECURRENCE-ID line restated without TZID, or nil for a
    /// whole series.
    var recurrenceId: String?
    /// An iTIP REPLY needs a UID, an organizer, a readable SEQUENCE, and a
    /// RECURRENCE-ID that could be restated if there is one.
    var canReply = false

    /// A time of day with neither `Z` nor a TZID: RFC 5545 floating, read in
    /// the viewer's zone. An all-day date and an unresolved TZID are not this.
    var isFloating: Bool { !allDay && timeZone == nil && unknownZone == nil }

    /// Redacted: the notes are message content.
    var description: String { "CalendarEvent(redacted)" }
}

nonisolated struct CalendarInvite: Equatable, Sendable {
    /// Uppercase iTIP METHOD, or empty when absent or not a plain token.
    var method: String
    /// The series master first; an invite without one does not parse.
    var events: [CalendarEvent]

    var primary: CalendarEvent { events[0] }

    var isCancelled: Bool { method == "CANCEL" }

    /// A REQUEST with a raised SEQUENCE re-sends an invite the user may
    /// already have.
    var isUpdate: Bool { method == "REQUEST" && primary.sequence > 0 }

    /// Adding a cancellation or someone's reply would put an event in the
    /// calendar that is not happening.
    var offersAdd: Bool { method == "REQUEST" || method == "PUBLISH" || method.isEmpty }

    /// `listedMethod` is the relay's `calendarMethod` for the part
    /// (KyPost-Server #353). A relay without it predates `calendarReply`
    /// (#354), ignores the field, and would deliver the RSVP as plain mail —
    /// so it gets no buttons at all.
    func offersRsvp(listedMethod: String) -> Bool {
        method == "REQUEST" && primary.canReply && !listedMethod.isEmpty
    }
}

/// The listed part to download, or nil. A `text/calendar` part (the iMIP body
/// part) beats the `.ics` file Google attaches beside it; both hold the same
/// event.
nonisolated func inviteAttachment(_ listing: [EmailAttachment]) -> EmailAttachment? {
    func type(_ item: EmailAttachment) -> String {
        item.mimeType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }
    let candidate = listing.first { type($0) == "text/calendar" }
        ?? listing.first {
            type($0) == "application/ics"
                || $0.name.trimmingCharacters(in: .whitespaces).lowercased().hasSuffix(".ics")
        }
    guard let candidate, (1...CalendarInviteLimits.maxInviteBytes).contains(candidate.size) else { return nil }
    return candidate
}

/// Parses an invite, or nil for anything it cannot vouch for.
///
/// Floating times and all-day dates are read in `localZone`. `windowsZone`
/// maps an Outlook TZID such as "Pacific Standard Time" to an IANA id.
nonisolated func parseCalendarInvite(
    _ bytes: Data,
    localZone: TimeZone,
    windowsZone: (String) -> String? = WindowsTimeZones.ianaIdentifier(forWindowsName:)
) -> CalendarInvite? {
    guard !bytes.isEmpty, bytes.count <= CalendarInviteLimits.maxInviteBytes else { return nil }
    var text = String(decoding: unfold([UInt8](bytes)), as: UTF8.self)
    if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
    return ICS.parse(text, localZone: localZone, windowsZone: windowsZone)
}

// MARK: - RSVP

/// An RSVP answer; `rawValue` is its iTIP PARTSTAT.
nonisolated enum Rsvp: String, CaseIterable, Sendable {
    case accepted = "ACCEPTED"
    case tentative = "TENTATIVE"
    case declined = "DECLINED"

    var subjectPrefix: String {
        switch self {
        case .accepted: "Accepted"
        case .tentative: "Tentative"
        case .declined: "Declined"
        }
    }

    var verb: String {
        switch self {
        case .accepted: "accepted"
        case .tentative: "tentatively accepted"
        case .declined: "declined"
        }
    }
}

/// The user's attendee address: the one of `accountAddresses` the invite
/// lists, else the primary. Nil when no usable address is known — including
/// a relay-supplied "address" carrying CRLF, which could inject an ICS line.
nonisolated func rsvpAttendee(_ event: CalendarEvent, accountAddresses: [String]) -> String? {
    let own = accountAddresses.map { $0.trimmingCharacters(in: .whitespaces) }.filter(ICS.isAddress)
    return own.first { mine in
        event.attendees.contains { $0.caseInsensitiveCompare(mine) == .orderedSame }
    } ?? own.first
}

/// What an RSVP sends through `/api/mail/send`. **Always unencrypted and
/// unsigned**: the relay refuses `calendarReply` beside either flag, and the
/// organizer's calendar could not read an encrypted reply anyway — so this
/// type has no field that could ask for either.
nonisolated struct CalendarReplyDraft: Equatable, Sendable {
    var to: String
    var subject: String
    var body: String
    /// The alias the user answers as, or empty for the account's primary.
    var from: String
    var ics: String
}

/// RFC 5546 §3.2.3 REPLY: the same UID, SEQUENCE and RECURRENCE-ID, this
/// attendee's PARTSTAT, a fresh DTSTAMP, addressed to the ORGANIZER. Nil
/// when the event cannot be answered or the attendee is not an address.
nonisolated func rsvpDraft(
    _ event: CalendarEvent,
    attendee: String,
    answer: Rsvp,
    now: Date,
    sendAs: String = ""
) -> CalendarReplyDraft? {
    guard event.canReply, ICS.isAddress(attendee) else { return nil }
    let lines: [String] = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//KyPost//Apple//EN",
        "METHOD:REPLY",
        "BEGIN:VEVENT",
        "UID:\(event.uid)",
        event.recurrenceId,
        "SEQUENCE:\(event.sequence)",
        "DTSTAMP:" + ICS.utcStamp(now),
        "ORGANIZER:mailto:\(event.organizer)",
        "ATTENDEE;PARTSTAT=\(answer.rawValue):mailto:\(attendee)",
        "END:VEVENT",
        "END:VCALENDAR",
    ].compactMap { $0 }
    let title = ICS.collapsingAsciiWhitespace(event.summary)
    return CalendarReplyDraft(
        to: event.organizer,
        subject: "\(answer.subjectPrefix): \(title.isEmpty ? "Invitation" : title)",
        body: "\(attendee) has \(answer.verb) this invitation.",
        from: sendAs,
        ics: lines.map { ICS.fold($0) + "\r\n" }.joined()
    )
}

/// One answerable revision: a raised SEQUENCE is a new invite to answer.
nonisolated func rsvpKey(_ event: CalendarEvent) -> String {
    [event.uid, event.recurrenceId ?? "", String(event.sequence)].joined(separator: "\u{0}")
}

// MARK: - Parsing

/// RFC 5545 §3.1: unfolded as bytes, because a fold may split a UTF-8
/// sequence and decoding first would turn each half into U+FFFD.
private nonisolated func unfold(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var index = 0
    while index < bytes.count {
        let lineFeed: Int? = if bytes[index] == 0x0A {
            index
        } else if bytes[index] == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
            index + 1
        } else {
            nil
        }
        if let lineFeed, lineFeed + 1 < bytes.count,
           bytes[lineFeed + 1] == 0x20 || bytes[lineFeed + 1] == 0x09 {
            index = lineFeed + 2
            continue
        }
        out.append(bytes[index])
        index += 1
    }
    return out
}

private nonisolated enum ICS {
    struct ContentLine {
        var name: String
        var params: [String: String]
        var value: String
    }

    struct EventTime {
        var at: Date
        var zone: TimeZone
        var allDay: Bool
        var unknownZone: String?
        /// The zone the value named (TZID or `Z`); nil when it named none or
        /// an unresolvable one.
        var declaredZone: TimeZone? = nil
    }

    static func parse(
        _ text: String,
        localZone: TimeZone,
        windowsZone: (String) -> String?
    ) -> CalendarInvite? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var stack: [String] = []
        var method = ""
        var event: [String: ContentLine]?
        var attendees: [String] = []
        var events: [(event: CalendarEvent, isOverride: Bool)] = []
        var eventCount = 0

        for (index, raw) in lines.enumerated() {
            guard let line = contentLine(raw) else { return nil }
            if index == 0,
               !(line.name == "BEGIN" && line.value.caseInsensitiveCompare("VCALENDAR") == .orderedSame) {
                return nil
            }
            if index > 0, stack.isEmpty { return nil }
            switch line.name {
            case "BEGIN":
                let component = line.value.trimmingCharacters(in: .whitespaces).uppercased()
                if component == "VCALENDAR", !stack.isEmpty { return nil }
                if component == "VEVENT" {
                    eventCount += 1
                    guard stack.count == 1, eventCount <= CalendarInviteLimits.maxEvents else { return nil }
                    event = [:]
                    attendees = []
                }
                stack.append(component)
            case "END":
                guard stack.last == line.value.trimmingCharacters(in: .whitespaces).uppercased()
                else { return nil }
                if stack.removeLast() == "VEVENT" {
                    guard let props = event,
                          let parsed = toEvent(props, attendees: attendees, localZone: localZone, windowsZone: windowsZone)
                    else { return nil }
                    events.append(parsed)
                    event = nil
                }
            default:
                if stack.count == 1, line.name == "METHOD" {
                    let token = line.value.trimmingCharacters(in: .whitespaces).uppercased()
                    method = isMethodToken(token) ? token : ""
                } else if stack.count == 2, stack[1] == "VEVENT" {
                    // Only the VEVENT's own properties: a VALARM inside it
                    // has a DESCRIPTION too.
                    if line.name == "ATTENDEE" {
                        // Uncapped: the byte bound already limits the list,
                        // and a cut could drop the user's own alias.
                        if let address = mailtoAddress(line.value) { attendees.append(address) }
                    } else if event?[line.name] == nil {
                        event?[line.name] = line
                    }
                }
            }
        }
        // No series master: an override must never be the headline event.
        guard stack.isEmpty, events.contains(where: { !$0.isOverride }) else { return nil }
        let ordered = events.filter { !$0.isOverride } + events.filter(\.isOverride)
        return CalendarInvite(method: method, events: ordered.map(\.event))
    }

    static func toEvent(
        _ props: [String: ContentLine],
        attendees: [String],
        localZone: TimeZone,
        windowsZone: (String) -> String?
    ) -> (event: CalendarEvent, isOverride: Bool)? {
        guard let startLine = props["DTSTART"],
              let start = time(startLine, localZone: localZone, windowsZone: windowsZone)
        else { return nil }
        var endTime: EventTime?
        if let endLine = props["DTEND"] {
            guard let parsed = time(endLine, localZone: localZone, windowsZone: windowsZone) else { return nil }
            endTime = parsed
        }
        let end = endTime?.at
            ?? props["DURATION"].flatMap { addDuration(start, $0.value.trimmingCharacters(in: .whitespaces)) }
            ?? (start.allDay ? calendar(start.zone).date(byAdding: .day, value: 1, to: start.at) ?? start.at : start.at)

        // Untrimmed: the organizer matches the REPLY on the exact UID text.
        let rawUid = props["UID"]?.value ?? ""
        let uid = !rawUid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && rawUid.utf16.count <= 1_000
            && !rawUid.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            ? rawUid : ""
        let organizer = props["ORGANIZER"].flatMap { mailtoAddress($0.value) } ?? ""
        let recurrence = props["RECURRENCE-ID"]
        let recurrenceId = recurrence.flatMap { recurrenceIdLine($0, localZone: localZone, windowsZone: windowsZone) }
        // A SEQUENCE that cannot be read back exactly would make a
        // valid-looking reply to the wrong revision.
        let sequence: Int? = if let raw = props["SEQUENCE"]?.value.trimmingCharacters(in: .whitespaces) {
            Int32(raw).flatMap { $0 >= 0 ? Int($0) : nil }
        } else {
            0
        }
        let rrule = props["RRULE"]?.value.trimmingCharacters(in: .whitespaces) ?? ""

        return (
            CalendarEvent(
                uid: uid,
                sequence: sequence ?? 0,
                summary: text(props["SUMMARY"], limit: 1_000),
                location: text(props["LOCATION"], limit: 1_000),
                notes: text(props["DESCRIPTION"], limit: CalendarInviteLimits.maxDescriptionCharacters),
                organizer: organizer,
                begin: start.at,
                end: max(end, start.at),
                allDay: start.allDay,
                rrule: isSafeRRule(rrule) ? rrule : "",
                unknownZone: start.unknownZone ?? endTime?.unknownZone,
                timeZone: start.allDay ? nil : start.declaredZone,
                attendees: attendees,
                recurrenceId: recurrenceId,
                canReply: !uid.isEmpty && !organizer.isEmpty && sequence != nil
                    && (recurrence == nil || recurrenceId != nil)
            ),
            recurrence != nil
        )
    }

    /// The REPLY carries no VTIMEZONE, so a TZID cannot be copied: a date
    /// stays a date, a floating or UTC time stays as written, a zoned time
    /// becomes UTC. Nil when it cannot be restated.
    static func recurrenceIdLine(
        _ line: ContentLine,
        localZone: TimeZone,
        windowsZone: (String) -> String?
    ) -> String? {
        guard let time = time(line, localZone: localZone, windowsZone: windowsZone),
              time.unknownZone == nil
        else { return nil }
        let value = line.value.trimmingCharacters(in: .whitespaces)
        if time.allDay { return "RECURRENCE-ID;VALUE=DATE:\(value)" }
        let tzid = line.params["TZID"]?.trimmingCharacters(in: .whitespaces) ?? ""
        if tzid.isEmpty || value.hasSuffix("Z") { return "RECURRENCE-ID:\(value)" }
        return "RECURRENCE-ID:" + utcStamp(time.at)
    }

    static func time(
        _ line: ContentLine,
        localZone: TimeZone,
        windowsZone: (String) -> String?
    ) -> EventTime? {
        let value = Array(line.value.trimmingCharacters(in: .whitespaces).unicodeScalars)
        let declaredDate = line.params["VALUE"]?.caseInsensitiveCompare("DATE") == .orderedSame
        if declaredDate || isDigits(value[...], count: 8) {
            guard value.count == 8, let date = localDate(value[0..<8]),
                  let at = makeDate(date, hour: 0, minute: 0, second: 0, zone: localZone)
            else { return nil }
            return EventTime(at: at, zone: localZone, allDay: true, unknownZone: nil)
        }
        // yyyyMMddTHHmmss, optionally Z.
        guard value.count == 15 || (value.count == 16 && value[15] == "Z"),
              value[8] == "T",
              let date = localDate(value[0..<8]),
              isDigits(value[9..<15], count: 6),
              let hour = number(value[9..<11]), let minute = number(value[11..<13]),
              let second = number(value[13..<15]),
              hour < 24, minute < 60, second < 60
        else { return nil }
        if value.count == 16 {
            let utc = TimeZone(identifier: "UTC")!
            return makeDate(date, hour: hour, minute: minute, second: second, zone: utc)
                .map { EventTime(at: $0, zone: utc, allDay: false, unknownZone: nil, declaredZone: utc) }
        }
        let tzid = line.params["TZID"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let resolved = tzid.isEmpty ? nil : resolveZone(tzid, windowsZone: windowsZone)
        let zone = resolved ?? localZone
        return makeDate(date, hour: hour, minute: minute, second: second, zone: zone).map {
            EventTime(
                at: $0,
                zone: zone,
                allDay: false,
                unknownZone: !tzid.isEmpty && resolved == nil ? String(tzid.prefix(64)) : nil,
                declaredZone: resolved
            )
        }
    }

    /// The IANA id as given, then its last three or two path segments
    /// (`/mozilla.org/20050126_1/America/New_York`), then the Windows-name
    /// table. Over the cap is unknown without being looked at.
    static func resolveZone(_ tzid: String, windowsZone: (String) -> String?) -> TimeZone? {
        guard tzid.utf16.count <= CalendarInviteLimits.maxTzidCharacters else { return nil }
        let segments = tzid.split(separator: "/").map(String.init)
        let candidates = [
            tzid,
            segments.suffix(3).joined(separator: "/"),
            segments.suffix(2).joined(separator: "/"),
        ] + [windowsZone(tzid)].compactMap { $0 }
        for id in candidates where !id.isEmpty {
            if let zone = TimeZone(identifier: id) { return zone }
        }
        return nil
    }

    /// RFC 5545 §3.3.6. Weeks and days are nominal, so they move with DST the
    /// way a calendar would; hours, minutes and seconds are exact.
    static func addDuration(_ start: EventTime, _ value: String) -> Date? {
        var scalars = Array(value.unicodeScalars)[...]
        var sign = 1
        if let first = scalars.first, first == "+" || first == "-" {
            sign = first == "-" ? -1 : 1
            scalars = scalars.dropFirst()
        }
        guard scalars.first == "P" else { return nil }
        scalars = scalars.dropFirst()

        func take(_ unit: Unicode.Scalar) -> Int?? {
            var digits = 0
            while digits < scalars.count, isDigit(scalars[scalars.startIndex + digits]) { digits += 1 }
            // Absent unless digits are followed by this unit; the next unit
            // gets its own look at them.
            guard digits > 0,
                  scalars.startIndex + digits < scalars.endIndex,
                  scalars[scalars.startIndex + digits] == unit
            else { return .some(nil) }
            guard digits <= 6 else { return nil }
            let n = number(scalars.prefix(digits))
            scalars = scalars.dropFirst(digits + 1)
            return .some(n)
        }

        var weeks: Int?
        var days: Int?
        var hours: Int?
        var minutes: Int?
        var seconds: Int?
        guard let w = take("W") else { return nil }
        weeks = w
        if weeks == nil {
            guard let d = take("D") else { return nil }
            days = d
            if scalars.first == "T" {
                scalars = scalars.dropFirst()
                guard let h = take("H") else { return nil }
                hours = h
                guard let m = take("M") else { return nil }
                minutes = m
                guard let s = take("S") else { return nil }
                seconds = s
            }
        }
        guard scalars.isEmpty, [weeks, days, hours, minutes, seconds].contains(where: { $0 != nil })
        else { return nil }

        let nominal = calendar(start.zone)
        guard let shifted = nominal.date(
            byAdding: DateComponents(day: sign * ((weeks ?? 0) * 7 + (days ?? 0))),
            to: start.at
        ) else { return nil }
        let exact = (hours ?? 0) * 3_600 + (minutes ?? 0) * 60 + (seconds ?? 0)
        return shifted.addingTimeInterval(TimeInterval(sign * exact))
    }

    /// `NAME *(;PARAM=value) : value`, with quoted parameter values that may
    /// hold `:` or `;`. Worked on scalars: a combining mark after `:` would
    /// otherwise fuse with it into one `Character` and hide the delimiter.
    static func contentLine(_ line: String) -> ContentLine? {
        let s = Array(line.unicodeScalars)
        var i = 0
        while i < s.count, s[i] != ";", s[i] != ":" { i += 1 }
        guard i < s.count, i > 0 else { return nil }
        let name = String(String.UnicodeScalarView(s[0..<i])).uppercased()
        guard isName(name) else { return nil }
        var params: [String: String] = [:]
        while s[i] == ";" {
            guard let equals = s[i...].firstIndex(of: "=") else { return nil }
            let param = String(String.UnicodeScalarView(s[(i + 1)..<equals])).uppercased()
            guard isName(param) else { return nil }
            i = equals + 1
            var value = String.UnicodeScalarView()
            while i < s.count, s[i] != ";", s[i] != ":" {
                if s[i] == "\"" {
                    guard let close = s[(i + 1)...].firstIndex(of: "\"") else { return nil }
                    value.append(contentsOf: s[(i + 1)..<close])
                    i = close + 1
                } else {
                    value.append(s[i])
                    i += 1
                }
            }
            guard i < s.count else { return nil }
            if params[param] == nil { params[param] = String(value) }
        }
        return ContentLine(name: name, params: params, value: String(String.UnicodeScalarView(s[(i + 1)...])))
    }

    /// RFC 5545 §3.3.11 unescape, then strip what could reorder or hide text
    /// on the card: controls and format characters (bidi, zero-width), except
    /// newline, tab, and ZWJ, which joins emoji. `limit` counts UTF-16 units.
    static func text(_ line: ContentLine?, limit: Int) -> String {
        guard let value = line?.value else { return "" }
        var out = String.UnicodeScalarView()
        var length = 0
        var scalars = value.unicodeScalars.makeIterator()
        while length < limit, var scalar = scalars.next() {
            if scalar == "\\", let next = scalars.next() {
                scalar = next == "n" || next == "N" ? "\n" : next
            }
            let category = scalar.properties.generalCategory
            if scalar == "\n" || scalar == "\t" || scalar == "\u{200D}"
                || (category != .control && category != .format) {
                out.append(scalar)
                length += scalar.utf16.count
            }
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mailtoAddress(_ value: String) -> String? {
        var address = value.trimmingCharacters(in: .whitespaces)
        if address.lowercased().hasPrefix("mailto:") {
            address = String(address.unicodeScalars.dropFirst(7))
        }
        return isAddress(address) ? address : nil
    }

    /// `local@domain`, 1–64 and 1–190 characters, with no whitespace, angle
    /// brackets, quotes, controls or format characters in either half — so a
    /// zero-width or bidi character makes the whole address unusable rather
    /// than invisibly different.
    static func isAddress(_ value: String) -> Bool {
        let halves = value.unicodeScalars.split(separator: "@", omittingEmptySubsequences: false)
        guard halves.count == 2,
              (1...64).contains(halves[0].count), (1...190).contains(halves[1].count)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            if scalar == "@" { return true }
            if " \t\n\u{0B}\u{0C}\r<>\"".unicodeScalars.contains(scalar) { return false }
            let category = scalar.properties.generalCategory
            return category != .control && category != .format
        }
    }

    /// RFC 5545 §3.1: at most 75 octets a line, never splitting a UTF-8
    /// sequence. A continuation's leading space counts.
    static func fold(_ line: String) -> String {
        var out = ""
        var octets = 0
        for scalar in line.unicodeScalars {
            let size = String(scalar).utf8.count
            if octets + size > 75 {
                out += "\r\n "
                octets = 1
            }
            out.unicodeScalars.append(scalar)
            octets += size
        }
        return out
    }

    static func utcStamp(_ date: Date) -> String {
        let parts = calendar(TimeZone(identifier: "UTC")!).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    static func collapsingAsciiWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: "[ \\t\\n\\x0B\\f\\r]+", with: " ", options: .regularExpression)
    }

    // MARK: Small pieces

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// Strict: an impossible date is refused, never rolled over.
    static func localDate(_ digits: ArraySlice<Unicode.Scalar>) -> (year: Int, month: Int, day: Int)? {
        guard isDigits(digits, count: 8),
              let year = number(digits.prefix(4)),
              let month = number(digits.dropFirst(4).prefix(2)),
              let day = number(digits.dropFirst(6).prefix(2)),
              (1...12).contains(month)
        else { return nil }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...lengths[month - 1]).contains(day) else { return nil }
        return (year, month, day)
    }

    static func makeDate(
        _ date: (year: Int, month: Int, day: Int),
        hour: Int, minute: Int, second: Int,
        zone: TimeZone
    ) -> Date? {
        calendar(zone).date(from: DateComponents(
            year: date.year, month: date.month, day: date.day,
            hour: hour, minute: minute, second: second
        ))
    }

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

    static func isDigits(_ scalars: ArraySlice<Unicode.Scalar>, count: Int) -> Bool {
        scalars.count == count && scalars.allSatisfy(isDigit)
    }

    static func number(_ scalars: ArraySlice<Unicode.Scalar>) -> Int? {
        Int(String(String.UnicodeScalarView(scalars)))
    }

    /// `[A-Z0-9-]{1,64}`.
    static func isName(_ value: String) -> Bool {
        (1...64).contains(value.unicodeScalars.count)
            && value.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || isDigit($0) || $0 == "-" }
    }

    /// `[A-Z][A-Z0-9-]{0,31}`.
    static func isMethodToken(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, ("A"..."Z").contains(first),
              value.unicodeScalars.count <= 32
        else { return false }
        return isName(value)
    }

    /// `[A-Za-z0-9=;,:+-]{1,512}` — passed to the calendar as given, so
    /// nothing else gets through.
    static func isSafeRRule(_ value: String) -> Bool {
        (1...512).contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || isDigit($0) || "=;,:+-".unicodeScalars.contains($0)
        }
    }
}

/// Exposed for `rsvpAttendee` and tests: the parser's address rule.
nonisolated func isInviteAddress(_ value: String) -> Bool { ICS.isAddress(value) }
