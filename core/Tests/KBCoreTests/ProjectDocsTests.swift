import Foundation
import Testing
@testable import KBCore

@Suite struct ProjectDocsTests {
    @Test func decodesTheListAndGroupsByFolder() throws {
        let json = """
        {"checkout": "/r", "docs": [
          {"path": "docs/b.md", "title": "Beta", "file": "/k/docs-drafts/docs/b.md", "repo_file": "/r/docs/b.md", "exists": true, "draft": "edited", "draft_file": "/k/docs-drafts/docs/b.md", "stale": true, "modified": "2026-11-13T10:00"},
          {"path": "README.md", "title": "Readme", "file": "/r/README.md", "repo_file": "/r/README.md", "exists": true, "draft": null, "draft_file": null, "stale": false, "modified": ""},
          {"path": "docs/a.md", "title": "Alpha", "file": "/r/docs/a.md", "repo_file": "/r/docs/a.md", "exists": true, "draft": null, "draft_file": null, "stale": false, "modified": ""}
        ]}
        """
        let list = try ProjectDocList.decode(json)
        #expect(list.byFolder.map(\.folder) == ["", "docs"])
        #expect(list.byFolder[1].docs.map(\.title) == ["Alpha", "Beta"])
        #expect(list.drafts.map(\.path) == ["docs/b.md"])
        #expect(list.docs[0].stale)
    }

    @Test func pathsForNewDocs() {
        #expect(ProjectDocPath.suggested(title: "BLE Reconnect Flow") == "docs/ble-reconnect-flow.md")
        #expect(ProjectDocPath.isValid("docs/x.md"))
        #expect(!ProjectDocPath.isValid("../x.md"))
        #expect(!ProjectDocPath.isValid("/abs/x.md"))
        #expect(!ProjectDocPath.isValid("docs/x.swift"))
        #expect(!ProjectDocPath.isValid("knowledgebase/x.md"))
    }

    @Test func briefNamesTheFilesAndClearsTheDrafts() {
        let doc = ProjectDocList.Doc(path: "docs/b.md", title: "B", file: "/k/b.md", draft: "new")
        let brief = ProjectDocPath.prBrief(scope: "contoso-android", docs: [doc], note: "")
        #expect(brief.contains("`docs/b.md` (new): the new text is in `/k/b.md`"))
        #expect(brief.contains("kb docs saved --scope contoso-android docs/b.md"))
        #expect(brief.contains("Keep the draft paths"))
    }
}
