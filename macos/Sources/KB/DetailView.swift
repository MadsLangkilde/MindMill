import KBCore
import KBEngine
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.loadError {
            ListEmptyState(title: error.title, systemImage: "books.vertical", message: error.message) {
                SettingsLink { Text("Open Settings…") }
                if error.isMissing {
                    Button("Create a Knowledge Base Here") { model.createKnowledgeBase() }
                        .help("Makes \(model.rootPath) with an empty kb.json, then asks for your first project")
                }
                Button("Try Again") {
                    model.reload()
                    model.startWatching()
                }
            }
        } else if model.multiSelection.count > 1 {
            MultiSelectionView(ids: model.multiSelection)
        } else if model.sidebarSelection == .project, !model.isSearching, let p = model.project {
            ProjectDetail(project: p)
        } else if model.sidebarSelection == .section(.architecture), model.architectureTab == .docs, !model.isSearching,
                  let scope = model.projectID {
            if let doc = model.projectDoc(scope, model.selectedProjectDoc) {
                ProjectDocDetail(scope: scope, doc: doc).id(doc.path + doc.file + doc.modified)
            } else {
                ListEmptyState(title: "No Document Selected", systemImage: "doc.richtext", message: "Pick a document from the repository, or add some with +.")
            }
        } else if let doc = model.document {
            if doc.id.section == .research, !doc.isNew {
                ResearchDetailView(doc: doc).id(doc.id)
            } else {
                EntryDetailView(doc: doc)
            }
        } else if model.isSearching, case .reminder(let id)? = model.searchPick, let r = model.reminders.first(where: { $0.id == id }) {
            ReminderDetailView(reminder: r)
        } else if model.isSearching, case .goal(let id)? = model.searchPick, let g = model.goals.first(where: { $0.id == id }) {
            GoalDetailView(goal: g)
        } else if model.isSearching, let id = model.selectedWorkItem, let item = model.workItem(id) {
            WorkItemDetailView(item: item)
        } else if model.sidebarSelection == .sessions, !model.isSearching {
            if let s = model.selectedSession, s.space == .plan {
                SessionView(session: s).id(s.id)
            } else {
                SessionStartView()
            }
        } else if model.sidebarSelection == .pullRequests, !model.isSearching {
            if let id = model.selectedPR {
                PullRequestDetailView(id: id).id(id)
            } else {
                ListEmptyState(title: "No Pull Request Selected", systemImage: "arrow.triangle.pull", message: "Pick one to see its comments, reply, resolve, or complete it.")
            }
        } else if model.sidebarSelection == .section(.backlog), !model.isSearching, let p = model.project,
                  model.trackerKind(p.id) == "local" {
            LocalWorkDetail(project: p)
        } else if model.sidebarSelection == .section(.backlog), model.showLooseTasks, let p = model.project {
            LooseTasksView(project: p)
        } else if model.sidebarSelection == .section(.facts), model.showProposedFacts, model.document == nil, let p = model.project {
            ProposedFactsView(project: p)
        } else if model.sidebarSelection == .section(.backlog), model.showProposedBacklog, let p = model.project {
            ProposedBacklogView(project: p)
        } else if model.sidebarSelection == .section(.backlog), let id = model.selectedWorkItem, let item = model.workItem(id) {
            WorkItemDetailView(item: item)
        } else if model.sidebarSelection == .today {
            TodayDetail()
        } else if model.sidebarSelection == .goals {
            if let g = model.goals.first(where: { $0.id == model.selectedGoalID }) {
                GoalDetailView(goal: g)
            } else {
                ListEmptyState(title: "No Goal Selected", systemImage: "mountain.2", message: "Pick a goal, or add one with +. Active goals quietly shape briefs, meeting prep and the morning plan.")
            }
        } else if model.sidebarSelection == .reminders {
            if let r = model.reminders.first(where: { $0.id == model.selectedReminderID }) {
                ReminderDetailView(reminder: r)
            } else {
                ListEmptyState(title: "No Reminder Selected", systemImage: "bell", message: "Add one with + or ⌥⌘R. Due-date choices: today, tomorrow, in a week, or any date.")
            }
        } else {
            ListEmptyState(title: "No Entry Selected", systemImage: "doc.text", message: "Choose an entry in \(model.project?.title ?? "the list").")
        }
    }
}

