import Foundation

/// How an "Implement" from My Work runs: in one session, or led by a strategy that may start sessions under it.
public enum ImplementWay {
    /// UserDefaults key: the way picked last, preselected when asking.
    public static let lastKey = "implementLastWay"
    public static let oneSession = "one-session"

    /// Added to the task when a strategy leads it, so the repo's skill and the strategy don't pull apart.
    public static func strategyNote(_ strategy: Strategy, skill: String?, fast: Bool) -> String {
        var lines: [String] = []
        if let skill {
            lines.append("Use the `\(skill)` skill as the recipe for the branch, work item tasks, review and pull request, but follow the strategy for how the work is split.")
            if strategy.spawns {
                lines.append("Where the skill would run parts in parallel as subagents, start them as sessions under you with `kb crew start --under me` instead, so they show in the Mindmill app.")
            }
        }
        if fast {
            lines.append("My approval above of the commits, push and pull request for this work item replaces the strategy's rule to ask before committing or pushing.")
        }
        return lines.joined(separator: "\n")
    }
}
