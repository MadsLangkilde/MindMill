import Foundation
import Testing
@testable import KBCore

struct SprintWatchTests {
    let s41 = SprintInfo(name: "Sprint 41", path: "P\\R\\Sprint 41", start: "2026-11-02", finish: "2026-11-15")
    let s42 = SprintInfo(name: "Sprint 42", path: "P\\R\\Sprint 42", start: "2026-11-16", finish: "2026-11-29")
    let s43 = SprintInfo(name: "Sprint 43", path: "P\\R\\Sprint 43", start: "2026-11-30", finish: "2026-12-13")

    func running(_ cur: SprintInfo, prev: SprintInfo?, next: SprintInfo? = nil) -> TrackerSprints {
        TrackerSprints(key: "azure-devops:O/P:P\\R", kind: "azure-devops", scopes: ["app"], state: .running,
                       current: cur, previous: prev, next: next)
    }

    @Test func decodesTheCLIReport() throws {
        let json = """
        {"today": "2026-11-23", "trackers": [
          {"key": "local:app", "kind": "local", "scopes": ["app"], "reachable": true, "state": "ended",
           "current": null, "previous": {"name": "Sprint 1", "path": "Sprint 1", "start": "2026-11-02", "finish": "2026-11-15"},
           "next": null, "days_since_end": 8, "can_create": true, "create_url": "", "note": ""},
          {"key": "jira:web", "kind": "jira", "scopes": ["web"], "reachable": false, "state": "unknown", "note": "through Claude"}]}
        """
        let r = try SprintReport.decode(json)
        #expect(r.trackers.count == 2)
        #expect(r.tracker(scope: "app")?.state == .ended)
        #expect(r.tracker(scope: "app")?.daysSinceEnd == 8)
        #expect(r.tracker(scope: "web")?.throughClaude == true)
        #expect(r.tracker(scope: "web")?.reachable == false)
    }

    @Test func noticesANewSprintOnceAndNotAnOldOneOnFirstSight() {
        var w = SprintWatch()
        #expect(w.observe(running(s42, prev: s41), today: "2026-11-23") == nil)
        #expect(w.pending("azure-devops:O/P:P\\R", today: "2026-11-23") == nil)
        #expect(w.observe(running(s42, prev: s41), today: "2026-11-24") == nil)
        let p = w.observe(running(s43, prev: s42), today: "2026-11-30")
        #expect(p?.sprint == s42)
        #expect(p?.target == s43)
        #expect(w.observe(running(s43, prev: s42), today: "2026-12-01") == nil)
        #expect(w.pending("azure-devops:O/P:P\\R", today: "2026-12-01")?.sprint == s42)
    }

    @Test func aSprintThatJustStartedCountsAsNewOnFirstSight() {
        var w = SprintWatch()
        #expect(w.observe(running(s43, prev: s42), today: "2026-12-01")?.sprint == s42)
        var later = SprintWatch()
        #expect(later.observe(running(s43, prev: s42), today: "2026-12-05") == nil)
    }

    @Test func notNowComesBackTomorrowAndDoneReviewingNever() {
        let key = "azure-devops:O/P:P\\R"
        var w = SprintWatch()
        w.observe(running(s42, prev: s41), today: "2026-11-23")
        w.observe(running(s43, prev: s42), today: "2026-11-30")
        w.snooze(key, today: "2026-11-30")
        #expect(w.pending(key, today: "2026-11-30") == nil)
        #expect(w.pending(key, today: "2026-12-01") != nil)
        w.finish(key, sprint: s42.path)
        #expect(w.pending(key, today: "2026-12-02") == nil)
        w.observe(running(s43, prev: s42), today: "2026-12-02")
        #expect(w.pending(key, today: "2026-12-02") == nil)
        w.request(key, sprint: s42, target: s43, today: "2026-12-03")
        #expect(w.pending(key, today: "2026-12-03")?.sprint == s42)
    }

