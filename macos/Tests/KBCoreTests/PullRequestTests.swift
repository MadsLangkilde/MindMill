import Foundation
import Testing
@testable import KBCore

struct PullRequestTests {
    @Test func decodesTheCLIsJSON() throws {
        let json = """
        {"fetched": "2026-11-12T09:00:00Z", "prs": [{"id": 7, "title": "Fix it", "repo": "app", "repo_id": "r1", "scope": "android",
          "url": "https://x/7", "draft": false, "author": "Me", "source": "feature/a", "target": "main", "created": "2026-11-11",
          "merge_status": "succeeded", "auto_complete": false,
          "reviewers": [{"name": "Ana", "vote": 10, "required": true, "vote_name": "approved"}, {"name": "Bo", "vote": 0, "required": false, "vote_name": "no vote"}],
          "work_items": [123], "open_threads": 2, "threads_total": 3,
          "policies": [{"name": "Build", "kind": "Build", "status": "approved", "blocking": true}],
          "blockers": ["2 open comments"], "strategies": ["squash"], "keep_branch": false}]}
        """
        let list = try PullRequestList.decode(json)
        let pr = try #require(list.pr(7))
        #expect(pr.approvals == 1)
        #expect(!pr.canComplete)
        #expect(pr.workItems == [123])
        #expect(pr.policies.first?.passed == true)
        #expect(list.needingAnswers == 1)
        #expect(pr.threads == nil)
    }

    @Test func openThreadsComeFirstThenNewest() {
        let pr = PullRequest(id: 1, title: "t", threads: [
            .init(id: 1, status: "fixed", published: "2026-11-10"),
            .init(id: 2, status: "active", published: "2026-11-09"),
            .init(id: 3, status: "pending", published: "2026-11-11"),
            .init(id: 4, status: "closed", published: "2026-11-12"),
        ])
        #expect(pr.sortedThreads.map(\.id) == [3, 2, 4, 1])
    }

    @Test func threadNamesItsFile() {
        let t = PullRequest.Thread(id: 1, status: "fixed", file: "/a/b/C.kt", line: 4)
        #expect(t.fileName == "C.kt")
        #expect(t.statusTitle == "Resolved")
        #expect(!t.isOpen)
    }
}

struct TrackerTaskTests {
    private func item(_ stage: TrackerBacklog.Stage, _ states: [String]) -> TrackerBacklog.Item {
        TrackerBacklog.Item(id: 1, title: "x", stage: stage, scope: "a",
                            tasks: states.enumerated().map { .init(id: 10 + $0.offset, title: "t\($0.offset)", state: $0.element) })
    }

    @Test func resolvedWithOpenTasksIsLoose() {
        let loose = item(.resolved, ["Done", "In Progress", "New"])
        #expect(loose.hasLooseTasks)
        #expect(loose.openTasks.map(\.id) == [11, 12])
        #expect(loose.tasksInProgress == 1)
        #expect(loose.tasksDone == 1)
        #expect(loose.tasksTotal == 3)
        #expect(!item(.done, ["Done", "Closed"]).hasLooseTasks)
        #expect(!item(.inProgress, ["New"]).hasLooseTasks)
    }

    @Test func onlyNotStartedCanStart() {
        #expect(item(.notStarted, []).canStart)
        for s in [TrackerBacklog.Stage.inProgress, .inPR, .resolved, .done] { #expect(!item(s, []).canStart) }
    }

    @Test func settingTasksUpdatesCounts() {
        var backlog = TrackerBacklog()
        backlog.items = [item(.resolved, ["Done", "New", "New"])]
        let after = backlog.settingTasks([11, 12], to: "Done")
        #expect(after.items[0].tasksDone == 3)
        #expect(!after.items[0].hasLooseTasks)
    }

    @Test func decodesTasksFromTheBacklog() throws {
        let json = """
        {"fetched": "", "me": "", "sprints": {}, "items": [{"id": 5, "type": "pbi", "title": "x", "state": "Resolved", "stage": "resolved",
          "scope": "a", "tasks_done": 0, "tasks_total": 1, "tasks": [{"id": 9, "title": "Device check", "state": "New", "assignee": ""}]}]}
        """
        let b = try TrackerBacklog.decode(json)
        #expect(b.items[0].tasks.first?.title == "Device check")
        #expect(b.items[0].hasLooseTasks)
    }
}
