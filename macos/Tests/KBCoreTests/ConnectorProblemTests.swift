import Foundation
import Testing
@testable import KBCore

@Suite struct ConnectorProblemTests {
    @Test func signedOutClaudeAIConnectorIsAProblemWithItsFix() {
        let servers = ClaudeConnectors.parse("""
        claude.ai Microsoft Learn: https://learn.microsoft.com/api/mcp - ✔ Connected
        claude.ai Microsoft 365: https://microsoft365.mcp.claude.com/mcp - ! Needs authentication
        claude.ai Slack: https://mcp.slack.com/mcp - ✔ Connected
        """)
        let problems = ClaudeConnectors.problems(servers)
        #expect(problems.map(\.service.id) == ["m365"])
        #expect(problems.first?.headline == "Microsoft 365 needs signing in")
        #expect(problems.first?.advice.contains("password change") == true)
        #expect(problems.first?.advice.contains("claude.ai → Settings → Connectors") == true)
    }

    @Test func oneWorkingServerIsEnoughAndUnusedToolsArentProblems() {
        let servers = [ClaudeConnectors.Server(name: "jira-old", target: "x", status: .failed),
                       ClaudeConnectors.Server(name: "claude.ai Atlassian", target: "y", status: .connected)]
        #expect(ClaudeConnectors.problems(servers).isEmpty)
        #expect(ClaudeConnectors.problems([]).isEmpty)
        let local = ClaudeConnectors.problems([.init(name: "slack", target: "npx slack", status: .failed)])
        #expect(local.first?.headline == "Slack isn't working")
        #expect(local.first?.advice.contains("/mcp") == true)
    }
}