    @Test func endedWithoutANextSprintAsksForOneAndPicksTheNewOneUp() {
        let key = "local:app"
        let ended = TrackerSprints(key: key, kind: "local", scopes: ["app"], state: .ended, previous: s42, daysSinceEnd: 1, canCreate: true)
        var w = SprintWatch()
        w.observe(TrackerSprints(key: key, kind: "local", scopes: ["app"], state: .running, current: s42, previous: s41), today: "2026-11-25")
        let p = w.observe(ended, today: "2026-11-30")
        #expect(p?.sprint == s42)
        #expect(p?.target == nil)
        let report = SprintReport(today: "2026-11-30", trackers: [ended])
        let moments = SprintMoment.list(report, watch: w, today: "2026-11-30")
        #expect(moments.count == 1)
        #expect(moments[0].needsNextSprint)
        #expect(moments[0].headline == "Sprint 42 ended yesterday; no next sprint in Mindmill's tracker yet")
        w.observe(TrackerSprints(key: key, kind: "local", scopes: ["app"], state: .running, current: s43, previous: s42), today: "2026-12-01")
        #expect(w.pending(key, today: "2026-12-01")?.target == s43)
        #expect(w.pending(key, today: "2026-12-01")?.sprint == s42)
    }

    @Test func unreachableTrackersAreNeverWatched() {
        var w = SprintWatch()
        let jira = TrackerSprints(key: "jira:web", kind: "jira", scopes: ["web"], reachable: false, state: .unknown)
        #expect(w.observe(jira, today: "2026-11-23") == nil)
        #expect(w.trackers.isEmpty)
        #expect(SprintMoment.list(SprintReport(trackers: [jira]), watch: w, today: "2026-11-23").isEmpty)
    }

    @Test func savesAndLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var w = SprintWatch()
        w.observe(running(s43, prev: s42), today: "2026-11-30")
        let url = SprintWatch.url(base: dir)
        try w.save(to: url)
        #expect(SprintWatch.load(from: url) == w)
        #expect(SprintWatch.adding(1, to: "2026-12-31") == "2027-01-01")
        #expect(SprintWatch.days(from: "2026-11-30", to: "2026-12-02") == 2)
    }
}

struct SprintReviewTests {
    let agile: [TrackerBacklog.WorkState] = [
        .init(name: "New", category: "Proposed"), .init(name: "Active", category: "InProgress"),
        .init(name: "Resolved", category: "Resolved"), .init(name: "Closed", category: "Completed"),
        .init(name: "Removed", category: "Removed"),
    ]
    let target = SprintInfo(name: "Sprint 43", path: "P\\Sprint 43")

    func review(_ items: [TrackerBacklog.Item], target: SprintInfo? = SprintInfo(name: "Sprint 43", path: "P\\Sprint 43")) -> SprintReviewData {
        SprintReviewData(key: "k", kind: "azure-devops", scopes: ["app"], sprint: SprintInfo(name: "Sprint 42", path: "P\\Sprint 42"),
                         target: target, items: items,
                         states: ["pbi": agile, "bug": agile, "task": [.init(name: "New", category: "Proposed"), .init(name: "Closed", category: "Completed")]],
                         backlog: "P")
    }

