import KBCore
import SwiftUI

/// Plan ⇄ Build, in the main window's toolbar.
struct ModePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let needs = model.waitingTally.build
        HStack(spacing: 2) {
            segment(.plan, title: "Plan", badge: model.planSessionsNeedingUser.count)
            segment(.build, title: "Build", badge: needs)
        }
        // Its own container, with the toolbar's glass hidden: the picked capsule sits inset by the same margin all
        // round, so both capsules have one shape.
        .padding(3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .fixedSize()
        .help(needs > 0
              ? (model.overseerNeedsUser && needs == 1 ? "The overview session asks you something in Build (⌃⌘B)"
                 : "\(needs) session\(needs == 1 ? " needs" : "s need") your input in Build (⌃⌘B)")
              : "Plan: the knowledge base and planning (⌃⌘P). Build: implementation sessions (⌃⌘B).")
    }

    private func segment(_ mode: AppMode, title: String, badge: Int) -> some View {
        let selected = model.mode == mode
        return Button {
            model.mode = mode
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.icon)
                Text(title)
                if badge > 0 { NeedsBadge(count: badge) }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(selected ? Color.secondary.opacity(0.25) : .clear, in: Capsule())
            .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An orange count that pulses: sessions waiting for the user.
struct NeedsBadge: View {
    let count: Int

    var body: some View {
        Pulsing { pulse in
            Text("\(count)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 16, minHeight: 16)
                .padding(.horizontal, count > 9 ? 3 : 0)
                .background(Color.orange, in: Capsule())
                .scaleEffect(pulse ? 1.15 : 1)
                .shadow(color: .orange.opacity(pulse ? 0.7 : 0), radius: pulse ? 4 : 0)
        }
    }
}

/// Build mode: the overview session on top, leads with their sessions, and every other session.
struct BuildView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.kbTheme) private var theme
    @AppStorage(BuildView.myWorkSideKey) private var myWorkSide = false
    static let myWorkSideKey = "buildMyWorkOnRight"
    @AppStorage("buildMyWorkWidth") private var myWorkWidth = 306.0
    /// My Work's width on screen, only for where a drag of the divider starts; the layout never reads it.
    @State private var shownMyWorkWidth = 306.0
    static let minSessionWidth: CGFloat = 320

    var body: some View {
        NavigationSplitView {
            BuildSidebar()
                .themedSidebar()
                .navigationSplitViewColumnWidth(min: SplitViewMemory.sidebarRange.min, ideal: SplitViewMemory.sidebarRange.ideal, max: SplitViewMemory.sidebarRange.max)
        } detail: {
            if myWorkSide {
                // The widths come from the space the layout is given, never from a measurement fed back into
                // the views, which could resize back and forth.
                SidePanelLayout(preferred: myWorkWidth, mainMin: Self.minSessionWidth) {
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    PanelDivider(width: $myWorkWidth, shown: shownMyWorkWidth, range: 200...620)
                    MyWorkView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { shownMyWorkWidth = $0 }
                }
            } else {
                detail.frame(minWidth: Self.minSessionWidth, maxWidth: .infinity)
            }
        }
        // The sidebar floats over the window: behind it goes the same colour as the session beside it, not the
        // window's black.
        .background(Color(hex: theme.contentBackground) ?? Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $myWorkSide) {
                    Label("My Work on the Right", systemImage: "checklist")
                }
                .help(myWorkSide ? "Hide My Work on the right" : "Show My Work on the right, next to the session")
            }
        }
        .onAppear { model.startCrewEngine() }
    }

    @ViewBuilder private var detail: some View {
        if model.buildSelection == AppModel.testTag {
            TestView()
        } else if model.buildSelection?.hasPrefix(AppModel.factoryTag) == true {
            FactoryView(factoryID: model.selectedFactoryID)
        } else if let raw = model.buildSelection, raw.hasPrefix("pr:"), let id = Int(raw.dropFirst(3)) {
            PullRequestDetailView(id: id, inBuild: true).id(id)
        } else if let s = model.session(model.buildSelection), s.role != .overseer {
            SessionView(session: s).id(s.id)
        } else {
            OverviewSessionView()
        }
    }
}

