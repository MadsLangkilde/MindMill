import Foundation
import Testing
@testable import KBCore

struct FactoryDashboardTests {
    @Test func halfPanelsPairUpAndWidePanelsStandAlone() {
        let d = FactoryDashboard.standard
        #expect(d.rows.map { $0.map(\.kind) } == [[.board], [.details], [.history, .approvals]])
        var odd = d
        odd.remove(.approvals)
        odd.add(.stats)
        odd.setWide(.stats, false)
        #expect(odd.rows.map { $0.map(\.kind) } == [[.board], [.details], [.history, .stats]])
        odd.move(.stats, by: -3)
        #expect(odd.panels.map(\.kind) == [.stats, .board, .details, .history])
        #expect(odd.rows.map { $0.map(\.kind) } == [[.stats], [.board], [.details], [.history]])
    }

    @Test func movingAddingAndHiding() {
        var d = FactoryDashboard.standard
        d.move(.approvals, to: .board)
        #expect(d.panels.map(\.kind) == [.approvals, .board, .details, .history])
        d.move(.approvals, to: .history)
        #expect(d.panels.map(\.kind) == [.board, .details, .history, .approvals])
        #expect(d.hidden == [.questions, .stats, .rules])
        d.add(.board)
        #expect(d.panels.count == 4)
        d.add(.questions)
        #expect(d.panels.last?.kind == .questions && d.panels.last?.wide == false)
        d.setCollapsed(.history, true)
        #expect(d.panels.first { $0.kind == .history }?.collapsed == true)
    }

