import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    /// Fetches every PBI and bug from the trackers. Skipped when fetched in the last two minutes, unless forced.
    func refreshTracker(force: Bool = false) { engine.tracker.refreshBacklog(force: force) }

    /// Every ten minutes while the app is in front: the tracker and My Work; the sprints at most hourly.
    func startTrackerTimer() {
        guard trackerTimer == nil else { return }
        trackerTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSApp.isActive else { return }
                if self.tracker != nil || self.trackerError != nil { self.refreshTracker(force: true) }
                if self.myWork != nil { self.refreshMyWork(force: true) }
                if self.pullRequests != nil { self.refreshPullRequests(force: true) }
                self.checkSprints()
            }
        }
    }

    /// The Sync button: rereads the KB, and fetches the tracker, My Work and the calendar again.
    func syncEverything() {
        reload()
        refreshTracker(force: true)
        checkSprints(force: true)
        if mode == .build || myWork != nil { refreshMyWork(force: true) }
        if mode == .build || pullRequests != nil { refreshPullRequests(force: true) }
        if !calendar.isRunning, !morning.isBusy, backgroundStarted { syncCalendar() }
        notice = "Syncing…"
    }

    var isSyncing: Bool { trackerLoading || myWorkLoading || pullRequestsLoading || calendar.isRunning }

    func selectWorkItem(_ id: Int?) {
        navigate { [self] in
            multiSelection = []
            closeDocument()
            selectedWorkItem = id
            searchPick = nil
            showProposedBacklog = false
            showLooseTasks = false
        }
    }

    func showProposed() {
        navigate { [self] in
            multiSelection = []
            closeDocument()
            selectedWorkItem = nil
            showLooseTasks = false
            showProposedBacklog = true
        }
    }

    func showLooseTaskList() {
        navigate { [self] in
            multiSelection = []
            closeDocument()
            selectedWorkItem = nil
            showProposedBacklog = false
            showLooseTasks = true
        }
    }

    /// The tracker's items for a scope: its own, what it includes, and for a project-wide scope the whole project.
    func trackerItems(scope: String) -> [TrackerBacklog.Item] {
        tracker?.items(in: index.members(of: scope)) ?? []
    }

    /// Opens Backlog on the work item's sprint with the item selected, leaving any search.
    func showInBacklog(_ item: TrackerBacklog.Item) {
        navigate { [self] in
            searchText = ""
            listSearch[ListSearchKey.backlog.rawValue] = nil
            mode = .plan
            let here = projectID.map { !index.members(of: $0).isDisjoint(with: item.scopes) } ?? false
            if !here { setProject(item.scope) }
            sidebarSelection = .section(.backlog)
            closeDocument()
            showProposedBacklog = false
            showLooseTasks = false
            let known = tracker?.sprint(path: item.sprint) != nil
            UserDefaults.standard.set(known ? item.sprint : "none", forKey: "backlogSprint")
            if known, tracker?.sprint(path: item.sprint)?.when == "past" { loadSprint(item.sprint) }
            if tracker?.item(item.id) == nil, known { sprintItems[item.sprint, default: []].append(item) }
            selectedWorkItem = item.id
        }
    }

    /// A work item from the backlog, a past sprint read separately, or a search.
    func workItem(_ id: Int) -> TrackerBacklog.Item? {
        tracker?.item(id)
            ?? sprintItems.values.lazy.compactMap { $0.first { $0.id == id } }.first
            ?? workItemSearch.items.first { $0.id == id }
    }

    /// Reads everything in a past sprint, finished work included. Once per sprint unless forced.
    func loadSprint(_ path: String, force: Bool = false) {
        guard !sprintLoading.contains(path), force || sprintItems[path] == nil else { return }
        sprintLoading.insert(path)
        let cli = cli
        Task {
            do {
                let out = try await cli.run(["tracker", "backlog", "--sprint", path, "--json"])
                sprintItems[path] = try TrackerBacklog.decode(out).items
            } catch {
                errorMessage = cliMessage(error)
            }
            sprintLoading.remove(path)
        }
    }

    /// Finds PBIs and bugs in Azure DevOps whose title has every word, or whose number it is, after a pause in typing.
    func searchWorkItems(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q != workItemSearch.query else { return }
        workItemSearch = WorkItemSearch(query: q)
        guard q.count >= 3 || Int(q.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) != nil else { return }
        workItemSearch.loading = true
        let cli = cli
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard workItemSearch.query == q else { return }
            let found = try? TrackerBacklog.decode(try await cli.run(["tracker", "backlog", "--search", q, "--json"])).items
            guard workItemSearch.query == q else { return }
            workItemSearch.items = found ?? []
            workItemSearch.failed = found == nil
            workItemSearch.loading = false
        }
    }

    func moveWorkItems(_ ids: [Int], to sprint: TrackerBacklog.Sprint) {
        guard !ids.isEmpty else { return }
        changeWorkItems(ids, ["tracker", "move"] + ids.map(String.init) + ["--sprint", sprint.path],
                        done: ids.count == 1 ? "#\(ids[0]) moved to \(sprint.name)." : "\(ids.count) items moved to \(sprint.name).") { b in
            b.moving(Set(ids), to: sprint.path)
        }
    }

    func setWorkItemState(_ ids: [Int], _ state: TrackerBacklog.WorkState) {
        guard !ids.isEmpty else { return }
        changeWorkItems(ids, ["tracker", "state"] + ids.map(String.init) + ["--state", state.name],
                        done: ids.count == 1 ? "#\(ids[0]) is now \(state.name)." : "\(ids.count) items are now \(state.name).") { b in
            b.setting(Set(ids), to: state)
        }
    }

    /// Runs a change in the items' tracker, shows it at once in the backlog, past sprints and search, then refetches.
    private func changeWorkItems(_ ids: [Int], _ args: [String], done: String, apply: @escaping (TrackerBacklog) -> TrackerBacklog) {
        busyWorkItems.formUnion(ids)
        let scopes = Set((tracker?.items ?? []).filter { ids.contains($0.id) }.map(\.scope))
        let args = args + (scopes.count == 1 ? ["--project", scopes.first!] : [])
        let cli = cli
        Task {
            do {
                _ = try await cli.run(args)
                tracker = tracker.map(apply)
                sprintItems = sprintItems.mapValues { apply(TrackerBacklog(items: $0)).items }
                workItemSearch.items = apply(TrackerBacklog(items: workItemSearch.items)).items
                notice = done
                refreshTracker(force: true)
            } catch {
                errorMessage = cliMessage(error)
            }
            busyWorkItems.subtract(ids)
        }
    }

    private func cliMessage(_ error: Error) -> String {
        (error as? KBCLIError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription
    }
}