/// The session, the divider and My Work side by side. My Work keeps the width the user chose while the session
/// still gets its minimum; in a narrow window the session gives way first.
private struct SidePanelLayout: Layout {
    var preferred: Double
    var mainMin: Double
    static let panelMin = 200.0
    /// The least the session gets when the window is too narrow for both.
    static let mainFloor = 120.0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let divider = subviews.count == 3 ? subviews[1].sizeThatFits(.unspecified).width : 0
        let least = Self.mainFloor + divider + Self.panelMin
        let width = max(least, proposal.width ?? (mainMin + divider + preferred))
        let height = proposal.height ?? subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let divider = subviews[1].sizeThatFits(.unspecified).width
        let w = SidePanelFit.widths(available: b.width, divider: divider, preferred: preferred,
                                    panelMin: Self.panelMin, mainMin: mainMin)
        subviews[0].place(at: b.origin, proposal: ProposedViewSize(width: w.main, height: b.height))
        subviews[1].place(at: CGPoint(x: b.minX + w.main, y: b.minY), proposal: ProposedViewSize(width: divider, height: b.height))
        subviews[2].place(at: CGPoint(x: b.minX + w.main + divider, y: b.minY),
                          proposal: ProposedViewSize(width: w.panel, height: b.height))
    }
}

/// The line between the session and My Work; drag it to resize My Work.
private struct PanelDivider: View {
    @Binding var width: Double
    /// What is on screen, which can be narrower than `width` in a small window; a drag starts from here.
    let shown: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle()))
            .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let from = start ?? shown
                    start = from
                    width = min(max(from - v.translation.width, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in start = nil })
    }
}

// MARK: Sidebar

