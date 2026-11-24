import Foundation

/// `kb tracker mine --json`: the user's open PBIs and bugs by stage, their PRs, and PRs waiting for their review.
public struct MyWork: Codable, Equatable, Sendable {
    public struct PR: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        public var title: String
        public var repo: String
        public var url: String
        public var draft: Bool
        public var author: String
    }

    public enum Stage: String, Codable, Sendable, CaseIterable {
        case inPR = "in_pr", inProgress = "in_progress", notStarted = "not_started", resolved

        public var title: String {
            switch self {
            case .inPR: return "In PR"
            case .inProgress: return "In progress"
            case .notStarted: return "Not started"
            case .resolved: return "Resolved"
            }
        }
    }

    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        public var type: String
        public var title: String
        public var state: String
        public var sprint: String
        public var project: String
        public var url: String
        public var stage: Stage
        public var prs: [PR]

        public var isBug: Bool { type == "bug" }
        /// "Sprint 25" from "Product\2026\Sprint 25".
        public var sprintName: String { sprint.split(separator: "\\").last.map(String.init) ?? sprint }
        /// The key a Build session working on it carries in `about`.
        public var sessionKey: String { "wi:\(id)" }
    }

    public struct Review: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        public var title: String
        public var repo: String
        public var url: String
        public var draft: Bool
        public var author: String
        public var project: String
        public var required: Bool
        public var assigned: Bool

        public var sessionKey: String { "pr:\(id)" }

        public init(id: Int, title: String, repo: String, url: String, draft: Bool = false, author: String = "",
                    project: String = "", required: Bool = false, assigned: Bool = false) {
            self.id = id
            self.title = title
            self.repo = repo
            self.url = url
            self.draft = draft
            self.author = author
            self.project = project
            self.required = required
            self.assigned = assigned
        }
    }

    public var fetched: String
    public var me: String
    public var items: [Item]
    public var reviews: [Review]
    /// The current sprint's iteration path per KB project.
    public var sprints: [String: String]

    public init(fetched: String = "", me: String = "", items: [Item] = [], reviews: [Review] = [], sprints: [String: String] = [:]) {
        self.fetched = fetched
        self.me = me
        self.items = items
        self.reviews = reviews
        self.sprints = sprints
    }

    public static func decode(_ json: String) throws -> MyWork {
        try JSONDecoder().decode(MyWork.self, from: Data(json.utf8))
    }

    public func items(_ stage: Stage, currentSprintOnly: Bool) -> [Item] {
        items.filter { $0.stage == stage && (!currentSprintOnly || isInCurrentSprint($0)) }
    }

    public func isInCurrentSprint(_ item: Item) -> Bool {
        guard let current = sprints[item.project] else { return true }
        return item.sprint == current
    }
}
