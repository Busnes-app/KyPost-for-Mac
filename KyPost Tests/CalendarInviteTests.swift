//
//  CalendarInviteTests.swift
//  KyPost Tests
//
//  kypost-android's CalendarInviteTest, CalendarRsvpTest and
//  CalendarHandoffTest, ported as tables where a table reads better. The
//  bytes are sender-controlled, so the refusal rows matter as much as the
//  parsing ones.
//

import EventKit
import Foundation
import Testing
@testable import KyPost

private let berlin = TimeZone(identifier: "Europe/Berlin")!
private let utc = TimeZone(identifier: "UTC")!

private func iso(_ value: String) -> Date {
    try! Date(value, strategy: .iso8601)
}

private func ics(_ lines: [String]) -> Data {
    Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
}

private func invite(method: String = "REQUEST", _ event: [String]) -> Data {
    ics(["BEGIN:VCALENDAR", "VERSION:2.0", "METHOD:\(method)", "BEGIN:VEVENT"] + event + ["END:VEVENT", "END:VCALENDAR"])
}

private func parse(_ data: Data, zone: TimeZone = berlin, windows: (String) -> String? = { _ in nil }) -> CalendarInvite? {
    parseCalendarInvite(data, localZone: zone, windowsZone: windows)
}

/// One row of the parser table: input, and either a refusal or a check on
/// what parsed.
struct InviteCase: Sendable, CustomTestStringConvertible {
    let name: String
    let data: Data
    /// Nil means the invite must be refused.
    let check: (@Sendable (CalendarInvite) -> Void)?

    var testDescription: String { name }

    static func refused(_ name: String, _ data: Data) -> InviteCase {
        InviteCase(name: name, data: data, check: nil)
    }

    static func parses(_ name: String, _ data: Data, _ check: @escaping @Sendable (CalendarInvite) -> Void) -> InviteCase {
        InviteCase(name: name, data: data, check: check)
    }
}

