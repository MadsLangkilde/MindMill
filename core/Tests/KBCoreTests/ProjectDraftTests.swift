import Foundation
import Testing
@testable import KBCore

@Suite struct ProjectDraftTests {
    let home = "/Users/me"

    func registry() -> Registry {
        Registry(projects: [.init(id: "acme", title: "Acme")], scopes: [
            .init(id: "acme-wide", title: "Overview", project: "acme", wide: true),
            .init(id: "android", title: "Android", project: "acme", paths: ["~/src/android"], remotes: ["_git/android"]),
            .init(id: "ios", title: "iOS", project: "acme", paths: ["~/src/ios"], related: ["other"]),
            .init(id: "other", title: "Other", project: "zeta", wide: true),
        ] ) .with(project: .init(id: "zeta", title: "Zeta"))
    }

    @Test func locationsComeFromScopesUntilNamed() {
        var r = registry()
        #expect(r.locations(of: "acme") == [.init(name: "Android", path: "~/src/android"), .init(name: "iOS", path: "~/src/ios")])
        r.projects[0].locations = [.init(name: "Android app", path: "~/src/android")]
        #expect(r.locations(of: "acme").map(\.name) == ["Android app", "iOS"])
    }

    @Test func locationsRoundTripThroughJSON() throws {
        var r = registry()
        r.projects[0].locations = [.init(name: "Android app", path: "~/src/android")]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID().uuidString).json")
        try r.json.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let back = try Registry.load(url)
        #expect(back.projects.first { $0.id == "acme" }?.locations == [.init(name: "Android app", path: "~/src/android")])
        #expect(back.projects.first { $0.id == "zeta" }?.locations == [])
    }

    @Test func newProjectNeedsANameAndALocation() {
        let r = registry()
        var d = ProjectDraft()
        #expect(d.problem(in: r) == "Give the project a name.")
        d.setTitle("Billing App", in: r)
        #expect(d.newID == "billing-app")
        #expect(d.problem(in: r)?.contains("at least one location") == true)
        d.addLocation(path: "/Users/me/src/billing", name: "Billing", withScope: true, home: home)
        #expect(d.problem(in: r) == nil)
    }

    @Test func newProjectIdFollowsTitleUntilTyped() {
        let r = registry()
        var d = ProjectDraft()
        d.setTitle("Acme", in: r)
        #expect(d.newID == "acme-2")
        d.setID("acme-new")
        d.setTitle("Acme Two", in: r)
        #expect(d.newID == "acme-new")
        d.setID("Bad Id")
        #expect(d.problem(in: r)?.contains("can't be a project id") == true)
    }

    @Test func applyingANewProjectMakesItsScopes() throws {
        let r = registry()
        var d = ProjectDraft()
        d.setTitle("Billing", in: r)
        d.addLocation(path: "/Users/me/src/api", name: "API", withScope: true, home: home)
        d.addLocation(path: "/Users/me/src/web", name: "Web", withScope: true, home: home)
        let mobile = d.addScope(title: "Front ends")
        let i = d.scopes.firstIndex { $0.id == mobile }!
        d.scopes[i].includes = d.scopes.filter { $0.title == "Web" }.map(\.id)
        d.scopes[i].related = ["android"]
        let out = try d.apply(to: r)
        #expect(out.project == "billing")
        #expect(out.scopes == ["billing-wide", "api", "web", "front-ends"])
        let made = out.registry.scopes(in: "billing")
        #expect(made.first { $0.id == "billing-wide" }?.wide == true)
        #expect(made.first { $0.id == "api" }?.paths == ["~/src/api"])
        #expect(made.first { $0.id == "front-ends" }?.includes == ["web"])
        #expect(made.first { $0.id == "front-ends" }?.related == ["android"])
        #expect(out.registry.projects.last?.locations.map(\.name) == ["API", "Web"])
        #expect(out.removals.isEmpty)
    }

    @Test func editingKeepsIdsAndRelatedOfTheSameProject() throws {
        var r = registry()
        r.scopes[2].related = ["android", "other"]
        var d = try #require(ProjectDraft(project: "acme", registry: r))
        #expect(d.scopes.first { $0.existing == "ios" }?.related == ["other"])
        let ios = d.scopes.first { $0.existing == "ios" }!.id
        d.scopes[d.scopes.firstIndex { $0.id == ios }!].title = "Apple"
        let out = try d.apply(to: r)
        let s = out.registry.scopes.first { $0.id == "ios" }!
        #expect(s.title == "Apple")
        #expect(s.related == ["android", "other"])
        #expect(out.registry.scopes.first { $0.id == "android" }?.remotes == ["_git/android"])
    }

    @Test func renamingALocationRenamesItsScope() throws {
        let r = registry()
        var d = try #require(ProjectDraft(project: "acme", registry: r))
        let loc = d.locations.first { $0.path == "~/src/android" }!.id
        d.renameLocation(loc, to: "Droid")
        #expect(d.scopes.first { $0.existing == "android" }?.title == "Droid")
        d.moveLocation(loc, to: "/Users/me/code/android", home: home)
        #expect(d.scopes.first { $0.existing == "android" }?.paths == ["~/code/android"])
        d.removeLocation(loc)
        #expect(d.scopes.first { $0.existing == "android" }?.paths == [])
    }

    @Test func removedScopesMoveTheirEntriesToTheWideOne() throws {
        let r = registry()
        var d = try #require(ProjectDraft(project: "acme", registry: r))
        let ios = d.scopes.first { $0.existing == "ios" }!.id
        let android = d.scopes.first { $0.existing == "android" }!.id
        d.scopes[d.scopes.firstIndex { $0.id == android }!].includes = [ios]
        d.removeScope(ios)
        #expect(d.scopes.first { $0.id == android }?.includes == [])
        let out = try d.apply(to: r)
        #expect(out.removals == ["ios": "acme-wide"])
        #expect(out.registry.scopes.contains { $0.id == "ios" })
        d.restoreScope("ios")
        #expect(d.removed.isEmpty)
        #expect(d.scopes.contains { $0.existing == "ios" })
    }

    @Test func theWideScopeCanMoveButNotBeRemoved() throws {
        let r = registry()
        var d = try #require(ProjectDraft(project: "acme", registry: r))
        let wide = d.scopes.first(where: \.wide)!.id
        d.removeScope(wide)
        #expect(d.scopes.contains { $0.id == wide })
        let android = d.scopes.first { $0.existing == "android" }!.id
        d.makeWide(android)
        let out = try d.apply(to: r)
        #expect(out.registry.scopes.first { $0.id == "android" }?.wide == true)
        #expect(out.registry.scopes.first { $0.id == "acme-wide" }?.wide == false)
    }

    @Test func remotesAreParsedOnSave() throws {
        let r = registry()
        var d = try #require(ProjectDraft(project: "acme", registry: r))
        let i = d.scopes.firstIndex { $0.existing == "android" }!
        d.scopes[i].remotes = "_git/a, , _git/b, "
        let out = try d.apply(to: r)
        #expect(out.registry.scopes.first { $0.id == "android" }?.remotes == ["_git/a", "_git/b"])
    }

    @Test func typedScopeIdsMustBeFree() {
        let r = registry()
        var d = ProjectDraft()
        d.setTitle("New", in: r)
        d.addLocation(path: "/x", name: "X", withScope: false, home: home)
        let s = d.addScope(title: "Thing")
        d.scopes[d.scopes.firstIndex { $0.id == s }!].newID = "android"
        #expect(d.problem(in: r)?.contains("is taken") == true)
    }
}

