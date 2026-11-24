import Foundation
import KBCore
import Testing
@testable import KBEngine

/// The Plan and backlog work that moved into the engine, the sprints, and what the Windows shell's tests found.
@MainActor
@Suite struct PlanEngineTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("kb-plan-\(UUID().uuidString)")
    var root: URL { base.appendingPathComponent("knowledgebase") }
    var repo: URL { base.appendingPathComponent("android") }
    let defaults = UserDefaults(suiteName: "kb-plan-\(UUID().uuidString)")!
    /// The kb plugin of this repository, so actions run the real `kb` CLI on the temp knowledge base.
    static let plugin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardizedFileURL.path

    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func makeEngine(plugin: String = PlanEngineTests.plugin) throws -> MindmillEngine {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try write(root.appendingPathComponent("shared/kb.json"), """
        {"version": 2, "projects": [{"id": "p", "title": "P", "scopes": [
          {"id": "overview", "title": "Overview", "wide": true, "paths": []},
          {"id": "android", "title": "Android", "paths": ["\(repo.path)"]},
          {"id": "ios", "title": "iOS", "paths": []}]}]}
        """)
        try write(root.appendingPathComponent("android/facts/min-sdk.md"), "---\ntitle: Min SDK\ndate: 2026-11-13\n---\n\n26\n")
        try write(root.appendingPathComponent("android/facts/room.md"), "---\ntitle: Room\ndate: 2026-11-13\n---\n\nThe database\n")
        defaults.set("Me", forKey: "myName")
        let platform = EnginePlatform(name: "Windows", machineWord: "PC", secrets: MemorySecretStore(), transport: FakeTransport(),
                                      defaults: defaults, pluginRoot: { plugin })
        let engine = MindmillEngine(rootPath: root.path, platform: platform, remoteFolder: base.appendingPathComponent("remote"))
        engine.isolate(in: base.appendingPathComponent("data"))
        engine.reload()
        return engine
    }

    /// Runs an action from the UI channel (no confirmation); a failure throws its sentence.
    @discardableResult
    func run(_ engine: MindmillEngine, _ name: String, _ params: JSONValue = [:]) async throws -> ActionResult {
        switch await engine.actions.run(name, params, channel: .ui) {
        case .done(let r): return r
        case .confirm(_, let q): throw ActionError("confirm: \(q)")
        case .failed(let m): throw ActionError(m)
        }
    }

    @Test func testTargetsOfAWideScopeComeFromItsScopesRepositories() async throws {
        let engine = try makeEngine()
        try write(repo.appendingPathComponent("settings.gradle.kts"), "rootProject.name = \"x\"\n")
        try write(repo.appendingPathComponent("app/build.gradle.kts"), "plugins { id(\"com.android.application\") }\n")
        _ = try await run(engine, "test.detect", ["scope": "overview"])
        let status = try await engine.call("test.status", ["scope": "overview"], from: RemoteClient(FakeConnection()))
        #expect(status["targets"]?.array?.isEmpty == false)
    }

    func client() -> RemoteClient { RemoteClient(FakeConnection()) }

    // MARK: What the Windows shell's tests found

    @Test func membersNameTheirLeadInTheSessionList() async throws {
        let engine = try makeEngine()
        let hub = engine.sessions
        let lead = hub.newSession(title: "#7 Do it", about: "wi:7", show: false, space: .build)
        let member = hub.newSession(title: "#7 tests", about: "wi:7", show: false, space: .build)
        let list = try await engine.call("sessions.list", [:], from: client())["sessions"]?.array ?? []
        #expect(list.first { $0["id"]?.string == member.id }?["lead"]?.string == lead.id)
        #expect(list.first { $0["id"]?.string == lead.id }?["lead"] == nil)
    }

    @Test func aLocalTrackerShowsNewWorkAtOnceHasNoPullRequestsAndListsReadyWork() async throws {
        let engine = try makeEngine()
        _ = try await engine.cli.run(["settings", "set", "tracker", #"{"kind": "local"}"#, "--scope", "android"])
        let created = try await run(engine, "workitem.create", ["scope": "android", "title": "Offline mode"])
        #expect(created.speech.hasPrefix("Created"))
        let items = try await engine.call("tracker.items", ["scope": "android"], from: client())["items"]?.array ?? []
        #expect(items.contains { $0["title"]?.string == "Offline mode" })
        _ = try await run(engine, "workitem.create", ["scope": "android", "title": "Dark theme"])
        let again = try await engine.call("tracker.items", ["scope": "android"], from: client())["items"]?.array ?? []
        #expect(again.contains { $0["title"]?.string == "Dark theme" })

        let prs = try await run(engine, "prs.list", ["scope": "android"])
        #expect(prs.speech == "You have no open pull requests.")

        let ready = try await run(engine, "work.startable", ["scope": "android", "owner": "everyone"])
        let titles = (ready.data["items"]?.array ?? []).compactMap { $0["title"]?.string }
        #expect(Set(titles) == ["Offline mode", "Dark theme"])
        let mine = try await run(engine, "work.startable", ["scope": "android"])
        #expect(mine.data["items"]?.array?.isEmpty == true)
        #expect(mine.data["owner"]?.string == "me")
    }

    @Test func pullRequestsToReviewListAndStartAReviewSession() async throws {
        let engine = try makeEngine()
        let review = MyWork.Review(id: 318327, title: "Fix login", repo: "app", url: "https://example.invalid/pr/318327",
                                   draft: false, author: "A. Colleague", project: "android", required: true, assigned: true)
        engine.tracker.myWork = MyWork(fetched: "2026-11-24T10:00:00Z", me: "Me", items: [], reviews: [review])
        engine.tracker.myWorkFetched = Date()
        let listed = try await run(engine, "prs.reviews", [:])
        #expect(listed.speech == "1 pull request waits for your review.")
        #expect(listed.data["reviews"]?.array?.first?["id"] == .number(318327))
        #expect(listed.data["reviews"]?.array?.first?["session"] == nil)
        let started = try await run(engine, "pr.review", ["id": "318327"])
        let id = started.data["session"]?.string
        #expect(id != nil && engine.sessions.list.contains { $0.id == id && $0.about == "pr:318327" })
        let again = try await run(engine, "pr.review", ["id": "318327"])
        #expect(again.data["session"]?.string == id)
        #expect(try await run(engine, "prs.reviews", [:]).data["reviews"]?.array?.first?["session"]?.string == id)
    }

    @Test func aForcedRefreshDuringAFetchFetchesAgain() async throws {
        let engine = try makeEngine()
        let t = engine.tracker
        #expect(t.backlogStale)
        t.refreshBacklog(force: true)
        t.refreshBacklog(force: true)
        await t.freshBacklog(seconds: 30)
        #expect(!t.backlogStale)
        #expect(t.backlogHave == t.backlogWanted)
    }

    @Test func stubClaudeFromTheEnvironment() {
        let found = LoginShell.Resolved(environment: ["A": "1"], claude: URL(fileURLWithPath: "/usr/bin/claude"), python3: nil)
        #expect(SystemTools.overriding(found, environment: [:]) == found)
        let stub = SystemTools.overriding(found, environment: ["MINDMILL_CLAUDE": "/tmp/stub"])
        #expect(stub.claude?.path == "/tmp/stub" && stub.environment == ["A": "1"])
    }

    @Test func testStatusOfAWideScopeDetectsWithoutAskingAndSaysWhenNoRepositoryIsHere() async throws {
        let engine = try makeEngine()
        try write(repo.appendingPathComponent("package.json"), #"{"name": "site", "scripts": {"dev": "vite"}}"#)
        let status = try await engine.call("test.status", ["scope": "overview"], from: client())
        #expect(status["targets"]?.array?.isEmpty == false)
        #expect(status["note"] == .null)
        let ios = try await engine.call("test.status", ["scope": "ios"], from: client())
        #expect(ios["note"]?.string?.contains("on this PC") == true)
        let detect = try await run(engine, "test.detect", ["scope": "ios"])
        #expect(detect.speech.contains("on this PC"))
    }

    // MARK: Plan

    @Test func remindersGoalsAndReferences() async throws {
        let engine = try makeEngine()
        let made = try await run(engine, "reminder.create", ["title": "Call the bank", "due": "2026-12-01"])
        let id = try #require(made.data["id"]?.string)
        _ = try await run(engine, "reminder.update", ["id": "bank", "status": "done", "due": "2026-12-02"])
        let r = try engine.reminder(id)
        #expect(r.due == "2026-12-02" && r.status == .open)
        _ = try await run(engine, "reminder.delete", ["id": .string(id)])
        #expect(throws: ActionError.self) { try engine.reminder(id) }

        let goal = try await run(engine, "goal.create", ["title": "Learn Kotlin", "horizon": "2027"])
        let gid = try #require(goal.data["id"]?.string)
        _ = try await run(engine, "goal.progress", ["id": "kotlin", "text": "Read the coroutines guide"])
        _ = try await run(engine, "goal.status", ["id": .string(gid), "status": "paused"])
        let g = try engine.plan.goal(gid)
        #expect(g.status == .paused && g.body.contains("Read the coroutines guide"))
        await #expect(throws: ActionError.self) { try await run(engine, "goal.coach", ["id": .string(gid), "text": "Next?"]) }
        _ = try await run(engine, "goal.delete", ["id": .string(gid)])
        #expect(throws: ActionError.self) { try engine.plan.goal(gid) }

        let ref = try await run(engine, "reference.save", ["scope": "android", "title": "Room docs", "url": "https://developer.android.com/room"])
        let rid = try #require(ref.data["id"]?.string.flatMap(EntryID.init))
        #expect(engine.index.entry(rid)?.field("kind") == "web")
    }

    @Test func entriesFactsAndTheQuizState() async throws {
        let engine = try makeEngine()
        let sdk = EntryID(project: "android", section: .facts, stem: "min-sdk")
        let room = EntryID(project: "android", section: .facts, stem: "room")
        _ = try await run(engine, "entry.tags", ["id": .string(sdk.rawValue), "tags": ["build", "Build", "sdk"]])
        #expect(engine.index.entry(sdk)?.tags == ["build", "sdk"])
        _ = try await run(engine, "fact.link", ["id": .string(sdk.rawValue), "other": .string(room.rawValue)])
        #expect(engine.index.linkedFacts(of: sdk).map(\.id) == [room])
        #expect(engine.plan.linkCandidates(sdk).isEmpty)
        _ = try await run(engine, "quiz.answer", ["fact": .string(sdk.rawValue), "correct": true])
        #expect(engine.plan.quiz.facts[sdk.rawValue] != nil)
        let moved = try await run(engine, "entry.move", ["id": .string(room.rawValue), "to": "ios"])
        #expect(moved.data["id"]?.string == "ios/facts/room")
        _ = try await run(engine, "entry.delete", ["id": "ios/facts/room"])
        #expect(engine.index.entry(EntryID("ios/facts/room")!) == nil)
    }

    @Test func todaysPlanAndUpcomingMeetings() async throws {
        let engine = try makeEngine()
        let today = KBDate.today()
        try write(DailyPlan.url(date: today, root: root), "---\ntitle: Today\ndate: \(today)\n---\n\n## Today\n- [ ] Ship it\n- [ ] Tidy up\n")
        let plan = try await run(engine, "today.plan")
        let first = try #require(plan.data["today"]?.array?.first)
        #expect(plan.speech.contains("2 things left"))
        _ = try await run(engine, "today.check", ["item": first["item"] ?? .null, "done": true])
        #expect(DailyPlan.load(date: today, root: root)?.today.first?.done == true)

        _ = try await run(engine, "meeting.create", ["scope": "android", "title": "Planning", "date": "today", "start": "23:59"])
        let upcoming = try await run(engine, "calendar.upcoming", ["days": 2])
        #expect(upcoming.data["events"]?.array?.first?["title"]?.string == "Planning")
        let meeting = try #require(upcoming.data["events"]?.array?.first?["id"]?.string)
        let prep = try await run(engine, "meeting.prepare", ["meeting": .string(meeting)])
        let s = try #require(engine.sessions.session(prep.data["session"]?.string))
        #expect(s.space == .plan && s.title == "Prepare: Planning")
    }

    @Test func backlogProposalsAndSessionsForPlanWork() async throws {
        let engine = try makeEngine()
        let proposed = try await run(engine, "backlog.propose", ["scope": "android", "title": "Export to CSV", "details": "From the list"])
        let id = try #require(proposed.data["id"]?.string.flatMap(EntryID.init))
        #expect(engine.backlog.proposals(scope: "android").map(\.id) == [id])
        _ = try await run(engine, "backlog.reject", ["id": .string(id.rawValue)])
        #expect(engine.backlog.proposals(scope: "android").isEmpty)

        let asked = try await run(engine, "entry.ask", ["id": "android/facts/room"])
        #expect(engine.sessions.session(asked.data["session"]?.string)?.subject?.title == "Room")
        _ = try await run(engine, "discussion.start", ["scope": "android", "look_for": "the login thread"])
        #expect(engine.sessions.list.contains { $0.title == "New discussion" })
        await #expect(throws: ActionError.self) { try await run(engine, "sync.calendar") }
        #expect(engine.routines.calendarSync.inFlight == false)
    }

    @Test func sprintWatchRemembersAnEndedSprint() throws {
        let engine = try makeEngine()
        let ended = SprintInfo(name: "Sprint 4", path: "S\\Sprint 4", start: "2026-11-02", finish: "2026-11-13")
        let t = TrackerSprints(key: "local:android", kind: "local", scopes: ["android"], state: .ended, previous: ended)
        let fresh = engine.sprints.take(SprintReport(today: "2026-11-14", trackers: [t]), today: "2026-11-14")
        #expect(engine.sprints.tracker(scope: "overview")?.key == "local:android")
        engine.sprints.snooze("local:android")
        #expect(fresh.map(\.1.sprint.name) == ["Sprint 4"])
        #expect(engine.sprints.watch.pending("local:android", today: KBDate.today()) == nil)
        #expect(FileManager.default.fileExists(atPath: engine.sprints.watchURL.path))
    }

    @Test func helpers() {
        #expect(MindmillEngine.pullOutcome("android: pulled 3 commits\n", count: 1).message == "Pulled android.")
        #expect(MindmillEngine.pullOutcome("android: not pulled (local changes)\n", count: 2).ok == false)
        #expect(BacklogCenter.parseBrainVerdicts("1: same\n#2: different\n3: maybe").map(\.1) == ["same", "different"])
        #expect(RoutineCenter.firstLine("\n  calendar: 3 meetings\nmore") == "calendar: 3 meetings")
        #expect(ActionText.clock(Date(timeIntervalSince1970: 0)).count == 5)
    }
}
