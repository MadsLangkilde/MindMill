import KBCore
import SwiftUI

extension AppModel {
    func refreshDonePRs(force: Bool = false) {
        guard !donePRsLoading else { return }
        if !force, donePRs != nil { return }
        donePRsLoading = true
        let cli = cli
        Task {
            if let out = try? await cli.run(["pr", "done", "--json"]), let list = try? CompletedPRs.decode(out) {
                donePRs = list
                autoCleanUp(list)
            }
            donePRsLoading = false
        }
    }

    /// The open pull requests of the work a session is about: its own PR, or the PRs of its work item.
    func linkedPRs(_ s: WorkSession) -> [PullRequest] {
        guard let about = s.about, let list = pullRequests else { return [] }
        if let id = Self.number(about, "mypr:") { return list.pr(id).map { [$0] } ?? [] }
        if let id = Self.number(about, "wi:"), let item = myWork?.items.first(where: { $0.id == id }) {
            return item.prs.compactMap { list.pr($0.id) }
        }
        return []
    }

    func linkedPR(_ s: WorkSession) -> PullRequest? { linkedPRs(s).first }

    /// The pull requests that can be completed now: the session's own and, for a lead, those of the sessions under
    /// it, each with the session that made it.
    func readyPRs(_ s: WorkSession) -> [(pr: PullRequest, session: WorkSession)] {
        let from = s.role == .lead ? [s] + members(of: s) : [s]
        var seen = Set<Int>()
        return from.flatMap { m in linkedPRs(m).map { (pr: $0, session: m) } }
            .filter { $0.pr.canComplete && !$0.pr.draft && seen.insert($0.pr.id).inserted }
    }

    static let stuckPRsReportedKey = "stuckPRsReported"

    /// Approved pull requests held up by a failed or stuck build or merge conflicts.
    var stuckPRs: [PullRequest] { PRRescue.blocked(pullRequests?.prs ?? []) }

    /// The session working through the stuck PRs, while it isn't archived.
    var prRescueSession: WorkSession? {
        buildSessions.first { $0.title == "Complete approved PRs" && !isArchived($0) }
    }

    /// Tells the overview session when an approved PR gets stuck, so the user can have them all fixed from there.
    /// Once per PR joining the list; `force` reports the current list now (My Work's button).
    func reportStuckPRs(force: Bool = false) {
        guard backgroundStarted || force else { return }
        let stuck = stuckPRs
        let last = Set(UserDefaults.standard.array(forKey: Self.stuckPRsReportedKey) as? [Int] ?? [])
        UserDefaults.standard.set(stuck.map(\.id), forKey: Self.stuckPRsReportedKey)
        guard !stuck.isEmpty, force || (PRRescue.shouldReport(stuck, lastReported: last) && prRescueSession == nil) else { return }
        deliver(PRRescue.report(stuck), to: ensureOverseer(), from: "the Mindmill app")
        if force {
            mode = .build
            buildSelection = nil
        } else {
            notice = "\(stuck.count) approved PR\(stuck.count == 1 ? " is" : "s are") stuck. The overview session asks what to do."
        }
    }