struct BuildSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var showArchived = false
    @AppStorage("buildCollapsedLeads") private var collapsedRaw = ""
    private static let overviewTag = "overview"

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    private func toggle(_ id: String) {
        var c = collapsed
        if c.contains(id) { c.remove(id) } else { c.insert(id) }
        collapsedRaw = c.sorted().joined(separator: ",")
    }

    @AppStorage("buildCollapsedScopes") private var collapsedScopesRaw = ""

    private func scopeExpanded(_ scope: String?) -> Binding<Bool> {
        let key = scope ?? "-"
        return Binding(
            get: { !collapsedScopesRaw.split(separator: ",").contains(Substring(key)) },
            set: { open in
                var c = Set(collapsedScopesRaw.split(separator: ",").map(String.init))
                if open { c.remove(key) } else { c.insert(key) }
                collapsedScopesRaw = c.sorted().joined(separator: ",")
            })
    }

    @ViewBuilder
    private func sessionRows(_ s: WorkSession) -> some View {
        let members = s.role == .lead ? model.members(of: s) : []
        let folded = collapsed.contains(s.id)
        HStack(alignment: .top, spacing: 2) {
            if members.isEmpty {
                Color.clear.frame(width: 14, height: 1)
            } else {
                Button { toggle(s.id) } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .frame(width: 14, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .help(folded ? "Show the \(members.count) sessions under it" : "Hide the sessions under it")
            }
            VStack(alignment: .leading, spacing: 1) {
                CrewSessionRow(session: s, showScope: false)
                if folded {
                    Text("\(members.count) session\(members.count == 1 ? "" : "s") under it")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .tag(s.id).crewContextMenu(s)
        ForEach(members.filter { !folded || $0.crewState.needsUser }) { m in
            CrewSessionRow(session: m, showScope: false).padding(.leading, 30).tag(m.id).crewContextMenu(m)
        }
    }

    var body: some View {
        let query = model.listQuery(.buildSessions)
        VStack(spacing: 0) {
            ListSearchField(key: .buildSessions, prompt: "Search sessions")
            List(selection: Binding(get: { model.buildSelection ?? Self.overviewTag },
                                    set: { model.buildSelection = $0 == Self.overviewTag ? nil : $0 })) {
                overviewRow.tag(Self.overviewTag)
                if model.factories.isEmpty {
                    FactorySidebarRow().tag(AppModel.factoryTag)
                }
                if query.isEmpty { TestSidebarRow().tag(AppModel.testTag) }
                if query.isEmpty, !model.factories.isEmpty {
                    Section {
                        ForEach(model.factories) { f in
                            FactoryListRow(factory: f).tag(AppModel.factoryTag + f.id)
                        }
                    } header: {
                        HStack {
                            Text("Software Factories")
                            Spacer()
                            HeaderButton(systemImage: "plus", help: "New software factory") {
                                model.factoryEditor = FactoryEditRequest(factoryID: nil)
                            }
                        }
                    }
                }
                if !query.isEmpty {
                    // Every session, older and archived ones too, newest first.
                    let found = model.buildSessions.filter { $0.role != .overseer && $0.matches(query) }.sorted { $0.updated > $1.updated }
                    if found.isEmpty {
                        Section("Found · 0") { ListSearchNoMatch(query: query) }
                    }
                    ForEach(ScopeSections.split(found, order: model.index.projects.map(\.id)) { $0.project }, id: \.scope) { section in
                        Section {
                            ForEach(section.items) { s in CrewSessionRow(session: s, showScope: false).tag(s.id).crewContextMenu(s) }
                        } header: {
                            ScopeSectionHeader(scope: section.scope, sessions: section.items, found: true)
                        }
                    }
                } else if !model.buildStatusKnown {
                    Section("Sessions") {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading sessions…").foregroundStyle(.secondary).font(.callout)
                        }
                    }
                } else {
                    let top = model.topLevelBuildSessions
                    if top.isEmpty {
                        Section("Sessions") {
                            Text("No sessions yet").foregroundStyle(.secondary).font(.callout)
                        }
                    }
                    ForEach(ScopeSections.split(top, order: model.index.projects.map(\.id)) { $0.project }, id: \.scope) { section in
                        FoldableSection(isExpanded: scopeExpanded(section.scope)) {
                            ForEach(section.items) { s in sessionRows(s) }
                        } header: {
                            ScopeSectionHeader(scope: section.scope, sessions: section.items)
                        }
                    }
                    let archived = model.archivedBuildSessions
                    if !archived.isEmpty {
                        FoldableSection(isExpanded: $showArchived) {
                            ForEach(archived) { s in
                                CrewSessionRow(session: s).tag(s.id).crewContextMenu(s)
                            }
                        } header: {
                            Text("Archived · \(archived.count)")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onAppear {
                model.refreshPullRequests()
                model.refreshMyWork()
                model.refreshDonePRs()
            }
            Divider()
            HStack {
                Button {
                    model.newLeadRequest = NewLeadRequest(project: model.projectID)
                } label: {
                    Label("New Session…", systemImage: "plus.circle")
                }
                Spacer()
                Menu {
                    Button("Strategies…") { model.strategiesSheet = StrategiesSheetRequest() }
                    Toggle("Show My Work on the Right", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: BuildView.myWorkSideKey) },
                        set: { UserDefaults.standard.set($0, forKey: BuildView.myWorkSideKey) }))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var overviewRow: some View {
        let needs = model.waitingTally.overview
        return HStack(spacing: 8) {
            Image(systemName: "binoculars.fill").foregroundStyle(Color.accentColor).frame(width: 18)
            Text("Overview").font(.body.weight(.medium))
            Spacer()
            if model.overseer?.chat.isBusy == true { ProgressView().controlSize(.mini) }
            if let o = model.overseer, o.crewState.needsUser {
                StatusPill(status: o.crewState == .blocked ? .needsPermission : .needsInput, compact: true)
                    .help("The overview session is waiting for your answer")
            }
            if needs > 0 {
                Text("\(needs)").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.orange, in: Capsule())
                    .help("\(needs) thing\(needs == 1 ? "" : "s") wait\(needs == 1 ? "s" : "") on you; the overview session lists them")
            }
        }
        .padding(.vertical, 3)
    }
}

/// A Build sidebar section's header: which scope (and project) the sessions under it work in, how many there are,
/// and how many need you, so a folded section still says so.
struct ScopeSectionHeader: View {
    @Environment(AppModel.self) private var model
    let scope: String?
    let sessions: [WorkSession]
    var found = false

    var body: some View {
        let needs = sessions.reduce(0) { n, s in
            n + (s.crewState.needsUser ? 1 : 0) + (s.role == .lead ? model.members(of: s).filter(\.crewState.needsUser).count : 0)
        }
        HStack(spacing: 6) {
            Image(systemName: scope == nil ? "questionmark.folder" : "folder")
            ViewThatFits(in: .horizontal) {
                if let project { Text(title) + Text("  \(project)").foregroundStyle(.tertiary) }
                Text(title)
            }
            Text(found ? "\(sessions.count) found" : "\(sessions.count)").foregroundStyle(.tertiary).monospacedDigit()
            Spacer(minLength: 0)
            if needs > 0 {
                Text("\(needs)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange, in: Capsule())
                    .help("\(needs) session\(needs == 1 ? "" : "s") here need you")
            }
        }
        .help(scope == nil ? "Sessions without a scope" : "Sessions working in \(title)" + (project.map { " (\($0))" } ?? ""))
    }

    private var title: String {
        guard let scope else { return "No scope" }
        return model.index.project(scope)?.title ?? scope
    }

    /// The project the scope belongs to, when there is more than one project and its name adds something.
    private var project: String? {
        guard let scope, model.index.groups.count > 1, let g = model.index.group(of: scope), g.title != title else { return nil }
        return g.title
    }
}

struct StateDot: View {
    let state: CrewSessionState
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Self.color(state))
            .frame(width: size, height: size)
            .overlay {
                if state == .working {
                    Circle().stroke(Self.color(state).opacity(0.4), lineWidth: 3).scaleEffect(1.6)
                }
            }
            .help(state.label)
    }

    static func color(_ s: CrewSessionState) -> Color {
        switch s {
        case .working: return .green
        case .waiting, .blocked: return .orange
        case .idle: return .blue.opacity(0.7)
        case .stopped: return .secondary.opacity(0.4)
        }
    }
}

struct CrewSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession
    var showScope = true

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            SessionTitleBlock(session: session, bold: session.role == .lead, showScope: showScope)
            if session.role != .member, let pr = model.readyPRs(session).first?.pr {
                Spacer(minLength: 0)
                Button("Complete") { model.completePRRequest = CompletePRRequest(id: pr.id) }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.mini)
                    .help("!\(pr.id) is ready: merge it")
            }
        }
        .padding(.vertical, 3)
    }
}

enum RelativeTime {
    static func short(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}

struct CrewContextMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    let session: WorkSession

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Open") { model.buildSelection = session.id }
            if session.role == .lead {
                Button("Add a Session Under It…") { model.newLeadRequest = NewLeadRequest(parent: session.id) }
            }
            StrategyMenuItems(session: session)
            Divider()
            if session.role != .lead { Button("Make It a Lead") { model.makeLead(session) } }
            let leads = model.leads.filter { $0.id != session.id && $0.id != session.parentID }
            if !leads.isEmpty, session.role != .lead || model.members(of: session).isEmpty {
                Menu("Move Under") {
                    ForEach(leads) { l in Button(l.title) { model.move(session, under: l) } }
                }
            }
            if session.role == .member { Button("Take It Out of the Crew") { model.detach(session) } }
            Divider()
            if session.chat.isRunning {
                Button(session.role == .lead ? "Stop" : "Stop Session") { model.stopSession(session) }
                if session.role == .lead, !model.members(of: session).isEmpty {
                    Button("Stop the Lead and Its Sessions") { model.stopCrew(session) }
                }
            }
            Button("Continue in Terminal") { model.openSessionInTerminal(session) }
            if session.role != .overseer, let pr = model.linkedPR(session) {
                Divider()
                PRActionItems(pr: pr, session: session)
            }
            if let id = model.reviewedPR(session) {
                Divider()
                Menu("Vote on !\(String(id))") {
                    ReviewVoteItems(prID: id) { model.castVote($0, on: id, from: session) }
                }
            }
            ForEach(model.readyPRs(session).filter { $0.session.id != session.id }, id: \.pr.id) { item in
                Button("Complete !\(item.pr.id)…") { model.completePRRequest = CompletePRRequest(id: item.pr.id) }
            }
            Divider()
            if model.isArchived(session) {
                Button("Move Out of the Archive") { model.setArchived(session, false) }
            } else {
                Button("Archive") { model.setArchived(session, true) }
            }
            Button("Delete", role: .destructive) { model.deleteSession(session) }
        }
    }
}

