import Foundation
import Testing
@testable import KBCore

func makeWorkflowKB() throws -> TempDir {
    let kb = try makeKB()
    try kb.write("projects/alpha/inbox/20261106-101500-use-ble-6.md", """
    ---
    title: Use BLE 6
    date: 2026-11-06
    status: active
    summary: Move to BLE 6
    supersedes: [alpha/decisions/2026-03-01-use-ble-5]
    proposed_section: decisions
    proposed_by: alpha/meetings/2026-02-10-sync
    reason: Agreed in the sync
    ---
    ## Decision
    BLE 6.
    """)
    try kb.write("projects/alpha/inbox/20261106-101600-credit-fact.md", """
    ---
    title: Credit Ble fact
    proposed_section: facts
    proposed_by: session:abc
    reason: noticed
    ---
    """)
    try kb.write("projects/alpha/followups/2026-11-04-which-export-format.md", """
    ---
    title: Which export format goes to Hub?
    date: 2026-11-04
    kind: question
    status: open
    owner: Mads
    due: 2026-11-05
    raised_in: alpha/meetings/2026-02-10-sync
    ---
    """)
    try kb.write("projects/alpha/followups/2026-11-01-done-thing.md", "---\ntitle: Done thing\nkind: action\nstatus: done\ndue: 2026-10-01\n---\n")
    try kb.write("projects/alpha/backlog/2026-11-06-raw-upload.md", """
    ---
    title: Upload export formats
    date: 2026-11-06
    kind: pbi
    status: proposed
    source: [alpha/meetings/2026-02-10-sync, alpha/decisions/2026-03-01-use-ble-5]
    sprint: next
    ---
    ## Description
    Send raw.

    ## Acceptance criteria
    - Raw is sent
    """)
    return kb
}

@Suite struct WorkflowIndexTests {
    @Test func indexesNewSectionsAndKeepsInboxOutOfOtherLists() throws {
        let kb = try makeWorkflowKB()
        let index = try KBIndex.load(root: kb.url)
        #expect(index.count(project: "alpha", section: .inbox) == 2)
        #expect(index.count(project: "alpha", section: .followups) == 2)
        #expect(index.count(project: "alpha", section: .backlog) == 1)
        // The inbox decision is not a decision yet.
        #expect(index.count(project: "alpha", section: .decisions) == 3)
        #expect(!index.entries(project: "alpha", section: .decisions).contains { $0.title == "Use BLE 6" })
        let timeline = index.decisionTimeline(project: "alpha")
        let inTimeline = timeline.chains.flatMap(\.entries) + timeline.standalone
        #expect(!inTimeline.contains { $0.title == "Use BLE 6" })
        // Search covers every area, the inbox too.
        #expect(index.search("ble 6", project: "alpha").flatMap(\.entries).map(\.title) == ["Use BLE 6"])
        #expect(index.search("credit ble", project: nil).flatMap(\.entries).map(\.section) == [.inbox])

        let inbox = index.entries(project: "alpha", section: .inbox)
        #expect(inbox.map(\.title) == ["Credit Ble fact", "Use BLE 6"])
        let proposal = try #require(inbox.last)
        #expect(proposal.proposedSection == .decisions)
        #expect(proposal.reason == "Agreed in the sync")
        #expect(index.inbox(project: "alpha", proposedBy: "alpha/meetings/2026-02-10-sync").map(\.title) == ["Use BLE 6"])
        #expect(index.backlog(project: "alpha", sourcedFrom: "alpha/meetings/2026-02-10-sync").count == 1)
        #expect(index.backlog(project: "alpha", sourcedFrom: "alpha/meetings/other").isEmpty)
    }

    @Test func followupAndBacklogFields() throws {
        let kb = try makeWorkflowKB()
        let index = try KBIndex.load(root: kb.url)
        let open = try #require(index.entry(EntryID("alpha/followups/2026-11-04-which-export-format")!))
        #expect(open.followupKind == "question")
        #expect(open.followupStatus == .open)
        #expect(open.isOverdue(today: "2026-11-06"))
        #expect(!open.isOverdue(today: "2026-11-05"))
        let done = try #require(index.entry(EntryID("alpha/followups/2026-11-01-done-thing")!))
        #expect(done.followupStatus == .done)
        #expect(!done.isOverdue(today: "2026-11-06"))
        let item = try #require(index.entries(project: "alpha", section: .backlog).first)
        #expect(item.backlogKind == "pbi")
        #expect(item.backlogStatus == .proposed)
        #expect(item.sources.count == 2)
        #expect(item.field("sprint") == "next")
        #expect(EntryID("alpha/inbox/20261106-101500-use-ble-6")?.section == .inbox)
    }
}

@Suite struct DailyPlanTests {
    static let sample = """
    ---
    title: Thursday 6 November
    date: 2026-11-06
    ---

    ## Today
    - [ ] [contoso-android] Review PR 318327 (ado:318327)
    - [x] [acme-go] Ask BFF who signs off the export format (acme-go/followups/2026-11-04-which-export-format)
    - [ ] Plain item without project

    ## Meetings
    - 10:00–10:30 [acme-go] Network retry sync → acme-go/meetings/2026-11-06-network-retry-sync (prepared)

    ## To decide
    - [acme-go] Export format before or after retry (acme-go/followups/2026-11-04-which-export-format)

    ## Proposed
    - 2 backlog items and 3 inbox entries waiting: open the app's Inbox.

    """

    @Test func parsesEverySection() {
        let plan = DailyPlan.parse(Self.sample)
        #expect(plan.title == "Thursday 6 November")
        #expect(plan.date == "2026-11-06")
        #expect(plan.today.count == 3)
        #expect(plan.today[0].project == "contoso-android")
        #expect(plan.today[0].text == "Review PR 318327")
        #expect(plan.today[0].ref == "ado:318327")
        #expect(plan.today[0].done == false)
        #expect(plan.today[1].done == true)
        #expect(plan.today[1].ref == "acme-go/followups/2026-11-04-which-export-format")
        #expect(plan.today[2].project == nil)
        let m = try! #require(plan.meetings.first)
        #expect(m.time == "10:00–10:30")
        #expect(m.project == "acme-go")
        #expect(m.title == "Network retry sync")
        #expect(m.meetingID == "acme-go/meetings/2026-11-06-network-retry-sync")
        #expect(m.status == "prepared")
        #expect(plan.toDecide.first?.text == "Export format before or after retry")
        #expect(plan.toDecide.first?.done == nil)
        #expect(plan.proposed.count == 1)
    }

    @Test func toggleRoundTripKeepsEverythingElse() throws {
        let plan = DailyPlan.parse(Self.sample)
        let line = plan.today[0].lineText
        let ticked = try #require(DailyPlan.toggle(Self.sample, lineText: line, done: true))
        #expect(ticked == Self.sample.replacingOccurrences(of: "- [ ] [contoso-android]", with: "- [x] [contoso-android]"))
        #expect(DailyPlan.parse(ticked).today[0].done == true)
        let back = try #require(DailyPlan.toggle(ticked, lineText: line, done: false))
        #expect(back == Self.sample)
        // To decide lines are not toggled, and unknown lines are reported.
        #expect(DailyPlan.toggle(Self.sample, lineText: "nope", done: true) == nil)

        let kb = try TempDir()
        try kb.write("daily/2026-11-06.md", Self.sample)
        try DailyPlan.setDone(date: "2026-11-06", lineText: plan.today[1].lineText, done: false, root: kb.url)
        #expect(DailyPlan.load(date: "2026-11-06", root: kb.url)?.today[1].done == false)
        #expect(throws: DailyPlanError.self) {
            try DailyPlan.setDone(date: "2026-11-06", lineText: "missing", done: true, root: kb.url)
        }
    }

    @Test func notRelevantAndRemoveKeepEverythingElse() throws {
        let plan = DailyPlan.parse(Self.sample)
        let line = plan.today[0].lineText
        let aside = try #require(DailyPlan.mark(Self.sample, lineText: line, .notRelevant))
        #expect(aside == Self.sample.replacingOccurrences(of: "- [ ] [contoso-android]", with: "- [-] [contoso-android]"))
        let parsed = DailyPlan.parse(aside).today[0]
        #expect(parsed.notRelevant && parsed.done == nil && parsed.project == "contoso-android" && parsed.lineText == line)
        #expect(DailyPlan.mark(aside, lineText: line, .open) == Self.sample)
        let removed = try #require(DailyPlan.mark(Self.sample, lineText: line, .removed))
        #expect(!removed.contains("Review PR 318327"))
        #expect(DailyPlan.parse(removed).today.count == 2)
        // A To decide line has no checkbox, and gets none back when restored.
        let decide = plan.toDecide[0].lineText
        let decideAside = try #require(DailyPlan.mark(Self.sample, lineText: decide, .notRelevant))
        #expect(DailyPlan.parse(decideAside).toDecide[0].notRelevant)
        #expect(DailyPlan.mark(decideAside, lineText: decide, .open) == Self.sample)
    }
}

