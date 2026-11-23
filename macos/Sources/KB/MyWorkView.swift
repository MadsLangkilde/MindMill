import AppKit
import KBCore
import SwiftUI

/// How "Implement" starts: with questions along the way, or straight through to a pull request.
enum ImplementMode: String, CaseIterable {
    case guided, fast

    var title: String { self == .guided ? "Implement" : "Implement Fast" }
    var skill: String { self == .guided ? "implement" : "implement-fast" }
}

extension AppModel {
    func refreshMyWork(force: Bool = false) {
        guard !myWorkLoading else { return }
        if !force, let at = myWorkFetched, Date().timeIntervalSince(at) < 300 { return }
        myWorkLoading = true
        let cli = cli
        Task {
            do {
                let out = try await cli.run(["tracker", "mine", "--json"])
                myWork = try MyWork.decode(out)
                myWorkError = nil
                myWorkFetched = Date()
                groupSessionsByWork()
            } catch {
                myWorkError = error.localizedDescription
            }
            myWorkLoading = false
        }
    }

    func sessions(forKey key: String) -> [WorkSession] {
        buildSessions.filter { $0.about == key }.sorted { $0.updated > $1.updated }
    }

    private func repo(of project: String) -> URL {
        ClaudeLaunch.workingDirectory(project: index.project(project), root: rootURL)
    }

    /// Whether the project's repo has its own skill with this name.
    func repoHasSkill(_ name: String, project: String) -> Bool {
        FileManager.default.fileExists(atPath: repo(of: project).appendingPathComponent(".claude/skills/\(name)/SKILL.md").path)
    }

    /// Always asks how: the pace and the strategy. `show` opens the session in Build once it starts;
    /// from Plan it stays hidden, and the Implement button turns into "Implementing…".
    func startImplement(_ item: MyWork.Item, show: Bool) {
        implementRequest = ImplementRequest(item: item, show: show)
    }

    func beginImplement(_ item: MyWork.Item, mode: ImplementMode, strategy: Strategy?, show: Bool) {
        let ref = "work item #\(item.id) (“\(item.title)”)"
        let hasSkill = repoHasSkill(mode.skill, project: item.project)
        var message: String
        if trackerKind(item.project) == "local" {
            let tracker = LocalTracker.load(scope: item.project, root: rootURL)
            let brief = tracker.item(item.id).map(tracker.brief) ?? ref
            let done = "When it is done, move it on with `kb work set \(item.id) --state Done --scope \(item.project)` (and its tasks the same way as you finish them)."
            message = mode == .fast
                ? "Implement this end to end: plan, implement with tests, then commit on a new branch and push. I approve the commits and push for it, so keep going without stopping to ask. \(done)\n\n\(brief)"
                : "Implement this: propose a plan and ask me to approve it with choices, then implement with tests. Ask before committing or pushing. \(done)\n\n\(brief)"
        } else if hasSkill {
            message = mode == .fast
                ? "Run the `\(mode.skill)` skill for \(ref): use the Skill tool with args `\(item.id)`. I approve the branch, commits, push and pull request it makes for this work item, so keep going without stopping to ask."
                : "Run the `\(mode.skill)` skill for \(ref): use the Skill tool with args `\(item.id)`. Ask me with choices whenever it has a decision for me."
        } else {
            message = mode == .fast
                ? "Implement \(ref) end to end: read it (`kb tracker item \(item.id)`), plan, implement with tests, then commit on a new branch, push and open a pull request linked to it. I approve the commits, push and pull request for this work item, so keep going without stopping to ask."
                : "Implement \(ref): read it (`kb tracker item \(item.id)`), propose a plan and ask me to approve it with choices, then implement with tests. Ask before committing, pushing or opening a pull request."
        }
        if let strategy {
            message += "\n\n" + ImplementWay.strategyNote(strategy, skill: hasSkill ? mode.skill : nil, fast: mode == .fast)
        }
        if let note = markWorkStarted(item.id, scope: item.project, ref: ref) { message = note + "\n\n" + message }
        newSession(title: "#\(item.id) \(item.title)", project: item.project, message: message,
                   display: "\(mode.title) #\(item.id): \(item.title)",
                   model: strategy.flatMap { $0.leadModel.isEmpty ? nil : $0.leadModel },
                   strategy: strategy, about: item.sessionKey, show: show, space: .build)
        if !show { notice = "Implementing #\(item.id) in Build. Click Implementing… to open it." }
    }