    @Test func oldFactoriesGetTheStandardLayoutAndUnknownPanelsAreSkipped() throws {
        let old = Factory.decodeList(Data(#"[{"id":"x","name":"Old","rules":{}}]"#.utf8))
        #expect(old.first?.dashboard == .standard)
        let json = #"[{"id":"x","name":"N","rules":{},"dashboard":{"panels":[{"kind":"future"},{"kind":"history","wide":false},{"kind":"board"},{"kind":"board"}]}}]"#
        let f = try #require(Factory.decodeList(Data(json.utf8)).first)
        #expect(f.dashboard.panels.map(\.kind) == [.history, .board])
        let back = Factory.decodeList(try #require(Factory.encodeList([f])))
        #expect(back.first?.dashboard == f.dashboard)
    }

    @Test func workItemDetailDecodes() throws {
        let d = try WorkItemDetail.decode(#"{"id":5,"title":"T","state":"New","type":"Bug","iteration":"I","assignee":"A","tags":["x"],"description":"D","acceptance":"","repro":"R","url":"u"}"#)
        #expect(d.repro == "R" && d.tags == ["x"])
    }
}

struct FactoryCoverageTests {
    @Test func onlyVerdictsForAskedQuestionsCount() {
        let a = UUID(), b = UUID()
        let open = [FactoryCoverage.Open(id: a, text: "Retry three times?", workItem: 1), .init(id: b, text: "Which icon?", workItem: nil)]
        let prompt = FactoryCoverage.prompt(known: [.init(id: "answer:1", text: "Keep the session offline")], open: open)
        #expect(prompt.contains(a.uuidString) && prompt.contains("(work item #1)") && prompt.contains("[answer:1] Keep the session offline"))
        let reply = """
        Here you go:
        [{"id": "\(a.uuidString.lowercased())", "answer": "Keep the session", "because": "your answer on #2"},
         {"id": "\(a.uuidString)", "answer": "dup", "because": "x"},
         {"id": "\(UUID().uuidString)", "answer": "stranger", "because": "x"},
         {"id": "\(b.uuidString)", "answer": " ", "because": "x"}]
        """
        let v = FactoryCoverage.parse(reply, open: open)
        #expect(v.map(\.answer) == ["Keep the session"])
        #expect(FactoryCoverage.parse("no json", open: open).isEmpty)
        #expect(FactoryCoverage.message(question: "Q?", answer: "A", because: "B").contains("(B): A"))
    }

    @Test func answeredForYouUntilDismissed() throws {
        var run = FactoryRun(endsAt: nil)
        var q = FactoryQuestion(sessionID: "s", workItem: 1, checkpoint: nil, text: "Q", options: [])
        run.questions = [q]
        #expect(run.openQuestions.count == 1 && run.answeredForYou.isEmpty)
        q.answer = "A"
        q.indirect = true
        q.coveredBy = "your answer on #2"
        run.questions = [q]
        #expect(run.openQuestions.isEmpty && run.answeredForYou.count == 1)
        run.questions[0].dismissed = true
        #expect(run.answeredForYou.isEmpty)
        var f = Factory(name: "F")
        f.run = run
        let back = Factory.decodeList(try #require(Factory.encodeList([f])))
        #expect(back.first?.run?.questions.first?.coveredBy == "your answer on #2")
    }
}

struct ScreenAreaTests {
    @Test func draggedAreasAreClampedAndScaled() throws {
        let size = CGSize(width: 200, height: 100)
        let a = try #require(ScreenArea.area(from: CGPoint(x: 150, y: 80), to: CGPoint(x: 50, y: -20), in: size))
        #expect(a == CGRect(x: 0.25, y: 0, width: 0.5, height: 0.8))
        #expect(ScreenArea.area(from: .zero, to: CGPoint(x: 2, y: 50), in: size) == nil)
        #expect(ScreenArea.pixels(a, width: 1000, height: 500) == CGRect(x: 250, y: 0, width: 500, height: 400))
        #expect(ScreenArea.pixels(CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5), width: 100, height: 100) == CGRect(x: 90, y: 90, width: 10, height: 10))
        #expect(ScreenArea.rect(a, in: size) == CGRect(x: 50, y: 0, width: 100, height: 80))
    }
}

struct FollowupCheckTests {
    @Test func theReportListsWhatItHandledAndUpdated() {
        let r = FollowupCheckReport("""
        HANDLED `app/followups/2026-11-04-who-signs` | answered by the sign-off decision
        UPDATED app/followups/2026-11-05-raw | Lena is asked first
        HANDLED  | nothing
        FOLLOWUPS 1 handled 1 updated
        """)
        #expect(r.handled.map(\.id) == ["app/followups/2026-11-04-who-signs"])
        #expect(r.handled.first?.why == "answered by the sign-off decision")
        #expect(r.updated.map(\.id) == ["app/followups/2026-11-05-raw"])
        #expect(FollowupCheckReport("FOLLOWUPS 0 handled 0 updated") == FollowupCheckReport(""))
        let prompt = ClaudeModes.followupCheck(["a/facts/x"], wide: "acmego")
        #expect(prompt.contains("`a/facts/x`") && prompt.contains("--auto") && prompt.contains("kb followup note"))
        #expect(prompt.contains("`acmego`") && prompt.contains("--all-projects"))
        #expect(FollowupStatus.dropped.handledTitle == "No longer needed")
    }
}

struct MeetingMaterialTests {
    @Test func materialsRoundTripAndSitAfterPrep() {
        let list = [MeetingMaterial(title: "Roadmap Q3.pdf", link: "2026-11-17-sync.files/Roadmap Q3.pdf", note: "Upload ships in sprint 4."),
                    MeetingMaterial(title: "example.com/spec", link: "https://example.com/spec")]
        let text = MeetingMaterial.render(list)
        #expect(text == "- [Roadmap Q3.pdf](<2026-11-17-sync.files/Roadmap Q3.pdf>) — Upload ships in sprint 4.\n- [example.com/spec](<https://example.com/spec>)")
        #expect(MeetingMaterial.parse(text) == list)
        #expect(MeetingMaterial.parse("- [Old](https://a.b/c) - a note\nnot a line") == [MeetingMaterial(title: "Old", link: "https://a.b/c", note: "a note")])
        #expect(list[1].isWeb && !list[0].isWeb)
        let body = MeetingBody.setting(.materials, to: text, in: "\n## Prep\n\nctx\n\n## Questions\n\n- [ ] Q\n")
        #expect(body.range(of: "## Prep")!.lowerBound < body.range(of: "## Materials")!.lowerBound)
        #expect(body.range(of: "## Materials")!.lowerBound < body.range(of: "## Questions")!.lowerBound)
        #expect(MeetingBody.section(.materials, in: body) == text)
        #expect(ClaudeModes.material("/x/a.pdf", title: "a.pdf", isWeb: false).contains("Read tool"))
        #expect(ClaudeModes.material("https://a", title: "a", isWeb: true).contains("WebFetch"))
    }
}

struct VagueSearchTests {
    @Test func closeMatchesFindMostWordsAndWordStarts() throws {
        let kb = try makeKB()
        try kb.write("projects/alpha/followups/2026-03-02-who-signs.md",
                     "---\ntitle: Who signs off the export format?\ndate: 2026-03-02\nstatus: open\n---\nAsk Lena.\n")
        try kb.write("projects/alpha/followups/2026-03-03-closed.md",
                     "---\ntitle: Upload batching\ndate: 2026-03-03\nstatus: done\nclosed_by: kb\n---\nFirst\n\n## Updates\n\n- 2026-03-04: Endpoint batches 10 (alpha/facts/zeta)\n")
        let index = try KBIndex.load(root: kb.url)
        // "signing" isn't in the text, but "sign" starts it; "export" is; "approval" isn't: two of three words.
        let loose = index.looseSearch("signing export approval", project: "alpha")
        #expect(loose.first?.title == "Who signs off the export format?")
        #expect(index.looseSearch("who signs off", project: "alpha").isEmpty, "strict matches are left to search()")
        #expect(index.looseSearch("ab", project: "alpha").isEmpty)
        let closed = try #require(index.entry(EntryID("alpha/followups/2026-03-03-closed")!))
        #expect(closed.closedByKB && closed.latestUpdate == "Endpoint batches 10 (alpha/facts/zeta)")
        #expect(index.entry(EntryID("alpha/followups/2026-03-02-who-signs")!)?.latestUpdate == nil)
    }

    @Test func findRepliesParse() {
        let hits = ClaudeModes.parseFind("Found:\n[{\"id\": \"alpha/facts/zeta\", \"why\": \"credit-bound transfers\"}, {\"why\": \"no id\"}]")
        #expect(hits.map(\.id) == ["alpha/facts/zeta"] && hits.first?.why == "credit-bound transfers")
        #expect(ClaudeModes.parseFind("nothing").isEmpty)
        #expect(ClaudeModes.find("the BLE thing", scope: "alpha").contains("`alpha`"))
    }
}
