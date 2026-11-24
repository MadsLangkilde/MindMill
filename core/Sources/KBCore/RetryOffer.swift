import Foundation

/// A transcript's offer to send the last message again after its turn failed (an API error, Claude crashing).
/// The Retry button shows under that error line, and goes once anything is sent.
public struct RetryOffer: Equatable, Sendable {
    /// The error line that shows the Retry button.
    public private(set) var errorItem: UUID?

    public init() {}

    /// A turn failed and its error is shown as `item`. `turn` is the failed turn's tag, nil when the process
    /// failed and took every waiting turn with it; `waiting` is the tag of the last shown message still unanswered.
    /// Only the failure of that message is offered: a hidden turn or an earlier message failing leaves things as they are.
    public mutating func failed(item: UUID, turn: String?, waiting: String?) {
        guard let waiting, turn == nil || turn == waiting else { return }
        errorItem = item
    }

    public mutating func clear() {
        errorItem = nil
    }
}
