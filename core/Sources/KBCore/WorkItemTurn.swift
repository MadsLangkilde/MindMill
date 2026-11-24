import Foundation

/// Whose turn a work item is: the session's, the user's, or other people's (reviewers, a build).
public enum WorkItemTurn: Equatable, Sendable {
    /// The session is working on it.
    case implementing
    /// The session asks the user something or needs a permission.
    case needsYou(String)
    /// Its pull request waits on reviewers or checks; nothing for the user to do.
    case waitingForOthers(String)
    /// The session stopped; the user can open it to carry on.
    case paused

    public static func of(_ state: CrewSessionState, pr: PullRequest?) -> WorkItemTurn {
        switch state {
        case .working: return .implementing
        case .waiting, .blocked: return .needsYou(state.label)
        case .idle, .stopped: break
        }
        if let pr, let line = waitingOnOthers(pr) { return .waitingForOthers(line) }
        return .paused
    }

    /// What the card's button says.
    public var buttonTitle: String {
        switch self {
        case .implementing: return "Implementing…"
        case .needsYou(let label): return label
        case .waitingForOthers, .paused: return "Open Session"
        }
    }

    /// The reviewers who haven't approved, by first name, leaving out the author.
    public static func pendingReviewers(_ pr: PullRequest) -> [String] {
        pr.reviewers.filter { $0.vote < 5 && $0.name != pr.author && !$0.name.contains("[") }
            .map { String($0.name.split(separator: " ").first ?? Substring($0.name)) }
    }

    /// How the pull request stands when only others can move it on: approval from reviewers who haven't approved,
    /// or a build or merge check still running. Nil when something is the user's (comments, a failed build, a
    /// conflict, a draft) or it can be completed.
    public static func waitingOnOthers(_ pr: PullRequest) -> String? {
        guard !pr.draft, !pr.blockers.isEmpty else { return nil }
        let othersOnly: Set<String> = ["Waiting for approval", PRBlocker.buildRunning, PRBlocker.buildQueued,
                                       PRBlocker.mergeChecking]
        guard pr.blockers.allSatisfy(othersOnly.contains) else { return nil }
        if pr.blockers.contains("Waiting for approval") {
            let names = pendingReviewers(pr)
            return names.isEmpty ? "Waiting for reviewers to approve"
                : "Waiting for \(names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!) to approve"
        }
        return pr.blockers.first
    }
}
