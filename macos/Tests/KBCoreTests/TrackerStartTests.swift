import Foundation
import Testing
@testable import KBCore

@Suite struct TrackerStartTests {
    @Test func eachTrackerKindHasItsRoute() {
        #expect(TrackerStart.route(kind: "azure-devops") == .cli)
        #expect(TrackerStart.route(kind: "local") == .local)
        #expect(TrackerStart.route(kind: "") == .none)
        #expect(TrackerStart.route(kind: "jira") == .claude("Jira"))
        #expect(TrackerStart.route(kind: "linear") == .claude("Linear"))
    }

    @Test func onlyConnectorTrackersAddANoteToTheSession() {
        #expect(TrackerStart.sessionNote(kind: "azure-devops", ref: "#5") == nil)
        #expect(TrackerStart.sessionNote(kind: "local", ref: "#5") == nil)
        let note = TrackerStart.sessionNote(kind: "jira", ref: "work item #5")
        #expect(note?.contains("work item #5") == true)
        #expect(note?.contains("Jira connector") == true)
    }

    @Test func startingMovesOnlyUnstartedItems() {
        var t = LocalTracker()
        let p = t.add(.pbi, title: "P", now: "t")
        let task = t.add(.task, title: "x", parent: p, now: "t")
        let first = t.start(p, now: "t2")
        let again = t.start(p, now: "t3")
        let taskStarted = t.start(task, now: "t2")
        #expect(first && !again && taskStarted)
        #expect(t.item(p)?.state == "Committed")
        #expect(t.item(task)?.state == "In Progress")
        t.setState(p, "Done", now: "t4")
        #expect(t.startedState(p) == nil)
        #expect(t.startedState(99) == nil)
    }
}
