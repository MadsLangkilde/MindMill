import Foundation

/// `kb pr list --json`: the user's active pull requests, with comments, reviewers and what blocks completing.
public struct PullRequestList: Codable, Equatable, Sendable {
    public var fetched: String
    public var prs: [PullRequest]
    /// The user's pull requests completed or abandoned in the last week.
    public var closed: [ClosedPR]

    public init(fetched: String = "", prs: [PullRequest] = [], closed: [ClosedPR] = []) {
        self.fetched = fetched
        self.prs = prs
        self.closed = closed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fetched = try c.decodeIfPresent(String.self, forKey: .fetched) ?? ""
        prs = try c.decodeIfPresent([PullRequest].self, forKey: .prs) ?? []
        closed = try c.decodeIfPresent([ClosedPR].self, forKey: .closed) ?? []
    }

    /// The PR merged lately: completed, not abandoned.
    public func completed(_ id: Int) -> ClosedPR? { closed.first { $0.id == id && $0.completed } }

    /// A work item's code is merged: a PR of it was completed lately and none of its PRs is still open, so the
    /// session is done even while the work item itself hasn't moved yet.
    public func workMerged(item: Int, itemPRs: [Int]) -> Bool {
        let mine = { (id: Int, items: [Int]) in items.contains(item) || itemPRs.contains(id) }
        if prs.contains(where: { mine($0.id, $0.workItems) }) { return false }
        return closed.contains { $0.completed && mine($0.id, $0.workItems) }
    }

    public static func decode(_ json: String) throws -> PullRequestList {
        try JSONDecoder().decode(PullRequestList.self, from: Data(json.utf8))
    }

    public func pr(_ id: Int) -> PullRequest? { prs.first { $0.id == id } }

    /// Pull requests with comments waiting for an answer.
    public var needingAnswers: Int { prs.filter { $0.openThreads > 0 }.count }
}

public struct ClosedPR: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    /// `completed` or `abandoned`.
    public var status: String
    public var closed: String
    public var repo: String
    public var workItems: [Int]

    public var completed: Bool { status == "completed" }

    enum CodingKeys: String, CodingKey {
        case id, title, status, closed, repo
        case workItems = "work_items"
    }

    public init(id: Int, title: String = "", status: String = "completed", closed: String = "", repo: String = "", workItems: [Int] = []) {
        self.id = id
        self.title = title
        self.status = status
        self.closed = closed
        self.repo = repo
        self.workItems = workItems
    }
}

public struct PullRequest: Codable, Equatable, Sendable, Identifiable {
    public struct Reviewer: Codable, Equatable, Sendable, Hashable {
        public var name: String
        public var vote: Int
        public var required: Bool
        public var voteName: String

        enum CodingKeys: String, CodingKey { case name, vote, required, voteName = "vote_name" }

        public init(name: String, vote: Int = 0, required: Bool = false, voteName: String = "no vote") {
            self.name = name
            self.vote = vote
            self.required = required
            self.voteName = voteName
        }
    }

    public struct Policy: Codable, Equatable, Sendable, Hashable {
        public var name: String
        public var kind: String
        public var status: String
        public var blocking: Bool
        /// A build whose result expired: it has to run again before the PR can complete.
        public var expired: Bool?

        public var passed: Bool { status == "approved" || status == "notApplicable" }
    }

    public struct Comment: Codable, Equatable, Sendable, Identifiable, Hashable {
        public var id: Int
        public var author: String
        public var content: String
        public var date: String
    }

    public struct Thread: Codable, Equatable, Sendable, Identifiable, Hashable {
        public var id: Int
        public var status: String
        public var file: String
        public var line: Int
        public var published: String
        public var comments: [Comment]

        public init(id: Int, status: String, file: String = "", line: Int = 0, published: String = "", comments: [Comment] = []) {
            self.id = id
            self.status = status
            self.file = file
            self.line = line
            self.published = published
            self.comments = comments
        }

        public var isOpen: Bool { status == "active" || status == "pending" }
        public var fileName: String { file.split(separator: "/").last.map(String.init) ?? file }
        public var statusTitle: String { PullRequest.threadStatusTitle(status) }
    }

