import AppKit
import KBCore
import SwiftUI

struct CompletePRRequest: Identifiable, Equatable {
    let id: Int
}

/// The open comments on a PR, in a sheet; `session` is the Build session it was opened from.
struct PRCommentsRequest: Identifiable, Equatable {
    let id: Int
    var session: String?
}

extension AppModel {
    func refreshPullRequests(force: Bool = false) {
        startPullRequestTimer()
        guard !pullRequestsLoading else { return }
        if !force, let at = pullRequestsFetched, Date().timeIntervalSince(at) < 120 { return }
        pullRequestsLoading = true
        let cli = cli
        Task {
            do {
                let before = Set(pullRequests?.prs.map(\.id) ?? [])
                pullRequests = try PullRequestList.decode(try await cli.run(["pr", "list", "--json"]))
                // One left the open list: it may have been merged, so look for what it left behind.
                if PRAutoCleanup.isOn, !before.subtracting(pullRequests?.prs.map(\.id) ?? []).isEmpty {
                    refreshDonePRs(force: true)
                }
                pullRequestsError = nil
                pullRequestsFetched = Date()
                groupSessionsByWork()
                reportStuckPRs()
                askFinishedSessions()
                retryExpiredBuilds()
            } catch {
                pullRequestsError = error.localizedDescription
            }
            pullRequestsLoading = false
        }
    }

    /// Runs an expired build again, as Azure DevOps's "Re-queue" does: at most once every 15 minutes per pull
    /// request, so a build that keeps expiring isn't requeued in a loop.
    func retryExpiredBuilds() {
        let now = Date()
        let due = (pullRequests?.prs ?? []).filter { pr in
            pr.buildExpired && !pr.draft && expiredBuildRetries[pr.id].map { now.timeIntervalSince($0) > 900 } ?? true
        }
        guard !due.isEmpty else { return }
        for pr in due { expiredBuildRetries[pr.id] = now }
        let cli = cli
        Task {
            var done: [Int] = []
            for pr in due {
                do {
                    _ = try await cli.run(["pr", "checks", String(pr.id), "--requeue-expired", "--log-lines", "0"])
                    done.append(pr.id)
                } catch {
                    notice = "Could not run the expired build of !\(pr.id) again: \(error.localizedDescription)"
                }
            }
            guard !done.isEmpty else { return }
            notice = "The build of " + done.map { "!\($0)" }.joined(separator: ", ") + " had expired. Mindmill queued it again."
            try? await Task.sleep(for: .seconds(15))
            refreshPullRequests(force: true)
        }
    }