struct WorkItemSearch: Equatable {
    var query = ""
    var items: [TrackerBacklog.Item] = []
    var loading = false
    var failed = false
}

/// Syncs everything the app shows. In the toolbar of both Plan and Build.
struct SyncButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.syncEverything()
        } label: {
            if model.isSyncing {
                ProgressView().controlSize(.small)
            } else {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .help(help)
    }

    private var help: String {
        var lines = ["Sync now (⌘R): reread the knowledge base, and fetch work items, My Work and the calendar."]
        if let at = model.trackerFetched { lines.append("Work items updated \(MeetingController.clock(at)).") }
        lines.append("Work items also update every ten minutes.")
        return lines.joined(separator: "\n")
    }
}

/// Who has the item: you, someone else, or nobody.
struct AssigneeBadge: View {
    let item: TrackerBacklog.Item

    var body: some View {
        let owner = TrackerBacklog.owner(item)
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(color(owner).opacity(0.18))
                if owner == .nobody {
                    Image(systemName: "person.fill.questionmark").font(.system(size: 9))
                } else {
                    Text(initials(item.assignee)).font(.system(size: 9, weight: .bold))
                }
            }
            .frame(width: 20, height: 20)
            .foregroundStyle(color(owner))
            Text(owner == .me ? "You" : owner == .nobody ? "Not assigned" : item.assignee)
                .font(.caption.weight(.medium))
                .foregroundStyle(owner == .nobody ? .secondary : .primary)
                .lineLimit(1)
        }
        .help(owner == .nobody ? "Nobody is assigned" : "Assigned to \(item.assignee)")
    }

    private func color(_ o: TrackerBacklog.Owner) -> Color {
        switch o {
        case .me: return .accentColor
        case .others: return .purple
        case .nobody: return .gray
        }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// The state, a bar from New to Done, and child-task progress.
struct WorkItemProgress: View {
    let item: TrackerBacklog.Item

    var body: some View {
        let value = item.stage == .done ? 1 : item.tasksTotal > 0
            ? max(item.stage.fraction * 0.5, Double(item.tasksDone) / Double(item.tasksTotal)) : item.stage.fraction
        HStack(spacing: 8) {
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .tint(tint)
                .frame(width: 90)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var label: String {
        var parts = [item.state]
        if item.stage == .inPR { parts.append(item.prs.count > 1 ? "\(item.prs.count) PRs" : "in PR") }
        if item.tasksTotal > 0 { parts.append("\(item.tasksDone)/\(item.tasksTotal) tasks") }
        return parts.joined(separator: " · ")
    }

    private var tint: Color {
        switch item.stage {
        case .notStarted: return .gray
        case .inProgress: return .blue
        case .inPR: return .purple
        case .resolved, .done: return .green
        }
    }
}

struct TrackerItemRow: View {
    @Environment(AppModel.self) private var model
    let item: TrackerBacklog.Item
    let showScopes: Bool

    var body: some View {
        let selected = model.selectedWorkItem == item.id
        let current = model.tracker?.isInCurrentSprint(item) ?? false
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ChipRow(spacing: 6) {
                    KindChip(kind: item.isBug ? "bug" : "pbi")
                    if let u = URL(string: item.url) {
                        Link("#\(String(item.id))", destination: u).font(.caption.weight(.semibold))
                    }
                    if showScopes {
                        ForEach(item.scopes, id: \.self) { ProjectChip(project: $0) }
                    }
                }
                Spacer(minLength: 4)
                AssigneeBadge(item: item)
            }
            Text(item.title).font(.headline).lineLimit(3)
            HStack(spacing: 8) {
                ChipRow(spacing: 6) {
                    StageBadge(stage: item.stage)
                    TaskSummary(item: item)
                    TagChips(tags: model.localTags(item), key: .backlog)
                }
                Spacer(minLength: 4)
                if !item.sprintName.isEmpty, item.sprint.contains("\\") {
                    let overdue = !current && item.isUnfinished && model.tracker?.sprint(path: item.sprint)?.when == "past"
                    Chip(text: item.sprintName, color: current ? .accentColor : overdue ? .orange : .secondary, systemImage: "calendar")
                        .help(overdue ? "\(item.sprintName) is over and this isn't Done" : item.sprintName)
                }
                if model.busyWorkItems.contains(item.id) { ProgressView().controlSize(.mini) }
                if let s = model.sessions(forKey: item.sessionKey).first { StateDot(state: s.crewState) }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.selectWorkItem(item.id) }
        .contextMenu {
            if let u = URL(string: item.url) {
                Button("Open in \(TrackerLink.name(forURL: item.url))") { NSWorkspace.shared.open(u) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url, forType: .string)
                }
            }
            Button("Ask \(Brain.name) About This…") {
                model.askAbout(.text("Work item #\(item.id): \(item.title) (\(item.state), \(item.assignee.isEmpty ? "not assigned" : "assigned to \(item.assignee)")). Read it with `kb tracker item \(item.id)`.",
                                     title: "#\(item.id) \(item.title)", project: item.scope))
            }
            WorkItemActionsMenu(item: item)
        }
    }
}

/// What can be done with a work item at its stage: start it, carry on with it, or tidy its tasks.
struct WorkItemActionsMenu: View {
    @Environment(AppModel.self) private var model
    let item: TrackerBacklog.Item

    var body: some View {
        let session = model.sessions(forKey: item.sessionKey).first
        if let session {
            Divider()
            Button(session.crewState == .working ? "Implementing… Open in Build" : "Open Session in Build") { model.openSession(session) }
        } else if item.canStart {
            Divider()
            Button("Implement…") { model.startImplement(item.asMyWork, show: false) }
        } else if !item.isFinished {
            Divider()
            Button("Continue in Build…") { model.continueItem(item.asMyWork) }
        }
        if !item.openTasks.isEmpty {
            Divider()
            Button("Mark \(item.openTasks.count == 1 ? "Its Open Task" : "All \(item.openTasks.count) Open Tasks") Done") {
                model.setTasks(item.openTasks.map(\.id), state: "Done")
            }
        }
        Divider()
        WorkItemSprintMenu(item: item)
        WorkItemStateMenu(item: item)
    }
}

/// Moves a work item to the current sprint or a later one.
struct WorkItemSprintMenu: View {
    @Environment(AppModel.self) private var model
    let item: TrackerBacklog.Item

    var body: some View {
        let targets = model.tracker?.moveTargets(for: item) ?? []
        let current = model.tracker?.currentSprint(scope: item.scope)
        if let current, current.path != item.sprint {
            Button("Move to \(current.name) (Current Sprint)") { model.moveWorkItems([item.id], to: current) }
        }
        if !targets.isEmpty {
            Menu("Move to Sprint") {
                ForEach(targets, id: \.path) { sp in
                    Button("\(sp.name)\(sp.path == current?.path ? " (current)" : "")  ·  \(DateText.short(sp.start))–\(DateText.short(sp.finish))") {
                        model.moveWorkItems([item.id], to: sp)
                    }
                    .disabled(sp.path == item.sprint)
                }
            }
        }
    }
}

/// Sets a work item's state, from the states its type has in Azure DevOps.
struct WorkItemStateMenu: View {
    @Environment(AppModel.self) private var model
    let item: TrackerBacklog.Item
    var title = "Set State"

    var body: some View {
        Menu(title) {
            ForEach(model.tracker?.states(for: item) ?? TrackerBacklog.WorkState.scrum, id: \.name) { st in
                Button(st.name) { model.setWorkItemState([item.id], st) }
                    .disabled(st.name == item.state)
            }
        }
    }
}

/// Where a work item stands, in a word and a colour.
struct StageBadge: View {
    let stage: TrackerBacklog.Stage

    var body: some View {
        Chip(text: Self.title(stage), color: Self.color(stage), systemImage: Self.icon(stage))
    }

    static func title(_ s: TrackerBacklog.Stage) -> String { s == .notStarted ? "Ready to start" : s.title }

    static func icon(_ s: TrackerBacklog.Stage) -> String {
        switch s {
        case .notStarted: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .inPR: return "arrow.triangle.pull"
        case .resolved: return "checkmark.circle"
        case .done: return "checkmark.circle.fill"
        }
    }

    static func color(_ s: TrackerBacklog.Stage) -> Color {
        switch s {
        case .notStarted: return .secondary
        case .inProgress: return .blue
        case .inPR: return .purple
        case .resolved, .done: return .green
        }
    }
}

/// The child tasks at a glance: how many are done, in progress and not started. Orange when the item is
/// finished but tasks are still open.
struct TaskSummary: View {
    let item: TrackerBacklog.Item

    var body: some View {
        if item.tasksTotal > 0 {
            let open = item.openTasks.count
            let working = item.tasksInProgress
            if item.hasLooseTasks {
                Chip(text: "\(open) open task\(open == 1 ? "" : "s")", color: .orange, systemImage: "exclamationmark.circle.fill")
                    .help("It is \(item.stage.title.lowercased()), but \(open) of its tasks aren't Done")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checklist").foregroundStyle(.secondary)
                    Text("\(item.tasksDone)/\(item.tasksTotal)").monospacedDigit()
                    if working > 0 {
                        Text("· \(working) in progress").foregroundStyle(.blue)
                    }
                }
                .font(.caption)
                .fixedSize()
                .help(item.tasks.map { "\($0.state): \($0.title)" }.joined(separator: "\n"))
            }
        }
    }
}