    /// Moves the item to its tracker's in-progress state as work starts, so the board shows it. Returns the
    /// instruction for the session when only Claude can reach the tracker (Jira, GitHub and the like).
    @discardableResult
    func markWorkStarted(_ id: Int, scope: String, ref: String) -> String? {
        let kind = trackerKind(scope)
        switch TrackerStart.route(kind: kind) {
        case .local:
            editLocalTracker(scope) { $0.start(id) }
            return nil
        case .cli:
            let cli = cli
            Task {
                do {
                    _ = try await cli.run(["tracker", "start", String(id), "--scope", scope])
                    refreshMyWork(force: true)
                    refreshTracker(force: true)
                } catch {
                    notice = "Could not move #\(id) to in progress: \(error.localizedDescription)"
                }
            }
            return nil
        case .claude, .none:
            return TrackerStart.sessionNote(kind: kind, ref: ref)
        }
    }

    /// For an item already under way with no session here: find where it stands.
    func continueItem(_ item: MyWork.Item) {
        let pr = item.prs.first.map { " Its pull request is !\($0.id) in \($0.repo)." } ?? ""
        newSession(title: "#\(item.id) \(item.title)", project: item.project,
                   message: "Pick up work item #\(item.id) (“\(item.title)”, state \(item.state)).\(pr) Find its branch or worktree and the pull request if there is one, and tell me in a few lines where it stands and what is next. Don't change anything yet.",
                   display: "Continue #\(item.id): \(item.title)", about: item.sessionKey, space: .build)
    }

    func startReview(_ r: MyWork.Review) {
        let message = repoHasSkill("review-pr", project: r.project)
            ? "Run the `review-pr` skill for pull request \(r.id) (“\(r.title)” by \(r.author)): use the Skill tool with args `\(r.id)`. Ask me before posting any comment or vote."
            : "Review pull request \(r.id) (“\(r.title)” by \(r.author), repo \(r.repo)): \(r.url). Summarise what it changes and list findings by severity. Ask me before posting any comment or vote."
        let learn = " When you're done, propose as facts what the pull request taught you about the codebase, as your instructions say."
        newSession(title: "Review !\(r.id) \(r.title)", project: r.project, message: message + learn + "\n\n" + ReviewVote.askAtTheEnd(r.id),
                   display: "Review !\(r.id): \(r.title)", about: r.sessionKey, space: .build)
    }

    func openSession(_ s: WorkSession) {
        mode = .build
        buildSelection = s.id
    }
}

/// A card's text with its button beside it, or under it when the card is too narrow for both, so the text is
/// never squeezed and nothing is cut off.
struct AdaptiveCard<Lead: View, Info: View, Action: View>: View {
    @ViewBuilder var lead: Lead
    @ViewBuilder var info: Info
    @ViewBuilder var action: Action

    var body: some View {
        AdaptiveCardLayout {
            HStack(spacing: 0) { lead }
            VStack(alignment: .leading, spacing: 0) { info }
            HStack(spacing: 0) { action }
        }
    }
}

enum MyWorkTab: String, CaseIterable {
    case new, inProgress, inPR, review

    var title: String {
        switch self {
        case .new: return "New"
        case .inProgress: return "In progress"
        case .inPR: return "In PR"
        case .review: return "To review"
        }
    }
}

