import Foundation

/// Finds open factory questions that something the user already answered or decided settles, so they aren't
/// asked twice.
public enum FactoryCoverage {
    /// Something the user answered or decided.
    public struct Known: Equatable, Sendable {
        public var id: String
        public var text: String
        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    public struct Open: Equatable, Sendable {
        public var id: UUID
        public var text: String
        public var workItem: Int?
        public init(id: UUID, text: String, workItem: Int?) {
            self.id = id
            self.text = text
            self.workItem = workItem
        }
    }

    public struct Verdict: Codable, Equatable, Sendable {
        public var id: String
        public var answer: String
        public var because: String
    }

    public static let system = "You compare questions with what a user already answered or decided, and reply with JSON only."

    public static func prompt(known: [Known], open: [Open]) -> String {
        let k = known.map { "- [\($0.id)] \($0.text)" }.joined(separator: "\n")
        let o = open.map { q in "- [\(q.id.uuidString)]" + (q.workItem.map { " (work item #\($0))" } ?? "") + " \(q.text)" }.joined(separator: "\n")
        return """
        Coding sessions asked the user these questions, which are still open:
        \(o)

        This is what the user has answered or decided:
        \(k)

        Which open questions does that already settle? Be strict: only when it fully answers the question, so asking \
        the user would only get "we already decided that". A question that is merely on the same topic is not settled.
        Reply with only a JSON array, [] when none:
        [{"id": "<the open question's id>", "answer": "<the answer for the session, in the user's terms>", \
        "because": "<what settles it, in a few words, e.g. your answer about token refresh on #415772>"}]
        """
    }

    /// The verdicts in a reply, for questions that were asked about; anything else is ignored.
    public static func parse(_ reply: String, open: [Open]) -> [Verdict] {
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"), start < end,
              let list = try? JSONDecoder().decode([Verdict].self, from: Data(reply[start...end].utf8)) else { return [] }
        let ids = Set(open.map { $0.id.uuidString.lowercased() })
        var seen = Set<String>()
        return list.filter { v in
            let id = v.id.lowercased()
            return ids.contains(id) && !v.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert(id).inserted
        }
    }

    /// The message to the session whose question was settled elsewhere.
    public static func message(question: String, answer: String, because: String) -> String {
        "Your question “\(question)” is already settled by something the user answered or decided (\(because)): \(answer)\n\nTreat this as the user's answer and carry on. If it doesn't fully settle your question, ask again with only what is still open."
    }
}