/// The backlog of a scope: KB items waiting to be created, then every work item by who has it.
struct BacklogView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    /// `all`, `none`, or a sprint's iteration path.
    @AppStorage("backlogSprint") private var sprint = "all"

    var body: some View {
        let all = model.trackerItems(scope: project.id)
        let past = model.tracker?.sprint(path: sprint).map { $0.when == "past" } ?? false
        let members = model.index.members(of: project.id)
        let extra = sprint != "all" && sprint != "none" ? (model.sprintItems[sprint] ?? []).filter { !members.isDisjoint(with: $0.scopes) } : []
        let inSprint = TrackerBacklog.merge(all.filter { matches($0) }, extra)
        let query = model.listQuery(.backlog)
        let picked = model.tagSelection(.backlog)
        let items = (query.isEmpty ? inSprint : inSprint.filter { $0.matches(query) })
            .filter { EntryTags.matches(model.allTags($0), selected: picked) }
        VStack(spacing: 0) {
            if model.tracker == nil {
                BacklogLoading()
            } else {
                BacklogHeader(count: inSprint.filter { $0.stage != .done }.count, filtered: sprint != "all", selection: $sprint)
                SprintPills(items: all, selection: $sprint)
                if past, let s = model.tracker?.sprint(path: sprint) {
                    PastSprintBar(sprint: s, project: project, items: inSprint, loading: model.sprintLoading.contains(sprint))
                }
            }
            ListSearchField(key: .backlog, prompt: "Search this backlog")
            TagFilterBar(key: .backlog, available: inSprint.map { model.allTags($0) })
            Divider()
            BacklogList(project: project, items: items, sprintPicked: sprint != "all", query: query)
        }
        .navigationSubtitle("Backlog")
        .onAppear {
            model.refreshTracker()
            if past { model.loadSprint(sprint) }
            if !query.isEmpty { model.searchWorkItems(query) }
        }
        .onChange(of: sprint) { _, path in
            if model.tracker?.sprint(path: path)?.when == "past" { model.loadSprint(path) }
        }
        .onChange(of: query) { _, q in model.searchWorkItems(q) }
    }

    private func matches(_ item: TrackerBacklog.Item) -> Bool {
        switch sprint {
        case "all": return true
        case "none": return model.tracker?.matches(item, .none) ?? true
        default: return item.sprint == sprint
        }
    }
}