    /// Every three minutes while Build is in front, so merged PRs and finished builds show without Sync.
    private func startPullRequestTimer() {
        guard pullRequestTimer == nil else { return }
        pullRequestTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSApp.isActive, self.mode == .build else { return }
                self.refreshPullRequests(force: true)
                self.refreshMyWork()
            }
        }
    }

    func loadPRDetail(_ id: Int) {
        guard !prDetailLoading.contains(id) else { return }
        prDetailLoading.insert(id)
        let cli = cli
        Task {
            do {
                let pr = try JSONDecoder().decode(PullRequest.self, from: Data(try await cli.run(["pr", "show", String(id), "--json"]).utf8))
                prDetails[id] = pr
                if var list = pullRequests, let i = list.prs.firstIndex(where: { $0.id == id }) {
                    var brief = pr
                    brief.threads = nil
                    brief.description = nil
                    list.prs[i] = brief
                    pullRequests = list
                }
            } catch {
                errorMessage = "Could not read pull request !\(id): \(error.localizedDescription)"
            }
            prDetailLoading.remove(id)
        }
    }

    /// The PR as fully as it is known: with threads once read, else the list's summary.
    func pullRequest(_ id: Int) -> PullRequest? { prDetails[id] ?? pullRequests?.pr(id) }

    private func prAction(_ id: Int, _ args: [String], stdin: String? = nil, done: String, refreshAll: Bool = false,
                          then: (() -> Void)? = nil) {
        prBusy.insert(id)
        let cli = cli
        Task {
            do {
                _ = try await cli.run(args, stdin: stdin)
                notice = done
                then?()
                loadPRDetail(id)
                if refreshAll {
                    refreshPullRequests(force: true)
                    refreshTracker(force: true)
                    if myWork != nil { refreshMyWork(force: true) }
                }
            } catch {
                errorMessage = (error as? KBCLIError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription
            }
            prBusy.remove(id)
        }
    }

    func replyToThread(pr: Int, thread: Int, text: String, resolve: Bool) {
        var args = ["pr", "reply", String(pr), String(thread)]
        if resolve { args += ["--status", "fixed"] }
        prAction(pr, args, stdin: text, done: resolve ? "Replied and resolved." : "Replied.")
    }

    /// A new comment thread on the pull request.
    func commentOnPR(_ pr: Int, text: String) {
        prAction(pr, ["pr", "comment", String(pr)], stdin: text, done: "Commented.")
    }

    func setThreadStatus(pr: Int, thread: Int, status: String) {
        prAction(pr, ["pr", "thread", String(pr), String(thread), "--status", status],
                 done: "Comment is now \(PullRequest.threadStatusTitle(status).lowercased()).")
    }

    func completePR(_ id: Int, strategy: String, deleteBranch: Bool, completeWorkItems: Bool, message: String, auto: Bool) {
        var args = ["pr", "complete", String(id), "--strategy", strategy, deleteBranch ? "--delete-branch" : "--keep-branch"]
        if completeWorkItems { args.append("--complete-work-items") }
        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args += ["--message", message] }
        if auto { args.append("--auto") }
        prAction(id, args, done: auto ? "!\(id) completes by itself when its checks pass." : "!\(id) completed.", refreshAll: true) { [weak self] in
            guard !auto else { return }
            self?.offerCleanup(id)
        }
    }

    func cancelAutoComplete(_ id: Int) {
        prAction(id, ["pr", "complete", String(id), "--cancel-auto"], done: "Auto-complete cancelled on !\(id).", refreshAll: true)
    }

    /// Hands the PR's open comments to Claude: in `session` when given, else in the session already on this PR,
    /// else in a new Build session.
    func handlePRComments(_ pr: PullRequest, mode: PRCommentsMode, in session: WorkSession? = nil) {
        if let s = session ?? sessions(forKey: pr.sessionKey).first ?? sessionsLinked(to: pr).first {
            send(mode.prompt(pr), in: s, display: mode.display(pr))
            openSession(s)
            return
        }
        newSession(title: "!\(pr.id) comments: \(pr.title)", project: pr.scope.isEmpty ? nil : pr.scope, message: mode.prompt(pr),
                   display: mode.display(pr), about: pr.sessionKey, space: .build)
    }

    /// Build sessions whose work leads to this PR, such as the one that implemented its work item.
    func sessionsLinked(to pr: PullRequest) -> [WorkSession] {
        buildSessions.filter { $0.role != .overseer && linkedPRs($0).contains { $0.id == pr.id } }
    }

    func openPRInBuild(_ id: Int) {
        mode = .build
        buildSelection = "pr:\(id)"
    }

    func selectPR(_ id: Int?) {
        navigate { [self] in
            multiSelection = []
            closeDocument()
            selectedPR = id
        }
    }

    func setTasks(_ ids: [Int], state: String) {
        guard !ids.isEmpty else { return }
        busyTasks.formUnion(ids)
        let cli = cli
        Task {
            do {
                _ = try await cli.run(["tracker", "task-state"] + ids.map(String.init) + ["--state", state])
                tracker = tracker?.settingTasks(Set(ids), to: state)
                notice = ids.count == 1 ? "Task #\(ids[0]) is now \(state)." : "\(ids.count) tasks are now \(state)."
                refreshTracker(force: true)
            } catch {
                errorMessage = (error as? KBCLIError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription
            }
            busyTasks.subtract(ids)
        }
    }
}

