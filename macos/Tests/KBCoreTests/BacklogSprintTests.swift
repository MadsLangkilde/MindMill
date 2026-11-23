import Foundation
import Testing
@testable import KBCore

@Suite struct BacklogSprintTests {
    private let sprints: [TrackerBacklog.Sprint] = [
        .init(name: "S1", path: "P\\S1", when: "past"),
        .init(name: "S2", path: "P\\S2", when: "past"),
        .init(name: "S3", path: "P\\S3", when: "past"),
        .init(name: "S4", path: "P\\S4", when: "current"),
        .init(name: "S5", path: "P\\S5", when: "future"),
        .init(name: "S6", path: "P\\S6", when: "future"),
        .init(name: "S7", path: "P\\S7", when: "future"),
    ]

    private func item(_ id: Int, _ sprint: String, _ stage: TrackerBacklog.Stage, tasks: [TrackerBacklog.Task] = []) -> TrackerBacklog.Item {
        .init(id: id, title: "Item \(id)", stage: stage, scope: "a", sprint: sprint, tasks: tasks)
    }

    @Test func pastSprintsShowOnlyWithWorkLeft() {
        let items = [
            item(1, "P\\S1", .done),
            item(2, "P\\S2", .inProgress),
            item(3, "P\\S3", .done, tasks: [.init(id: 30, title: "t", state: "To Do")]),
            item(4, "P\\S7", .notStarted),
        ]
        let backlog = TrackerBacklog(items: items, sprintList: sprints)
        #expect(backlog.shownSprints(for: items).map(\.name) == ["S2", "S3", "S4", "S5", "S7"])
        #expect(backlog.olderSprints(for: items).map(\.name) == ["S1"])
    }

    @Test func olderSprintsAreNewestFirst() {
        let backlog = TrackerBacklog(sprintList: sprints)
        #expect(backlog.olderSprints(for: []).map(\.name) == ["S3", "S2", "S1"])
    }

    @Test func movingAndSettingStateUpdateLocally() {
        let backlog = TrackerBacklog(items: [item(1, "P\\S2", .inProgress), item(2, "P\\S2", .notStarted)], sprintList: sprints)
        let moved = backlog.moving([1], to: "P\\S4")
        #expect(moved.item(1)?.sprint == "P\\S4")
        #expect(moved.item(2)?.sprint == "P\\S2")

        let done = backlog.setting([1], to: .init(name: "Done", category: "Completed"))
        #expect(done.item(1)?.stage == .done)
        #expect(done.item(1)?.state == "Done")

        let removed = backlog.setting([2], to: .init(name: "Removed", category: "Removed"))
        #expect(removed.item(2) == nil)
        #expect(removed.item(1) != nil)
    }

    @Test func statesFallBackToScrum() throws {
        let json = """
        {"fetched": "", "me": "", "sprints": {}, "items": [],
         "states": {"bug": [{"name": "New", "category": "Proposed"}, {"name": "Closed", "category": "Completed"}]}}
        """
        let backlog = try TrackerBacklog.decode(json)
        #expect(backlog.states(for: .init(id: 1, type: "bug", title: "b", scope: "a")).map(\.name) == ["New", "Closed"])
        #expect(backlog.states(for: .init(id: 2, title: "p", scope: "a")).map(\.name)
                == ["New", "Approved", "Committed", "Done", "Removed"])
    }

    @Test func moveTargetsAreCurrentAndLaterUnderTheSameRoot() {
        var list = sprints
        list.append(.init(name: "Sprint 9", path: "Other\\Sprint 9", when: "future"))
        let backlog = TrackerBacklog(sprints: ["a": "P\\S4"], sprintList: list)
        #expect(backlog.moveTargets(for: item(1, "P\\S2", .inProgress)).map(\.name) == ["S4", "S5", "S6", "S7"])
        #expect(backlog.currentSprint(scope: "b")?.name == "S4")
    }

    @Test func mergeKeepsBaseAndAddsTheRest() {
        let merged = TrackerBacklog.merge([item(1, "P\\S1", .inProgress)], [item(1, "P\\S1", .done), item(2, "P\\S1", .done)])
        #expect(merged.map(\.id) == [1, 2])
        #expect(merged[0].stage == .inProgress)
    }
}
