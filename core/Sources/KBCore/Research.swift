import Foundation

/// A research: something the user looks into with Claude, alone or for a PBI, idea or discussion. Open while
/// Claude digs; review once Claude has summarized it and proposed what to keep; done when the user has taken
/// what they wanted.
public enum ResearchStatus: String, CaseIterable, Sendable {
    case open, review, done, parked

    public static let icon = "binoculars"

    public var title: String {
        switch self {
        case .open: return "Researching"
        case .review: return "Ready to finish"
        case .done: return "Done"
        case .parked: return "Parked"
        }
    }
}

/// What a research is for: a work item in the tracker (`wi:<id>`), or a KB entry such as an idea or a discussion.
public enum ResearchTarget: Hashable, Sendable {
    case workItem(Int)
    case entry(EntryID)

    public init?(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("wi:"), let n = Int(t.dropFirst(3)) {
            self = .workItem(n)
        } else if t.hasPrefix("#"), let n = Int(t.dropFirst()) {
            self = .workItem(n)
        } else if let id = EntryID(t), id.section != .research {
            self = .entry(id)
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .workItem(let n): return "wi:\(n)"
        case .entry(let id): return id.rawValue
        }
    }
}

extension KBEntry {
    public var researchStatus: ResearchStatus { ResearchStatus(rawValue: rawStatus) ?? .open }
    public var researchFor: ResearchTarget? { field("for").flatMap(ResearchTarget.init) }
    public var researchUpdated: String { field("updated") ?? date }
}

/// The parts of a research file. Claude adds findings, open questions and sources as it goes; finishing writes
/// the summary and the takeaways, which are what can be carried over to the PBI.
public struct ResearchBody: Equatable, Sendable {
    public var question: String
    public var findings: [String]
    public var openQuestions: [String]
    public var sources: [String]
    public var summary: String
    public var takeaways: [String]

    public init(_ body: String) {
        func lines(_ name: String, openOnly: Bool = false) -> [String] {
            (GoalBody.section(name, in: body) ?? "").components(separatedBy: "\n").compactMap { raw in
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- [ ] ") { return String(t.dropFirst(6)) }
                if openOnly { return nil }
                if t.hasPrefix("- [x] ") { return nil }
                if t.hasPrefix("- ") || t.hasPrefix("* ") { return String(t.dropFirst(2)) }
                return nil
            }
        }
        question = (GoalBody.section("Question", in: body) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        findings = lines("Findings")
        openQuestions = lines("Open questions", openOnly: true)
        sources = lines("Sources")
        summary = (GoalBody.section("Summary", in: body) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        takeaways = lines("Takeaways")
    }

    public static func template(question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return "## Question\n\n\(q.isEmpty ? "" : q + "\n")\n## Findings\n\n## Open questions\n\n## Sources\n\n## Summary\n\n## Takeaways\n"
    }
}

public enum ResearchTransfer {
    /// The takeaways the user picked, as the Markdown that goes on the PBI or entry.
    public static func text(_ takeaways: [String]) -> String {
        takeaways.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { "- \($0)" }.joined(separator: "\n")
    }

    /// An entry's body with the takeaways added under `## Research` (made at the end when it isn't there).
    public static func appending(_ text: String, to body: String, title: String, date: String) -> String {
        let block = "**\(title)** (\(date))\n\n\(text)"
        if let existing = GoalBody.section("Research", in: body) {
            let merged = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            return GoalBody.setting("Research", to: merged.isEmpty ? block : merged + "\n\n" + block, in: body)
        }
        let trimmed = body.trimmingCharacters(in: .newlines)
        return (trimmed.isEmpty ? "" : trimmed + "\n\n") + "## Research\n\n" + block + "\n"
    }
}

/// Whether a Build session reads like research rather than work on code: asked once per session.
public enum ResearchDetect {
    private static let asks = [
        "research", "investigate", "find out", "look into", "compare", "comparison", "what are the options",
        "options for", "pros and cons", "which library", "which framework", "which approach", "is it possible",
        "is there a way", "how does", "how do ", "why does", "why is", "what is the best", "what's the best",
        "evaluate", "explore", "alternatives", "trade-off", "tradeoff",
        "undersøg", "find ud af", "sammenlign", "hvordan", "hvorfor", "hvilken", "hvilke", "er det muligt", "kan man",
    ]
    private static let work = [
        "implement", "fix ", "fix the", "refactor", "add a ", "add an ", "add the ", "create a pr", "pull request",
        "commit", "write a test", "write tests", "rename", "migrate", "change the", "remove the", "delete the",
        "update the code", "make it ", "build the", "implementér", "implementer", "ret fejl", "tilføj", "lav en", "lav et",
    ]

    /// The first thing the user asked: a question to look into, without words that ask for changes.
    public static func looksLikeResearch(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, !t.hasPrefix("/") else { return false }
        if work.contains(where: { t.contains($0) }) { return false }
        return asks.contains { t.contains($0) } || t.hasSuffix("?")
    }

    /// Tool lines (`Name\tsummary`) that changed files or the repository.
    public static func changedSomething(_ toolLines: [String]) -> Bool {
        toolLines.contains { line in
            let name = line.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? line
            if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name) { return true }
            return name == "Bash" && (line.contains("git commit") || line.contains("git push"))
        }
    }

    public static func shouldOffer(firstMessage: String, toolLines: [String], offered: Bool) -> Bool {
        !offered && looksLikeResearch(firstMessage) && !changedSomething(toolLines)
    }
}
