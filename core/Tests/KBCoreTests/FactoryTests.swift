import Foundation
import Testing
@testable import KBCore

struct FactoryTests {
    let cur = "P\\2026\\Sprint 25"
    let next = "P\\2026\\Sprint 26"

    func backlog(_ items: [TrackerBacklog.Item]) -> TrackerBacklog {
        TrackerBacklog(items: items, sprints: ["android": cur], sprintList: [
            .init(name: "Sprint 24", path: "P\\2026\\Sprint 24", when: "past"),
            .init(name: "Sprint 25", path: cur, when: "current"),
            .init(name: "Sprint 26", path: next, when: "future"),
        ])
    }

    @Test func picksOnlyWhatTheRulesAllow() {
        var rules = FactoryRules()
        rules.scopes = ["android"]
        let items: [TrackerBacklog.Item] = [
            .init(id: 1, title: "Mine now", scope: "android", assignee: "Me", mine: true, sprint: cur),
            .init(id: 2, title: "Unassigned now", scope: "android", sprint: cur),
            .init(id: 3, title: "Someone else's", scope: "android", assignee: "Erik", sprint: cur),
            .init(id: 4, title: "iOS", scope: "ios", assignee: "Me", mine: true, sprint: cur),
            .init(id: 5, type: "bug", title: "Mine next sprint", scope: "android", assignee: "Me", mine: true, sprint: next),
            .init(id: 6, title: "Mine started", stage: .inProgress, scope: "android", assignee: "Me", mine: true, sprint: cur),
            .init(id: 7, title: "Mine in PR", stage: .inPR, scope: "android", assignee: "Me", mine: true, sprint: cur),
        ]
        let b = backlog(items)
        #expect(FactoryPicker.candidates(b, rules: rules, exclude: []).map(\.id) == [1])
        rules.unassigned = true
        rules.sprint = .currentAndNext
        rules.resumeStarted = true
        #expect(FactoryPicker.candidates(b, rules: rules, exclude: []).map(\.id) == [6, 1, 2, 5])
        rules.bugs = false
        #expect(FactoryPicker.candidates(b, rules: rules, exclude: [1]).map(\.id) == [6, 2])
        rules.assignedToMe = false
        #expect(FactoryPicker.candidates(b, rules: rules, exclude: []).map(\.id) == [2])
    }

    @Test func strategyRulesMatchInOrder() {
        var rules = FactoryRules()
        rules.defaultStrategy = "solo"
        rules.strategyRules = [.init(match: .bug, strategy: "bugfix"), .init(match: .title, value: "ble", strategy: "careful")]
        #expect(rules.strategy(for: .init(id: 1, type: "bug", title: "BLE crash", scope: "a")) == "bugfix")
        #expect(rules.strategy(for: .init(id: 2, title: "BLE pairing", scope: "a")) == "careful")
        #expect(rules.strategy(for: .init(id: 3, title: "Settings", scope: "a")) == "solo")
    }

