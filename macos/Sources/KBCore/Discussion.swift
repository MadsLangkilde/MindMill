import Foundation

public enum DiscussionStatus: String, CaseIterable, Sendable {
    case open, parked, concluded

    public var title: String { rawValue.capitalized }
}

/// Who the discussion waits on now.
public enum WaitingOn: String, CaseIterable, Sendable {
    case me, others, nobody

    public var title: String {
        switch self {
        case .me: return "Waiting on you"
        case .others: return "Waiting on others"
        case .nobody: return "Not waiting"
        }
    }
}

extension KBEntry {
    public var discussionStatus: DiscussionStatus { DiscussionStatus(rawValue: rawStatus) ?? .open }
    public var waitingOn: String { field("waiting_on") ?? "nobody" }
    /// The last activity: `updated`, else the day it started.
    public var discussionUpdated: String { field("updated") ?? date }
    public var channel: String? { field("channel") }
}

/// The parts of a discussion file the app shows on their own: points raised, open questions and findings.
public struct DiscussionBody: Equatable, Sendable {
    public struct Point: Equatable, Sendable, Hashable {
        public var date: String
        public var who: String
        public var text: String
    }

    public struct Question: Equatable, Sendable, Hashable {
        public var text: String
        public var answered: Bool
    }

    public var summary: String
    public var points: [Point]
    public var questions: [Question]
    public var findings: [String]
    public var outcome: String

    public init(_ body: String) {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                current = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                sections[current!, default: []] = []
            } else if let c = current {
                sections[c, default: []].append(line)
            }
        }
        func text(_ name: String) -> String {
            (sections[name] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func bullets(_ name: String) -> [String] {
            (sections[name] ?? []).compactMap { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("- ") || t.hasPrefix("* ") else { return nil }
                return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
        summary = text("Summary")
        outcome = text("Outcome")
        findings = bullets("Findings")
        questions = bullets("Open questions").map { raw in
            if raw.hasPrefix("[ ] ") { return Question(text: String(raw.dropFirst(4)), answered: false) }
            if raw.lowercased().hasPrefix("[x] ") { return Question(text: String(raw.dropFirst(4)), answered: true) }
            return Question(text: raw, answered: false)
        }
        points = bullets("Points raised").map { raw in
            // "2026-11-10 · Ana: text", "2026-11-10: text", or free text
            var rest = Substring(raw)
            var date = ""
            if raw.count >= 10, KBDate.isISODate(String(raw.prefix(10))) {
                date = String(raw.prefix(10))
                rest = raw.dropFirst(10).drop { $0 == " " || $0 == "·" || $0 == ":" }
            }
            if let colon = rest.firstIndex(of: ":"), rest.distance(from: rest.startIndex, to: colon) <= 40, !date.isEmpty {
                let who = rest[..<colon].trimmingCharacters(in: .whitespaces)
                if !who.contains(" ") || who.split(separator: " ").count <= 4 {
                    return Point(date: date, who: who, text: rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                }
            }
            return Point(date: date, who: "", text: rest.trimmingCharacters(in: .whitespaces))
        }
    }

    public var openQuestions: [Question] { questions.filter { !$0.answered } }
}
