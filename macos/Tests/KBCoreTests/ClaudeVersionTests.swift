import Testing
@testable import KBCore

struct ClaudeVersionTests {
    @Test func parses() {
        #expect(ClaudeVersion.parse("2.1.329 (Claude Code)\n") == [2, 1, 329])
        #expect(ClaudeVersion.parse("2.0.9 (Claude Code)") == [2, 0, 9])
        #expect(ClaudeVersion.parse("error: nope") == nil)
    }

    @Test func picksTheNewest() {
        #expect(ClaudeVersion.newest(["old", "new"], versions: [[2, 0, 9], [2, 1, 329]]) == "new")
        #expect(ClaudeVersion.newest(["new", "old"], versions: [[2, 1, 329], [2, 0, 9]]) == "new")
        #expect(ClaudeVersion.newest(["a", "b"], versions: [[2, 1], [2, 1]]) == "a")
        #expect(ClaudeVersion.newest(["broken", "ok"], versions: [nil, [1, 0]]) == "ok")
        #expect(ClaudeVersion.newest(["x"], versions: [nil]) == nil)
        #expect(ClaudeVersion.newest(["short", "long"], versions: [[2, 1], [2, 1, 1]]) == "long")
    }
}
