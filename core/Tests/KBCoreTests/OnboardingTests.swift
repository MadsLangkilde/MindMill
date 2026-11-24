import Foundation
import Testing
@testable import KBCore

@Suite struct OnboardingTests {
    @Test func setupShowsUntilTheAssistantIsInstalledAndOnAFirstLaunch() {
        #expect(OnboardingGate.needed(completed: true, aiFound: false, hasKnowledgeBase: true, forced: false))
        #expect(OnboardingGate.needed(completed: false, aiFound: true, hasKnowledgeBase: false, forced: false))
        #expect(OnboardingGate.needed(completed: true, aiFound: true, hasKnowledgeBase: true, forced: true))
        // An existing user with a knowledge base isn't sent through it, and looking for Claude alone never shows it.
        #expect(!OnboardingGate.needed(completed: false, aiFound: true, hasKnowledgeBase: true, forced: false))
        #expect(!OnboardingGate.needed(completed: true, aiFound: nil, hasKnowledgeBase: true, forced: false))
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
    }
}
