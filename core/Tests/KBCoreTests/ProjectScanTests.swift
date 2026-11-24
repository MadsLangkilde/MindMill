import Foundation
import Testing
@testable import KBCore

struct ProjectScanTests {
    let log = """
    {"type": "start", "scope": "android", "kinds": ["facts", "decisions"], "sources": ["code", "docs"], "focus": "BLE", "at": "2026-11-15T09:00:00Z"}
    {"type": "progress", "text": "Reading the BLE layer", "at": "2026-11-15T09:01:00Z"}
    {"type": "finding", "id": "f1", "kind": "facts", "scope": "android", "title": "Min SDK is 26", "summary": "s", "body": "b", "source": "app/build.gradle:12", "scopes": [], "date": "", "updates": "", "path": "", "confidence": "high", "at": "2026-11-15T09:02:00Z"}
    {"type": "finding", "id": "f2", "kind": "decisions", "scope": "acme-go", "title": "Use Room", "updates": "android/decisions/x", "at": "2026-11-15T09:03:00Z"}
    not json
    {"type": "finding", "id": "f3", "kind": "gossip", "title": "skipped"}
    {"type": "applied", "finding": "f1", "entry": "android/facts/min-sdk-is-26", "at": "2026-11-15T09:10:00Z"}
    {"type": "dismissed", "finding": "f9"}
    """

    @Test func foldsTheLog() throws {
        let run = try #require(ScanRun.parse(id: "20261115-090000-android", text: log))
        #expect(run.scope == "android")
        #expect(run.kinds == [.facts, .decisions])
        #expect(run.sources == [.code, .docs])
        #expect(run.focus == "BLE")
        #expect(run.progress == ["Reading the BLE layer"])
        #expect(run.findings.map(\.id) == ["f1", "f2"])
        #expect(run.findings[0].status == .applied)
        #expect(run.findings[0].entry == "android/facts/min-sdk-is-26")
        #expect(run.findings[1].updates == "android/decisions/x")
        #expect(run.pending.map(\.id) == ["f2"])
        #expect(!run.isFinished)
        #expect(run.started != nil)
        #expect(run.grouped(run.findings).map(\.kind) == [.decisions, .facts])
    }

    @Test func finishedAndFailed() throws {
        let run = try #require(ScanRun.parse(id: "r", text: log + "\n{\"type\": \"done\", \"note\": \"no access\", \"failed\": true, \"at\": \"2026-11-15T09:20:00Z\"}"))
        #expect(run.isFinished)
        #expect(run.failed)
        #expect(run.note == "no access")
    }

    @Test func noStartNoRun() {
        #expect(ScanRun.parse(id: "r", text: "{\"type\": \"progress\", \"text\": \"x\"}") == nil)
    }

    @Test func loadsNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for id in ["20261101-100000-a", "20261115-100000-b"] {
            try "{\"type\": \"start\", \"scope\": \"\(id.suffix(1))\"}\n".write(to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        }
        #expect(ScanRun.loadAll(dir: dir).map(\.scope) == ["b", "a"])
    }

    @Test func promptNamesRunKindsAndRules() {
        var run = ScanRun(id: "20261115-090000-android", scope: "android", kinds: [.architecture], sources: [.code], focus: "Only BLE")
        run.started = Date()
        let p = ScanPrompt.system(run: run, scopeTitle: "Android", project: "Acme Go", wideScope: "acme-go", otherScopes: ["ios"],
                                  checkout: "/repo", hasOverview: true)
        #expect(p.contains("kb scan found --run 20261115-090000-android"))
        #expect(p.contains("architecture: one note per part"))
        #expect(!p.contains("decisions: a choice"))
        #expect(p.contains("Only BLE"))
        #expect(p.contains("--scope acme-go"))
        #expect(p.contains("kb list --project android"))
        #expect(p.contains("Never record secrets"))
    }

    @Test func registryAddsRepositoriesAndProjects() {
        var r = Registry()
        let p = r.addProject(title: "Acme Go")
        #expect(p == "acme-go")
        #expect(r.scopes(in: p).filter(\.wide).count == 1)
        let a = r.addRepository(path: "/Users/me/projects/android", title: "Android", project: p, home: "/Users/me")
        #expect(a == "android")
        #expect(r.scopes.first { $0.id == a }?.paths == ["~/projects/android"])
        #expect(r.addRepository(path: "/Users/me/projects/android", title: "Other", project: p, home: "/Users/me") == "android")
        let b = r.addRepository(path: "/elsewhere/android", title: "Android", project: p, home: "/Users/me")
        #expect(b == "android-2")
        r.locate(scope: b, path: "/Users/me/src/android", home: "/Users/me")
        #expect(r.scopes.first { $0.id == b }?.paths == ["~/src/android", "/elsewhere/android"])
        #expect(r.problem == nil)
    }

    @Test func createsAnEmptySplitKnowledgeBase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Registry.createKnowledgeBase(root: root)
        #expect(KBLayout.isSplit(root: root))
        var r = try Registry.load(root.appendingPathComponent("shared/kb.json"))
        #expect(r.projects.isEmpty)
        let p = r.addProject(title: "Demo")
        try r.save(root: root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(r.scopes(in: p)[0].id).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("projects").path))
        try Registry.createKnowledgeBase(root: root)
        #expect(try Registry.load(root.appendingPathComponent("shared/kb.json")).projects.count == 1)
    }

    @Test func scopeRepoSeesTheTeamFolder() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("knowledgebase/facts"), withIntermediateDirectories: true)
        try "x".write(to: repo.appendingPathComponent("knowledgebase/facts/a.md"), atomically: true, encoding: .utf8)
        try "x".write(to: repo.appendingPathComponent("knowledgebase/overview.md"), atomically: true, encoding: .utf8)
        let s = ScopeRepo.of(paths: ["/nope", repo.path])
        #expect(s.checkout?.standardizedFileURL.path == repo.standardizedFileURL.path)
        #expect(s.hasTeamFolder)
        #expect(s.teamEntries == 2)
        #expect(ScopeRepo.of(paths: ["/nope"]).checkout == nil)
    }
}
