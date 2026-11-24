import Foundation
import KBCore

/// How a Build session's work stands: its work item and pull request from the tracker cache, whether it's done, and
/// whether it's archived; and the sessions that start work (implement, continue, review, PR comments).
extension SessionHub {
    var myWork: MyWork? { engine.tracker.myWork }
    var pullRequests: PullRequestList? { engine.tracker.pullRequests }

    /// The open pull requests of the work a session is about: its own PR, or the PRs of its work item.
    public func linkedPRs(_ s: WorkSession) -> [PullRequest] {
        guard let about = s.about, let list = pullRequests else { return [] }
        if let id = Self.number(about, "mypr:") { return list.pr(id).map { [$0] } ?? [] }
        if let id = Self.number(about, "wi:"), let item = myWork?.items.first(where: { $0.id == id }) {
            return item.prs.compactMap { list.pr($0.id) }
        }
        return []
    }

    public func linkedPR(_ s: WorkSession) -> PullRequest? { linkedPRs(s).first }

    /// The pull requests that can be completed now: the session's own and, for a lead, those of the sessions under
    /// it, each with the session that made it.
    public func readyPRs(_ s: WorkSession) -> [(pr: PullRequest, session: WorkSession)] {
        let from = s.role == .lead ? [s] + members(of: s) : [s]
        var seen = Set<Int>()
        return from.flatMap { m in linkedPRs(m).map { (pr: $0, session: m) } }
            .filter { $0.pr.canComplete && !$0.pr.draft && seen.insert($0.pr.id).inserted }
    }

    /// Approved pull requests held up by a failed or stuck build or merge conflicts.
    public var stuckPRs: [PullRequest] { PRRescue.blocked(pullRequests?.prs ?? []) }

    /// The session working through the stuck PRs, while it isn't archived.
    public var prRescueSession: WorkSession? {
        buildSessions.first { $0.title == "Complete approved PRs" && !isArchived($0) }
    }

    /// Tells the overview session when an approved PR gets stuck, so the user can have them all fixed from there.
    /// Once per PR joining the list; `force` reports the current list now. True when it told the overview session.
    @discardableResult
    public func reportStuckPRs(force: Bool = false) -> Bool {
        guard backgroundChecks || force else { return false }
        let stuck = stuckPRs
        let last = Set(defaults.array(forKey: Self.stuckPRsReportedKey) as? [Int] ?? [])
        defaults.set(stuck.map(\.id), forKey: Self.stuckPRsReportedKey)
        guard !stuck.isEmpty, force || (PRRescue.shouldReport(stuck, lastReported: last) && prRescueSession == nil) else { return false }
        deliver(PRRescue.report(stuck), to: ensureOverseer(), from: "the Mindmill app")
        if !force {
            engine.report("\(stuck.count) approved PR\(stuck.count == 1 ? " is" : "s are") stuck. The overview session asks what to do.")
        }
        return true
    }

    /// Asks the session to clear what keeps its approved pull request from completing.
    public func fixBlockers(_ pr: PullRequest, in s: WorkSession) {
        let list = pr.blockers.map { "- \($0)" }.joined(separator: "\n")
        send("""
        !\(pr.id) is approved but can't be completed yet:
        \(list)
        Clear these: for a failed build, find the failing step in the PR's build and fix it; for merge conflicts, merge \
        the target branch into this branch and resolve them; a queued or running build only needs waiting. Push the \
        fixes, then tell me when it can be completed. Ask before anything you're unsure of.
        """, in: s, display: "Fix what blocks !\(pr.id): \(pr.blockers.joined(separator: ", "))")
    }

    /// The work is over: its PR completed, its item resolved and merged, or the review no longer waits.
    /// Unknown until the tracker has answered, and never while the session runs.
    public func isWorkDone(_ s: WorkSession) -> Bool {
        guard let about = s.about, !s.chat.isBusy, !s.crewState.needsUser else { return false }
        let quiet = Date().timeIntervalSince(s.updated) > 3600
        if let id = Self.number(about, "wi:"), let work = myWork {
            let item = work.items.first { $0.id == id }
            // Its PR just completed: done now, before the work item itself moves.
            if pullRequests?.workMerged(item: id, itemPRs: item?.prs.map(\.id) ?? []) == true { return true }
            if let item { return item.stage == .resolved && linkedPRs(s).isEmpty }
            return quiet
        }
        if let id = Self.number(about, "mypr:"), let list = pullRequests {
            guard let pr = list.pr(id) else { return list.closed.contains { $0.id == id } || quiet }
            // A comments session is done once they're answered and the work item's own session carries the PR.
            return pr.openThreads == 0 && Date().timeIntervalSince(s.updated) > 600 && buildSessions.contains {
                $0 !== s && $0.role != .member && ($0.about?.hasPrefix("wi:") ?? false) && linkedPRs($0).contains { $0.id == id }
            }
        }
        if let id = Self.number(about, "pr:"), let work = myWork { return !work.reviews.contains { $0.id == id } && quiet }
        return false
    }