@Suite struct MeetingBodyTests {
    static let body = """

    Intro kept as is.

    ## Prep
    Context from last week.

    ## Questions
    ### Upload
    - [ ] Who signs off the export format? (re: acme-go/decisions/2026-11-04-x)
    - [x] Is retry per device?
    Some note under the questions.

    ## Summary
    **Context:** sync.

    ## Decisions
    - One

    """

    @Test func readsSectionsIncludingNestedHeadings() {
        #expect(MeetingBody.section(.prep, in: Self.body) == "Context from last week.")
        #expect(MeetingBody.section(.rawNotes, in: Self.body) == nil)
        #expect(MeetingBody.section(.summary, in: Self.body) == "**Context:** sync.\n\n## Decisions\n- One")
    }

    @Test func insertsAndReplacesInOrderKeepingTheRest() {
        let withNotes = MeetingBody.setting(.rawNotes, to: "first note\n\nsecond", in: Self.body)
        #expect(MeetingBody.section(.rawNotes, in: withNotes) == "first note\n\nsecond")
        #expect(withNotes.contains("Some note under the questions.\n\n## Raw notes\n\nfirst note\n\nsecond\n\n## Summary"))
        #expect(withNotes.hasPrefix("\nIntro kept as is.\n"))

        let replaced = MeetingBody.setting(.rawNotes, to: "only", in: withNotes)
        #expect(MeetingBody.section(.rawNotes, in: replaced) == "only")
        #expect(MeetingBody.section(.summary, in: replaced) == MeetingBody.section(.summary, in: Self.body))
        #expect(MeetingBody.section(.prep, in: replaced) == "Context from last week.")

        let newSummary = MeetingBody.setting(.summary, to: "New summary.", in: replaced)
        #expect(MeetingBody.section(.summary, in: newSummary) == "New summary.")
        #expect(newSummary.hasSuffix("## Summary\n\nNew summary.\n"))

        // Same content gives the same text.
        #expect(MeetingBody.setting(.rawNotes, to: "only", in: replaced) == replaced)

        let fresh = MeetingBody.setting(.rawNotes, to: "a", in: "\n## Questions\n")
        #expect(fresh == "\n## Questions\n\n## Raw notes\n\na\n")
        let fromEmpty = MeetingBody.setting(.summary, to: "S", in: "")
        #expect(MeetingBody.section(.summary, in: fromEmpty) == "S")
    }

    @Test func questionListKeepsOtherLinesAndTicksAnswers() throws {
        var list = QuestionList(markdown: try #require(MeetingBody.section(.questions, in: Self.body)))
        #expect(list.questions.map(\.text) == ["Who signs off the export format? (re: acme-go/decisions/2026-11-04-x)", "Is retry per device?"])
        #expect(list.questions.first?.group == "Upload")
        let found = list.markAnswered("Who signs off the export format?")
        #expect(found)
        #expect(list.questions.allSatisfy { $0.done })
        let missing = list.markAnswered("Something never asked")
        #expect(!missing)
        list.append("New one")
        #expect(list.markdown.contains("Some note under the questions.\n- [ ] New one"))
        #expect(list.markdown.hasPrefix("### Upload\n- [x] Who signs off"))
        var loose = QuestionList(markdown: "- [ ] When does the BFF ship the export format endpoint to stage?")
        let looseFound = loose.markAnswered("the BFF ship the export format endpoint to stage")
        #expect(looseFound)
    }

    @Test func answersSitUnderTheirQuestions() {
        var list = QuestionList(markdown: "### Upload\n- [ ] Who signs off?\n- [ ] Is retry per device?")
        list.set(1, done: true)
        list.set(1, answer: "Lena, by Friday")
        #expect(list.markdown == "### Upload\n- [x] Who signs off?\n  - Answer: Lena, by Friday\n- [ ] Is retry per device?")
        let reread = QuestionList(markdown: list.markdown)
        #expect(reread.questions.map(\.answer) == ["Lena, by Friday", ""])
        #expect(reread.questions.map(\.group) == ["Upload", "Upload"])
        list.set(1, answer: "Lena\nby Friday")
        #expect(list.questions.first?.answer == "Lena by Friday")
        let ticked = list.markAnswered("Is retry per device?", answer: "Yes, per device")
        #expect(ticked)
        #expect(list.questions.last?.answer == "Yes, per device")
        list.markAnswered("Who signs off?", answer: "Someone else")
        #expect(list.questions.first?.answer == "Lena by Friday")
        list.remove(1)
        #expect(list.markdown == "### Upload\n- [x] Is retry per device?\n  - Answer: Yes, per device")
        list.set(1, answer: "")
        #expect(list.markdown == "### Upload\n- [x] Is retry per device?")
        // A top-level "- Answer:" is someone's note, not an answer.
        #expect(QuestionList(markdown: "- [ ] Q\n- Answer: no").questions.first?.answer == "")
    }

    @Test func createsPreparedMeetingAndUpdatesSections() throws {
        let kb = try makeKB()
        let doc = try MeetingFile.create(project: "alpha", title: "Network retry sync", date: "2026-11-06", start: "10:00",
                                         attendees: ["Ann", "Bo"], root: kb.url)
        #expect(doc.id.rawValue == "alpha/meetings/2026-11-06-network-retry-sync")
        let text = try kb.read("projects/alpha/meetings/2026-11-06-network-retry-sync.md")
        #expect(text.contains("status: prepared\nstart: \"10:00\"") || text.contains("status: prepared\nstart: 10:00"))
        #expect(text.hasSuffix("---\n\n## Questions\n"))
        let index = try KBIndex.load(root: kb.url)
        #expect(index.entry(doc.id)?.meetingStatus == .prepared)

        try MeetingFile.update(doc.id, root: kb.url) { d in
            d.frontmatter.set("status", .string("live"))
            d.setMeetingSection(.rawNotes, "note one")
        }
        let loaded = try KBStore.load(doc.id, root: kb.url)
        #expect(MeetingFile.status(of: loaded) == .live)
        #expect(loaded.meetingSection(.rawNotes) == "note one")
        #expect(loaded.meetingSection(.questions) == "")
        #expect(loaded.frontmatter.list("attendees") == ["Ann", "Bo"])
    }
}

@Suite struct LiveReplyTests {
    @Test func okSaysNothing() {
        #expect(LiveReply.parse("OK").isOK)
        #expect(LiveReply.parse("OK.\n").isOK)
        #expect(LiveReply.parse("  ok  ").isOK)
    }

    @Test func flagsAndAnswers() {
        let r = LiveReply.parse("""
        ⚠ Conflicts with acme-go/decisions/2026-11-04-x (2026-11-04): retry is per device.
        ℹ️ Open since 2026-10-01: acme-go/meetings/2026-10-01-y.
        ANSWERED: Who signs off the export format?
        """)
        #expect(r.flags == [
            .init(kind: .warning, text: "Conflicts with acme-go/decisions/2026-11-04-x (2026-11-04): retry is per device."),
            .init(kind: .info, text: "Open since 2026-10-01: acme-go/meetings/2026-10-01-y."),
        ])
        #expect(r.answered == ["Who signs off the export format?"])
        let onlyAnswer = LiveReply.parse("OK\nANSWERED: \"Is retry per device?\"")
        #expect(onlyAnswer.isOK)
        #expect(onlyAnswer.answered == ["Is retry per device?"])
        let withAnswer = LiveReply.parse("ANSWERED: \"Who signs off the export format?\" => Lena, by Friday")
        #expect(withAnswer.answered == ["Who signs off the export format?"])
        #expect(withAnswer.answers == ["Who signs off the export format?": "Lena, by Friday"])
        #expect(LiveReply.parse("- ⚠️ **Code today:** reads it raw.").flags.first?.kind == .warning)
        #expect(LiveReply.parse("Noted, Lena owns it.").flags.first?.kind == .note)
    }

    @Test func proposedCount() {
        #expect(LiveReply.proposedCount("PROPOSED 4") == 4)
        #expect(LiveReply.proposedCount("Done.\n`PROPOSED 0`") == 0)
        #expect(LiveReply.proposedCount("Proposed: 3") == 3)
        #expect(LiveReply.proposedCount("nothing") == nil)
    }
}

@Suite struct LiveNoteTrackerTests {
    @Test func sendsCompletedParagraphsOnce() {
        var t = LiveNoteTracker()
        #expect(t.update(text: "First note", paused: false).isEmpty)
        let sent = t.update(text: "First note\n\n", paused: false)
        #expect(sent.map(\.text) == ["First note"])
        #expect(t.update(text: "First note\n\nSecond", paused: false).isEmpty)
        #expect(t.update(text: "First note\n\nSecond", paused: true).map(\.text) == ["Second"])
        // Typing on after a pause sends only what was added.
        let more = t.update(text: "First note\n\nSecond, and Lena owns it\n\n", paused: false)
        #expect(more.map(\.text) == [", and Lena owns it"])
        #expect(more.first?.anchor == "Second, and Lena owns it")
        #expect(t.notes.filter { $0.anchor == "Second, and Lena owns it" }.count == 2)
        // A typo fix is not resent.
        #expect(t.update(text: "First note!\n\nSecond, and Lena owns it\n\n", paused: true).isEmpty)
        #expect(t.notes.first?.anchor == "First note!")
    }

