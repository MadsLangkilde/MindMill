import AppKit
import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    static let readyTag = "ready:"
}

// MARK: Sprint news

/// The sprint news for the current project: a new sprint to review the last one for, or a sprint that ended with
/// nothing after it. In Build (Ready to Start, My Work) and Today; nothing when there is no news.
struct SprintMomentCards: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let moments = model.sprintMoments
        if !moments.isEmpty {
            VStack(spacing: 8) {
                ForEach(moments) { SprintMomentCard(moment: $0) }
            }
        }
    }
}

struct SprintMomentCard: View {
    @Environment(AppModel.self) private var model
    let moment: SprintMoment

    var body: some View {
        let t = moment.tracker
        let sprint = moment.review?.sprint ?? t.previous
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 200) {
                Image(systemName: moment.needsNextSprint ? "calendar.badge.exclamationmark" : "flag.checkered")
                    .font(.title3).foregroundStyle(moment.needsNextSprint ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(moment.headline).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(moment.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if let sprint {
                        Button("Review \(sprint.name)…") { model.openSprintReview(moment) }
                            .buttonStyle(.borderedProminent)
                            .help("Decide, item by item, what happens to what it left unfinished. Nothing changes until you apply.")
                    }
                }
                .fixedSize()
            }
            ChipRow(spacing: 8) {
                if moment.needsNextSprint {
                    if t.canCreate {
                        Button(model.sprintCreating.contains(t.key) ? "Adding…" : "Add the Next Sprint") { model.createNextSprint(t) }
                            .disabled(model.sprintCreating.contains(t.key))
                            .help("The same length as the last one, starting the day after it ended (or today)")
                    } else if !t.createURL.isEmpty {
                        Button("Add It in \(t.trackerName)…") { model.createNextSprint(t) }
                            .help("Mindmill doesn't create iterations in Azure DevOps. This opens the project's iteration settings: add the sprint there and select it for the team.")
                    }
                }
                Button("Not Now") { model.snoozeSprint(t.key) }
                    .help("Hide this until tomorrow")
                if let sprint {
                    Button("Done Reviewing") { model.finishSprintReview(t.key, sprint: sprint.path) }
                        .help("Don't ask about \(sprint.name) again")
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Pills

/// A row of choices as capsules that wrap whole, never squeezed.
struct ChoicePill: View {
    let title: String
    let selected: Bool
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.1), in: Capsule())
                .foregroundStyle(selected ? Color.white : .primary)
                .fixedSize()
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct OwnerPills: View {
    @Binding var owner: WorkFilter.Owner

    var body: some View {
        ChipRow(spacing: 6) {
            ForEach(WorkFilter.Owner.allCases, id: \.self) { o in
                ChoicePill(title: o.title, selected: owner == o, help: help(o)) { owner = o }
            }
        }
    }

    private func help(_ o: WorkFilter.Owner) -> String {
        switch o {
        case .me: return "Only what is assigned to you"
        case .meAndUnassigned: return "Yours, and what nobody has yet"
        case .everyone: return "The whole team's"
        }
    }
}

// MARK: Ready to Start

/// Build's sidebar row for what can be started now in the current project.
struct ReadySidebarRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scope = model.projectID
        let count = scope.map { model.startableWork(scope: $0, filter: WorkFilter.load(scope: $0)).count } ?? 0
        let news = !model.sprintMoments.isEmpty
        HStack(spacing: 8) {
            Image(systemName: "play.circle").foregroundStyle(count > 0 ? Color.green : Color.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ready to Start").font(.body.weight(.medium))
                Text(model.tracker == nil ? "In the current sprint" : count == 0 ? "Nothing waiting" : "\(count) in the current sprint")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if news {
                Image(systemName: "flag.checkered").foregroundStyle(Color.accentColor)
                    .help("A sprint changed: review what the last one left unfinished")
            }
        }
        .padding(.vertical, 3)
        .onAppear {
            model.refreshTracker()
            model.checkSprints()
        }
    }
}

/// What can be started now in the current sprint: not started, no session on it yet, filtered by whose it is and
/// what kind. Start is one click away. The filter is remembered per scope.
struct ReadyToStartView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = WorkFilter()
    @State private var loadedScope: String?

    var body: some View {
        let scope = model.projectID
        VStack(spacing: 0) {
            header(scope)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SprintMomentCards()
                    if let scope { content(scope) }
                }
                .padding(18)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Ready to Start")
        .onAppear {
            loadFilter(scope)
            model.refreshTracker()
            model.checkSprints()
        }
        .onChange(of: model.projectID) { _, new in loadFilter(new) }
        .onChange(of: filter) { _, f in
            if let s = loadedScope { f.save(scope: s) }
        }
    }

    private func loadFilter(_ scope: String?) {
        loadedScope = scope
        filter = scope.map { WorkFilter.load(scope: $0) } ?? WorkFilter()
    }

    private func header(_ scope: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Ready to Start").font(.title2.weight(.semibold)).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                if let scope { sprintMenu(scope) }
                Button {
                    model.refreshTracker(force: true)
                    model.checkSprints(force: true)
                } label: {
                    if model.trackerLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .help("Read the tracker again")
            }
            if let scope, let line = sprintLine(scope) {
                Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            OwnerPills(owner: $filter.owner)
            ChipRow(spacing: 6) {
                ChoicePill(title: "PBIs", selected: filter.pbis, help: "Show product backlog items") { filter.pbis.toggle() }
                ChoicePill(title: "Bugs", selected: filter.bugs, help: "Show bugs") { filter.bugs.toggle() }
                ChoicePill(title: "Tasks", selected: filter.tasks, help: "Show tasks still to do under work that isn't finished") { filter.tasks.toggle() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func sprintLine(_ scope: String) -> String? {
        guard let t = model.sprintTracker(scope: scope) else { return nil }
        if t.throughClaude { return "\(t.trackerName)'s sprints are read through \(Brain.name), so Mindmill can't tell when a new one starts. Review the last sprint from the Sprint menu." }
        if !t.reachable { return "Can't read the sprints: \(t.note)" }
        switch t.state {
        case .running:
            guard let c = t.current else { return nil }
            return "\(c.name), until \(DateText.short(c.finish))" + (t.next.map { "; then \($0.name)" } ?? "")
        case .between: return "Between sprints" + (t.next.map { "; \($0.name) starts \(DateText.short($0.start))" } ?? "")
        case .ended: return t.previous.map { "\($0.name) has ended and no sprint follows it yet." }
        case .off: return "Sprints are off for this scope: everything not started counts."
        case .none, .upcoming, .unknown: return nil
        }
    }

    private func sprintMenu(_ scope: String) -> some View {
        let t = model.sprintTracker(scope: scope)
        return Menu("Sprint") {
            Button("Review Last Sprint…") { model.reviewLastSprint(scope: scope) }
            if let t, t.state == .ended || t.state == .between || t.next == nil {
                if t.canCreate {
                    Button("Add the Next Sprint") { model.createNextSprint(t) }
                } else if !t.createURL.isEmpty {
                    Button("Add the Next Sprint in \(t.trackerName)…") { model.createNextSprint(t) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The last sprint's leftovers, and the next sprint")
    }

    @ViewBuilder
    private func content(_ scope: String) -> some View {
        let items = model.startableWork(scope: scope, filter: filter)
        if model.tracker == nil {
            if let e = model.trackerError {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the tracker…").foregroundStyle(.secondary)
                }
            }
        } else if !filter.pbis && !filter.bugs && !filter.tasks {
            ListEmptyState(title: "Pick what to show", systemImage: "line.3.horizontal.decrease.circle",
                           message: "Turn on PBIs, bugs or tasks above.")
        } else if items.isEmpty {
            ListEmptyState(title: "Nothing ready to start", systemImage: "checkmark.circle",
                           message: filter.owner == .everyone
                               ? "Everything in the current sprint is started or has a session working on it."
                               : "Nothing of yours waits in the current sprint. Widen the filter to see unassigned work or the team's.")
        } else {
            VStack(spacing: 8) { ForEach(items) { StartableRow(work: $0) } }
        }
    }
}

struct StartableRow: View {
    @Environment(AppModel.self) private var model
    let work: StartableWork

    var body: some View {
        AdaptiveCard {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 24)
        } info: {
            VStack(alignment: .leading, spacing: 4) {
                Text(work.title).font(.body.weight(.medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                ChipRow(spacing: 6) {
                    Text("#\(String(work.number))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Chip(text: work.state, color: .gray)
                    if work.isUnassigned {
                        Chip(text: "Unassigned", color: .orange)
                    } else {
                        Text(work.mine ? "You" : work.assignee).font(.caption).foregroundStyle(.secondary)
                    }
                    if work.task == nil, work.item.tasksTotal > 0 {
                        Text("\(work.item.tasksDone)/\(work.item.tasksTotal) tasks").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.index.projects.count > 1 { ProjectChip(project: work.item.scope) }
                }
                if work.task != nil {
                    Text("In #\(String(work.item.id)) \(work.item.title)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        } action: {
            Button { model.startReady(work) } label: { Label("Start…", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .help(work.isUnassigned ? "Choose the pace and strategy, then start; it is assigned to you as it starts"
                                        : "Choose the pace and strategy, then start")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            if let url = URL(string: work.item.url), !work.item.url.isEmpty, work.task == nil {
                Button("Open in \(TrackerLink.name(forURL: work.item.url))") { NSWorkspace.shared.open(url) }
            }
            Button("Show in Backlog") { model.showInBacklog(work.item) }
            Button("Copy ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(work.number), forType: .string)
            }
        }
    }

    private var icon: String {
        switch work.kind {
        case "bug": return "ladybug.fill"
        case "task": return "checklist"
        default: return "doc.text.fill"
        }
    }

    private var color: Color {
        switch work.kind {
        case "bug": return .red
        case "task": return .purple
        default: return .blue
        }
    }
}

// MARK: Review

/// The calm review of a finished sprint: each unfinished item with a suggested decision the user can change.
/// Nothing is written until Apply, which asks once for the whole batch and shows each item's result.
struct SprintReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SprintReviewRequest
    @State private var data: SprintReviewData?
    @State private var loadError: String?
    @State private var decisions: [Int: SprintDecision] = [:]
    @State private var owner: WorkFilter.Owner = .me
    @State private var results: [Int: SprintApplyResult] = [:]
    @State private var applying = false
    @State private var confirming = false
    @State private var applyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review \(request.sprint.name)").font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            OwnerPills(owner: $owner)
            if let loadError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { Task { await load() } }
                }
            }
            if let applyError {
                Label(applyError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let data {
                        let shown = visible(data)
                        if shown.isEmpty {
                            ListEmptyState(title: data.items.isEmpty ? "Nothing left unfinished" : "Nothing here for this filter",
                                           systemImage: "checkmark.circle",
                                           message: data.items.isEmpty ? "\(request.sprint.name) finished everything it had."
                                               : "\(data.items.count) unfinished item\(data.items.count == 1 ? " belongs" : "s belong") to others. Widen the filter to see them.")
                        }
                        ForEach(shown) { item in
                            SprintReviewRow(item: item, review: data, decision: binding(item.id, data), result: results[item.id],
                                            suggestion: suggestion(item, data))
                        }
                    } else if loadError == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading \(request.sprint.name)…").foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 480)
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 680, maxWidth: 820)
        .task { await load() }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button("Apply \(pending.count) Change\(pending.count == 1 ? "" : "s")") { Task { await apply(pending) } }
        } message: {
            Text(confirmMessage)
        }
    }

    private var subtitle: String {
        guard let data else { return "What it left unfinished, and what to do with each." }
        let target = data.target.map { "Move to: \($0.name)." } ?? "No next sprint yet: items can stay, go back to the backlog, or be finished."
        return "\(data.items.count) unfinished item\(data.items.count == 1 ? "" : "s"). Suggestions are preselected; nothing changes until you apply. \(target)"
    }

    @ViewBuilder private var footer: some View {
        let changes = pending
        ChipRow(spacing: 8) {
            if let data, let target = data.target, !visible(data).isEmpty {
                Button("Move All Shown to \(target.name)") {
                    decisions = SprintReview.moveAll(visible(data), to: target, decisions: decisions)
                }
                .help("Carry every unfinished item shown, with its open tasks, over to \(target.name)")
            }
            if !failed.isEmpty {
                Button("Retry \(failed.count) Failed") { Task { await apply(failed) } }
                    .disabled(applying)
            }
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                closeButtons
                Spacer(minLength: 8)
                applyButton(changes.count)
            }
            VStack(alignment: .trailing, spacing: 8) {
                applyButton(changes.count)
                HStack(spacing: 8) { closeButtons }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder private var closeButtons: some View {
        Button("Not Now") {
            model.snoozeSprint(request.key)
            dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .help("Close; the review comes back tomorrow")
        Button("Done Reviewing") {
            model.finishSprintReview(request.key, sprint: request.sprint.path)
            dismiss()
        }
        .help("Close, and don't ask about \(request.sprint.name) again")
    }

    private func applyButton(_ count: Int) -> some View {
        HStack(spacing: 8) {
            if applying { ProgressView().controlSize(.small) }
            Button("Apply \(count) Change\(count == 1 ? "" : "s")…") { confirming = true }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0 || applying)
        }
        .fixedSize()
    }

    private var names: [String] { model.workItemNames }

    private func visible(_ data: SprintReviewData) -> [TrackerBacklog.Item] {
        data.items.filter { owner.accepts(mine: Startable.isMine($0.assignee, flagged: $0.mine, me: names), unassigned: $0.isUnassigned) }
    }

    private func suggestion(_ item: TrackerBacklog.Item, _ data: SprintReviewData) -> SprintSuggestion {
        let merged = model.pullRequests?.closed.contains { $0.completed && $0.workItems.contains(item.id) } ?? false
        return SprintReview.suggest(item, in: data, mergedPR: merged, hasSession: model.hasBuildSession(item.sessionKey))
    }

    private func binding(_ id: Int, _ data: SprintReviewData) -> Binding<SprintDecision> {
        Binding(get: { decisions[id] ?? .keep }, set: { decisions[id] = $0 })
    }

    /// The changes to apply: those chosen for the items shown, not yet applied.
    private var pending: [Int: SprintDecision] {
        guard let data else { return [:] }
        let shown = Set(visible(data).map(\.id))
        return decisions.filter { shown.contains($0.key) && $0.value.changes && results[$0.key]?.ok != true }
    }

    private var failed: [Int: SprintDecision] {
        decisions.filter { results[$0.key]?.ok == false }
    }

    private var confirmTitle: String {
        let tracker = TrackerSprints.trackerName(data?.kind ?? "")
        return "Apply \(pending.count) change\(pending.count == 1 ? "" : "s") in \(tracker)?"
    }

    private var confirmMessage: String {
        guard let data else { return "" }
        var counts: [String: Int] = [:]
        for (_, d) in pending { counts[SprintReview.title(d, in: data), default: 0] += 1 }
        let lines = counts.sorted { $0.key < $1.key }.map { "\($0.value) × \($0.key)" }
        return lines.joined(separator: "\n") + "\n\nOpen tasks go along with moved items and are finished with completed ones."
    }

    private func load() async {
        loadError = nil
        do {
            let d = try await model.loadSprintReview(scope: request.scope, sprint: request.sprint)
            data = d
            var picked: [Int: SprintDecision] = [:]
            for item in d.items { picked[item.id] = suggestion(item, d).decision }
            decisions = picked
            if visible(d).isEmpty, !d.items.isEmpty, owner == .me { owner = .meAndUnassigned }
        } catch {
            loadError = (error as? KBCLIError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription
        }
    }

    private func apply(_ chosen: [Int: SprintDecision]) async {
        guard let data, !chosen.isEmpty else { return }
        applying = true
        applyError = nil
        defer { applying = false }
        do {
            let got = try await model.applySprintDecisions(chosen, review: data, scope: request.scope)
            for r in got { results[r.id] = r }
            let bad = got.filter { !$0.ok }.count
            model.notice = bad == 0 ? "Applied \(got.count) change\(got.count == 1 ? "" : "s") to \(request.sprint.name)'s leftovers."
                : "\(bad) of \(got.count) changes failed; see the review."
        } catch {
            applyError = (error as? KBCLIError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription
        }
    }
}

struct SprintReviewRow: View {
    @Environment(AppModel.self) private var model
    let item: TrackerBacklog.Item
    let review: SprintReviewData
    @Binding var decision: SprintDecision
    let result: SprintApplyResult?
    let suggestion: SprintSuggestion

    var body: some View {
        let session = model.sessions(forKey: item.sessionKey).first
        AdaptiveCard {
            Image(systemName: item.isBug ? "ladybug.fill" : "doc.text.fill").font(.title3)
                .foregroundStyle(item.isBug ? Color.red : Color.blue).frame(width: 24)
        } info: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                ChipRow(spacing: 6) {
                    Text("#\(String(item.id))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Chip(text: item.state, color: item.stage == .notStarted ? .gray : .blue)
                    if item.isUnassigned { Chip(text: "Unassigned", color: .orange) } else {
                        Text(item.assignee).font(.caption).foregroundStyle(.secondary)
                    }
                    if item.tasksTotal > 0 {
                        Text("\(item.openTasks.count) of \(item.tasksTotal) tasks open").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(item.prs, id: \.self) { pr in
                        Button("!\(String(pr))") { model.openPRInBuild(pr) }.buttonStyle(.link).font(.caption)
                    }
                    if let session { SessionLinkButton(session: session).controlSize(.small) }
                }
                Text("Suggested: \(SprintReview.title(suggestion.decision, in: review)) · \(suggestion.reason)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let result {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(result.ok ? Color.green : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } action: {
            Picker("Decision", selection: $decision) {
                ForEach(options, id: \.self) { d in Text(SprintReview.title(d, in: review)).tag(d) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(result?.ok == true)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var options: [SprintDecision] {
        var out: [SprintDecision] = [.keep]
        if let t = review.target { out.append(.move(t.path)) }
        out.append(.backlog)
        out += review.finishing(item).map { .state($0.name) }
        if let r = review.removedState(item) { out.append(.state(r.name)) }
        if !out.contains(decision) { out.append(decision) }
        return out
    }
}
