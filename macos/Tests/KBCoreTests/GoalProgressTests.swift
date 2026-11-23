import Foundation
import Testing
@testable import KBCore

@Suite struct GoalProgressTests {
    private let body = """

    ## Why
    Lead.

    ## Suggestions
    - [ ] Write the retry note: technical direction (refinement)

    ## Proposed progress
    - 2026-11-12: Led the pairing bug review (!319228)
    - 2026-11-10: Presented upload options

    ## Progress
    - 2026-11-11: Mentored Erik on Compose
    - 2026-11-01: Wrote the BLE decision
    """

    @Test func readsAndEditsProgressNewestFirst() {
        var log = ProgressLog(markdown: GoalBody.section("Progress", in: body) ?? "")
        #expect(log.items.map(\.date) == ["2026-11-11", "2026-11-01"])
        #expect(log.items.first?.text == "Mentored Erik on Compose")
        log.add(date: "2026-11-05", text: "Gave a talk")
        #expect(log.items.map(\.date) == ["2026-11-11", "2026-11-05", "2026-11-01"])
        log.set(log.items[2].id, date: "2026-11-13", text: "Wrote the BLE decision note")
        #expect(log.items.map(\.text) == ["Wrote the BLE decision note", "Mentored Erik on Compose", "Gave a talk"])
        log.remove(log.items[1].id)
        #expect(log.markdown == "- 2026-11-13: Wrote the BLE decision note\n- 2026-11-05: Gave a talk")
    }

    @Test func acceptingAProposalMovesItWithTheEditedText() {
        let proposed = ProgressLog(markdown: GoalBody.section("Proposed progress", in: body) ?? "")
        var b = GoalBody.accepting(proposed.items[0].id, date: "2026-11-12", text: "Led the pairing bug review", in: body)
        #expect(GoalBody.section("Progress", in: b)?.hasPrefix("- 2026-11-12: Led the pairing bug review\n- 2026-11-11") == true)
        #expect(GoalBody.section("Proposed progress", in: b) == "- 2026-11-10: Presented upload options")
        let last = ProgressLog(markdown: GoalBody.section("Proposed progress", in: b) ?? "")
        b = GoalBody.accepting(last.items[0].id, date: "2026-11-10", text: "Presented upload options", in: b)
        #expect(GoalBody.section("Proposed progress", in: b) == nil)
        #expect(GoalBody.section("Suggestions", in: b)?.contains("retry note") == true)
    }

    @Test func addingProgressKeepsUndatedLines() {
        let b = GoalBody.addingProgress("New", date: "2026-11-13", to: "## Progress\nSome intro\n")
        #expect(GoalBody.section("Progress", in: b) == "Some intro\n- 2026-11-13: New")
    }
}