    @Test func similarNewParagraphIsStillSent() {
        var t = LiveNoteTracker()
        _ = t.update(text: "Decision: we will use BLE 5\n\n", paused: false)
        let sent = t.update(text: "Decision: we will use BLE 5\n\nDecision: we will use BLE 6\n\n", paused: false)
        #expect(sent.map(\.text) == ["Decision: we will use BLE 6"])
    }

    @Test func markSentSkipsRestoredNotes() {
        var t = LiveNoteTracker()
        t.markSent("Old one\n\nOld two")
        #expect(t.update(text: "Old one\n\nOld two\n\nNew\n\n", paused: false).map(\.text) == ["New"])
    }
}

@Suite struct StreamParsingTests {
    @Test func reportsConnectorStatusFromInit() {
        let line = #"{"type":"system","subtype":"init","session_id":"s","mcp_servers":[{"name":"claude.ai Microsoft 365","status":"needs-auth"},{"name":"figma","status":"connected"}]}"#
        #expect(ClaudeStreamLine.parse(line) == [.initialized(sessionID: "s"),
                                                .connectors(["claude.ai Microsoft 365": "needs-auth", "figma": "connected"])])
    }

    @Test func calendarStatusesStageAndActivity() {
        #expect(MeetingStatus.scheduled.isUpcoming && MeetingStatus.scheduled.isActive)
        #expect(!MeetingStatus.cancelled.isActive && !MeetingStatus.cancelled.isUpcoming)
        #expect(!MeetingStatus.live.isUpcoming)
    }

    @Test func parsesTheRealLines() {
        #expect(ClaudeStreamLine.parse(#"{"type":"system","subtype":"init","session_id":"0b1c-22","tools":["Read"],"model":"x"}"#)
            == [.initialized(sessionID: "0b1c-22")])
        #expect(ClaudeStreamLine.parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"OK1."}]}}"#) == [.text("OK1.")])
        #expect(ClaudeStreamLine.parse(#"{"type":"result","subtype":"success","result":"OK1."}"#) == [.result(text: "OK1.", isError: false)])
        #expect(ClaudeStreamLine.parse(#"{"type":"system","subtype":"hook_started"}"#).isEmpty)
        #expect(ClaudeStreamLine.parse(#"{"type":"rate_limit_event"}"#).isEmpty)
        #expect(ClaudeStreamLine.parse("not json").isEmpty)
        #expect(ClaudeStreamLine.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}},{"type":"text","text":"Done"}]}}"#)
            == [.toolUse("Edit"), .text("Done")])
        #expect(ClaudeStreamLine.parse(#"{"type":"result","subtype":"error_during_execution","is_error":true}"#)
            == [.result(text: "error_during_execution", isError: true)])
    }

    @Test func userMessageIsOneJSONLine() throws {
        let line = ClaudeStreamLine.userMessage("a \"quote\"\nand a newline")
        #expect(line.hasSuffix("\n"))
        #expect(line.dropLast().contains("\n") == false)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(json["type"] as? String == "user")
        let message = try #require(json["message"] as? [String: Any])
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "a \"quote\"\nand a newline")
    }

    @Test func lineBufferSplitsAcrossChunks() {
        var b = LineBuffer()
        #expect(b.append(Data("{\"a\":".utf8)).isEmpty)
        #expect(b.append(Data("1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
        #expect(b.flush() == "{\"b\"")
    }
}

final class FakeClaudeProcess: ClaudeProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var _written: [String] = []
    private var onLine: (@Sendable (String) -> Void)?
    private var onExit: (@Sendable (Int32) -> Void)?

    var written: [String] { lock.withLock { _written } }

    func start(onLine: @escaping @Sendable (String) -> Void, onStderr: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws {
        lock.withLock {
            self.onLine = onLine
            self.onExit = onExit
        }
    }

    func write(_ line: String) throws { lock.withLock { _written.append(line) } }
    func terminate() { exit(143) }
    func emit(_ line: String) { lock.withLock { onLine }?(line) }
    func exit(_ code: Int32) { lock.withLock { onExit }?(code) }

    func sentTexts() -> [String] {
        written.compactMap { line in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let m = json["message"] as? [String: Any], let c = m["content"] as? [[String: Any]] else { return nil }
            return c.first?["text"] as? String
        }
    }
}

