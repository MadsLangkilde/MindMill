import Foundation
import Testing
@testable import KBCore

@Suite struct SuggestionTests {
    @Test func pickingMovesAQuestionToItsGroupAndBack() {
        var suggested = QuestionList(markdown: "- [ ] Loose one\n\n### Upload\n- [ ] Who signs off?\n- [ ] Is retry per device?\n\n### Risks\n- [ ] Legal?")
        var questions = QuestionList(markdown: "- [ ] My own")
        suggested.move(suggested.questions.first { $0.text == "Who signs off?" }!.id, to: &questions)
        #expect(questions.markdown == "- [ ] My own\n\n### Upload\n- [ ] Who signs off?")
        let legal = suggested.questions.first { $0.text == "Legal?" }!
        suggested.move(legal.id, to: &questions)
        #expect(suggested.markdown == "- [ ] Loose one\n\n### Upload\n- [ ] Is retry per device?")
        let upload = suggested.questions.first { $0.text == "Is retry per device?" }!
        suggested.move(upload.id, to: &questions)
        #expect(questions.markdown == "- [ ] My own\n\n### Upload\n- [ ] Who signs off?\n- [ ] Is retry per device?\n\n### Risks\n- [ ] Legal?")
        // Back again: an ungrouped question goes before the first heading.
        questions.move(0, to: &suggested)
        #expect(suggested.markdown == "- [ ] Loose one\n- [ ] My own")
        #expect(questions.questions.map(\.group) == ["Upload", "Upload", "Risks"])
    }

    @Test func anAnswerMovesWithItsQuestion() {
        var a = QuestionList(markdown: "- [x] Q\n  - Answer: yes\n- [ ] R")
        var b = QuestionList()
        a.move(0, to: &b)
        #expect(b.markdown == "- [x] Q\n  - Answer: yes")
        #expect(a.markdown == "- [ ] R")
    }

    @Test func ownQuestionGoesAboveGroups() {
        var q = QuestionList(markdown: "### Upload\n- [ ] Who?")
        q.insert([.task(done: false, text: "Mine")], group: nil)
        #expect(q.markdown == "- [ ] Mine\n\n### Upload\n- [ ] Who?")
    }

    @Test func unpreparedMeetingTakesAllSuggestionsUnderSuggested() {
        var questions = QuestionList(markdown: "- [ ] Mine")
        questions.addSuggestions(QuestionList(markdown: "- [ ] Loose\n\n### Went well\n- [ ] Releases\n**Talking points**\n- Auth lands soon"))
        #expect(questions.markdown == "- [ ] Mine\n\n### Suggested\n- [ ] Loose\n\n### Suggested · Went well\n- [ ] Releases\n\n### Suggested · Talking points\n- Auth lands soon")
        #expect(questions.questions.map { QuestionList.isSuggested(group: $0.group) } == [false, true, true])
        #expect(questions.questions.map { QuestionList.displayGroup($0.group) } == [nil, nil, "Went well"])
        var empty = QuestionList(markdown: "- [ ] Mine")
        empty.addSuggestions(QuestionList(markdown: "### Only a heading"))
        #expect(empty.markdown == "- [ ] Mine")
    }

    @Test func suggestedSectionSitsBetweenPrepAndQuestions() {
        let body = "\n## Prep\nctx\n\n## Questions\n- [ ] Mine\n"
        let out = MeetingBody.setting(.suggested, to: "- [ ] Claude's", in: body)
        #expect(out == "\n## Prep\nctx\n\n## Suggested questions\n\n- [ ] Claude's\n\n## Questions\n- [ ] Mine\n")
        #expect(MeetingBody.section(.questions, in: out) == "- [ ] Mine")
        #expect(MeetingBody.removing(.suggested, in: out) == body)
    }
}

@Suite struct DaySectionTests {
    @Test func pastAndFutureLabels() {
        let today = "2026-11-11" // a Wednesday
        #expect(DaySections.label("2026-11-11", today: today, direction: .past) == "Today")
        #expect(DaySections.label("2026-11-10", today: today, direction: .past) == "Yesterday")
        #expect(DaySections.label("2026-11-06", today: today, direction: .past) == "Friday 6 Nov")
        #expect(DaySections.label("2026-11-04", today: today, direction: .past) == "Older")
        #expect(DaySections.label("", today: today, direction: .past) == "No date")
        #expect(DaySections.label("2026-11-12", today: today, direction: .future) == "Tomorrow")
        #expect(DaySections.label("2026-11-17", today: today, direction: .future) == "Tuesday 17 Nov")
        #expect(DaySections.label("2026-11-18", today: today, direction: .future) == "Later")
        let groups = DaySections.group(["2026-11-11", "2026-11-11", "2026-11-10", "2026-10-01", "2026-09-01"], date: { $0 }, today: today)
        #expect(groups.map(\.title) == ["Today", "Yesterday", "Older"])
        #expect(groups.map(\.items.count) == [2, 1, 2])
    }

    @Test func nextWorkingDaySkipsTheWeekend() {
        #expect(KBDate.nextWorkingDay(after: "2026-11-11") == "2026-11-12")
        #expect(KBDate.nextWorkingDay(after: "2026-11-13") == "2026-11-16")
    }

    private func meeting(_ fm: String) -> KBEntry {
        KBEntry(id: EntryID("alpha/meetings/2026-11-11-sync")!, url: URL(fileURLWithPath: "/x.md"), text: "---\ntitle: Sync\n\(fm)\n---\n")
    }

    @Test func onlyUnhandledMeetingsCount() {
        let today = "2026-11-11"
        #expect(meeting("date: 2026-11-11\nstatus: prepared").meetingNeedsAttention(today: today))
        #expect(!meeting("date: 2026-11-11\nstatus: prepared\nready: true").meetingNeedsAttention(today: today))
        #expect(meeting("date: 2026-11-12\nstatus: scheduled").meetingNeedsAttention(today: today))
        #expect(!meeting("date: 2026-11-20\nstatus: scheduled").meetingNeedsAttention(today: today))
        #expect(!meeting("date: 2026-11-10\nstatus: scheduled").meetingNeedsAttention(today: today))
        #expect(meeting("date: 2026-11-03\nstatus: review").meetingNeedsAttention(today: today))
        #expect(!meeting("date: 2026-11-11\nstatus: filed").meetingNeedsAttention(today: today))
        #expect(!meeting("date: 2026-11-11\nstatus: cancelled").meetingNeedsAttention(today: today))
    }

    @Test func todaysMeetingIsPastOnceHeld() {
        let today = "2026-11-11"
        #expect(!meeting("date: 2026-11-11\nstatus: prepared").meetingIsPast(today: today))
        #expect(!meeting("date: 2026-11-11\nstatus: live").meetingIsPast(today: today))
        #expect(meeting("date: 2026-11-11\nstatus: review").meetingIsPast(today: today))
        #expect(meeting("date: 2026-11-10\nstatus: scheduled").meetingIsPast(today: today))
        #expect(!meeting("date: 2026-11-12\nstatus: scheduled").meetingIsPast(today: today))
    }
}
