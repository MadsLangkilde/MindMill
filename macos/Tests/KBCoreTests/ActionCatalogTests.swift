import Foundation
import Testing
@testable import KBCore

/// The whole catalog: what the phone's action browser, voice and the assistant session see.
struct ActionCatalogTests {
    @Test func namesAreUniqueAndEveryActionHasAnArea() {
        let names = ActionCatalog.all.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(Set(ActionCatalog.areas.map(\.title)).count == ActionCatalog.areas.count)
        for s in ActionCatalog.all {
            #expect(!s.area.isEmpty, "\(s.name)")
            #expect(ActionCatalog.areas.contains { $0.title == s.area }, "\(s.name)")
            #expect(!s.about.isEmpty, "\(s.name)")
            #expect(s.name.range(of: "^[a-z_]+(\\.[a-z_]+)*$", options: .regularExpression) != nil, "\(s.name)")
        }
    }

    @Test func eachAreaKeepsItsGroupedPrefixes() {
        let area = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.name, $0.area) })
        for (prefix, title) in [("factory.", "Factories"), ("pr.", "Pull Requests"), ("meeting.mac.", "Meetings"),
                                ("strategy.", "Strategies"), ("settings.", "Settings"), ("session.", "Sessions"), ("goal.", "Reminders and Goals")] {
            for name in area.keys where name.hasPrefix(prefix) { #expect(area[name] == title, "\(name)") }
        }
    }

    @Test func riskyActionsAskFirstAndSayWhat() {
        let risk = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.name, $0.risk) })
        for name in ["factory.delete", "factory.stop", "entry.delete", "session.delete", "session.stop", "meeting.mac.stop",
                     "reminder.delete", "goal.delete", "strategy.delete", "fact.change.remove", "followup.merge", "backlog.reject"] {
            #expect(risk[name] == .destructive, "\(name)")
        }
        for name in ["workitem.create", "workitem.update", "workitem.tasks", "workitem.implement", "backlog.create", "pr.comment",
                     "pr.reply", "pr.thread", "pr.approve", "pr.vote", "pr.complete", "pr.autocomplete.cancel", "pr.build.rerun"] {
            #expect(risk[name] == .external, "\(name)")
        }
        for name in ["overview", "factory.get", "calendar.upcoming", "meeting.mac.status", "settings.get", "prs.list", "app.show"] {
            #expect(risk[name] == .read, "\(name)")
        }
        for s in ActionCatalog.all where s.risk.needsConfirmation {
            #expect(!s.confirm.isEmpty, "\(s.name) should ask its own question")
            #expect(s.confirm.contains("?"), "\(s.name)")
            let re = try! NSRegularExpression(pattern: "\\{([a-z_]+)\\}")
            let placeholders = re.matches(in: s.confirm, range: NSRange(s.confirm.startIndex..., in: s.confirm))
                .compactMap { Range($0.range(at: 1), in: s.confirm).map { String(s.confirm[$0]) } }
            for p in placeholders { #expect(s.params.contains { $0.name == p }, "\(s.name) asks about {\(p)}") }
        }
    }

    @Test func schemasAreObjectsWithKnownTypesAndRequiredParameters() {
        let types: Set<String> = ["string", "integer", "number", "boolean", "array"]
        for s in ActionCatalog.all {
            let schema = s.inputSchema
            #expect(schema["type"] == "object")
            guard case .object(let props)? = schema["properties"] else { Issue.record("\(s.name) has no properties"); continue }
            #expect(props.count == s.params.count, "\(s.name) repeats a parameter")
            for (name, p) in props {
                #expect(types.contains(p["type"]?.string ?? ""), "\(s.name).\(name)")
                let about = p["description"]?.string ?? ""
                #expect(about.isEmpty == false, "\(s.name).\(name)")
            }
            for r in schema["required"]?.strings ?? [] { #expect(props[r] != nil, "\(s.name) requires \(r)") }
        }
    }

    @Test func theCatalogCoversWhatThePhoneAndVoiceNeed() {
        let names = Set(ActionCatalog.all.map(\.name))
        for n in ["factory.get", "factory.create", "factory.update", "factory.duplicate", "factory.delete", "strategies.list",
                  "calendar.upcoming", "meeting.mac.start", "meeting.mac.note", "meeting.mac.stop", "meeting.mac.status",
                  "app.show", "entry.create", "entry.update", "pr.get", "pr.comment", "pr.approve", "settings.get", "settings.ai",
                  "test.detect", "test.check", "test.deliver", "sessions.list", "session.start"] {
            #expect(names.contains(n), "\(n)")
        }
        #expect(ActionCatalog.voiceCore.isSubset(of: names))
        #expect(ActionCatalog.voiceCore.count < 64)
        let screens = ActionCatalog.all.first { $0.name == "app.show" }!.params.first { $0.name == "screen" }!.choices
        #expect(screens.contains("backlog") && screens.contains("factory") && screens.contains("settings"))
    }

    @MainActor @Test func aModelWithSomeToolsFindsAndRunsTheRest() async {
        let layer = ActionLayer()
        var ran: [String] = []
        layer.register("strategies.list") { _ in ran.append("strategies.list"); return ActionResult("Two.") }
        let found = await layer.callTool(ActionTools.findName, ["query": "strategy"], channel: .voice)
        guard case .done(let r) = found else { Issue.record("find failed"); return }
        #expect(r.data["actions"]?.array?.contains { $0["name"] == "strategies.list" } == true)
        let byArea = layer.find("", area: "Factories")
        #expect(byArea.data["actions"]?.array?.allSatisfy { $0["area"] == "Factories" } == true)

        #expect(await layer.callTool(ActionTools.runName, ["name": "strategies.list"], channel: .voice) == .done(ActionResult("Two.")))
        #expect(ran == ["strategies.list"])
        if case .confirm = await layer.callTool(ActionTools.runName, ["name": "factory.delete", "params": ["factory": "x"]], channel: .voice) {
        } else { Issue.record("a risky action run through run_action still asks first") }
        #expect(layer.toolDefinitions(only: ["overview"]).count == 1)
    }
}

