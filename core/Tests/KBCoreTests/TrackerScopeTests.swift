import Foundation
import Testing
@testable import KBCore

@Suite struct TrackerScopeTests {
    /// A split knowledge base with one project: its Overview, a repository scope and one with its own tracker.
    private func knowledgeBase() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        let registry: [String: Any] = ["version": 2, "projects": [[
            "id": "prod", "title": "Prod", "scopes": [
                ["id": "prod-wide", "title": "Overview", "wide": true, "paths": [String]()],
                ["id": "app", "title": "App", "paths": ["~/app"]],
                ["id": "web", "title": "Web", "paths": ["~/web"]],
            ],
        ]]]
        try JSONSerialization.data(withJSONObject: registry).write(to: root.appendingPathComponent("shared/kb.json"))
        func set(_ scope: String, _ tracker: [String: Any]) throws {
            let url = ProjectSettings.url(project: scope, root: root)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["tracker": tracker]).write(to: url)
        }
        try set("prod-wide", ["kind": "local"])
        try set("web", ["kind": "jira", "organization": "acme.atlassian.net", "project": "WEB"])
        return root
    }

    @Test func aScopeWithoutATrackerUsesItsOverviewsAndItsBoard() throws {
        let root = try knowledgeBase()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ProjectSettings.trackerScope("app", root: root) == "prod-wide")
        #expect(ProjectSettings.tracker(scope: "app", root: root).kind == "local")
        #expect(ProjectSettings.trackerScope("web", root: root) == "web")
        #expect(ProjectSettings.trackerScope("prod-wide", root: root) == "prod-wide")
        #expect(LocalTracker.url(scope: "app", root: root) == LocalTracker.url(scope: "prod-wide", root: root))
        #expect(!ProjectSettings.load(project: "app", root: root).ownsTracker)
    }

    @Test func withoutAnOverviewTrackerAScopeKeepsNone() throws {
        let root = try knowledgeBase()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: ProjectSettings.url(project: "prod-wide", root: root))
        #expect(ProjectSettings.trackerScope("app", root: root) == "app")
        #expect(ProjectSettings.tracker(scope: "app", root: root).kind == "none")
    }
}