@Suite struct ClaudeSessionTests {
    @Test func sendsOneTurnAtATime() async throws {
        let fake = FakeClaudeProcess()
        let session = ClaudeSession(process: fake)
        session.send("before start", tag: "0")
        try session.start()
        #expect(fake.sentTexts() == ["before start"])
        session.send("one", tag: "1")
        session.send("two", tag: "2")
        #expect(fake.sentTexts() == ["before start"])
        #expect(session.queuedCount == 2)
        #expect(session.isBusy)

        fake.emit(#"{"type":"system","subtype":"init","session_id":"s-1"}"#)
        fake.emit(#"{"type":"system","subtype":"hook_started"}"#)
        fake.emit(#"{"type":"assistant","message":{"content":[{"type":"text","text":"OK"}]}}"#)
        fake.emit(#"{"type":"result","subtype":"success","result":"OK"}"#)
        #expect(fake.sentTexts() == ["before start", "one"])
        fake.emit(#"{"type":"system","subtype":"init","session_id":"s-1"}"#)
        fake.emit(#"{"type":"result","subtype":"success","result":"⚠ x"}"#)
        #expect(fake.sentTexts() == ["before start", "one", "two"])
        fake.emit(#"{"type":"result","subtype":"success","result":"OK"}"#)
        #expect(!session.isBusy)
        #expect(session.sessionID == "s-1")
        fake.exit(0)

        var events: [ClaudeEvent] = []
        for await e in session.events { events.append(e) }
        #expect(events == [
            .turnStarted(tag: "0"),
            .sessionStarted("s-1"),
            .assistantText("OK"),
            .turnResult(text: "OK", isError: false, tag: "0"),
            .turnStarted(tag: "1"),
            .turnResult(text: "⚠ x", isError: false, tag: "1"),
            .turnStarted(tag: "2"),
            .turnResult(text: "OK", isError: false, tag: "2"),
            .exited(0),
        ])
    }

    @Test func exitDropsTheQueueAndReportsErrors() async throws {
        let fake = FakeClaudeProcess()
        let session = ClaudeSession(process: fake)
        try session.start()
        session.send("a")
        session.send("b")
        fake.exit(1)
        session.send("c")
        var events: [ClaudeEvent] = []
        for await e in session.events { events.append(e) }
        #expect(fake.sentTexts() == ["a"])
        #expect(events.contains(.error("Claude exited with code 1.")))
        #expect(events.last == .exited(1))
        #expect(!session.isRunning)
    }
}

@Suite struct LaunchTests {
    @Test func argumentsFollowTheBridgeDoc() {
        let l = ClaudeLaunch(executable: URL(fileURLWithPath: "/usr/local/bin/claude"), pluginRoot: "/p", systemPrompt: "PROMPT",
                             sessionID: "abc", model: "sonnet", workingDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(l.arguments == ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                "--session-id", "abc", "--plugin-dir", "/p", "--model", "sonnet",
                                "--append-system-prompt", "PROMPT", "--allowedTools", ClaudeLaunch.bridgeTools.joined(separator: " ")])
        var r = l
        r.resume = true
        r.model = ""
        #expect(r.arguments.contains("--resume"))
        #expect(!r.arguments.contains("--session-id"))
        #expect(!r.arguments.contains("--model"))
        #expect(ClaudeModes.live("p/meetings/x").contains("ANSWERED: <the question text exactly as written>"))
        #expect(ClaudeModes.askMessage("Q?", sources: ["kb", "wiki"]) == "Q?\n\nUse only these sources: kb, wiki")
    }

    @Test func workingDirectoryFallsBackToRoot() throws {
        let kb = try TempDir()
        let root = URL(fileURLWithPath: "/tmp/root")
        #expect(ClaudeLaunch.workingDirectory(project: KBProject(id: "a", title: "A", paths: [kb.url.path]), root: root).path == kb.url.path)
        #expect(ClaudeLaunch.workingDirectory(project: KBProject(id: "a", title: "A", paths: ["/does/not/exist"]), root: root) == root)
        #expect(ClaudeLaunch.workingDirectory(project: KBProject(id: "a", title: "A"), root: root) == root)
    }
}

struct MockRunner: CommandRunning {
    let calls = CallLog()
    var result: CommandResult

    final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _args: [[String]] = []
        private var _env: [[String: String]] = []
        private var _stdin: [String?] = []
        func add(_ a: [String], _ e: [String: String], _ s: String?) { lock.withLock { _args.append(a); _env.append(e); _stdin.append(s) } }
        var args: [[String]] { lock.withLock { _args } }
        var env: [[String: String]] { lock.withLock { _env } }
        var stdin: [String?] { lock.withLock { _stdin } }
    }

    func run(executable: URL, arguments: [String], environment: [String: String], stdin: String?, currentDirectory: URL?) async -> CommandResult {
        calls.add(arguments, environment, stdin)
        return result
    }
}

@Suite struct KBCLITests {
    let plugin = URL(fileURLWithPath: "/plugin")
    let root = URL(fileURLWithPath: "/kb")

    func cli(_ result: CommandResult) -> (KBCLI, MockRunner) {
        let runner = MockRunner(result: result)
        return (KBCLI(pluginRoot: plugin, kbRoot: root, environment: ["PATH": "/bin"], runner: runner), runner)
    }

    @Test func approveReturnsLineOneAndSetsRoot() async throws {
        let (c, runner) = cli(CommandResult(status: 0, stdout: "alpha/decisions/2026-11-06-use-ble-6\nmarked x superseded\n", stderr: ""))
        let id = try await c.approveInbox(EntryID("alpha/inbox/20261106-101500-use-ble-6")!)
        #expect(id == "alpha/decisions/2026-11-06-use-ble-6")
        #expect(runner.calls.args.first == ["/plugin/scripts/kb.py", "inbox", "approve", "alpha/inbox/20261106-101500-use-ble-6"])
        #expect(runner.calls.env.first?["KB_ROOT"] == "/kb")
    }

    @Test func failureCarriesStderr() async {
        let (c, _) = cli(CommandResult(status: 2, stdout: "", stderr: "no such inbox entry\n"))
        do {
            try await c.rejectInbox(EntryID("alpha/inbox/x")!)
            Issue.record("expected a throw")
        } catch let e as KBCLIError {
            #expect(e.status == 2)
            #expect(e.localizedDescription.contains("no such inbox entry"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func backlogAndFollowupArguments() async throws {
        let (c, runner) = cli(CommandResult(status: 0, stdout: "created 417001 https://dev.azure.com/x/_workitems/edit/417001\n", stderr: ""))
        let created = try await c.createBacklog(EntryID("alpha/backlog/2026-11-06-raw")!, sprint: .next)
        #expect(created == .init(id: "417001", url: "https://dev.azure.com/x/_workitems/edit/417001"))
        #expect(runner.calls.args.last == ["/plugin/scripts/kb.py", "backlog", "create", "alpha/backlog/2026-11-06-raw", "--yes", "--sprint", "next"])
        try await c.closeFollowup(EntryID("alpha/followups/x")!, status: .done, resolvedBy: "alpha/decisions/y", answer: "Lena")
        #expect(runner.calls.args.last == ["/plugin/scripts/kb.py", "followup", "close", "alpha/followups/x", "--status", "done",
                                           "--resolved-by", "alpha/decisions/y", "--answer", "Lena"])
        try await c.closeFollowup(EntryID("alpha/followups/x")!, status: .dropped, resolvedBy: " ", answer: nil)
        #expect(runner.calls.args.last == ["/plugin/scripts/kb.py", "followup", "close", "alpha/followups/x", "--status", "dropped"])
        _ = try await c.addInboxFact(project: "alpha", title: "T", proposedBy: "ask:s1", reason: "from Ask", body: "B")
        #expect(runner.calls.args.last?.contains("--body-stdin") == true)
        #expect(runner.calls.stdin.last == "B")
    }
}

@Suite struct SettingsAndSourcesTests {
    @Test func settingsRoundTripKeepsUnknownKeys() throws {
        let json = """
        {"tracker": {"kind": "azure-devops", "organization": "AcmeCorp", "project": "AcmeGo",
          "area_path": "AcmeGo\\\\Acme Go App team", "title_prefix": "Android: ", "tags": ["Android"],
          "default_parent": 411000, "assignee": "me@example.com", "extra_tracker_key": 1},
         "conventions": {"pr": "Squash only"}, "future": {"x": 1},
         "sources": [{"id": "ado-wiki", "kind": "ado-wiki", "title": "AcmeGo wiki", "use_for": "Release process",
                      "enabled": true, "config": {"organization": "AcmeCorp", "project": "AcmeGo", "wiki": "AcmeGo.wiki"}}]}
        """
        var s = ProjectSettings.parse(Data(json.utf8))
        #expect(s.hasTracker)
        #expect(s.tracker.areaPath == "AcmeGo\\Acme Go App team")
        #expect(s.tracker.defaultParent == "411000")
        #expect(s.conventions.map(\.key) == ["pr"])
        #expect(s.sources.first?.string("wiki") == "AcmeGo.wiki")
        s.tracker.titlePrefix = "iOS: "
        s.conventions.append(.init(key: "new", value: "v"))
        s.sources.append(KnowledgeSource(id: "tool", kind: "command", title: "Tool", useFor: "x", config: ["run": .string("mytool q {query}")]))
        let out = try s.serialized()
        let reparsed = ProjectSettings.parse(out)
        #expect(reparsed.tracker.titlePrefix == "iOS: ")
        #expect(reparsed.tracker.defaultParent == "411000")
        #expect(reparsed.conventions.count == 2)
        #expect(reparsed.sources.map(\.id) == ["ado-wiki", "tool"])
        let raw = try #require(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        #expect((raw["future"] as? [String: Any])?["x"] as? Int == 1)
        #expect((raw["tracker"] as? [String: Any])?["extra_tracker_key"] as? Int == 1)
        #expect((raw["tracker"] as? [String: Any])?["default_parent"] as? Int == 411000)
    }

    @Test func projectWithoutTrackerStaysWithoutOne() throws {
        var s = ProjectSettings()
        s.sources = [KnowledgeSource(id: "docs", kind: "folder", title: "Docs", useFor: "design docs", config: ["path": .string("~/docs")])]
        let raw = try #require(try JSONSerialization.jsonObject(with: s.serialized()) as? [String: Any])
        #expect(raw["tracker"] == nil)
        #expect((raw["sources"] as? [Any])?.count == 1)
    }

    @Test func globalSourcesRoundTrip() throws {
        let kb = try TempDir()
        try kb.write("sources.json", #"{"note": "keep", "sources": [{"id": "m", "kind": "mcp", "title": "Miro", "use_for": "boards", "enabled": false, "config": {"server": "miro", "tools": ["search"]}, "custom": [1,2]}]}"#)
        var list = GlobalSources.load(root: kb.url)
        #expect(list.count == 1)
        #expect(list[0].enabled == false)
        #expect(list[0].list("tools") == ["search"])
        list[0].enabled = true
        try GlobalSources.save(list, root: kb.url)
        let again = GlobalSources.load(root: kb.url)
        #expect(again == list)
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(kb.read("sources.json").utf8)) as? [String: Any])
        #expect(raw["note"] as? String == "keep")
        #expect(((raw["sources"] as? [[String: Any]])?.first?["custom"] as? [Int]) == [1, 2])
        #expect(KnowledgeSource.makeID(title: "AcmeGo wiki", taken: ["acmego-wiki"]) == "acmego-wiki-2")
    }

    @Test func allowedToolsFromSources() {
        let sources = [
            KnowledgeSource(id: "a", kind: "mcp", title: "Miro", useFor: "", config: ["server": .string("miro")]),
            KnowledgeSource(id: "b", kind: "mcp", title: "Figma", useFor: "", config: ["server": .string("figma"), "tools": .list(["get_screenshot", "mcp__figma__whoami"])]),
            KnowledgeSource(id: "c", kind: "command", title: "Tool", useFor: "", config: ["run": .string("  jira-cli search {query}")]),
            KnowledgeSource(id: "d", kind: "mcp", title: "Off", useFor: "", enabled: false, config: ["server": .string("off")]),
            KnowledgeSource(id: "e", kind: "folder", title: "Docs", useFor: "", config: ["path": .string("/x")]),
            KnowledgeSource(id: "f", kind: "command", title: "Curl", useFor: "", config: ["run": .string("curl -s {query}")]),
        ]
        let tools = AskTools.allowedTools(sources: sources)
        #expect(Array(tools.prefix(ClaudeLaunch.bridgeTools.count)) == ClaudeLaunch.bridgeTools)
        #expect(tools.contains("WebFetch") && tools.contains("WebSearch") && tools.contains("Bash(git:*)"))
        #expect(tools.contains("mcp__miro__*"))
        #expect(tools.contains("mcp__figma__get_screenshot") && tools.contains("mcp__figma__whoami"))
        #expect(!tools.contains("mcp__figma__*"))
        #expect(tools.contains("Bash(jira-cli:*)"))
        #expect(!tools.contains { $0.contains("off") })
        #expect(tools.filter { $0 == "Bash(curl:*)" }.count == 1)
    }
}

@Suite struct CitationTests {
    @Test func parsesSourcesBlock() {
        let answer = AskAnswer.parse("""
        retry is set per device [1], and the export format goes to Hub [2]. See the wiki [3].

        **Sources:**
        [1] kb — acme-go/decisions/2026-11-04-network-retry-policy-is-set-per-device — Network retry per device
        [2] code — `app/src/main/java/Upload.kt` — Upload mapper
        - [3] ado-wiki — https://dev.azure.com/x/_wiki/wikis/AcmeGo.wiki/12 — Release process
        [4] ado-work-items — ado:416914 — Build-time modules
        """)
        #expect(answer.body == "retry is set per device [1], and the export format goes to Hub [2]. See the wiki [3].")
        #expect(answer.citations.map(\.number) == [1, 2, 3, 4])
        #expect(answer.citations[0].target == .entry(EntryID("acme-go/decisions/2026-11-04-network-retry-policy-is-set-per-device")!))
        #expect(answer.citations[0].title == "Network retry per device")
        #expect(answer.citations[1].target == .file("app/src/main/java/Upload.kt"))
        #expect(answer.citations[2].target == .url(URL(string: "https://dev.azure.com/x/_wiki/wikis/AcmeGo.wiki/12")!))
        #expect(answer.citations[3].target == .other("ado:416914"))
        #expect(answer.citations[3].source == "ado-work-items")
    }

    @Test func answerWithoutSources() {
        let a = AskAnswer.parse("I don't know.")
        #expect(a.body == "I don't know.")
        #expect(a.citations.isEmpty)
    }
}

@Suite struct TimeQuotingTests {
    @Test func clockTimesAreQuoted() {
        #expect(FrontmatterCodec.format(.string("12:53")) == "\"12:53\"")
        #expect(FrontmatterCodec.format(.string("9:05")) == "\"9:05\"")
        #expect(FrontmatterCodec.format(.string("2026-11-06")) == "2026-11-06")
    }
}

@Suite struct CitationColumnTests {
    /// A real Haiku answer put the entry id where the source id belongs.
    @Test func swappedColumnsStillLink() {
        let a = AskAnswer.parse("""
        retry is per device [1].

        Sources:
        [1] acme-go/decisions/2026-11-04-network-retry-policy-is-set-per-device — acme-go decision — Network retry policy is set per device
        """)
        #expect(a.citations.first?.target == .entry(EntryID("acme-go/decisions/2026-11-04-network-retry-policy-is-set-per-device")!))
        #expect(a.citations.first?.title == "Network retry policy is set per device")
    }
}

@Suite struct ReminderTests {
    func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kb-rem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func createUpdateAndReloadKeepsFields() throws {
        let root = tempRoot()
        let r = try Reminders.create(title: "Finish GDPR training", due: "2026-11-12", note: "Course in the LMS", project: "app-a",
                                     link: "https://lms.example/x", root: root, today: "2026-11-09")
        #expect(r.id == "reminders/finish-gdpr-training")
        let again = try Reminders.create(title: "Finish GDPR training", due: "2026-11-13", root: root)
        #expect(again.stem == "finish-gdpr-training-2")
        try Reminders.setStatus(r, .done, today: "2026-11-10")
        try Reminders.setDue(r, "2026-11-20")
        let loaded = try #require(Reminders.load(root: root).first { $0.id == r.id })
        #expect(loaded.status == .done)
        #expect(loaded.due == "2026-11-20")
        #expect(loaded.project == "app-a")
        #expect(loaded.note == "Course in the LMS")
        #expect(loaded.frontmatter.string("done") == "2026-11-10")
    }

    @Test func readsTheCLIFormatAndJudgesDueDates() throws {
        let root = tempRoot()
        let dir = Reminders.directory(root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\ntitle: Approve expenses\ndue: 2026-11-08\nstatus: proposed\ncreated: 2026-11-09\nsource: email:abc\nfrom: Finance\nfrom_domain: example.com\n---\n\nThree receipts.\n"
            .write(to: dir.appendingPathComponent("approve-expenses.md"), atomically: true, encoding: .utf8)
        let r = try #require(Reminders.load(root: root).first)
        #expect(r.status == .proposed && r.isFromEmail && r.fromDomain == "example.com")
        #expect(!r.isOverdue(today: "2026-11-09"))
        try Reminders.setStatus(r, .open)
        let open = try #require(Reminders.load(root: root).first)
        #expect(open.isOverdue(today: "2026-11-09") && open.isDue(today: "2026-11-09"))
        let undated = try Reminders.create(title: "Read the team handbook", due: "", root: root)
        #expect(!undated.hasDue && !undated.isOverdue(today: "2026-11-09") && !undated.isDue(today: "2026-11-09"))
        #expect(undated.frontmatter.string("due") == nil)
        #expect(Reminders.load(root: root).last?.id == undated.id)
        try Reminders.setDue(open, "")
        #expect(Reminders.load(root: root).first { $0.id == open.id }?.hasDue == false)
        let q = Reminders.quickDates(from: KBDate.parse("2026-11-09")!)
        #expect(q.today == "2026-11-09" && q.tomorrow == "2026-11-10" && q.nextWeek == "2026-11-16")
    }
}

@Suite struct GoalTests {
    @Test func createLogAndSuggestionsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kb-goal-\(UUID().uuidString)")
        let g = try Goals.create(title: "Become a tech lead", horizon: "by end of 2027", why: "Next career step",
                                 root: root, today: "2026-11-09")
        #expect(g.id == "goals/become-a-tech-lead")
        try Goals.update(g) { e in
            e.body = GoalBody.setting("Suggestions", to: "- [ ] Write the retry decision note: technical direction\n- [x] Run the retro", in: e.body)
            e.body = GoalBody.addingProgress("Led the retro", date: "2026-11-09", to: e.body)
            e.body = GoalBody.addingProgress("Wrote a design note", date: "2026-11-10", to: e.body)
        }
        let loaded = try #require(Goals.load(root: root).first)
        #expect(loaded.section("Why") == "Next career step")
        #expect(loaded.openSuggestions == 1)
        #expect(loaded.lastProgress == "2026-11-10")
        #expect(loaded.horizon == "by end of 2027" && loaded.status == .active)
        #expect(loaded.body.contains("## What it takes"))
    }

    @Test func dayPlanReadsTheSideGoalSection() {
        let plan = DailyPlan.parse("---\ntitle: Monday\n---\n\n## Today\n- [ ] [app] Review PR (pr:1)\n\n## Side goal\n- [ ] [goal] Offer to own the review rule in the retro (goals/principal)\n\n## Proposed\n- 1 item\n")
        #expect(plan.today.count == 1)
        #expect(plan.sideGoal.count == 1)
        #expect(plan.sideGoal.first?.ref == "goals/principal")
        #expect(plan.other.isEmpty)
    }
}

@Suite struct TranscriptTests {
    @Test func linesRoundTripAndSectionSitsBeforeSummary() {
        let lines = [MeetingTranscript.Line(time: "10:32", speaker: "Others", text: "We keep the export format: and the settings."),
                     MeetingTranscript.Line(time: "10:33", speaker: "You", text: "Agreed.")]
        let md = lines.map(\.markdown).joined(separator: "\n")
        #expect(MeetingTranscript.parse(md) == lines)
        var body = "\n## Questions\n- [ ] Q\n\n## Raw notes\nnote\n\n## Summary\nsum\n"
        body = MeetingBody.setting(.transcript, to: md, in: body)
        let t = body.range(of: "## Transcript")!.lowerBound
        #expect(body.range(of: "## Raw notes")!.lowerBound < t)
        #expect(t < body.range(of: "## Summary")!.lowerBound)
        #expect(MeetingBody.section(.rawNotes, in: body) == "note")
        #expect(MeetingBody.section(.transcript, in: body) == md)
    }

    @Test func languageTagRoundTrips() {
        let line = MeetingTranscript.Line(time: "10:32", speaker: "Others", text: "Vi beholder eksportformatet.", language: "da")
        #expect(line.markdown == "- 10:32 [da] **Others:** Vi beholder eksportformatet.")
        #expect(MeetingTranscript.parse(line.markdown) == [line])
        #expect(MeetingTranscript.parse("- 10:33 **You:** [sic] ok").first?.text == "[sic] ok")
    }

    @Test func transcriptSummaryPartsMergeIntoSummary() {
        let md = "Intro line.\n\n### Upload format\n- Export formats, per device\n\n### Release\nShips in 1.1."
        let parts = TranscriptSummary.parts(md)
        #expect(parts.map(\.title) == ["", "Upload format", "Release"])
        #expect(parts[1].body == "- Export formats, per device")
        let merged = TranscriptSummary.merged(summary: "## Decisions\n- A\n", keeping: [parts[2]])
        #expect(merged == "## Decisions\n- A\n\n## From the conversation\n\n### Release\n\nShips in 1.1.")
        #expect(TranscriptSummary.merged(summary: "S", keeping: []) == "S")

        var body = "\n## Raw notes\nnote\n\n## Transcript\n- 10:00 **You:** hi\n\n## Summary\nsum\n"
        body = MeetingBody.setting(.transcriptSummary, to: md, in: body)
        let ts = body.range(of: "## Transcript summary")!.lowerBound
        #expect(body.range(of: "## Transcript\n")!.lowerBound < ts)
        #expect(ts < body.range(of: "## Summary")!.lowerBound)
        #expect(MeetingBody.section(.transcript, in: body) == "- 10:00 **You:** hi")
        #expect(MeetingBody.section(.transcriptSummary, in: body) == md)
        body = MeetingBody.removing(.transcriptSummary, in: body)
        body = MeetingBody.removing(.transcript, in: body)
        #expect(body == "\n## Raw notes\nnote\n\n## Summary\nsum\n")
    }
}

@Suite struct SessionWindowTests {
    @Test func choicesBlocksBecomeOptions() {
        let reply = """
        **3. Sprint**
        Sprint 25 runs until 23 Nov.

        ```choices
        Sprint 25 (Recommended)
        - Comet Post launch
        No sprint
        ```
        """
        let blocks = MarkdownBlocks.parse(reply)
        #expect(blocks.first == .paragraph("**3. Sprint**\nSprint 25 runs until 23 Nov."))
        #expect(blocks.last == .choices(multi: false, options: ["Sprint 25 (Recommended)", "Comet Post launch", "No sprint"]))
        #expect(MarkdownBlocks.trailingChoices(reply)?.options.count == 3)
        #expect(MarkdownBlocks.trailingChoices("```choices multi\nAndroid\niOS\n```")?.multi == true)
        #expect(MarkdownBlocks.trailingChoices("```choices\nA\n```\n\n## Done\nok") == nil)
    }

    @Test func blocksKeepStructure() {
        let md = """
        ## Summary
        Text with `code`.

        - [ ] open
        - [x] done
        1. first
           continued
          - nested
        > quoted

        | A | B |
        |---|---|
        | 1 | 2 |

        ```swift
        let x = 1
        ```
        ---
        """
        let blocks = MarkdownBlocks.parse(md)
        #expect(blocks == [
            .heading(level: 2, text: "Summary"),
            .paragraph("Text with `code`."),
            .listItem(indent: 0, marker: "", checked: false, text: "open"),
            .listItem(indent: 0, marker: "", checked: true, text: "done"),
            .listItem(indent: 0, marker: "1.", checked: nil, text: "first continued"),
            .listItem(indent: 1, marker: "•", checked: nil, text: "nested"),
            .quote("quoted"),
            .table(header: ["A", "B"], rows: [["1", "2"]]),
            .code(language: "swift", text: "let x = 1"),
            .rule,
        ])
    }

