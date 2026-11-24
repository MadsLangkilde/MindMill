import AppKit
import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    @discardableResult
    func saveProjects(_ drafts: [ProjectDraft]) async throws -> [(project: String, scopes: [String])] {
        try await engine.saveProjects(drafts)
    }

    func remoteProjectsChanged() { engine.projectsChanged() }

    /// Opens a new project's first scope that works in a location, and its scan form when asked.
    func openNewProject(_ made: (project: String, scopes: [String]), scan: Bool) {
        let scopes = made.scopes.compactMap { index.project($0) }
        let located = scopes.filter { !$0.wide && !$0.paths.isEmpty }
        guard let first = located.first ?? scopes.first else { return }
        selectProject(first.id)
        selectSidebar(.project)
        projectPane = scan && !located.isEmpty ? .newScan(located.map(\.id)) : .home
    }
}

/// Every project with its locations and scopes, to set up a new one or change one. Opened for a new project, for a
/// project (optionally adding a location right away), or on the current one.
struct ProjectsSheet: View {
    enum Start: Equatable {
        case current
        case new
        case project(String, addLocation: Bool)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let start: Start
    @State private var registry = Registry()
    @State private var drafts: [String: ProjectDraft] = [:]
    @State private var originals: [String: ProjectDraft] = [:]
    @State private var order: [String] = []
    @State private var selection: String?
    @State private var scanAfter = true
    @State private var saving = false
    @State private var error: String?
    @State private var confirmCancel = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                projectList.frame(width: 230)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 520, idealHeight: 680)
        .onAppear(perform: load)
        .confirmationDialog("Discard your changes to projects?", isPresented: $confirmCancel) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private var changed: [String] { order.filter { drafts[$0] != originals[$0] } }

