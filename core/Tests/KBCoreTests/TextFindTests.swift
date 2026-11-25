import Foundation
import Testing
@testable import KBCore

struct TextFindTests {
    @Test func findsEveryPlaceIgnoringCaseAndAccents() {
        let text = "Café notes: the CAFE opens at 8. cafe again"
        let found = TextFind.ranges(of: " cafe ", in: text).map { String(text[$0]) }
        #expect(found == ["Café", "CAFE", "cafe"])
        #expect(TextFind.contains(text, "OPENS"))
        #expect(!TextFind.contains(text, "closes"))
    }

    @Test func emptySearchFindsNothing() {
        #expect(TextFind.ranges(of: "   ", in: "anything").isEmpty)
        #expect(!TextFind.contains("anything", ""))
        #expect(TextFind.position(current: 0, count: 0, query: " ") == "")
    }

    @Test func matchesDoNotOverlap() {
        #expect(TextFind.ranges(of: "aa", in: "aaaa").count == 2)
    }

    @Test func positionReadsLikeOtherApps() {
        #expect(TextFind.position(current: 2, count: 12, query: "x") == "3 of 12")
        #expect(TextFind.position(current: 9, count: 3, query: "x") == "3 of 3")
        #expect(TextFind.position(current: 0, count: 0, query: "x") == "No matches")
    }
}
