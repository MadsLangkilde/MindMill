import Foundation
import Testing
@testable import KBCore

struct RetryOfferTests {
    @Test func offersTheFailedLastMessage() {
        var offer = RetryOffer()
        let error = UUID()
        offer.failed(item: error, turn: "a", waiting: "a")
        #expect(offer.errorItem == error)
    }

    @Test func ignoresOtherTurnsFailing() {
        var offer = RetryOffer()
        offer.failed(item: UUID(), turn: "warmup", waiting: "a")
        #expect(offer.errorItem == nil)
        offer.failed(item: UUID(), turn: "a", waiting: nil)
        #expect(offer.errorItem == nil)
    }

    @Test func aProcessFailureOffersWhatWasWaiting() {
        var offer = RetryOffer()
        let error = UUID()
        offer.failed(item: error, turn: nil, waiting: "a")
        #expect(offer.errorItem == error)
        offer.clear()
        offer.failed(item: UUID(), turn: nil, waiting: nil)
        #expect(offer.errorItem == nil)
    }

    @Test func aLaterFailureMovesTheOfferAndSendingClearsIt() {
        var offer = RetryOffer()
        offer.failed(item: UUID(), turn: "a", waiting: "a")
        let second = UUID()
        offer.failed(item: second, turn: "b", waiting: "b")
        #expect(offer.errorItem == second)
        offer.clear()
        #expect(offer.errorItem == nil)
    }
}