/// Under the pills when a past sprint is picked: what is left in it, and moving all of it to the sprint running now.
private struct PastSprintBar: View {
    @Environment(AppModel.self) private var model
    let sprint: TrackerBacklog.Sprint
    let project: KBProject
    let items: [TrackerBacklog.Item]
    let loading: Bool

    var body: some View {
        let unfinished = items.filter(\.isUnfinished)
        let loose = items.filter(\.hasLooseTasks).count
        let current = model.tracker?.currentSprint(scope: project.id)
        let busy = unfinished.contains { model.busyWorkItems.contains($0.id) }
        AdaptiveCardLayout(spacing: 8, stackedSpacing: 6, minInfoWidth: 150) {
            Image(systemName: unfinished.isEmpty && loose == 0 ? "checkmark.circle" : "clock.badge.exclamationmark")
                .foregroundStyle(unfinished.isEmpty && loose == 0 ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(sprint.name) ended \(DateText.short(sprint.finish))").font(.callout.weight(.medium))
                Text(summary(unfinished: unfinished.count, loose: loose))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if loading || busy {
                    ProgressView().controlSize(.small)
                }
                if let current, !unfinished.isEmpty {
                    Button("Move \(unfinished.count) to \(current.name)") {
                        model.moveWorkItems(unfinished.map(\.id), to: current)
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(busy)
                    .help("Move every PBI and bug in \(sprint.name) that isn't Done to \(current.name), the sprint running now")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(unfinished.isEmpty && loose == 0 ? 0 : 0.08))
    }

    private func summary(unfinished: Int, loose: Int) -> String {
        var parts: [String] = []
        if unfinished > 0 { parts.append("\(unfinished) not done") }
        if loose > 0 { parts.append("\(loose) with tasks to close") }
        return parts.isEmpty ? "Everything in it is done." : parts.joined(separator: " · ")
    }
}

/// Until the first fetch is back: no counts or sprints that would only be wrong.
private struct BacklogLoading: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if let e = model.trackerError {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).lineLimit(2)
                Spacer(minLength: 4)
                Button("Try Again") { model.refreshTracker(force: true) }.controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
                Text("Loading work items and sprints from Azure DevOps…").foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
    }
}

private struct BacklogHeader: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let filtered: Bool
    @Binding var selection: String