extension View {
    func crewContextMenu(_ s: WorkSession) -> some View { modifier(CrewContextMenu(session: s)) }
}

// MARK: Overview

/// The overview session as a full conversation, with every lead and session in a panel on the right.
struct OverviewSessionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let o = model.overseer {
                SessionView(session: o).id(o.id)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.overseer?.id) {
            // Also after "Delete Session" on it: a fresh overview session takes its place.
            if model.overseer == nil { model.ensureOverseer() }
        }
    }
}

/// Shown in the overview session before anything was said.
struct OverviewEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Overview", systemImage: "binoculars.fill").font(.title2.weight(.semibold)).foregroundStyle(Color.accentColor)
            Text("This session sees every lead and session in Build. Ask how things stand, tell the leads what to do, or have it start new work.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.prompts, id: \.self) { p in
                    Button {
                        model.askOverseer(p)
                    } label: {
                        Label(p, systemImage: "text.bubble")
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 24)
    }

    static let prompts = [
        "Ask every lead for a one-line status, then give me the picture.",
        "What needs me right now, most urgent first?",
        "Look at the open follow-ups and proposed backlog items and suggest what to start next. Don't start anything yet.",
    ]
}

/// The right-hand panel: running leads with their sessions, then everything that isn't running.



// MARK: New lead

