import Foundation

/// Approved pull requests that can't be completed because of a failed or stuck build or merge conflicts: what
/// the Mindmill app reports to the overview session, and the brief for the session that gets them all completed.
public enum PRRescue {
    /// Blockers that clear by themselves soon.
    static let passing = [PRBlocker.buildRunning, PRBlocker.mergeChecking, PRBlocker.buildExpired]

    public static func isApproved(_ pr: PullRequest) -> Bool {
        pr.approvals > 0 && pr.rejections == 0 && !pr.reviewers.contains { $0.vote == -5 }
    }

    /// Approved, not a draft, no open comments, and held up by something that doesn't clear by itself.
    public static func blocked(_ prs: [PullRequest]) -> [PullRequest] {
        prs.filter { pr in
            !pr.draft && isApproved(pr) && pr.openThreads == 0 && !pr.canComplete
                && pr.blockers.contains { !passing.contains($0) }
        }
        .sorted { $0.id < $1.id }
    }

    /// The ids the last report covered, as stored: a new report goes out only when a pull request joins the list.
    public static func shouldReport(_ prs: [PullRequest], lastReported: Set<Int>) -> Bool {
        !Set(prs.map(\.id)).isSubset(of: lastReported)
    }

    static func line(_ pr: PullRequest) -> String {
        "- !\(pr.id) \(pr.repo): \(pr.title) (\(pr.source) → \(pr.target)). \(pr.blockers.joined(separator: "; "))."
    }

    /// The message to the overview session.
    public static func report(_ prs: [PullRequest]) -> String {
        """
        PR report: \(prs.count) approved pull request\(prs.count == 1 ? "" : "s") can't be completed:
        \(prs.map(line).joined(separator: "\n"))

        Tell the user in a line or two, then ask with a choices block: `Fix and complete them all (Recommended)`, `Only some of them`, `Not now`. Not now: drop it; the app reports again when another PR gets stuck. Only some: ask which, then use only those. On yes, start one lead for it with `kb crew start --lead --title "Complete approved PRs" --project \(prs.first?.scope ?? "<scope>") "<brief>"`, the brief being exactly the text between the lines below (with the PR list cut down to the chosen ones), and say in one line that it reports back here.
        ---
        \(brief(prs))
        ---
        """
    }

    /// What the lead is asked to do; the user has said yes to pushing the fixes and completing the PRs.
    public static func brief(_ prs: [PullRequest]) -> String {
        """
        Get these approved pull requests completed. The user said yes to fixing them, pushing the fixes, re-running builds and completing them:
        \(prs.map(line).joined(separator: "\n"))

        1. Look first: `kb pr checks <id>` shows each one's builds, with the failing steps and their logs; `kb pr show <id>` the rest. Work out the order: a PR whose source branch is based on another PR's branch goes after that one.
        2. Then each in that order:
           - Merge conflicts: in a worktree on the PR's source branch (reuse one that exists), merge the target branch in, resolve the conflicts keeping what both sides meant, build, run the tests, commit and push. Never force-push or rewrite history.
           - Failed build: read why. A timeout, a lost or unresponsive agent or another infrastructure failure only needs `kb pr checks <id> --requeue`. A real failure (a compile error, a failing test) gets fixed on the branch, built and tested locally, and pushed.
           - A queued build that has expired or is stuck: `kb pr checks <id> --requeue`.
           - When `kb pr list` shows nothing blocks it, `kb pr complete <id>` (the policy's merge type; delete the source branch unless it is a release, test, staging or hotfix branch). While a build still runs, `kb pr complete <id> --auto` and go on to the next.
           - After each merge the others' target branch has moved: check them again for conflicts.
        3. When all are completed, `kb pr done` lists what they left behind; remove it with `kb pr cleanup <id> --worktree --branch` (never `--force`; leave anything it refuses and say so).
        Report to the overview session (`kb crew send overseer`) in one line as each PR completes or gets stuck, and once at the end. Ask the user through it (`NEEDS:`) before resolving a conflict whose intent is unclear, before changing a test just to make it pass, and when a build keeps failing after a requeue.
        """
    }
}