    private var projectList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Projects") {
                    ForEach(order, id: \.self) { key in
                        if let d = drafts[key] {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(d.title.isEmpty ? "New project" : d.title)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(d.title.isEmpty ? .secondary : .primary)
                                    if drafts[key] != originals[key] {
                                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("Changed, not saved yet")
                                    }
                                }
                                Text(summary(d)).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(key)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Button {
                addProject()
            } label: {
                Label("New Project", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
    }

    private func summary(_ d: ProjectDraft) -> String {
        let l = d.locations.count
        let s = d.scopes.count
        return "\(l) location\(l == 1 ? "" : "s") · \(s) scope\(s == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var detail: some View {
        if let key = selection, drafts[key] != nil {
            ProjectEditor(draft: Binding(get: { drafts[key] ?? ProjectDraft() }, set: { drafts[key] = $0 }),
                          registry: registry, scanAfter: $scanAfter)
                .id(key)
        } else {
            ListEmptyState(title: "Projects", systemImage: "square.stack.3d.up",
                           message: "A project, such as Acme App, has locations (the folders its code is in) and scopes: one project-wide, and one per app or part, such as Android or iOS.") {
                Button("New Project") { addProject() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var footer: some View {
        let problem = selection.flatMap { drafts[$0] }.flatMap { $0.problem(in: registry) }
            ?? changed.lazy.compactMap { k in drafts[k]?.problem(in: registry).map { "\(drafts[k]?.title ?? ""): \($0)" } }.first
        return HStack(alignment: .center, spacing: 10) {
            if let message = error ?? problem {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if saving { ProgressView().controlSize(.small) }
            Button("Cancel") {
                if changed.isEmpty { dismiss() } else { confirmCancel = true }
            }
            .keyboardShortcut(.cancelAction)
            Button(saveTitle) { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(changed.isEmpty || saving || changed.contains { drafts[$0]?.problem(in: registry) != nil })
        }
        .padding(12)
    }

    private var saveTitle: String {
        let c = changed
        if c.count == 1, drafts[c[0]]?.isNew == true { return "Add Project" }
        return "Save"
    }

    private func addProject() {
        let key = "new:\(UUID().uuidString)"
        drafts[key] = ProjectDraft()
        order.append(key)
        selection = key
    }

    private func load() {
        do {
            registry = try Registry.load(KBLayout.home(root: model.rootURL).appendingPathComponent("kb.json"))
        } catch {
            registry = Registry()
        }
        for p in registry.projects {
            guard let d = ProjectDraft(project: p.id, registry: registry) else { continue }
            drafts[p.id] = d
            originals[p.id] = d
            order.append(p.id)
        }
        switch start {
        case .new:
            addProject()
        case .project(let id, let addLocation):
            selection = drafts[id] != nil ? id : order.first
            if addLocation, let id = selection {
                DispatchQueue.main.async {
                    let urls = model.chooseFolders(message: "Choose folders to add to \(drafts[id]?.title ?? "the project")", multiple: true)
                    for url in urls { drafts[id]?.addLocation(path: url.path, name: ProjectEditor.name(for: url), withScope: true) }
                }
            }
        case .current:
            selection = model.selectedGroup?.id ?? order.first
            if order.isEmpty { addProject() }
        }
    }

    private func save() {
        let keys = changed
        let list = keys.compactMap { drafts[$0] }
        let newOnes = list.filter(\.isNew).count
        saving = true
        error = nil
        Task {
            do {
                let made = try await model.saveProjects(list)
                saving = false
                dismiss()
                if newOnes == 1, let last = made.last, list.last?.isNew == true {
                    model.openNewProject(last, scan: scanAfter)
                } else {
                    model.notice = "Saved \(list.count == 1 ? list[0].title : "\(list.count) projects")."
                }
            } catch {
                saving = false
                self.error = error.localizedDescription
                if let r = try? Registry.load(KBLayout.home(root: model.rootURL).appendingPathComponent("kb.json")) { registry = r }
            }
        }
    }
}

/// One project: its name, its locations and its scopes.
struct ProjectEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: ProjectDraft
    let registry: Registry
    @Binding var scanAfter: Bool
    @State private var scopePerLocation = true

    static func name(for url: URL) -> String {
        let n = url.lastPathComponent
        return n.prefix(1).uppercased() + n.dropFirst()
    }

    var body: some View {
        Form {
            projectSection
            locationsSection
            scopesSection
            if !draft.removed.isEmpty { removedSection }
            if draft.isNew {
                Section {
                    Toggle("Scan the locations for knowledge next", isOn: $scanAfter)
                } footer: {
                    Text("Opens the scan form after saving. You pick what to look for, and tick what goes into the knowledge base.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
    }

    // MARK: Project

    private var projectSection: some View {
        Section {
            TextField("Name", text: Binding(get: { draft.title }, set: { draft.setTitle($0, in: registry) }), prompt: Text("e.g. Acme App"))
            if draft.isNew {
                TextField("Id", text: Binding(get: { draft.newID }, set: { draft.setID($0) }), prompt: Text("made from the name"))
                    .font(.body.monospaced())
                    .help("The project's id in the knowledge base. It can't change later.")
            } else {
                LabeledContent("Id") { Text(draft.id).font(.body.monospaced()).textSelection(.enabled) }
            }
        } header: {
            Text(draft.isNew ? "New project" : "Project")
        }
    }

    // MARK: Locations

    private var locationsSection: some View {
        Section {
            if draft.locations.isEmpty {
                Text(draft.isNew ? "Choose at least one folder the project's code is in." : "No locations yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.locations) { loc in
                LocationRow(location: loc,
                            name: Binding(get: { draft.locations.first { $0.id == loc.id }?.name ?? "" },
                                          set: { draft.renameLocation(loc.id, to: $0) }),
                            change: {
                                if let url = model.chooseFolders(message: "Where is \(loc.name)?", multiple: false).first {
                                    draft.moveLocation(loc.id, to: url.path)
                                }
                            },
                            remove: { draft.removeLocation(loc.id) })
            }
            ChipRow(spacing: 10) {
                Button {
                    for url in model.chooseFolders(message: "Choose the folders \(draft.title.isEmpty ? "the project" : draft.title)'s code is in", multiple: true) {
                        draft.addLocation(path: url.path, name: Self.name(for: url), withScope: scopePerLocation)
                    }
                } label: {
                    Label(draft.locations.isEmpty ? "Choose Folders…" : "Add Location…", systemImage: "folder.badge.plus")
                }
                Toggle("Give each new location its own scope", isOn: $scopePerLocation)
                    .toggleStyle(.checkbox)
            }
        } header: {
            Text("Locations")
        } footer: {
            Text("The folders on this Mac the project's code is in, usually its repositories. A session started in a location works in the scopes that work there, and a location's knowledgebase/ folder shows in Mindmill right away.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Scopes

    @ViewBuilder
    private var scopesSection: some View {
        ForEach(draft.scopes) { s in
            ScopeEditor(scope: Binding(get: { draft.scopes.first { $0.id == s.id } ?? s },
                                       set: { new in if let i = draft.scopes.firstIndex(where: { $0.id == s.id }) { draft.scopes[i] = new } }),
                        draft: $draft, registry: registry, entries: entries(of: s))
        }
        Section {
            Button {
                draft.addScope()
            } label: {
                Label("Add Scope", systemImage: "plus")
            }
        } footer: {
            Text("Scopes divide the project's knowledge and work: one project-wide scope that shows everything, and one per app or part, such as Android, iOS or a Mobile scope working on both.")
                .foregroundStyle(.secondary)
        }
    }

    private func entries(of s: ProjectDraft.Scope) -> Int {
        guard let id = s.existing else { return 0 }
        return model.index.entries.values.filter { $0.project == id }.count
    }

    private var removedSection: some View {
        Section("Deleted on Save") {
            ForEach(draft.removedTitles, id: \.id) { r in
                AdaptiveCardLayout(spacing: 10, minInfoWidth: 200) {
                    Image(systemName: "trash").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).strikethrough()
                        let n = model.index.entries.values.filter { $0.project == r.id }.count
                        Text(n == 0 ? "No entries live in it." : "Its \(n) entries move to \(r.moveTo).")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Keep") { draft.restoreScope(r.id) }
                }
            }
        }
    }
}

private struct LocationRow: View {
    let location: ProjectDraft.Location
    @Binding var name: String
    let change: () -> Void
    let remove: () -> Void

    var body: some View {
        let repo = ScopeRepo.of(paths: [location.path])
        let expanded = (location.path as NSString).expandingTildeInPath
        let exists = FileManager.default.fileExists(atPath: expanded)
        AdaptiveCardLayout(spacing: 10, minInfoWidth: 220) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $name, prompt: Text("e.g. Android app"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Text(location.path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ChipRow(spacing: 6) {
                    if !exists {
                        Chip(text: "Not on this Mac", color: .orange, systemImage: "exclamationmark.triangle")
                    } else if !ScopeRepo.isRepository(URL(fileURLWithPath: expanded)) {
                        Chip(text: "Not a git repository", color: .secondary, systemImage: "folder")
                    }
                    if repo.hasTeamFolder {
                        Chip(text: "knowledgebase/ · \(repo.teamEntries) entries", color: .green, systemImage: "checkmark.circle.fill")
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Change…", action: change)
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove this location. Its folder stays where it is.")
            }
        }
        .padding(.vertical, 2)
    }
}

/// One scope of the project being edited.
private struct ScopeEditor: View {
    @Binding var scope: ProjectDraft.Scope
    @Binding var draft: ProjectDraft
    let registry: Registry
    let entries: Int

    var body: some View {
        let others = draft.scopes.filter { $0.id != scope.id && !$0.wide }
        let elsewhere = registry.scopes.filter { $0.project != draft.existing }
        Section {
            TextField("Title", text: $scope.title, prompt: Text(scope.wide ? "Overview" : "e.g. Android"))
            if scope.existing == nil {
                TextField("Id", text: $scope.newID, prompt: Text("made from the title"))
                    .font(.body.monospaced())
                    .help("The scope's folder id. It can't change later.")
            }
            if scope.wide {
                LabeledContent("Works in", value: "Everything in \(draft.title.isEmpty ? "the project" : draft.title)")
            } else {
                LabeledContent("Works in") {
                    if draft.locations.isEmpty {
                        Text("Add a location first").foregroundStyle(.secondary)
                    } else {
                        ChipRow(spacing: 6) {
                            ForEach(draft.locations) { loc in
                                ToggleChip(title: loc.name.isEmpty ? (loc.path as NSString).lastPathComponent : loc.name,
                                           isOn: Binding(get: { scope.paths.contains(loc.path) },
                                                         set: { on in
                                                             scope.paths.removeAll { $0 == loc.path }
                                                             if on { scope.paths.append(loc.path) }
                                                         }))
                            }
                        }
                    }
                }
                if !others.isEmpty {
                    LabeledContent("Also shows") {
                        VStack(alignment: .leading, spacing: 4) {
                            ChipRow(spacing: 6) {
                                ForEach(others) { o in
                                    ToggleChip(title: o.title.isEmpty ? "Untitled" : o.title,
                                               isOn: Binding(get: { scope.includes.contains(o.id) },
                                                             set: { on in
                                                                 scope.includes.removeAll { $0 == o.id }
                                                                 if on { scope.includes.append(o.id) }
                                                             }))
                                }
                            }
                            Text("Worked on together: its sessions can change these scopes' code, and their entries and work items show here too.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !elsewhere.isEmpty {
                LabeledContent("Knowledge from") {
                    VStack(alignment: .leading, spacing: 4) {
                        ChipRow(spacing: 6) {
                            ForEach(elsewhere) { o in
                                let project = registry.projects.first { $0.id == o.project }?.title ?? o.project
                                ToggleChip(title: "\(o.title) · \(project)",
                                           isOn: Binding(get: { scope.related.contains(o.id) },
                                                         set: { on in
                                                             scope.related.removeAll { $0 == o.id }
                                                             if on { scope.related.append(o.id) }
                                                         }))
                            }
                        }
                        Label("Read only: sessions learn from their code and knowledge, but never change it.", systemImage: "eye")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            TextField("Git remotes", text: $scope.remotes, prompt: Text("_git/app: part of the origin URL, comma separated"))
                .help("Finds the scope for a clone of its repository somewhere else on the Mac.")
            if !scope.wide {
                ChipRow(spacing: 10) {
                    Button("Make Project-Wide") { draft.makeWide(scope.id) }
                        .help("The project-wide scope shows everything in the project.")
                    Button("Remove Scope", role: .destructive) { draft.removeScope(scope.id) }
                        .help(scope.existing == nil ? "Remove this new scope"
                              : entries == 0 ? "Delete this scope on Save" : "Delete this scope on Save. Its \(entries) entries move to the project-wide scope.")
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text(scope.title.isEmpty ? "New scope" : scope.title)
                if scope.wide { Chip(text: "Project-wide", color: .accentColor) }
                if scope.existing == nil { Chip(text: "New", color: .green) }
                Spacer()
                if let id = scope.existing { Text(id).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
        }
    }
}

/// A pill that is on or off, for picking several things in a wrapping row.
struct ToggleChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                Text(title)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(isOn ? Color.accentColor : .primary)
            .background(isOn ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