    @Test func rulesSurviveARoundTripAndOldFiles() throws {
        var rules = FactoryRules()
        rules.scopes = ["android"]
        rules.checkpoints = [.beforePR, .planReady]
        rules.customCheckpoints = ["Before touching the database schema"]
        rules.until = Date(timeIntervalSince1970: 1_800_000_000)
        var f = Factory(name: "Android", rules: rules)
        f.run = FactoryRun(endsAt: nil)
        f.run?.log("Started", kind: .run)
        let data = try #require(Factory.encodeList([f]))
        let back = Factory.decodeList(data)
        #expect(back.first?.rules == f.rules)
        #expect(back.first?.run?.events.map(\.text) == ["Started"])
        #expect(Factory.encodeList(back) == data)
        let old = Factory.decodeList(Data(#"[{"id":"x","name":"Old","rules":{"scopes":["ios"]}}]"#.utf8))
        #expect(old.first?.rules.scopes == ["ios"])
        #expect(old.first?.rules.checkpoints == [.missingKnowledge, .beforePR])
        #expect(rules.orderedCheckpoints == [.planReady, .beforePR])
    }

    @Test func endDatesAndProblems() {
        var rules = FactoryRules()
        let now = Date()
        #expect(rules.endDate(from: now) == nil)
        rules.duration = .hours
        rules.hours = 2
        #expect(rules.endDate(from: now) == now.addingTimeInterval(7200))
        #expect(rules.problems == ["Choose at least one scope."])
        rules.scopes = ["a"]
        rules.pbis = false
        rules.bugs = false
        #expect(rules.problems == ["Pick PBIs, bugs, or both."])
    }

    @Test func theBriefFollowsTheRules() {
        var rules = FactoryRules()
        rules.scopes = ["android"]
        rules.customCheckpoints = ["Before changing the Room schema", "  "]
        let item = TrackerBacklog.Item(id: 418750, type: "bug", title: "Pairing", state: "Approved", scope: "android")
        let brief = FactoryBrief.task(item, rules: rules, factory: "Android", overviewScope: "acmego", skill: "implement")
        #expect(brief.contains("#418750"))
        #expect(brief.contains("`implement` skill"))
        #expect(brief.contains("kb factory ask"))
        #expect(brief.contains("`beforePR`"))
        #expect(brief.contains("Before changing the Room schema"))
        #expect(!brief.contains("`planReady`"))
        #expect(brief.contains("Never complete or merge"))
        #expect(brief.contains("--section facts"))
        #expect(brief.contains("`acmego`"))
        rules.questions = .never
        rules.completePRs = true
        rules.newWorkItems = .create
        let quiet = FactoryBrief.task(item, rules: rules, factory: "Android", overviewScope: nil, skill: nil)
        #expect(!quiet.contains("kb factory ask"))
        #expect(quiet.contains("complete it with the repo's merge policy."))
        #expect(quiet.contains("kb backlog create"))
    }

    @Test func askPointsFollowTheRulesAndTheirWording() throws {
        var rules = FactoryRules()
        #expect(rules.askPoints.first?.id == FactoryRules.unsureID)
        #expect(!rules.askPoints.contains { $0.id == "beforeComplete" })
        rules.completePRs = true
        #expect(rules.askPoints.contains { $0.id == "beforeComplete" })
        #expect(!rules.askPoints.contains { $0.id == "newWorkItems" })

        rules.setAsk(FactoryRules.unsureID, on: false)
        #expect(rules.questions == .checkpointsOnly)
        rules.setAskInstruction("beforePR", "Before the PR: show me the diff stat.")
        rules.setAskInstruction("missingKnowledge", FactoryCheckpoint.missingKnowledge.instruction)
        #expect(rules.askTexts == ["beforePR": "Before the PR: show me the diff stat."])
        #expect(rules.askPoints.first { $0.id == "beforePR" }?.isEdited == true)
        let id = rules.addAsk("Before changing the Room schema")
        rules.setAskInstruction(id, "Say which tables.")
        rules.setAsk("custom:x", on: false)

        let item = TrackerBacklog.Item(id: 1, title: "X", scope: "android")
        let brief = FactoryBrief.task(item, rules: rules, factory: "F", overviewScope: nil, skill: nil)
        #expect(brief.contains("Before the PR: show me the diff stat."))
        #expect(brief.contains("\"Before changing the Room schema\": Say which tables."))
        #expect(brief.contains("Ask only at the checkpoints"))

        rules.setAsk(id, on: false)
        #expect(!FactoryBrief.task(item, rules: rules, factory: "F", overviewScope: nil, skill: nil).contains("Room schema"))
        rules.setAskInstruction("beforePR", "")
        #expect(rules.askTexts.isEmpty)

        rules.until = Date(timeIntervalSince1970: 1_800_000_000)
        let back = Factory.decodeList(try #require(Factory.encodeList([Factory(name: "F", rules: rules)])))
        #expect(back.first?.rules == rules)
    }

    @Test func oldRulesMoveToTheNewSettings() {
        let json = #"[{"id":"x","name":"Old","rules":{"checkpoints":["newWorkItems","beforePR"],"newWorkItems":"create","customCheckpoints":["Before migrations"]}}]"#
        let rules = Factory.decodeList(Data(json.utf8)).first?.rules
        #expect(rules?.checkpoints == [.beforePR])
        #expect(rules?.newWorkItems == .propose)
        #expect(rules?.customCheckpoints.map(\.title) == ["Before migrations"])
        #expect(rules?.customCheckpoints.first?.on == true)
    }

    @Test func askingAndNewWorkInTheBrief() {
        var rules = FactoryRules()
        rules.questions = .never
        rules.newWorkItems = .propose
        let item = TrackerBacklog.Item(id: 7, title: "X", scope: "android")
        let brief = FactoryBrief.task(item, rules: rules, factory: "F", overviewScope: nil, skill: nil)
        #expect(brief.contains("except before creating a work item"))
        #expect(brief.contains("--checkpoint newWorkItems"))
        #expect(brief.contains("kb backlog create"))
        rules.questions = .checkpointsOnly
        rules.checkpoints = []
        #expect(rules.problems.contains("Tick at least one moment to ask, or turn asking off."))
        rules.strategyRules = [.init(match: .tag, value: " ")]
        #expect(rules.problems.contains("An exception needs a tag or words."))
    }

    @Test func theOutlineSaysWhatItWillDo() {
        var rules = FactoryRules()
        rules.scopes = ["android", "ios"]
        rules.unassigned = true
        rules.defaultStrategy = "pair"
        rules.strategyRules = [.init(match: .bug, strategy: ""), .init(match: .tag, value: "ble", strategy: "careful")]
        rules.checkpoints = [.planReady, .beforePR]
        rules.newWorkItems = .propose
        let steps = rules.outline(scopeTitle: { $0.capitalized }, strategyTitle: { "S-\($0)" })
        #expect(steps.map(\.id) == FactoryStep.allCases)
        let byID = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0) })
        #expect(byID[.pick]?.detail.hasPrefix("Takes your and unassigned PBIs and bugs from Android") == true, "\(byID[.pick]?.detail ?? "")")
        #expect(byID[.start]?.detail == "Each item gets S-pair. Except Bugs: one session working alone; Tagged “ble”: S-careful.")
        #expect(byID[.plan]?.asks == ["Plan ready"])
        #expect(byID[.build]?.asks == ["When unsure"])
        #expect(byID[.newWork]?.asks == ["Before creating it"])
        #expect(byID[.deliver]?.asks == ["Before the pull request"])
        rules.questions = .never
        rules.openPRs = false
        let quiet = rules.outline(scopeTitle: { $0 }, strategyTitle: { $0 })
        #expect(quiet.allSatisfy { $0.id == .newWork || $0.asks.isEmpty })
        #expect(quiet.first { $0.id == .deliver }?.detail.contains("no pull request") == true)
    }

