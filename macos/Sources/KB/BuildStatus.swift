import KBCore
import KBEngine
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

    func linkedPRs(_ s: WorkSession) -> [PullRequest] { engine.sessions.linkedPRs(s) }

    func linkedPR(_ s: WorkSession) -> PullRequest? { engine.sessions.linkedPR(s) }

    func readyPRs(_ s: WorkSession) -> [(pr: PullRequest, session: WorkSession)] { engine.sessions.readyPRs(s) }

    var stuckPRs: [PullRequest] { engine.sessions.stuckPRs }

    var prRescueSession: WorkSession? { engine.sessions.prRescueSession }

    /// Tells the overview session when an approved PR gets stuck; `force` (My Work's button) also opens it.
    func reportStuckPRs(force: Bool = false) {
        if engine.sessions.reportStuckPRs(force: force), force {
            mode = .build
            buildSelection = nil
        }
    }

    func fixBlockers(_ pr: PullRequest, in s: WorkSession) { engine.sessions.fixBlockers(pr, in: s) }

    func isWorkDone(_ s: WorkSession) -> Bool { engine.sessions.isWorkDone(s) }

    func prProblem(_ s: WorkSession) -> PRProblem? { engine.sessions.prProblem(s) }

    func badges(_ s: WorkSession) -> SessionBadges { engine.sessions.badges(s) }

    func status(_ s: WorkSession) -> SessionStatus { engine.sessions.status(s) }

    func isArchived(_ s: WorkSession) -> Bool { engine.sessions.isArchived(s) }

    func asksToArchive(_ s: WorkSession) -> Bool { engine.sessions.asksToArchive(s) }

    func noteDoneSessions() { engine.sessions.noteDoneSessions() }

    func doneReason(_ s: WorkSession) -> String { engine.sessions.doneReason(s) }

    func setArchived(_ s: WorkSession, _ on: Bool) { engine.sessions.setArchived(s, on) }

    var buildStatusKnown: Bool { engine.sessions.buildStatusKnown }

    var archivedBuildSessions: [WorkSession] { engine.sessions.archivedBuildSessions }

    static func number(_ key: String, _ prefix: String) -> Int? { SessionHub.number(key, prefix) }
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