nonisolated private let inviteParserTable: [InviteCase] = [
    .parses("a Google-style request", invite([
        "UID:abc@google.com",
        "SEQUENCE:0",
        "DTSTART:20261012T130000Z",
        "DTEND:20261012T140000Z",
        "SUMMARY:Planning\\, Q4",
        "LOCATION:Room 4\\; Floor 2",
        "DESCRIPTION:Line one\\nLine two\\\\done",
        "ORGANIZER;CN=\"Boss: The Real One\":mailto:boss@example.com",
    ])) { parsed in
        let event = parsed.primary
        #expect(parsed.method == "REQUEST")
        #expect(event.uid == "abc@google.com")
        #expect(event.summary == "Planning, Q4")
        #expect(event.location == "Room 4; Floor 2")
        #expect(event.notes == "Line one\nLine two\\done")
        // The bare address, never the CN.
        #expect(event.organizer == "boss@example.com")
        #expect(event.begin == iso("2026-10-12T13:00:00Z"))
        #expect(event.end == iso("2026-10-12T14:00:00Z"))
        #expect(!event.allDay)
        #expect(parsed.offersAdd)
        #expect(!parsed.isUpdate)
    },
    .parses("a TZID resolves to its zone, not the device's", invite([
        "DTSTART;TZID=America/New_York:20261012T090000", "DURATION:PT90M",
    ])) { parsed in
        #expect(parsed.primary.begin == iso("2026-10-12T13:00:00Z"))
        #expect(parsed.primary.end == iso("2026-10-12T14:30:00Z"))
        #expect(parsed.primary.unknownZone == nil)
    },
    .parses("a Mozilla-prefixed TZID resolves from its tail", invite([
        "DTSTART;TZID=/mozilla.org/20050126_1/America/New_York:20261012T090000",
    ])) { parsed in
        #expect(parsed.primary.begin == iso("2026-10-12T13:00:00Z"))
    },
    .parses("an unknown TZID falls back to floating and says so", invite([
        "DTSTART;TZID=Narnia Time:20261012T090000",
    ])) { parsed in
        #expect(parsed.primary.begin == iso("2026-10-12T07:00:00Z"))
        #expect(parsed.primary.unknownZone == "Narnia Time")
    },
    .parses("a huge TZID is unknown, capped, and not looked up", invite([
        "DTSTART;TZID=\(String(repeating: "/a", count: 100_000)):20261012T090000",
    ])) { parsed in
        #expect(parsed.primary.unknownZone?.count == 64)
    },
    .parses("a fold that splits a UTF-8 sequence is rejoined",
            Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20261012T100000Z\r\nSUMMARY:Caf".utf8)
                + Data([0xC3]) + Data("\r\n ".utf8) + Data([0xA9])
                + Data("\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)) { parsed in
        #expect(parsed.primary.summary == "Café")
    },
    .refused("an impossible date-time is refused, not rolled over", invite(["DTSTART:20260231T100000Z"])),
    .refused("an impossible date is refused, not rolled over", invite(["DTSTART;VALUE=DATE:20260231"])),
    .refused("a parameter name cannot swallow the value", invite(["DTSTART:20261012T100000Z", "X-JUNK;FOO:a=b:c"])),
    .parses("format characters are stripped, joiners kept", invite([
        "DTSTART:20261012T100000Z", "SUMMARY:a\u{200B}b\u{061C}c\u{FEFF}d \u{1F469}\u{200D}\u{1F4BB}",
    ])) { parsed in
        #expect(parsed.primary.summary == "abcd \u{1F469}\u{200D}\u{1F4BB}")
    },
    .parses("a zero-width character makes an address unusable", invite([
        "DTSTART:20261012T100000Z", "ORGANIZER:mailto:ce\u{200B}o@example.com",
    ])) { parsed in
        #expect(parsed.primary.organizer == "")
    },
    .refused("an override-only invite has no series master", invite([
        "RECURRENCE-ID:20261019T100000Z", "DTSTART:20261019T110000Z",
    ])),
    .refused("one unparseable event refuses the whole invite", ics([
        "BEGIN:VCALENDAR", "METHOD:REQUEST",
        "BEGIN:VEVENT", "SUMMARY:no start", "END:VEVENT",
        "BEGIN:VEVENT", "DTSTART:20261012T100000Z", "SUMMARY:valid", "END:VEVENT",
        "END:VCALENDAR",
    ])),
    .refused("an unreadable DTEND refuses the invite", invite(["DTSTART:20261012T100000Z", "DTEND:garbage"])),
    .parses("an unknown zone on the end is reported too", invite([
        "DTSTART;TZID=Europe/Berlin:20261012T090000", "DTEND;TZID=Narnia:20261012T100000",
    ])) { parsed in
        #expect(parsed.primary.unknownZone == "Narnia")
    },
    .parses("a floating time is read in the local zone, with no guessed length", invite([
        "DTSTART:20261012T090000",
    ])) { parsed in
        #expect(parsed.primary.begin == iso("2026-10-12T07:00:00Z"))
        #expect(parsed.primary.end == parsed.primary.begin)
    },
    .parses("an all-day event is local midnight with an exclusive end", invite([
        "DTSTART;VALUE=DATE:20261012", "DTEND;VALUE=DATE:20261014",
    ])) { parsed in
        #expect(parsed.primary.allDay)
        #expect(parsed.primary.begin == iso("2026-10-11T22:00:00Z"))
        #expect(parsed.primary.end == iso("2026-10-13T22:00:00Z"))
    },
    .parses("an all-day event without an end lasts one day", invite(["DTSTART;VALUE=DATE:20261012"])) { parsed in
        #expect(parsed.primary.end == iso("2026-10-12T22:00:00Z"))
    },
    .parses("duration days are nominal across DST", invite([
        // Berlin leaves DST on 2026-10-25: that calendar day is 25 hours.
        "DTSTART;TZID=Europe/Berlin:20261024T100000", "DURATION:P1D",
    ])) { parsed in
        #expect(parsed.primary.end == iso("2026-10-25T09:00:00Z"))
    },
    .parses("a week duration is understood", invite(["DTSTART:20261012T100000Z", "DURATION:P1W"])) { parsed in
        #expect(parsed.primary.end == iso("2026-10-19T10:00:00Z"))
    },
    .parses("an empty DURATION is ignored, not fatal", invite(["DTSTART:20261012T100000Z", "DURATION:P"])) { parsed in
        #expect(parsed.primary.end == parsed.primary.begin)
    },
    .parses("an RRULE passes through", invite([
        "DTSTART:20261012T100000Z", "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10",
    ])) { parsed in
        #expect(parsed.primary.rrule == "FREQ=WEEKLY;BYDAY=MO;COUNT=10")
    },
    .parses("junk in an RRULE drops it", invite([
        "DTSTART:20261012T100000Z", "RRULE:FREQ=WEEKLY<script>",
    ])) { parsed in
        #expect(parsed.primary.rrule == "")
    },
    .parses("CANCEL is recognised and offers no Add", invite(method: "CANCEL", [
        "DTSTART:20261012T100000Z", "SEQUENCE:2",
    ])) { parsed in
        #expect(parsed.isCancelled)
        #expect(!parsed.isUpdate)
        #expect(!parsed.offersAdd)
    },
    .parses("REPLY offers no Add", invite(method: "REPLY", ["DTSTART:20261012T100000Z"])) { parsed in
        #expect(!parsed.offersAdd)
    },
    .parses("a raised SEQUENCE on a REQUEST is an update", invite([
        "DTSTART:20261012T100000Z", "SEQUENCE:3",
    ])) { parsed in
        #expect(parsed.isUpdate)
        #expect(parsed.primary.sequence == 3)
    },
    .parses("folded lines are unfolded", invite([
        "DTSTART:20261012T100000Z", "SUMMARY:A very long", "  title that folds", "DESCRIPTION:tab\r\n\tfolded",
    ])) { parsed in
        #expect(parsed.primary.summary == "A very long title that folds")
        #expect(parsed.primary.notes == "tabfolded")
    },
    .parses("a VALARM's properties do not override the event's", invite([
        "DTSTART:20261012T100000Z",
        "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder text", "END:VALARM",
        "DESCRIPTION:The real one",
    ])) { parsed in
        #expect(parsed.primary.notes == "The real one")
    },
    .parses("the series master is primary even when an override comes first", ics([
        "BEGIN:VCALENDAR", "METHOD:REQUEST",
        "BEGIN:VEVENT", "RECURRENCE-ID:20261019T100000Z", "DTSTART:20261019T110000Z", "SUMMARY:Moved instance", "END:VEVENT",
        "BEGIN:VEVENT", "DTSTART:20261012T100000Z", "SUMMARY:Weekly", "END:VEVENT",
        "END:VCALENDAR",
    ])) { parsed in
        #expect(parsed.primary.summary == "Weekly")
        #expect(parsed.events.count == 2)
    },
    .parses("an organizer without mailto: keeps the address", invite([
        "DTSTART:20261012T100000Z", "ORGANIZER:a@b.example",
    ])) { parsed in
        #expect(parsed.primary.organizer == "a@b.example")
    },
    .parses("a bidi override makes the organizer unusable", invite([
        "DTSTART:20261012T100000Z", "ORGANIZER:mailto:evil@x\u{202E}elpmaxe.com",
    ])) { parsed in
        #expect(parsed.primary.organizer == "")
    },
    .parses("bidi and control characters are stripped from text", invite([
        "DTSTART:20261012T100000Z", "SUMMARY:Pay\u{202E}gnp.exe\u{07} now",
    ])) { parsed in
        #expect(parsed.primary.summary == "Paygnp.exe now")
    },
    .parses("a missing METHOD is blank and still addable", ics([
        "BEGIN:VCALENDAR", "BEGIN:VEVENT", "DTSTART:20261012T100000Z", "END:VEVENT", "END:VCALENDAR",
    ])) { parsed in
        #expect(parsed.method == "")
        #expect(parsed.offersAdd)
    },
    .parses("a description is bounded", invite([
        "DTSTART:20261012T100000Z",
        "DESCRIPTION:" + String(repeating: "d", count: CalendarInviteLimits.maxDescriptionCharacters + 50),
    ])) { parsed in
        #expect(parsed.primary.notes.count == CalendarInviteLimits.maxDescriptionCharacters)
    },
    .refused("empty input", Data()),
    .refused("not a calendar at all", Data("not a calendar at all".utf8)),
    .refused("an unclosed VCALENDAR",
             Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20261012T100000Z\r\nEND:VEVENT\r\n".utf8)),
    .refused("a mismatched END",
             Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20261012T100000Z\r\nEND:VTODO\r\nEND:VCALENDAR\r\n".utf8)),
    .refused("month 13",
             Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20261399T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)),
    .refused("an unterminated quoted parameter",
             Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART;TZID=\"open:20261012T100000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)),
    .refused("an event with no start",
             Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:no start\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)),
    .refused("content after the calendar ends",
             Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\nBEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n".utf8)),
    .refused("a nested VCALENDAR",
             Data("BEGIN:VCALENDAR\r\nBEGIN:VCALENDAR\r\nEND:VCALENDAR\r\nEND:VCALENDAR\r\n".utf8)),
    .refused("oversize input, before parsing", invite([
        "DTSTART:20261012T100000Z", "X-PAD:" + String(repeating: "a", count: CalendarInviteLimits.maxInviteBytes),
    ])),
]

@Suite struct CalendarInviteParserTests {
    @Test(arguments: inviteParserTable)
    func parserRow(_ row: InviteCase) {
        let parsed = parse(row.data)
        if let check = row.check {
            guard let parsed else {
                Issue.record("\(row.name): expected a parse, got a refusal")
                return
            }
            check(parsed)
        } else {
            #expect(parsed == nil, "\(row.name): expected a refusal")
        }
    }

    /// Outlook writes Windows zone names; CLDR's table resolves them.
    @Test func outlookWindowsZonesGoThroughTheTable() throws {
        let data = invite(["DTSTART;TZID=\"Pacific Standard Time\":20261012T090000"])
        let parsed = try #require(parse(data, windows: WindowsTimeZones.ianaIdentifier(forWindowsName:)))
        #expect(parsed.primary.begin == iso("2026-10-12T16:00:00Z"))
        #expect(parsed.primary.unknownZone == nil)
        #expect(WindowsTimeZones.ianaIdentifier(forWindowsName: "W. Europe Standard Time") == "Europe/Berlin")
    }

    @Test func fiftyEventsParseAndFiftyOneDoNot() throws {
        func events(_ n: Int) -> [String] {
            (0..<n).flatMap { _ in ["BEGIN:VEVENT", "DTSTART:20261012T100000Z", "END:VEVENT"] }
        }
        let fifty = ics(["BEGIN:VCALENDAR"] + events(CalendarInviteLimits.maxEvents) + ["END:VCALENDAR"])
        let fiftyOne = ics(["BEGIN:VCALENDAR"] + events(CalendarInviteLimits.maxEvents + 1) + ["END:VCALENDAR"])
        #expect(try #require(parse(fifty)).events.count == CalendarInviteLimits.maxEvents)
        #expect(parse(fiftyOne) == nil)
    }

    /// A `text/calendar` part beats the `.ics` file beside it; the byte cap
    /// and an empty part both mean no download.
    @Test func theInvitePartIsChosenAndCapped() {
        let pdf = EmailAttachment(index: 0, name: "agenda.pdf", mimeType: "application/pdf", size: 10)
        let file = EmailAttachment(index: 1, name: "invite.ics", mimeType: "application/ics", size: 900)
        let part = EmailAttachment(index: 2, name: "invite.ics", mimeType: "text/calendar; method=REQUEST", size: 900)
        #expect(inviteAttachment([pdf, file, part]) == part)
        #expect(inviteAttachment([pdf, file]) == file)
        #expect(inviteAttachment([pdf]) == nil)
        var huge = part
        huge.size = CalendarInviteLimits.maxInviteBytes + 1
        #expect(inviteAttachment([huge]) == nil)
        var empty = part
        empty.size = 0
        #expect(inviteAttachment([empty]) == nil)
    }
}

// MARK: - RSVP

private let now = iso("2026-10-10T08:09:10Z")

private let request = [
    "UID:040000008200E00074C5B7101A82E008@outlook.example",
    "SEQUENCE:4",
    "DTSTART:20261012T100000Z",
    "SUMMARY:Quarterly\\nplanning",
    "ORGANIZER;CN=Boss:mailto:boss@example.com",
    "ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:me@example.com",
    "ATTENDEE;CN=\"Me, Alias\";RSVP=TRUE:MAILTO:Alias@Example.com",
]

private func requestInvite(_ event: [String] = request, method: String = "REQUEST") throws -> CalendarInvite {
    try #require(parse(invite(method: method, event), zone: utc))
}

/// The override VEVENT of a series, parsed beside its master.
private func override(_ extra: String) throws -> CalendarEvent {
    let data = ics(["BEGIN:VCALENDAR", "METHOD:REQUEST", "BEGIN:VEVENT"] + request
        + ["END:VEVENT", "BEGIN:VEVENT"] + request + [extra] + ["END:VEVENT", "END:VCALENDAR"])
    return try #require(parse(data, zone: utc)?.events.last)
}

private func replacing(_ prefix: String, with line: String?) -> [String] {
    request.filter { !$0.hasPrefix(prefix) } + [line].compactMap { $0 }
}

private func unfolded(_ ics: String) -> String { ics.replacingOccurrences(of: "\r\n ", with: "") }

/// KyPost-Server's `mailmsg.CalendarReply` checks, ported: what the relay
/// refuses with 400.
private func expectRelayAccepts(_ ics: String) {
    #expect(ics.utf8.count <= 64 * 1024)
    #expect(ics.hasSuffix("\r\n"))
    // Not `dropLast(2)`: "\r\n" is one Character in Swift.
    let lines = Array(ics.components(separatedBy: "\r\n").dropLast())
    #expect(lines.first == "BEGIN:VCALENDAR")
    var stack: [String] = []
    var methods = 0
    var events = 0
    for (index, line) in lines.enumerated() {
        #expect(!line.isEmpty)
        #expect(!line.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F })
        #expect(line.utf8.count <= 75, "unfolded line: \(line)")
        if line.hasPrefix(" ") { continue }
        #expect(index == 0 || !stack.isEmpty)
        let name = String(line.prefix { $0 != ":" && $0 != ";" }).uppercased()
        let value = line.split(separator: ":", maxSplits: 1).last.map(String.init)?.uppercased() ?? ""
        switch name {
        case "BEGIN":
            stack.append(value)
            if value == "VEVENT" { events += 1 }
        case "END":
            #expect(stack.popLast() == value)
        case "METHOD":
            #expect(stack.count == 1)
            #expect(value == "REPLY")
            methods += 1
        default:
            break
        }
    }
    #expect(stack.isEmpty)
    #expect(methods == 1)
    #expect(events == 1)
}

@Suite struct CalendarRsvpTests {
    @Test func aReplyCopiesUidAndSequenceAndAnswersAsTheListedAddress() throws {
        let event = try requestInvite().primary
        let attendee = try #require(rsvpAttendee(event, accountAddresses: ["primary@example.com", "alias@example.com"]))
        #expect(attendee == "alias@example.com")

        let draft = try #require(rsvpDraft(event, attendee: attendee, answer: .accepted, now: now))
        expectRelayAccepts(draft.ics)
        let lines = unfolded(draft.ics).components(separatedBy: "\r\n")
        #expect(lines.contains("UID:040000008200E00074C5B7101A82E008@outlook.example"))
        #expect(lines.contains("SEQUENCE:4"))
        #expect(lines.contains("DTSTAMP:20261010T080910Z"))
        #expect(lines.contains("ORGANIZER:mailto:boss@example.com"))
        #expect(lines.contains("ATTENDEE;PARTSTAT=ACCEPTED:mailto:alias@example.com"))
        #expect(!lines.contains { $0.hasPrefix("RECURRENCE-ID") })
        #expect(draft.to == "boss@example.com")
        #expect(draft.subject == "Accepted: Quarterly planning")
    }

    /// The request body never carries a PGP flag beside `calendarReply`.
    @Test func theRelayRequestIsPlainAndUnsigned() throws {
        let event = try requestInvite().primary
        let draft = try #require(rsvpDraft(event, attendee: "alias@example.com", answer: .declined, now: now, sendAs: "alias@example.com"))
        let json = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(RelaySendRequest(calendarReply: draft))
        ) as? [String: Any])
        #expect(json["encrypt"] == nil)
        #expect(json["sign"] == nil)
        #expect(json["allowPickupFallback"] == nil)
        #expect(json["mode"] as? String == "plain")
        #expect(json["from"] as? String == "alias@example.com")
        #expect((json["calendarReply"] as? [String: Any])?["ics"] as? String == draft.ics)
        // An ordinary send carries neither field.
        let plain = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(RelaySendRequest(
            from: OutgoingEmail(to: ["a@example.com"], cc: [], bcc: [], subject: "s", body: "b")
        ))) as? [String: Any])
        #expect(plain["calendarReply"] == nil)
        #expect(plain["from"] == nil)
    }

    @Test func ourOwnParserReadsTheReplyBack() throws {
        let event = try requestInvite().primary
        let reply = try #require(rsvpDraft(event, attendee: "me@example.com", answer: .declined, now: now)).ics
        // The card parser insists on DTSTART, which a REPLY need not carry.
        let withStart = reply.replacingOccurrences(of: "END:VEVENT", with: "DTSTART:20261012T100000Z\r\nEND:VEVENT")
        let parsed = try #require(parse(Data(withStart.utf8), zone: utc))
        #expect(parsed.method == "REPLY")
        #expect(parsed.primary.uid == event.uid)
        #expect(parsed.primary.attendees == ["me@example.com"])
    }

    @Test(arguments: Rsvp.allCases)
    func eachAnswerIsItsPartstat(_ answer: Rsvp) throws {
        let event = try requestInvite().primary
        let ics = unfolded(try #require(rsvpDraft(event, attendee: "me@example.com", answer: answer, now: now)).ics)
        #expect(ics.contains("ATTENDEE;PARTSTAT=\(answer.rawValue):mailto:me@example.com"))
    }

    /// The REPLY carries no VTIMEZONE, so a zoned RECURRENCE-ID becomes UTC.
    @Test(arguments: [
        ("RECURRENCE-ID;TZID=Europe/Berlin:20261019T100000", "RECURRENCE-ID:20261019T080000Z"),
        ("RECURRENCE-ID:20261019T100000Z", "RECURRENCE-ID:20261019T100000Z"),
        ("RECURRENCE-ID;VALUE=DATE:20261019", "RECURRENCE-ID;VALUE=DATE:20261019"),
        ("RECURRENCE-ID;X-JUNK=1:20261019T100000", "RECURRENCE-ID:20261019T100000"),
    ])
    func aRecurrenceIdIsRestatedWithoutATzid(_ line: String, _ restated: String) throws {
        let reply = unfolded(try #require(rsvpDraft(try override(line), attendee: "me@example.com", answer: .tentative, now: now)).ics)
        #expect(reply.contains("\r\n\(restated)\r\n"))
    }

    @Test func anUnrestatableRecurrenceIdOrSequenceMeansNoRsvp() throws {
        #expect(!(try override("RECURRENCE-ID;TZID=Narnia:20261019T100000")).canReply)
        #expect(!(try override("RECURRENCE-ID:garbage")).canReply)
        let badSequence = request.map { $0.hasPrefix("SEQUENCE") ? "SEQUENCE:99999999999" : $0 }
        #expect(!(try requestInvite(badSequence)).offersRsvp(listedMethod: "REQUEST"))
    }

    @Test func theUidIsCopiedVerbatimIncludingSurroundingSpaces() throws {
        let event = try requestInvite(replacing("UID", with: "UID: event@example.com ")).primary
        #expect(event.uid == " event@example.com ")
        let lines = unfolded(try #require(rsvpDraft(event, attendee: "me@example.com", answer: .accepted, now: now)).ics)
            .components(separatedBy: "\r\n")
        #expect(lines.contains("UID: event@example.com "))
        // Blank is no UID at all.
        #expect(!(try requestInvite(replacing("UID", with: "UID:   "))).offersRsvp(listedMethod: "REQUEST"))
    }

    @Test func aLongUidIsFoldedWithoutSplittingUtf8() throws {
        let uid = String(repeating: "é", count: 300) + "@example.com"
        let event = try requestInvite(replacing("UID", with: "UID:\(uid)")).primary
        let ics = try #require(rsvpDraft(event, attendee: "me@example.com", answer: .accepted, now: now)).ics
        expectRelayAccepts(ics)
        #expect(unfolded(ics).contains("UID:\(uid)"))
        for line in ics.components(separatedBy: "\r\n") {
            // Every physical line decodes on its own.
            #expect(String(validating: Array(line.utf8), as: UTF8.self) != nil)
        }
    }

    @Test func anAliasListedPastFiveHundredAttendeesIsStillFound() throws {
        let others = (1...500).map { "ATTENDEE:mailto:guest\($0)@example.com" }
        let event = try requestInvite(request + others + ["ATTENDEE:mailto:late-alias@example.com"]).primary
        #expect(rsvpAttendee(event, accountAddresses: ["primary@example.com", "late-alias@example.com"]) == "late-alias@example.com")
    }

    @Test func anUnlistedUserFallsBackToThePrimaryAddress() throws {
        let event = try requestInvite().primary
        #expect(rsvpAttendee(event, accountAddresses: ["primary@example.com", "other@example.com"]) == "primary@example.com")
    }

    @Test func noUsableAccountAddressMeansNoReply() throws {
        let event = try requestInvite().primary
        #expect(rsvpAttendee(event, accountAddresses: []) == nil)
        // A relay-supplied address carrying CRLF could inject an ICS line.
        #expect(rsvpAttendee(event, accountAddresses: ["me@example.com\r\nATTENDEE:mailto:x@y"]) == nil)
        #expect(rsvpDraft(event, attendee: "bad address", answer: .accepted, now: now) == nil)
    }

    @Test func rsvpIsOfferedOnlyForAnAnswerableRequestFromANewEnoughRelay() throws {
        #expect(try requestInvite().offersRsvp(listedMethod: "REQUEST"))
        // An older relay lists no calendarMethod and would drop calendarReply.
        #expect(!(try requestInvite()).offersRsvp(listedMethod: ""))
        #expect(!(try requestInvite(method: "CANCEL")).offersRsvp(listedMethod: "CANCEL"))
        #expect(!(try requestInvite(method: "PUBLISH")).offersRsvp(listedMethod: "PUBLISH"))
        #expect(!(try requestInvite(replacing("ORGANIZER", with: nil))).offersRsvp(listedMethod: "REQUEST"))
        #expect(!(try requestInvite(replacing("UID", with: nil))).offersRsvp(listedMethod: "REQUEST"))
    }

    @Test func attendeesAreCollectedNotJustTheFirst() throws {
        #expect(try requestInvite().primary.attendees == ["me@example.com", "Alias@Example.com"])
    }

    @Test func aNewRevisionIsANewKey() throws {
        let seq4 = try requestInvite().primary
        let seq5 = try requestInvite(request.map { $0.hasPrefix("SEQUENCE") ? "SEQUENCE:5" : $0 }).primary
        #expect(rsvpKey(seq4) != rsvpKey(seq5))
        #expect(rsvpKey(seq4) != rsvpKey(try override("RECURRENCE-ID:20261019T100000Z")))
    }

    /// Only a definite refusal is safe to retry.
    @Test func onlyADefiniteRefusalIsRefused() {
        #expect(rsvpRefusedBeforeSending(NetworkError.badRequest(body: "invalid calendar reply: x")))
        #expect(rsvpRefusedBeforeSending(NetworkError.rateLimited(retryAfter: 10)))
        #expect(rsvpRefusedBeforeSending(NetworkError.unauthorized))
        #expect(rsvpRefusedBeforeSending(NetworkError.certificateMismatch))
        #expect(!rsvpRefusedBeforeSending(NetworkError.transport(description: "timeout")))
        #expect(!rsvpRefusedBeforeSending(NetworkError.server(statusCode: 502)))
        #expect(!rsvpRefusedBeforeSending(NetworkError.decoding(description: "x")))
    }

    /// Success only on the JSON acknowledgement.
    @Test func onlyTheAcknowledgementIsAnRsvp() throws {
        let acked = try JSONDecoder().decode(RelaySendResponse.self, from: Data(#"{"ok":true,"calendarReply":true}"#.utf8))
        let ignored = try JSONDecoder().decode(RelaySendResponse.self, from: Data(#"{"ok":true,"sentSaved":true}"#.utf8))
        #expect(acked.calendarReply == true)
        #expect(ignored.calendarReply == nil)
    }

    @Test func theListedCalendarMethodIsDecoded() throws {
        let dto = try JSONDecoder().decode(RelayAttachmentDTO.self, from: Data(
            #"{"index":2,"name":"invite.ics","mimeType":"text/calendar","size":900,"calendarMethod":"REQUEST"}"#.utf8
        ))
        #expect(dto.toDomain().calendarMethod == "REQUEST")
        let old = try JSONDecoder().decode(RelayAttachmentDTO.self, from: Data(#"{"index":0}"#.utf8))
        #expect(old.toDomain().calendarMethod == "")
    }
}

// MARK: - Tracker

@MainActor
@Suite struct RsvpTrackerTests {
    private func key() throws -> String { rsvpKey(try requestInvite().primary) }

    @Test func aSentRevisionCannotBeAnsweredAgainButANewOneCan() throws {
        let tracker = RsvpTracker(center: NotificationCenter())
        let seq4 = try key()
        let seq5 = rsvpKey(try requestInvite(request.map { $0.hasPrefix("SEQUENCE") ? "SEQUENCE:5" : $0 }).primary)
        #expect(tracker.begin(seq4))
        #expect(!tracker.begin(seq4))
        tracker.finish(seq4, result: .sent)
        #expect(!tracker.canAnswer(seq4))
        #expect(tracker.canAnswer(seq5))
    }

    /// Only a definite refusal re-arms the buttons.
    @Test(arguments: [(RsvpResult.refused, true), (.sent, false), (.sentAsPlainMail, false), (.maybeSent, false)])
    func onlyARefusalReArms(_ result: RsvpResult, _ rearmed: Bool) throws {
        let tracker = RsvpTracker(center: NotificationCenter())
        let key = try key()
        #expect(tracker.begin(key))
        tracker.finish(key, result: result)
        #expect(tracker.canAnswer(key) == rearmed)
    }

    @Test func anUnsureSendStaysLockedUntilAFreshOpen() throws {
        let tracker = RsvpTracker(center: NotificationCenter())
        let key = try key()
        for result in [RsvpResult.maybeSent, .sentAsPlainMail] {
            #expect(tracker.begin(key))
            tracker.finish(key, result: result)
            tracker.opened(key, freshOpen: false)
            #expect(!tracker.canAnswer(key))
            tracker.opened(key, freshOpen: true)
            #expect(tracker.canAnswer(key))
        }
        #expect(tracker.begin(key))
        tracker.finish(key, result: .sent)
        tracker.opened(key, freshOpen: true)
        #expect(!tracker.canAnswer(key), "a confirmed RSVP stays sent")
        tracker.cancel(key)
        #expect(!tracker.canAnswer(key), "cancel releases only a pending send")
    }

    /// Unpair or wipe: the session advances and the tracker empties; a
    /// completion from the old session records nothing.
    @Test func aCompletionFromAnEndedSessionIsDropped() throws {
        let center = NotificationCenter()
        let tracker = RsvpTracker(center: center)
        let key = try key()
        let session = tracker.session
        #expect(tracker.begin(key))
        center.post(name: .kyPostSessionReset, object: nil)
        #expect(!tracker.complete(key, result: .sent, message: "RSVP sent", session: session))
        #expect(tracker.phases.isEmpty)
        #expect(tracker.messages.isEmpty)
        #expect(tracker.canAnswer(key))

        #expect(tracker.begin(key))
        #expect(tracker.complete(key, result: .sent, session: tracker.session))
        #expect(!tracker.canAnswer(key))
    }
}

// MARK: - Card model

@MainActor
@Suite(.serialized) struct InviteCardModelTests {
    private let account = MailAccountBinding(Pairing(
        sub: "me@example.com", deviceSecret: "s", srv: "https://relay.example.com",
        pairingToken: "t", pairedAt: Date(timeIntervalSince1970: 0)
    ))

    private func listing(method: String = "REQUEST") -> [EmailAttachment] {
        [EmailAttachment(index: 0, name: "invite.ics", mimeType: "text/calendar", size: 900, calendarMethod: method)]
    }

    private func model(
        tracker: RsvpTracker,
        addresses: [String]? = ["me@example.com"],
        sent: Box<[CalendarReplyDraft]> = Box([]),
        outcome: (RsvpResult, String)? = (.sent, "")
    ) -> InviteCardModel {
        let account = self.account
        return InviteCardModel(
            tracker: tracker,
            accountAddresses: { addresses },
            currentAccount: { account },
            send: { draft, _ in
                sent.value.append(draft)
                return outcome.map { (result: $0.0, reason: $0.1) }
            },
            now: { now }
        )
    }

    private func load(_ model: InviteCardModel, method: String = "REQUEST") async {
        let data = invite(request)
        await model.load(listing: listing(method: method)) { _ in data }
    }

    @Test func aConfirmedRsvpSendsOnceAndLandsInTheTracker() async throws {
        let tracker = RsvpTracker(center: NotificationCenter())
        let sent = Box<[CalendarReplyDraft]>([])
        let subject = model(tracker: tracker, sent: sent)
        await load(subject)
        #expect(subject.offersRsvp)

        await subject.requestRsvp(.accepted, senderEmail: "boss@example.com")
        let pending = try #require(subject.pendingRsvp)
        #expect(pending.message.contains("unencrypted and unsigned"))
        #expect(!pending.message.contains("not the sender"))
        // A second tap while the first is pending offers nothing.
        #expect(!subject.canAnswer)

        await subject.confirmRsvp(pending)?.value
        // A dismissal racing the button must not release a sent revision.
        subject.rsvpPromptDismissed(pending)
        await Task.yield()
        #expect(sent.value.count == 1)
        #expect(subject.rsvpMessage == "RSVP sent")
        #expect(!subject.canAnswer)
        #expect(subject.confirmRsvp(pending) == nil)
    }

    @Test func backingOutReleasesTheRevision() async throws {
        let tracker = RsvpTracker(center: NotificationCenter())
        let subject = model(tracker: tracker)
        await load(subject)
        await subject.requestRsvp(.declined, senderEmail: "someone@else.example")
        let pending = try #require(subject.pendingRsvp)
        #expect(pending.message.contains("not the sender"))
        subject.rsvpPromptDismissed(pending)
        await Task.yield()
        await Task.yield()
        #expect(subject.canAnswer)
    }

    @Test func noAddressMeansNoRsvp() async {
        let tracker = RsvpTracker(center: NotificationCenter())
        let subject = model(tracker: tracker, addresses: nil)
        await load(subject)
        await subject.requestRsvp(.accepted, senderEmail: "boss@example.com")
        #expect(subject.pendingRsvp == nil)
        #expect(subject.rsvpProblem != nil)
        #expect(subject.canAnswer)
    }

    /// A send confirmed before a wipe or unpair does no I/O after it.
    @Test func anEndedSessionSendsNothing() async throws {
        let center = NotificationCenter()
        let tracker = RsvpTracker(center: center)
        let sent = Box<[CalendarReplyDraft]>([])
        let subject = model(tracker: tracker, sent: sent)
        await load(subject)
        await subject.requestRsvp(.accepted, senderEmail: "boss@example.com")
        let pending = try #require(subject.pendingRsvp)
        center.post(name: .kyPostSessionReset, object: nil)
        await subject.confirmRsvp(pending)?.value
        #expect(sent.value.isEmpty)
        #expect(subject.rsvpMessage == nil)
    }

    @Test func anOldRelayGetsNoButtons() async {
        let subject = model(tracker: RsvpTracker(center: NotificationCenter()))
        await load(subject, method: "")
        #expect(subject.invite != nil)
        #expect(!subject.offersRsvp)
    }

    /// Under Hostile Location Protection a tap asks first; nothing is handed
    /// off until the user confirms.
    @Test func hostileLocationProtectionConfirmsBeforeAnyHandoff() async {
        let subject = model(tracker: RsvpTracker(center: NotificationCenter()))
        await load(subject)
        await subject.requestAdd(hostileLocationProtection: true)
        #expect(subject.pendingHandoff != nil)
        #expect(subject.handoffMessage == nil)
    }

    @Test func aCancelledInviteOffersNoAdd() async {
        let subject = model(tracker: RsvpTracker(center: NotificationCenter()))
        let data = invite(method: "CANCEL", request)
        await subject.load(listing: listing(method: "CANCEL")) { _ in data }
        await subject.requestAdd(hostileLocationProtection: true)
        #expect(subject.pendingHandoff == nil)
    }
}

// MARK: - Wording and handoff

@Suite struct InviteWordingTests {
    @Test func noticesComeInOrderAndNameTheOrganizer() throws {
        let parsed = try #require(parse(invite(method: "CANCEL", [
            "DTSTART;TZID=Narnia:20261012T090000", "ORGANIZER:mailto:boss@example.com", "SEQUENCE:1",
        ])))
        let notices = inviteNotices(parsed, senderEmail: "eve@example.com", phishing: true)
        #expect(notices.count == 4)
        #expect(notices[0].contains("phishing"))
        #expect(notices[1].contains("boss@example.com"))
        #expect(notices[2].contains("cancelled"))
        #expect(notices[3].contains("Narnia"))
        #expect(inviteNotices(parsed, senderEmail: "BOSS@example.com", phishing: false).count == 2)
    }

    @Test func whenTextIsInTheViewersZone() throws {
        let event = try #require(parse(invite(["DTSTART:20261012T130000Z", "DTEND:20261012T140000Z"]))).primary
        let us = Locale(identifier: "en_US")
        let berlinText = inviteWhenText(event, zone: berlin, locale: us).replacingOccurrences(of: "\u{202F}", with: " ")
        let newYork = inviteWhenText(event, zone: TimeZone(identifier: "America/New_York")!, locale: us)
            .replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(berlinText.contains("3:00 PM") && berlinText.hasSuffix("4:00 PM"))
        #expect(newYork.contains("9:00 AM") && newYork.hasSuffix("10:00 AM"))
    }

    @Test func allDayWhenTextShowsTheInclusiveRange() throws {
        let us = Locale(identifier: "en_US")
        let one = try #require(parse(invite(["DTSTART;VALUE=DATE:20261012"]))).primary
        #expect(inviteWhenText(one, zone: berlin, locale: us) == "Oct 12, 2026")
        let two = try #require(parse(invite(["DTSTART;VALUE=DATE:20261012", "DTEND;VALUE=DATE:20261014"]))).primary
        #expect(inviteWhenText(two, zone: berlin, locale: us) == "Oct 12, 2026 – Oct 13, 2026")
    }

    @Test func outcomesHaveTheirOwnSentences() {
        #expect(rsvpOutcomeMessage(.sent, reason: "") == "RSVP sent")
        #expect(rsvpOutcomeMessage(.sentAsPlainMail, reason: "").contains("update your server"))
        #expect(rsvpOutcomeMessage(.refused, reason: "bad").contains("not sent: bad"))
        #expect(rsvpOutcomeMessage(.maybeSent, reason: "timeout").contains("Check your Sent folder"))
    }

    @Test(arguments: [
        ("FREQ=WEEKLY;BYDAY=MO,WE;COUNT=10", true),
        ("FREQ=MONTHLY;BYDAY=-1FR;INTERVAL=2", true),
        ("FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=1;UNTIL=20301231", true),
        ("FREQ=DAILY;UNTIL=20261231T235959Z;WKST=MO", true),
        ("FREQ=HOURLY", false),
        ("FREQ=DAILY;BYHOUR=9", false),
        ("FREQ=DAILY;COUNT=3;UNTIL=20261231", false),
        ("FREQ=WEEKLY;BYDAY=XX", false),
        ("FREQ=DAILY;UNTIL=20260231", false),
        ("COUNT=3", false),
    ])
    func onlyExpressibleRulesMapToEventKit(_ rrule: String, _ expressible: Bool) {
        #expect((RecurrenceSpec(rrule, zone: berlin) != nil) == expressible)
    }

    @Test func aRecurrenceSpecCarriesItsParts() throws {
        let spec = try #require(RecurrenceSpec("FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=6", zone: berlin))
        #expect(spec.frequency == .monthly)
        #expect(spec.interval == 2)
        #expect(spec.days == [RecurrenceSpec.Day(weekday: 6, week: -1)])
        #expect(spec.end == .count(6))
        let rule = spec.rule()
        #expect(rule.interval == 2)
        #expect(rule.recurrenceEnd?.occurrenceCount == 6)
    }
}
