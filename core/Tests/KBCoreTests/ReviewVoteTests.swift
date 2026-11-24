import Foundation
import Testing
@testable import KBCore

@Suite struct ReviewVoteTests {
    @Test func votesMatchTheCommandAndReviewsAlwaysAsk() {
        #expect(ReviewVote.allCases.map(\.rawValue) == ["approve", "approve-with-suggestions", "wait-for-author", "reject", "reset"])
        let ask = ReviewVote.askAtTheEnd(42)
        #expect(ask.contains("always end by asking which vote to cast"))
        #expect(ask.contains("kb pr vote 42 --vote"))
        #expect(ask.contains("only after I pick one"))
    }
}