    /// Asks the session to clear what keeps its approved pull request from completing.
    func fixBlockers(_ pr: PullRequest, in s: WorkSession) {
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
    /// Unknown until Azure DevOps has answered, and never while the session runs.
    func isWorkDone(_ s: WorkSession) -> Bool {
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
    func prProblem(_ s: WorkSession) -> PRProblem? {
        guard s.role != .member, ![.draft, .done].contains(status(s)) else { return nil }
        return PRProblem.shown(linkedPR(s).flatMap(PRProblem.of), status: status(s))
    }

    /// What the session is doing, and where its work item or pull request stands, for the row and the header.
    func badges(_ s: WorkSession) -> SessionBadges {
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
        let pr = linkedPR(s).map(prState)
        // A PR or item that has left the open lists is finished, even before the session counts as done.
        let gone = known && pr == nil && item == nil && !reviewing
        var badges = SessionBadges.of(s.crewState, linked: linked, known: known, pr: pr, item: item,
                                      workDone: isWorkDone(s) || gone)
        if reviewing, badges.work == nil { badges.work = .inReview }
        return badges
    }

    private func prState(_ pr: PullRequest) -> SessionStatus.PRState {
        SessionStatus.PRState(canComplete: pr.canComplete, openThreads: pr.openThreads, draft: pr.draft,
                              approved: pr.approvals > 0 && pr.rejections == 0 && !pr.reviewers.contains { $0.vote == -5 },
                              autoComplete: pr.autoComplete, building: pr.waitingForChecks,
                              buildQueued: pr.buildQueuedOnly)
    }

    func status(_ s: WorkSession) -> SessionStatus {
        let pr = s.role == .member ? nil : linkedPR(s).map(prState)
        return SessionStatus.of(s.crewState, pr: pr, workDone: isWorkDone(s))
    }

    /// Archived by the user, or done by itself unless the user kept it. A session that needs the user never hides.
    func isArchived(_ s: WorkSession) -> Bool {
        if s.chat.isBusy || s.crewState.needsUser { return false }
        if let lead = s.parentID.flatMap({ session($0) }), s.role == .member, isArchived(lead) { return true }
        return s.archived ?? (status(s) == .done && DoneArchive.autoArchived(doneSince: sessionsDoneSince?[s.id]))
    }

    /// Done and not yet archived or kept: the session asks whether to archive it.
    func asksToArchive(_ s: WorkSession) -> Bool {
        s.role != .overseer && s.role != .member && s.archived == nil && !isArchived(s) && status(s) == .done
    }

    /// Notes when sessions turn done, once their work items and pull requests are known, so each asks to be
    /// archived before it is archived by itself.
    func noteDoneSessions() {
        guard myWork != nil, pullRequests != nil else { return }
        let done = Set(buildSessions.filter { $0.role != .overseer && $0.role != .member && $0.archived == nil && status($0) == .done }.map(\.id))
        let next = DoneArchive.update(sessionsDoneSince, done: done)
        guard next != sessionsDoneSince else { return }
        sessionsDoneSince = next
        UserDefaults.standard.set(next.mapValues(\.timeIntervalSince1970), forKey: Self.doneSinceKey)
    }

    /// What finished the session's work, for the Archive question.
    func doneReason(_ s: WorkSession) -> String {
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

    func setArchived(_ s: WorkSession, _ on: Bool) {
        s.archived = on
        for m in members(of: s) { m.archived = on }
        saveSessions()
    }

    /// Whether every Build session's state can be told yet: a finished one hides only once its work item or pull
    /// request has been looked up (or the lookup failed), so lists wait for that instead of showing it first.
    var buildStatusKnown: Bool {
        let workKnown = myWork != nil || myWorkError != nil
        let prsKnown = pullRequests != nil || pullRequestsError != nil
        if workKnown && prsKnown { return true }
        return !buildSessions.contains { s in
            guard s.role != .overseer, s.archived == nil, let about = s.about else { return false }
            if about.hasPrefix("wi:") { return !workKnown || !prsKnown }
            if about.hasPrefix("pr:") { return !workKnown }
            if about.hasPrefix("mypr:") { return !prsKnown }
            return false
        }
    }

    var archivedBuildSessions: [WorkSession] {
        buildSessions.filter { $0.role != .overseer && $0.role != .member && isArchived($0) }.sorted { $0.updated > $1.updated }
    }

    static func number(_ key: String, _ prefix: String) -> Int? {
        key.hasPrefix(prefix) ? Int(key.dropFirst(prefix.count)) : nil
    }
}

/// The session's status as a coloured label; it pulses while the session needs the user.
struct StatusPill: View {
    let status: SessionStatus
    var compact = false

    var body: some View {
        Pulsing(active: status.needsUser) { pulse in
            Text(status.label)
                .font((compact ? Font.caption2 : .caption).weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .foregroundStyle(Self.foreground(status))
                .background(Self.color(status).opacity(status.needsUser ? (pulse ? 0.95 : 0.55) : 0.16), in: Capsule())
                .scaleEffect(pulse ? 1.06 : 1)
        }
    }

    static func color(_ s: SessionStatus) -> Color {
        switch s {
        case .needsInput, .needsPermission: return .orange
        case .running: return .green
        case .readyToComplete, .completing: return .green
        case .building, .buildQueued: return .mint
        case .comments: return .purple
        case .approved: return .mint
        case .inReview, .draft, .inPR: return .blue
        case .inProgress: return .indigo
        case .resolved: return .green
        case .idle: return .teal
        case .notStarted, .checking, .notRunning, .done: return .gray
        }
    }

    static func foreground(_ s: SessionStatus) -> Color {
        s.needsUser ? .white : ([.notRunning, .done, .checking, .notStarted].contains(s) ? .secondary : color(s))
    }
}

/// What holds up the session's pull request, beside its status; it pulses while it needs fixing.
struct ProblemPill: View {
    let problem: PRProblem
    var compact = false

    var body: some View {
        let color: Color = problem.needsFixing ? .red : .orange
        Pulsing(active: problem.needsFixing) { pulse in
            Label(problem.label, systemImage: problem.icon)
                .font((compact ? Font.caption2 : .caption).weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .foregroundStyle(problem.needsFixing ? .white : color)
                .background(color.opacity(problem.needsFixing ? (pulse ? 0.95 : 0.55) : 0.16), in: Capsule())
        }
    }
}

/// What the session is doing, where its work stands, and what holds up its PR, as separate pills.
struct SessionBadgePills: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession
    let badges: SessionBadges
    var compact = false

    var body: some View {
        if let activity = badges.activity { StatusPill(status: activity, compact: compact) }
        if let work = badges.work {
            StatusPill(status: work, compact: compact)
                .help(workHelp(work))
        }
        if let problem = model.prProblem(session) { ProblemPill(problem: problem, compact: compact) }
    }

    private func workHelp(_ work: SessionStatus) -> String {
        if let pr = model.linkedPR(session) { return "!\(pr.id): \(work.label)" }
        if let id = AppModel.number(session.about ?? "", "wi:") { return "#\(id): \(work.label)" }
        return work.label
    }
}

/// A session's readable title, with what it is about and when underneath, and its status.
struct SessionTitleBlock: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession
    var detail: String?
    var bold = false
    var showScope = true

    var body: some View {
        let split = SessionTitle.split(session.title)
        let badges = model.badges(session)
        VStack(alignment: .leading, spacing: 2) {
            Text(split.text)
                .font(.callout.weight(bold ? .semibold : .regular))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            ChipRow(spacing: 5) {
                SessionBadgePills(session: session, badges: badges, compact: true)
                Text(caption(ref: split.ref, running: badges.activity == .running))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(badges.needsUser ? .orange : .secondary).lineLimit(2)
            }
        }
    }

    private func caption(ref: String?, running: Bool) -> String {
        var parts: [String] = []
        if running, let a = session.chat.activity { return a }
        if let ref { parts.append(ref) }
        if showScope, session.role != .member, let p = session.project.flatMap({ model.index.project($0)?.title }) { parts.append(p) }
        parts.append(RelativeTime.short(session.stateSince > session.updated ? session.stateSince : session.updated))
        return parts.joined(separator: " · ")
    }
}
