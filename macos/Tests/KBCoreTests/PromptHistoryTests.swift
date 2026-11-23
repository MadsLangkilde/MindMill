import Foundation
import Testing
@testable import KBCore

struct PromptHistoryTests {
    @Test func recordingTrimsSkipsEmptyAndMovesRepeatsToNewest() {
        var h = PromptHistory()
        h.record("  first \n")
        h.record("")
        h.record("second")
        h.record("first")
        #expect(h.entries == ["second", "first"])
    }

    @Test func keepsTheNewestUpToTheLimit() {
        var h = PromptHistory()
        for i in 0..<(PromptHistory.limit + 5) { h.record("p\(i)") }
        #expect(h.entries.count == PromptHistory.limit)
        #expect(h.entries.first == "p5")
    }

    @Test func walksBackAndForwardAndRestoresTheDraft() {
        let h = PromptHistory(entries: ["a", "b", "c"])
        var r = PromptRecall()
        #expect(r.older(current: "draft", in: h) == "c")
        #expect(r.older(current: "c", in: h) == "b")
        #expect(r.older(current: "b", in: h) == "a")
        #expect(r.older(current: "a", in: h) == nil)
        #expect(r.newer(in: h) == "b")
        #expect(r.newer(in: h) == "c")
        #expect(r.newer(in: h) == "draft")
        #expect(!r.isBrowsing)
        #expect(r.newer(in: h) == nil)
    }

    @Test func upNeedsAnEmptyFieldTheStartOrARecalledPrompt() {
        let h = PromptHistory(entries: ["a", "b"])
        var r = PromptRecall()
        #expect(r.takesUp(text: "", caret: 0, in: h))
        #expect(r.takesUp(text: "typed", caret: 0, in: h))
        #expect(!r.takesUp(text: "typed", caret: 3, in: h))
        _ = r.older(current: "", in: h)
        #expect(r.takesUp(text: "b", caret: 1, in: h))
        #expect(!r.takesUp(text: "b edited", caret: 3, in: h))
        #expect(!PromptRecall().takesUp(text: "", caret: 0, in: PromptHistory()))
    }

    @Test func downOnlyWhileWalkingAtTheEndOrUnchanged() {
        let h = PromptHistory(entries: ["a", "b"])
        var r = PromptRecall()
        #expect(!r.takesDown(text: "", caret: 0, in: h))
        _ = r.older(current: "", in: h)
        #expect(r.takesDown(text: "b", caret: 0, in: h))
        #expect(r.takesDown(text: "b edited", caret: 8, in: h))
        #expect(!r.takesDown(text: "b edited", caret: 2, in: h))
        r.reset()
        #expect(!r.takesDown(text: "b", caret: 1, in: h))
    }
}
