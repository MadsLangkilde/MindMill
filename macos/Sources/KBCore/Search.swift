import Foundation

/// Plain-text search shared by every area: all words must appear, a leading `#` or `!` (a work item or pull
/// request number) is ignored, and case doesn't matter.
public enum KBSearch {
    public static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map { t in
            let s = t.drop(while: { $0 == "#" || $0 == "!" })
            return String(s.isEmpty ? t : s)
        }
    }

    public static func matches(_ query: String, in haystack: String) -> Bool {
        let t = terms(query)
        return !t.isEmpty && t.allSatisfy { haystack.contains($0) }
    }

    /// Dates, times and links to other entries: their digits would match almost any number searched for.
    static let skippedKeys: Set<String> = [
        "date", "start", "end", "due", "created", "updated", "fetched", "supersedes", "superseded_by", "source",
        "proposed_by", "raised_in", "previous", "session_id", "calendar_id", "calendar_series", "calendar_url",
        "online_url", "updates",
    ]

    /// The frontmatter values worth searching (titles, people, work items, URLs, statuses), as text.
    public static func text(_ fm: Frontmatter) -> String {
        fm.keys.filter { !skippedKeys.contains($0) }.compactMap { fm[$0]?.stringValue }.joined(separator: "\n")
    }
}

extension TrackerBacklog.Item {
    public var searchText: String {
        ([String(id), type, title, state, assignee, sprint, scope] + scopes + tags + prs.map(String.init))
            .joined(separator: "\n").lowercased()
    }

    public func matches(_ query: String) -> Bool { KBSearch.matches(query, in: searchText) }
}

extension Reminder {
    public func matches(_ query: String) -> Bool {
        KBSearch.matches(query, in: [id, KBSearch.text(frontmatter), note].joined(separator: "\n").lowercased())
    }
}

extension Goal {
    public func matches(_ query: String) -> Bool {
        KBSearch.matches(query, in: [id, KBSearch.text(frontmatter), body].joined(separator: "\n").lowercased())
    }
}

extension PullRequest {
    public func matches(_ query: String) -> Bool {
        KBSearch.matches(query, in: ([String(id), title, repo, scope, author, source, target] + workItems.map(String.init)
                                     + reviewers.map(\.name)).joined(separator: "\n").lowercased())
    }
}

extension CompletedPRs.PR {
    public func matches(_ query: String) -> Bool {
        KBSearch.matches(query, in: [String(id), title, repo, scope, branch].joined(separator: "\n").lowercased())
    }
}

extension MyWork.Item {
    public func matches(_ query: String) -> Bool {
        KBSearch.matches(query, in: ([String(id), type, title, state, sprint, project] + prs.flatMap { [String($0.id), $0.title, $0.repo] })
            .joined(separator: "\n").lowercased())
    }
}

extension MyWork.Review {
    public func matches(_ query: String) -> Bool {
        KBSearch.matches(query, in: [String(id), title, repo, author, project].joined(separator: "\n").lowercased())
    }
}

extension DailyPlan.Item {
    public func matches(_ query: String) -> Bool {
        KBSearch.matches(query, in: [text, project ?? "", ref ?? ""].joined(separator: "\n").lowercased())
    }
}

extension Strategy {
    public func matches(_ query: String) -> Bool {
        KBSearch.matches(query, in: [slug, title, summary].joined(separator: "\n").lowercased())
    }
}