    @Test func suggestsFromWhereEachItemStands() {
        let done: [TrackerBacklog.Task] = [.init(id: 101, title: "a", state: "Closed")]
        let open: [TrackerBacklog.Task] = [.init(id: 102, title: "b", state: "Active"), .init(id: 103, title: "c", state: "New")]
        let items: [TrackerBacklog.Item] = [
            .init(id: 1, title: "Resolved", state: "Resolved", stage: .resolved, scope: "app", assignee: "Me", mine: true),
            .init(id: 2, title: "Tasks done", state: "Active", stage: .inProgress, scope: "app", assignee: "Me", tasks: done),
            .init(id: 3, title: "In PR", state: "Active", stage: .inPR, scope: "app", assignee: "Me", prs: [7], tasks: done),
            .init(id: 4, title: "Busy", state: "Active", stage: .inProgress, scope: "app", assignee: "Me", tasks: open),
            .init(id: 5, title: "Nobody's", state: "New", scope: "app"),
            .init(id: 6, title: "Mine, not begun", state: "New", scope: "app", assignee: "Me"),
            .init(id: 7, title: "Merged", state: "Active", stage: .inProgress, scope: "app", assignee: "Me", tasks: open),
        ]
        let r = review(items)
        let got = items.map { SprintReview.suggest($0, in: r, mergedPR: $0.id == 7).decision }
        #expect(got == [.state("Closed"), .state("Closed"), .move("P\\Sprint 43"), .move("P\\Sprint 43"), .backlog,
                        .move("P\\Sprint 43"), .state("Closed")])
        #expect(SprintReview.suggest(items[3], in: review(items, target: nil)).decision == .keep)
        #expect(SprintReview.suggest(items[5], in: r, hasSession: true).reason == "Under way")
    }

    @Test func statesComeFromTheProcess() {
        let item = TrackerBacklog.Item(id: 1, title: "x", state: "Active", scope: "app")
        let r = review([item])
        #expect(r.finishing(item).map(\.name) == ["Resolved", "Closed"])
        #expect(r.doneState(item)?.name == "Closed")
        #expect(r.removedState(item)?.name == "Removed")
        #expect(r.taskDoneState == "Closed")
        let scrum = SprintReviewData(items: [item])
        #expect(scrum.doneState(item)?.name == "Done")
        #expect(SprintReview.title(.state("Removed"), in: r) == "Remove (won't do)")
        #expect(SprintReview.title(.move("P\\Sprint 43"), in: r) == "Move to Sprint 43")
    }

    @Test func payloadTakesOpenTasksAlong() throws {
        let tasks: [TrackerBacklog.Task] = [.init(id: 101, title: "a", state: "Closed"), .init(id: 102, title: "b", state: "New")]
        let item = TrackerBacklog.Item(id: 1, title: "x", state: "Active", scope: "app", tasks: tasks)
        let r = review([item, .init(id: 2, title: "y", scope: "app")])
        #expect(SprintReview.payload(item, .keep, in: r) == nil)
        #expect(SprintReview.payload(item, .move("P\\Sprint 43"), in: r) == ["id": 1, "do": "move", "sprint": "P\\Sprint 43", "tasks": [102]])
        #expect(SprintReview.payload(item, .state("Closed"), in: r) == ["id": 1, "do": "state", "state": "Closed", "tasks": [102], "task_state": "Closed"])
        #expect(SprintReview.payload(item, .state("Resolved"), in: r) == ["id": 1, "do": "state", "state": "Resolved"])
        let all = SprintReview.moveAll(r.items, to: target, decisions: [2: .backlog])
        #expect(all == [1: .move("P\\Sprint 43"), 2: .move("P\\Sprint 43")])
        let json = SprintReview.applyJSON([1: .backlog, 2: .keep], in: r)
        #expect(json == #"[{"do":"backlog","id":1,"tasks":[102]}]"#)
    }

    @Test func parsesSpokenDecisions() {
        let items: [TrackerBacklog.Item] = [.init(id: 1, title: "x", scope: "app"), .init(id: 2, title: "y", scope: "app")]
        let r = review(items)
        let (d, problems) = SprintReview.parse(["1:done", "#2:move", "3:move", "1:state:resolved", "2:fly"], in: r)
        #expect(d == [1: .state("Resolved"), 2: .move("P\\Sprint 43")])
        #expect(problems.count == 2)
        #expect(SprintReview.parse(["2:remove"], in: r).decisions == [2: .state("Removed")])
        #expect(SprintReview.parse(["2:move"], in: review(items, target: nil)).problems == ["#2: there is no next sprint to move to"])
    }

    @Test func decodesTheReviewAndTheResults() throws {
        let json = """
        {"key": "local:app", "kind": "local", "scopes": ["app"], "state": "running",
         "sprint": {"name": "Sprint 41", "path": "Sprint 41", "start": "2026-11-02", "finish": "2026-11-15"},
         "target": {"name": "Sprint 42", "path": "Sprint 42", "start": "2026-11-16", "finish": "2026-11-29"},
         "items": [{"id": 1, "type": "pbi", "title": "Left over", "state": "Committed", "stage": "in_progress", "scope": "app",
                    "scopes": ["app"], "tags": [], "assignee": "Ann", "mine": false, "sprint": "Sprint 41", "changed": "",
                    "url": "", "prs": [], "tasks": [{"id": 2, "title": "t", "state": "To Do", "assignee": ""}],
                    "tasks_done": 0, "tasks_total": 1}],
         "states": {"pbi": [{"name": "New", "category": "Proposed"}, {"name": "Done", "category": "Completed"}]},
         "backlog": "no sprint"}
        """
        let r = try SprintReviewData.decode(json)
        #expect(r.items.first?.openTasks.map(\.id) == [2])
        #expect(r.target?.name == "Sprint 42")
        #expect(r.taskDoneState == "Done")
        let results = try SprintApplyResult.decode(##"{"results": [{"id": 1, "ok": true, "message": "#1 moved"}, {"id": null, "ok": false, "message": "bad"}]}"##)
        #expect(results.map(\.ok) == [true, false])
    }
}

struct StartableTests {
    let cur = "P\\Sprint 25"

    func backlog(_ items: [TrackerBacklog.Item], me: String = "Mads") -> TrackerBacklog {
        TrackerBacklog(me: me, items: items, sprints: ["android": cur], sprintList: [.init(name: "Sprint 25", path: cur, when: "current")])
    }

