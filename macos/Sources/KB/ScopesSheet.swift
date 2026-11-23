import KBCore
import SwiftUI

/// Projects and their scopes: add a project, add a scope, rename, set where a scope's code lives.
struct ScopesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var registry = Registry()
    @State private var original = Registry()
    @State private var selection: String?
    @State private var error: String?
    /// Existing scopes to delete on Save, each with where its entries go.
    @State private var deletions: [String: String] = [:]
    @State private var confirmDelete: String?
    @State private var deleteTarget = ""
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                list.frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
                detail.frame(minWidth: 400)
            }
            Divider()
            HStack {
                if let problem = registry.problem ?? error {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if saving { ProgressView().controlSize(.small) }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((registry == original && deletions.isEmpty) || registry.problem != nil || saving)
            }
            .padding(12)
        }
        .frame(width: 760, height: 500)
        .onAppear(perform: load)
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(registry.projects) { p in
                    Section {
                        Label(p.title, systemImage: "folder.fill").font(.headline).tag("project:\(p.id)")
                        ForEach(registry.scopes(in: p.id)) { s in
                            HStack {
                                Text(s.title).strikethrough(deletions[s.id] != nil)
                                Spacer()
                                if deletions[s.id] != nil {
                                    Text("deleted on Save").font(.caption2).foregroundStyle(.red)
                                } else if s.wide {
                                    Text("project-wide").font(.caption2).foregroundStyle(.secondary)
                                } else if !s.includes.isEmpty {
                                    Text("+ \(s.includes.count)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, 12)
                            .tag("scope:\(s.id)")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Menu {
                    ForEach(registry.projects) { p in
                        Button("Scope in \(p.title)") { addScope(to: p.id) }
                    }
                    Divider()
                    Button("Project…") { addProject() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let sel = selection, sel.hasPrefix("scope:"), let i = registry.scopes.firstIndex(where: { "scope:\($0.id)" == sel }) {
            scopeForm(i)
        } else if let sel = selection, sel.hasPrefix("project:"), let i = registry.projects.firstIndex(where: { "project:\($0.id)" == sel }) {
            projectForm(i)
        } else {
            ListEmptyState(title: "Projects and Scopes", systemImage: "square.stack.3d.up", message: "A project, such as Acme App, has scopes: one project-wide and one per app or part, such as Android or iOS. An entry lives in one scope and can be tagged with others in the same project.")
        }
    }

    private func scopeForm(_ i: Int) -> some View {
        let isNew = !original.scopes.contains { $0.id == registry.scopes[i].id }
        let entries = model.index.entries.values.filter { $0.project == registry.scopes[i].id }.count
        return Form {
            TextField("Title", text: $registry.scopes[i].title, prompt: Text("Android"))
            if isNew {
                TextField("Folder id", text: $registry.scopes[i].id, prompt: Text("android"))
                    .font(.body.monospaced())
            } else {
                LabeledContent("Folder id", value: "projects/\(registry.scopes[i].id)")
            }
            Picker("Project", selection: $registry.scopes[i].project) {
                ForEach(registry.projects) { Text($0.title).tag($0.id) }
            }
            Toggle("Project-wide scope", isOn: Binding(
                get: { registry.scopes[i].wide },
                set: { on in
                    guard on else { return }
                    let p = registry.scopes[i].project
                    for j in registry.scopes.indices where registry.scopes[j].project == p { registry.scopes[j].wide = (j == i) }
                }))
            TextField("Code folders", text: listBinding(\.paths, i), prompt: Text("~/projects/android/app, comma separated"))
                .help("A \(Brain.name) session started in one of these folders works in this scope. Leave it empty for a scope that only works on other scopes' repositories, such as Mobile working on Android and iOS.")
            TextField("Git remotes", text: listBinding(\.remotes, i), prompt: Text("_git/app, part of the origin URL"))
            includesSection(i)
            Section {
                if isNew {
                    Button("Remove This Scope", role: .destructive) {
                        registry.scopes.remove(at: i)
                        selection = nil
                    }
                } else if let to = deletions[registry.scopes[i].id] {
                    HStack {
                        Text("Deleted on Save. Its \(entries) entries move to \(title(of: to)).").font(.callout).foregroundStyle(.red)
                        Spacer()
                        Button("Keep") { deletions[registry.scopes[i].id] = nil }
                    }
                } else {
                    HStack {
                        Text(entries == 0 ? "No entries live here." : "\(entries) entries live here.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete Scope…", role: .destructive) {
                            let s = registry.scopes[i]
                            deleteTarget = registry.scopes.first { $0.project == s.project && $0.wide }?.id ?? ""
                            confirmDelete = s.id
                        }
                        .disabled(registry.scopes[i].wide)
                        .help(registry.scopes[i].wide ? "Make another scope project-wide first" : "Delete this scope and move its entries")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
        .sheet(item: Binding(get: { confirmDelete.map { DeleteRequest(id: $0) } }, set: { confirmDelete = $0?.id })) { req in
            deleteSheet(req.id)
        }
    }

    private struct DeleteRequest: Identifiable { let id: String }

    private func title(of scope: String) -> String {
        registry.scopes.first { $0.id == scope }?.title ?? scope
    }

    /// What the scope works on (its own repository and those it works on alongside it, whose entries it shows too)
    /// and what it only takes knowledge from, read only.
    @ViewBuilder
    private func includesSection(_ i: Int) -> some View {
        let s = registry.scopes[i]
        let projectTitle = registry.projects.first { $0.id == s.project }?.title ?? s.project
        let others = registry.scopes(in: s.project).filter { $0.id != s.id && !$0.wide }
        Section {
            if s.wide {
                LabeledContent("Works on", value: "Everything in \(projectTitle)")
            } else {
                LabeledContent("Works on") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.paths.isEmpty ? "No code folder of its own" : "Its own code folder")
                            .foregroundStyle(.secondary)
                        ForEach(others) { o in
                            Toggle(isOn: Binding(
                                get: { registry.scopes[i].includes.contains(o.id) },
                                set: { on in
                                    registry.scopes[i].includes.removeAll { $0 == o.id }
                                    registry.scopes[i].related.removeAll { $0 == o.id }
                                    if on { registry.scopes[i].includes.append(o.id) }
                                })) {
                                ScopeOptionLabel(title: o.title, paths: o.paths)
                            }
                        }
                        Text("Worked on together: sessions in this scope can change these repositories, and their entries and work items show here too.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            let knowledge = registry.scopes.filter { o in
                o.id != s.id && !(s.wide && o.project == s.project) && !registry.scopes[i].includes.contains(o.id)
            }
            if !knowledge.isEmpty {
                LabeledContent("Knowledge from") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(knowledge) { o in
                            Toggle(isOn: Binding(
                                get: { registry.scopes[i].related.contains(o.id) },
                                set: { on in
                                    registry.scopes[i].related.removeAll { $0 == o.id }
                                    if on { registry.scopes[i].related.append(o.id) }
                                })) {
                                ScopeOptionLabel(title: o.project == s.project ? o.title : "\(o.title) (\(registry.projects.first { $0.id == o.project }?.title ?? o.project))",
                                                 paths: o.paths)
                            }
                        }
                        Label("Read only: sessions read their code and knowledge to learn from them, but never change, branch, commit or open pull requests there.",
                              systemImage: "eye")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("Repositories")
        }
    }

    private func deleteSheet(_ id: String) -> some View {
        let s = registry.scopes.first { $0.id == id }
        let targets = registry.scopes.filter { $0.project == s?.project && $0.id != id && deletions[$0.id] == nil }
        let count = model.index.entries.values.filter { $0.project == id }.count
        return VStack(alignment: .leading, spacing: 14) {
            Text("Delete “\(s?.title ?? id)”?").font(.title3.weight(.semibold))
            Text(count == 0 ? "No entries live in it. Entries elsewhere that are tagged with it lose that tag."
                 : "Its \(count) entries move to the scope you pick, and keep their other scopes. Entries elsewhere tagged with it lose that tag. Its folder and its settings are deleted.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Move entries to", selection: $deleteTarget) {
                ForEach(targets) { Text($0.title).tag($0.id) }
            }
            HStack {
                Spacer()
                Button("Cancel") { confirmDelete = nil }.keyboardShortcut(.cancelAction)
                Button("Delete on Save", role: .destructive) {
                    deletions[id] = deleteTarget
                    for j in registry.scopes.indices {
                        registry.scopes[j].includes.removeAll { $0 == id }
                        registry.scopes[j].related.removeAll { $0 == id }
                    }
                    confirmDelete = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(deleteTarget.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func projectForm(_ i: Int) -> some View {
        let isNew = !original.projects.contains { $0.id == registry.projects[i].id }
        return Form {
            TextField("Title", text: $registry.projects[i].title, prompt: Text("Acme App"))
            if isNew {
                TextField("Id", text: $registry.projects[i].id, prompt: Text("acme")).font(.body.monospaced())
            } else {
                LabeledContent("Id", value: registry.projects[i].id)
            }
            LabeledContent("Scopes", value: registry.scopes(in: registry.projects[i].id).map(\.title).joined(separator: ", "))
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
    }

    private func listBinding(_ key: WritableKeyPath<Registry.Scope, [String]>, _ i: Int) -> Binding<String> {
        Binding(get: { registry.scopes[i][keyPath: key].joined(separator: ", ") },
                set: { registry.scopes[i][keyPath: key] = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }

    private func unique(_ base: String) -> String {
        var id = base.isEmpty ? "scope" : base
        var n = 2
        while registry.scopes.contains(where: { $0.id == id }) || registry.projects.contains(where: { $0.id == id }) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    private func addScope(to project: String) {
        let id = unique("new-scope")
        registry.scopes.append(.init(id: id, title: "New scope", project: project))
        selection = "scope:\(id)"
    }

    private func addProject() {
        let pid = unique("new-project")
        registry.projects.append(.init(id: pid, title: "New project"))
        let sid = unique("\(pid)-wide")
        registry.scopes.append(.init(id: sid, title: "Project-wide", project: pid, wide: true))
        selection = "project:\(pid)"
    }

    private func load() {
        do {
            registry = try Registry.load(KBLayout.home(root: model.rootURL).appendingPathComponent("kb.json"))
            original = registry
        } catch {
            self.error = "Could not read kb.json: \(error.localizedDescription)"
        }
    }

    /// Writes kb.json, then deletes the scopes marked for it through the CLI, which moves their entries.
    private func save() {
        do {
            try registry.save(root: model.rootURL)
        } catch {
            self.error = error.localizedDescription
            return
        }
        guard !deletions.isEmpty else {
            model.reload()
            dismiss()
            return
        }
        saving = true
        let cli = model.cli
        let pending = deletions
        Task {
            var failures: [String] = []
            for (id, to) in pending.sorted(by: { $0.key < $1.key }) {
                do { _ = try await cli.run(["scope", "remove", id, "--move-to", to]) } catch { failures.append(error.localizedDescription) }
            }
            saving = false
            model.reload()
            if failures.isEmpty {
                model.notice = "Deleted \(pending.count) scope\(pending.count == 1 ? "" : "s")."
                dismiss()
            } else {
                self.error = failures.joined(separator: " ")
                load()
                deletions = [:]
            }
        }
    }
}

/// A scope in the Works on / Knowledge from lists: its title and where its code is.
private struct ScopeOptionLabel: View {
    let title: String
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(paths.first ?? "No repository")
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}
