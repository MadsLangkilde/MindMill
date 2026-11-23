import Testing
@testable import KBCore

@Suite struct ClaudeConnectorsTests {
    let output = """
    Checking MCP server health…

    claude.ai Microsoft 365: https://microsoft365.mcp.claude.com/mcp - ✔ Connected
    claude.ai Miro: https://mcp.miro.com - ! Needs authentication
    plugin:postman:postman: https://mcp.postman.com/mcp (HTTP) - ! Needs authentication
    figma: https://mcp.figma.com/mcp (HTTP) - ✔ Connected
    local: node /x/server.js - ✗ Failed to connect
    """

    @Test func linesBecomeServersWithStatus() {
        let s = ClaudeConnectors.parse(output)
        #expect(s.map(\.name) == ["claude.ai Microsoft 365", "claude.ai Miro", "plugin:postman:postman", "figma", "local"])
        #expect(s.map(\.status) == [.connected, .needsAuth, .needsAuth, .connected, .failed])
        #expect(s[3].target == "https://mcp.figma.com/mcp")
        #expect(s[0].fromClaudeAI && s[0].displayName == "Microsoft 365")
        #expect(s[2].fromPlugin && s[2].displayName == "postman")
    }

    @Test func servicesFindTheirServers() {
        let s = ClaudeConnectors.parse(output)
        let m365 = ClaudeConnectors.catalog.first { $0.id == "m365" }!
        #expect(ClaudeConnectors.servers(for: m365, in: s).map(\.name) == ["claude.ai Microsoft 365"])
        #expect(ClaudeConnectors.others(s).map(\.name) == ["claude.ai Miro", "plugin:postman:postman", "local"])
        #expect(ClaudeConnectors.safeName("My Jira (work)") == "my-jira-work")
    }
}
