import Foundation
import Testing
@testable import KBCore

@Suite struct KBLayoutTests {
    /// A split KB with Android (a repo) and an Overview without one.
    private func makeKB() throws -> (root: URL, repo: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kblayout-\(UUID().uuidString)")
        let root = base.appendingPathComponent("knowledgebase")
        let repo = base.appendingPathComponent("android")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        let registry = """
        {"version": 2, "projects": [{"id": "p", "title": "P", "scopes": [
          {"id": "overview", "title": "Overview", "wide": true, "paths": []},
          {"id": "android", "title": "Android", "paths": ["\(repo.path)"]},
          {"id": "ios", "title": "iOS", "paths": []}]}]}
        """
        try registry.write(to: root.appendingPathComponent("shared/kb.json"), atomically: true, encoding: .utf8)
        func write(_ url: URL, _ title: String) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "---\ntitle: \(title)\ndate: 2026-11-13\n---\n\nBody\n".write(to: url, atomically: true, encoding: .utf8)
        }
        try write(repo.appendingPathComponent("knowledgebase/decisions/2026-11-13-use-room.md"), "Use Room")
        try write(root.appendingPathComponent("android/discussions/2026-11-13-login.md"), "Login")
        try write(root.appendingPathComponent("overview/facts/brand.md"), "Brand")
        return (root, repo)
    }

    @Test func readsTeamAndPrivateFolders() throws {
        let (root, repo) = try makeKB()
        let index = try KBIndex.load(root: root)
        let decision = EntryID(project: "android", section: .decisions, stem: "2026-11-13-use-room")
        #expect(index.entry(decision)?.title == "Use Room")
        #expect(index.entry(EntryID(project: "android", section: .discussions, stem: "2026-11-13-login")) != nil)
        #expect(index.entry(EntryID(project: "overview", section: .facts, stem: "brand")) != nil)
        #expect(index.members(of: "overview") == ["overview", "android", "ios"])
        let layout = KBLayout.of(root: root)
        #expect(layout.isTeam(repo.appendingPathComponent("knowledgebase/decisions/2026-11-13-use-room.md")))
        #expect(EntryID(fileURL: repo.appendingPathComponent("knowledgebase/decisions/2026-11-13-use-room.md"), root: root) == decision)
        #expect(EntryID(fileURL: root.appendingPathComponent("overview/facts/brand.md"), root: root)?.rawValue == "overview/facts/brand")
    }

    @Test func newEntriesAlwaysGoInThePrivateFolder() throws {
        let (root, _) = try makeKB()
        let layout = KBLayout.of(root: root)
        let fact = EntryID(project: "android", section: .facts, stem: "min-sdk")
        #expect(fact.fileURL(root: root).path.hasPrefix(root.appendingPathComponent("android").path))
        let meeting = EntryID(project: "android", section: .meetings, stem: "2026-11-13-standup")
        #expect(meeting.fileURL(root: root).path.hasPrefix(root.appendingPathComponent("android").path))
        // No repo on this Mac: everything private.
        #expect(EntryID(project: "ios", section: .facts, stem: "x").fileURL(root: root).path.hasPrefix(root.appendingPathComponent("ios").path))
        #expect(EntryID(project: "overview", section: .decisions, stem: "x").fileURL(root: root).path.hasPrefix(root.appendingPathComponent("overview").path))
        #expect(layout.home == root.appendingPathComponent("shared", isDirectory: true))
        #expect(Reminders.directory(root: root).path.hasSuffix("shared/reminders"))
    }

    @Test func anEntryInBothFoldersIsReadFromThePrivateOne() throws {
        let (root, repo) = try makeKB()
        let mine = root.appendingPathComponent("android/decisions/2026-11-13-use-room.md")
        try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\ntitle: Use Room (mine)\ndate: 2026-11-13\n---\n".write(to: mine, atomically: true, encoding: .utf8)
        let id = EntryID(project: "android", section: .decisions, stem: "2026-11-13-use-room")
        #expect(try KBIndex.load(root: root).entry(id)?.title == "Use Room (mine)")
        #expect(id.fileURL(root: root).standardizedFileURL == mine.standardizedFileURL)
        _ = repo
    }

    @Test func legacyLayoutIsUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kblegacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"version": 1, "projects": [{"id": "a", "title": "A", "paths": []}]}"#
            .write(to: root.appendingPathComponent("kb.json"), atomically: true, encoding: .utf8)
        let id = EntryID(project: "a", section: .facts, stem: "x")
        #expect(id.fileURL(root: root).path.hasSuffix("projects/a/facts/x.md"))
        #expect(!KBLayout.of(root: root).isSplit)
    }
}