@Suite struct ProjectDraftJSONTests {
    let home = "/Users/me"

    func registry() -> Registry {
        Registry(projects: [.init(id: "acme", title: "Acme", locations: [.init(name: "Droid", path: "~/src/android")])], scopes: [
            .init(id: "acme-wide", title: "Overview", project: "acme", wide: true),
            .init(id: "android", title: "Android", project: "acme", paths: ["~/src/android"]),
            .init(id: "ios", title: "iOS", project: "acme", paths: ["~/src/ios"]),
        ])
    }

    @Test func getListsLocationsAndScopes() {
        let j = ProjectDraft.json(project: "acme", registry: registry(), entries: { $0 == "ios" ? 3 : 0 }, home: home)
        #expect(j["locations"]?.array?.compactMap { $0["name"]?.string } == ["Droid", "iOS"])
        #expect(j["scopes"]?.array?.last?["entries"] == .number(3))
        #expect(j["scopes"]?.array?.first?["wide"] == .bool(true))
    }

    @Test func savingANewProjectFromThePhone() throws {
        let r = registry()
        let body: JSONValue = [
            "title": "Billing", "locations": [["name": "API", "path": "/Users/me/src/api"]],
            "scopes": [["title": "API", "paths": ["~/src/api"]], ["title": "All", "includes": ["API"]]],
        ]
        let d = try ProjectDraft.from(json: body, id: nil, registry: r, home: home)
        #expect(d.scopes.first?.wide == true)
        let out = try d.apply(to: r)
        #expect(out.scopes == ["billing-wide", "api", "all"])
        #expect(out.registry.scopes.first { $0.id == "all" }?.includes == ["api"])
        #expect(out.registry.projects.last?.locations == [.init(name: "API", path: "~/src/api")])
    }

    @Test func scopesLeftOutAreRemoved() throws {
        let r = registry()
        let body: JSONValue = ["scopes": [["id": "acme-wide"], ["id": "android", "title": "Droid"]]]
        let d = try ProjectDraft.from(json: body, id: "acme", registry: r, home: home)
        let out = try d.apply(to: r)
        #expect(out.removals == ["ios": "acme-wide"])
        #expect(out.registry.scopes.first { $0.id == "android" }?.title == "Droid")
    }

    @Test func theWideScopeDropsPathsOtherScopesWorkIn() throws {
        let body: JSONValue = ["scopes": [["id": "acme-wide", "paths": ["~/src/android", "~/src/ios"]], ["id": "android"]]]
        let out = try ProjectDraft.from(json: body, id: "acme", registry: registry(), home: home).apply(to: registry())
        #expect(out.registry.scopes.first { $0.id == "acme-wide" }?.paths == ["~/src/ios"])
    }

    @Test func pathsMustBeLocations() {
        let body: JSONValue = ["scopes": [["id": "acme-wide"], ["id": "android", "paths": ["~/elsewhere"]], ["id": "ios"]]]
        #expect(throws: (any Error).self) { try ProjectDraft.from(json: body, id: "acme", registry: registry(), home: home) }
    }

    @Test func foldersStayInTheHomeFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("src/app/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        let top = try FolderListing.list(nil, home: home.path)
        #expect(top["folders"]?.array?.compactMap { $0["name"]?.string } == ["src"])
        #expect(top["parent"] == .null)
        let src = try FolderListing.list("~/src", home: home.path)
        #expect(src["folders"]?.array?.first?["repository"] == .bool(true))
        #expect(src["parent"] == .string("~"))
        #expect(throws: (any Error).self) { try FolderListing.list("/etc", home: home.path) }
        #expect(throws: (any Error).self) { try FolderListing.list("~/../..", home: home.path) }
    }
}

private extension Registry {
    func with(project: Registry.Project) -> Registry {
        var r = self
        r.projects.append(project)
        return r
    }
}
