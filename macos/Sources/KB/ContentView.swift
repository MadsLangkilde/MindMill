import KBCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        @Bindable var signIn = model.claudeSignIn
        @Bindable var azure = model.azureSignIn
        VStack(spacing: 0) {
        if !model.showOnboarding {
            ClaudeSignInBanner()
            ConnectorBanner()
        }
        Group {
            if model.showOnboarding {
                OnboardingView()
            } else if model.mode == .build {
                BuildView()
                    .transition(ModeTransition.value)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .themedSidebar()
                        .navigationSplitViewColumnWidth(min: SplitViewMemory.sidebarRange.min, ideal: SplitViewMemory.sidebarRange.ideal, max: SplitViewMemory.sidebarRange.max)
                } content: {
                    ContentColumn()
                        .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 640)
                } detail: {
                    DetailView()
                }
                .searchable(
                    text: $model.searchText,
                    placement: .toolbar,
                    prompt: model.searchAllProjects ? "Search or describe it (all scopes)" : "Search or describe it in \(model.project?.title ?? "scope")"
                )
                .modifier(SearchFocus(focused: $searchFocused))
                .onChange(of: model.findRequest) { _, _ in if model.mode == .plan { searchFocused = true } }
                .transition(ModeTransition.value)
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.mode)
        // A new identity after Reset Layout, so the split views lay out again from the standard widths.
        .id(model.layoutGeneration)
        if let notice = model.notice {
            NoticeBar(text: notice, seconds: 4) { model.notice = nil }
        }
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
        .themedWindow()
        .toolbar {
            if #available(macOS 26, *) {
                ToolbarItem(placement: .navigation) { ModePicker() }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { ModePicker() }
            }
            ToolbarItem(placement: .primaryAction) { SyncButton() }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Settings: appearance, \(Brain.name), meetings, shortcuts and more (⌘,)")
            }
        }
        .navigationTitle(model.mode == .build ? "Mindmill — Build" : model.windowTitle)
        .sheet(item: $model.newLeadRequest) { request in
            NewLeadSheet(request: request)
        }
        .sheet(item: $model.strategiesSheet) { request in
            StrategiesSheet(request: request)
        }
        .sheet(item: $model.factoryEditor) { request in
            FactoryRulesSheet(request: request)
        }
        .sheet(item: $model.addProjectRequest) { request in
            AddProjectSheet(request: request)
        }
        .sheet(isPresented: $model.scopesSheet) {
            ScopesSheet()
        }
        .sheet(isPresented: $signIn.showSheet) {
            ClaudeSignInSheet()
        }
        .sheet(isPresented: $azure.showSheet) {
            AzureSignInSheet()
        }
        .alert("Save changes to “\(model.document?.title ?? "this entry")”?", isPresented: $model.showUnsavedPrompt) {
            Button("Save") { model.resolveUnsaved(save: true) }
            Button("Discard", role: .destructive) { model.resolveUnsaved(save: false) }
            Button("Cancel", role: .cancel) { model.cancelNavigation() }
        } message: {
            Text("Your changes will be lost if you don’t save them.")
        }
        .alert("Mindmill", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Delete “\(model.deleteRequest?.title ?? "")”?",
            isPresented: Binding(get: { model.deleteRequest != nil }, set: { if !$0 { model.deleteRequest = nil } })
        ) {
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.deleteRequest = nil }
        } message: {
            Text(model.deleteRequest?.message ?? "")
        }
        .sheet(item: $model.newEntryRequest) { request in
            NewEntrySheet(request: request)
        }
        .sheet(item: $model.reminderSheet) { request in
            ReminderSheet(request: request)
        }
        .sheet(item: $model.goalSheet) { request in
            GoalSheet(request: request)
        }
        .sheet(item: $model.newMeetingRequest) { request in
            NewMeetingSheet(request: request)
        }
        .sheet(item: $model.followupCloseRequest) { request in
            FollowupCloseSheet(id: request.entry)
        }
        .sheet(item: $model.newMailReferenceRequest) { request in
            NewMailReferenceSheet(request: request)
        }
        .sheet(item: $model.docScanRequest) { DocScanSheet(request: $0) }
        .sheet(item: $model.newDocRequest) { NewDocSheet(request: $0) }
        .sheet(item: $model.saveDocsRequest) { SaveDocsSheet(request: $0) }
        .sheet(item: $model.diagramRequest) { DiagramEditorSheet(request: $0) }
        .sheet(item: $model.newDiscussionRequest) { request in
            NewDiscussionSheet(request: request)
        }
        .sheet(item: $model.newResearchRequest) { NewResearchSheet(request: $0) }
        .sheet(item: $model.concludeDiscussionRequest) { request in
            ConcludeDiscussionSheet(id: request.entry)
        }
        .sheet(item: $model.prCleanupRequest) { pr in
            PRCleanupSheet(pr: pr)
        }
        .sheet(item: $model.bulkCleanupRequest) { request in
            BulkCleanupSheet(prs: request.prs)
        }
        .sheet(item: $model.completePRRequest) { request in
            CompletePRSheet(id: request.id)
        }
        .sheet(item: $model.prCommentsRequest) { request in
            PRCommentsSheet(request: request)
        }
        .sheet(item: $model.implementRequest) { request in
            ImplementSheet(request: request)
        }
        .sheet(item: $model.backlogCreateRequest) { request in
            BacklogBatchCreateSheet(request: BacklogBatchRequest(entries: [request.entry]))
        }
        .sheet(item: $model.backlogBatchRequest) { request in
            BacklogBatchCreateSheet(request: request)
        }
        .sheet(item: $model.newPBIRequest) { request in
            NewPBISheet(source: request.source)
        }
        .sheet(item: $model.projectSettingsRequest) { request in
            ProjectSettingsSheet(request: request)
        }
        .onAppear {
            model.startCrewEngine()
            model.openWindowAction = { id, value in
                if let value { openWindow(id: id, value: value) } else { openWindow(id: id) }
            }
            model.openSettingsAction = { openSettings() }
            if let raw = ProcessInfo.processInfo.environment["KB_OPEN_URL"], let url = URL(string: raw) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.handle(url: url) }
            }
        }
        .background(WindowTitleSetter(title: model.mode == .build ? "Mindmill — Build" : model.windowTitle))
    }
}