    @Test func streamReportsCommandsToolDetailsAndDenials() {
        #expect(ClaudeStreamLine.parse(#"{"type":"system","subtype":"init","session_id":"s","slash_commands":["kb:create-pbi","review"]}"#)
            == [.initialized(sessionID: "s"), .commands(["kb:create-pbi", "review"])])
        #expect(ClaudeStreamLine.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"kb tracker sprints\n--project x"}}]}}"#)
            == [.toolUse("Bash"), .toolDetail(name: "Bash", summary: "kb tracker sprints --project x\tkb tracker sprints\n--project x")])
        #expect(ClaudeStreamLine.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b/SKILL.md"}}]}}"#)
            == [.toolUse("Read"), .toolDetail(name: "Read", summary: "SKILL.md")])
        #expect(ClaudeStreamLine.parse(#"{"type":"result","subtype":"success","result":"x","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"npm test"}}]}"#)
            == [.denied(["Bash(npm test)"]), .result(text: "x", isError: false)])
    }

    @Test func sessionStoreRoundTripsAndPrunes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("sessions.json")
        let now = Date()
        let fresh = SessionRecord(title: "PBI", project: "p", claudeSessionID: "c1", workingDirectory: "/tmp", updated: now,
                                  extraTools: ["Bash(npm:*)"], messages: [.init(role: "user", text: "hi")])
        let old = SessionRecord(title: "Old", project: nil, workingDirectory: "/tmp", updated: now.addingTimeInterval(-40 * 86_400),
                                messages: [.init(role: "user", text: "x")])
        let empty = SessionRecord(title: "Empty", project: nil, workingDirectory: "/tmp", updated: now)
        try SessionStore.save([old, fresh, empty], to: url, now: now)
        let loaded = SessionStore.load(from: url)
        #expect(loaded.map(\.title) == ["PBI"])
        #expect(loaded.first?.claudeSessionID == "c1" && loaded.first?.extraTools == ["Bash(npm:*)"])
        #expect(loaded.first?.messages == [.init(role: "user", text: "hi")])
    }

    @Test func sessionPromptAndLaunchFlags() {
        let p = ClaudeModes.session(project: "acme-go", projectTitle: "Acme Go", kbRoot: "/kb")
        #expect(p.contains("```") == false && p.contains("`choices`") && p.contains("--project acme-go"))
        var launch = ClaudeLaunch(executable: URL(fileURLWithPath: "/bin/claude"), pluginRoot: "/p", systemPrompt: p,
                                  sessionID: "s", workingDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(!launch.arguments.contains("--disallowedTools"))
        launch.disallowedTools = ["AskUserQuestion"]
        #expect(launch.arguments.suffix(2) == ["--disallowedTools", "AskUserQuestion"])
    }
}