    /// A conflict or build problem on the session's open pull request.
    public func prProblem(_ s: WorkSession) -> PRProblem? {
        guard s.role != .member, ![.draft, .done].contains(status(s)) else { return nil }
        return PRProblem.shown(linkedPR(s).flatMap(PRProblem.of), status: status(s))
    }

    /// What the session is doing, and where its work item or pull request stands, for the row and the header.
    public func badges(_ s: WorkSession) -> SessionBadges {
        let about = s.about ?? ""
        var known = true
        var item: MyWork.Stage?
        var reviewing = false
        if let id = Self.number(about, "wi:") {
            known = myWork != nil
            item = myWork?.items.first { $0.id == id }?.stage
        } else if about.hasPrefix("mypr:") {
            known = pullRequests != nil
        } else if let id = Self.number(about, "pr:") {
            known = myWork != nil
            reviewing = myWork?.reviews.contains { $0.id == id } ?? false
        }
        let linked = s.role != .member && ["wi:", "mypr:", "pr:"].contains { about.hasPrefix($0) }
        let pr = linkedPR(s).map(Self.prState)
        // A PR or item that has left the open lists is finished, even before the session counts as done.
        let gone = known && pr == nil && item == nil && !reviewing
        var badges = SessionBadges.of(s.crewState, linked: linked, known: known, pr: pr, item: item,
                                      workDone: isWorkDone(s) || gone)
        if reviewing, badges.work == nil { badges.work = .inReview }
        return badges
    }

    static func prState(_ pr: PullRequest) -> SessionStatus.PRState {
        SessionStatus.PRState(canComplete: pr.canComplete, openThreads: pr.openThreads, draft: pr.draft,
                              approved: pr.approvals > 0 && pr.rejections == 0 && !pr.reviewers.contains { $0.vote == -5 },
                              autoComplete: pr.autoComplete, building: pr.waitingForChecks,
                              buildQueued: pr.buildQueuedOnly)
    }

    public func status(_ s: WorkSession) -> SessionStatus {
        let pr = s.role == .member ? nil : linkedPR(s).map(Self.prState)
        return SessionStatus.of(s.crewState, pr: pr, workDone: isWorkDone(s))
    }

    /// Archived by the user, or done by itself unless the user kept it. A session that needs the user never hides.
    public func isArchived(_ s: WorkSession) -> Bool {
        if s.chat.isBusy || s.crewState.needsUser { return false }
        if let lead = s.parentID.flatMap({ session($0) }), s.role == .member, isArchived(lead) { return true }
        return s.archived ?? (status(s) == .done && DoneArchive.autoArchived(doneSince: doneSince?[s.id]))
    }

    /// Plan sessions are archived only by the user; Build ones also once their work is done.
    public func sessionArchived(_ s: WorkSession) -> Bool { s.space == .plan ? s.archived == true : isArchived(s) }

    /// Done and not yet archived or kept: the session asks whether to archive it.
    public func asksToArchive(_ s: WorkSession) -> Bool {
        s.role != .overseer && s.role != .member && s.archived == nil && !isArchived(s) && status(s) == .done
    }

    /// Notes when sessions turn done, once their work items and pull requests are known, so each asks to be
    /// archived before it is archived by itself.
    public func noteDoneSessions() {
        guard myWork != nil, pullRequests != nil else { return }
        let done = Set(buildSessions.filter { $0.role != .overseer && $0.role != .member && $0.archived == nil && status($0) == .done }.map(\.id))
        let next = DoneArchive.update(doneSince, done: done)
        guard next != doneSince else { return }
        doneSince = next
        defaults.set(next.mapValues(\.timeIntervalSince1970), forKey: Self.doneSinceKey)
    }