struct FactoryConfigTests {
    @Test func rulesRoundTripThroughTheConfigJSON() throws {
        var r = FactoryRules()
        r.scopes = ["app", "web"]
        r.unassigned = true
        r.sprint = .currentAndNext
        r.questions = .checkpointsOnly
        r.defaultStrategy = "tdd"
        r.strategyRules = [FactoryStrategyRule(match: .tag, value: "ble", strategy: "spike")]
        r.checkpoints = [.planReady, .beforePR]
        r.customCheckpoints = [FactoryCustomAsk(title: "Before touching billing", instruction: "Ask first")]
        r.askTexts = ["planReady": "Show me the plan"]
        r.maxParallel = 5
        r.duration = .until
        r.until = Date(timeIntervalSince1970: 1_800_000_000)
        let json = FactoryConfig.json(r)
        #expect(json["until"]?.string == "2027-01-15T08:00:00Z")
        #expect(json["checkpoints"]?.strings == ["beforePR", "planReady"])
        #expect(try FactoryConfig.merge(FactoryRules(), with: json) == r)
    }

    @Test func unknownKeysAndNullsAreIgnoredAndLeftOutKeysKeepTheirValue() throws {
        var base = FactoryRules()
        base.scopes = ["app"]
        base.maxParallel = 2
        let merged = try FactoryConfig.merge(base, with: ["maxParallel": 4, "colour": "blue", "nested": ["x": 1], "bugs": nil,
                                                          "strategyRules": [["match": "title", "value": "login", "strategy": ""]]])
        #expect(merged.maxParallel == 4)
        #expect(merged.scopes == ["app"])
        #expect(merged.bugs == base.bugs)
        #expect(merged.strategyRules.first?.match == .title && merged.strategyRules.first?.value == "login")
    }

    @Test func badValuesSayWhichKey() {
        #expect(throws: FactoryConfig.ConfigError.self) { try FactoryConfig.merge(FactoryRules(), with: ["maxParallel": "lots"]) }
        #expect(throws: FactoryConfig.ConfigError.self) { try FactoryConfig.merge(FactoryRules(), with: "rules") }
        do {
            _ = try FactoryConfig.merge(FactoryRules(), with: ["strategyRules": [["match": "colour"]]])
            Issue.record("an unknown match should fail")
        } catch {
            #expect(error.localizedDescription.hasPrefix("rules.strategyRules"))
        }
    }

    @Test func actionParametersBecomeAPatch() throws {
        let patch = FactoryConfig.patch(fromAction: ["scopes": "app, web", "max_parallel": 40, "questions": "never", "hours": 6,
                                                     "factory": "Nightly", "name": "x"])
        let r = try FactoryConfig.merge(FactoryRules(), with: patch)
        #expect(r.scopes == ["app", "web"])
        #expect(r.maxParallel == 10)
        #expect(r.questions == .never)
        #expect(r.duration == .hours && r.hours == 6)
        #expect(try FactoryConfig.merge(r, with: FactoryConfig.patch(fromAction: ["hours": 0])).duration == .untilStopped)
    }

    @Test func optionsListEveryChoice() {
        let o = FactoryConfig.options(scopes: [.init(id: "app", title: "App")], strategies: [(slug: "tdd", title: "Test first")])
        #expect(o["scopes"]?.array?.first?["id"] == "app")
        #expect(o["strategies"]?.array?.map { $0["slug"]?.string ?? "-" } == ["", "tdd"])
        #expect(o["sprint"]?.array?.count == FactoryRules.SprintFilter.allCases.count)
        #expect(o["checkpoints"]?.array?.contains { $0["id"] == "newWorkItems" } == false)
        #expect(o["checkpoints"]?.array?.first { $0["id"] == "beforeComplete" }?["requires"]?.strings == ["openPRs", "completePRs"])
        #expect(o["maxParallel"]?.array?.count == FactoryRules.parallelChoices.count)
        #expect(o["strategyMatch"]?.array?.first { $0["id"] == "tag" }?["needsValue"] == true)
    }
}

struct AssistantSessionTests {
    @Test func theLatestAssistantIsFoundAndArchivedOnesAreSkipped() {
        func rec(_ id: String, about: String?, project: String?, updated: Double, archived: Bool? = nil) -> SessionRecord {
            SessionRecord(id: id, title: id, project: project, workingDirectory: "/", updated: Date(timeIntervalSince1970: updated),
                          about: about, archived: archived)
        }
        let records = [rec("a", about: "assistant", project: "app", updated: 10), rec("b", about: "assistant", project: "web", updated: 20),
                       rec("c", about: "assistant", project: "app", updated: 30, archived: true), rec("d", about: nil, project: "app", updated: 40)]
        #expect(SessionRecord.latestAssistant(records, scope: nil)?.id == "b")
        #expect(SessionRecord.latestAssistant(records, scope: "app")?.id == "a")
        #expect(SessionRecord.latestAssistant(records, scope: "none") == nil)
        #expect(PlanSessions.kind(title: "Assistant", about: "assistant", firstMessage: "create a PBI") == .assistant)
    }
}