/// What holds up a pull request that needs doing something about, shown beside its session's status.
public enum PRProblem: String, Sendable {
    case conflicts, buildFailed, buildExpired, buildQueued

    public var label: String {
        switch self {
        case .conflicts: return "Merge conflicts"
        case .buildFailed: return "Build failed"
        case .buildExpired: return "Build expired"
        case .buildQueued: return "Build queued"
        }
    }

    public var icon: String {
        switch self {
        case .conflicts, .buildFailed: return "exclamationmark.triangle.fill"
        case .buildExpired: return "arrow.clockwise"
        case .buildQueued: return "hourglass"
        }
    }

    /// Conflicts and a failed build need fixing; a queued build only needs waiting, and the app runs an expired
    /// build again by itself.
    public var needsFixing: Bool { self == .conflicts || self == .buildFailed }

    public static func of(_ pr: PullRequest) -> PRProblem? {
        guard !pr.draft else { return nil }
        if pr.blockers.contains(PRBlocker.conflicts) { return .conflicts }
        if pr.blockers.contains(PRBlocker.buildFailed) { return .buildFailed }
        if pr.buildExpired { return .buildExpired }
        if pr.blockers.contains(PRBlocker.buildQueued) { return .buildQueued }
        return nil
    }

    /// The problem beside a session's status, unless the status already says the same.
    public static func shown(_ problem: PRProblem?, status: SessionStatus) -> PRProblem? {
        problem == .buildQueued && (status == .building || status == .buildQueued) ? nil : problem
    }
}

/// What a session is asked when the user picks a fix for its pull request.
public enum PRFix {
    public static func conflicts(_ pr: PullRequest) -> String {
        """
        !\(pr.id) (\(pr.source) → \(pr.target)) has merge conflicts. Resolve them:
        1. In this work's worktree or branch `\(pr.source)` (reuse the one that exists), fetch and merge `origin/\(pr.target)` in. Never rebase, force-push or rewrite history.
        2. Resolve each conflict keeping what both sides meant. When a conflict's intent is unclear, stop and ask me with choices before deciding it.
        3. Build and run the tests. If something fails because of the merge, fix it.
        4. Commit the merge and push; I approve that for this pull request. Then tell me in a few lines which files conflicted and how you resolved each, and whether the PR can be completed (`kb pr show \(pr.id)`).
        """
    }

    public static func failedBuild(_ pr: PullRequest) -> String {
        """
        The build of !\(pr.id) (\(pr.source) → \(pr.target)) failed. Run `kb pr checks \(pr.id)` to see the failing steps and their logs.
        - A timeout, a lost agent or another infrastructure failure only needs `kb pr checks \(pr.id) --requeue`.
        - A real failure (a compile error, a failing test): fix it on `\(pr.source)`, build and test locally, commit and push; I approve that for this pull request. Never change a test just to make it pass without asking me.
        Tell me in a few lines what failed and what you did.
        """
    }
}

/// A reviewer's vote on a pull request, as the app offers it and `kb pr vote` casts it.
public enum ReviewVote: String, CaseIterable, Sendable, Identifiable {
    case approve, approveWithSuggestions = "approve-with-suggestions", waitForAuthor = "wait-for-author", reject, reset

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .approve: return "Approve"
        case .approveWithSuggestions: return "Approve with Suggestions"
        case .waitForAuthor: return "Wait for Author"
        case .reject: return "Reject"
        case .reset: return "Reset My Vote"
        }
    }

    /// Added to every review: it ends by asking which vote to cast, whatever was posted or skipped.
    public static func askAtTheEnd(_ prID: Int) -> String {
        "When you've gone through every finding (posted or skipped), always end by asking which vote to cast, even if the review skill says to offer it only sometimes: a short line on what was posted, then a choices block with `Approve`, `Approve with suggestions`, `Wait for author`, `Reject` and `Don't vote`, your recommendation first and marked (Recommended). Cast it with `kb pr vote \(prID) --vote <approve | approve-with-suggestions | wait-for-author | reject>` only after I pick one."
    }
}