/// Keeps the window title as "Mindmill — <project>" even when a column sets its own navigation title.
struct EntryContextMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    let id: EntryID

    func body(content: Content) -> some View {
        content.contextMenu {
            if model.multiSelection.count > 1, model.multiSelection.contains(id) {
                bulkItems(model.multiSelection)
            } else {
                singleItems
            }
        }
    }

    @ViewBuilder
    private func bulkItems(_ ids: Set<EntryID>) -> some View {
        Button("Ask \(Brain.name) About These \(ids.count)…") { model.askAboutEntries(ids, question: "") }
        Button("Work on These in Build…") { model.startLeadOn(ids) }
        if ids.allSatisfy({ $0.section == .followups }) {
            Divider()
            Button("Mark \(ids.count) Done") { model.closeFollowups(ids, status: .done) }
            Button("Drop \(ids.count)") { model.closeFollowups(ids, status: .dropped) }
        }
        Divider()
        Menu("Move to Scope") {
            ForEach(model.index.projects, id: \.id) { p in
                Button(p.title) { model.moveEntries(ids, to: p.id) }
            }
        }
        Button("Delete \(ids.count)…", role: .destructive) {
            // The detail pane asks to confirm.
            model.multiSelection = ids
        }
    }

    @ViewBuilder
    private var singleItems: some View {
            Button("Ask \(Brain.name) About This…") { model.askAbout(.entry(id, title: model.index.entry(id)?.title ?? id.stem)) }
            Button("Work on It with \(Brain.name)…") { model.workWithClaude(.entry(id, title: model.index.entry(id)?.title ?? id.stem)) }
            if AppModel.pbiSources.contains(id.section) {
                Button("New PBI or Bug…") { model.newPBIRequest = NewPBIRequest(source: id) }
                Button("Create PBI with \(Brain.name)…") { model.createWorkItem(from: id) }
                if id.section == .meetings {
                    Button("Suggest PBIs with \(Brain.name)") { model.suggestPBIs(for: id) }
                }
            }
            if model.canShare(id) {
                Menu("Sharing") { SharingItems(id: id) }
            }
            Divider()
            if id.section == .meetings {
                Button("Open Meeting Window") { model.openMeeting(id) }
                Button("Take Notes") { model.takeNotes(id) }
                Divider()
            }
            if id.section != .overview {
                Menu("Move to Scope") {
                    ForEach(model.index.projects.filter { $0.id != id.project }, id: \.id) { p in
                        Button(p.title) { model.moveEntry(id, to: p.id) }
                    }
                }
            }
            Button("Delete…", role: .destructive) { model.requestDelete(id) }
    }
}

