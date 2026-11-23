import Foundation

/// A session title split into the readable part and the work item or pull request it is about:
/// "#418750 Stale login token" → ("Stale login token", "#418750").
public enum SessionTitle {
    public static func split(_ title: String) -> (text: String, ref: String?) {
        let t = title.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(?:(Review|Continue|Implement(?: Fast)?)\s+)?([#!]\d+)(?:\s+comments)?\s*[:·\-–]?\s*"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let refRange = Range(m.range(at: 2), in: t), let all = Range(m.range, in: t) else { return (t, nil) }
        var rest = String(t[all.upperBound...]).trimmingCharacters(in: .whitespaces)
        var ref = String(t[refRange])
        if let verb = Range(m.range(at: 1), in: t) { ref = "\(t[verb]) \(ref)" }
        if t[all].contains("comments") { ref += " comments" }
        if rest.isEmpty { rest = ref }
        return (rest, ref)
    }
}

/// Where a Build session stands, from its process and the work it is about. Ordered by how much it needs the user.
public enum SessionStatus: String, Sendable, CaseIterable {
    case needsInput, needsPermission, running, completing, readyToComplete, comments, building, buildQueued, approved, inReview, draft
    case inPR, inProgress, notStarted, resolved, checking, idle, notRunning, done

    public var label: String {
        switch self {
        case .needsInput: return "Needs input"
        case .needsPermission: return "Needs permission"
        case .running: return "Running"
        case .completing: return "Completing"
        case .readyToComplete: return "Ready to complete"
        case .building: return "Building"
        case .buildQueued: return "Build queued"
        case .comments: return "Comments to answer"
        case .approved: return "Approved"
        case .inReview: return "In review"
        case .draft: return "Draft PR"
        case .inPR: return "In PR"
        case .inProgress: return "In progress"
        case .notStarted: return "Not started"
        case .resolved: return "Resolved"
        case .checking: return "Checking…"
        case .idle: return "Idle"
        case .notRunning: return "Not running"
        case .done: return "Done"
        }
    }

    public var needsUser: Bool { self == .needsInput || self == .needsPermission }

    /// What the session's pull request looks like, when it has one that is open.
    public struct PRState: Equatable, Sendable {
        public var canComplete: Bool
        public var openThreads: Int
        public var draft: Bool
        /// Approved, or approved with suggestions, and nobody rejects or waits for the author.
        public var approved: Bool
        /// Set to complete by itself once its checks pass.
        public var autoComplete: Bool
        /// What holds it up is only a build or merge check that is queued or running.
        public var building: Bool
        /// Of those, the build hasn't started: it waits in the queue.
        public var buildQueued: Bool
        public init(canComplete: Bool, openThreads: Int, draft: Bool, approved: Bool = false, autoComplete: Bool = false,
                    building: Bool = false, buildQueued: Bool = false) {
            self.buildQueued = buildQueued
            self.canComplete = canComplete
            self.openThreads = openThreads
            self.draft = draft
            self.approved = approved
            self.autoComplete = autoComplete
            self.building = building
        }
    }

    /// A question or a refused tool wins over everything; then a running turn; then the work's own stage.
    public static func of(_ crew: CrewSessionState, pr: PRState?, workDone: Bool) -> SessionStatus {
        switch crew {
        case .waiting: return .needsInput
        case .blocked: return .needsPermission
        case .working: return .running
        default: break
        }
        if workDone { return .done }
        if let pr { return stage(of: pr) }
        return crew == .idle ? .idle : .notRunning
    }

    public static func stage(of pr: PRState) -> SessionStatus {
        if pr.draft { return .draft }
        // Completing by itself, or approved and only waiting for its build: nothing to do but wait.
        if pr.autoComplete, pr.openThreads == 0 { return .completing }
        if pr.canComplete { return .readyToComplete }
        if pr.openThreads > 0 { return .comments }
        if pr.approved, pr.building { return pr.buildQueued ? .buildQueued : .building }
        // Approved but held up by a failed build, a conflict or another policy: the next step is the user's.
        if pr.approved { return .approved }
        return .inReview
    }

    public static func stage(of item: MyWork.Stage) -> SessionStatus {
        switch item {
        case .inPR: return .inPR
        case .inProgress: return .inProgress
        case .notStarted: return .notStarted
        case .resolved: return .resolved
        }
    }
}

/// What a session row shows side by side: what the session itself is doing, and where the work it's about stands.
public struct SessionBadges: Equatable, Sendable {
    /// Needs input, needs permission or running. Idle or not running only when there's no work stage to show.
    public var activity: SessionStatus?
    /// The open PR's stage, else the work item's, done, or checking while Azure DevOps hasn't answered yet.
    public var work: SessionStatus?

    public var needsUser: Bool { activity?.needsUser ?? false }

    /// - Parameters:
    ///   - linked: the session is about a work item, a PR of the user's or a review.
    ///   - known: the tracker data that says where that work stands has loaded.
    public static func of(_ crew: CrewSessionState, linked: Bool, known: Bool, pr: SessionStatus.PRState?,
                          item: MyWork.Stage?, workDone: Bool) -> SessionBadges {
        var work: SessionStatus?
        if linked {
            if workDone { work = .done }
            else if let pr { work = SessionStatus.stage(of: pr) }
            else if let item { work = SessionStatus.stage(of: item) }
            else if !known { work = .checking }
        }
        let activity: SessionStatus?
        switch crew {
        case .waiting: activity = .needsInput
        case .blocked: activity = .needsPermission
        case .working: activity = .running
        case .idle: activity = work == nil ? .idle : nil
        case .stopped: activity = work == nil ? .notRunning : nil
        }
        return SessionBadges(activity: activity, work: work)
    }
}

/// When the Mindmill app asks a quiet session that nothing tracks whether its work is done, so the user can archive it.
/// A session whose work is done is asked about before it is archived: it stays in the list, marked Done, with an
/// Archive question, and is archived by itself only once nobody answered for `grace`.
public enum DoneArchive {
    public static let grace: TimeInterval = 3 * 86_400

    /// The sessions seen done now, with when each was first seen done. The first time ever, every session already
    /// done counts as long done, so the old ones don't all come back to ask.
    public static func update(_ seen: [String: Date]?, done: Set<String>, now: Date = Date()) -> [String: Date] {
        guard let seen else { return Dictionary(uniqueKeysWithValues: done.map { ($0, Date.distantPast) }) }
        var out: [String: Date] = [:]
        for id in done { out[id] = seen[id] ?? now }
        return out
    }

    public static func autoArchived(doneSince: Date?, now: Date = Date()) -> Bool {
        guard let doneSince else { return false }
        return now.timeIntervalSince(doneSince) >= grace
    }
}

public enum FinishedCheck {
    public static let quietFor: TimeInterval = 12 * 3600
    /// Older sessions are out of Build's list already; waking them all at once helps nobody.
    public static let lookBack: TimeInterval = 14 * 86_400

    /// A work item, a PR of the user's or a review: the app archives these itself when the work closes.
    public static func isTracked(about: String?) -> Bool {
        guard let about else { return false }
        return ["wi:", "mypr:", "pr:"].contains { about.hasPrefix($0) }
    }

    /// - Parameter askedAt: when it was last asked; it is asked again only after work it did since.
    public static func shouldAsk(role: SessionRole, about: String?, busy: Bool, needsUser: Bool, archived: Bool,
                                 hasMessages: Bool, updated: Date, askedAt: Date?, now: Date = Date()) -> Bool {
        guard role == .solo || role == .lead, !isTracked(about: about), !busy, !needsUser, !archived, hasMessages else { return false }
        let quiet = now.timeIntervalSince(updated)
        guard quiet >= quietFor, quiet <= lookBack else { return false }
        // The check's own reply moves `updated` a little; only real work afterwards earns another check.
        if let askedAt, updated.timeIntervalSince(askedAt) < 3600 { return false }
        return true
    }
}

/// `kb pr done --json`: completed pull requests that left a worktree or a branch on this Mac.
public struct CompletedPRs: Codable, Equatable, Sendable {
    public struct Worktree: Codable, Equatable, Sendable {
        public var path: String
        public var dirty: Bool
    }

    public struct PR: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        public var title: String
        public var repo: String
        public var scope: String
        public var closed: String
        public var url: String
        public var branch: String
        public var repoPath: String
        public var worktrees: [Worktree]
        public var localBranch: Bool
        public var localBranchSafe: Bool
        public var checkedOutInMain: Bool
        public var remoteBranch: Bool
        /// The branch the PR merged into: where a forced clean-up switches the main checkout.
        public var target: String?
        /// The main checkout, on this PR's branch, has uncommitted changes (they move with it when it switches).
        public var mainDirty: Bool?

        enum CodingKeys: String, CodingKey {
            case id, title, repo, scope, closed, url, branch, worktrees, target
            case repoPath = "repo_path", localBranch = "local_branch", localBranchSafe = "local_branch_safe"
            case checkedOutInMain = "checked_out_in_main", remoteBranch = "remote_branch", mainDirty = "main_dirty"
        }

        /// Release, test, staging and hotfix branches are kept on the server by default.
        public var keepRemoteByDefault: Bool {
            ["release/", "test/", "staging/", "hotfix/"].contains { branch.hasPrefix($0) }
        }

        /// `kb pr cleanup` arguments for a clean-up that only removes what loses nothing: worktrees without
        /// uncommitted changes, a local branch whose commits the PR took and that isn't checked out, and the server
        /// branch unless it's one kept by default. Nil when nothing qualifies.
        public func safeCleanupArgs(worktrees: Bool, localBranch: Bool, remote: Bool) -> [String]? {
            var args = ["pr", "cleanup", String(id)]
            if worktrees, !self.worktrees.isEmpty, !self.worktrees.contains(where: \.dirty) { args.append("--worktree") }
            if localBranch, self.localBranch, localBranchSafe, !checkedOutInMain { args.append("--branch") }
            if remote, remoteBranch, !keepRemoteByDefault { args.append("--remote") }
            return args.count > 3 ? args : nil
        }

        /// `kb pr cleanup` arguments that remove everything, warnings or not.
        public var forceCleanupArgs: [String] {
            var args = ["pr", "cleanup", String(id)]
            if !worktrees.isEmpty { args.append("--worktree") }
            if localBranch { args.append("--branch") }
            if remoteBranch { args.append("--remote") }
            return args + ["--force"]
        }

        /// What cleaning up anyway does that a safe clean-up wouldn't, for the confirmation.
        public var anywayEffects: [String] {
            var out: [String] = []
            for w in worktrees where w.dirty { out.append("Removes the worktree \(w.path) and its uncommitted changes.") }
            if localBranch, !localBranchSafe { out.append("Deletes the branch \(branch) with the commits the pull request didn't take.") }
            if localBranch, checkedOutInMain {
                let to = target.map { "to \($0)" } ?? "to its target branch"
                out.append("Switches your main checkout (\(repoPath)) \(to) first"
                           + (mainDirty == true ? "; its uncommitted changes come along, and if git can't carry them it stops there." : "."))
            }
            if remoteBranch, keepRemoteByDefault { out.append("Deletes \(branch) on Azure DevOps, a branch normally kept, for example until the build is uploaded.") }
            return out
        }

        /// What a safe clean-up leaves for the user to decide, in words.
        public var needsDecision: [String] {
            var out: [String] = []
            if worktrees.contains(where: \.dirty) { out.append("a worktree with uncommitted changes") }
            if localBranch, !localBranchSafe { out.append("a branch with commits the PR didn't take") }
            if localBranch, checkedOutInMain { out.append("a branch checked out in the main checkout") }
            if remoteBranch, keepRemoteByDefault { out.append("a \(branch.split(separator: "/").first ?? "") branch kept on Azure DevOps") }
            return out
        }

        public var leftovers: [String] {
            var out: [String] = []
            if !worktrees.isEmpty { out.append(worktrees.count == 1 ? "worktree" : "\(worktrees.count) worktrees") }
            if localBranch { out.append("local branch") }
            if remoteBranch { out.append("remote branch") }
            return out
        }
    }

    public var fetched: String
    public var prs: [PR]

    public static func decode(_ json: String) throws -> CompletedPRs {
        try JSONDecoder().decode(CompletedPRs.self, from: Data(json.utf8))
    }
}
