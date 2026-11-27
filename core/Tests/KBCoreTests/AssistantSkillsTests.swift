import Foundation
import Testing
@testable import KBCore

@Suite struct AssistantSkillsTests {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func plugin(_ root: URL) throws -> URL {
        let skills = root.appendingPathComponent("plugin/skills")
        for name in ["notes", "create-pbi", "migrate-memory"] {
            let d = skills.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: Does \(name).\nallowed-tools: Bash(kb:*)\n---\n\n# \(name)\n\nFollow the `mindmill:work-item` skill; the app sends `/mindmill:notes discuss <id>`.\n"
                .write(to: d.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try "x".write(to: skills.appendingPathComponent("notes/extra.md"), atomically: true, encoding: .utf8)
        return skills
    }

    @Test func adaptingRenamesDropsClaudesToolListAndCallsSkillsTheAssistantsWay() {
        let text = "---\nname: notes\ndescription: D.\nallowed-tools: Bash(kb:*)\n---\n\n# Notes\nUse `mindmill:work-item`, or `/mindmill:notes sort <id>`.\n"
        let codex = AssistantSkills.adapt(text, skill: "notes", provider: AIProvider.codex.id, kbCommand: "/p/bin/kb")
        #expect(codex.hasPrefix("---\nname: mindmill-notes\ndescription: D.\n---\n\n> Mindmill's command line is `kb`"))
        #expect(!codex.contains("allowed-tools"))
        #expect(codex.contains("`mindmill-work-item`"))
        #expect(codex.contains("`$mindmill-notes sort <id>`"))
        #expect(codex.contains("/p/bin/kb"))
        let gemini = AssistantSkills.adapt(text, skill: "notes", provider: AIProvider.gemini.id, kbCommand: "kb")
        #expect(gemini.contains("`mindmill-notes sort <id>`"))
    }

    @Test func skillsGoWhereAssistantsInUseReadThemAndLeaveWhenNoneDoes() throws {
        let root = tempDir()
        let skills = try plugin(root)
        let home = root.appendingPathComponent("home")
        let folder = home.appendingPathComponent(".agents/skills")
        var setup = AISetup()
        #expect(AssistantSkills.providers(setup) == [AIProvider.claudeCode.id])
        try AssistantSkills.sync(setup, skills: skills, kbCommand: "kb", home: home)
        #expect(AssistantSkills.placed(in: folder).isEmpty)

        let mine = folder.appendingPathComponent("mindmill-mine")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        setup.skillsIn = [AIProvider.codex.id]
        let c = try AssistantSkills.sync(setup, skills: skills, kbCommand: "kb", home: home)
        #expect(Set(c.written) == ["notes", "create-pbi"])
        #expect(AssistantSkills.placed(in: folder) == ["mindmill-create-pbi", "mindmill-notes"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mindmill-notes/extra.md").path))
        #expect(try AssistantSkills.sync(setup, skills: skills, kbCommand: "kb", home: home).isEmpty)

        try FileManager.default.removeItem(at: skills.appendingPathComponent("create-pbi"))
        #expect(try AssistantSkills.sync(setup, skills: skills, kbCommand: "kb", home: home).removed == ["create-pbi"])

        setup.skillsIn = nil
        try AssistantSkills.sync(setup, skills: skills, kbCommand: "kb", home: home)
        #expect(AssistantSkills.placed(in: folder).isEmpty)
        #expect(FileManager.default.fileExists(atPath: mine.path))
    }

    @Test func theUsersToolsKeepOnePerAreaExceptDocumentsAndSurviveSaving() throws {
        let root = tempDir()
        var t = UserTools()
        t.set(.mail, ["google", "m365"])
        t.set(.chat, ["figma"])
        t.adopt(["m365", "figma"])
        #expect(t.tools(for: .mail) == ["google"])
        #expect(t.tools(for: .chat) == ["m365"])
        #expect(t.tools(for: .calendar) == ["m365"])
        #expect(t.tools(for: .docs) == ["m365", "figma"])
        try t.save(root: root)
        #expect(UserTools.load(root: root) == t)
        #expect(UserTools.readTools(.mail).contains("mcp__claude_ai_Microsoft_365__outlook_email_search"))
        #expect(ClaudeLaunch.bridgeTools.contains("mcp__claude_ai_Microsoft_365__outlook_calendar_search"))
    }
}