    /// What finished the session's work, for the Archive question.
    public func doneReason(_ s: WorkSession) -> String {
        let about = s.about ?? ""
        if let id = Self.number(about, "wi:") {
            let itemPRs = myWork?.items.first { $0.id == id }?.prs.map(\.id) ?? []
            if let pr = pullRequests?.closed.first(where: { $0.completed && ($0.workItems.contains(id) || itemPRs.contains($0.id)) }) {
                return "!\(pr.id) is completed."
            }
            return "#\(id) is resolved or closed."
        }
        if let id = Self.number(about, "mypr:") {
            if let c = pullRequests?.closed.first(where: { $0.id == id }) { return "!\(id) is \(c.completed ? "completed" : "abandoned")." }
            return "!\(id) is no longer open."
        }
        if let id = Self.number(about, "pr:") { return "!\(id) no longer waits for your review." }
        return "Its work is done."
    }

    /// Whether every Build session's state can be told yet: a finished one hides only once its work item or pull
    /// request has been looked up (or the lookup failed), so lists wait for that instead of showing it first.
    public var buildStatusKnown: Bool {
        let t = engine.tracker
        let workKnown = t.myWork != nil || t.myWorkError != nil
        let prsKnown = t.pullRequests != nil || t.pullRequestsError != nil
        if workKnown && prsKnown { return true }
        return !buildSessions.contains { s in
            guard s.role != .overseer, s.archived == nil, let about = s.about else { return false }
            if about.hasPrefix("wi:") { return !workKnown || !prsKnown }
            if about.hasPrefix("pr:") { return !workKnown }
            if about.hasPrefix("mypr:") { return !prsKnown }
            return false
        }
    }

    public var archivedBuildSessions: [WorkSession] {
        buildSessions.filter { $0.role != .overseer && $0.role != .member && isArchived($0) }.sorted { $0.updated > $1.updated }
    }

    /// Build sessions whose work leads to this PR, such as the one that implemented its work item.
    public func sessionsLinked(to pr: PullRequest) -> [WorkSession] {
        buildSessions.filter { $0.role != .overseer && linkedPRs($0).contains { $0.id == pr.id } }
    }

    /// The Build sessions about a pull request: its own, or one on a work item it belongs to.
    public func sessions(aboutPR id: Int) -> [WorkSession] {
        let items = Set((myWork?.items ?? []).filter { $0.prs.contains { $0.id == id } }.map(\.sessionKey))
        return buildSessions.filter { $0.about == "mypr:\(id)" || ($0.about.map(items.contains) ?? false) }
    }

    /// Asks the session that owns the PR's work to do something about it (conflicts, a failed build); a new session
    /// for the PR when none does.
    @discardableResult
    public func askAboutPR(_ pr: PullRequest, in session: WorkSession? = nil, message: String, display: String) -> WorkSession {
        if let s = session ?? sessions(forKey: pr.sessionKey).first ?? sessionsLinked(to: pr).first {
            send(message, in: s, display: display)
            show(s)
            return s
        }
        return newSession(title: "!\(pr.id) \(pr.title)", project: pr.scope.isEmpty ? nil : pr.scope, message: message,
                          display: display, about: pr.sessionKey, space: .build)
    }

    // MARK: Starting work

    /// Whether the project's repo has its own skill with this name.
    public func repoHasSkill(_ name: String, project: String) -> Bool {
        let repo = ClaudeLaunch.workingDirectory(project: engine.index.project(project), root: engine.rootURL)
        return FileManager.default.fileExists(atPath: repo.appendingPathComponent(".claude/skills/\(name)/SKILL.md").path)
    }

