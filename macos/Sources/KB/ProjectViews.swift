import KBCore
import KBEngine
import SwiftUI

// MARK: Content column

/// Plan → Project: the project's repositories, the knowledge already in them, and scans.
struct ProjectColumn: View {
    @Environment(AppModel.self) private var model
    let project: KBProject

    var body: some View {
        let group = model.index.group(of: project.id)
        let scans = group.map { model.scans(group: $0.id) } ?? []
        List(selection: Binding(get: { selection }, set: { pick($0) })) {
            Section {
                ForEach(group.map { model.repoScopes(group: $0.id) } ?? []) { scope in
                    RepositoryRow(scope: scope)
                }
                Button { model.addProjectRequest = AddProjectRequest(project: group?.id) } label: {
                    Label("Add Locations…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Repositories")
            }
            Section {
                Label("New Scan…", systemImage: "sparkle.magnifyingglass")
                    .foregroundStyle(Color.accentColor)
                    .tag("new")
                ForEach(scans) { run in
                    ScanRunRow(run: run).tag(run.id)
                        .contextMenu {
                            if model.isScanning(run.id) {
                                Button("Stop Scan") { model.stopScan(run.id) }
                            } else {
                                Button("Delete Scan", role: .destructive) { model.deleteScan(run.id) }
                            }
                        }
                }
            } header: {
                Text("Scans")
            } footer: {
                if scans.isEmpty {
                    Text("A scan reads a repository (docs, code, comments, history, work items) and lists what it finds. You tick what goes into the knowledge base.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .navigationSubtitle("Project")
        .onAppear { model.loadScansIfNeeded() }
    }

    private var selection: String? {
        switch model.projectPane {
        case .home: return nil
        case .newScan: return "new"
        case .run(let id): return id
        }
    }

    private func pick(_ tag: String?) {
        switch tag {
        case nil: model.projectPane = .home
        case "new":
            if case .newScan = model.projectPane { return }
            model.projectPane = .newScan(project.wide ? [] : [project.id])
        case let id?: model.projectPane = .run(id)
        }
    }
}

private struct RepositoryRow: View {
    @Environment(AppModel.self) private var model
    let scope: KBProject

    var body: some View {
        let repo = ScopeRepo.of(paths: scope.paths)
        VStack(alignment: .leading, spacing: 4) {
            Text(scope.title).font(.headline).lineLimit(2)
            if let dir = repo.checkout {
                Text(dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            ChipRow(spacing: 6) {
                if repo.checkout == nil {
                    Chip(text: scope.paths.isEmpty ? "No repository" : "Not on this Mac", color: .orange, systemImage: "questionmark.folder")
                } else if repo.hasTeamFolder {
                    Chip(text: "knowledgebase/ · \(repo.teamEntries) entr\(repo.teamEntries == 1 ? "y" : "ies")", color: .green,
                         systemImage: "checkmark.circle.fill")
                        .help("The team's knowledge in the repository. It is in the knowledge base already.")
                } else {
                    Chip(text: "No knowledgebase/ yet", color: .secondary, systemImage: "folder")
                        .help("Made when the first team entry is added, such as from a scan.")
                }
                if repo.checkout == nil {
                    Button("Locate…") { model.locateScope(scope.id) }
                        .controlSize(.small)
                        .help("Point \(scope.title) at its checkout on this Mac")
                } else {
                    Button("Scan…") { model.projectPane = .newScan([scope.id]) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ScanRunRow: View {
    @Environment(AppModel.self) private var model
    let run: ScanRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.index.project(run.scope)?.title ?? run.scope).font(.headline).lineLimit(1)
            Text(run.kinds.count == ScanKind.allCases.count ? "Everything" : run.kinds.map(\.title).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ChipRow(spacing: 6) {
                ScanStatePill(run: run)
                if let d = run.started {
                    Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct ScanStatePill: View {
    @Environment(AppModel.self) private var model
    let run: ScanRun

    var body: some View {
        let pending = run.pending.count
        if model.isScanning(run.id) {
            Chip(text: "Scanning · \(run.findings.count) found", color: .blue, systemImage: "sparkle.magnifyingglass")
        } else if !run.isFinished {
            Chip(text: "Interrupted", color: .orange, systemImage: "pause.circle")
        } else if pending > 0 {
            Chip(text: "\(pending) to review", color: .orange, systemImage: "checklist")
        } else if run.failed {
            Chip(text: "Stopped", color: .red, systemImage: "exclamationmark.triangle")
        } else {
            Chip(text: run.findings.isEmpty ? "Nothing new" : "Reviewed · \(run.appliedCount) added", color: .green,
                 systemImage: "checkmark.circle")
        }
    }
}

// MARK: Detail

struct ProjectDetail: View {
    @Environment(AppModel.self) private var model
    let project: KBProject

    var body: some View {
        switch model.projectPane {
        case .home:
            ProjectHome(project: project)
        case .newScan(let preset):
            ScanSetupView(project: project, preset: preset).id(preset)
        case .run(let id):
            if let run = model.scan(id) {
                ScanReviewView(run: run).id(id)
            } else {
                ListEmptyState(title: "Scan Not Found", systemImage: "sparkle.magnifyingglass")
            }
        }
    }
}

private struct ProjectHome: View {
    @Environment(AppModel.self) private var model
    let project: KBProject

    var body: some View {
        let group = model.index.group(of: project.id)
        let repos = group.map { model.repoScopes(group: $0.id) } ?? []
        let missing = repos.filter { ScopeRepo.of(paths: $0.paths).checkout == nil && !$0.paths.isEmpty }
        let pending = (group.map { model.scans(group: $0.id) } ?? []).filter { !$0.pending.isEmpty }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(group?.title ?? project.title).font(.title2.weight(.semibold))
                    Text("Bring knowledge in from the project's repositories: facts, decisions, architecture, open questions and more. A scan lists what it finds; only what you tick goes into the knowledge base.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ChipRow(spacing: 8) {
                    Button { model.projectPane = .newScan(project.wide ? [] : [project.id]) } label: {
                        Label("New Scan…", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { model.addProjectRequest = AddProjectRequest(project: group?.id) } label: {
                        Label("Add Locations…", systemImage: "plus")
                    }
                    Button { model.addProjectRequest = AddProjectRequest() } label: {
                        Label("New Project…", systemImage: "folder.badge.plus")
                    }
                }
                ScopeRepositoriesCard(scope: project)
                if !missing.isEmpty {
                    ProjectCard(title: "Not on this Mac yet", systemImage: "questionmark.folder", color: .orange,
                                note: "Point each at its checkout. Team knowledge in a repository's knowledgebase/ folder shows up as soon as it is found.") {
                        ForEach(missing) { s in
                            AdaptiveCardLayout(spacing: 10, minInfoWidth: 160) {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.headline)
                                    Text(s.paths.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .lineLimit(2).truncationMode(.middle)
                                }
                                Button("Locate…") { model.locateScope(s.id) }
                            }
                        }
                    }
                }
                if !pending.isEmpty {
                    ProjectCard(title: "Waiting for your review", systemImage: "checklist", color: .orange, note: nil) {
                        ForEach(pending) { run in
                            AdaptiveCardLayout(spacing: 10, minInfoWidth: 160) {
                                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.index.project(run.scope)?.title ?? run.scope).font(.headline)
                                    Text("\(run.pending.count) found, not reviewed yet").font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Review") { model.projectPane = .run(run.id) }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProjectCard<Content: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    let note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline).foregroundStyle(color)
            if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: New scan

struct ScanSetupView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    let preset: [String]
    @State private var scopes: Set<String> = []
    @State private var kinds = Set(ScanKind.allCases)
    @State private var sources = Set(ScanSource.allCases)
    @State private var focus = ""
    @State private var loaded = false

    var body: some View {
        let group = model.index.group(of: project.id)
        let repos = group.map { model.repoScopes(group: $0.id) } ?? []
        VStack(spacing: 0) {
            Form {
                Section {
                    if repos.isEmpty {
                        Text("No repositories yet. Add one first.").foregroundStyle(.secondary)
                    }
                    ForEach(repos) { s in
                        let repo = ScopeRepo.of(paths: s.paths)
                        HStack {
                            Toggle(isOn: binding(s.id, in: $scopes)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.title)
                                    Text(repo.checkout == nil ? "Not on this Mac"
                                         : repo.hasTeamFolder ? "Has knowledgebase/ with \(repo.teamEntries) entries" : "No knowledgebase/ yet")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(repo.checkout == nil)
                            if repo.checkout == nil {
                                Spacer()
                                Button("Locate…") { model.locateScope(s.id) }
                            }
                        }
                    }
                } header: {
                    Text("Repositories to scan")
                } footer: {
                    Text("Each repository is scanned by its own session, side by side.").foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Everything", isOn: Binding(get: { kinds.count == ScanKind.allCases.count },
                                                       set: { kinds = $0 ? Set(ScanKind.allCases) : [] }))
                        .fontWeight(.semibold)
                    ForEach(ScanKind.allCases) { k in
                        Toggle(isOn: binding(k, in: $kinds)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Label(k.title, systemImage: k.icon)
                                Text(k.help).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("What to look for")
                }
                Section {
                    ForEach(ScanSource.allCases) { src in
                        Toggle(isOn: binding(src, in: $sources)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(src.title)
                                Text(src.help).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Where to look")
                }
                Section {
                    TextField("Focus", text: $focus, prompt: Text("Optional, e.g. “the Bluetooth layer” or “how releases are made”"), axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text("Focus")
                }
            }
            .formStyle(.grouped)
            .multilineTextAlignment(.leading)
            Divider()
            HStack(spacing: 10) {
                Text(problem ?? "Nothing goes into the knowledge base until you tick it.")
                    .font(.callout)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Start Scan") {
                    model.startScans(scopes: repos.map(\.id).filter { scopes.contains($0) },
                                     kinds: ScanKind.allCases.filter { kinds.contains($0) },
                                     sources: ScanSource.allCases.filter { sources.contains($0) }, focus: focus)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let withRepo = repos.filter { ScopeRepo.of(paths: $0.paths).checkout != nil }.map(\.id)
            scopes = Set(preset.isEmpty ? withRepo : preset.filter(withRepo.contains))
        }
    }

    private var problem: String? {
        if scopes.isEmpty { return "Tick a repository." }
        if kinds.isEmpty { return "Tick something to look for." }
        if sources.isEmpty { return "Tick somewhere to look." }
        return nil
    }

    private func binding<T: Hashable>(_ value: T, in set: Binding<Set<T>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(value) },
                set: { on in if on { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } })
    }
}

// MARK: Review

struct ScanReviewView: View {
    @Environment(AppModel.self) private var model
    let run: ScanRun
    @State private var selected: Set<String> = []
    @State private var filter: ScanFinding.Status = .pending
    @State private var expanded: Set<String> = []

    var body: some View {
        let shown = run.findings.filter { $0.status == filter }
        let groups = run.grouped(shown)
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Show", selection: $filter) {
                Text("To Review · \(run.pending.count)").tag(ScanFinding.Status.pending)
                Text("Added · \(run.appliedCount)").tag(ScanFinding.Status.applied)
                Text("Dismissed · \(run.findings.filter { $0.status == .dismissed }.count)").tag(ScanFinding.Status.dismissed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if shown.isEmpty {
                ListEmptyState(title: emptyTitle, systemImage: filter == .pending ? "checklist" : "tray",
                               message: emptyMessage)
            } else {
                List {
                    ForEach(groups, id: \.kind) { g in
                        Section {
                            ForEach(g.findings) { f in
                                FindingRow(finding: f, run: run, selected: binding(f.id), expanded: expandedBinding(f.id))
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Label(g.kind.title, systemImage: g.kind.icon)
                                Text("\(g.findings.count)").monospacedDigit().foregroundStyle(.secondary)
                                Spacer()
                                if filter == .pending {
                                    let ids = Set(g.findings.map(\.id))
                                    Button(ids.isSubset(of: selected) ? "Untick All" : "Tick All") {
                                        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            if filter == .pending, !run.pending.isEmpty {
                Divider()
                footer
            }
        }
        .onChange(of: run.pending.map(\.id)) { _, ids in selected.formIntersection(ids) }
    }

    private var emptyTitle: String {
        switch filter {
        case .pending: return model.isScanning(run.id) ? "Nothing found yet" : "All reviewed"
        case .applied: return "Nothing added yet"
        case .dismissed: return "Nothing dismissed"
        }
    }

    private var emptyMessage: String? {
        guard filter == .pending else { return nil }
        return model.isScanning(run.id) ? "Findings show up here as the scan records them." : nil
    }

    private var header: some View {
        let title = model.index.project(run.scope)?.title ?? run.scope
        return VStack(alignment: .leading, spacing: 6) {
            AdaptiveCardLayout(spacing: 10, minInfoWidth: 180) {
                Image(systemName: "sparkle.magnifyingglass").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan of \(title)").font(.title3.weight(.semibold))
                    Text(run.kinds.count == ScanKind.allCases.count ? "Everything" : run.kinds.map(\.title).joined(separator: ", "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.isScanning(run.id) {
                    Button("Stop") { model.stopScan(run.id) }
                } else {
                    Menu {
                        Button("Scan Again…") { model.projectPane = .newScan([run.scope]) }
                        Divider()
                        Button("Delete Scan", role: .destructive) { model.deleteScan(run.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            ChipRow(spacing: 6) {
                ScanStatePill(run: run)
                if !run.focus.isEmpty { Chip(text: "Focus: \(run.focus)", color: .secondary, systemImage: "scope") }
                ForEach(run.sources) { Text($0.title).font(.caption).foregroundStyle(.secondary) }
            }
            if model.isScanning(run.id) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text([run.progress.last, model.scanActivity[run.id]].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            } else if !run.note.isEmpty {
                Text(run.note).font(.callout).foregroundStyle(run.failed ? Color.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        let busy = !model.scanApplying.isDisjoint(with: selected)
        return HStack(spacing: 10) {
            Button(selected.count == run.pending.count ? "Untick All" : "Tick All") {
                selected = selected.count == run.pending.count ? [] : Set(run.pending.map(\.id))
            }
            Text("\(selected.count) of \(run.pending.count) ticked").font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).layoutPriority(-1)
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            Button("Dismiss") {
                model.dismissFindings(run: run.id, ids: ordered(selected))
                selected = []
            }
            .disabled(selected.isEmpty || busy)
            .help("Leave the ticked ones out of the knowledge base")
            Button("Add \(selected.count) to the Knowledge Base") {
                model.applyFindings(run: run.id, ids: ordered(selected))
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty || busy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func ordered(_ ids: Set<String>) -> [String] { run.findings.map(\.id).filter(ids.contains) }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
}

private struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let finding: ScanFinding
    let run: ScanRun
    @Binding var selected: Bool
    @Binding var expanded: Bool

    var body: some View {
        let f = finding
        HStack(alignment: .top, spacing: 8) {
            if f.status == .pending {
                Toggle("", isOn: $selected).toggleStyle(.checkbox).labelsHidden().padding(.top, 1)
            } else {
                Image(systemName: f.status == .applied ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundStyle(f.status == .applied ? Color.green : .secondary)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(f.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if !f.summary.isEmpty {
                        Text(f.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if f.status == .pending { selected.toggle() } }
                ChipRow(spacing: 6) {
                    if !f.updates.isEmpty {
                        let old = EntryID(f.updates).flatMap { model.index.entry($0) }?.title ?? f.updates
                        Chip(text: "Updates “\(old)”", color: .purple, systemImage: "arrow.triangle.2.circlepath")
                    }
                    if f.scope != run.scope {
                        Chip(text: model.index.project(f.scope)?.title ?? f.scope, color: .secondary, systemImage: "folder")
                    }
                    ForEach(f.scopes.filter { $0 != f.scope }, id: \.self) { s in
                        Chip(text: model.index.project(s)?.title ?? s, color: .secondary)
                    }
                    if f.confidence == "low" { Chip(text: "Unsure", color: .orange, systemImage: "questionmark.circle") }
                    if !f.date.isEmpty { Text(DateText.display(f.date)).font(.caption).foregroundStyle(.secondary) }
                    if !f.source.isEmpty {
                        Text(f.source).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                }
                if !f.body.isEmpty || f.kind == .docs {
                    DisclosureGroup(isExpanded: $expanded) {
                        Text(f.kind == .docs ? f.path : f.body)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    } label: {
                        Text(expanded ? "Hide details" : "Show details").font(.caption)
                    }
                }
                if f.status == .applied, !f.entry.isEmpty {
                    Button("Open in Mindmill") { model.openFinding(f) }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Sidebar

struct ProjectSidebarRow: View {
    @Environment(AppModel.self) private var model
    let project: KBProject

    var body: some View {
        let group = model.index.group(of: project.id)
        let pending = group.map { model.pendingFindings(group: $0.id) } ?? 0
        let scanning = model.scans.contains { model.isScanning($0.id) }
        SidebarLabel(title: "Project", systemImage: scanning ? "sparkle.magnifyingglass" : "shippingbox", item: .project)
            .badge(pending > 0 ? Text("\(pending)").foregroundStyle(.white).bold() : nil)
            .badgeProminence(pending > 0 ? .increased : .standard)
            .tag(SidebarItem.project)
            .help("Repositories, the knowledge in them, and scans for more")
            .onAppear { model.loadScansIfNeeded() }
    }
}

/// The repositories the selected scope works on and the ones it only takes knowledge from, each with its branch,
/// how far behind it is, and Pull.
private struct ScopeRepositoriesCard: View {
    @Environment(AppModel.self) private var model
    let scope: KBProject

    var body: some View {
        let repos = model.repositories(of: scope.id)
        if !repos.all.isEmpty {
            ProjectCard(title: "Repositories of \(scope.title)", systemImage: "arrow.triangle.branch", color: .primary,
                        note: "Pull fast-forwards a repository to its remote branch. It never merges or overwrites your changes; when it can't, it says why.") {
                ChipRow(spacing: 8) {
                    Button { model.pullRepos(scope: scope.id) } label: {
                        Label("Pull All", systemImage: "arrow.down.circle")
                    }
                    .disabled(!model.reposPulling.isEmpty || repos.all.allSatisfy { $0.checkout == nil })
                    Button { model.loadRepoStates(scope: scope.id, fetch: true) } label: {
                        Label("Check Remotes", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.reposLoading)
                    if model.reposLoading { ProgressView().controlSize(.small) }
                    Button("Edit Scope…") { model.scopesSheet = true }
                }
                if !repos.work.isEmpty {
                    RepoGroup(title: "Works on", scope: scope.id, repos: repos.work)
                }
                if !repos.reference.isEmpty {
                    RepoGroup(title: "Knowledge only · read, never changed", scope: scope.id, repos: repos.reference)
                }
            }
            .task(id: scope.id) { model.loadRepoStates(scope: scope.id, fetch: true) }
        }
    }
}

private struct RepoGroup: View {
    @Environment(AppModel.self) private var model
    let title: String
    let scope: String
    let repos: [ScopeRepositories.Repo]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(repos) { r in
                AdaptiveCardLayout(spacing: 10, minInfoWidth: 160) {
                    Image(systemName: r.reference ? "eye" : "hammer").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).font(.headline)
                        Text((r.checkout?.path ?? r.configured).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if r.checkout == nil {
                            Text("Not on this Mac").font(.caption).foregroundStyle(.orange)
                        } else if let st = model.repoStates[r.scope] {
                            Text(st.summary).font(.caption).foregroundStyle(st.behind > 0 ? .orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 6) {
                        if r.checkout == nil {
                            Button("Locate…") { model.locateScope(r.scope) }
                        } else if model.reposPulling.contains(r.scope) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Pull") { model.pullRepos(scope: scope, only: r.scope) }
                                .disabled(model.repoStates[r.scope].map { !$0.canPull } ?? false)
                                .help(model.repoStates[r.scope].map { $0.canPull ? "Fast-forward to \($0.upstream ?? "the remote")" : ($0.git ? "\($0.branch ?? "This branch") has no remote branch" : "Not a git repository") } ?? "Pull the latest")
                        }
                    }
                }
            }
        }
    }
}
