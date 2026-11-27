import Foundation

/// Prompts the user has sent, oldest first, for ↑ and ↓ in a prompt field the way a shell does.
public struct PromptHistory: Equatable, Sendable {
    public static let limit = 200
    public private(set) var entries: [String]

    public init(entries: [String] = []) {
        self.entries = Array(entries.suffix(Self.limit))
    }

    /// A session's messages in the order they were sent, so ↑ steps back through exactly that conversation
    /// (a message sent twice in a row counts once).
    public init(sessionMessages: [String]) {
        var out: [String] = []
        for m in sessionMessages {
            let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, out.last != t { out.append(t) }
        }
        self.init(entries: out)
    }

    /// Sending a prompt again moves it to the newest place instead of keeping two.
    public mutating func record(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        entries.removeAll { $0 == t }
        entries.append(t)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}

/// Where one prompt field is in the history while ↑ and ↓ walk it; what was typed before is kept and comes back
/// after the newest entry.
public struct PromptRecall: Equatable, Sendable {
    private var position: Int?
    private var draft = ""

    public init() {}

    public var isBrowsing: Bool { position != nil }

    /// ↑ goes back when the field is empty, the caret is at the very start, or it still shows a recalled prompt.
    public func takesUp(text: String, caret: Int, in history: PromptHistory) -> Bool {
        guard !history.entries.isEmpty else { return false }
        return text.isEmpty || caret == 0 || shown(in: history) == text
    }

    /// ↓ goes forward while walking the history, when the caret is at the end or the recalled prompt is unchanged.
    public func takesDown(text: String, caret: Int, in history: PromptHistory) -> Bool {
        guard isBrowsing else { return false }
        return caret >= (text as NSString).length || shown(in: history) == text
    }

    /// The older prompt to show, or nil at the oldest (the field stays as it is).
    public mutating func older(current: String, in history: PromptHistory) -> String? {
        guard !history.entries.isEmpty else { return nil }
        guard let p = position, p < history.entries.count else {
            draft = current
            position = history.entries.count - 1
            return history.entries.last
        }
        guard p > 0 else { return nil }
        position = p - 1
        return history.entries[p - 1]
    }

    /// The newer prompt to show; past the newest, what was typed before walking started.
    public mutating func newer(in history: PromptHistory) -> String? {
        guard let p = position else { return nil }
        if p + 1 < history.entries.count {
            position = p + 1
            return history.entries[p + 1]
        }
        position = nil
        defer { draft = "" }
        return draft
    }

    /// After sending: the next ↑ starts from the newest again.
    public mutating func reset() {
        position = nil
        draft = ""
    }

    private func shown(in history: PromptHistory) -> String? {
        guard let p = position, history.entries.indices.contains(p) else { return nil }
        return history.entries[p]
    }
}
