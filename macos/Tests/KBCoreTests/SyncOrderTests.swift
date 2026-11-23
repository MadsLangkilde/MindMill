import Foundation
import Testing
@testable import KBCore

@Suite struct SyncOrderTests {
    @Test func syncOrderParsesWithItsRange() {
        let json = #"{"kind": "sync", "id": "ab12cd", "what": ["calendar", "bogus", "prs"], "range_from": "2026-11-23", "range_to": "2026-11-29", "from": "s1"}"#
        guard case .sync(let req)? = CrewOrder.parse(Data(json.utf8)) else { Issue.record("not a sync order"); return }
        #expect(req.id == "ab12cd" && req.what == ["calendar", "prs"] && req.from == "s1")
        #expect(req.range?.from == "2026-11-23" && req.range?.to == "2026-11-29")
        // The id names a file, so nothing but letters and digits.
        #expect(CrewOrder.parse(Data(#"{"kind": "sync", "id": "../x", "what": ["prs"]}"#.utf8)) == nil)
        #expect(CrewOrder.parse(Data(#"{"kind": "sync", "id": "a1", "what": []}"#.utf8)) == nil)
    }

    @Test func refusedConnectorReadsAsNeedingSignIn() {
        #expect(ConnectorSignIn.isNeeded("ERROR No such tool available: mcp__claude_ai_Microsoft_365__outlook_calendar_search. Claude Code connected to MCP server \"claude.ai Microsoft 365\" again with its existing sign-in and was refused. The user needs to sign in."))
        #expect(ConnectorSignIn.isNeeded("ERROR needs sign-in. Run `/mcp` and authenticate claude.ai Microsoft 365."))
        #expect(!ConnectorSignIn.isNeeded("ERROR the importer failed: bad date"))
    }
}