struct BuildModeTests {
    @Test func testCrewOrdersParse() {
        let send = #"{"kind":"send","to":"abc","text":"status?","from":"lead1","at":"2026-11-09T10:00:00Z"}"#
        #expect(CrewOrder.parse(Data(send.utf8)) == .send(to: "abc", text: "status?", from: "lead1"))
        let start = #"{"kind":"start","title":"Tests","parent":"lead1","lead":false,"project":"p","model":"haiku","strategy":null,"about":null,"text":"Write tests","from":"lead1"}"#
        #expect(CrewOrder.parse(Data(start.utf8)) == .start(.init(title: "Tests", parent: "lead1", project: "p", model: "haiku", text: "Write tests", from: "lead1")))
        #expect(CrewOrder.parse(Data(#"{"kind":"stop","to":"x"}"#.utf8)) == .stop(to: "x", from: "cli"))
        #expect(CrewOrder.parse(Data(#"{"kind":"archive","to":"x","from":"x"}"#.utf8)) == .archive(to: "x", from: "x"))
        #expect((CrewOrder.parse(Data(#"{"kind":"send","to":"x"}"#.utf8))) == nil)
        #expect((CrewOrder.parse(Data("not json".utf8))) == nil)
    }

    @Test func testStatusTextNestsMembersUnderLeads() {
        func s(_ id: String, _ title: String, _ role: SessionRole, lead: String? = nil, state: CrewSessionState = .idle) -> CrewState.Session {
            .init(id: id, title: title, role: role, lead: lead, project: "p", state: state, activity: "", strategy: nil,
                  model: nil, updated: "", last: "", about: nil)
        }
        let st = CrewState(updated: "", sessions: [
            s("o", "Overview", .overseer), s("l1", "Login", .lead, state: .working),
            s("m1", "Login tests", .member, lead: "l1"), s("x", "Loose", .solo),
        ])
        let lines = st.statusText.components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("★ Login"))
        #expect(lines[1].hasPrefix("    - Login tests"))
        #expect(st.statusText.contains("Other sessions:\n  - Loose"))
        #expect(!(st.statusText.contains("Overview [")))
    }

    @Test func testStrategyRoundTripAndOverride() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plugin = tmp.appendingPathComponent("plugin/strategies")
        let kb = tmp.appendingPathComponent("kb")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try "---\ntitle: Auto crew\nsummary: Leads\nspawn: auto\nmax_sessions: 4\nmodel: sonnet\n---\n\nYou lead.\n"
            .write(to: plugin.appendingPathComponent("auto-crew.md"), atomically: true, encoding: .utf8)
        var list = StrategyStore.load(pluginRoot: tmp.appendingPathComponent("plugin"), kbRoot: kb)
        #expect(list.map(\.slug) == ["auto-crew"])
        #expect(list[0].spawns)
        #expect(list[0].maxSessions == 4)
        #expect(list[0].origin == .builtIn)
        #expect(list[0].message.contains("up to 4 sessions"))

        var changed = list[0]
        changed.instructions = "You lead: carefully."
        try StrategyStore.save(changed, kbRoot: kb)
        try StrategyStore.save(Strategy(slug: "mine", title: "Mine: careful", summary: "x", instructions: "Go slow."), kbRoot: kb)
        list = StrategyStore.load(pluginRoot: tmp.appendingPathComponent("plugin"), kbRoot: kb)
        #expect(list.map(\.slug) == ["auto-crew", "mine"])
        #expect(list[0].origin == .override)
        #expect(list[0].instructions == "You lead: carefully.")
        #expect(list[1].title == "Mine: careful")
        #expect(!(list[1].spawns))
        try StrategyStore.delete("auto-crew", kbRoot: kb)
        #expect(StrategyStore.load(pluginRoot: tmp.appendingPathComponent("plugin"), kbRoot: kb)[0].origin == .builtIn)
    }

    @Test func testOldSessionRecordsDecodeAsSolo() throws {
        let json = #"[{"id":"a","title":"T","workingDirectory":"/tmp","created":"2026-11-09T10:00:00Z","updated":"2026-11-09T10:00:00Z","extraTools":[],"messages":[{"role":"user","text":"hi"}]}]"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(json.utf8).write(to: url)
        let r = SessionStore.load(from: url)
        #expect(r.count == 1)
        #expect(r[0].role == .solo)
        #expect(!(r[0].strategyOffered))
    }

    @Test func testOverseerIsKeptEvenWhenEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try SessionStore.save([SessionRecord(title: "Overview", project: nil, workingDirectory: "/tmp", role: .overseer),
                               SessionRecord(title: "Empty", project: nil, workingDirectory: "/tmp")], to: url)
        #expect(SessionStore.load(from: url).map(\.title) == ["Overview"])
    }

    @Test func testDraftFlag() {
        let id = EntryID(project: "p", section: .followups, stem: "2026-11-09-x")
        let doc = EntryDocument(id: id, url: URL(fileURLWithPath: "/tmp/x.md"), text: "---\ntitle: X\ndraft: true\n---\n")
        #expect(doc.isDraft)
        var saved = doc
        saved.frontmatter.set("draft", nil)
        #expect(!(saved.isDraft))
        #expect(saved.isDirty)
    }

    @Test func testCrewPromptsNameTheCommands() {
        let member = ClaudeModes.crew(role: .member, sessionID: "abc", leadTitle: "Login", leadID: "lead-123456", project: nil)
        #expect(member.contains("kb crew send lead"))
        #expect(member.contains("“Login”"))
        #expect(ClaudeModes.crew(role: .lead, sessionID: "abc", leadTitle: nil, leadID: nil, project: nil).contains("kb crew start --under me"))
        #expect(ClaudeModes.overseer(kbRoot: "/kb").contains("kb crew start --lead"))
        #expect(ClaudeModes.factCheck(["p/decisions/x"]).contains("kb fact challenge"))
    }
}

