import Testing
@testable import KBCore

struct MeetingDaysTests {
    let today = "2026-11-12"

    @Test func pillsRunFromEarlierToAll() {
        let titles = MeetingDays.pills(today: today).map(\.title)
        #expect(titles.prefix(4) == ["Earlier", "Yesterday", "Today", "Tomorrow"])
        #expect(titles[4] == "Sat 14")
        #expect(titles.suffix(2) == ["Later", "All"])
    }

    @Test func eachPillCoversItsDays() {
        let p = MeetingDays.pills(today: today)
        let earlier = p.first { $0.key == "earlier" }!
        #expect(earlier.contains("2026-11-10"))
        #expect(!earlier.contains("2026-11-11"))
        #expect(earlier.contains(""))
        #expect(MeetingDays.pill("today", today: today).contains("2026-11-12"))
        #expect(!MeetingDays.pill("today", today: today).contains("2026-11-13"))
        let later = p.first { $0.key == "later" }!
        #expect(!later.contains("2026-11-18"))
        #expect(later.contains("2026-11-19"))
        #expect(p.first { $0.key == "all" }!.contains("2020-01-01"))
    }

    @Test func aStaleDayFallsBackToToday() {
        #expect(MeetingDays.pill("2026-10-01", today: today).key == today)
    }

    @Test func pastDaysListNewestFirst() {
        #expect(MeetingDays.newestFirst(MeetingDays.pill("earlier", today: today), today: today))
        #expect(MeetingDays.newestFirst(MeetingDays.pill("2026-11-11", today: today), today: today))
        #expect(!MeetingDays.newestFirst(MeetingDays.pill(today, today: today), today: today))
    }
}

struct MonthGridTests {
    @Test func monthsRunInWholeWeeksFromMonday() {
        let days = MonthGrid.days(month: "2026-11-13")
        // 1 November 2026 is a Sunday: the grid starts on Monday 26 October and ends on Sunday 6 December.
        #expect(days.first == "2026-10-26")
        #expect(days.last == "2026-12-06")
        #expect(days.count % 7 == 0)
        #expect(days.contains("2026-11-30"))
        #expect(MonthGrid.days(month: "2027-02-01").count == 28) // February 2027 starts on a Monday
    }

    @Test func monthsWeeksAndTitles() {
        #expect(MonthGrid.month(of: "2026-11-13") == "2026-11-01")
        #expect(MonthGrid.shift(month: "2026-12-15", by: 1) == "2027-01-01")
        #expect(MonthGrid.shift(month: "2026-01-31", by: -1) == "2025-12-01")
        #expect(MonthGrid.week(of: "2026-11-15") == ("2026-11-09", "2026-11-15"))
        #expect(MonthGrid.weekNumber("2026-11-13") == 46)
        #expect(MonthGrid.title(month: "2026-11-13") == "November 2026")
        #expect(MonthGrid.dayNumber("2026-11-03") == "3")
    }
}
