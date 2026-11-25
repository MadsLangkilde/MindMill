import Foundation
import Testing
@testable import KBCore

struct TranscriptTimesTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        return c
    }

    let en = Locale(identifier: "en_GB")

    func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f.date(from: s)!
    }

    @Test func dayTitlesGoFromTodayToDates() {
        let now = date("2026-11-25T14:00:00")
        #expect(TranscriptTimes.dayTitle(date("2026-11-25T08:00:00"), now: now, calendar: calendar, locale: en) == "Today")
        #expect(TranscriptTimes.dayTitle(date("2026-11-24T23:30:00"), now: now, calendar: calendar, locale: en) == "Yesterday")
        #expect(TranscriptTimes.dayTitle(date("2026-11-21T10:00:00"), now: now, calendar: calendar, locale: en) == "Saturday")
        #expect(TranscriptTimes.dayTitle(date("2026-11-10T10:00:00"), now: now, calendar: calendar, locale: en) == "Tuesday 10 November")
        #expect(TranscriptTimes.dayTitle(date("2025-12-30T10:00:00"), now: now, calendar: calendar, locale: en) == "Tuesday, 30 December 2025")
    }

    @Test func aHeadingPerDayAndOneTimePerRun() {
        let now = date("2026-11-25T14:00:00")
        let entries: [TranscriptTimes.Entry] = [
            .init(at: nil, side: .user),
            .init(at: date("2026-11-24T16:05:00"), side: .user),
            .init(at: date("2026-11-24T16:05:20"), side: .other),
            .init(at: date("2026-11-24T16:05:40"), side: .reply),
            .init(at: date("2026-11-24T16:05:50"), side: .reply),
            .init(at: date("2026-11-24T16:07:00"), side: .reply),
            .init(at: date("2026-11-25T09:12:00"), side: .user),
        ]
        let marks = TranscriptTimes.marks(entries, now: now, calendar: calendar, locale: en)
        #expect(marks.map(\.day) == [nil, "Yesterday", nil, nil, nil, nil, "Today"])
        #expect(marks.map(\.time) == [nil, "16:05", nil, "16:05", nil, "16:07", "09:12"])
    }

    @Test func clockStyleFollowsTheLocaleAndStepsShowASpan() {
        let us = Locale(identifier: "en_US")
        let us12 = TranscriptTimes.time(date("2026-11-25T14:05:00"), locale: us, calendar: calendar)
        #expect(us12.hasPrefix("2:05") && us12.hasSuffix("PM"))
        let span = TranscriptTimes.span([date("2026-11-25T14:12:00"), date("2026-11-25T14:05:00")], locale: en, calendar: calendar)
        #expect(span == "14:05–14:12")
        #expect(TranscriptTimes.span([], locale: en, calendar: calendar) == nil)
    }

    @Test func messagesKeepTheirTimeThroughSaving() throws {
        let at = date("2026-11-25T09:12:00")
        let record = SessionRecord.Message(role: "user", text: "Hi", at: at)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(SessionRecord.Message.self, from: encoder.encode(record)).at == at)
        let old = try decoder.decode(SessionRecord.Message.self, from: Data(#"{"role":"user","text":"Hi"}"#.utf8))
        #expect(old.at == nil)
    }
}