struct ResolvedByTests {
    @Test func testTwoWorkItemsInOneString() {
        let r = ResolvedBy(values: ["https://dev.azure.com/Org/P/_workitems/edit/417801, https://dev.azure.com/Org/P/_workitems/edit/417802"])
        #expect(r.items.count == 2)
        if case .workItem(let n, _) = r.items[0] { #expect(n == "417801") } else { Issue.record("not a work item") }
        if case .workItem(let n, _) = r.items[1] { #expect(n == "417802") } else { Issue.record("not a work item") }
        #expect(r.text == "")
    }

    @Test func testMixedWordsEntryAndUrl() {
        let r = ResolvedBy(values: ["Agreed in p/decisions/2026-11-09-x and https://example.com/a."])
        #expect(r.items == [.entry(EntryID("p/decisions/2026-11-09-x")!), .url(URL(string: "https://example.com/a")!)])
        #expect(r.text == "Agreed in")
    }

    @Test func testPlainTextStaysAsIs() {
        let r = ResolvedBy(values: ["Tom confirmed it on Teams"])
        #expect(r.items.isEmpty)
        #expect(r.text == "Tom confirmed it on Teams")
    }

    @Test func testListValues() {
        let r = ResolvedBy(values: ["https://a.example/x", "https://a.example/x", "https://b.example/y"])
        #expect(r.items.count == 2)
    }
}

struct ResolvedByFrontmatterTests {
    @Test func testQuotedListFromTheCLI() {
        let text = "---\ntitle: Make PBIs\nresolved_by: [\"https://dev.azure.com/O/P/_workitems/edit/1\", \"https://dev.azure.com/O/P/_workitems/edit/2\"]\n---\n"
        let fm = FrontmatterCodec.parse(text).frontmatter
        let r = ResolvedBy(values: fm.list("resolved_by"))
        #expect(r.items.count == 2)
        #expect(r.text == "")
    }
}

struct SessionSpaceTests {
    @Test func testOldRecordsSplitByRole() throws {
        let json = #"[{"id":"a","title":"Plan one","workingDirectory":"/tmp","created":"2026-11-09T10:00:00Z","updated":"2026-11-09T10:00:00Z","messages":[{"role":"user","text":"hi"}]},{"id":"b","title":"Lead","workingDirectory":"/tmp","created":"2026-11-09T10:00:00Z","updated":"2026-11-09T10:00:00Z","messages":[{"role":"user","text":"hi"}],"role":"lead"}]"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(json.utf8).write(to: url)
        let r = SessionStore.load(from: url).sorted { $0.id < $1.id }
        #expect(r.map(\.space) == [.plan, .build])
    }

    @Test func testSpaceRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try SessionStore.save([SessionRecord(title: "Build solo", project: nil, workingDirectory: "/tmp",
                                             messages: [.init(role: "user", text: "x")], space: .build)], to: url)
        #expect(SessionStore.load(from: url).first?.space == .build)
    }
}

struct MyWorkTests {
    @Test func testDecodesTheCLIOutputAndFiltersBySprint() throws {
        let json = #"""
        {"fetched": "2026-11-10T08:00:00Z", "me": "Me", "sprints": {"app": "P\\2026\\Sprint 25"},
         "items": [
          {"id": 1, "type": "pbi", "title": "One", "state": "New", "sprint": "P\\2026\\Sprint 25", "changed": "", "project": "app",
           "url": "https://x/1", "stage": "not_started", "prs": []},
          {"id": 2, "type": "bug", "title": "Two", "state": "New", "sprint": "P", "changed": "", "project": "app",
           "url": "https://x/2", "stage": "not_started", "prs": []},
          {"id": 3, "type": "pbi", "title": "Three", "state": "Committed", "sprint": "P\\2026\\Sprint 25", "changed": "", "project": "app",
           "url": "https://x/3", "stage": "in_pr", "prs": [{"id": 10, "title": "PR", "repo": "app", "url": "https://x/pr/10", "draft": false, "author": "Me"}]}],
         "reviews": [{"id": 11, "title": "Theirs", "repo": "app", "url": "https://x/pr/11", "draft": false, "author": "Bob",
                      "project": "app", "required": false, "assigned": false}]}
        """#
        let w = try MyWork.decode(json)
        #expect(w.items(.notStarted, currentSprintOnly: false).map(\.id) == [1, 2])
        #expect(w.items(.notStarted, currentSprintOnly: true).map(\.id) == [1])
        #expect(w.items(.inPR, currentSprintOnly: true).first?.prs.first?.id == 10)
        #expect(w.items[0].sprintName == "Sprint 25")
        #expect(w.items[1].isBug)
        #expect(w.reviews.first?.sessionKey == "pr:11")
    }
}

struct CapturePromptTests {
    @Test func testPlanChatsAskBeforeRecordingInTheRightProject() {
        for p in [ClaudeModes.prepare("p/meetings/x"), ClaudeModes.session(project: "p", projectTitle: "P", kbRoot: "/kb"),
                  ClaudeModes.goal("goals/g"), ClaudeModes.ask("p")] {
            #expect(p.contains("Record what the user tells you"))
            #expect(p.contains("--field status=done"))
            #expect(p.contains("not by where this session runs"))
        }
        #expect(ClaudeModes.prepare("p/meetings/x").contains("`choices` block"))
        #expect(!ClaudeModes.ask("p").contains("```choices"))
    }
}

struct ScopeTests {
    @Test func testV2RegistryGroupsScopesAndEntriesShowInTaggedScopes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("projects/acme-go/facts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("projects/android/facts"), withIntermediateDirectories: true)
        let r = Registry(projects: [.init(id: "acmego", title: "Acme Go")],
                         scopes: [.init(id: "acme-go", title: "Product-wide", project: "acmego", wide: true),
                                  .init(id: "android", title: "Android", project: "acmego", paths: ["~/a"])])
        try r.save(root: dir)
        try "---\ntitle: Shared rule with Android details\nscopes: [acme-go, android]\n---\n"
            .write(to: dir.appendingPathComponent("projects/acme-go/facts/shared.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: Product only\n---\n".write(to: dir.appendingPathComponent("projects/acme-go/facts/only.md"), atomically: true, encoding: .utf8)
        let index = try KBIndex.load(root: dir)
        #expect(index.groups.map(\.title) == ["Acme Go"])
        #expect(index.project("android")?.group == "acmego")
        #expect(index.project("acme-go")?.wide == true)
        #expect(index.siblings(of: "acme-go").map(\.id) == ["android"])
        #expect(index.entries(project: "android", section: .facts).map(\.title) == ["Shared rule with Android details"])
        #expect(index.entries(project: "acme-go", section: .facts).count == 2)
        #expect(index.entries(project: "android", section: .facts).first?.scopes == ["acme-go", "android"])
        let reloaded = try Registry.load(dir.appendingPathComponent("kb.json"))
        #expect(reloaded == r)
    }

    @Test func testProjectWideShowsAllAndAScopeShowsWhatItIncludes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let r = Registry(projects: [.init(id: "acmego", title: "Acme Go")],
                         scopes: [.init(id: "wide", title: "Product-wide", project: "acmego", wide: true),
                                  .init(id: "android", title: "Android", project: "acmego"),
                                  .init(id: "ios", title: "iOS", project: "acmego"),
                                  .init(id: "vault", title: "Vault", project: "acmego"),
                                  .init(id: "mobile", title: "Mobile", project: "acmego", includes: ["android", "ios"])])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try r.save(root: dir)
        for (scope, title) in [("android", "A"), ("ios", "I"), ("vault", "S"), ("mobile", "M")] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("projects/\(scope)/facts"), withIntermediateDirectories: true)
            try "---\ntitle: \(title)\n---\n".write(to: dir.appendingPathComponent("projects/\(scope)/facts/f.md"), atomically: true, encoding: .utf8)
        }
        try "---\ntitle: Overview\n---\n".write(to: dir.appendingPathComponent("projects/android/overview.md"), atomically: true, encoding: .utf8)
        let index = try KBIndex.load(root: dir)
        #expect(index.members(of: "mobile") == ["mobile", "android", "ios"])
        #expect(Set(index.entries(project: "mobile", section: .facts).map(\.title)) == ["A", "I", "M"])
        #expect(Set(index.entries(project: "wide", section: .facts).map(\.title)) == ["A", "I", "S", "M"])
        #expect(index.count(project: "wide", section: .facts) == 4)
        #expect(index.entries(project: "android", section: .facts).map(\.title) == ["A"])
        #expect(index.entries(project: "wide", section: .overview).isEmpty)
        #expect(try Registry.load(dir.appendingPathComponent("kb.json")) == r)
    }

    @Test func testV1RegistryEachScopeIsItsOwnProject() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"version": 1, "projects": [{"id": "a", "title": "A"}, {"id": "b", "title": "B"}]}"#
            .write(to: dir.appendingPathComponent("kb.json"), atomically: true, encoding: .utf8)
        let index = try KBIndex.load(root: dir)
        #expect(index.groups.map(\.id) == ["a", "b"])
        #expect(index.siblings(of: "a").isEmpty)
        let r = try Registry.load(dir.appendingPathComponent("kb.json"))
        #expect(r.problem == nil)
        #expect(r.scopes.filter { !$0.wide }.isEmpty)
    }

    @Test func testRegistryProblems() {
        var r = Registry(projects: [.init(id: "p", title: "P")], scopes: [.init(id: "p", title: "P", project: "p")])
        #expect(r.problem == "P needs exactly one project-wide scope.")
        r.scopes[0].wide = true
        #expect(r.problem == nil)
        r.scopes.append(.init(id: "Bad Id", title: "X", project: "p"))
        #expect(r.problem?.contains("can't be a scope id") == true)
        #expect(Registry.slug("Localization catalog") == "localization-catalog")
    }
}

struct ScopeTaggingPromptTests {
    @Test func testTaggerPromptSetsScopesWithTheCLIOnly() {
        let p = ClaudeModes.scopeTagging(["acme-go/facts/x"])
        #expect(p.contains("kb scopes <id> --set"))
        #expect(p.contains("`acme-go/facts/x`"))
        #expect(p.contains("never edit anything else"))
    }
}

struct OneLineTitleTests {
    @Test func testEscapedAndRealLineBreaksBecomeSpaces() {
        #expect(KBEntry.oneLine("Profile alignments\\nProfile screen alignment") == "Profile alignments Profile screen alignment")
        #expect(KBEntry.oneLine("  Two\nlines  ") == "Two lines")
        let id = EntryID(project: "p", section: .followups, stem: "x")
        let e = KBEntry(id: id, url: URL(fileURLWithPath: "/x.md"), text: "---\ntitle: \"A\\nB\"\n---\n")
        #expect(e.title == "A B")
    }
}


struct TrackerBacklogTests {
    @Test func testDecodesAndSplitsByOwnerAndScope() throws {
        let json = """
        {"fetched": "2026-11-10T10:00:00Z", "me": "Me", "sprints": {"android": "P\\\\2026\\\\Sprint 25"}, "items": [
          {"id": 1, "type": "pbi", "title": "Mine", "state": "Committed", "stage": "in_progress", "scope": "android",
           "scopes": ["android"], "tags": [], "assignee": "Me", "mine": true, "sprint": "P\\\\2026\\\\Sprint 25",
           "changed": "2026-11-09", "url": "u", "prs": [], "tasks_done": 1, "tasks_total": 3},
          {"id": 2, "type": "bug", "title": "Theirs", "state": "New", "stage": "not_started", "scope": "android",
           "scopes": ["android", "ios"], "assignee": "Someone", "mine": false, "sprint": "P", "changed": "2026-11-08", "url": "u"},
          {"id": 3, "type": "pbi", "title": "Nobody's", "state": "New", "stage": "not_started", "scope": "ios",
           "assignee": "", "mine": false, "sprint": "", "changed": "", "url": "u"}
        ]}
        """
        let b = try TrackerBacklog.decode(json)
        #expect(b.items.map(TrackerBacklog.owner) == [.me, .others, .nobody])
        #expect(b.items(in: ["android"]).map(\.id) == [1, 2])
        #expect(b.items(in: ["ios"]).map(\.id) == [2, 3])
        #expect(b.isInCurrentSprint(b.items[0]))
        #expect(!b.isInCurrentSprint(b.items[1]))
        #expect(b.items[0].sprintName == "Sprint 25")
        #expect(b.items[2].scopes == ["ios"])
        #expect(b.items[0].asMyWork.project == "android")
    }

    @Test func testSprintFilterPicksPreviousCurrentAndNext() throws {
        func sp(_ n: Int, _ when: String) -> TrackerBacklog.Sprint {
            .init(name: "Sprint \(n)", path: "P\\Sprint \(n)", start: "2026-0\(n % 9 + 1)-01", finish: "2026-0\(n % 9 + 1)-14", when: when)
        }
        func item(_ id: Int, _ sprint: String) -> TrackerBacklog.Item { .init(id: id, title: "x", scope: "a", sprint: sprint) }
        var b = TrackerBacklog(items: [item(1, "P\\Sprint 24"), item(2, "P\\Sprint 25"), item(3, "P\\Sprint 26"), item(4, "P"), item(5, "P\\Sprint 22")])
        b.sprintList = [sp(22, "past"), sp(24, "past"), sp(25, "current"), sp(26, "future")]
        #expect(b.items.filter { b.matches($0, .current) }.map(\.id) == [2])
        #expect(b.items.filter { b.matches($0, .previous) }.map(\.id) == [1])
        #expect(b.items.filter { b.matches($0, .next) }.map(\.id) == [3])
        #expect(b.items.filter { b.matches($0, .none) }.map(\.id) == [4])
        #expect(b.items.filter { b.matches($0, .all) }.count == 5)
        b.sprintList = [sp(24, "past"), sp(25, "current")]
        #expect(b.sprint(.next) == nil)
        #expect(b.items.filter { b.matches($0, .next) }.isEmpty)
    }
}


struct PeopleTests {
    @Test func testInitialsAndSearchPreferTheKBsOwnPeople() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = dir.appendingPathComponent("dir.json")
        try #"{"fetched": "2026-11-10T10:00:00Z", "people": [{"name": "Petra Gray Hill", "email": "pgh@example.com"}, {"name": "Erik Nord", "email": "ext1001@example.com"}, {"name": "Peder Hanley", "email": "phan@example.com"}]}"#
            .write(to: cache, atomically: true, encoding: .utf8)
        try #"{"people": [{"name": "Ole from Contoso", "source": "manual"}, {"name": "Peder Hanley", "email": "phan@example.com"}]}"#
            .write(to: dir.appendingPathComponent("people.json"), atomically: true, encoding: .utf8)
        let people = People.load(root: dir, cache: cache)
        #expect(people.all.count == 4)
        #expect(people.fetched != nil)
        #expect(people.person(named: "Petra Gray Hill")?.initials == "PGH")
        #expect(people.person(named: "Erik Nord")?.initials == "EN")
        #expect(people.person(named: "Ole from Contoso")?.isManual == true)
        #expect(people.search("pgh").first?.name == "Petra Gray Hill")
        #expect(people.search("pe").map(\.name) == ["Peder Hanley", "Petra Gray Hill"])
        #expect(people.search("nord").first?.name == "Erik Nord")
        #expect(people.search("ole").first?.name == "Ole from Contoso")
        #expect(people.search("pe", excluding: ["peder hanley"]).map(\.name) == ["Petra Gray Hill"])
        #expect(people.person(named: "Peder Hanley")?.known == true)
        #expect(People.initials(name: "Anne-Marie Berg", email: "") == "AB")
    }
}
