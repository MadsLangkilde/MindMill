import KBCore
import KBEngine
import SwiftUI

struct ProjectSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ProjectSettingsRequest
    @State private var settings = ProjectSettings()
    @State private var original = ProjectSettings()
    @State private var tab: ProjectSettingsTab = .tracker
    @State private var tagsText = ""
    @State private var applyExisting = false

    var body: some View {
        let title = model.index.project(request.project)?.title ?? request.project
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(title) Settings").font(.title2.weight(.semibold))
                    Text("projects/\(request.project)/settings.json").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $tab) {
                    Text("Tracker").tag(ProjectSettingsTab.tracker)
                    Text("Conventions").tag(ProjectSettingsTab.conventions)
                    Text("Sources").tag(ProjectSettingsTab.sources)
                    Text("Sharing").tag(ProjectSettingsTab.sharing)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 10)
            Divider()
            Group {
                switch tab {
                case .tracker: trackerForm
                case .conventions: conventionsForm
                case .sources:
                    SourcesEditor(sources: $settings.sources, project: request.project, scopeLabel: "this scope",
                                  inherited: GlobalSources.load(root: model.rootURL))
                case .sharing: sharingForm
                }
            }
            .frame(minHeight: 380)
            Divider()
            HStack {
                if settings != original {
                    Text("Unsaved changes").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings == original)
            }
            .padding(16)
        }
        .frame(width: 640)
        .onAppear {
            settings = model.settings(for: request.project)
            original = settings
            tagsText = settings.tracker.tags.joined(separator: ", ")
            tab = request.tab
        }
    }

    private var trackerForm: some View {
        Form {
            Picker("Tracker", selection: $settings.tracker.kind) {
                Text("Azure DevOps").tag("azure-devops")
                Text("Jira (through \(Brain.name))").tag("jira")
                Text("Mindmill's own tracker").tag("local")
                Text("GitHub").tag("github")
                Text("None").tag("none")
                if !["azure-devops", "jira", "local", "github", "none"].contains(settings.tracker.kind) {
                    Text(settings.tracker.kind).tag(settings.tracker.kind)
                }
            }
            .onChange(of: settings.tracker.kind) { _, _ in settings.hasTracker = true }
            switch settings.tracker.kind {
            case "local":
                Text("Features, PBIs, bugs and tasks live in this scope's folder in the knowledge base, with an optional sprint plan. Find them under Backlog: a list on the left and a board on the right. \(Brain.name) adds and updates them with `kb work`.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Plan work in sprints", isOn: Binding(
                    get: { (model.localTrackers[request.project] ?? LocalTracker.load(scope: request.project, root: model.rootURL)).useSprints },
                    set: { on in model.editLocalTracker(request.project) { $0.useSprints = on } }))
            case "jira":
                TextField("Jira site", text: $settings.tracker.organization, prompt: Text("e.g. yourcompany.atlassian.net"))
                TextField("Project key", text: $settings.tracker.project, prompt: Text("e.g. APP"))
                TextField("Title prefix", text: $settings.tracker.titlePrefix, prompt: Text("e.g. Android: "))
                Text("\(Brain.name) creates and reads Jira issues through its Jira connector. Connect it under Settings → Connections.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case "none":
                EmptyView()
            default:
                TextField("Organization", text: $settings.tracker.organization, prompt: Text("required, e.g. Contoso"))
                TextField("Project", text: $settings.tracker.project, prompt: Text("required, e.g. AcmeApp"))
                if settings.tracker.kind == "azure-devops", missingTracker {
                    trackerWarning
                }
                TextField("Area path", text: $settings.tracker.areaPath, prompt: Text("e.g. AcmeApp\\Team"))
                TextField("Iteration root", text: $settings.tracker.iterationRoot, prompt: Text("e.g. AcmeApp\\Release"))
                TextField("Title prefix", text: $settings.tracker.titlePrefix, prompt: Text("e.g. Android: "))
                TextField("Tags", text: $tagsText, prompt: Text("comma, separated"))
                    .onChange(of: tagsText) { _, v in
                        settings.tracker.tags = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                TextField("Default parent", text: $settings.tracker.defaultParent, prompt: Text("work item id, or empty"))
                TextField("Assignee", text: $settings.tracker.assignee, prompt: Text("name@company.com"))
                TextField("Found in (bugs)", text: $settings.tracker.foundIn, prompt: Text("where the version comes from"))
            }
            Text("No secrets here: credentials stay where you keep them (for Azure DevOps, ~/.git-credentials).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
        .scrollContentBackground(.hidden)
    }

    private var missingTracker: Bool {
        settings.tracker.organization.trimmingCharacters(in: .whitespaces).isEmpty
            || settings.tracker.project.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Another scope of the same project whose Azure DevOps tracker is filled in, to copy from.
    private var siblingTracker: (title: String, tracker: ProjectSettings.Tracker)? {
        guard let me = model.index.project(request.project) else { return nil }
        for p in model.index.projects where p.group == me.group && p.id != me.id {
            let t = model.settings(for: p.id).tracker
            if t.kind == "azure-devops", !t.organization.isEmpty, !t.project.isEmpty { return (p.title, t) }
        }
        return nil
    }

    private var trackerWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Work items can't be created until the organization and the project are filled in. The grey text is only an example.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let sibling = siblingTracker {
                Button("Use the same as \(sibling.title): \(sibling.tracker.organization) / \(sibling.tracker.project)") {
                    settings.tracker.organization = sibling.tracker.organization
                    settings.tracker.project = sibling.tracker.project
                    if settings.tracker.areaPath.isEmpty { settings.tracker.areaPath = sibling.tracker.areaPath }
                    if settings.tracker.iterationRoot.isEmpty { settings.tracker.iterationRoot = sibling.tracker.iterationRoot }
                }
                .controlSize(.small)
                .help("Copies the organization, project, area path and iteration root; not the title prefix")
            }
        }
    }

    private var conventionsForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What skills learned about this scope, one sentence each. \(Brain.name) reads these; it never asks again for something listed here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            List {
                ForEach($settings.conventions) { $c in
                    HStack(alignment: .top, spacing: 8) {
                        TextField("key", text: $c.key)
                            .font(.body.monospaced())
                            .frame(width: 170)
                        TextField("value", text: $c.value, axis: .vertical)
                            .lineLimit(1...)
                            .scrollingInput(c.value, maxLines: 4)
                        Button {
                            settings.conventions.removeAll { $0.id == c.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }
            .listStyle(.inset)
            HStack {
                Button {
                    settings.conventions.append(.init(key: "", value: ""))
                } label: {
                    Label("Add Convention", systemImage: "plus")
                }
                Spacer()
            }
            .padding(12)
        }
    }

    static let sharingKinds: [KBSection] = [.notes, .decisions, .facts, .architecture, .followups, .backlog, .ideas, .research,
                                            .references, .discussions, .meetings, .overview]

    private var sharingForm: some View {
        let repo = model.sharing.repos[request.project]?.name
        return Form {
            Section {
                Text(repo == nil
                     ? "This scope has no repository on this Mac, so everything in it stays private."
                     : "What's shared gets a copy in \(repo!)/knowledgebase, part of your next commit and pull request there. Private entries stay only in your knowledge base on this Mac. You can still change each entry on its own.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("New entries of each kind") {
                ForEach(Self.sharingKinds) { kind in
                    Picker(kind.title, selection: Binding(
                        get: { SharingStatus.sharedByDefault(kind, chosen: settings.sharing) ? "shared" : "private" },
                        set: { settings.sharing[kind.rawValue] = $0 })) {
                        Text("Private").tag("private")
                        Text("Shared").tag("shared")
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("Also change the entries already there when I save", isOn: $applyExisting)
                    .help("Shares or makes private the existing entries of each kind you changed. Making entries private removes their copies from the repository; that goes out with your next commit there.")
            }
            .disabled(repo == nil)
        }
        .formStyle(.grouped)
    }

    private func save() {
        do {
            if settings.tracker != original.tracker { settings.hasTracker = true }
            try settings.save(project: request.project, root: model.rootURL)
            if applyExisting {
                let changed = Self.sharingKinds.filter {
                    SharingStatus.sharedByDefault($0, chosen: settings.sharing) != SharingStatus.sharedByDefault($0, chosen: original.sharing)
                }
                model.applySharingDefaults(changed.map { ($0, SharingStatus.sharedByDefault($0, chosen: settings.sharing)) }, scope: request.project)
            }
            model.reload()
            dismiss()
        } catch {
            model.errorMessage = "Could not write settings.json: \(error.localizedDescription)"
        }
    }
}

// MARK: Sources

/// Lists and edits knowledge sources. Writes nothing itself: the owner saves the list.
struct SourcesEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var sources: [KnowledgeSource]
    /// The project the sources are tested for; `nil` for the global list.
    let project: String?
    let scopeLabel: String
    var inherited: [KnowledgeSource] = []
    @State private var editing: SourceDraft?
    @State private var testing: KnowledgeSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Where \(Brain.name) looks when you Ask. The knowledge base, the code and docs, and related scopes are always used. \(Brain.name) routes on “use for”, so make it one clear line.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            List {
                Section("Built in") {
                    ForEach(BuiltinSources.all, id: \.id) { b in
                        HStack {
                            Image(systemName: b.id == BuiltinSources.kb ? "books.vertical" : b.id == BuiltinSources.code ? "chevron.left.forwardslash.chevron.right" : "link")
                                .frame(width: 20)
                                .foregroundStyle(.secondary)
                            Text(b.title)
                            Spacer()
                            Text("always on").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                Section("Configured for \(scopeLabel)") {
                    if sources.isEmpty {
                        Text("None yet.").foregroundStyle(.secondary)
                    }
                    ForEach($sources) { $s in
                        SourceRow(source: $s, onEdit: { editing = SourceDraft(source: s, isNew: false) },
                                  onTest: { testing = s },
                                  onDelete: { sources.removeAll { $0.id == s.id } })
                    }
                }
                if !inherited.isEmpty {
                    Section("Global (all scopes; edit in Mindmill Settings)") {
                        ForEach(inherited) { s in
                            HStack(spacing: 8) {
                                Image(systemName: SourceRow.icon(s.kind)).frame(width: 20).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.title)
                                    Text(s.useFor).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(s.enabled ? "on" : "off").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Menu {
                    ForEach(SourceKind.allCases) { kind in
                        Button {
                            let id = KnowledgeSource.makeID(title: kind.rawValue, taken: Set(sources.map(\.id)))
                            editing = SourceDraft(source: KnowledgeSource(id: id, kind: kind.rawValue, title: "", useFor: ""), isNew: true)
                        } label: {
                            Label(kind.title, systemImage: SourceRow.icon(kind.rawValue))
                        }
                    }
                } label: {
                    Label("Add Source", systemImage: "plus")
                }
                .fixedSize()
                Spacer()
            }
            .padding(12)
        }
        .sheet(item: $editing) { draft in
            SourceEditSheet(draft: draft, taken: Set(sources.map(\.id))) { saved in
                if let i = sources.firstIndex(where: { $0.id == draft.source.id }), !draft.isNew {
                    sources[i] = saved
                } else {
                    sources.append(saved)
                }
            }
        }
        .sheet(item: $testing) { s in
            SourceTestSheet(source: s, project: project)
        }
    }
}

struct SourceDraft: Identifiable {
    let id = UUID()
    var source: KnowledgeSource
    let isNew: Bool
}

struct SourceRow: View {
    @Binding var source: KnowledgeSource
    let onEdit: () -> Void
    let onTest: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $source.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            Image(systemName: SourceRow.icon(source.kind)).frame(width: 20).foregroundStyle(source.enabled ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(source.title).foregroundStyle(source.enabled ? .primary : .secondary)
                    Text(source.sourceKind?.title ?? source.kind).font(.caption).foregroundStyle(.tertiary)
                }
                Text(source.useFor.isEmpty ? "No “use for” yet" : source.useFor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Test", action: onTest).controlSize(.small)
            Button("Edit", action: onEdit).controlSize(.small)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
        }
    }

    static func icon(_ kind: String) -> String {
        switch SourceKind(rawValue: kind) {
        case .folder: return "folder"
        case .url: return "globe"
        case .adoWiki: return "book.closed"
        case .adoWorkItems: return "checklist"
        case .adoRepos: return "arrow.triangle.branch"
        case .teams: return "bubble.left.and.bubble.right"
        case .outlook: return "envelope"
        case .mcp: return "puzzlepiece.extension"
        case .command: return "terminal"
        case nil: return "questionmark.square.dashed"
        }
    }
}

struct SourceEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: SourceDraft
    let taken: Set<String>
    let onSave: (KnowledgeSource) -> Void
    @State private var source = KnowledgeSource(id: "", kind: "folder", title: "", useFor: "")
    @State private var values: [String: String] = [:]

    var body: some View {
        let kind = source.sourceKind
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: SourceRow.icon(source.kind))
                Text(draft.isNew ? "Add \(kind?.title ?? source.kind) Source" : "Edit \(source.title)").font(.title2.weight(.semibold))
            }
            Form {
                TextField("Title", text: $source.title, prompt: Text("Team wiki"))
                TextField("Use for", text: $source.useFor, prompt: Text("Which questions this source answers"), axis: .vertical)
                    .lineLimit(1...)
                    .scrollingInput(source.useFor, maxLines: 3)
                TextField("Id", text: $source.id)
                    .font(.body.monospaced())
                    .disabled(!draft.isNew)
                ForEach(kind?.fields ?? [], id: \.key) { field in
                    TextField(field.label + (field.required ? "" : " (optional)"),
                              text: Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 }),
                              prompt: Text(field.isList ? (field.placeholder.isEmpty ? "comma, separated" : field.placeholder) : field.placeholder))
                }
                Toggle("Enabled", isOn: $source.enabled)
            }
            .formStyle(.grouped)
            .multilineTextAlignment(.leading)
            .scrollContentBackground(.hidden)
            if kind == .command {
                Text("`{query}` in the command is replaced with what \(Brain.name) searches for.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add" : "Done") {
                    var s = source
                    for field in kind?.fields ?? [] {
                        let v = (values[field.key] ?? "").trimmingCharacters(in: .whitespaces)
                        if field.isList {
                            let l = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            s.config[field.key] = l.isEmpty ? nil : .list(l)
                        } else if case .other? = s.config[field.key], !v.isEmpty {
                            s.config[field.key] = .other(v)
                        } else {
                            s.config[field.key] = v.isEmpty ? nil : .string(v)
                        }
                    }
                    onSave(s)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            source = draft.source
            for (k, v) in source.config { values[k] = v.display }
        }
        .onChange(of: source.title) { _, t in
            if draft.isNew, !t.isEmpty { source.id = KnowledgeSource.makeID(title: t, taken: taken) }
        }
    }

    private var problem: String? {
        if source.title.trimmingCharacters(in: .whitespaces).isEmpty { return "A title is needed." }
        if source.useFor.trimmingCharacters(in: .whitespaces).isEmpty { return "Say what it is used for." }
        if draft.isNew, taken.contains(source.id) { return "The id \(source.id) is taken." }
        for f in source.sourceKind?.fields ?? [] where f.required && (values[f.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(f.label) is required."
        }
        return nil
    }
}

/// Runs `kb sources test`, or for connector kinds a one-shot `claude -p` limited to that source.
struct SourceTestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: KnowledgeSource
    let project: String?
    @State private var query = ""
    @State private var output = ""
    @State private var failed = false
    @State private var running = false
    @State private var ranWith = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test \(source.title)").font(.title2.weight(.semibold))
            HStack {
                TextField("Sample query", text: $query, prompt: Text("release process"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runCLI() }
                Button("Test") { runCLI() }
                    .disabled(running || query.isEmpty)
                Button("Test with \(Brain.name)") { runClaude() }
                    .disabled(running || query.isEmpty || !claudeAvailable)
                    .help(claudeAvailable ? "One question to \(Brain.name), using only this source" : model.claudeMissingExplanation)
            }
            if source.sourceKind?.testedByCLI == false {
                Text("\(source.sourceKind?.title ?? source.kind) is read through Claude's connectors, so the CLI can only print a hint. Use Test with \(Brain.name).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !ranWith.isEmpty { Text(ranWith).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(2) }
            ScrollView {
                Text(output.isEmpty ? (running ? "" : "Output appears here.") : output)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(failed ? Color.red : output.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(height: 260)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            .overlay { if running { ProgressView() } }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private var claudeAvailable: Bool { if case .found = model.claudeAvailability { return true } else { return false } }

    private func runCLI() {
        running = true
        output = ""
        ranWith = "kb sources test \(source.id)" + (project.map { " --project \($0)" } ?? "") + " --query \"\(query)\""
        let cli = model.cli
        Task {
            let r = await cli.testSource(source.id, project: project, query: query)
            failed = r.status != 0
            output = [r.stdout, r.stderr].filter { !$0.isEmpty }.joined(separator: "\n--- stderr ---\n")
            if output.isEmpty { output = "(exit \(r.status), no output)" }
            running = false
        }
    }

    private func runClaude() {
        guard case .found(let exe) = model.claudeAvailability else { return }
        running = true
        output = ""
        let prompt = "Using only the knowledge source `\(source.id)` (\(source.sourceKind?.title ?? source.kind): \(source.title); config: \(source.config.map { "\($0.key)=\($0.value.display)" }.sorted().joined(separator: ", "))), find one result for: \(query). Reply with the result's title, where it is (URL, path or id), and one line of what it says. If you cannot reach the source, say exactly why."
        let tools = AskTools.allowedTools(sources: [source])
        let args = ClaudeOneShot.arguments(prompt: prompt, pluginRoot: model.pluginRootPath, model: model.defaultModel, allowedTools: tools)
        ranWith = "claude -p … (only \(source.id))"
        let env = model.claudeEnvironment()
        let cwd = ClaudeLaunch.workingDirectory(project: project.flatMap { model.index.project($0) }, root: model.rootURL)
        Task {
            let r = await ProcessRunner().run(executable: exe, arguments: args, environment: env, stdin: nil, currentDirectory: cwd)
            failed = r.status != 0
            output = r.status == 0 ? r.stdout : [r.stdout, r.stderr].joined(separator: "\n")
            running = false
        }
    }
}

// MARK: App settings

private func pluginStatus(_ l: (path: String, source: PluginLocation.Source)) -> String {
    switch l.source {
    case .chosen: return "Using \(KBConfig.abbreviateTilde(KBConfig.expandTilde(l.path)))"
    case .bundled: return "Using the plugin inside Mindmill"
    case .development: return "Using the checkout at \(l.path)"
    case .missing: return "No scripts/kb.py found. Reinstall Mindmill, or choose a folder that has it."
    }
}

struct ClaudeSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettingsKeys.pluginRoot) private var pluginRoot = ""

    var body: some View {
        let location = model.pluginLocation
        Form {
            Section {
                TextField("Plugin folder", text: $pluginRoot, prompt: Text("The one inside Mindmill"))
                    .font(.body.monospaced())
                Label(pluginStatus(location), systemImage: location.source == .missing ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(location.source == .missing ? .orange : .green)
                    .font(.callout)
            } header: {
                Text("Plugin")
            } footer: {
                Text("Mindmill comes with its plugin. Choose a folder only to run your own copy, such as a checkout you edit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                BrainPicker()
            } header: {
                Text("The brain")
            } footer: {
                Text("Mindmill works through the brain: sessions, questions, meetings and the background work. Buttons and menus use its name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TaskAssignments()
            } header: {
                Text("For specific tasks")
            } footer: {
                Text("Give a task another model when it does better there: a fast one for live meetings, a small one for calendar sync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                SkillPlacesView()
            } header: {
                Text("Mindmill's skills")
            } footer: {
                Text("Each assistant reads skills from its own place. Mindmill puts its skills where the assistants you use read them, and moves them when you change the brain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("\(model.aiSetup.brainProvider.command) command") {
                switch model.claudeAvailability {
                case .resolving: Label("Looking for claude…", systemImage: "hourglass")
                case .found(let url): Label(url.path, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .missing: Label(model.claudeMissingExplanation, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct GlobalSourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var sources: [KnowledgeSource] = []
    @State private var loaded: [KnowledgeSource] = []

    var body: some View {
        VStack(spacing: 0) {
            SourcesEditor(sources: $sources, project: nil, scopeLabel: "every scope")
            HStack {
                Text("\(KBConfig.abbreviateTilde(GlobalSources.url(root: model.rootURL).path))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { sources = loaded }.disabled(sources == loaded)
                Button("Save") {
                    do {
                        try GlobalSources.save(sources, root: model.rootURL)
                        loaded = sources
                    } catch {
                        model.errorMessage = "Could not write sources.json: \(error.localizedDescription)"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sources == loaded)
            }
            .padding(12)
        }
        .frame(width: 620, height: 480)
        .onAppear {
            loaded = GlobalSources.load(root: model.rootURL)
            sources = loaded
        }
    }
}