    var body: some View {
        let current = model.tracker?.sprint(.current)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(count) open\(filtered ? " in this sprint" : "")")
                .font(.headline)
                .lineLimit(1)
                .layoutPriority(1)
            Text(updated)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button {
                if let current { selection = current.path }
            } label: {
                Image(systemName: "scope")
            }
            .buttonStyle(.borderless)
            .disabled(current == nil)
            .help(current.map { "Show \($0.name), the sprint running now" } ?? "No sprint is running today")
            Button { model.requestNewEntry(.backlog) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New backlog item to propose")
            Button { model.refreshTracker(force: true) } label: {
                if model.trackerLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .disabled(model.trackerLoading)
            .help("Fetch the work items again")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var updated: String {
        guard let at = model.trackerFetched else { return "Azure DevOps" }
        return "updated \(MeetingController.clock(at))"
    }
}

/// All, the sprints with work left or coming up, No sprint, and a menu for any older sprint. Wraps when narrow.
private struct SprintPills: View {
    @Environment(AppModel.self) private var model
    let items: [TrackerBacklog.Item]
    @Binding var selection: String

    var body: some View {
        let tracker = model.tracker
        var shown = tracker?.shownSprints(for: items) ?? []
        if let picked = tracker?.sprint(path: selection), !shown.contains(picked) {
            shown.append(picked)
            shown.sort { $0.start < $1.start }
        }
        let current = tracker?.sprint(.current)
        let older = (tracker?.olderSprints(for: items) ?? []).filter { $0.path != selection }
        let none = items.filter { (tracker?.matches($0, .none) ?? false) && $0.needsAttention }.count
        return FlowLayout(spacing: 6) {
            pill("All", count: items.filter(\.needsAttention).count, key: "all", current: false)
            ForEach(shown, id: \.path) { sp in
                let left = items.filter { $0.sprint == sp.path && $0.needsAttention }.count
                pill(sp.name, count: left, key: sp.path, current: sp.path == current?.path, past: sp.when == "past")
                    .help(help(sp, left: left))
            }
            pill("No sprint", count: none, key: "none", current: false)
            if !older.isEmpty {
                Menu {
                    ForEach(older, id: \.path) { sp in
                        Button("\(sp.name)  ·  \(DateText.short(sp.start))–\(DateText.short(sp.finish))") { selection = sp.path }
                    }
                } label: {
                    Label("Older sprints", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Past sprints with nothing left to do: pick one to see what was finished in it")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func help(_ sp: TrackerBacklog.Sprint, left: Int) -> String {
        let dates = "\(sp.name): \(DateText.short(sp.start))–\(DateText.short(sp.finish))"
        guard sp.when == "past" else { return dates }
        return left > 0 ? "\(dates). Ended with \(left) item\(left == 1 ? "" : "s") left to finish or move." : dates
    }

    private func pill(_ title: String, count: Int, key: String, current: Bool, past: Bool = false) -> some View {
        let selected = selection == key
        let warn = past && count > 0
        return Button {
            selection = key
        } label: {
            HStack(spacing: 4) {
                if current { Circle().fill(selected ? Color.white : Color.accentColor).frame(width: 6, height: 6) }
                Text(title).lineLimit(1)
                Text("\(count)")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : warn ? Color.orange : Color.secondary)
                    .frame(minWidth: 16, minHeight: 16)
                    .padding(.horizontal, count > 99 ? 3 : 0)
                    .background(selected ? Color.white.opacity(0.22) : (warn ? Color.orange : Color.secondary).opacity(0.14), in: Capsule())
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(selected ? Color.white : .primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct BacklogList: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    let items: [TrackerBacklog.Item]
    let sprintPicked: Bool
    let query: String
    private var showRejected: Bool {
        get { model.foldStates["backlog.rejected"] ?? false }
        nonmutating set { model.foldStates["backlog.rejected"] = newValue }
    }
    private var showDone: Bool {
        get { model.foldStates["backlog.done"] ?? false }
        nonmutating set { model.foldStates["backlog.done"] = newValue }
    }

    var body: some View {
        let searching = !query.isEmpty
        let everything = model.index.entries(project: project.id, section: .backlog)
            .filter { !searching || $0.matches(query) }
        let all = everything.filter { !$0.isDraft }
        let prefix = model.tracker(for: project.id).titlePrefix
        let proposed = all.filter { $0.backlogStatus == .proposed }
        let findings = model.duplicateFindings(for: proposed)
        let suggested = proposed.filter { findings[$0.id]?.alreadyCreated == nil }
        let known = Set(model.trackerItems(scope: project.id).map(\.id))
        let created = all.filter { $0.backlogStatus == .created && !known.contains(Int($0.field("work_item") ?? "") ?? -1) }
        let rejected = all.filter { $0.backlogStatus == .rejected }
        List(selection: model.entrySelection) {
            DraftsSection(drafts: everything.filter(\.isDraft))
            if !proposed.isEmpty {
                ProposedRow(count: suggested.count)
            }
            let loose = items.filter(\.hasLooseTasks)
            if !loose.isEmpty {
                LooseTasksRow(count: loose.count)
            }
            if searching && items.isEmpty && everything.isEmpty {
                ListSearchNoMatch(query: query)
            }
            trackerSections
            if searching {
                WorkItemSearchSection(query: query, shown: Set(items.map(\.id)), showScopes: model.index.members(of: project.id).count > 1)
            }
            if !created.isEmpty {
                Section("Created from the knowledge base · \(created.count)") {
                    ForEach(created) { BacklogCard(entry: $0, prefix: prefix).tag($0.id).entryContextMenu($0.id) }
                }
            }
            if !rejected.isEmpty {
                FoldableSection(isExpanded: model.fold("backlog.rejected")) {
                    ForEach(rejected) { BacklogCard(entry: $0, prefix: prefix).tag($0.id).entryContextMenu($0.id) }
                } header: {
                    Text("Rejected · \(rejected.count)")
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var trackerSections: some View {
        let showScopes = model.index.members(of: project.id).count > 1
        if model.tracker == nil {
            EmptyView()
        } else {
            ForEach(TrackerBacklog.Owner.allCases, id: \.self) { owner in
                let rows = items.filter { $0.stage != .done && TrackerBacklog.owner($0) == owner }
                if query.isEmpty || !rows.isEmpty {
                    Section("\(owner.title) · \(rows.count)") {
                        if rows.isEmpty { Text("None.").foregroundStyle(.secondary).font(.callout) }
                        ForEach(TrackerBacklog.listOrder, id: \.self) { stage in
                            let group = rows.filter { $0.stage == stage }
                            if !group.isEmpty {
                                StageHeader(stage: stage, count: group.count)
                                ForEach(group) { TrackerItemRow(item: $0, showScopes: showScopes) }
                            }
                        }
                    }
                }
            }
            let done = items.filter { $0.stage == .done }
            if !done.isEmpty {
                FoldableSection(isExpanded: Binding(get: { showDone || !query.isEmpty }, set: { showDone = $0 })) {
                    ForEach(done) { TrackerItemRow(item: $0, showScopes: showScopes) }
                } header: {
                    Text("\(sprintPicked ? "Done" : "Done in the last two weeks") · \(done.count)")
                }
            }
        }
    }
}

/// Under a search: PBIs and bugs Azure DevOps has beyond what the list shows, finished ones and older sprints too.
struct WorkItemSearchSection: View {
    @Environment(AppModel.self) private var model
    let query: String
    let shown: Set<Int>
    let showScopes: Bool

    var body: some View {
        let search = model.workItemSearch
        let more = search.query == query ? search.items.filter { !shown.contains($0.id) } : []
        if search.loading || !more.isEmpty || search.failed {
            Section {
                if search.loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Searching Azure DevOps…").foregroundStyle(.secondary).font(.callout)
                    }
                } else if search.failed {
                    Text("Couldn't search Azure DevOps.").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(more) { TrackerItemRow(item: $0, showScopes: showScopes) }
            } header: {
                Text("More in Azure DevOps\(more.isEmpty ? "" : " · \(more.count)")")
            }
        }
    }
}

/// The content area for a selected work item.
struct WorkItemDetailView: View {
    @Environment(AppModel.self) private var model
    let item: TrackerBacklog.Item

    private var sprintNote: String {
        if model.tracker?.isInCurrentSprint(item) == true { return "  (current)" }
        guard let sp = model.tracker?.sprint(path: item.sprint), sp.when == "past" else { return "" }
        return "  (ended \(DateText.short(sp.finish)))"
    }

    var body: some View {
        let sessions = model.sessions(forKey: item.sessionKey)
        let busy = model.busyWorkItems.contains(item.id)
        let current = model.tracker?.currentSprint(scope: item.scope)
        let done = model.tracker?.states(for: item).first { $0.category == "Completed" }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ChipRow(spacing: 8) {
                    KindChip(kind: item.isBug ? "bug" : "pbi")
                    Text("#\(String(item.id))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    ForEach(item.scopes, id: \.self) { ProjectChip(project: $0) }
                }
                Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Assigned").foregroundStyle(.secondary)
                        AssigneeBadge(item: item)
                    }
                    GridRow {
                        Text("Progress").foregroundStyle(.secondary)
                        WorkItemProgress(item: item)
                    }
                    GridRow {
                        Text("State").foregroundStyle(.secondary)
                        WorkItemStateMenu(item: item, title: item.state)
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(busy)
                            .help("Set the state in \(TrackerLink.name(forURL: item.url))")
                    }
                    GridRow {
                        Text("Sprint").foregroundStyle(.secondary)
                        Menu {
                            WorkItemSprintMenu(item: item)
                        } label: {
                            Text(item.sprint.contains("\\") ? item.sprintName : "No sprint")
                                + Text(sprintNote).foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(busy || (model.tracker?.moveTargets(for: item) ?? []).isEmpty)
                        .help("Move it to another sprint")
                    }
                    WorkItemTagRows(item: item)
                    if !item.prs.isEmpty {
                        GridRow {
                            Text("Pull requests").foregroundStyle(.secondary)
                            ChipRow(spacing: 8) {
                                ForEach(item.prs, id: \.self) { id in
                                    if let pr = model.pullRequests?.pr(id) {
                                        Button("!\(String(id)) \(pr.openThreads > 0 ? "· \(pr.openThreads) open comments" : "")") {
                                            model.mode = .plan
                                            model.selectSidebar(.pullRequests)
                                            model.selectPR(id)
                                        }
                                        .buttonStyle(.link)
                                    } else {
                                        Text("!\(String(id))").textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
                .font(.callout)
                ChipRow(spacing: 8) {
                    if item.isUnfinished, let current, current.path != item.sprint {
                        Button("Move to \(current.name)") { model.moveWorkItems([item.id], to: current) }
                            .disabled(busy)
                            .help("Move it to \(current.name), the sprint running now")
                    }
                    if item.isUnfinished, let done {
                        Button("Mark \(done.name)") { model.setWorkItemState([item.id], done) }
                            .disabled(busy)
                    }
                    if busy { ProgressView().controlSize(.small) }
                    if model.isSearching || model.sidebarSelection != .section(.backlog) || !model.listQuery(.backlog).isEmpty {
                        Button("Show in Backlog") { model.showInBacklog(item) }
                            .help("Open Backlog on \(item.sprint.contains("\\") ? item.sprintName : "No sprint") with this item")
                    }
                }
                HStack(spacing: 8) {
                    if let u = URL(string: item.url) {
                        Link(destination: u) { Label("Open in \(TrackerLink.name(forURL: item.url))", systemImage: "arrow.up.right.square") }
                        CopyButton(label: "Copy Link", text: item.url)
                    }
                }
                Divider()
                if !item.tasks.isEmpty {
                    TaskList(item: item)
                    Divider()
                }
                ResearchLinks(target: .workItem(item.id), project: item.scope, title: item.title)
                Divider()
                if !sessions.isEmpty, !item.canStart {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sessions").font(.headline)
                        ForEach(sessions) { SessionLinkButton(session: $0) }
                    }
                } else {
                    HStack(spacing: 8) {
                        if item.canStart {
                            ImplementButton(item: item.asMyWork, show: false)
                        } else if !item.isFinished {
                            Button("Continue in Build…") { model.continueItem(item.asMyWork) }
                                .buttonStyle(.borderedProminent)
                                .help("Open a session that finds the branch and PR and tells you where it stands")
                        }
                        Button("Ask \(Brain.name) About This…") {
                            model.askAbout(.text("Work item #\(item.id): \(item.title). Read it with `kb tracker item \(item.id)`.",
                                                 title: "#\(item.id) \(item.title)", project: item.scope))
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


/// A compact row at the top of Backlog: how many PBIs and bugs wait to be created. Opens them in the content area.
private struct ProposedRow: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        let selected = model.showProposedBacklog
        HStack(spacing: 8) {
            Image(systemName: "tray.full").foregroundStyle(selected ? Color.white : Color.accentColor)
            Text("Suggested backlog items").fontWeight(.medium)
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(minWidth: 18, minHeight: 18)
                .background(selected ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.18), in: Capsule())
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .foregroundStyle(selected ? Color.white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { model.showProposed() }
        .help("PBIs and bugs suggested from meetings, sessions and ideas, waiting for you to create them")
        .listRowSeparator(.hidden)
    }
}

/// The content area for the proposed PBIs and bugs of a scope: each with its details and what to do with it.
struct ProposedBacklogView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject

    var body: some View {
        let waiting = model.index.entries(project: project.id, section: .backlog)
            .filter { !$0.isDraft && $0.backlogStatus == .proposed }
        let findings = model.duplicateFindings(for: waiting)
        let shown = model.tagFiltered(waiting, .backlog)
        let proposed = shown.filter { findings[$0.id]?.alreadyCreated == nil }
        let covered = shown.filter { findings[$0.id]?.alreadyCreated != nil }
        let prefix = model.tracker(for: project.id).titlePrefix
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TagFilterBar(key: .backlog, available: waiting.map(\.tags), inset: 0)
                HStack(alignment: .firstTextBaseline) {
                    Text("Suggested backlog items").font(.title2.weight(.semibold))
                    Text("\(proposed.count) for \(model.trackerName(project.id))").foregroundStyle(.secondary)
                    Spacer()
                    if proposed.count > 1 {
                        Button("Create All…") { model.backlogBatchRequest = BacklogBatchRequest(entries: proposed.map(\.id)) }
                            .buttonStyle(.borderedProminent)
                            .help("Pick the sprint and assignee for each, then create them together")
                    }
                }
                if proposed.isEmpty {
                    Text("No suggestions. New ones come from meetings, sessions and the + button.")
                        .foregroundStyle(.secondary)
                }
                if !waiting.isEmpty {
                    DuplicateCheckStatus(scope: project.id)
                }
                ForEach(proposed) { e in
                    ProposedCard(entry: e, prefix: e.project == project.id ? prefix : model.tracker(for: e.project).titlePrefix,
                                 finding: findings[e.id])
                }
                if !covered.isEmpty {
                    DisclosureGroup(isExpanded: model.fold("backlog.covered")) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(covered) { e in
                                ProposedCard(entry: e, prefix: e.project == project.id ? prefix : model.tracker(for: e.project).titlePrefix,
                                             finding: findings[e.id])
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Probably already created (\(covered.count))").font(.headline)
                            .help("Something very like these exists already. Drop each, or say it isn't the same, to bring it back.")
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: project.id + "|" + waiting.map(\.id.rawValue).joined(separator: ",")) { model.checkDuplicates(scope: project.id) }
    }
}

/// Whether the proposals were checked against the tracker for items that already exist, and a way to check again.
private struct DuplicateCheckStatus: View {
    @Environment(AppModel.self) private var model
    let scope: String

    var body: some View {
        let checking = model.duplicateChecking.contains(scope)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if checking {
                ProgressView().controlSize(.small)
                Text("Looking for items that already exist…")
            } else if let error = model.duplicateErrors[scope] {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't search the tracker for duplicates: \(error)")
            } else if let at = model.duplicateChecked[scope] {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text("Checked for duplicates in the tracker \(at.formatted(.relative(presentation: .named))).")
            } else {
                Text("Proposals are checked for items that already exist.")
            }
            if !checking {
                Button("Check Again") { model.checkDuplicates(scope: scope, force: true) }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProposedCard: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry
    let prefix: String
    let finding: DuplicateFinding?
    @State private var expanded = false

    var body: some View {
        let busy = model.busyEntries.contains(entry.id)
        let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ChipRow(spacing: 6) {
                    KindChip(kind: entry.backlogKind)
                    ForEach(entry.scopes, id: \.self) { ProjectChip(project: $0) }
                    TagChips(tags: entry.tags, key: .backlog)
                }
                Spacer()
                if !entry.date.isEmpty { Text(DateText.display(entry.date)).font(.caption).foregroundStyle(.secondary) }
                if busy { ProgressView().controlSize(.small) }
            }
            (Text(prefix).foregroundStyle(.tertiary) + Text(entry.title))
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            if !entry.summary.isEmpty {
                Text(entry.summary).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !body.isEmpty {
                Text(Self.markdown(body))
                    .font(.callout)
                    .lineLimit(expanded ? nil : 6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if body.split(separator: "\n").count > 6 || body.count > 420 {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if !entry.sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.sources, id: \.self) { SourceView(source: $0) }
                }
                .font(.caption)
            }
            BacklogLinksRow(entry: entry)
            if let finding, finding.verdict != .none {
                DuplicateBox(entry: entry, finding: finding)
            }
            HStack(spacing: 10) {
                Button(BacklogBatchCreateSheet.createLabel(model.tracker(for: entry.project).kind) + "…") {
                    model.backlogCreateRequest = BacklogCreateRequest(entry: entry.id)
                }
                    .buttonStyle(.borderedProminent)
                Button("Edit") {
                    model.openNow(entry.id)
                    model.isEditing = true
                }
                Button("Open") { model.openNow(entry.id) }
                Spacer()
                Button("Reject", role: .destructive) { model.rejectBacklog(entry.id) }
            }
            .controlSize(.small)
            .disabled(busy)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
        .entryContextMenu(entry.id)
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}


/// A small heading inside an assignee section: the stage the rows below are at.
private struct StageHeader: View {
    let stage: TrackerBacklog.Stage
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: StageBadge.icon(stage)).foregroundStyle(StageBadge.color(stage))
            Text("\(StageBadge.title(stage).uppercased()) · \(count)")
                .foregroundStyle(.secondary)
        }
        .font(.caption2.weight(.bold))
        .padding(.top, 6)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }
}

/// The tasks under a PBI or bug, each with its state, and a way to move them on.
struct TaskList: View {
    @Environment(AppModel.self) private var model
    let item: TrackerBacklog.Item

    var body: some View {
        let open = item.openTasks
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tasks").font(.headline)
                Text("\(item.tasksDone) of \(item.tasksTotal) done").foregroundStyle(.secondary)
                Spacer()
                if !open.isEmpty {
                    Button(open.count == 1 ? "Mark Done" : "Mark All \(open.count) Done") {
                        model.setTasks(open.map(\.id), state: "Done")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(item.hasLooseTasks ? .orange : .accentColor)
                    .controlSize(.small)
                    .disabled(open.contains { model.busyTasks.contains($0.id) })
                }
            }
            if item.hasLooseTasks {
                Label("This \(item.isBug ? "bug" : "PBI") is \(item.stage.title.lowercased()), but \(open.count) task\(open.count == 1 ? " is" : "s are") still open.",
                      systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            ForEach(item.tasks) { TaskRow(task: $0) }
        }
    }
}

private struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TrackerBacklog.Task

    var body: some View {
        let busy = model.busyTasks.contains(task.id)
        HStack(spacing: 8) {
            Button {
                model.setTasks([task.id], state: task.isDone ? "New" : "Done")
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : task.isInProgress ? "circle.lefthalf.filled" : "circle")
                    .foregroundStyle(task.isDone ? Color.green : task.isInProgress ? Color.blue : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help(task.isDone ? "Done. Click to reopen." : "Mark Done")
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).strikethrough(task.isDone, color: .secondary).foregroundStyle(task.isDone ? .secondary : .primary)
                Text([task.state, task.assignee].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if busy { ProgressView().controlSize(.small) }
            Menu {
                ForEach(["New", "In Progress", "Done"], id: \.self) { state in
                    Button(state) { model.setTasks([task.id], state: state) }.disabled(task.state == state)
                }
            } label: {
                Text(task.state).font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(busy)
        }
        .padding(.vertical, 2)
    }
}

/// At the top of Backlog: finished PBIs and bugs that still have open tasks. Opens them in the content area.
private struct LooseTasksRow: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        let selected = model.showLooseTasks
        HStack(spacing: 8) {
            Image(systemName: "checklist.unchecked").foregroundStyle(selected ? Color.white : Color.orange)
            Text("Tasks to close").fontWeight(.medium)
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(minWidth: 18, minHeight: 18)
                .background(selected ? Color.white.opacity(0.25) : Color.orange.opacity(0.18), in: Capsule())
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .foregroundStyle(selected ? Color.white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.orange : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { model.showLooseTaskList() }
        .help("Resolved or done PBIs and bugs whose tasks aren't all Done yet")
        .listRowSeparator(.hidden)
    }
}

/// The content area for "Tasks to close": each finished item with its open tasks, to mark Done.
struct LooseTasksView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject

    var body: some View {
        let items = model.trackerItems(scope: project.id).filter(\.hasLooseTasks)
            .sorted { ($0.mine ? 0 : 1, $0.id) < ($1.mine ? 0 : 1, $1.id) }
        let allOpen = items.flatMap(\.openTasks).map(\.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Tasks to close").font(.title2.weight(.semibold))
                    Text("\(items.count) finished item\(items.count == 1 ? "" : "s") with open tasks").foregroundStyle(.secondary)
                    Spacer()
                    if allOpen.count > 1 {
                        Button("Mark All \(allOpen.count) Done") { model.setTasks(allOpen, state: "Done") }
                            .disabled(allOpen.contains { model.busyTasks.contains($0) })
                    }
                }
                if items.isEmpty {
                    Text("Every resolved or done item has its tasks closed.").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            KindChip(kind: item.isBug ? "bug" : "pbi")
                            Button("#\(String(item.id))") { model.selectWorkItem(item.id) }.buttonStyle(.link)
                            StageBadge(stage: item.stage)
                            Spacer()
                            AssigneeBadge(item: item)
                        }
                        Text(item.title).font(.headline)
                        TaskList(item: item)
                    }
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(22)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The session header's work item: open it in the scope's tracker (or under Backlog for Mindmill's own), or copy
/// its link.
struct WorkItemHeaderButton: View {
    @Environment(AppModel.self) private var model
    let item: String
    let scope: String

    var body: some View {
        let url = model.workItemURL(item, project: scope)
        let local = model.tracker(for: scope).kind == "local"
        Menu {
            if local, let n = Int(item) {
                Button("Show in Backlog") { model.showLocalItem(n, project: scope) }
            } else if let url {
                Button("Open in \(model.trackerName(scope))") { NSWorkspace.shared.open(url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            } else {
                Text("The tracker settings don't say where \(model.trackerName(scope)) is.")
                Button("Tracker Settings…") { model.projectSettingsRequest = ProjectSettingsRequest(project: scope) }
            }
        } label: {
            Label(Int(item) != nil ? "#\(item)" : item, systemImage: "list.bullet.rectangle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("See the work item in \(model.trackerName(scope))")
    }
}
