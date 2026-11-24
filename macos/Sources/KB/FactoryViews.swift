import KBCore
import KBEngine
import SwiftUI

/// What to show in the questions sheet: every open question, or those about one work item.
struct FactoryQuestionsRequest: Identifiable {
    let id = UUID()
    var workItem: Int?
}

/// The software factory in Build: a header, then panels the user arranges per factory (the board from Up next to
/// Done, the picked item's details, history, things to approve, and more).
struct FactoryView: View {
    @Environment(AppModel.self) private var model
    let factoryID: String?
    @State private var selected: Int?
    @State private var editing = false
    @State private var questions: FactoryQuestionsRequest?

    var body: some View {
        let f = model.factory(factoryID) ?? model.factories.first
        Group {
            if let f {
                let board = FactoryBoardData(factory: f, model: model)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        FactoryHeader(factory: f, board: board, editing: $editing)
                        if editing { FactoryLayoutBar(factory: f) { editing = false } }
                        ForEach(Array(f.dashboard.rows.enumerated()), id: \.offset) { _, row in
                            if row.count == 2 {
                                BoardLayout(minColumnWidth: 340, spacing: 16) {
                                    ForEach(row) { slot in panel(slot, f, board) }
                                }
                            } else if let slot = row.first {
                                panel(slot, f, board)
                            }
                        }
                        if f.dashboard.panels.isEmpty {
                            ListEmptyState(title: "No panels", systemImage: "square.dashed",
                                           message: "Add the board and other panels back with Customize.") {
                                Button("Customize") { editing = true }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 1600, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.25), value: f.dashboard)
                }
                .onChange(of: f.id) {
                    selected = nil
                    editing = false
                }
                .sheet(item: $questions) { FactoryQuestionsSheet(factoryID: f.id, request: $0) }
            } else {
                FactoryIntro()
            }
        }
        .navigationTitle("Software Factory")
        .onAppear {
            model.loadFactoriesIfNeeded()
            model.startCrewEngine()
            if model.tracker == nil { model.refreshTracker() }
        }
    }

    @ViewBuilder
    private func panel(_ slot: FactoryPanelSlot, _ f: Factory, _ board: FactoryBoardData) -> some View {
        FactoryPanelChrome(factory: f, slot: slot, editing: editing, accessory: { accessory(slot.kind, f, board) }) {
            switch slot.kind {
            case .board:
                FactoryBoard(factory: f, board: board, selected: $selected) { questions = FactoryQuestionsRequest(workItem: $0) }
            case .details:
                if let selected, let card = board.card(selected) {
                    FactoryItemDetail(factory: f, card: card, lane: board.lane(of: selected),
                                      openQuestions: { questions = FactoryQuestionsRequest(workItem: selected) }) { self.selected = nil }
                } else {
                    Text("Click an item on the board to see what its session does, its pull request and what happened with it.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .history: FactoryHistory(factory: f)
            case .approvals: FactoryApprovals(factory: f)
            case .questions: FactoryQuestionList(factory: f, workItem: nil)
            case .stats: FactoryStats(factory: f, board: board)
            case .rules: FactoryRuleChips(rules: f.rules)
            }
        }
    }

    @ViewBuilder
    private func accessory(_ kind: FactoryPanel, _ f: Factory, _ board: FactoryBoardData) -> some View {
        switch kind {
        case .board:
            let n = f.run?.openQuestions.count ?? 0
            if n > 0 {
                Button { questions = FactoryQuestionsRequest() } label: {
                    Label("\(n) question\(n == 1 ? "" : "s") for you", systemImage: "hand.raised.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }
        case .approvals:
            let n = model.factoryProposals(f).count
            if n > 0 { Text("\(n)").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
        default:
            EmptyView()
        }
    }
}

/// A panel's frame: its title bar (with a fold button, and when customizing, buttons to move, resize and remove it),
/// then its content.
private struct FactoryPanelChrome<Accessory: View, Content: View>: View {
    @Environment(AppModel.self) private var model
    let factory: Factory
    let slot: FactoryPanelSlot
    let editing: Bool
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editing {
                titleBar.draggable(slot.kind.rawValue) {
                    Label(slot.kind.title, systemImage: slot.kind.icon).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                titleBar
            }
            if !slot.collapsed { content }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if editing {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(targeted ? Color.accentColor : Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [5, 4]))
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard editing, let raw = items.first, let kind = FactoryPanel(rawValue: raw) else { return false }
            model.editFactoryDashboard(factory.id) { $0.move(kind, to: slot.kind) }
            return true
        } isTargeted: { targeted = editing && $0 }
    }

    private var titleBar: some View {
        let d = factory.dashboard
        let i = d.panels.firstIndex { $0.kind == slot.kind } ?? 0
        return HStack(spacing: 8) {
            if editing {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                    .help("Drag onto another panel to put it there")
            }
            Button {
                model.editFactoryDashboard(factory.id) { $0.setCollapsed(slot.kind, !slot.collapsed) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(slot.collapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                    Image(systemName: slot.kind.icon).foregroundStyle(Color.accentColor)
                    Text(slot.kind.title).font(.headline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(slot.collapsed ? "Show \(slot.kind.title)" : "Fold \(slot.kind.title) away")
            accessory
            Spacer(minLength: 8)
            if editing {
                HStack(spacing: 4) {
                    Button { model.editFactoryDashboard(factory.id) { $0.move(slot.kind, by: -1) } } label: { Image(systemName: "arrow.up") }
                        .disabled(i == 0).help("Move up")
                    Button { model.editFactoryDashboard(factory.id) { $0.move(slot.kind, by: 1) } } label: { Image(systemName: "arrow.down") }
                        .disabled(i == d.panels.count - 1).help("Move down")
                    Picker("Width", selection: Binding(get: { slot.wide }, set: { w in model.editFactoryDashboard(factory.id) { $0.setWide(slot.kind, w) } })) {
                        Text("Full").tag(true)
                        Text("Half").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Half-width panels sit side by side in pairs")
                    Button { model.editFactoryDashboard(factory.id) { $0.remove(slot.kind) } } label: { Image(systemName: "xmark") }
                        .help("Remove this panel; add it back with Add Panel")
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
    }
}

/// While customizing: what to do, panels to add, back to the standard layout, and Done.
private struct FactoryLayoutBar: View {
    @Environment(AppModel.self) private var model
    let factory: Factory
    let done: () -> Void

    var body: some View {
        AdaptiveCardLayout(minInfoWidth: 240) {
            Text("Drag panels by their title to rearrange them, or use the arrows. Half-width panels sit side by side in pairs. The layout is this factory's own.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Menu {
                    ForEach(factory.dashboard.hidden) { kind in
                        Button { model.editFactoryDashboard(factory.id) { $0.add(kind) } } label: {
                            Label("\(kind.title): \(kind.summary)", systemImage: kind.icon)
                        }
                    }
                } label: {
                    Label("Add Panel", systemImage: "plus")
                }
                .disabled(factory.dashboard.hidden.isEmpty)
                .fixedSize()
                Button("Reset") { model.editFactoryDashboard(factory.id) { $0 = .standard } }
                    .help("Back to the board, details, history and approvals")
                Button("Done", action: done).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .fixedSize()
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A card on the board: a work item the factory works on or worked on, or one it would take next.
enum FactoryCard: Identifiable {
    case task(FactoryTask)
    case next(TrackerBacklog.Item)

    var id: Int {
        switch self {
        case .task(let t): return t.workItem
        case .next(let i): return i.id
        }
    }

    var title: String {
        switch self {
        case .task(let t): return t.title
        case .next(let i): return i.title
        }
    }

    var scope: String {
        switch self {
        case .task(let t): return t.scope
        case .next(let i): return i.scope
        }
    }
}

/// The factory's work items sorted into the board's lanes.
struct FactoryBoardData {
    var lanes: [FactoryLane: [FactoryCard]] = [:]
    var moreUpNext = 0
    var slotsInUse = 0
    var trackerMissing = false

    @MainActor
    init(factory f: Factory, model: AppModel) {
        let run = f.run
        for t in (run?.tasks ?? []).reversed() {
            let s = model.session(t.sessionID)
            let waits = (run?.openQuestions.contains { $0.sessionID == t.sessionID } ?? false) || (s?.crewState.needsUser ?? false)
            let slot = model.occupiesSlot(t, in: f)
            if slot { slotsInUse += 1 }
            lanes[FactoryLane.of(t, occupiesSlot: slot, waitsOnUser: waits), default: []].append(.task(t))
        }
        if let backlog = model.tracker {
            let next = model.nextItems(f, backlog: backlog)
            lanes[.upNext] = next.prefix(8).map { .next($0) }
            moreUpNext = max(0, next.count - 8)
        } else {
            trackerMissing = true
        }
    }

    /// Changes when a card moves to another lane, so the board animates the move.
    var signature: [String] {
        FactoryLane.allCases.map { lane in lane.rawValue + ":" + cards(lane).map { String($0.id) }.joined(separator: ",") }
    }

    func cards(_ lane: FactoryLane) -> [FactoryCard] { lanes[lane] ?? [] }
    func count(_ lane: FactoryLane) -> Int { cards(lane).count + (lane == .upNext ? moreUpNext : 0) }
    func card(_ id: Int) -> FactoryCard? { lanes.values.lazy.flatMap { $0 }.first { $0.id == id } }
    func lane(of id: Int) -> FactoryLane? { lanes.first { $0.value.contains { $0.id == id } }?.key }
}

private struct FactoryIntro: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gearshape.2.fill").font(.system(size: 44)).foregroundStyle(Color.accentColor)
            Text("Software Factory").font(.largeTitle.weight(.semibold))
            Text("Let \(Brain.name) pick up work items and build them, one after another, by rules you set: which items it may take, how it builds them, when it stops to ask you, and for how long it runs. Questions never stop it: it carries on with what it can until you answer.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button {
                model.factoryEditor = FactoryEditRequest(factoryID: nil)
            } label: {
                Label("Set Up a Factory…", systemImage: "plus").padding(.horizontal, 8).padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: Header

private struct FactoryHeader: View {
    @Environment(AppModel.self) private var model
    let factory: Factory
    let board: FactoryBoardData
    @Binding var editing: Bool
    @State private var confirmDelete = false
    @State private var name = ""
    @FocusState private var naming: Bool

    var body: some View {
        let run = factory.run
        AdaptiveCardLayout(minInfoWidth: 280) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "gearshape.2.fill").foregroundStyle(Color.accentColor).font(.title2)
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .focused($naming)
                        .onSubmit(commitName)
                        .onChange(of: naming) { _, on in if !on { commitName() } }
                        .help("Click to rename the factory")
                }
                SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 6) {
                        Text([timeLine(run), summary].compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if run?.status != .stopped, let progress = run?.progress(at: context.date) {
                            ProgressView(value: progress).progressViewStyle(.linear).tint(.green).frame(maxWidth: 360)
                        }
                    }
                }
                if !factory.rules.problems.isEmpty {
                    Text(factory.rules.problems.joined(separator: " ")).font(.callout).foregroundStyle(.orange)
                }
            }
            ChipRow(spacing: 8) {
                if factory.isRunning {
                    if run?.isPaused == true {
                        Button { model.resumeFactory(factory.id) } label: { Label("Resume", systemImage: "play.fill") }
                            .help("Take new work items again")
                    } else if run?.status == .running {
                        Button { model.pauseFactory(factory.id) } label: { Label("Pause", systemImage: "pause.fill") }
                            .help("Take no new work items for now. Sessions working carry on.")
                    }
                    if run?.status == .running {
                        Button { model.stopFactory(factory.id) } label: { Label("Stop", systemImage: "stop.fill") }
                            .help("Start nothing new. Sessions working finish the step they're on and push.")
                    }
                } else {
                    Button { model.startFactory(factory.id) } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(!factory.rules.problems.isEmpty)
                        .help(factory.rules.problems.first ?? "Start picking work items by these rules")
                }
                Button { model.factoryEditor = FactoryEditRequest(factoryID: factory.id) } label: { Label("Edit Rules…", systemImage: "slider.horizontal.3") }
                Button { editing.toggle() } label: { Label("Customize", systemImage: "square.grid.2x2") }
                    .help("Arrange this factory's panels, add more or leave some out")
                Menu {
                    Button("Rename") { naming = true }
                    Button("New Factory…") { model.factoryEditor = FactoryEditRequest(factoryID: nil) }
                    Divider()
                    Button("Delete Factory…", role: .destructive) { confirmDelete = true }
                        .disabled(factory.isRunning)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                FactoryStatusPill(factory: factory)
            }
            .fixedSize()
        }
        .onAppear { name = factory.name }
        .onChange(of: factory.name) { _, n in if !naming { name = n } }
        .onChange(of: factory.id) { name = factory.name }
        .alert("Delete “\(factory.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteFactory(factory.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its rules and its history go. Sessions it started stay in Build.")
        }
    }

    private func commitName() {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { name = factory.name } else { model.renameFactory(factory.id, t) }
    }

    private var summary: String? {
        guard factory.run != nil else { return nil }
        var parts = ["\(board.slotsInUse) of \(factory.rules.maxParallel) places in use"]
        let n = board.count(.needsYou)
        if n > 0 { parts.append("\(n) need\(n == 1 ? "s" : "") you") }
        return parts.joined(separator: " · ")
    }

    private func timeLine(_ run: FactoryRun?) -> String? {
        guard let run else { return "Not started yet." }
        var started = "Started \(run.started.formatted(date: .abbreviated, time: .shortened))"
        if let again = run.resumed { started += " · started again \(again.formatted(date: .abbreviated, time: .shortened))" }
        switch run.status {
        case .stopped:
            return started + (run.stopped.map { " · stopped \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        case .windingDown:
            return started + " · finishing the steps under way, then it stops"
        case .running:
            guard let end = run.endsAt else { return started + " · runs until you stop it" }
            let left = max(0, end.timeIntervalSinceNow)
            let h = Int(left) / 3600, m = Int(left) % 3600 / 60
            return started + " · stops at \(end.formatted(date: .omitted, time: .shortened)) (\(h > 0 ? "\(h)h " : "")\(m)m left)"
        }
    }
}

struct FactoryStatusPill: View {
    let factory: Factory

    var body: some View {
        let (text, color): (String, Color) = {
            guard let run = factory.run else { return ("Not started", .gray) }
            switch run.status {
            case .running: return ("Running", .green)
            case .windingDown: return ("Finishing up", .orange)
            case .stopped: return ("Stopped", .gray)
            }
        }()
        HStack(spacing: 5) {
            Pulsing(active: factory.run?.status == .running, duration: 0.9) { pulse in
                Circle().fill(color).frame(width: 7, height: 7).opacity(pulse ? 0.35 : 1)
            }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color == .gray ? Color.secondary : color)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// A number with what it counts, in the header.
private struct FactoryStat: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color == .secondary ? Color.primary : color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FactoryStats: View {
    let factory: Factory
    let board: FactoryBoardData

    var body: some View {
        ChipRow(spacing: 10) {
            FactoryStat(value: "\(board.slotsInUse) of \(factory.rules.maxParallel)", label: "places in use", color: .green)
            FactoryStat(value: "\(board.count(.needsYou))", label: "need you", color: board.count(.needsYou) > 0 ? .orange : .secondary)
            FactoryStat(value: "\(board.count(.review))", label: "in review", color: .blue)
            FactoryStat(value: "\(board.count(.done))", label: "done", color: .secondary)
            FactoryStat(value: board.trackerMissing ? "–" : "\(board.count(.upNext))", label: "up next", color: .accentColor)
        }
    }
}

/// The rules in short, so it's clear what the factory may do.
private struct FactoryRuleChips: View {
    @Environment(AppModel.self) private var model
    let rules: FactoryRules

    var body: some View {
        ChipRow(spacing: 6) {
            ForEach(rules.scopes, id: \.self) { p in
                Chip(text: model.index.project(p)?.title ?? p, color: .accentColor, systemImage: "folder")
            }
            Chip(text: who, color: .blue, systemImage: "person")
            Chip(text: [rules.pbis ? "PBIs" : nil, rules.bugs ? "bugs" : nil].compactMap { $0 }.joined(separator: " and ").capitalizedFirst, color: .blue, systemImage: "list.bullet.rectangle")
            Chip(text: rules.sprint.title, color: .blue, systemImage: "calendar")
            Chip(text: "Up to \(rules.maxParallel) at a time", color: .teal, systemImage: "square.stack.3d.up")
            Chip(text: strategyText, color: .purple, systemImage: "point.3.connected.trianglepath.dotted")
            Chip(text: questionsText, color: .orange, systemImage: "questionmark.bubble")
            Chip(text: rules.openPRs ? (rules.completePRs ? "Opens and completes PRs" : "Opens PRs, you merge") : "Pushes branches, no PRs", color: .green, systemImage: "arrow.triangle.pull")
            Chip(text: newWorkText, color: .indigo, systemImage: "plus.square.on.square")
        }
    }

    private var who: String {
        switch (rules.assignedToMe, rules.unassigned) {
        case (true, true): return "Mine and unassigned"
        case (false, true): return "Unassigned, assigned to me"
        default: return "Assigned to me"
        }
    }

    private var strategyText: String {
        let name = rules.defaultStrategy.isEmpty ? "One session" : model.strategies.first { $0.slug == rules.defaultStrategy }?.title ?? rules.defaultStrategy
        return rules.strategyRules.isEmpty ? name : "\(name) + \(rules.strategyRules.count) exception\(rules.strategyRules.count == 1 ? "" : "s")"
    }

    private var questionsText: String {
        let points = rules.activeAskPoints
        guard rules.asks, !points.isEmpty else { return "Never asks" }
        let others = points.filter { $0.id != FactoryRules.unsureID }.count
        let moments = "\(others) moment\(others == 1 ? "" : "s")"
        if rules.asksWhenUnsure { return others == 0 ? "Asks when unsure" : "Asks when unsure + \(moments)" }
        return "Asks at \(moments)"
    }

    private var newWorkText: String {
        switch rules.newWorkItems {
        case .never: return "No new work items"
        case .propose: return "Creates work items, asks first"
        case .create: return "Creates work items"
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: Questions and approvals

/// Every open question, or those about one work item, each with the item it is about.
private struct FactoryQuestionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let factoryID: String
    let request: FactoryQuestionsRequest
    @State private var showAll = false

    var body: some View {
        let f = model.factory(factoryID)
        let item = showAll ? nil : request.workItem
        let open = (f?.run?.openQuestions ?? []).filter { item == nil || $0.workItem == item }
        let all = (f?.run?.openQuestions.count ?? 0) + (f?.run?.answeredForYou.count ?? 0)
        let shown = open.count + (f?.run?.answeredForYou ?? []).filter { item == nil || $0.workItem == item }.count
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.map { "Questions about #\(String($0))" } ?? "Questions for you").font(.title2.weight(.semibold))
                Text("The sessions carry on with what they can while these wait. Pick an option, answer in your own words, or let the session decide.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            ScrollView {
                if let f {
                    FactoryQuestionList(factory: f, workItem: item).padding(20)
                }
            }
            Divider()
            HStack {
                if request.workItem != nil, all > shown || showAll {
                    Toggle("Show all questions", isOn: $showAll).toggleStyle(.checkbox)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 720)
        .frame(minHeight: 420, idealHeight: 720)
    }
}

private struct FactoryQuestionList: View {
    let factory: Factory
    let workItem: Int?

    var body: some View {
        let open = (factory.run?.openQuestions ?? []).filter { workItem == nil || $0.workItem == workItem }
        let covered = (factory.run?.answeredForYou ?? []).filter { workItem == nil || $0.workItem == workItem }
        VStack(alignment: .leading, spacing: 12) {
            if open.isEmpty {
                Text("No questions waiting.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(open) { q in FactoryQuestionCard(factory: factory, question: q) }
            if !covered.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Answered for you", systemImage: "checkmark.bubble").font(.headline)
                    Text("Something you answered or decided already settled these, so the sessions were told and carried on. Dismiss them, or add to the answer.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, open.isEmpty ? 0 : 6)
                ForEach(covered) { q in FactoryCoveredCard(factory: factory, question: q) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A question with the work item it is about: which item, where the session is, the item's description and
/// criteria, and a way to open the item and the session.
private struct FactoryQuestionCard: View {
    @Environment(AppModel.self) private var model
    let factory: Factory
    let question: FactoryQuestion
    @State private var answer = ""
    @State private var showItem = false

    var body: some View {
        let task = question.workItem.flatMap { id in factory.run?.tasks.last { $0.workItem == id } }
        let item = question.workItem.flatMap { id in model.tracker?.items.first { $0.id == id } }
        let detail = question.workItem.flatMap { model.workItemDetails[$0] }
        VStack(alignment: .leading, spacing: 10) {
            if let id = question.workItem {
                AdaptiveCardLayout(minInfoWidth: 260) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: isBug(item, detail) ? "ladybug.fill" : "doc.text.fill")
                                .foregroundStyle(isBug(item, detail) ? Color.red : Color.blue)
                            Text("#\(String(id)) \(task?.title ?? item?.title ?? detail?.title ?? "")")
                                .font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        }
                        ChipRow(spacing: 6) {
                            if let state = item?.state ?? detail?.state, !state.isEmpty { Chip(text: state, color: .secondary) }
                            if let scope = task?.scope ?? item?.scope { Chip(text: model.index.project(scope)?.title ?? scope, color: .secondary, systemImage: "folder") }
                            if let st = task?.strategy, !st.isEmpty { Chip(text: st, color: .purple) }
                            if let cp = question.checkpointTitle { Chip(text: cp, color: .orange, systemImage: "flag") }
                            Text("asked \(RelativeTime.short(question.asked)) ago").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        if let url = workItemURL(item, detail) {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Label("Open \(isBug(item, detail) ? "Bug" : "PBI")", systemImage: "arrow.up.forward.square")
                            }
                            .help("Open the work item in \(TrackerLink.name(forURL: url.absoluteString))")
                        }
                        if model.session(question.sessionID) != nil {
                            Button("Open Session") { model.buildSelection = question.sessionID }
                        }
                    }
                    .fixedSize()
                }
                if model.canStartAside(question) {
                    FactoryAsideView(question: question)
                } else if let m = factory.run?.lastMilestone(for: id) {
                    Text("Where it is: \(m.text)").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(isExpanded: $showItem) {
                    itemText(detail, loading: model.workItemDetailLoading.contains(id)).padding(.top, 4)
                } label: {
                    Text("About the work item").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
                .onAppear { load(id, scope: task?.scope ?? item?.scope) }
                Divider()
            }
            Text(question.text).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !question.options.isEmpty {
                ChipRow(spacing: 6) {
                    ForEach(question.options, id: \.self) { o in
                        Button(o) { model.answerFactoryQuestion(factory.id, question.id, answer: o) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Answer in your own words", text: $answer, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button("Let It Decide") { model.skipFactoryQuestion(factory.id, question.id) }
                .buttonStyle(.borderless)
                .font(.callout)
                .help("The session makes the reasonable choice and notes the assumption")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.25)))
    }

    @ViewBuilder
    private func itemText(_ detail: WorkItemDetail?, loading: Bool) -> some View {
        if let detail {
            VStack(alignment: .leading, spacing: 8) {
                if !detail.tags.isEmpty {
                    ChipRow(spacing: 4) { ForEach(detail.tags, id: \.self) { Chip(text: $0, color: .secondary, systemImage: "tag") } }
                }
                block("Description", detail.description)
                block(detail.type.lowercased() == "bug" && !detail.repro.isEmpty ? "Repro steps" : "Acceptance criteria",
                      detail.type.lowercased() == "bug" && !detail.repro.isEmpty ? detail.repro : detail.acceptance)
                if detail.description.isEmpty && detail.acceptance.isEmpty && detail.repro.isEmpty {
                    Text("The work item has no description.").font(.callout).foregroundStyle(.secondary)
                }
            }
        } else if loading {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading the work item…").font(.callout).foregroundStyle(.secondary) }
        } else {
            Text("Couldn't read the work item. Open it in Azure DevOps instead.").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func block(_ title: String, _ text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func load(_ id: Int, scope: String?) {
        guard let scope else { return }
        model.loadWorkItemDetail(id, scope: scope)
    }

    private func isBug(_ item: TrackerBacklog.Item?, _ detail: WorkItemDetail?) -> Bool {
        item?.isBug ?? (detail?.type.lowercased() == "bug")
    }

    private func workItemURL(_ item: TrackerBacklog.Item?, _ detail: WorkItemDetail?) -> URL? {
        let raw = item?.url.isEmpty == false ? item?.url : detail?.url
        return raw.flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    private func send() {
        model.answerFactoryQuestion(factory.id, question.id, answer: answer)
        answer = ""
    }
}

/// A question something else the user answered or decided settled: what settled it and the answer the session got,
/// to dismiss or add to.
private struct FactoryCoveredCard: View {
    @Environment(AppModel.self) private var model
    let factory: Factory
    let question: FactoryQuestion
    @State private var adding = false
    @State private var extra = ""

    var body: some View {
        let task = question.workItem.flatMap { id in factory.run?.tasks.last { $0.workItem == id } }
        VStack(alignment: .leading, spacing: 8) {
            ChipRow(spacing: 6) {
                if let id = question.workItem { Chip(text: "#\(String(id))", color: .green) }
                if let title = task?.title { Text(title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true) }
                if let at = question.answered { Text(RelativeTime.short(at) + " ago").font(.caption).foregroundStyle(.secondary) }
            }
            Text(question.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Already answered" + (question.coveredBy.map { ": \($0)" } ?? ""))
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
                Text(question.answer ?? "").font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if adding {
                HStack(spacing: 8) {
                    TextField("What to add to the answer", text: $extra, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Send", action: add).disabled(extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            HStack(spacing: 8) {
                Button("Dismiss") { model.dismissAnsweredForYou(factory.id, question.id) }.buttonStyle(.borderedProminent)
                if !adding { Button("Add to the Answer…") { adding = true } }
                if model.session(question.sessionID) != nil {
                    Button("Open Session") { model.buildSelection = question.sessionID }.buttonStyle(.borderless)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.green.opacity(0.25)))
    }

    private func add() {
        model.addToAnsweredForYou(factory.id, question.id, extra)
        extra = ""
        adding = false
    }
}

/// Before answering: a catch-up on what the session did and decided, and a few follow-up questions, in a throwaway
/// copy of the asking session that is never listed with the sessions.
private struct FactoryAsideView: View {
    @Environment(AppModel.self) private var model
    let question: FactoryQuestion
    @State private var followUp = ""

    var body: some View {
        let chat = model.factoryAsides[question.id]
        let parts = chat.map { Self.split($0.items) } ?? (catchUp: "", exchanges: [])
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "text.badge.checkmark").foregroundStyle(Color.accentColor)
                    Text("Catch-up").font(.callout.weight(.semibold))
                    if chat?.isBusy == true { ProgressView().controlSize(.small) }
                }
                if !parts.catchUp.isEmpty {
                    MarkdownDocument(text: parts.catchUp).font(.callout)
                } else if let error = chat?.lastError, !(chat?.isBusy ?? false) {
                    Text("Couldn't catch up: \(error)").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Reading what the session did and decided…").font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(parts.exchanges.enumerated()), id: \.offset) { _, ex in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "person.fill").foregroundStyle(.secondary).font(.caption)
                        Text(ex.question).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    }
                    if ex.answer.isEmpty {
                        Text("Thinking…").font(.callout).foregroundStyle(.secondary)
                    } else {
                        MarkdownDocument(text: ex.answer).font(.callout).padding(.leading, 18)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Ask about it before you answer", text: $followUp, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                Button("Ask", action: ask)
                    .disabled(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(chat?.isRunning ?? false))
            }
            .help("A short side question in a copy of the session; the session at work isn't disturbed and this isn't kept")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { model.startFactoryAside(question) }
    }

    private func ask() {
        model.askFactoryAside(question.id, followUp)
        followUp = ""
    }

    /// The catch-up reply, then each follow-up with its answer.
    static func split(_ items: [ClaudeChat.Item]) -> (catchUp: String, exchanges: [(question: String, answer: String)]) {
        var catchUp: [String] = []
        var exchanges: [(question: String, answer: String)] = []
        for item in items {
            switch item.role {
            case .user where item.tag == "catchup": continue
            case .user: exchanges.append((item.text, ""))
            case .assistant, .error:
                if exchanges.isEmpty { catchUp.append(item.text) } else { exchanges[exchanges.count - 1].answer += (exchanges[exchanges.count - 1].answer.isEmpty ? "" : "\n\n") + item.text }
            default: continue
            }
        }
        return (catchUp.joined(separator: "\n\n"), exchanges)
    }
}

private struct FactoryApprovals: View {
    @Environment(AppModel.self) private var model
    let factory: Factory

    var body: some View {
        let proposals = model.factoryProposals(factory)
        VStack(alignment: .leading, spacing: 8) {
            if proposals.isEmpty {
                Text("Nothing to approve. Facts and work items the sessions propose wait here for your yes.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(proposals) { FactoryProposalRow(entry: $0) }
        }
    }
}

/// A fact or work item a factory session proposed, waiting for the user's yes.
private struct FactoryProposalRow: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry

    var body: some View {
        AdaptiveCardLayout {
            VStack(alignment: .leading, spacing: 4) {
                ChipRow(spacing: 6) {
                    Chip(text: entry.proposedSection?.singularTitle ?? "Proposal", color: entry.proposedSection == .facts ? .teal : .indigo,
                         systemImage: entry.proposedSection == .facts ? "checkmark.seal" : "plus.square")
                    Chip(text: model.index.project(entry.id.project)?.title ?? entry.id.project, color: .secondary)
                }
                Text(entry.title).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if !entry.summary.isEmpty {
                    Text(entry.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let r = entry.reason { Text(r).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            HStack(spacing: 6) {
                Button("Approve") { model.approveInbox([entry.id]) }.buttonStyle(.borderedProminent)
                Button("Reject") { model.rejectInbox([entry.id]) }
                Button { model.openLink(entry.id.rawValue) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless)
                    .help("Open it in Plan to read or edit it first")
            }
            .disabled(model.busyEntries.contains(entry.id))
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Board

private struct FactoryBoard: View {
    @Environment(AppModel.self) private var model
    let factory: Factory
    let board: FactoryBoardData
    @Binding var selected: Int?
    let openQuestions: (Int?) -> Void
    @Namespace private var cards

    var body: some View {
        BoardLayout(minColumnWidth: 220, spacing: 12) {
            ForEach(FactoryLane.allCases) { lane in
                FactoryLaneColumn(factory: factory, lane: lane, board: board, selected: $selected, cards: cards, openQuestions: openQuestions)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: board.signature)
    }
}

private struct FactoryLaneColumn: View {
    @Environment(AppModel.self) private var model
    let factory: Factory
    let lane: FactoryLane
    let board: FactoryBoardData
    @Binding var selected: Int?
    let cards: Namespace.ID
    let openQuestions: (Int?) -> Void

    var body: some View {
        let list = board.cards(lane)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: FactoryLaneStyle.icon(lane)).foregroundStyle(FactoryLaneStyle.color(lane))
                    Text(factory.isRunning || lane != .upNext ? lane.title : "It would take").font(.headline)
                    Text("\(board.count(lane))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if lane == .needsYou, let n = factory.run?.answeredForYou.count, n > 0 {
                        Button { openQuestions(nil) } label: { Label("\(n)", systemImage: "checkmark.bubble").font(.caption.weight(.semibold)) }
                            .buttonStyle(.bordered)
                            .tint(.green)
                            .controlSize(.small)
                            .help("\(n) question\(n == 1 ? " was" : "s were") answered for you by something you answered or decided elsewhere")
                    }
                    if lane == .needsYou, let n = factory.run?.openQuestions.count, n > 0 {
                        Button { openQuestions(nil) } label: { Text("Answer \(n)").font(.caption.weight(.semibold)) }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                            .help("See every question with its work item, and answer them")
                    }
                }
                Text(lane.caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(FactoryLaneStyle.color(lane).opacity(0.6)).frame(height: 2)
            if list.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            }
            ForEach(list) { card in
                FactoryCardView(factory: factory, card: card, lane: lane, selected: selected == card.id, openQuestions: openQuestions)
                    .matchedGeometryEffect(id: card.id, in: cards)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .onTapGesture { selected = selected == card.id ? nil : card.id }
            }
            if lane == .upNext, board.moreUpNext > 0 {
                Text("and \(board.moreUpNext) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyText: String {
        switch lane {
        case .upNext:
            if board.trackerMissing { return model.trackerLoading ? "Reading the work items…" : "Work items aren't loaded yet." }
            return "Nothing matches the rules right now."
        case .working: return factory.run?.status == .running ? "Nothing right now. It starts the next item within a few seconds." : "Nothing."
        case .needsYou: return "No questions."
        case .review: return "No open pull requests."
        case .done: return "Nothing yet."
        }
    }
}

enum FactoryLaneStyle {
    static func icon(_ lane: FactoryLane) -> String {
        switch lane {
        case .upNext: return "tray.full"
        case .working: return "hammer.fill"
        case .needsYou: return "hand.raised.fill"
        case .review: return "eye"
        case .done: return "checkmark.circle.fill"
        }
    }

    static func color(_ lane: FactoryLane) -> Color {
        switch lane {
        case .upNext: return .accentColor
        case .working: return .green
        case .needsYou: return .orange
        case .review: return .blue
        case .done: return .secondary
        }
    }
}

private struct FactoryCardView: View {
    @Environment(AppModel.self) private var model
    let factory: Factory
    let card: FactoryCard
    let lane: FactoryLane
    let selected: Bool
    let openQuestions: (Int?) -> Void

    var body: some View {
        let item = model.tracker?.items.first { $0.id == card.id }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: item?.isBug == true ? "ladybug.fill" : "doc.text.fill")
                    .foregroundStyle(item?.isBug == true ? Color.red : Color.blue)
                    .font(.caption)
                Text("#\(String(card.id))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if case .task(let t) = card {
                    Text(RelativeTime.short(t.started)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help("Started \(t.started.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            Text(card.title).font(.callout.weight(.medium)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            switch card {
            case .task(let t): taskDetails(t)
            case .next(let i): nextDetails(i)
            }
            let covered = factory.run?.answeredForYou.filter { $0.workItem == card.id }.count ?? 0
            if covered > 0 {
                Button { openQuestions(card.id) } label: {
                    Label("Answered for you", systemImage: "checkmark.bubble").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .controlSize(.small)
                .help("A question on this item was settled by something you answered or decided elsewhere")
            }
            let asks = factory.run?.openQuestions.filter { $0.workItem == card.id }.count ?? 0
            if asks > 0 {
                Button { openQuestions(card.id) } label: {
                    Label("\(asks) question\(asks == 1 ? "" : "s") for you", systemImage: "hand.raised.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                .help("See the question with the work item, and answer it")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.18),
                                                                lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .contextMenu { FactoryCardActions(factory: factory, card: card, lane: lane) }
        .help("Click for details")
    }

    @ViewBuilder
    private func taskDetails(_ t: FactoryTask) -> some View {
        let s = model.session(t.sessionID)
        if let line = nowLine(t, s) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if s?.chat.isBusy == true { BusyDot() }
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        ChipRow(spacing: 4) {
            if let s, t.isActive { SessionBadgePills(session: s, badges: model.badges(s), compact: true) }
            if !t.strategy.isEmpty { Chip(text: t.strategy, color: .purple) }
            if let s, case let n = model.members(of: s).count, n > 0 {
                Chip(text: "+\(n) session\(n == 1 ? "" : "s")", color: .purple, systemImage: "person.2")
            }
        }
    }

    @ViewBuilder
    private func nextDetails(_ i: TrackerBacklog.Item) -> some View {
        ChipRow(spacing: 4) {
            Chip(text: model.index.project(i.scope)?.title ?? i.scope, color: .secondary)
            if i.isUnassigned { Chip(text: "Unassigned", color: .orange, systemImage: "person.badge.plus") }
            if i.stage == .inProgress { Chip(text: "Continues it", color: .indigo) }
            let strategy = factory.rules.strategy(for: i)
            if !strategy.isEmpty { Chip(text: model.strategies.first { $0.slug == strategy }?.title ?? strategy, color: .purple) }
        }
    }

    private func nowLine(_ t: FactoryTask, _ s: WorkSession?) -> String? {
        if !t.isActive { return t.outcome }
        if let q = factory.run?.openQuestions.first(where: { $0.sessionID == t.sessionID }) { return "Asks: \(q.text)" }
        if let s, s.chat.isBusy, let a = s.chat.activity { return a }
        if let o = t.outcome { return "Done: \(o)" }
        if let m = factory.run?.lastMilestone(for: t.workItem) { return m.text }
        let reply = s?.lastReply ?? ""
        return reply.isEmpty ? nil : reply
    }
}

/// A small pulsing dot: the session is at work right now.
private struct BusyDot: View {
    var body: some View {
        Pulsing { on in
            Circle().fill(Color.green).frame(width: 6, height: 6).opacity(on ? 0.3 : 1)
        }
    }
}

private struct FactoryCardActions: View {
    @Environment(AppModel.self) private var model
    let factory: Factory
    let card: FactoryCard
    let lane: FactoryLane

    var body: some View {
        if case .task(let t) = card, model.session(t.sessionID) != nil {
            Button("Open Session") { model.buildSelection = t.sessionID }
        }
        if let url = workItemURL { Button("Open Work Item") { NSWorkspace.shared.open(url) } }
        if case .task(let t) = card, let s = model.session(t.sessionID), let pr = model.linkedPR(s), let url = URL(string: pr.url) {
            Button("Open Pull Request !\(String(pr.id))") { NSWorkspace.shared.open(url) }
        }
        if case .next = card, factory.run != nil {
            Divider()
            Button("Skip This Run") { model.skipFactoryItem(factory.id, card.id) }
        }
    }

    private var workItemURL: URL? {
        let raw: String? = switch card {
        case .next(let i): i.url
        case .task: model.tracker?.items.first { $0.id == card.id }?.url
        }
        return raw.flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
}

/// The item picked on the board: where it stands, what its session does now, and what happened with it.
private struct FactoryItemDetail: View {
    @Environment(AppModel.self) private var model
    let factory: Factory
    let card: FactoryCard
    let lane: FactoryLane?
    let openQuestions: () -> Void
    let close: () -> Void

    var body: some View {
        let item = model.tracker?.items.first { $0.id == card.id }
        let asks = factory.run?.openQuestions.filter { $0.workItem == card.id }.count ?? 0
        VStack(alignment: .leading, spacing: 12) {
            AdaptiveCardLayout(minInfoWidth: 260) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("#\(String(card.id)) \(card.title)").font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    ChipRow(spacing: 6) {
                        if let lane { Chip(text: lane.title, color: FactoryLaneStyle.color(lane), systemImage: FactoryLaneStyle.icon(lane)) }
                        if let item { Chip(text: item.isBug ? "Bug" : "PBI", color: item.isBug ? .red : .blue) }
                        Chip(text: model.index.project(card.scope)?.title ?? card.scope, color: .secondary, systemImage: "folder")
                        if let item, !item.state.isEmpty { Chip(text: item.state, color: .secondary) }
                        if case .task(let t) = card {
                            if !t.strategy.isEmpty { Chip(text: t.strategy, color: .purple) }
                            Chip(text: "Started \(t.started.formatted(date: .omitted, time: .shortened))", color: .secondary, systemImage: "clock")
                            if let end = t.finished { Chip(text: "Finished \(end.formatted(date: .omitted, time: .shortened))", color: .secondary) }
                        }
                    }
                }
                HStack(spacing: 8) {
                    if asks > 0 {
                        Button { openQuestions() } label: { Label("\(asks) question\(asks == 1 ? "" : "s")", systemImage: "hand.raised.fill") }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                    }
                    if case .task(let t) = card, model.session(t.sessionID) != nil {
                        Button("Open Session") { model.buildSelection = t.sessionID }
                    }
                    Menu {
                        FactoryCardActions(factory: factory, card: card, lane: lane ?? .upNext)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .help("Close the details")
                }
                .fixedSize()
            }
            switch card {
            case .task(let t): taskBody(t)
            case .next(let i): nextBody(i)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func taskBody(_ t: FactoryTask) -> some View {
        let s = model.session(t.sessionID)
        if let s {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.chat.isBusy ? "Doing now" : "Last said").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if s.chat.isBusy { BusyDot() }
                    let text = s.chat.isBusy ? (s.chat.activity ?? "Working…") : (s.lastReply.isEmpty ? "Nothing yet." : s.lastReply)
                    Text(text).font(.callout).lineLimit(8).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                ChipRow(spacing: 6) {
                    SessionBadgePills(session: s, badges: model.badges(s))
                    ForEach(model.members(of: s)) { m in
                        Chip(text: m.title, color: m.chat.isBusy ? .green : .secondary, systemImage: m.chat.isBusy ? "bolt.fill" : "person")
                    }
                }
            }
        } else {
            Text("Its session was deleted.").font(.callout).foregroundStyle(.secondary)
        }
        if let pr = s.flatMap({ model.linkedPR($0) }) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pull request").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("!\(String(pr.id)) \(pr.title)").font(.callout).fixedSize(horizontal: false, vertical: true)
                ChipRow(spacing: 6) {
                    Chip(text: "\(pr.approvals) approval\(pr.approvals == 1 ? "" : "s")", color: pr.approvals > 0 ? .green : .secondary)
                    if pr.openThreads > 0 { Chip(text: "\(pr.openThreads) open comment\(pr.openThreads == 1 ? "" : "s")", color: .orange) }
                    ForEach(pr.blockers, id: \.self) { Chip(text: $0, color: .red, systemImage: "exclamationmark.triangle") }
                }
            }
        }
        let events = factory.run?.events(for: t.workItem) ?? []
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("What happened").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(events.reversed()) { e in FactoryEventRow(event: e, showItem: false) }
            }
        }
    }

    @ViewBuilder
    private func nextBody(_ i: TrackerBacklog.Item) -> some View {
        let strategy = factory.rules.strategy(for: i)
        VStack(alignment: .leading, spacing: 4) {
            Text("When it takes this").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(whenText(i, strategy: strategy)).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func whenText(_ i: TrackerBacklog.Item, strategy: String) -> String {
        var parts: [String] = []
        if i.isUnassigned { parts.append("It assigns it to you first.") }
        if i.stage == .inProgress { parts.append("It continues the work already started.") }
        parts.append(strategy.isEmpty ? "One session works on it alone."
                     : "It uses \(model.strategies.first { $0.slug == strategy }?.title ?? strategy).")
        if !i.sprint.isEmpty { parts.append("Sprint: \(i.sprintName).") }
        if factory.run == nil { parts.append("Start the factory to begin.") }
        return parts.joined(separator: " ")
    }
}

// MARK: Activity

private struct FactoryHistory: View {
    let factory: Factory
    @State private var showAll = false

    var body: some View {
        let all = Array((factory.run?.events ?? []).reversed())
        let events = showAll ? Array(all.prefix(300)) : Array(all.prefix(12))
        VStack(alignment: .leading, spacing: 6) {
            if events.isEmpty { Text("Nothing yet.").font(.callout).foregroundStyle(.secondary) }
            ForEach(events) { FactoryEventRow(event: $0, showItem: true) }
            if all.count > 12 {
                Button(showAll ? "Show Less" : "Show All \(all.count)") { showAll.toggle() }
                    .buttonStyle(.borderless).font(.callout)
            }
        }
    }
}

private struct FactoryEventRow: View {
    let event: FactoryEvent
    let showItem: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.icon(event.kind)).foregroundStyle(Self.color(event.kind)).frame(width: 16)
            Text(event.at.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
            if showItem, let id = event.workItem {
                Text("#\(String(id))").font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            }
            Text(event.text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    static func icon(_ k: FactoryEvent.Kind) -> String {
        switch k {
        case .run: return "gearshape.2"
        case .started: return "play.circle"
        case .question: return "questionmark.bubble"
        case .answer: return "text.bubble"
        case .fact: return "checkmark.seal"
        case .done: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .info: return "circle.fill"
        }
    }

    static func color(_ k: FactoryEvent.Kind) -> Color {
        switch k {
        case .run: return .accentColor
        case .started: return .green
        case .question: return .orange
        case .answer: return .blue
        case .fact: return .teal
        case .done: return .green
        case .warning: return .red
        case .info: return .secondary
        }
    }
}

// MARK: Sidebar row

struct FactorySidebarRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let running = model.factories.filter(\.isRunning)
        let questions = model.factoryQuestionCount
        let tasks = running.reduce(0) { n, f in n + (f.run?.activeTasks.filter { model.occupiesSlot($0, in: f) }.count ?? 0) }
        HStack(spacing: 8) {
            Image(systemName: "gearshape.2.fill").foregroundStyle(running.isEmpty ? Color.secondary : Color.green).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Software Factory").font(.body.weight(.medium))
                Text(running.isEmpty ? (model.factories.isEmpty ? "Set one up" : "Not running")
                     : "Running · \(tasks) task\(tasks == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if questions > 0 { NeedsBadge(count: questions).help("\(questions) question\(questions == 1 ? "" : "s") from the factory") }
        }
        .padding(.vertical, 3)
        .onAppear { model.loadFactoriesIfNeeded() }
    }
}

/// One factory in Build's sidebar: its name, whether it runs and what it does, and its questions.
struct FactoryListRow: View {
    @Environment(AppModel.self) private var model
    let factory: Factory
    @State private var confirmDelete = false

    var body: some View {
        let run = factory.run
        let working = run?.activeTasks.filter { model.occupiesSlot($0, in: factory) }.count ?? 0
        let questions = run?.openQuestions.count ?? 0
        HStack(spacing: 8) {
            Image(systemName: "gearshape.2.fill")
                .foregroundStyle(factory.isRunning ? Color.green : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(factory.name).font(.body.weight(.medium)).lineLimit(2)
                Text(subtitle(run, working: working)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if questions > 0 {
                NeedsBadge(count: questions).help("\(questions) question\(questions == 1 ? "" : "s") from this factory")
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if factory.isRunning {
                if run?.isPaused == true { Button("Resume") { model.resumeFactory(factory.id) } }
                else if run?.status == .running { Button("Pause") { model.pauseFactory(factory.id) } }
                if run?.status == .running { Button("Stop") { model.stopFactory(factory.id) } }
            } else {
                Button("Start") { model.startFactory(factory.id) }.disabled(!factory.rules.problems.isEmpty)
            }
            Button("Edit Rules…") { model.factoryEditor = FactoryEditRequest(factoryID: factory.id) }
            Button("New Factory…") { model.factoryEditor = FactoryEditRequest(factoryID: nil) }
            Divider()
            Button("Delete Factory…", role: .destructive) { confirmDelete = true }.disabled(factory.isRunning)
        }
        .alert("Delete “\(factory.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteFactory(factory.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its rules and its history go. Sessions it started stay in Build.")
        }
    }

    private func subtitle(_ run: FactoryRun?, working: Int) -> String {
        guard let run else { return "Not started" }
        switch run.status {
        case .running: return run.isPaused ? "Paused · \(working) working" : "Running · \(working) working"
        case .windingDown: return "Finishing up"
        case .stopped: return "Stopped"
        }
    }
}