struct NewLeadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var request: NewLeadRequest

    var body: some View {
        let parent = model.session(request.parent)
        VStack(alignment: .leading, spacing: 14) {
            Text(parent.map { "Add a Session Under “\($0.title)”" } ?? "New Session").font(.title3.weight(.semibold))
            Text(parent == nil
                 ? "A session works in the project's code. Give it sessions under it, or a strategy that starts them, and it leads them."
                 : "The session works in the lead's project and reports to the lead.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Title", text: $request.title, prompt: Text(parent == nil ? "Login flow" : "Tests for the login flow"))
                if parent == nil {
                    Picker("Scope", selection: $request.project) {
                        ForEach(model.index.projects) { p in Text(p.title).tag(Optional(p.id)) }
                    }
                }
                Picker("Strategy", selection: $request.strategy) {
                    Text("None").tag(String?.none)
                    ForEach(model.strategies) { s in Text(s.title).tag(Optional(s.slug)) }
                }
                .onChange(of: request.strategy) { _, slug in
                    guard let st = model.strategies.first(where: { $0.slug == slug }) else { return }
                    if st.spawns {
                        request.helpers = .auto
                        request.helperCount = st.maxSessions
                    }
                }
                if parent == nil {
                    Picker("Sessions under it", selection: $request.helpers) {
                        Text("None").tag(NewLeadRequest.Helpers.alone)
                        Text("Auto").tag(NewLeadRequest.Helpers.auto)
                        Text("Fixed").tag(NewLeadRequest.Helpers.fixed)
                    }
                    .pickerStyle(.segmented)
                    if request.helpers != .alone {
                        Stepper(request.helpers == .auto ? "Up to \(request.helperCount)" : "Exactly \(request.helperCount)",
                                value: $request.helperCount, in: 1...8)
                    }
                }
                if let a = request.about.flatMap(EntryID.init) {
                    LabeledContent("About", value: model.index.entry(a)?.title ?? a.stem)
                }
            }
            .formStyle(.grouped)
            .multilineTextAlignment(.leading)
            .frame(height: parent == nil ? (request.helpers == .alone ? 230 : 265) : 150)
            if let slug = request.strategy, let st = model.strategies.first(where: { $0.slug == slug }) {
                VStack(alignment: .leading, spacing: 6) {
                    if !st.summary.isEmpty { Text(st.summary).font(.caption).foregroundStyle(.secondary) }
                    StrategyTeamDiagram(strategy: st, compact: true)
                    StrategyMiniFlow(strategy: st)
                }
            }
            Text("Brief").font(.callout.weight(.medium))
            TextEditor(text: $request.brief)
                .font(.body)
                .frame(minHeight: 110)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            Text(request.helpers == .alone || parent != nil
                 ? "What to do and when it is done. Leave it empty to start with a blank conversation."
                 : "What to do and when it is done. It leads the sessions it starts, and they report to it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    model.startLead(request)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(request.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