// MARK: List

/// Plan's Pull Requests: your active PRs, what blocks each, and comments waiting.
struct PullRequestsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.pullRequests.map { "\($0.prs.count) open" } ?? "Pull requests").font(.headline).lineLimit(1)
                if let at = model.pullRequestsFetched {
                    Text("updated \(MeetingController.clock(at))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { model.refreshPullRequests(force: true) } label: {
                    if model.pullRequestsLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .disabled(model.pullRequestsLoading)
                .help("Fetch your pull requests again")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            ListSearchField(key: .pullRequests, prompt: "Search pull requests")
            Divider()
            if let list = model.pullRequests {
                let query = model.listQuery(.pullRequests)
                let prs = query.isEmpty ? list.prs : list.prs.filter { $0.matches(query) }
                List(selection: Binding(get: { model.selectedPR }, set: { model.selectPR($0) })) {
                    if list.prs.isEmpty {
                        Text("You have no open pull requests.").foregroundStyle(.secondary)
                    } else if prs.isEmpty {
                        ListSearchNoMatch(query: query)
                    }
                    ForEach(prs) { PullRequestRow(pr: $0).tag($0.id) }
                }
                .listStyle(.inset)
            } else if let e = model.pullRequestsError {
                VStack(spacing: 10) {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try Again") { model.refreshPullRequests(force: true) }
                }
                .padding()
                Spacer()
            } else {
                ProgressView("Asking Azure DevOps…").padding(.top, 40)
                Spacer()
            }
        }
        .navigationSubtitle("Pull Requests")
        .onAppear { model.refreshPullRequests() }
    }
}

/// One PR: title, branch, and at a glance whether it waits on comments, reviewers or nothing.
struct PullRequestRow: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    var card = false

    var body: some View {
        let session = model.sessions(forKey: pr.sessionKey).first
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(.blue)
                Text(pr.title).font(.body.weight(.medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let session, let badge = model.badges(session).activity ?? model.badges(session).work { StatusPill(status: badge, compact: true) }
            }
            ChipRow(spacing: 6) {
                Text("!\(String(pr.id)) · \(pr.repo)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                PRStatusChips(pr: pr)
                if card, pr.canComplete, !pr.draft {
                    Button("Complete…") { model.completePRRequest = CompletePRRequest(id: pr.id) }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)
                }
            }
        }
        .padding(card ? 12 : 4)
        .background(card ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .contextMenu { PRContextMenu(pr: pr) }
    }
}

/// Comments, approvals, and ready or what blocks completing.
struct PRStatusChips: View {
    let pr: PullRequest

    var body: some View {
        if pr.draft { Chip(text: "Draft", color: .secondary, systemImage: "pencil") }
        if pr.openThreads > 0 {
            Chip(text: "\(pr.openThreads) open comment\(pr.openThreads == 1 ? "" : "s")", color: .orange, systemImage: "text.bubble.fill")
        }
        if pr.rejections > 0 {
            Chip(text: "Changes requested", color: .red, systemImage: "xmark.circle.fill")
        } else if pr.approvals > 0 {
            Chip(text: "\(pr.approvals) approved", color: .green, systemImage: "checkmark.circle.fill")
        }
        if pr.autoComplete {
            Chip(text: "Auto-complete", color: .purple, systemImage: "clock.arrow.circlepath")
        } else if pr.canComplete {
            Chip(text: "Ready to complete", color: .green, systemImage: "checkmark.seal.fill")
        } else if let other = pr.blockers.first(where: { !$0.contains("comment") }) {
            Chip(text: other, color: .secondary, systemImage: "hourglass")
        }
    }
}

