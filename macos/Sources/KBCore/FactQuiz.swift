import Foundation

/// How the user has done on each fact in the quiz, in `quiz.json` in the knowledge base's home folder. Spaced repetition in boxes:
/// a right answer moves a fact up a box and further out, a wrong one back to the first box, due again the next day.
public struct QuizStats: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var box: Int
        public var due: String
        public var right: Int
        public var wrong: Int
        public var last: String

        public init(box: Int = 0, due: String = "", right: Int = 0, wrong: Int = 0, last: String = "") {
            self.box = box
            self.due = due
            self.right = right
            self.wrong = wrong
            self.last = last
        }
    }

    /// Days until a fact in each box comes up again.
    public static let intervals = [1, 2, 4, 8, 16, 32]

    public var version = 1
    public var facts: [String: Record] = [:]

    public init() {}

    public static func url(root: URL) -> URL { KBLayout.home(root: root).appendingPathComponent("quiz.json") }

    public static func load(root: URL) -> QuizStats {
        guard let data = try? Data(contentsOf: url(root: root)) else { return QuizStats() }
        return (try? JSONDecoder().decode(QuizStats.self, from: data)) ?? QuizStats()
    }

    public func save(root: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let target = Self.url(root: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: target, options: .atomic)
    }

    public mutating func record(_ id: String, correct: Bool, today: String) {
        var r = facts[id] ?? Record()
        if correct {
            r.right += 1
            r.box = min(r.box + 1, Self.intervals.count - 1)
        } else {
            r.wrong += 1
            r.box = 0
        }
        r.last = today
        r.due = Self.add(days: correct ? Self.intervals[r.box] : 1, to: today)
        facts[id] = r
    }

    public func isDue(_ id: String, today: String) -> Bool {
        guard let r = facts[id] else { return true }
        return r.due.isEmpty || r.due <= today
    }

    /// Facts answered wrong more often than right.
    public var weakSpots: [String] { facts.filter { $0.value.wrong > $0.value.right }.map(\.key).sorted() }

    static func add(days: Int, to iso: String) -> String {
        guard let d = KBDate.parse(iso), let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: d) else { return iso }
        return KBDate.today(next)
    }
}

public enum FactQuiz {
    public struct Candidate: Equatable, Sendable {
        public var id: String
        /// When the fact was added or last verified.
        public var date: String
        public init(id: String, date: String) {
            self.id = id
            self.date = date
        }
    }

    /// How much a fact wants to be asked now: due and weak ones most, new and recently added ones next, facts known
    /// well and not due hardly at all.
    public static func weight(_ c: Candidate, stats: QuizStats, today: String) -> Double {
        let recent = KBDate.isISODate(c.date) && c.date >= QuizStats.add(days: -14, to: today)
        guard let r = stats.facts[c.id] else { return recent ? 6 : 3 }
        let due = stats.isDue(c.id, today: today)
        let wrongRatio = Double(r.wrong) / Double(max(r.right + r.wrong, 1))
        var w = due ? 4 : 0.15
        w += wrongRatio * 5
        if recent { w += 2 }
        return w
    }

    /// Up to `count` facts for one round, drawn by weight; `seed` makes a round repeatable.
    public static func pick(_ candidates: [Candidate], stats: QuizStats, today: String, count: Int, seed: UInt64) -> [String] {
        var rng = SplitMix64(seed: seed)
        // Weighted sampling without replacement: each fact gets a key u^(1/w); the largest keys win.
        let keyed = candidates.map { c -> (String, Double) in
            let w = max(weight(c, stats: stats, today: today), 0.0001)
            let u = max(Double(rng.next() >> 11) / Double(1 << 53), 1e-12)
            return (c.id, pow(u, 1 / w))
        }
        return keyed.sorted { $0.1 > $1.1 }.prefix(count).map(\.0)
    }
}

/// A question Claude wrote about a fact, with the answer to check against.
public struct QuizQuestion: Codable, Equatable, Sendable, Identifiable {
    public var fact: String
    public var question: String
    public var answer: String

    public var id: String { fact + "|" + question }

    public init(fact: String, question: String, answer: String) {
        self.fact = fact
        self.question = question
        self.answer = answer
    }

    /// The JSON array in Claude's reply; questions about other facts, or empty ones, are dropped.
    public static func parse(_ reply: String, facts: Set<String>) -> [QuizQuestion] {
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"), start < end,
              let list = try? JSONDecoder().decode([QuizQuestion].self, from: Data(reply[start...end].utf8)) else { return [] }
        return list.filter {
            facts.contains($0.fact) && !$0.question.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.answer.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
