import Foundation
import Testing
@testable import KBCore

struct FactQuizTests {
    @Test func rightMovesUpAndOutWrongGoesBackToTomorrow() {
        var s = QuizStats()
        s.record("f", correct: true, today: "2026-11-21")
        #expect(s.facts["f"] == .init(box: 1, due: "2026-11-23", right: 1, wrong: 0, last: "2026-11-21"))
        s.record("f", correct: true, today: "2026-11-23")
        #expect(s.facts["f"]?.due == "2026-11-27")
        s.record("f", correct: false, today: "2026-11-27")
        #expect(s.facts["f"]?.box == 0)
        #expect(s.facts["f"]?.due == "2026-11-28")
        #expect(!s.isDue("f", today: "2026-11-27"))
        #expect(s.isDue("f", today: "2026-11-28"))
        #expect(s.isDue("never-asked", today: "2026-11-27"))
    }

    @Test func weakDueAndRecentFactsWeighMore() {
        var s = QuizStats()
        let today = "2026-11-21"
        s.facts["known"] = .init(box: 5, due: "2026-12-20", right: 6, wrong: 0, last: "2026-11-18")
        s.facts["weak"] = .init(box: 0, due: "2026-11-21", right: 1, wrong: 3, last: "2026-11-20")
        let known = FactQuiz.weight(.init(id: "known", date: "2026-01-01"), stats: s, today: today)
        let weak = FactQuiz.weight(.init(id: "weak", date: "2026-01-01"), stats: s, today: today)
        let recentNew = FactQuiz.weight(.init(id: "new", date: "2026-11-19"), stats: s, today: today)
        let oldNew = FactQuiz.weight(.init(id: "old", date: "2025-01-01"), stats: s, today: today)
        #expect(weak > recentNew && recentNew > oldNew && oldNew > known)
        #expect(s.weakSpots == ["weak"])
    }

    @Test func pickingIsRepeatableAndFavoursWeakFacts() {
        var s = QuizStats()
        let today = "2026-11-21"
        var candidates: [FactQuiz.Candidate] = []
        for i in 0..<40 {
            candidates.append(.init(id: "k\(i)", date: "2025-01-01"))
            s.facts["k\(i)"] = .init(box: 5, due: "2027-01-01", right: 5, wrong: 0, last: today)
        }
        candidates.append(.init(id: "weak", date: "2025-01-01"))
        s.facts["weak"] = .init(box: 0, due: today, right: 0, wrong: 4, last: today)
        let a = FactQuiz.pick(candidates, stats: s, today: today, count: 5, seed: 42)
        #expect(a == FactQuiz.pick(candidates, stats: s, today: today, count: 5, seed: 42))
        #expect(a.count == 5 && Set(a).count == 5)
        var hits = 0
        for seed in 0..<50 where FactQuiz.pick(candidates, stats: s, today: today, count: 5, seed: UInt64(seed)).contains("weak") { hits += 1 }
        #expect(hits > 40)
    }

    @Test func parsesQuestionsForTheAskedFactsOnly() {
        let reply = #"[{"fact": "a/facts/bff", "question": "What validates the token the BFF issues?", "answer": "The device"}, {"fact": "a/facts/other", "question": "Q", "answer": "A"}, {"fact": "a/facts/bff", "question": " ", "answer": "x"}]"#
        let q = QuizQuestion.parse(reply, facts: ["a/facts/bff"])
        #expect(q.map(\.answer) == ["The device"])
    }
}
