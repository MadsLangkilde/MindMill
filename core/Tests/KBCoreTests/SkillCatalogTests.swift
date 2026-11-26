import Foundation
import Testing
@testable import KBCore

struct SkillCatalogTests {
    private func tree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func findsTheUsersTheProjectsAndThePluginsSkills() throws {
        let root = try tree([
            "home/.claude/skills/release-notes/SKILL.md": "---\nname: release-notes\ndescription: \"Write release notes from merged PRs\"\n---\nSteps",
            "home/.claude/skills/not-a-skill/README.md": "x",
            "home/.claude/commands/standup.md": "---\ndescription: Draft my stand-up\n---\n",
            "home/.claude/skills/synced/abc/docx/SKILL.md": "---\nname: docx\ndescription: Word files\n---\n",
            "repo/.claude/skills/deploy/SKILL.md": "---\nname: deploy\ndescription: Deploy the app\n---\n",
            "plugins/mindmill/skills/idea/SKILL.md": "---\nname: idea\ndescription: Brainstorm ideas\n---\n",
        ])
        let home = SkillCatalog.Home(user: root.appendingPathComponent("home/.claude"), projectFolder: ".claude")
        let all = SkillCatalog.scan(home: home, repos: [("app", root.appendingPathComponent("repo"))],
                                    plugins: [.init(name: "mindmill", folder: root.appendingPathComponent("plugins/mindmill"))],
                                    listed: ["compact", "mindmill:idea", "release-notes"])
        #expect(Set(all.map(\.command)) == ["/release-notes", "/standup", "/anthropic-skills:docx", "/deploy", "/mindmill:idea", "/compact"])
        let deploy = try #require(all.first { $0.name == "deploy" })
        #expect(deploy.source == .project && deploy.scope == "app" && deploy.editable && deploy.location == .project)
        #expect(all.first { $0.name == "release-notes" }?.description == "Write release notes from merged PRs")
        #expect(all.first { $0.name == "idea" }?.editable == false)
        #expect(all.first { $0.name == "compact" }?.source == .command)
    }

    @Test func slashMatchesRankPrefixesFirst() {
        let skills = [
            SkillInfo(name: "idea", description: "Brainstorm ideas", source: .plugin, plugin: "mindmill"),
            SkillInfo(name: "research", description: "Look into an idea", source: .plugin, plugin: "mindmill"),
            SkillInfo(name: "ideate", description: "", source: .user),
            SkillInfo(name: "deploy", description: "", source: .project, scope: "app"),
        ]
        #expect(SkillCatalog.matches(skills, query: "ide").map(\.command) == ["/ideate", "/mindmill:idea", "/mindmill:research"])
        #expect(SkillCatalog.matches(skills, query: "mindmill:r").map(\.command) == ["/mindmill:research"])
        #expect(SkillCatalog.matches(skills, query: "").first?.command == "/deploy")
    }

    @Test func draftsComeBackAsTheFileOnly() {
        #expect(SkillCatalog.cleanDraft("```markdown\n---\nname: x\n---\nDo it\n```") == "---\nname: x\n---\nDo it\n")
        #expect(SkillCatalog.cleanDraft("Here it is:\n---\nname: x\n---\nDo it") == "---\nname: x\n---\nDo it\n")
        #expect(SkillCatalog.safeName("Release Notes!") == "release-notes")
        #expect(SkillCatalog.draftPrompt(description: "d", name: "My Skill", current: nil).contains("name: my-skill"))
        #expect(SkillCatalog.draftPrompt(description: "shorter", name: nil, current: "---\nname: a\n---").contains("The user's change: shorter"))
    }

    @Test func pluginListsOfBothShapes() {
        let plain = AIExtensions.parsePlugins(#"[{"id":"a@m","version":"1","scope":"user","enabled":true,"projectEnabled":false,"installPath":"/p"}]"#)
        #expect(plain.installed.map(\.name) == ["a"])
        #expect(plain.installed.first?.enabled == false)
        let both = AIExtensions.parsePlugins(#"{"installed":[{"id":"a@m","enabled":true}],"available":[{"pluginId":"a@m","name":"a"},{"pluginId":"b@m","name":"b","description":"Bees","installCount":5},{"pluginId":"c@m","name":"c","installCount":50}]}"#)
        #expect(both.available.map(\.id) == ["b@m", "c@m"])
        #expect(AIExtensions.search(both.available, query: "").map(\.id) == ["c@m", "b@m"])
        #expect(AIExtensions.search(both.available, query: "bee").map(\.id) == ["b@m"])
    }

    @Test func notesHaveTheirParts() {
        let body = NoteBody.template(text: "Ship on Fridays?\nAsk Kim") + "- facts: Release day\n"
        let n = NoteBody(body)
        #expect(n.text == "Ship on Fridays?\nAsk Kim")
        #expect(n.filed == ["facts: Release day"])
        #expect(NoteBody.title(from: "\n# one two three four five six seven eight nine") == "one two three four five six seven eight…")
    }
}