    @Test func boardLanesAndRunProgress() {
        var t = FactoryTask(workItem: 1, title: "X", scope: "a", sessionID: "s")
        #expect(FactoryLane.of(t, occupiesSlot: true, waitsOnUser: false) == .working)
        #expect(FactoryLane.of(t, occupiesSlot: true, waitsOnUser: true) == .needsYou)
        #expect(FactoryLane.of(t, occupiesSlot: false, waitsOnUser: false) == .review)
        t.finished = Date()
        #expect(FactoryLane.of(t, occupiesSlot: false, waitsOnUser: true) == .done)

        let start = Date(timeIntervalSince1970: 1_000_000)
        var run = FactoryRun(started: start, endsAt: start.addingTimeInterval(3600))
        #expect(run.progress(at: start.addingTimeInterval(900)) == 0.25)
        #expect(run.progress(at: start.addingTimeInterval(9000)) == 1)
        #expect(FactoryRun(started: start, endsAt: nil).progress(at: start) == nil)
        run.log("Started #1", kind: .started, workItem: 1)
        run.log("plan ready", workItem: 1)
        run.log("asks: which?", kind: .question, workItem: 1)
        run.log("other", workItem: 2)
        #expect(run.lastMilestone(for: 1)?.text == "plan ready")
        #expect(run.events(for: 1).count == 3)
    }

    @Test func asidesForkWithoutSaving() {
        var launch = ClaudeLaunch(executable: URL(fileURLWithPath: "/bin/claude"), pluginRoot: "/p", systemPrompt: "x",
                                  sessionID: "abc", resume: true, workingDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(!launch.arguments.contains("--fork-session"))
        launch.fork = true
        launch.persist = false
        let args = launch.arguments
        #expect(args.contains("--fork-session") && args.contains("--no-session-persistence"))
        #expect(args[args.firstIndex(of: "--resume")! + 1] == "abc")
        #expect(FactoryBrief.catchUp("Retry or keep?").contains("“Retry or keep?”"))
        #expect(FactoryBrief.asideSystemPrompt.contains("don't change files"))
    }

    @Test func factoryOrdersParse() {
        let ask = #"{"kind":"factory_ask","from":"s1","text":"Which?","options":["A"," ",""],"checkpoint":"beforePR"}"#
        #expect(CrewOrder.parse(Data(ask.utf8)) == .factoryAsk(from: "s1", text: "Which?", options: ["A"], checkpoint: "beforePR"))
        #expect(CrewOrder.parse(Data(#"{"kind":"factory_log","from":"s1","text":"done: PR open"}"#.utf8)) == .factoryLog(from: "s1", text: "done: PR open"))
    }

    @Test func startingAgainKeepsTheBoardAndHistory() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var run = FactoryRun(started: start, endsAt: start.addingTimeInterval(3600))
        run.tasks.append(FactoryTask(workItem: 7, title: "In review", scope: "android", sessionID: "s7"))
        run.log("Started #7", kind: .started, workItem: 7)
        run.status = .stopped
        run.stopped = start.addingTimeInterval(3600)

        let again = start.addingTimeInterval(7200)
        run.resume(endsAt: again.addingTimeInterval(7200), at: again)
        #expect(run.status == .running)
        #expect(run.stopped == nil)
        #expect(run.started == start)
        #expect(run.since == again)
        #expect(run.tasks.map(\.workItem) == [7])
        #expect(run.events.count == 1)
        #expect(run.progress(at: again.addingTimeInterval(3600)) == 0.5)

        let data = try #require(Factory.encodeList([Factory(name: "F", run: run)]))
        #expect(Factory.decodeList(data).first?.run?.resumed == again)
    }

