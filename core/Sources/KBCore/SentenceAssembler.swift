import Foundation

/// Joins the pieces a speech recogniser reports into sentence-sized lines. The recogniser ends a piece at every
/// short pause, which reads as "You have no way of" / "Yeah" / "This"; a line ends instead when the sentence is
/// complete and the speaker pauses, when they stop for a while, when it grows long, or when the language changes.
public struct SentenceAssembler: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public let text: String
        public let language: String
        public let started: Date
    }

    public static let sentencePause: TimeInterval = 0.8
    public static let silence: TimeInterval = 3.5
    public static let maxWords = 60

    public private(set) var text = ""
    private var language = ""
    private var started = Date.distantPast
    private var lastAdded = Date.distantPast

    public init() {}

    public var isEmpty: Bool { text.isEmpty }

    /// Adds a piece. Returns a finished line when the piece starts a new one: a change of language, or a line
    /// already at its length.
    public mutating func add(_ piece: String, language: String, at time: Date) -> Line? {
        let piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return nil }
        var done: Line?
        if !text.isEmpty, language != self.language || wordCount >= Self.maxWords {
            done = flush()
        }
        if text.isEmpty {
            text = piece
            self.language = language
            started = time
        } else {
            text += " " + Self.continuing(piece)
        }
        lastAdded = time
        return done
    }

    /// The line, when it is finished at `time`.
    public mutating func due(at time: Date) -> Line? {
        guard !text.isEmpty else { return nil }
        let quiet = time.timeIntervalSince(lastAdded)
        if quiet >= Self.silence || wordCount >= Self.maxWords || (endsSentence && quiet >= Self.sentencePause) {
            return flush()
        }
        return nil
    }

    public mutating func flush() -> Line? {
        guard !text.isEmpty else { return nil }
        let line = Line(text: text, language: language, started: started)
        text = ""
        return line
    }

    private var wordCount: Int { text.split(separator: " ").count }

    private var endsSentence: Bool {
        guard let last = text.last else { return false }
        return ".?!".contains(last)
    }

    /// A piece that continues a sentence loses the capital the recogniser gives every piece: "Clarify a little"
    /// after "I mean, good we need" reads "clarify a little". "I" and words in capitals keep theirs.
    static func continuing(_ piece: String) -> String {
        if let last = piece.split(separator: " ").first, last == "I" || last.hasPrefix("I'") { return piece }
        guard let first = piece.first, first.isUppercase else { return piece }
        let word = piece.prefix { !$0.isWhitespace && !$0.isPunctuation }
        if word.count > 1, word.allSatisfy({ $0.isUppercase || $0.isNumber }) { return piece }
        return first.lowercased() + piece.dropFirst()
    }
}