extension View {
    func entryContextMenu(_ id: EntryID) -> some View { modifier(EntryContextMenu(id: id)) }
}

struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.title = title }
    }
}

// MARK: Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.planningOrderKey) private var planningOrder = ""
    @AppStorage(AppModel.workOrderKey) private var workOrder = ""

    var body: some View {
        VStack(spacing: 0) {
            TodayRow()
            RemindersRow()
            GoalsRow()
            Divider()
            ProjectPicker()
            Divider()
            if let project = model.project {
                List(selection: Binding(get: { model.sidebarSelection }, set: { model.selectSidebar($0) })) {
                    ProjectSidebarRow(project: project)
                    item("sessions", project: project.id)
                    if model.hasOverview(project: project.id) {
                        row(.overview, project: project.id)
                    }
                    reorderable("Planning", order: $planningOrder, defaults: SidebarOrder.planning, project: project.id)
                    reorderable("Work", order: $workOrder, defaults: SidebarOrder.work, project: project.id)
                }
                .listStyle(.sidebar)
                // Space under the scope picker that scrolling or a restored selection can't take away.
                .padding(.top, 8)
                Divider()
                Button {
                    model.openAsk()
                } label: {
                    HStack {
                        Label("Ask a question", systemImage: "questionmark.bubble")
                        Spacer()
                        Text("⌘K").foregroundStyle(.secondary).font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .help("Ask a question across the knowledge base, the code, related scopes and your sources")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button { model.addProjectRequest = AddProjectRequest() } label: {
                        Label("Add a Project…", systemImage: "folder.badge.plus")
                    }
                    .disabled(model.loadError != nil)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
        }
    }

    /// A sidebar section whose rows the user can drag into their own order.
    private func reorderable(_ title: String, order: Binding<String>, defaults: [String], project: String) -> some View {
        let full = SidebarOrder.resolve(SidebarOrder.decode(order.wrappedValue), defaults: defaults)
        let visible = full.filter { $0 != "overview" || model.hasOverview(project: project) }
        return Section(title) {
            ForEach(visible, id: \.self) { key in
                item(key, project: project)
            }
            .onMove { from, to in
                order.wrappedValue = SidebarOrder.encode(SidebarOrder.move(full, visible: visible, from: from, to: to))
            }
        }
    }

    @ViewBuilder
    private func item(_ key: String, project: String) -> some View {
        if key == "sessions" {
            let needs = model.planItems(scope: project).filter(model.needsYou).count
            SidebarLabel(title: "Sessions", systemImage: "bubble.left.and.text.bubble.right", item: .sessions)
                .badge(needs > 0 ? Text("\(needs)").foregroundStyle(.white).bold() : nil)
                .badgeProminence(needs > 0 ? .increased : .standard)
                .tag(SidebarItem.sessions)
                .help("\(Brain.name) conversations in Plan, wherever they were started: creating PBIs and bugs, research, ideas, discussions, follow-ups, meetings, goals, questions"
                      + (needs > 0 ? ". \(needs) need\(needs == 1 ? "s" : "") you." : ""))
        } else if key == "pullRequests" {
            SidebarLabel(title: "Pull Requests", systemImage: "arrow.triangle.pull", item: .pullRequests)
                .badge(model.pullRequests?.needingAnswers ?? 0)
                .tag(SidebarItem.pullRequests)
                .help("Your open pull requests. The number is how many have comments waiting.")
        } else if let section = KBSection(rawValue: key) {
            if section == .architecture {
                row(section, project: project)
                    .help("How the systems fit together across repos: the parts, what talks to what, and why")
            } else {
                row(section, project: project)
            }
        }
    }

    @ViewBuilder
    private func row(_ section: KBSection, project: String) -> some View {
        let badge = model.sidebarBadge(section, project: project)
        if section == .facts && badge.needsYou {
            let changes = model.factChangeCount(project: project)
            let proposed = model.factProposals(project: project).count
            SidebarLabel(title: section.title, systemImage: SidebarView.icon(section), item: .section(section))
                .badge(Text("\(badge.count)").foregroundStyle(.white).bold())
                .tag(SidebarItem.section(section))
                .badgeProminence(.increased)
                .help([changes > 0 ? "\(changes) fact\(changes == 1 ? "" : "s") may have changed" : nil,
                       proposed > 0 ? "\(proposed) new fact\(proposed == 1 ? "" : "s") to approve" : nil]
                    .compactMap { $0 }.joined(separator: "; "))
        } else if section == .inbox && badge.needsYou {
            SidebarLabel(title: section.title, systemImage: SidebarView.icon(section), item: .section(section))
                .badge(Text("\(badge.count)").foregroundStyle(.white).bold())
                .tag(SidebarItem.section(section))
                .badgeProminence(.increased)
        } else {
            let empty = section == .inbox || (section == .overview && model.index.count(project: project, section: section) == 0)
            SidebarLabel(title: section.title, systemImage: SidebarView.icon(section), item: .section(section))
                .badge(section == .overview ? 0 : badge.count)
                .foregroundStyle(empty ? .secondary : .primary)
                .tag(SidebarItem.section(section))
        }
    }

    static func icon(_ s: KBSection) -> String {
        switch s {
        case .overview: return "doc.text"
        case .decisions: return "checkmark.seal"
        case .meetings: return "person.2"
        case .facts: return "lightbulb"
        case .architecture: return "building.columns"
        case .followups: return "checklist"
        case .backlog: return "list.bullet.rectangle"
        case .discussions: return "bubble.left.and.bubble.right"
        case .ideas: return IdeaRow.icon
        case .research: return ResearchStatus.icon
        case .references: return "bookmark"
        case .inbox: return "tray.and.arrow.down"
        }
    }
}

/// Cross-project: the day plan sits above the project picker.
struct TodayRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.kbTheme) private var theme

    var body: some View {
        let selected = model.sidebarSelection == .today
        let plan = model.dailyPlan
        let open = plan?.today.filter { $0.done == false && !$0.notRelevant && model.todayShows($0) }.count ?? 0
        Button {
            model.selectSidebar(.today)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sun.max")
                    .foregroundStyle(selected ? Color.white : theme.sidebarIconColor)
                    .frame(width: 18)
                Text("Today")
                    .font(.body.weight(.medium))
                Spacer()
                if model.morning.isBusy {
                    ProgressView().controlSize(.mini)
                } else if open > 0 {
                    Text("\(open)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : .primary)
            .background(selected ? theme.selectionColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .help("The day plan across all scopes (⌘0)")
    }
}

struct ProjectPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text((model.selectedGroup?.title ?? "Project").uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Menu {
                    ForEach(model.index.groups) { g in
                        Section(g.title) {
                            ForEach(g.scopes.compactMap { model.index.project($0) }) { p in
                                Button {
                                    model.selectProject(p.id)
                                } label: {
                                    if p.id == model.projectID {
                                        Label(p.title, systemImage: "checkmark")
                                    } else {
                                        Text(p.title)
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Projects and Scopes…") { model.scopesSheet = true }
                } label: {
                    Text(model.project?.title ?? "No scope")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .disabled(model.index.projects.isEmpty)
                .help("Switch scope")
                Spacer(minLength: 0)
                if let p = model.project {
                    Button {
                        model.projectSettingsRequest = ProjectSettingsRequest(project: p.id)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("\(p.title) settings: tracker, conventions, knowledge sources")
                }
            }
            if let p = model.project {
                Text(p.wide ? (model.index.overviewSpansAll ? "Everything in Mindmill" : "Project-wide scope")
                     : KBLayout.of(root: model.rootURL).teamDir(p.id) != nil ? "Scope · team knowledge in the repo" : "Scope · \(p.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }
}

// MARK: Content column

struct ContentColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.loadError != nil {
                Color.clear
            } else if model.sidebarSelection == .today && !model.isSearching {
                TodayView()
            } else if model.sidebarSelection == .reminders && !model.isSearching {
                RemindersView()
            } else if model.sidebarSelection == .goals && !model.isSearching {
                GoalsView()
            } else if model.isSearching {
                SearchResultsView()
            } else if let project = model.project {
                switch model.sidebarSelection {
                case .timeline:
                    DecisionsColumn(project: project)
                case .pullRequests:
                    PullRequestsList()
                case .sessions:
                    PlanSessionsList(project: project)
                case .today:
                    TodayView()
                case .reminders:
                    RemindersView()
                case .goals:
                    GoalsView()
                case .project:
                    ProjectColumn(project: project)
                case .section(.inbox):
                    InboxView(project: project)
                case .section(.followups):
                    FollowupsView(project: project)
                case .section(.backlog):
                    if model.trackerKind(project.id) == "local" {
                        LocalBacklogView(project: project)
                    } else {
                        BacklogView(project: project)
                    }
                case .section(.meetings):
                    MeetingsView(project: project)
                case .section(.discussions):
                    DiscussionsView(project: project)
                case .section(.ideas):
                    IdeasView(project: project)
                case .section(.research):
                    ResearchListView(project: project)
                case .section(.architecture):
                    ArchitectureView(project: project)
                case .section(.references):
                    ReferencesView(project: project)
                case .section(.facts):
                    FactsColumn(project: project)
                case .section(.decisions):
                    DecisionsColumn(project: project)
                case .section(let section):
                    EntryListView(project: project, section: section)
                case nil:
                    ListEmptyState(title: "Choose a section", systemImage: "sidebar.left")
                }
            } else {
                ListEmptyState(title: "No projects yet", systemImage: "folder.badge.plus",
                               message: "Add a project from its repositories. Team knowledge in their knowledgebase/ folders shows up right away, and a scan can find more.") {
                    Button("Add a Project…") { model.addProjectRequest = AddProjectRequest() }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NewEntryMenu()
                Button {
                    model.openAsk()
                } label: {
                    Label("Ask", systemImage: "questionmark.bubble")
                }
                .disabled(model.project == nil)
                .help("Ask about \(model.project?.title ?? "the project") (⌘K)")
                Button {
                    model.newSession()
                } label: {
                    Label("\(Brain.name) Session", systemImage: "sparkles")
                }
                .help("Start a \(Brain.name) session to work on something, or run a skill (⇧⌘K)")
            }
        }
    }
}

struct NewEntryMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("In \(model.project?.title ?? "")") {
                Button("New Decision…") { model.requestNewEntry(.decisions) }
                Button("New Meeting…") { model.requestNewEntry(.meetings) }
                Button("New Discussion…") {
                    if let p = model.projectID { model.newDiscussionRequest = NewDiscussionRequest(project: p) }
                }
                Button("New Research…") {
                    if let p = model.projectID { model.newResearchRequest = NewResearchRequest(project: p) }
                }
                Button("New Fact…") { model.requestNewEntry(.facts) }
                if let p = model.project, !model.hasOverview(project: p.id) {
                    Button("Write Overview…") {
                        model.createEntry(NewEntryRequest(project: p.id, section: .overview), title: p.title)
                    }
                    .help("A few lines on what this scope is: every \(Brain.name) session here starts by reading it")
                }
                Button("New Architecture Note…") { model.requestNewEntry(.architecture) }
                Button("New Follow-up…") { model.requestNewEntry(.followups) }
                Button("New Backlog Item…") { model.requestNewEntry(.backlog) }
            }
        } label: {
            Label("New Entry", systemImage: "plus")
        }
        .disabled(model.project == nil)
        .help("New entry in \(model.project?.title ?? "the selected project")")
    }
}

struct EntryListView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    let section: KBSection

    var body: some View {
        let every = model.index.entries(project: project.id, section: section)
        let query = model.listQuery(.section(section))
        let key = ListSearchKey.section(section)
        let picked = model.tagSelection(key)
        let all = model.tagFiltered(query.isEmpty ? every : every.filter { $0.matches(query) }, key)
        let drafts = all.filter(\.isDraft)
        let unsaved = model.document.flatMap { $0.isNew && $0.id.project == project.id && $0.id.section == section ? $0 : nil }
        let proposals = section == .facts ? model.factProposals(project: project.id) : []
        if every.isEmpty && unsaved == nil && proposals.isEmpty && (section != .facts || query.isEmpty) {
            emptyState
        } else {
            VStack(spacing: 0) {
                if section != .overview && section != .decisions {
                    ListSearchField(key: .section(section), prompt: "Search \(section.title.lowercased())")
                    TagFilterBar(key: key, available: every.map(\.tags))
                }
                Divider()
                let sections = daySections(all.filter { !$0.isDraft })
                List(selection: model.entrySelection) {
                    if let unsaved {
                        UnsavedRow(document: unsaved).tag(unsaved.id)
                    }
                    if !proposals.isEmpty {
                        ProposedFactsRow(count: proposals.count)
                    }
                    DraftsSection(drafts: drafts)
                    if sections.isEmpty, proposals.isEmpty, !query.isEmpty {
                        ListSearchNoMatch(query: query)
                    } else if sections.isEmpty, query.isEmpty, !picked.isEmpty {
                        TagFilterNoMatch(key: key)
                    }
                    ForEach(sections) { day in
                        if let title = day.title {
                            Section(title) { rows(day.items) }
                        } else {
                            rows(day.items)
                        }
                    }
                }
                .listStyle(.inset)
            }
            .navigationSubtitle(section.title)
        }
    }

    private struct Day: Identifiable {
        let title: String?
        let items: [KBEntry]
        var id: String { title ?? "" }
    }

    /// Dated sections (Today, Yesterday, the days of the week, Older); facts and architecture stay one list.
    private func daySections(_ entries: [KBEntry]) -> [Day] {
        let today = KBDate.today()
        switch section {
        case .decisions, .inbox:
            return DaySections.group(entries, date: \.date, today: today, direction: .past)
                .map { Day(title: $0.title, items: $0.items) }
        default:
            return entries.isEmpty ? [] : [Day(title: nil, items: entries)]
        }
    }

    @ViewBuilder
    private func rows(_ entries: [KBEntry]) -> some View {
        ForEach(entries) { entry in
            EntryRow(entry: entry).tag(entry.id).entryContextMenu(entry.id)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if section == .overview {
            ListEmptyState(title: "No overview", systemImage: "doc.text", message: "\(project.title) has no overview.md yet.") {
                Button("Create Overview") {
                    model.createEntry(NewEntryRequest(project: project.id, section: .overview), title: project.title)
            }
            }
        } else {
            ListEmptyState(title: "No \(section.title.lowercased())", systemImage: "tray", message: "\(project.title) has no \(section.title.lowercased()) yet.") {
                Button("New \(section.singularTitle)…") { model.requestNewEntry(section) }
            }
        }
    }
}

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Scope", selection: $model.searchAllProjects) {
                Text(model.project?.title ?? "This Scope").tag(false)
                Text("All Scopes").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            let results = model.searchResults
            let q = model.searchText
            let workItems = (model.searchAllProjects ? (model.tracker?.items ?? []) : model.trackerItems(scope: model.projectID ?? ""))
                .filter { $0.matches(q) }
            let reminders = model.reminders.filter { $0.matches(q) }
            let goals = model.goals.filter { $0.matches(q) }
            let strict = results.reduce(0) { $0 + $1.entries.count }
            List(selection: model.entrySelection) {
                VagueSearchSection(query: q, strictCount: strict)
                if !workItems.isEmpty {
                    Section {
                        ForEach(workItems.prefix(50)) { TrackerItemRow(item: $0, showScopes: true) }
                    } header: {
                        resultHeader("Work items in Azure DevOps", count: workItems.count, systemImage: "list.bullet.rectangle")
                    }
                }
                WorkItemSearchSection(query: q.trimmingCharacters(in: .whitespaces), shown: Set(workItems.map(\.id)), showScopes: true)
                ForEach(results, id: \.project.id) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            EntryRow(entry: entry, showSection: true).tag(entry.id).entryContextMenu(entry.id)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "folder.fill")
                            Text(group.project.title)
                            Spacer()
                            Text("\(group.entries.count)")
                                .monospacedDigit()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(group.project.id == model.projectID ? Color.accentColor : .secondary)
                    }
                }
                if !reminders.isEmpty {
                    Section {
                        ForEach(reminders) { r in
                            ReminderRow(reminder: r)
                                .contentShape(Rectangle())
                                .onTapGesture { model.pickSearchResult(.reminder(r.id)) }
                                .listRowBackground(model.searchPick == .reminder(r.id) ? Color.accentColor.opacity(0.15) : nil)
                        }
                    } header: {
                        resultHeader("Reminders", count: reminders.count, systemImage: "bell")
                    }
                }
                if !goals.isEmpty {
                    Section {
                        ForEach(goals) { g in
                            GoalRow(goal: g)
                                .contentShape(Rectangle())
                                .onTapGesture { model.pickSearchResult(.goal(g.id)) }
                                .listRowBackground(model.searchPick == .goal(g.id) ? Color.accentColor.opacity(0.15) : nil)
                        }
                    } header: {
                        resultHeader("Goals", count: goals.count, systemImage: "mountain.2")
                    }
                }
            }
            .listStyle(.inset)
            .onAppear { model.refreshTracker() }
        }
        .onAppear { model.searchWorkItems(model.searchText) }
        .onChange(of: model.searchText) { _, q in model.searchWorkItems(q) }
    }

    private func resultHeader(_ title: String, count: Int, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage)
            Text(title)
            Spacer()
            Text("\(count)").monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

enum SearchPick: Equatable {
    case reminder(String)
    case goal(String)
}

struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry
    var showSection = false

    var body: some View {
        let superseded = entry.status == .superseded
        let dirty = model.document.map { $0.id == entry.id && $0.isDirty } ?? false
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if dirty {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                        .help("Unsaved changes")
                }
                Text(entry.title)
                    .font(.headline)
                    .strikethrough(superseded)
                    .foregroundStyle(superseded ? .secondary : .primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SharingIcon(id: entry.id)
            }
            ChipRow(spacing: 5) {
                if showSection {
                    Text(entry.section.singularTitle).font(.caption).foregroundStyle(.secondary)
                }
                if !entry.date.isEmpty {
                    Text(DateText.display(entry.date)).font(.caption).foregroundStyle(.secondary)
                }
                if entry.section == .meetings, let start = entry.field("start") {
                    Text(entry.field("end").map { "\(start)–\($0)" } ?? start).monospacedDigit()
                        .font(.caption).foregroundStyle(.secondary)
                }
                StatusBadge(status: entry.status)
                if entry.section == .facts, !model.factChanges(for: entry.id).isEmpty {
                    MayHaveChangedChip()
                }
                InBuildChip(id: entry.id)
                ScopeChips(entry: entry)
                TagChips(tags: entry.tags, key: showSection ? nil : .section(entry.section))
                if let m = entry.meetingStatus, m != .filed {
                    let chip = MeetingDayRow.chip(entry)
                    Chip(text: chip.text, color: chip.color)
                }
            }
            if !entry.summary.isEmpty {
                Text(entry.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct UnsavedRow: View {
    let document: EntryDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                Text(document.title).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Text("Not saved")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }
            Text(DateText.display(document.frontmatter.string("date") ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct StatusBadge: View {
    let status: DecisionStatus?

    var body: some View {
        switch status {
        case .proposed:
            badge("Proposed", .orange)
        case .superseded:
            badge("Superseded", .gray)
        default:
            EmptyView()
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
    }
}

enum DateText {
    static func display(_ iso: String) -> String {
        guard let date = KBDate.parse(iso) else { return iso }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// "9 Nov", without the year.
    static func short(_ iso: String) -> String {
        guard let date = KBDate.parse(iso) else { return iso }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Decisions as a list by day, or as a timeline of which decision replaced which.
struct DecisionsColumn: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    @AppStorage("decisionsTimeline") private var timeline = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $timeline) {
                Text("List").tag(false)
                Text("Timeline").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 8)
            .help("Timeline shows which decisions replaced earlier ones")
            ListSearchField(key: .decisions, prompt: "Search decisions")
            if !timeline { TagFilterBar(key: .decisions, available: model.index.entries(project: project.id, section: .decisions).map(\.tags)) }
            Divider()
            if timeline {
                TimelineView(project: project)
            } else {
                EntryListView(project: project, section: .decisions)
            }
        }
    }
}

/// Switching between Plan and Build: the new mode fades in over the old one's place. The old one goes at once, so the
/// two split views never share the window, and so never the column widths AppKit saves for it.
enum ModeTransition {
    static let value = AnyTransition.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.995)), removal: .identity)
}

/// ⌘F puts the cursor in Plan's search field (macOS 15 and later).
private struct SearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.searchFocused(focused)
        } else {
            content
        }
    }
}

/// A Plan sidebar row's label: every icon in the same blue, white on the selected row's highlight.
struct SidebarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.kbTheme) private var theme
    let title: String
    let systemImage: String
    let item: SidebarItem

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(model.sidebarSelection == item && !model.isSearching ? Color.white : theme.sidebarIconColor)
        }
    }
}
