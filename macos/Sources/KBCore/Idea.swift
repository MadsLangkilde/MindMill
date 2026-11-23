import Foundation

public enum IdeaStatus: String, CaseIterable, Sendable {
    case new, exploring, shelved, done

    public var title: String {
        switch self {
        case .new: return "New"
        case .exploring: return "Exploring"
        case .shelved: return "Shelved"
        case .done: return "Turned into something"
        }
    }
}

/// What an idea can grow into. `project` starts a new KB project from it.
public enum IdeaOutcome: String, CaseIterable, Sendable, Identifiable {
    case backlog, fact, decision, followup, architecture, project

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .backlog: return "Backlog Items"
        case .fact: return "Facts"
        case .decision: return "A Decision"
        case .followup: return "Follow-ups"
        case .architecture: return "An Architecture Note"
        case .project: return "A New Project in Mindmill"
        }
    }
}

extension KBEntry {
    public var ideaStatus: IdeaStatus { IdeaStatus(rawValue: rawStatus) ?? .new }
    /// The last activity: `updated`, else the day it was written down.
    public var ideaUpdated: String { field("updated") ?? date }
}

/// The parts of an idea the app counts: open questions, next steps, and what it turned into.
public struct IdeaBody: Equatable, Sendable {
    public var openQuestions: [String]
    public var nextSteps: [String]
    public var turnedInto: [String]

    public init(_ body: String) {
        func items(_ name: String, open: Bool) -> [String] {
            (GoalBody.section(name, in: body) ?? "").components(separatedBy: "\n").compactMap { raw in
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- [ ] ") { return String(t.dropFirst(6)) }
                if !open, t.hasPrefix("- "), !t.hasPrefix("- [x]") { return String(t.dropFirst(2)) }
                return nil
            }
        }
        openQuestions = items("Open questions", open: true)
        nextSteps = items("Next steps", open: true)
        turnedInto = items("Turned into", open: false)
    }
}