    let items: [TrackerBacklog.Item] = [
        .init(id: 1, title: "Mine", scope: "android", assignee: "Mads", mine: true, sprint: "P\\Sprint 25"),
        .init(id: 2, title: "Nobody's", scope: "android", sprint: "P\\Sprint 25"),
        .init(id: 3, type: "bug", title: "Eve's bug", scope: "android", assignee: "Eve", sprint: "P\\Sprint 25"),
        .init(id: 4, title: "Next sprint", scope: "android", assignee: "Mads", mine: true, sprint: "P\\Sprint 26"),
        .init(id: 5, title: "Started", state: "Committed", stage: .inProgress, scope: "android", assignee: "Mads", mine: true,
              sprint: "P\\Sprint 25", tasks: [.init(id: 51, title: "Task to do", state: "To Do"),
                                              .init(id: 52, title: "Eve's task", state: "To Do", assignee: "Eve"),
                                              .init(id: 53, title: "Doing", state: "In Progress", assignee: "Mads")]),
        .init(id: 6, title: "iOS", scope: "ios", assignee: "Mads", mine: true, sprint: "X"),
    ]

    @Test func picksByOwnerKindAndSession() {
        let b = backlog(items)
        func ids(_ f: WorkFilter, sessions: Set<String> = []) -> [Int] {
            Startable.items(b, scopes: ["android"], filter: f, me: ["Mads"], sessionKeys: sessions).map(\.number)
        }
        #expect(ids(WorkFilter()) == [1])
        #expect(ids(WorkFilter(owner: .meAndUnassigned)) == [1, 2])
        #expect(ids(WorkFilter(owner: .everyone)) == [1, 2, 3])
        #expect(ids(WorkFilter(owner: .everyone, pbis: false)) == [3])
        #expect(ids(WorkFilter(owner: .meAndUnassigned, tasks: true)) == [1, 2, 51])
        #expect(ids(WorkFilter(owner: .everyone, pbis: false, bugs: false, tasks: true)) == [51, 52])
        #expect(ids(WorkFilter(owner: .meAndUnassigned), sessions: ["wi:1"]) == [2])
    }

    @Test func aTrackerWithoutSprintsCountsEverything() {
        let local = TrackerBacklog(items: [.init(id: 9, title: "Local", scope: "tool", assignee: "Mads")])
        let got = Startable.items(local, scopes: ["tool"], filter: WorkFilter(), me: ["mads"], sessionKeys: [])
        #expect(got.map(\.number) == [9])
        #expect(got[0].mine)
        #expect(got[0].asMyWork.project == "tool")
    }

    @Test func aTaskStartsAsItself() {
        let w = Startable.items(backlog(items), scopes: ["android"], filter: WorkFilter(owner: .me, pbis: false, bugs: false, tasks: true),
                                me: ["Mads"], sessionKeys: [])
        #expect(w.map(\.number) == [])
        let all = Startable.items(backlog(items), scopes: ["android"], filter: WorkFilter(owner: .everyone, pbis: false, bugs: false, tasks: true),
                                  me: ["Mads"], sessionKeys: [])
        #expect(all.first?.sessionKey == "wi:51")
        #expect(all.first?.asMyWork.type == "task")
        #expect(all.first?.kind == "task")
    }

    @Test func theFactoryTakesWhatReadyToStartShows() {
        let b = backlog(items)
        var rules = FactoryRules()
        rules.scopes = ["android"]
        for unassigned in [false, true] {
            rules.unassigned = unassigned
            let factory = FactoryPicker.candidates(b, rules: rules, exclude: [], me: ["Mads"]).map(\.id).sorted()
            let ready = Startable.items(b, scopes: ["android"], filter: .of(rules), me: ["Mads"], sessionKeys: []).map(\.number).sorted()
            #expect(factory == ready)
        }
    }

    @Test func theFilterIsRememberedPerScope() {
        let defaults = UserDefaults(suiteName: "startable-\(UUID().uuidString)")!
        WorkFilter(owner: .everyone, pbis: false, bugs: true, tasks: true).save(scope: "a", defaults: defaults)
        #expect(WorkFilter.load(scope: "a", defaults: defaults) == WorkFilter(owner: .everyone, pbis: false, bugs: true, tasks: true))
        #expect(WorkFilter.load(scope: "b", defaults: defaults) == WorkFilter())
    }
}