    @Test func putsBackSessionsItStartedThatTheRunLost() {
        var f = Factory(name: "Software Factory", run: FactoryRun(endsAt: nil))
        f.run?.tasks.append(FactoryTask(workItem: 1, title: "Known", scope: "android", sessionID: "s1"))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func info(_ id: String, _ item: Int, factory: String = "Software Factory", archived: Bool = false, at: Double = 0) -> FactorySessionInfo {
            FactorySessionInfo(id: id, title: "#\(item) Title \(item)", project: "android", about: "wi:\(item)",
                               firstMessage: Factory.sessionLabel(factory: factory, item: item, title: "Title \(item)") + "\n\nbrief",
                               created: t0.addingTimeInterval(at), archived: archived)
        }
        let lost = f.lostTasks([
            info("s1", 1),
            info("s3", 3, at: 20),
            info("s2", 2, at: 10),
            info("s4", 4, archived: true),
            info("s5", 5, factory: "Other"),
            FactorySessionInfo(id: "s6", title: "#6 By hand", project: "android", about: "wi:6", firstMessage: "Implement #6",
                               created: t0, archived: false),
        ])
        #expect(lost.map(\.workItem) == [2, 3])
        #expect(lost.first?.title == "Title 2")
        #expect(lost.first?.sessionID == "s2")
        #expect(lost.first?.started == t0.addingTimeInterval(10))
        #expect(lost.allSatisfy { $0.isActive })
    }

    @Test func sidePanelKeepsItsWidthUntilTheMainViewNeedsTheRoom() {
        let wide = SidePanelFit.widths(available: 1000, divider: 1, preferred: 306, panelMin: 200, mainMin: 320)
        #expect(wide.panel == 306 && wide.main == 693)
        let tight = SidePanelFit.widths(available: 600, divider: 1, preferred: 306, panelMin: 200, mainMin: 320)
        #expect(tight.panel == 279 && tight.main == 320)
        let narrow = SidePanelFit.widths(available: 350, divider: 1, preferred: 306, panelMin: 200, mainMin: 320)
        #expect(narrow.panel == 200 && narrow.main == 149)
        let tiny = SidePanelFit.widths(available: 100, divider: 1, preferred: 306, panelMin: 200, mainMin: 320)
        #expect(tiny.panel == 99 && tiny.main == 0)
    }

    @Test func changedFactsGoOutAsOneMessage() {
        #expect(FactoryBrief.factsChanged([]) == nil)
        let one = FactoryBrief.FactChange(kind: "fact", title: "The CDN supports range requests", id: "app/facts/cdn", summary: "")
        #expect(FactoryBrief.factsChanged([one]) == FactoryBrief.factChanged(one.title, id: one.id, summary: "", kind: "fact"))
        let two = FactoryBrief.FactChange(kind: "decision", title: "Warn below 20% storage", id: "app/decisions/warn", summary: "Agreed")
        let text = FactoryBrief.factsChanged([one, two]) ?? ""
        #expect(text.hasPrefix("2 facts and decisions changed while you work:"))
        #expect(text.contains("- Fact “The CDN supports range requests” (`app/facts/cdn`)\n"))
        #expect(text.contains("- Decision “Warn below 20% storage” (`app/decisions/warn`): Agreed"))
        #expect(text.components(separatedBy: "kb factory log").count == 2)
    }
}
