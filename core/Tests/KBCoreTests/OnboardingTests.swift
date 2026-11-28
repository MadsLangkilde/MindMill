import Foundation
import Testing
@testable import KBCore

@Suite struct OnboardingTests {
    @Test func setupShowsUntilTheAssistantIsInstalledAndWheneverThereIsNoKnowledgeBase() {
        #expect(OnboardingGate.needed(aiFound: false, hasKnowledgeBase: true, forced: false))
        #expect(OnboardingGate.needed(aiFound: true, hasKnowledgeBase: false, forced: false))
        #expect(OnboardingGate.needed(aiFound: true, hasKnowledgeBase: true, forced: true))
        // A user with a knowledge base isn't sent through it, and looking for Claude alone never shows it.
        #expect(!OnboardingGate.needed(aiFound: true, hasKnowledgeBase: true, forced: false))
        #expect(!OnboardingGate.needed(aiFound: nil, hasKnowledgeBase: true, forced: false))
    }

    @Test func knowledgeBaseStepWaitsForAProject() {
        #expect(!OnboardingGate.knowledgeBaseReady(hasKnowledgeBase: false, projects: 0))
        #expect(!OnboardingGate.knowledgeBaseReady(hasKnowledgeBase: true, projects: 0))
        #expect(OnboardingGate.knowledgeBaseReady(hasKnowledgeBase: true, projects: 1))
    }

    @Test func knowledgeBaseFolderMustBeNewEmptyOrAKnowledgeBase() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("kbfolder-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        #expect(KnowledgeBaseFolder.check(base.appendingPathComponent("missing")) == .new)

        let empty = base.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent(".DS_Store"))
        #expect(KnowledgeBaseFolder.check(empty) == .empty)

        let repo = base.appendingPathComponent("repo")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent("package.json"))
        #expect(KnowledgeBaseFolder.check(repo) == .inUse("a Git repository"))
        #expect(!KnowledgeBaseFolder.check(repo).usable)
        #expect(KnowledgeBaseFolder.check(repo).message.contains(KnowledgeBaseFolder.suggestedPath))

        let code = base.appendingPathComponent("code")
        try fm.createDirectory(at: code.appendingPathComponent("src"), withIntermediateDirectories: true)
        #expect(KnowledgeBaseFolder.check(code) == .inUse("a code project"))

        let notes = base.appendingPathComponent("notes")
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: notes.appendingPathComponent("todo.txt"))
        #expect(KnowledgeBaseFolder.check(notes) == .inUse("a folder with other files in it"))

        let kb = base.appendingPathComponent("kb")
        try Registry.createKnowledgeBase(root: kb)
        #expect(KnowledgeBaseFolder.check(kb) == .knowledgeBase)
        #expect(KnowledgeBaseFolder.check(kb).usable)
    }

    @Test func opensOnTheFirstStepThatIsntReady() {
        #expect(OnboardingGate.firstStep(assistantReady: false, hasKnowledgeBase: true) == .assistant)
        #expect(OnboardingGate.firstStep(assistantReady: true, hasKnowledgeBase: false) == .knowledgeBase)
        #expect(OnboardingGate.firstStep(assistantReady: true, hasKnowledgeBase: true) == .tools)
    }

    @Test func briefCoversTheTrackerAndOnlyThePickedTools() {
        let connected = [ClaudeConnectors.Server(name: "claude.ai Atlassian", target: "https://mcp.atlassian.com", status: .connected)]
        let scopes = [SourceSetup.Scope(id: "app", title: "App", tracker: "")]
        let jira = SourceSetup.brief(tracker: "jira", tools: ["slack"], scopes: scopes, connected: connected)
        #expect(jira.contains("## Work tracking: Jira"))
        #expect(jira.contains("\"kind\": \"jira\""))
        #expect(jira.contains("Atlassian (connected)"))
        #expect(jira.contains("- App (`app`): no tracker"))
        #expect(jira.contains("- Slack: not connected"))
        #expect(!jira.contains("Microsoft 365"))

        let ado = SourceSetup.brief(tracker: "azure-devops", tools: [], scopes: [], connected: [])
        #expect(ado.contains("Never ask me to paste a token"))
        #expect(ado.contains("Nothing yet."))
        #expect(!ado.contains("## Other tools"))

        let none = SourceSetup.brief(tracker: nil, tools: ["m365"], scopes: [], connected: [])
        #expect(!none.contains("## Work tracking"))
        #expect(none.contains("Microsoft 365: not connected"))
        #expect(!none.contains("## Calendar"))
    }

    @Test func briefWalksThroughThePickedCalendar() {
        let missing = SourceSetup.brief(tracker: nil, tools: [], calendar: .google, scopes: [], connected: [])
        #expect(missing.contains("## Calendar: Google Calendar"))
        #expect(missing.contains("isn't connected"))
        #expect(missing.contains("`kb sync calendar`"))

        let outlook = [ClaudeConnectors.Server(name: "claude.ai Microsoft 365", target: "https://x", status: .connected)]
        let connected = SourceSetup.brief(tracker: nil, tools: [], calendar: .microsoft365, scopes: [], connected: outlook)
        #expect(connected.contains("## Calendar: Outlook"))
        #expect(connected.contains("It is connected"))
    }
}
