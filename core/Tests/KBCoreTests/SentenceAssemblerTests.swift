import Foundation
import Testing
@testable import KBCore

struct SentenceAssemblerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func joinsPiecesUntilTheSpeakerStops() {
        var a = SentenceAssembler()
        #expect(a.add("I mean, good we need", language: "en", at: t0) == nil)
        #expect(a.add("Clarify a little bit on how", language: "en", at: t0 + 1) == nil)
        #expect(a.due(at: t0 + 2) == nil)
        let line = a.due(at: t0 + 1 + SentenceAssembler.silence)
        #expect(line?.text == "I mean, good we need clarify a little bit on how")
        #expect(line?.started == t0)
        #expect(a.isEmpty)
    }

    @Test func endsAFinishedSentenceAtAShortPause() {
        var a = SentenceAssembler()
        _ = a.add("We are gonna pilot it.", language: "en", at: t0)
        #expect(a.due(at: t0 + 0.3) == nil)
        #expect(a.due(at: t0 + 1)?.text == "We are gonna pilot it.")
    }

    @Test func aChangeOfLanguageStartsANewLine() {
        var a = SentenceAssembler()
        _ = a.add("Det er fint", language: "da", at: t0)
        let done = a.add("Sounds good", language: "en", at: t0 + 1)
        #expect(done == SentenceAssembler.Line(text: "Det er fint", language: "da", started: t0))
        #expect(a.text == "Sounds good")
    }

    @Test func keepsCapitalsThatMatter() {
        #expect(SentenceAssembler.continuing("I think so") == "I think so")
        #expect(SentenceAssembler.continuing("I'm fine") == "I'm fine")
        #expect(SentenceAssembler.continuing("PBI first") == "PBI first")
        #expect(SentenceAssembler.continuing("Skill") == "skill")
    }

    @Test func longLinesAreCut() {
        var a = SentenceAssembler()
        let words = Array(repeating: "word", count: SentenceAssembler.maxWords).joined(separator: " ")
        _ = a.add(words, language: "en", at: t0)
        #expect(a.due(at: t0)?.text == words)
    }
}