    /// Starts a Build session implementing a work item: guided (with questions) or fast (straight to a PR).
    @discardableResult
    public func beginImplement(_ item: MyWork.Item, fast: Bool, strategy: Strategy?, show: Bool) -> WorkSession {
        let skill = fast ? "implement-fast" : "implement"
        let ref = "work item #\(item.id) (“\(item.title)”)"
        let hasSkill = repoHasSkill(skill, project: item.project)
        var message: String
        if engine.tracker.kind(item.project) == "local" {
            let tracker = LocalTracker.load(scope: item.project, root: engine.rootURL)
            let brief = tracker.item(item.id).map(tracker.brief) ?? ref
            let done = "When it is done, move it on with `kb work set \(item.id) --state Done --scope \(item.project)` (and its tasks the same way as you finish them)."
            message = fast
                ? "Implement this end to end: plan, implement with tests, then commit on a new branch and push. I approve the commits and push for it, so keep going without stopping to ask. \(done)\n\n\(brief)"
                : "Implement this: propose a plan and ask me to approve it with choices, then implement with tests. Ask before committing or pushing. \(done)\n\n\(brief)"
        } else if hasSkill {
            message = fast
                ? "Run the `\(skill)` skill for \(ref): use the Skill tool with args `\(item.id)`. I approve the branch, commits, push and pull request it makes for this work item, so keep going without stopping to ask."
                : "Run the `\(skill)` skill for \(ref): use the Skill tool with args `\(item.id)`. Ask me with choices whenever it has a decision for me."
        } else {
            message = fast
                ? "Implement \(ref) end to end: read it (`kb tracker item \(item.id)`), plan, implement with tests, then commit on a new branch, push and open a pull request linked to it. I approve the commits, push and pull request for this work item, so keep going without stopping to ask."
                : "Implement \(ref): read it (`kb tracker item \(item.id)`), propose a plan and ask me to approve it with choices, then implement with tests. Ask before committing, pushing or opening a pull request."
        }
        if let strategy {
            message += "\n\n" + ImplementWay.strategyNote(strategy, skill: hasSkill ? skill : nil, fast: fast)
        }
        if let note = engine.tracker.markWorkStarted(item.id, scope: item.project, ref: ref) { message = note + "\n\n" + message }
        let s = newSession(title: "#\(item.id) \(item.title)", project: item.project, message: message,
                           display: "\(fast ? "Implement Fast" : "Implement") #\(item.id): \(item.title)",
                           model: strategy.flatMap { $0.leadModel.isEmpty ? nil : $0.leadModel },
                           strategy: strategy, about: item.sessionKey, show: show, space: .build)
        if !show { engine.report("Implementing #\(item.id) in Build. Click Implementing… to open it.") }
        return s
    }

    /// For an item already under way with no session here: find where it stands.
    @discardableResult
    public func continueItem(_ item: MyWork.Item) -> WorkSession {
        let pr = item.prs.first.map { " Its pull request is !\($0.id) in \($0.repo)." } ?? ""
        return newSession(title: "#\(item.id) \(item.title)", project: item.project,
                          message: "Pick up work item #\(item.id) (“\(item.title)”, state \(item.state)).\(pr) Find its branch or worktree and the pull request if there is one, and tell me in a few lines where it stands and what is next. Don't change anything yet.",
                          display: "Continue #\(item.id): \(item.title)", about: item.sessionKey, space: .build)
    }

    @discardableResult
    public func startReview(_ r: MyWork.Review) -> WorkSession {
        let message = repoHasSkill("review-pr", project: r.project)
            ? "Run the `review-pr` skill for pull request \(r.id) (“\(r.title)” by \(r.author)): use the Skill tool with args `\(r.id)`. Ask me before posting any comment or vote."
            : "Review pull request \(r.id) (“\(r.title)” by \(r.author), repo \(r.repo)): \(r.url). Summarise what it changes and list findings by severity. Ask me before posting any comment or vote."
        let learn = " When you're done, propose as facts what the pull request taught you about the codebase, as your instructions say."
        return newSession(title: "Review !\(r.id) \(r.title)", project: r.project, message: message + learn + "\n\n" + ReviewVote.askAtTheEnd(r.id),
                          display: "Review !\(r.id): \(r.title)", about: r.sessionKey, space: .build)
    }

    /// Hands the PR's open comments to Claude: in `session` when given, else in the session already on this PR,
    /// else in a new Build session.
    @discardableResult
    public func handlePRComments(_ pr: PullRequest, mode: PRCommentsMode, in session: WorkSession? = nil) -> WorkSession {
        if let s = session ?? sessions(forKey: pr.sessionKey).first ?? sessionsLinked(to: pr).first {
            send(mode.prompt(pr), in: s, display: mode.display(pr))
            show(s)
            return s
        }
        return newSession(title: "!\(pr.id) comments: \(pr.title)", project: pr.scope.isEmpty ? nil : pr.scope, message: mode.prompt(pr),
                          display: mode.display(pr), about: pr.sessionKey, space: .build)
    }
}