struct MyWorkView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("myWorkCurrentSprintOnly") private var sprintOnly = true
    @AppStorage("myWorkTab") private var tab = MyWorkTab.new.rawValue
    @State private var width: CGFloat = 800

    var body: some View {
        let current = MyWorkTab(rawValue: tab) ?? .new
        VStack(spacing: 0) {
            header(current)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = model.myWorkError, model.myWork == nil {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if let work = model.myWork {
                        content(current, work)
                    } else {
                        ProgressView("Asking Azure DevOps…").frame(maxWidth: .infinity).padding(.top, 30)
                    }
                }
                .padding(18)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("My Work")
        .onAppear {
            model.refreshMyWork()
            model.refreshPullRequests()
            model.refreshDonePRs()
        }
    }

    private func header(_ current: MyWorkTab) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("My Work").font(.title2.weight(.semibold)).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                Button {
                    model.refreshMyWork(force: true)
                    model.refreshPullRequests(force: true)
                    model.refreshDonePRs(force: true)
                } label: {
                    if model.myWorkLoading || model.pullRequestsLoading || model.donePRsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh from Azure DevOps")
            }
            if !updated.isEmpty {
                Text(updated).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            FlowLayout(spacing: 6) {
                ForEach(MyWorkTab.allCases, id: \.self) { t in
                    tabButton(t, selected: t == current)
                }
            }
            if current == .new || current == .inProgress {
                Picker("Sprint", selection: $sprintOnly) {
                    Text("This Sprint").tag(true)
                    Text("All").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ListSearchField(key: .myWork, prompt: "Search my work", inset: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var query: String { model.listQuery(.myWork) }

    private func items(_ work: MyWork, _ stage: MyWork.Stage, currentSprintOnly: Bool) -> [MyWork.Item] {
        let all = work.items(stage, currentSprintOnly: currentSprintOnly)
        return query.isEmpty ? all : all.filter { $0.matches(query) }
    }

    private func reviews(_ work: MyWork) -> [MyWork.Review] {
        query.isEmpty ? work.reviews : work.reviews.filter { $0.matches(query) }
    }

    private var donePRs: [CompletedPRs.PR] {
        let all = model.donePRs?.prs ?? []
        return query.isEmpty ? all : all.filter { $0.matches(query) }
    }

    private func tabButton(_ t: MyWorkTab, selected: Bool) -> some View {
        let n = count(t)
        let attention = t == .inPR && readyCount > 0
        return Button {
            tab = t.rawValue
        } label: {
            HStack(spacing: 5) {
                Text(t.title).lineLimit(1)
                Text("\(n)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(selected ? Color.white : (attention ? Color.white : Color.secondary))
                    .frame(minWidth: 16, minHeight: 16)
                    .background(selected ? Color.white.opacity(0.25) : (attention ? Color.green : Color.secondary.opacity(0.15)), in: Capsule())
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(selected ? Color.white : .primary)
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help(t))
    }

    private func help(_ t: MyWorkTab) -> String {
        switch t {
        case .new: return "Assigned to you and not started"
        case .inProgress: return "Under way, no pull request yet"
        case .inPR: return readyCount > 0 ? "\(readyCount) ready to complete" : "Open pull requests, and merged ones still to clean up"
        case .review: return "Pull requests waiting for your review"
        }
    }

    private var updated: String {
        var s = ""
        if let at = model.myWorkFetched { s = "updated \(RelativeTime.short(at)) ago".replacingOccurrences(of: "now ago", with: "just now") }
        if let e = model.myWorkError, model.myWork != nil { s += " · refresh failed: \(e)" }
        return s
    }

    private var readyCount: Int { (model.pullRequests?.prs ?? []).filter { $0.canComplete && !$0.draft }.count }

    private func count(_ t: MyWorkTab) -> Int {
        guard let work = model.myWork else { return 0 }
        switch t {
        case .new: return items(work, .notStarted, currentSprintOnly: sprintOnly).count
        case .inProgress: return items(work, .inProgress, currentSprintOnly: sprintOnly).count
        case .inPR: return items(work, .inPR, currentSprintOnly: false).count + loosePRs(work).count + donePRs.count
        case .review: return reviews(work).count
        }
    }

    /// Your open pull requests that none of your work items lists.
    private func loosePRs(_ work: MyWork) -> [PullRequest] {
        let linked = Set(work.items.flatMap { $0.prs.map(\.id) })
        return (model.pullRequests?.prs ?? []).filter { !linked.contains($0.id) && (query.isEmpty || $0.matches(query)) }
    }

    @ViewBuilder
    private func content(_ t: MyWorkTab, _ work: MyWork) -> some View {
        switch t {
        case .new:
            rows(items(work, .notStarted, currentSprintOnly: sprintOnly),
                 empty: !query.isEmpty ? noMatch : sprintOnly ? "Nothing new in this sprint." : "Nothing waits to be started.")
        case .inProgress:
            rows(items(work, .inProgress, currentSprintOnly: sprintOnly),
                 empty: !query.isEmpty ? noMatch : sprintOnly ? "Nothing in progress in this sprint." : "Nothing in progress.")
        case .inPR:
            let stuck = model.stuckPRs
            if !stuck.isEmpty {
                AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 200) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.orange).font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(stuck.count) approved PR\(stuck.count == 1 ? " is" : "s are") stuck").font(.callout.weight(.semibold))
                        Text(stuck.map { "!\($0.id): \($0.blockers.joined(separator: ", ").lowercased())" }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if let rescue = model.prRescueSession {
                            Button("Open the Session") { model.openSession(rescue) }
                        } else {
                            Button("Fix Them All…") { model.reportStuckPRs(force: true) }
                                .buttonStyle(.borderedProminent)
                                .help("The overview session asks you, then one session untangles them, fixes builds and conflicts, and completes them")
                        }
                    }
                    .fixedSize()
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            let items = items(work, .inPR, currentSprintOnly: false)
            let loose = loosePRs(work)
            let done = donePRs
            if items.isEmpty && loose.isEmpty && done.isEmpty {
                empty(!query.isEmpty ? noMatch : "No open pull requests, and nothing to clean up.")
            }
            if !items.isEmpty {
                VStack(spacing: 8) { ForEach(items) { WorkItemRow(item: $0) } }
            }
            if !loose.isEmpty {
                group("Without a work item", count: loose.count) {
                    ForEach(loose) { pr in
                        PullRequestRow(pr: pr, card: true)
                            .onTapGesture { model.openPRInBuild(pr.id) }
                    }
                }
            }
            if !done.isEmpty {
                group("Merged · to clean up", count: done.count, accessory: done.count > 1 ? AnyView(
                    Button("Clean Up All…") { model.bulkCleanupRequest = BulkCleanupRequest(prs: done) }
                        .controlSize(.small)
                        .help("Remove the worktrees and branches of every merged pull request here, and archive their sessions")
                ) : nil) {
                    ForEach(done) { CleanupRow(pr: $0) }
                }
            }
        case .review:
            let reviews = reviews(work)
            if reviews.isEmpty { empty(!query.isEmpty ? noMatch : "Nothing waits for your review.") }
            VStack(spacing: 8) { ForEach(reviews) { ReviewRow(review: $0) } }
        }
    }

    private var noMatch: String { "Nothing in this tab matches “\(query)”." }

    @ViewBuilder
    private func rows(_ items: [MyWork.Item], empty text: String) -> some View {
        if items.isEmpty { empty(text) }
        VStack(spacing: 8) { ForEach(items) { WorkItemRow(item: $0) } }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func group<C: View>(_ title: String, count: Int, accessory: AnyView? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(title.uppercased()) · \(count)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let accessory { accessory }
            }
            VStack(spacing: 8) { content() }
        }
        .padding(.top, 6)
    }
}

/// A merged pull request with a worktree or branch left behind.
struct CleanupRow: View {
    @Environment(AppModel.self) private var model
    let pr: CompletedPRs.PR

    var body: some View {
        AdaptiveCard {
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green).frame(width: 24)
        } info: {
            VStack(alignment: .leading, spacing: 3) {
                Text(pr.title).font(.body.weight(.medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text("!\(String(pr.id)) · merged \(pr.closed.prefix(10))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ChipRow(spacing: 6) {
                    ForEach(pr.leftovers, id: \.self) { Chip(text: $0, color: .gray) }
                }
            }
        } action: {
            Button("Clean Up…") { model.prCleanupRequest = pr }
                .help("Remove its worktree and branches, and archive its sessions")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// How a work item's pull request stands, with Complete when it is ready.
struct PRStatusLine: View {
    @Environment(AppModel.self) private var model
    let ref: MyWork.PR

    var body: some View {
        let pr = model.pullRequests?.pr(ref.id)
        ChipRow(spacing: 6) {
            Link(destination: URL(string: ref.url)!) {
                Label("!\(String(ref.id))", systemImage: "arrow.triangle.pull")
            }
            .font(.caption)
            if let pr {
                if pr.draft {
                    Chip(text: "Draft", color: .blue)
                } else if pr.canComplete {
                    Chip(text: "Ready to complete", color: .green)
                    Button("Complete…") { model.completePRRequest = CompletePRRequest(id: pr.id) }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)
                } else if let waiting = WorkItemTurn.waitingOnOthers(pr) {
                    Text("\(waiting) · nothing for you to do").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(pr.blockers.first ?? "In review").font(.caption).foregroundStyle(pr.openThreads > 0 ? Color.purple : .orange)
                }
                Button("Open") { model.openPRInBuild(pr.id) }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

/// One PBI or bug: what it is, where it stands, and the one thing to do next.
struct WorkItemRow: View {
    @Environment(AppModel.self) private var model
    let item: MyWork.Item

    var body: some View {
        let session = model.sessions(forKey: item.sessionKey).first
        AdaptiveCard {
            Image(systemName: item.isBug ? "ladybug.fill" : "doc.text.fill")
                .font(.title3)
                .foregroundStyle(item.isBug ? Color.red : Color.blue)
                .frame(width: 24)
        } info: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                ChipRow(spacing: 6) {
                    Text("#\(String(item.id))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Chip(text: item.state, color: item.state == "Blocked" ? .orange : .gray)
                    if !item.sprintName.isEmpty { Text(item.sprintName).font(.caption).foregroundStyle(.secondary) }
                    if model.index.projects.count > 1 { ProjectChip(project: item.project) }
                }
                ForEach(item.prs) { PRStatusLine(ref: $0) }
            }
        } action: {
            if let session {
                ImplementingButton(session: session, pr: item.prs.lazy.compactMap { model.pullRequests?.pr($0.id) }.first)
            } else if item.stage == .notStarted {
                ImplementButton(item: item, show: true)
            } else {
                Button("Continue") { model.continueItem(item) }
                    .help("Open a session that finds the branch and PR and tells you where it stands")
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(session?.crewState.needsUser == true ? 0 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(session?.crewState.needsUser == true ? 0.6 : 0)))
        .contextMenu {
            Button("Open in Azure DevOps") { NSWorkspace.shared.open(URL(string: item.url)!) }
            Button("Copy ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(item.id), forType: .string)
            }
            Divider()
            if session == nil { Button("Implement…") { model.startImplement(item, show: true) } }
            Button("Continue in a New Session") { model.continueItem(item) }
            if let s = session {
                Divider()
                Button("Open Session") { model.openSession(s) }
            }
        }
    }
}

/// "Implement…": asks how (pace and strategy), then starts. Once a session works on the item it reads
/// "Implementing…" and opens that session in Build.
struct ImplementButton: View {
    @Environment(AppModel.self) private var model
    let item: MyWork.Item
    /// Open the session in Build when it starts; false from Plan.
    let show: Bool

    var body: some View {
        if let session = model.sessions(forKey: item.sessionKey).first {
            ImplementingButton(session: session, pr: item.prs.lazy.compactMap { model.pullRequests?.pr($0.id) }.first)
        } else {
            Button { model.startImplement(item, show: show) } label: { Label("Implement…", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .help("Choose the pace and the strategy, then start")
        }
    }
}

/// A work item's session: "Implementing…" while it works, what it needs from you, or Open Session when it waits
/// on reviewers or has stopped. Opens it in Build.
struct ImplementingButton: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession
    var pr: PullRequest? = nil

    var body: some View {
        let state = session.crewState
        let turn = WorkItemTurn.of(state, pr: pr)
        Button { model.openSession(session) } label: {
            HStack(spacing: 6) {
                if turn == .implementing { ProgressView().controlSize(.mini) } else { StateDot(state: state) }
                Text(turn.buttonTitle)
                Image(systemName: "chevron.right").font(.caption2)
            }
        }
        .fixedSize()
        .help(help(turn))
    }

    private func help(_ turn: WorkItemTurn) -> String {
        switch turn {
        case .implementing: return "“\(session.title)” is working on it. Open it in Build."
        case .needsYou: return "“\(session.title)” needs you. Open it in Build."
        case .waitingForOthers(let line): return "\(line). Nothing waits on you; the session is archived when the PR completes."
        case .paused: return "“\(session.title)” isn't working right now. Open it in Build to carry on."
        }
    }
}

/// The session working on something: its state, one click away.
struct SessionLinkButton: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession

    var body: some View {
        let state = session.crewState
        Button {
            model.openSession(session)
        } label: {
            HStack(spacing: 6) {
                StateDot(state: state)
                Text(state == .working ? (session.chat.activity.map { String($0.prefix(28)) } ?? "Working") : state.label)
                    .lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2)
            }
        }
        .help("Open the session “\(session.title)”")
    }
}

struct ReviewRow: View {
    @Environment(AppModel.self) private var model
    let review: MyWork.Review

    var body: some View {
        let session = model.sessions(forKey: review.sessionKey).first
        AdaptiveCard {
            Image(systemName: "arrow.triangle.pull").font(.title3).foregroundStyle(.purple).frame(width: 24)
        } info: {
            VStack(alignment: .leading, spacing: 4) {
                Text(review.title).font(.body.weight(.medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text("!\(String(review.id)) · \(review.author) · \(review.repo)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ChipRow(spacing: 6) {
                    if review.required { Chip(text: "Required", color: .orange) } else if review.assigned { Chip(text: "Reviewer", color: .purple) }
                    Link("Open in Azure DevOps", destination: URL(string: review.url)!).font(.caption)
                }
            }
        } action: {
            if let session {
                SessionLinkButton(session: session)
            } else {
                Button {
                    model.startReview(review)
                } label: {
                    Label("Review", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .help("Opens a session that reviews it with you; nothing is posted without your yes")
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ImplementRequest: Identifiable {
    let id = UUID()
    let item: MyWork.Item
    var show = true
}

/// Asks how to implement a work item: the pace, then the strategy. Strategies have details with a diagram;
/// your own can be edited or deleted, and new ones made, right here.
struct ImplementSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ImplementRequest
    @State private var mode: ImplementMode = .guided
    @State private var way = ImplementWay.oneSession
    @State private var details: StrategySlug?
    @State private var editing: StrategyEditorRequest?
    @State private var deleting: Strategy?
    @AppStorage("implementMode") private var lastMode = ImplementMode.guided.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Implement #\(String(request.item.id))").font(.title2.weight(.semibold))
            Text(request.item.title).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Pace").font(.headline)
                Picker("Pace", selection: $mode) {
                    Text("Ask me along the way").tag(ImplementMode.guided)
                    Text("Fast, straight to a PR").tag(ImplementMode.fast)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text("Strategy").font(.headline)
            ScrollView {
                VStack(spacing: 8) {
                    card(nil)
                    ForEach(model.strategies.filter(\.isBuiltIn)) { card($0) }
                    let own = model.strategies.filter { !$0.isBuiltIn }
                    if !own.isEmpty {
                        Text("Yours").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        ForEach(own) { card($0) }
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 360)
            Button { editing = .new } label: { Label("New Strategy…", systemImage: "plus") }
                .help("Define your own way of working: which sessions the lead starts, their models, and who reviews when")
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.show ? "Start" : "Start in the Background") { start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            mode = ImplementMode(rawValue: lastMode) ?? .guided
            let last = UserDefaults.standard.string(forKey: ImplementWay.lastKey)
            way = last.flatMap { l in l == ImplementWay.oneSession || model.strategies.contains { $0.slug == l } ? l : nil }
                ?? ImplementWay.oneSession
        }
        .sheet(item: $details) { StrategyDetailsSheet(slug: $0.id) }
        .sheet(item: $editing) { StrategyEditorSheet(request: $0) }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let d = deleting {
                    if way == d.slug { way = ImplementWay.oneSession }
                    model.deleteStrategy(d)
                }
                deleting = nil
            }
        } message: {
            Text("Sessions already using it keep their instructions.")
        }
    }

    private func card(_ st: Strategy?) -> some View {
        let tag = st?.slug ?? ImplementWay.oneSession
        let selected = way == tag
        let summary = st?.summary ?? (model.repoHasSkill(mode.skill, project: request.item.project)
            ? "Runs /\(mode.skill) in a single session. Its helpers work inside it and don't show as sessions."
            : "One \(Brain.name) session does all of it.")
        return HStack(alignment: .top, spacing: 10) {
            Button { way = tag } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Image(systemName: st == nil ? "bubble.left.and.text.bubble.right" : st?.spawns == true ? "person.3.fill" : "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        ChipRow(spacing: 6) {
                            Text(st?.title ?? "One session").font(.callout.weight(.semibold)).fixedSize()
                            if let st, st.spawns { Chip(text: "Sessions under it", color: .purple) }
                        }
                        Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let st { StrategyMiniFlow(strategy: st) }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let st {
                VStack(alignment: .trailing, spacing: 4) {
                    Button { details = StrategySlug(id: st.slug) } label: { Image(systemName: "info.circle") }
                        .help("How it works, with a diagram")
                    if !st.isBuiltIn {
                        Button { editing = .edit(st) } label: { Image(systemName: "pencil") }.help("Edit")
                        Button(role: .destructive) { deleting = st } label: { Image(systemName: "trash") }.help("Delete")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(selected ? 0.4 : 0.15)))
    }

    private func start() {
        UserDefaults.standard.set(way, forKey: ImplementWay.lastKey)
        lastMode = mode.rawValue
        model.beginImplement(request.item, mode: mode, strategy: model.strategies.first { $0.slug == way }, show: request.show)
        dismiss()
    }
}

struct StrategySlug: Identifiable {
    let id: String
}
