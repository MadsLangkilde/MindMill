import Foundation
import Testing
@testable import KBCore

@Suite struct LocalTrackerTests {
    @Test func itemsHangUnderTheirParentsInOrder() {
        var t = LocalTracker()
        let f = t.add(.feature, title: "Login", now: "t")
        let a = t.add(.pbi, title: "Sign in", parent: f, now: "t")
        let b = t.add(.bug, title: "Crash", parent: f, now: "t")
        let task = t.add(.task, title: "UI", parent: a, now: "t")
        #expect(t.children(of: f).map(\.id) == [a, b])
        #expect(t.item(task)?.state == "To Do")
        #expect(t.item(a)?.state == "New")
        // A feature never gets a parent.
        let g = t.add(.feature, title: "Other", parent: a, now: "t")
        #expect(t.item(g)?.parent == nil)
        t.reorder(b, before: a)
        #expect(t.children(of: f).map(\.id) == [b, a])
    }

    @Test func statesFollowTheKindAndTasksCountTowardProgress() {
        var t = LocalTracker()
        let p = t.add(.pbi, title: "P", now: "t")
        let x = t.add(.task, title: "x", parent: p, now: "t")
        _ = t.add(.task, title: "y", parent: p, now: "t")
        t.setState(x, "Done", now: "t2")
        t.setState(p, "In Progress", now: "t2")
        #expect(t.item(p)?.state == "New")
        #expect(t.taskProgress(p) == (1, 2))
        #expect(t.item(x)?.changed == "t2")
        t.delete(p)
        #expect(t.items.isEmpty)
    }

    @Test func aChangeoverDayIsTheNewSprints() {
        let json = #"{"version":1,"next_id":1,"use_sprints":true,"sprints":[{"name":"S25","start":"2026-11-09","finish":"2026-11-23"},{"name":"S26","start":"2026-11-23","finish":"2026-12-06"}],"items":[]}"#
        let t = LocalTracker.parse(Data(json.utf8))
        #expect(t.currentSprint(today: "2026-11-23")?.name == "S26")
        #expect(t.currentSprint(today: "2026-11-22")?.name == "S25")
    }

    @Test func theFileKeepsKeysTheAppDoesNotKnow() throws {
        let json = #"{"version":1,"next_id":3,"use_sprints":true,"custom":"keep","sprints":[{"name":"S1","start":"2026-11-10","finish":"2026-11-23"}],"items":[{"id":2,"type":"pbi","title":"A","state":"Committed","parent":null,"sprint":"S1","assignee":"","tags":[],"description":"d","acceptance":"- ok","repro":"","effort":3,"order":1,"created":"c","changed":"c","rank":"x"}]}"#
        var t = LocalTracker.parse(Data(json.utf8))
        #expect(t.useSprints)
        #expect(t.currentSprint(today: "2026-11-17")?.name == "S1")
        #expect(t.item(2)?.effort == 3)
        t.setState(2, "Done", now: "n")
        let back = try JSONSerialization.jsonObject(with: t.serialized()) as? [String: Any]
        #expect(back?["custom"] as? String == "keep")
        let item = (back?["items"] as? [[String: Any]])?.first
        #expect(item?["rank"] as? String == "x")
        #expect(item?["state"] as? String == "Done")
        #expect(item?["parent"] is NSNull)
        #expect(LocalTracker.parse(try t.serialized()) == t)
    }

    @Test func workItemsBecomeMyWorkAndABrief() {
        var t = LocalTracker()
        let f = t.add(.feature, title: "Login", now: "t")
        let p = t.add(.pbi, title: "Sign in", parent: f, now: "t")
        var item = t.item(p)!
        item.description = "Users sign in."
        item.acceptance = "- Works"
        item.state = "Committed"
        t.update(item, now: "t")
        #expect(t.asMyWork(t.item(p)!, scope: "app").stage == .inProgress)
        let brief = t.brief(t.item(p)!)
        #expect(brief.contains("Part of feature #\(f): Login"))
        #expect(brief.contains("## Acceptance criteria"))
    }

    @Test func theBacklogTreeFollowsSprintAndDone() {
        var t = LocalTracker()
        let f = t.add(.feature, title: "F", now: "t")
        let a = t.add(.pbi, title: "A", parent: f, sprint: "S1", now: "t")
        let b = t.add(.bug, title: "B", parent: f, now: "t")
        let task = t.add(.task, title: "x", parent: a, now: "t")
        let loose = t.add(.pbi, title: "Loose", now: "t")
        t.setState(b, "Done", now: "t")
        #expect(t.tree(sprint: nil, showDone: false).map(\.item.id) == [f, a, task, loose])
        #expect(t.tree(sprint: nil, showDone: false).map(\.depth) == [0, 1, 2, 0])
        #expect(t.tree(sprint: "S1", showDone: false).map(\.item.id) == [f, a, task])
        #expect(t.tree(sprint: nil, showDone: true).map(\.item.id) == [f, a, task, b, loose])
    }
}