struct EntryDetailView: View {
    @Environment(AppModel.self) private var model
    let doc: EntryDocument
    @State private var bodyHeight: CGFloat = 200

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let conflict = model.diskConflict {
                ConflictBanner(conflict: conflict)
            }
            EntryActionBanner(doc: doc)
            if model.isEditing {
                ScrollView(.vertical) {
                    EntryHeader(doc: doc, isEditing: true)
                        .id(doc.id)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button {
                        model.diagramRequest = DiagramRequest(title: "New Diagram", source: MermaidBlocks.templates[0].source,
                                                              project: doc.id.project) { source in
                            guard let body = model.document?.body else { return }
                            model.document?.body = MermaidBlocks.replacing(Int.max, with: source, in: body)
                        }
                    } label: {
                        Label("Insert Diagram…", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .controlSize(.small)
                    .help("Draw a Mermaid diagram, by hand or with \(Brain.name). It goes at the end of the text.")
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                Divider()
                TextEditor(text: Binding(get: { model.document?.body ?? "" }, set: { model.document?.body = $0 }))
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            } else {
                // One scroll for the whole entry: the header and the body move together.
                let renderer = MarkdownRenderer(linkRewriter: MarkdownRenderer.entryLinkRewriter, diagramLinks: true)
                let trimmed = doc.body.trimmingCharacters(in: .whitespacesAndNewlines)
                let html = trimmed.isEmpty ? "<p class=\"empty\">No content yet. Press ⌘E to edit.</p>" : renderer.render(doc.body)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        EntryHeader(doc: doc, isEditing: false)
                            .id(doc.id)
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                            .padding(.bottom, 12)
                        if !doc.isNew, doc.id.section == .discussions {
                            DiscussionPanel(id: doc.id)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                        }
                        if !doc.isNew, doc.id.section == .ideas {
                            IdeaPanel(id: doc.id)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                        }
                        if !doc.isNew, AppModel.pbiSources.contains(doc.id.section) {
                            RelatedPBIsPanel(id: doc.id)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                        }
                        Divider()
                        MarkdownWebView(
                            html: MarkdownRenderer.page(body: html, accentHex: NSColor.controlAccentColor.hexString),
                            baseURL: doc.url.deletingLastPathComponent(),
                            onLink: { url in
                                if url.hasPrefix("kb://diagram"), let i = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "index" })?.value.flatMap(Int.init) {
                                    model.editEntryDiagram(doc.id, index: i)
                                } else {
                                    model.openLink(url)
                                }
                            },
                            contentHeight: $bodyHeight
                        )
                        .frame(height: max(bodyHeight, 40))
                        .id(doc.id)
                    }
                }
                .onChange(of: doc.id) { _, _ in bodyHeight = 200 }
            }
            if doc.isDraft || doc.isDirty { SaveBar(doc: doc) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if doc.isDirty {
                    Button {
                        model.save()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .help("Save (⌘S)")
                }
                Picker("Mode", selection: $model.isEditing) {
                    Label("Preview", systemImage: "eye").tag(false)
                    Label("Edit", systemImage: "pencil").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Toggle edit mode (⌘E)")
                if doc.status == .active && !doc.isNew {
                    Button {
                        model.requestSupersede()
                    } label: {
                        Label("Supersede…", systemImage: "arrow.triangle.branch")
                    }
                    .help("Write a new decision that replaces this one")
                }
                Button {
                    model.revealInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(doc.isNew)
                .help("Reveal in Finder")
                Button {
                    model.openInDefaultEditor()
                } label: {
                    Label("Open in Default Editor", systemImage: "arrow.up.forward.app")
                }
                .disabled(doc.isNew)
                .help("Open in default editor")
                Button {
                    model.askAbout(.entry(doc.id, title: doc.title))
                } label: {
                    Label("Ask \(Brain.name) About This", systemImage: "questionmark.bubble")
                }
                .disabled(doc.isNew)
                .help("Ask \(Brain.name) about this entry")
                if AppModel.pbiSources.contains(doc.id.section) {
                    Button {
                        model.newPBIRequest = NewPBIRequest(source: doc.id)
                    } label: {
                        Label("New PBI…", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .disabled(doc.isNew)
                    .help("A PBI or bug from this, after checking the backlog for one that exists")
                }
                Button {
                    model.workWithClaude(.entry(doc.id, title: doc.title))
                } label: {
                    Label("Work on It with \(Brain.name)", systemImage: "sparkles")
                }
                .disabled(doc.isNew)
                .help("Start a \(Brain.name) session about this entry")
                Button(role: .destructive) {
                    model.requestDelete(doc.id)
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
                .disabled(doc.isNew)
                .help("Delete this entry")
            }
        }
    }
}

struct ConflictBanner: View {
    @Environment(AppModel.self) private var model
    let conflict: DiskConflict

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(conflict == .modified ? "Changed on disk" : "Deleted on disk")
                .font(.callout.weight(.semibold))
            Text(conflict == .modified ? "This entry was changed outside the app while you were editing." :
                    "The file was removed while you were editing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button(conflict == .modified ? "Reload" : "Close") { model.reloadFromDisk() }
            Button("Keep Mine") { model.keepMine() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.14))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: Header

struct EntryHeader: View {
    @Environment(AppModel.self) private var model
    let doc: EntryDocument
    let isEditing: Bool

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(get: { model.document?.frontmatter.string(key) ?? "" },
                set: { value in
                    // One-line fields: a pasted line break would be saved as a literal \n.
                    let v = key == "title" || key == "summary" ? value.replacingOccurrences(of: "\n", with: " ") : value
                    model.document?.frontmatter.setString(key, v)
                })
    }

    private func listBinding(_ key: String) -> Binding<[String]> {
        Binding(get: { model.document?.frontmatter.list(key) ?? [] },
                set: { model.document?.frontmatter.setList(key, $0) })
    }

    private var statusBinding: Binding<DecisionStatus> {
        Binding(get: { model.document?.status ?? .active },
                set: { new in
                    guard let doc = model.document else { return }
                    if doc.frontmatter["status"] == nil && new == .active { return }
                    model.document?.frontmatter.set("status", .string(new.rawValue))
                })
    }

    var body: some View {
        if isEditing { editForm } else { readOnly }
    }

    // Preview: tidy, read-only, links clickable.
    private var readOnly: some View {
        let fm = doc.frontmatter
        let section = doc.id.section
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(doc.title)
                    .font(.title.weight(.semibold))
                    .strikethrough(doc.status == .superseded)
                    .foregroundStyle(doc.status == .superseded ? .secondary : .primary)
                    .textSelection(.enabled)
                if doc.isDirty {
                    Text("Edited")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            ChipRow(spacing: 12) {
                Label(section.singularTitle, systemImage: "doc.text")
                if let date = fm.string("date"), !date.isEmpty {
                    Label(DateText.display(date), systemImage: "calendar")
                }
                if section == .decisions {
                    Picker("Status", selection: statusBinding) {
                        ForEach(DecisionStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                if !doc.isNew, !doc.isDraft { SharingMenu(id: doc.id) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if section == .followups {
                FollowupFacts(fm: fm)
            } else if let summary = fm.string("summary"), !summary.isEmpty {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                if !model.index.siblings(of: doc.id.project).isEmpty, section != .overview, section != .inbox {
                    GridRow {
                        FieldLabel("Scopes")
                        EntryScopesRow(doc: doc)
                    }
                }
                if AppModel.taggedSections.contains(section) || !fm.list("tags").isEmpty {
                    GridRow {
                        FieldLabel("Tags")
                        if model.document?.id == doc.id {
                            TagEditor(tags: fm.list("tags")) { model.setTags($0) }
                        } else {
                            TagList(tags: fm.list("tags"))
                        }
                    }
                }
                if !fm.list("attendees").isEmpty {
                    GridRow {
                        FieldLabel("Attendees")
                        FlowLayout(spacing: 5) {
                            ForEach(fm.list("attendees"), id: \.self) { PersonChip(name: $0) }
                        }
                    }
                }
                if !fm.list("supersedes").isEmpty {
                    GridRow {
                        FieldLabel("Supersedes")
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(fm.list("supersedes"), id: \.self) { EntryLink(raw: $0) }
                        }
                    }
                }
                if let by = fm.string("superseded_by"), !by.isEmpty {
                    GridRow {
                        FieldLabel("Superseded by")
                        EntryLink(raw: by)
                    }
                }
                if !fm.list("source").isEmpty {
                    GridRow {
                        FieldLabel("Source")
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(fm.list("source"), id: \.self) { SourceView(source: $0) }
                        }
                    }
                }
                ForEach(otherKeys, id: \.self) { key in
                    GridRow {
                        FieldLabel(key.replacingOccurrences(of: "_", with: " "))
                        let value = fm.string(key) ?? ""
                        if EntryID(value) != nil || value.hasPrefix("http") {
                            SourceView(source: value)
                        } else {
                            Text(value)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .font(.callout)
            if section == .facts, !doc.isNew, !doc.isDraft {
                Divider().padding(.vertical, 4)
                LinkedFactsSection(id: doc.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let knownKeys: Set<String> = [
        "title", "date", "summary", "status", "supersedes", "superseded_by", "source", "tags", "attendees",
        "proposed_section", "proposed_by", "scopes", "tags_off", "related",
    ]

    private static let followupKeys: Set<String> = ["kind", "owner", "due", "raised_in", "resolved_by", "draft", "waiting_on"]

    private var otherKeys: [String] {
        doc.frontmatter.keys.filter {
            !Self.knownKeys.contains($0) && $0 != "draft" && !(doc.id.section == .followups && Self.followupKeys.contains($0))
        }
    }

    /// Follow-up fields as controls: kind, status, owner, due, where it was raised, what resolved it.
    @ViewBuilder
    private var followupRows: some View {
        let fm = model.document?.frontmatter ?? doc.frontmatter
        let status = FollowupStatus(rawValue: fm.string("status") ?? "open") ?? .open
        if status == .open, BacklogFollowup.workTitle(fm.string("title") ?? "") != nil {
            GridRow {
                FieldLabel("Backlog")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("This is work for the tracker, not a follow-up.").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Move to Suggested Backlog Items") { model.followupToBacklog(doc.id) }
                        .help("It becomes a suggested backlog item, checked against the tracker for duplicates, and this follow-up closes")
                }
            }
        }
        GridRow {
            FieldLabel("Kind")
            HStack {
                Picker("Kind", selection: stringBinding("kind")) {
                    Text("Action").tag("action")
                    Text("Question").tag("question")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Picker("Status", selection: stringBinding("status")) {
                    Text("Open").tag("open")
                    Text("Done").tag("done")
                    Text("Dropped").tag("dropped")
                }
                .fixedSize()
            }
        }
        GridRow {
            FieldLabel("Owner")
            PeoplePicker(names: Binding(get: { [stringBinding("owner").wrappedValue].filter { !$0.isEmpty } },
                                        set: { stringBinding("owner").wrappedValue = $0.first ?? "" }),
                         placeholder: "You", single: true)
        }
        GridRow {
            FieldLabel("Waiting on")
            PeoplePicker(names: Binding(get: { [stringBinding("waiting_on").wrappedValue].filter { !$0.isEmpty } },
                                        set: { stringBinding("waiting_on").wrappedValue = $0.first ?? "" }),
                         placeholder: "Nobody", single: true)
                .help("Someone whose answer or work this waits for. It then shows under Waiting on others.")
        }
        GridRow {
            FieldLabel("Due")
            OptionalDateField(value: stringBinding("due"))
        }
        if fm.list("raised_in").count > 1 {
            GridRow {
                FieldLabel("Raised in")
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(fm.list("raised_in"), id: \.self) { SourceView(source: $0) }
                }
                .help("Merged follow-ups keep every place they came from")
            }
        } else {
        GridRow {
            FieldLabel("Raised in")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("A meeting, or anything: “Teams chat with Tom”, an email, a URL", text: stringBinding("raised_in"))
                    Menu("Meetings") {
                        ForEach(recentMeetings) { m in
                            Button("\(DateText.display(m.date)) · \(m.title)") { stringBinding("raised_in").wrappedValue = m.id.rawValue }
                        }
                    }
                    .fixedSize()
                    .disabled(recentMeetings.isEmpty)
                }
                if let r = fm.string("raised_in"), EntryID(r) != nil { EntryLink(raw: r) }
            }
        }
        }
        if status != .open || !(fm.string("resolved_by") ?? "").isEmpty {
            GridRow {
                FieldLabel("Resolved by")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("A decision, a work item URL, or how", text: stringBinding("resolved_by"))
                        Menu("Decisions") {
                            ForEach(recentDecisions) { d in
                                Button(d.title) { stringBinding("resolved_by").wrappedValue = d.id.rawValue }
                            }
                        }
                        .fixedSize()
                        .disabled(recentDecisions.isEmpty)
                    }
                    if let r = fm.string("resolved_by"), EntryID(r) != nil { EntryLink(raw: r) }
                }
            }
        }
    }

    private var recentMeetings: [KBEntry] {
        Array(model.index.entries(project: doc.id.project, section: .meetings)
            .filter { $0.meetingStatus != .scheduled && $0.meetingStatus != .cancelled }
            .sorted { $0.date > $1.date }.prefix(15))
    }

    private var recentDecisions: [KBEntry] {
        Array(model.index.entries(project: doc.id.project, section: .decisions).sorted { $0.date > $1.date }.prefix(15))
    }

    // Edit: every known field as a control.
    private var editForm: some View {
        let section = doc.id.section
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                FieldLabel("Title")
                TextField("Title", text: stringBinding("title"))
                    .font(.title3.weight(.semibold))
            }
            GridRow {
                FieldLabel("Date")
                HStack {
                    TextField("YYYY-MM-DD", text: stringBinding("date"))
                        .font(.body.monospaced())
                        .frame(width: 130)
                    let date = model.document?.frontmatter.string("date") ?? ""
                    if !date.isEmpty && !KBDate.isISODate(date) {
                        Label("Use YYYY-MM-DD", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if section == .decisions {
                        Picker("Status", selection: statusBinding) {
                            ForEach(DecisionStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .fixedSize()
                    }
                }
            }
            GridRow {
                FieldLabel(section == .followups ? "Answer" : "Summary")
                TextField(section == .followups ? "The answer or outcome, once there is one" : "One line that stands alone",
                          text: stringBinding("summary"))
            }
            if section == .followups { followupRows }
            if !model.index.siblings(of: doc.id.project).isEmpty, section != .overview {
                GridRow {
                    FieldLabel("Scopes")
                    EntryScopesRow(doc: model.document ?? doc)
                }
            }
            GridRow {
                FieldLabel("Tags")
                ListField(placeholder: "comma, separated, lowercase", items: listBinding("tags"))
            }
            if section == .meetings || doc.frontmatter["attendees"] != nil {
                GridRow {
                    FieldLabel("Attendees")
                    PeoplePicker(names: listBinding("attendees"), placeholder: "Search Azure DevOps, or type a name")
                }
            }
            if section == .decisions {
                GridRow {
                    FieldLabel("Supersedes")
                    VStack(alignment: .leading, spacing: 4) {
                        ListField(placeholder: "project/decisions/id, …", items: listBinding("supersedes"))
                            .font(.body.monospaced())
                        ForEach(doc.frontmatter.list("supersedes"), id: \.self) { EntryLink(raw: $0) }
                    }
                }
                GridRow {
                    FieldLabel("Superseded by")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("project/decisions/id", text: stringBinding("superseded_by"))
                            .font(.body.monospaced())
                        if let by = doc.frontmatter.string("superseded_by"), !by.isEmpty { EntryLink(raw: by) }
                    }
                }
            }
            if section == .decisions || section == .facts || doc.frontmatter["source"] != nil {
                GridRow {
                    FieldLabel("Source")
                    TextField("Entry id or URL", text: stringBinding("source"))
                        .font(.body.monospaced())
                }
            }
            ForEach(otherKeys, id: \.self) { key in
                GridRow {
                    FieldLabel(key)
                    Text(doc.frontmatter.string(key) ?? "")
                        .foregroundStyle(.secondary)
                        .help("Kept as-is. Edit it in the file.")
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
            .frame(minWidth: 90, alignment: .trailing)
    }
}

struct TagList: View {
    let tags: [String]

    var body: some View {
        ChipRow(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .lineLimit(1)
                    .fixedSize()
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
            }
        }
    }
}

/// A link to another entry by id. An entry in another project names that project, and opening it
/// switches the selected project.
struct EntryLink: View {
    @Environment(AppModel.self) private var model
    let raw: String

    var body: some View {
        if let id = EntryID(raw) {
            let entry = model.index.entry(id)
            let otherProject = id.project != model.projectID
            Button {
                model.openLink(raw)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: entry == nil ? "questionmark.circle" : "arrow.right.circle")
                    if otherProject {
                        Text((model.index.project(id.project)?.title ?? id.project) + " ›")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text(entry?.title ?? raw)
                        .strikethrough(entry?.status == .superseded)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.link)
            .disabled(entry == nil)
            .help(entry == nil ? "\(raw) does not exist" : raw)
        } else {
            Text(raw).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct SourceView: View {
    let source: String

    var body: some View {
        if EntryID(source) != nil {
            EntryLink(raw: source)
        } else if let url = URL(string: source), let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme) {
            Link(source, destination: url)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(source).textSelection(.enabled)
        }
    }
}

/// Text field for an inline list. Keeps what is typed (including a trailing comma) while focused.
/// A list typed as text: what's typed stays as typed while editing, and the list is parsed from it.
struct ListField: View {
    let placeholder: String
    @Binding var items: [String]
    /// One item per line instead of comma separated.
    var perLine = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: perLine ? .vertical : .horizontal)
            .focused($focused)
            .onAppear { text = joined(items) }
            .onChange(of: text) { _, new in
                let parsed = parse(new)
                if parsed != items { items = parsed }
            }
            .onChange(of: items) { _, new in
                if !focused, parse(text) != new { text = joined(new) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { text = joined(items) }
            }
    }

    private func joined(_ list: [String]) -> String { list.joined(separator: perLine ? "\n" : ", ") }

    private func parse(_ t: String) -> [String] {
        t.split(whereSeparator: { perLine ? $0.isNewline : $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension NSColor {
    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