    public var id: Int
    public var title: String
    public var repo: String
    public var repoID: String
    public var scope: String
    public var url: String
    public var draft: Bool
    public var author: String
    public var source: String
    public var target: String
    public var created: String
    public var mergeStatus: String
    public var autoComplete: Bool
    public var reviewers: [Reviewer]
    public var workItems: [Int]
    public var openThreads: Int
    public var threadsTotal: Int
    public var policies: [Policy]
    public var blockers: [String]
    public var strategies: [String]
    public var keepBranch: Bool
    /// Only from `kb pr show`.
    public var description: String?
    public var threads: [Thread]?

    enum CodingKeys: String, CodingKey {
        case id, title, repo, scope, url, draft, author, source, target, created, reviewers, policies, blockers, strategies
        case description, threads
        case repoID = "repo_id", mergeStatus = "merge_status", autoComplete = "auto_complete", workItems = "work_items"
        case openThreads = "open_threads", threadsTotal = "threads_total", keepBranch = "keep_branch"
    }

    public init(id: Int, title: String, repo: String = "repo", scope: String = "", url: String = "", draft: Bool = false,
                source: String = "feature/x", target: String = "main", reviewers: [Reviewer] = [], workItems: [Int] = [],
                openThreads: Int = 0, policies: [Policy] = [], blockers: [String] = [], strategies: [String] = ["squash"],
                keepBranch: Bool = false, threads: [Thread]? = nil) {
        self.id = id
        self.title = title
        self.repo = repo
        self.repoID = ""
        self.scope = scope
        self.url = url
        self.draft = draft
        self.author = ""
        self.source = source
        self.target = target
        self.created = ""
        self.mergeStatus = "succeeded"
        self.autoComplete = false
        self.reviewers = reviewers
        self.workItems = workItems
        self.openThreads = openThreads
        self.threadsTotal = threads?.count ?? openThreads
        self.policies = policies
        self.blockers = blockers
        self.strategies = strategies
        self.keepBranch = keepBranch
        self.description = nil
        self.threads = threads
    }

    public var canComplete: Bool { blockers.isEmpty }
    public var sessionKey: String { "mypr:\(id)" }
    public var approvals: Int { reviewers.filter { $0.vote >= 5 }.count }

    /// All that holds it up is a build or merge check that is queued or running.
    public var waitingForChecks: Bool {
        let waits: Set<String> = [PRBlocker.buildRunning, PRBlocker.buildQueued, PRBlocker.mergeChecking]
        return !blockers.isEmpty && blockers.allSatisfy(waits.contains)
    }
    /// The build waits in the queue and nothing else holds it up but checks still to run.
    public var buildQueuedOnly: Bool {
        waitingForChecks && blockers.contains(PRBlocker.buildQueued) && !blockers.contains(PRBlocker.buildRunning)
    }
    public var buildExpired: Bool { blockers.contains(PRBlocker.buildExpired) }
    public var rejections: Int { reviewers.filter { $0.vote <= -5 }.count }

    /// Open threads first, newest first within each group.
    public var sortedThreads: [Thread] {
        (threads ?? []).sorted { a, b in
            if a.isOpen != b.isOpen { return a.isOpen }
            return a.published > b.published
        }
    }

    public static func strategyTitle(_ s: String) -> String {
        switch s {
        case "squash": return "Squash commit"
        case "noFastForward": return "Merge (no fast-forward)"
        case "rebase": return "Rebase and fast-forward"
        case "rebaseMerge": return "Semi-linear merge"
        default: return s
        }
    }

    public static func threadStatusTitle(_ s: String) -> String {
        switch s {
        case "active": return "Active"
        case "pending": return "Pending"
        case "fixed": return "Resolved"
        case "wontFix": return "Won't fix"
        case "closed": return "Closed"
        case "byDesign": return "By design"
        default: return s.capitalized
        }
    }
}

/// The blockers `kb pr list` words that the app acts on.
public enum PRBlocker {
    public static let buildRunning = "The build is running"
    public static let buildQueued = "The build is queued"
    public static let buildExpired = "The build expired"
    public static let buildFailed = "The build failed"
    public static let mergeChecking = "The merge is still being checked"
    public static let conflicts = "It has merge conflicts"
}
