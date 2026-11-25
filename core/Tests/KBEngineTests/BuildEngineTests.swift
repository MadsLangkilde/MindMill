import Foundation
import KBCore
import Testing
@testable import KBEngine

/// Build mode in the engine: sessions and their crew, the factory loop over a fake tracker, and the remote methods.
/// No Claude Code here: `claude` isn't found, so a message to a session fails to start it and the session waits.
@MainActor
@Suite struct BuildEngineTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kb-build-\(UUID().uuidString)")
    let defaults = UserDefaults(suiteName: "kb-build-\(UUID().uuidString)")!

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func makeEngine() throws -> MindmillEngine {
        try write("kb.json", #"{"version": 1, "projects": [{"id": "alpha", "title": "Alpha", "paths": []}, {"id": "beta", "title": "Beta"}]}"#)
        try write("projects/alpha/facts/one.md", "---\ntitle: One\n---\nFirst.\n")
        defaults.set("Me", forKey: "myName")
        let platform = EnginePlatform(name: "Windows", machineWord: "PC", secrets: MemorySecretStore(), transport: FakeTransport(),
                                      defaults: defaults, pluginRoot: { "/nonexistent" })
        let engine = MindmillEngine(rootPath: root.path, platform: platform, remoteFolder: root.appendingPathComponent("remote"))
        engine.isolate(in: root.appendingPathComponent("data"))
        engine.reload()
        return engine
    }

    var crew: URL { root.appendingPathComponent("data/crew") }

    func order(_ json: String, _ n: Int) throws {
        let dir = crew.appendingPathComponent("orders")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent(String(format: "%04d.json", n)), atomically: true, encoding: .utf8)
    }

    @Test func kbNewOutputGivesTheIDOnEitherLayout() {
        #expect(MindmillEngine.newEntryID("alpha/facts/x\n/Users/me/kb/projects/alpha/facts/x.md\n") == "alpha/facts/x")
        #expect(MindmillEngine.newEntryID("alpha/facts/x /Users/me/kb/x.md") == "alpha/facts/x")
        #expect(MindmillEngine.newEntryID("") == "")
    }

    @Test func newSessionsAreSavedShownAndReportWhenClaudeIsMissing() throws {
        let engine = try makeEngine()
        var shown: [String] = []
        var reported: [(String, Bool)] = []
        engine.sessions.onShow = { shown.append($0.id) }
        engine.onReport = { reported.append(($0, $1)) }
        let s = engine.sessions.newSession(title: "Try it", message: "Hello", space: .build)
        #expect(s.project == "alpha")
        #expect(shown == [s.id])
        #expect(reported.last?.1 == true)
        #expect(s.chat.items.isEmpty)
        let overseer = engine.sessions.ensureOverseer()
        #expect(overseer.project == nil && overseer.workingDirectory.standardizedFileURL == root.standardizedFileURL)
        engine.sessions.save()
        let saved = SessionStore.load(from: engine.sessions.storeURL)
        #expect(saved.map(\.id) == [overseer.id])
    }

    @Test func moreWorkOnTheSameItemGoesUnderItsLead() throws {
        let engine = try makeEngine()
        let hub = engine.sessions
        let first = hub.newSession(title: "#7 Do it", about: "wi:7", show: false, space: .build)
        let second = hub.newSession(title: "#7 tests", about: "wi:7", show: false, space: .build)
        #expect(first.role == .lead)
        #expect(second.role == .member)
        #expect(second.parentID == first.id)
        #expect(hub.members(of: first).map(\.id) == [second.id])
        #expect(first.pendingSetup?.contains("You now lead this work") == true)
        hub.setArchived(first, true)
        #expect(hub.isArchived(second))
        #expect(hub.archivedBuildSessions.map(\.id) == [first.id])
        hub.detach(second)
        #expect(second.role == .solo && second.parentID == nil)
    }

    @Test func crewOrdersStartArchiveAndWriteTheState() throws {
        let engine = try makeEngine()
        let hub = engine.sessions
        let lead = hub.newSession(title: "Feature", show: false, space: .build)
        try order(#"{"kind": "start", "title": "Part A", "parent": "\#(lead.id)", "text": "Do A", "from": "\#(lead.id)"}"#, 1)
        hub.tick()
        let member = try #require(hub.list.first { $0.title == "Part A" })
        #expect(lead.role == .lead)
        #expect(member.role == .member && member.parentID == lead.id && member.space == .build)
        let state = try JSONDecoder().decode(CrewState.self, from: Data(contentsOf: crew.appendingPathComponent("state.json")))
        #expect(Set(state.sessions.map(\.id)) == [lead.id, member.id])
        try order(#"{"kind": "archive", "to": "\#(lead.id)"}"#, 2)
        hub.tick()
        #expect(lead.archived == true && member.archived == true)
        #expect(hub.topLevelBuildSessions.isEmpty)
    }

    @Test func leadsGetTheirSetUpAndStrategiesMoveSessionsToBuild() throws {
        let engine = try makeEngine()
        let hub = engine.sessions
        let s = hub.startLead(NewLeadRequest(title: "Big job", project: "alpha", helpers: .fixed, helperCount: 2))
        #expect(s.role == .lead)
        #expect(s.pendingSetup?.contains("exactly 2 sessions") == true)
        let plan = hub.newSession(title: "Thinking", show: false, space: .plan)
        var st = Strategy(slug: "crew", title: "Crew")
        st.spawns = true
        var reported: [String] = []
        engine.onReport = { text, _ in reported.append(text) }
        hub.applyStrategy(st, to: plan)
        #expect(plan.role == .lead && plan.space == .build && plan.strategy == "crew")
        #expect(reported.contains { $0.contains("moved to Build") })
        #expect(SessionHub.allowPattern("Bash(npm run build)") == "Bash(npm:*)")
    }

    @Test func remoteMethodsListSessionsWithLinkedOnesAndArchive() async throws {
        let engine = try makeEngine()
        let hub = engine.sessions
        let build = hub.newSession(title: "Build one", show: false, space: .build)
        let plan = hub.newSession(title: "Plan one", show: false, space: .plan)
        var linkedArchived = false
        hub.linkedItems = { _ in
            [SessionHub.LinkedItem(updated: Date(), archived: linkedArchived,
                                   json: ["id": "link:ask:alpha", "space": "plan", "title": "Ask: what?", "needsYou": false])]
        }
        hub.archiveLinked = { id, on in
            guard id == "link:ask:alpha" else { return false }
            linkedArchived = on
            return true
        }
        let c = RemoteClient(FakeConnection())
        let list = try await engine.call("sessions.list", ["scope": "alpha"], from: c)
        let ids = Set(list["sessions"]?.array?.compactMap { $0["id"]?.string } ?? [])
        #expect(ids == [build.id, plan.id, "link:ask:alpha"])
        _ = try await engine.call("session.archive", ["id": "link:ask:alpha", "archived": true], from: c)
        _ = try await engine.call("session.archive", ["id": .string(plan.id), "archived": true], from: c)
        let after = try await engine.call("sessions.list", [:], from: c)
        #expect(after["sessions"]?.array?.compactMap { $0["id"]?.string } == [build.id])
        let got = try await engine.call("session.get", ["id": .string(build.id)], from: c)
        #expect(got["session"]?["space"]?.string == "build")
        #expect(got["denials"]?.array?.isEmpty == true)
        await #expect(throws: RemoteError.self) { _ = try await engine.call("session.get", ["id": "nope"], from: c) }
        let structure = engine.buildStructureExtras(scope: "alpha")
        #expect(structure.buildScopes.first?.count == 1)
        let asked = try await engine.call("session.new", ["space": "plan", "scope": "alpha", "message": "Hi", "assistant": true, "spoken": true], from: c)
        #expect(hub.session(asked["id"]?.string)?.isAssistant == true)
        let built = try await engine.call("session.new", ["space": "build", "scope": "alpha", "assistant": true], from: c)
        #expect(hub.session(built["id"]?.string)?.isAssistant == false)
        #expect(hub.session(built["id"]?.string)?.space == .build)
        _ = try await engine.call("session.send", ["id": .string(build.id), "text": "Hello", "spoken": true], from: c)
        let stopped = try await engine.call("session.stop", ["id": .string(build.id)], from: c)
        #expect(stopped["stopped"]?.bool == true)
        #expect(hub.session(build.id)?.chat.isBusy == false)
        await #expect(throws: RemoteError.self) { _ = try await engine.call("session.stop", ["id": "nope"], from: c) }
        let items = try await engine.call("tracker.items", ["scope": "alpha"], from: c)
        #expect(items["items"]?.array?.isEmpty == true)
    }

    // MARK: The factory

    func factoryEngine(items: [TrackerBacklog.Item], parallel: Int = 1) throws -> (MindmillEngine, String) {
        let engine = try makeEngine()
        engine.tracker.backlog = TrackerBacklog(me: "Me", items: items)
        engine.tracker.backlogFetched = Date()
        var rules = FactoryRules()
        rules.scopes = ["alpha"]
        rules.maxParallel = parallel
        let id = engine.factories.save(id: nil, name: "Line", rules: rules)
        #expect(rules.problems.isEmpty)
        let i = try #require(engine.factories.list.firstIndex { $0.id == id })
        engine.factories.list[i].run = FactoryRun(endsAt: nil)
        return (engine, id)
    }

    func tick(_ engine: MindmillEngine) {
        engine.factories.lastTick = .distantPast
        engine.factories.tick()
    }

    @Test func theFactoryPicksMyItemsOneAtATimeAndFollowsThem() throws {
        let (engine, id) = try factoryEngine(items: [
            TrackerBacklog.Item(id: 7, title: "Do it", scope: "alpha", assignee: "Me", mine: true),
            TrackerBacklog.Item(id: 8, title: "Elsewhere", scope: "beta", assignee: "Me", mine: true),
            TrackerBacklog.Item(id: 9, title: "Next", scope: "alpha", assignee: "Me", mine: true),
            TrackerBacklog.Item(id: 10, title: "Someone else's", scope: "alpha", assignee: "Ann"),
        ])
        tick(engine)
        var run = try #require(engine.factories.factory(id)?.run)
        #expect(run.tasks.map(\.workItem) == [7])
        let s = try #require(engine.sessions.session(run.tasks[0].sessionID))
        #expect(s.about == "wi:7" && s.space == .build && s.title == "#7 Do it")
        tick(engine)
        #expect(engine.factories.factory(id)?.run?.tasks.count == 1)

        var checkpoints: [String?] = []
        engine.factories.onCheckpoint = { _, c in checkpoints.append(c) }
        engine.sessions.execute(.factoryAsk(from: s.id, text: "Which database?", options: ["A", "B"], checkpoint: "before-pr"))
        #expect(engine.factories.questionCount == 1)
        #expect(checkpoints == ["before-pr"])
        let q = try #require(engine.factories.allOpenQuestions().first)
        #expect(q.workItem == 7)
        engine.factories.answer(id, q.id, answer: "A")
        #expect(engine.factories.questionCount == 0)

        engine.sessions.delete(s)
        tick(engine)
        run = try #require(engine.factories.factory(id)?.run)
        #expect(run.tasks.first { $0.workItem == 7 }?.outcome == "Session deleted")
        #expect(run.tasks.map(\.workItem) == [7, 9])
    }

    @Test func aFactoryWhoseTimeIsUpStopsOnceNothingIsBusy() throws {
        let (engine, id) = try factoryEngine(items: [])
        let i = try #require(engine.factories.list.firstIndex { $0.id == id })
        engine.factories.list[i].run?.endsAt = Date().addingTimeInterval(-60)
        tick(engine)
        #expect(engine.factories.factory(id)?.run?.status == .stopped)
        let status = engine.factoryStatus()
        #expect(status.first?["status"]?.string == "stopped")
    }

    @Test func factoryEditorMethodsSaveAndDelete() async throws {
        let engine = try makeEngine()
        let c = RemoteClient(FakeConnection())
        let empty = try await engine.call("factory.config.get", [:], from: c)
        #expect(empty["name"]?.string == "Software Factory")
        await #expect(throws: RemoteError.self) {
            _ = try await engine.call("factory.config.save", ["name": "No scopes", "rules": ["scopes": []]], from: c)
        }
        let saved = try await engine.call("factory.config.save", ["name": "Line", "rules": ["scopes": ["alpha"]]], from: c)
        let id = try #require(saved["id"]?.string)
        #expect(engine.factories.factory(id)?.rules.scopes == ["alpha"])
        let stored = try Data(contentsOf: engine.factories.storeURL)
        #expect(Factory.decodeList(stored).map(\.id) == [id])
        var deleted: [String] = []
        engine.factories.onDeleted = { deleted.append($0) }
        _ = try await engine.call("factory.config.delete", ["id": .string(id)], from: c)
        #expect(engine.factories.list.isEmpty && deleted == [id])
        let outcome = await engine.actions.run("factories.status", [:], channel: .remote)
        #expect(outcome.text == "There are no factories yet.")
    }

    // MARK: Testing

    @Test func iPhoneBuildsNeedAMacAndSayWhyFromTheCheck() {
        let check = CompatibilityResult(checked: Date(), findings: [
            .init(title: "No Xcode", detail: "Windows has no Xcode.", canStill: "Run the unit tests.", cannot: "Build the iOS app."),
        ], fingerprint: "x")
        let why = TestRunner.unsupported(kind: .testflight, own: [], machine: "PC", compatibility: check)
        #expect(why?.contains("need a Mac") == true)
        #expect(why?.contains("Build the iOS app.") == true && why?.contains("Run the unit tests.") == true)
        #expect(TestRunner.unsupported(kind: .iosDevice, own: [.iosDevice], machine: "Mac", compatibility: nil) == nil)
        for kind in [DeliveryKind.apk, .url, .preview] {
            #expect(TestRunner.unsupported(kind: kind, own: [], machine: "PC", compatibility: nil) == nil)
        }
    }

    @Test func portableFactsReadAdbAndTailscale() {
        let devices = TestRunner.androidDevices("List of devices attached\nemulator-5554 device product:x model:Pixel_8 device:y\nR5CT unauthorized usb:1\n")
        #expect(devices.map(\.kind) == [.androidEmulator, .android])
        #expect(devices.first?.name == "Pixel_8" && devices.first?.booted == true && devices.last?.paired == false)
        var f = TestEnvironmentFacts()
        TestRunner.readTailscale(#"{"BackendState": "Running", "Self": {"DNSName": "pc.tail.ts.net.", "TailscaleIPs": ["100.1.2.3", "fd7a::1"]}, "CertDomains": ["pc.tail.ts.net"]}"#, into: &f)
        #expect(f.tailscaleRunning && f.tailscaleName == "pc.tail.ts.net" && f.tailscaleIP == "100.1.2.3" && f.tailscaleHTTPS)
    }

    @Test func testingMethodsAnswerOnTheEngineAndMarkIPhoneTargetsUnavailable() async throws {
        let engine = try makeEngine()
        var plan = ScopeTestPlan()
        var t = TestTarget(type: .ios, repo: root.path, path: "", title: "App")
        t.method = "testflight"
        plan.targets = [t]
        engine.tests.center.store["alpha"] = plan
        engine.tests.center.facts.gathered = Date()
        let c = RemoteClient(FakeConnection())
        let status = try await engine.call("test.status", ["scope": "alpha"], from: c)
        let target = try #require(status["targets"]?.array?.first)
        #expect(target["ready"]?.bool == false)
        #expect(target["unavailable"]?.string?.contains("need a Mac") == true)
        let delivered = await engine.tests.deliver(scope: "alpha", targetID: t.id)
        #expect(delivered?.state == .failed)
        #expect(delivered?.message?.contains("need a Mac") == true)
        await #expect(throws: RemoteError.self) { _ = try await engine.call("test.send", ["delivery": "nope"], from: c) }
        let cards = try await engine.call("review.list", [:], from: c)
        #expect(cards["cards"]?.array != nil)
    }
}