struct PRContextMenu: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest

    var body: some View {
        if let u = URL(string: pr.url) { Button("Open in Azure DevOps") { NSWorkspace.shared.open(u) } }
        if pr.openThreads > 0 {
            Button("Show Comments…") { model.prCommentsRequest = PRCommentsRequest(id: pr.id) }
            Menu("Handle Comments with \(Brain.name)") {
                ForEach(PRCommentsMode.allCases) { m in Button(m.title) { model.handlePRComments(pr, mode: m) } }
            }
        }
        Button("Open in Build") { model.openPRInBuild(pr.id) }
        Divider()
        Button("Complete…") { model.completePRRequest = CompletePRRequest(id: pr.id) }
        if pr.autoComplete { Button("Cancel Auto-Complete") { model.cancelAutoComplete(pr.id) } }
    }
}

// MARK: Detail

/// A pull request with its reviewers, checks and comment threads. In Plan's detail column and in Build.
struct PullRequestDetailView: View {
    @Environment(AppModel.self) private var model
    let id: Int
    var inBuild = false
    @State private var showResolved = false

    var body: some View {
        Group {
            if let pr = model.pullRequest(id) {
                content(pr)
            } else if model.pullRequestsLoading || model.prDetailLoading.contains(id) {
                ProgressView("Reading pull request !\(id)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ListEmptyState(title: "Pull request !\(id) isn't open", systemImage: "arrow.triangle.pull", message: "It may be completed or abandoned.")
            }
        }
        .onAppear {
            model.refreshPullRequests()
            model.loadPRDetail(id)
        }
        .onChange(of: id) { _, new in model.loadPRDetail(new) }
    }

    private func content(_ pr: PullRequest) -> some View {
        let sessions = model.sessions(forKey: pr.sessionKey)
        let busy = model.prBusy.contains(pr.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if inBuild {
                    Button {
                        model.buildSelection = nil
                        UserDefaults.standard.set(true, forKey: BuildView.myWorkSideKey)
                    } label: { Label("My Work", systemImage: "chevron.left") }
                        .buttonStyle(.link)
                }
                ChipRow(spacing: 8) {
                    Text("!\(String(pr.id))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(pr.repo).font(.callout).foregroundStyle(.secondary)
                    if !pr.scope.isEmpty { ProjectChip(project: pr.scope) }
                    PRStatusChips(pr: pr)
                }
                Text(pr.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                ChipRow(spacing: 6) {
                    Text(pr.source).font(.callout.monospaced()).lineLimit(1)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    Text(pr.target).font(.callout.monospaced()).lineLimit(1)
                }
                .foregroundStyle(.secondary)
                actions(pr, sessions: sessions, busy: busy)
                if !sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sessions").font(.headline)
                        ForEach(sessions) { SessionLinkButton(session: $0) }
                    }
                }
                status(pr)
                Divider()
                threads(pr)
            }
            .padding(22)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actions(_ pr: PullRequest, sessions: [WorkSession], busy: Bool) -> some View {
        ChipRow(spacing: 8) {
            if pr.openThreads > 0 {
                PRCommentsMenu(pr: pr)
            }
            if let s = sessions.first {
                Button { model.openSession(s) } label: { Label("Open Session", systemImage: "sparkles") }
            }
            Button {
                model.completePRRequest = CompletePRRequest(id: pr.id)
            } label: {
                Label(pr.canComplete ? "Ready: Complete…" : "Complete or Auto-Complete…", systemImage: "checkmark.circle")
            }
            .tint(.green)
            .buttonStyle(ProminentWhen(on: pr.canComplete))
            if pr.autoComplete {
                Button("Cancel Auto-Complete") { model.cancelAutoComplete(pr.id) }
            }
            if let u = URL(string: pr.url) {
                Link(destination: u) { Label("Azure DevOps", systemImage: "arrow.up.right.square") }
            }
            if !inBuild {
                Button { model.openPRInBuild(pr.id) } label: { Label("Open in Build", systemImage: "hammer") }
            }
            if busy || model.prDetailLoading.contains(pr.id) { ProgressView().controlSize(.small) }
        }
        .disabled(busy)
    }

    private func status(_ pr: PullRequest) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("Can complete").foregroundStyle(.secondary)
                if pr.canComplete {
                    Label("Yes", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(pr.blockers, id: \.self) { Label($0, systemImage: "hourglass").foregroundStyle(.orange) }
                    }
                }
            }
            if !pr.reviewers.isEmpty {
                GridRow {
                    Text("Reviewers").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(pr.reviewers, id: \.self) { r in
                            HStack(spacing: 6) {
                                Image(systemName: voteIcon(r.vote)).foregroundStyle(voteColor(r.vote))
                                Text(r.name)
                                Text(r.voteName).foregroundStyle(.secondary)
                                if r.required { Chip(text: "Required", color: .orange) }
                            }
                        }
                    }
                }
            }
            if !pr.policies.isEmpty {
                GridRow {
                    Text("Checks").foregroundStyle(.secondary)
                    ChipRow(spacing: 6) {
                        ForEach(pr.policies, id: \.self) { p in
                            Chip(text: p.name, color: p.passed ? .green : p.blocking ? .orange : .secondary,
                                 systemImage: p.passed ? "checkmark" : "circle.dotted")
                                .help("\(p.kind): \(p.status)\(p.blocking ? "" : " (optional)")")
                        }
                    }
                }
            }
            if !pr.workItems.isEmpty {
                GridRow {
                    Text("Work items").foregroundStyle(.secondary)
                    ChipRow(spacing: 6) {
                        ForEach(pr.workItems, id: \.self) { w in
                            if let item = model.tracker?.item(w) {
                                Button("#\(String(w)) \(item.title)") {
                                    model.mode = .plan
                                    model.selectSidebar(.section(.backlog))
                                    model.selectWorkItem(w)
                                }
                                .buttonStyle(.link)
                                .lineLimit(1)
                            } else {
                                Text("#\(String(w))").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func threads(_ pr: PullRequest) -> some View {
        let all = pr.sortedThreads
        let open = all.filter(\.isOpen)
        let closed = all.filter { !$0.isOpen }
        HStack {
            Text("Comments").font(.headline)
            Text(pr.threads == nil ? "" : "\(open.count) open · \(closed.count) resolved").foregroundStyle(.secondary)
        }
        if pr.threads == nil {
            ProgressView().controlSize(.small)
        } else if all.isEmpty {
            Text("No comments yet.").foregroundStyle(.secondary)
        }
        ForEach(open) { ThreadCard(pr: pr.id, thread: $0) }
        if !closed.isEmpty {
            DisclosureGroup(isExpanded: $showResolved) {
                VStack(spacing: 10) { ForEach(closed) { ThreadCard(pr: pr.id, thread: $0) } }.padding(.top, 8)
            } label: {
                Text("Resolved · \(closed.count)").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private func voteIcon(_ v: Int) -> String {
        v >= 5 ? "checkmark.circle.fill" : v <= -10 ? "xmark.circle.fill" : v < 0 ? "clock.badge.exclamationmark" : "circle"
    }

    private func voteColor(_ v: Int) -> Color { v >= 5 ? .green : v < 0 ? .red : .secondary }
}

/// One comment thread: where, what was said, and reply / resolve right here.
struct ThreadCard: View {
    @Environment(AppModel.self) private var model
    let pr: Int
    let thread: PullRequest.Thread
    @State private var reply = ""
    @State private var replying = false

    var body: some View {
        let busy = model.prBusy.contains(pr)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Chip(text: thread.statusTitle, color: thread.isOpen ? .orange : .green,
                     systemImage: thread.isOpen ? "text.bubble.fill" : "checkmark")
                if thread.file.isEmpty {
                    Text("General comment").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(thread.fileName):\(thread.line)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(thread.file)
                }
                Spacer(minLength: 4)
                Menu {
                    if thread.isOpen {
                        Button("Resolve") { model.setThreadStatus(pr: pr, thread: thread.id, status: "fixed") }
                        Button("Won't Fix") { model.setThreadStatus(pr: pr, thread: thread.id, status: "wontFix") }
                        Button("Close") { model.setThreadStatus(pr: pr, thread: thread.id, status: "closed") }
                    } else {
                        Button("Reopen") { model.setThreadStatus(pr: pr, thread: thread.id, status: "active") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(busy)
            }
            ForEach(thread.comments) { c in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(c.author).font(.callout.weight(.semibold))
                        Text(DateText.short(String(c.date.prefix(10)))).font(.caption).foregroundStyle(.secondary)
                    }
                    MarkdownDocument(text: c.content).textSelection(.enabled)
                }
            }
            if replying {
                TextEditor(text: $reply)
                    .font(.callout)
                    .frame(minHeight: 60, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                HStack {
                    Button("Cancel") { replying = false }
                    Spacer()
                    Button("Reply") { send(resolve: false) }
                        .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    if thread.isOpen {
                        Button("Reply & Resolve") { send(resolve: true) }
                            .buttonStyle(.borderedProminent)
                            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    }
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 10) {
                    Button("Reply…") { replying = true }
                    if thread.isOpen {
                        Button("Resolve") { model.setThreadStatus(pr: pr, thread: thread.id, status: "fixed") }
                    }
                }
                .controlSize(.small)
                .disabled(busy)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((thread.isOpen ? Color.orange : Color.secondary).opacity(thread.isOpen ? 0.35 : 0.12)))
    }

    private func send(resolve: Bool) {
        model.replyToThread(pr: pr, thread: thread.id, text: reply, resolve: resolve)
        reply = ""
        replying = false
    }
}

/// The three ways to hand a PR's comments to Claude.
struct PRCommentsMenu: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    var session: WorkSession?
    var onPick: (() -> Void)?

    var body: some View {
        Menu {
            ForEach(PRCommentsMode.allCases) { m in
                Button {
                    model.handlePRComments(pr, mode: m, in: session)
                    onPick?()
                } label: {
                    Label(m.title, systemImage: m.systemImage)
                }
                .help(m.help)
            }
        } label: {
            Label("Handle with \(Brain.name)", systemImage: "sparkles")
        }
        .fixedSize()
        .help("With you one by one, the simple ones alone and the rest with you, or all of them alone.")
    }
}

/// In a session's header, beside Strategy: the PR's open comments, to read or hand to Claude.
struct CommentsButton: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let session: WorkSession

    var body: some View {
        Menu {
            Button("Show Comments…") { model.prCommentsRequest = PRCommentsRequest(id: pr.id, session: session.id) }
            Divider()
            ForEach(PRCommentsMode.allCases) { m in
                Button { model.handlePRComments(pr, mode: m, in: session) } label: { Label(m.title, systemImage: m.systemImage) }
                    .help(m.help)
            }
        } label: {
            Label("\(pr.openThreads) Comment\(pr.openThreads == 1 ? "" : "s")", systemImage: "text.bubble")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(pr.openThreads) open comment\(pr.openThreads == 1 ? "" : "s") on !\(pr.id): read and answer them, or hand them to \(Brain.name)")
    }
}

/// A PR's comments without leaving the session: read, reply and resolve, or hand them to Claude.
struct PRCommentsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PRCommentsRequest
    @State private var showResolved = false

    var body: some View {
        VStack(spacing: 0) {
            if let pr = model.pullRequest(request.id) {
                header(pr)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        threads(pr)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer(pr)
            } else {
                ProgressView().padding(40)
            }
        }
        .frame(width: 640)
        .frame(minHeight: 360, idealHeight: 620, maxHeight: 820)
        .onAppear { model.loadPRDetail(request.id) }
    }

    private func header(_ pr: PullRequest) -> some View {
        let open = (pr.threads ?? []).filter(\.isOpen).count
        return VStack(alignment: .leading, spacing: 4) {
            Text("Comments on !\(String(pr.id))").font(.title2.weight(.semibold))
            Text(pr.title).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(pr.threads == nil ? "Loading…" : open == 0 ? "No open comments" : "\(open) open")
                .font(.callout.weight(.semibold))
                .foregroundStyle(open > 0 ? Color.purple : .secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func threads(_ pr: PullRequest) -> some View {
        let all = pr.sortedThreads
        let closed = all.filter { !$0.isOpen }
        if pr.threads == nil {
            ProgressView().controlSize(.small)
        }
        ForEach(all.filter(\.isOpen)) { ThreadCard(pr: pr.id, thread: $0) }
        if !closed.isEmpty {
            DisclosureGroup(isExpanded: $showResolved) {
                VStack(spacing: 10) { ForEach(closed) { ThreadCard(pr: pr.id, thread: $0) } }.padding(.top, 8)
            } label: {
                Text("Resolved · \(closed.count)").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private func footer(_ pr: PullRequest) -> some View {
        HStack(spacing: 10) {
            if model.prBusy.contains(pr.id) || model.prDetailLoading.contains(pr.id) { ProgressView().controlSize(.small) }
            Button { model.loadPRDetail(pr.id) } label: { Image(systemName: "arrow.clockwise") }
                .help("Read the comments again")
            if let u = URL(string: pr.url) {
                Link(destination: u) { Label("Azure DevOps", systemImage: "arrow.up.right.square") }
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            if pr.openThreads > 0 || (pr.threads ?? []).contains(where: \.isOpen) {
                PRCommentsMenu(pr: pr, session: model.session(request.session)) { dismiss() }
            }
        }
        .padding(14)
    }
}

// MARK: Complete

struct CompletePRSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: Int
    @State private var strategy = ""
    @State private var deleteBranch = true
    @State private var completeWorkItems = false
    @State private var message = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let pr = model.pullRequest(id) {
                Text("Complete !\(String(pr.id))").font(.title2.weight(.semibold))
                Text(pr.title).foregroundStyle(.secondary)
                Text("\(pr.source) → \(pr.target)").font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                if !pr.canComplete {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not ready to complete now:").font(.callout.weight(.semibold))
                        ForEach(pr.blockers, id: \.self) { Label($0, systemImage: "hourglass").font(.callout).foregroundStyle(.orange) }
                        Text("Set auto-complete and it merges by itself when these pass.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Form {
                    Picker("Merge type", selection: $strategy) {
                        ForEach(pr.strategies, id: \.self) { Text(PullRequest.strategyTitle($0)).tag($0) }
                    }
                    .disabled(pr.strategies.count < 2)
                    Toggle("Delete \(pr.source) after merging", isOn: $deleteBranch)
                    if pr.keepBranch {
                        Text("This looks like a release or test branch, so it is kept by default.").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Complete linked work items", isOn: $completeWorkItems)
                        .help("Moves the linked PBIs and bugs on in Azure DevOps. Off by default, so they stay where the team puts them.")
                    TextField("Merge commit message", text: $message, axis: .vertical)
                        .lineLimit(2...)
                        .scrollingInput(message, maxLines: 5)
                }
                .formStyle(.grouped)
                .multilineTextAlignment(.leading)
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Set Auto-Complete") {
                        model.completePR(pr.id, strategy: strategy, deleteBranch: deleteBranch, completeWorkItems: completeWorkItems,
                                         message: message, auto: true)
                        dismiss()
                    }
                    .disabled(pr.autoComplete)
                    Button("Complete Now") {
                        model.completePR(pr.id, strategy: strategy, deleteBranch: deleteBranch, completeWorkItems: completeWorkItems,
                                         message: message, auto: false)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!pr.canComplete)
                }
                .onAppear {
                    guard !loaded else { return }
                    loaded = true
                    strategy = pr.strategies.first ?? "squash"
                    deleteBranch = !pr.keepBranch
                    message = "Merged PR \(pr.id): \(pr.title)"
                }
            } else {
                ProgressView()
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { model.loadPRDetail(id) }
    }
}

/// Bordered-prominent when `on`, plain bordered otherwise: the one next step stands out.
struct ProminentWhen: PrimitiveButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        if on {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.borderedProminent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(.bordered)
        }
    }
}
