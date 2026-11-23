import Foundation

/// Moving a work item to in progress when work on it starts, whichever tracker the scope uses: Azure DevOps through
/// `kb tracker start`, Mindmill's own tracker in place, and anything reached through Claude (Jira, GitHub, Linear) by
/// asking the session to do it with the connector for it.
public enum TrackerStart {
    public enum Route: Equatable, Sendable {
        case cli
        case local
        /// The tracker's name, for the session's instruction.
        case claude(String)
        case none
    }

    public static func route(kind: String) -> Route {
        switch kind {
        case "azure-devops": return .cli
        case "local": return .local
        case "", "none": return .none
        case "jira": return .claude("Jira")
        case "github": return .claude("GitHub")
        default: return .claude(kind.prefix(1).uppercased() + kind.dropFirst())
        }
    }

    /// The first thing a session does when its tracker is only reachable through Claude.
    public static func sessionNote(kind: String, ref: String) -> String? {
        guard case .claude(let name) = route(kind: kind) else { return nil }
        return "First, if \(ref) isn't started in \(name) yet, move it to its in-progress status (In Progress, Active or the like) with your \(name) connector, and say so in one line. If no \(name) connector is available, tell me instead of looking for another way."
    }
}

extension LocalTracker {
    /// The state starting work moves an item to, or nil when it is already under way, done or removed.
    public func startedState(_ id: Int) -> String? {
        guard let item = item(id) else { return nil }
        let proposed: Set<String> = item.kind == .task ? ["To Do"] : ["New", "Approved"]
        guard proposed.contains(item.state) else { return nil }
        return item.kind == .task ? "In Progress" : "Committed"
    }

    /// Moves an item nobody has started to in progress; false when there was nothing to move.
    @discardableResult
    public mutating func start(_ id: Int, now: String = LocalTracker.now()) -> Bool {
        guard let state = startedState(id) else { return false }
        setState(id, state, now: now)
        return true
    }
}
