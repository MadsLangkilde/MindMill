import Foundation
import Testing
@testable import KBCore

@Suite struct SharingTests {
    @Test func parsesStatusAndDefaultsToPrivate() throws {
        let json = """
        {"scopes": {"android": {"repo": "/x/contoso-android", "branch": "test/1", "upstream": "origin/test/1",
                                "entries": {"android/facts/a": "pushed", "android/facts/b": "uncommitted"}},
                    "overview": {"repo": null, "branch": null, "upstream": null, "entries": {}}}}
        """
        let s = try #require(SharingStatus.parse(json))
        #expect(s.state(of: EntryID(project: "android", section: .facts, stem: "a")) == .pushed)
        #expect(s.state(of: EntryID(project: "android", section: .facts, stem: "b")) == .uncommitted)
        #expect(s.state(of: EntryID(project: "android", section: .facts, stem: "c")) == .private)
        #expect(s.state(of: EntryID(project: "overview", section: .facts, stem: "c")) == .noRepository)
        #expect(s.repos["android"]?.name == "contoso-android")
    }

    @Test func helpSaysWhetherOthersCanSeeIt() {
        #expect(EntrySharing.pushed.help(repo: "app", branch: "main").contains("others with access to app can see it"))
        #expect(EntrySharing.uncommitted.help(repo: "app", branch: nil).contains("not committed yet"))
        #expect(EntrySharing.unpushed.help(repo: "app", branch: "main").contains("not pushed yet"))
        #expect(EntrySharing.missing.help(repo: "app", branch: "old").contains("safe in your knowledge base"))
        #expect(!EntrySharing.private.isShared && EntrySharing.unpushed.isShared)
        #expect(SharingStatus.sharedByDefault(.decisions) && !SharingStatus.sharedByDefault(.meetings))
    }

    private func index(_ dir: URL) -> KBIndex {
        let a = dir.appendingPathComponent("android"), i = dir.appendingPathComponent("ios"), l = dir.appendingPathComponent("lib")
        for d in [a, i, l] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        return KBIndex(root: dir, projects: [
            KBProject(id: "all", title: "Overview", group: "p", wide: true),
            KBProject(id: "android", title: "Android", paths: [a.path], group: "p", wide: false),
            KBProject(id: "ios", title: "iOS", paths: [i.path], group: "p", wide: false),
            KBProject(id: "mobile", title: "Mobile", related: ["lib", "gone"], group: "p", wide: false, includes: ["android", "ios"]),
            KBProject(id: "lib", title: "Lib", paths: [l.path], group: "q", wide: false),
            KBProject(id: "web", title: "Web", paths: ["/nowhere/web"], group: "q", wide: false),
        ], entries: [:])
    }

    @Test func multiRepoScopeWorksOnTwoAndReadsAThird() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("repos-\(UUID().uuidString)")
        let r = ScopeRepositories.of("mobile", in: index(dir))
        #expect(r.work.map(\.scope) == ["android", "ios"])
        #expect(r.reference.map(\.scope) == ["lib"])
        #expect(r.workingDirectory?.lastPathComponent == "android")
        #expect(r.extraDirectories.map(\.lastPathComponent) == ["ios", "lib"])
        let single = ScopeRepositories.of("web", in: index(dir))
        #expect(single.work.first?.checkout == nil && single.workingDirectory == nil)
    }

    @Test func addDirGoesOnTheCommandLine() {
        var l = ClaudeLaunch(executable: URL(fileURLWithPath: "/bin/claude"), pluginRoot: "/p", systemPrompt: "x",
                             sessionID: "s", workingDirectory: URL(fileURLWithPath: "/a"))
        #expect(!l.arguments.contains("--add-dir"))
        l.additionalDirectories = [URL(fileURLWithPath: "/b"), URL(fileURLWithPath: "/c")]
        let args = l.arguments
        let at = try? #require(args.firstIndex(of: "--add-dir"))
        #expect(at.map { Array(args[($0 + 1)...($0 + 2)]) } == ["/b", "/c"])
    }

    @Test func repoStateSummary() {
        let states = RepoState.parse("""
        {"scope": "mobile", "repos": [{"scope": "android", "path": "/a", "git": true, "branch": "main", "upstream": "origin/main", "ahead": 1, "behind": 3, "changed": 2},
                                      {"scope": "lib", "path": "/l", "git": false},
                                      {"scope": "web", "path": null}]}
        """)
        #expect(states["android"]?.summary == "main · 3 behind · 1 not pushed · 2 changed files")
        #expect(states["lib"]?.summary == "Not a git repository")
        #expect(states["lib"]?.canPull == false)
        #expect(states["web"] == nil)
        #expect(RepoState(git: true, branch: "main", upstream: "origin/main").summary == "main · up to date")
    }

    @Test func registryKeepsKnowledgeOnlyScopesClean() throws {
        var r = Registry(projects: [.init(id: "p", title: "P"), .init(id: "q", title: "Q")], scopes: [
            .init(id: "all", title: "O", project: "p", wide: true),
            .init(id: "mobile", title: "Mobile", project: "p", related: ["lib", "mobile", "android", "gone"], includes: ["android"]),
            .init(id: "android", title: "Android", project: "p"),
            .init(id: "lib", title: "Lib", project: "q", wide: true),
        ])
        r.scopes[1].paths = []
        let json = try #require(JSONSerialization.jsonObject(with: r.json) as? [String: Any])
        let scopes = ((json["projects"] as? [[String: Any]])?.first?["scopes"] as? [[String: Any]]) ?? []
        let mobile = try #require(scopes.first { $0["id"] as? String == "mobile" })
        #expect(mobile["related"] as? [String] == ["lib"])
        #expect(mobile["includes"] as? [String] == ["android"])
    }
}
