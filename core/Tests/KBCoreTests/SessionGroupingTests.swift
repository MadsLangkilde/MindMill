import Foundation
import Testing
@testable import KBCore

@Suite struct SessionGroupingTests {
    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: minutes * 60) }

    @Test func theImplementingSessionLeadsTheCommentsSession() {
        let plan = SessionGrouping.plan([
            .init(id: "comments", work: "wi:417904", role: .solo, created: at(1)),
            .init(id: "impl", work: "wi:417904", role: .solo, created: at(5), implements: true),
            .init(id: "other", work: "wi:418669", role: .solo, created: at(2), implements: true),
            .init(id: "free", work: nil, role: .solo, created: at(0)),
        ])
        #expect(plan.count == 1)
        #expect(plan.first?.lead == "impl")
        #expect(plan.first?.members == ["comments"])
    }

    @Test func anExistingLeadKeepsLeading() {
        let plan = SessionGrouping.plan([
            .init(id: "impl", work: "wi:1", role: .solo, created: at(0), implements: true),
            .init(id: "lead", work: "wi:1", role: .lead, created: at(9)),
            .init(id: "helper", work: "wi:1", role: .member, created: at(10)),
        ])
        #expect(plan.first?.lead == "lead")
        #expect(plan.first?.members == ["impl"])
    }

    @Test func withoutAnImplementationTheOldestLeads() {
        #expect(SessionGrouping.main(of: [
            .init(id: "b", work: "mypr:7", role: .solo, created: at(3)),
            .init(id: "a", work: "mypr:7", role: .solo, created: at(1)),
        ])?.id == "a")
        #expect(SessionGrouping.plan([.init(id: "a", work: "wi:1", role: .solo, created: at(1))]).isEmpty)
    }
}

@Suite struct ScopeSectionsTests {
    @Test func splitsByScopeInRegistryOrderKeepingSessionOrder() {
        let items: [(String, String?)] = [("a", "strings"), ("b", "android"), ("c", nil), ("d", "android"), ("e", "gone"), ("f", "")]
        let sections = ScopeSections.split(items, order: ["android", "ios", "strings"]) { $0.1 }
        #expect(sections.map(\.scope) == ["android", "strings", "gone", nil])
        #expect(sections[0].items.map(\.0) == ["b", "d"])
        #expect(sections[3].items.map(\.0) == ["c", "f"])
    }

    @Test func noSessionsNoSections() {
        #expect(ScopeSections.split([String](), order: ["android"]) { _ in "android" }.isEmpty)
    }
}

@Suite struct ReplyTailTests {
    @Test func shortRepliesStayWhole() {
        #expect(MarkdownBlocks.tail("Which one?", limit: 50) == ("Which one?", false))
    }

    @Test func longRepliesKeepTheLastWholeParagraphsAndTheChoices() {
        let reply = String(repeating: "Context. ", count: 40) + "\n\nI found two ways.\n\nWhich do you prefer?\n\n1. Fast\n2. Safe"
        let t = MarkdownBlocks.tail(reply, limit: 80)
        #expect(t.cut)
        #expect(t.text.hasPrefix("I found two ways."))
        #expect(t.text.hasSuffix("2. Safe"))
    }

    @Test func oneHugeParagraphIsKeptWhole() {
        let reply = String(repeating: "x", count: 900)
        #expect(MarkdownBlocks.tail(reply, limit: 100).text.count == 900)
    }
}
