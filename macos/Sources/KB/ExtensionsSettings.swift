import AppKit
import KBCore
import KBEngine
import SwiftUI

/// Settings → Skills & Plugins: the brain's skills (the user's own to add and change, plugins' to look at), its
/// plugins, and its tools (MCP servers). Sessions started afterwards pick changes up.
struct ExtensionsSettingsView: View {
    enum Tab: String, CaseIterable { case skills, plugins, tools }
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .skills

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Skills").tag(Tab.skills)
                if model.engine.brainHasPlugins {
                    Text("Plugins").tag(Tab.plugins)
                    Text("Tools").tag(Tab.tools)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(12)
            Divider()
            switch tab {
            case .skills: SkillsList()
            case .plugins: PluginsList()
            case .tools: ToolsList()
            }
        }
        .frame(width: 600, height: 620)
    }
}

// MARK: Skills

struct SkillEditRequest: Identifiable {
    let id = UUID()
    var name: String
    var location: SkillLocation
    var scope: String?
    var content: String
    var isNew: Bool
}

private struct SkillsList: View {
    @Environment(AppModel.self) private var model
    @State private var skills: [SkillInfo] = []
    @State private var loading = false
    @State private var editing: SkillEditRequest?
    @State private var adding = false
    @State private var showPlugins = false

    var body: some View {
        let mine = skills.filter { $0.source == .user }
        let project = skills.filter { $0.source == .project }
        let plugins = skills.filter { $0.source == .plugin }
        Form {
            Section {
                Text("Skills teach \(Brain.name) how to do something your way. Type / in a session to run one. Yours can be for every project or only one project (kept in its repository, so the team gets it too).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ChipRow(spacing: 8) {
                    Button { adding = true } label: { Label("Add Skill…", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                    if loading { ProgressView().controlSize(.small) }
                }
            }
            Section("Mine, in every project") {
                if mine.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(mine) { row($0) }
            }
            if !project.isEmpty {
                ForEach(Array(Set(project.compactMap(\.scope))).sorted(), id: \.self) { scope in
                    Section("Only in \(model.index.project(scope)?.title ?? scope)") {
                        ForEach(project.filter { $0.scope == scope }) { row($0) }
                    }
                }
            }
            Section {
                FoldableSection(isExpanded: $showPlugins) {
                    ForEach(plugins) { row($0) }
                } header: {
                    Text("From plugins · \(plugins.count)")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: model.skillsRevision) { _, _ in load() }
        .sheet(isPresented: $adding) { NewSkillSheet { editing = $0 } }
        .sheet(item: $editing) { SkillEditorSheet(request: $0) }
    }

    private func row(_ s: SkillInfo) -> some View {
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 260) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.command).font(.body.monospaced())
                if !s.description.isEmpty {
                    Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if s.editable, let location = s.location {
                Button("Edit…") {
                    let text = s.path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
                    editing = SkillEditRequest(name: s.name, location: location, scope: s.scope, content: text, isNew: false)
                }
            } else if let path = s.path {
                Button("Show") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .help("Open its SKILL.md; plugins' skills change with the plugin")
            }
        }
    }

    private func load() {
        loading = true
        Task {
            skills = await model.engine.skillCatalog(scope: nil)
            loading = false
        }
    }
}

/// A new skill: its name, where it's kept, and what it should do; the brain writes it for review.
private struct NewSkillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onDraft: (SkillEditRequest) -> Void
    @State private var name = ""
    @State private var scope = ""
    @State private var what = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let repos = model.index.projects.filter { KBLayout.of(root: model.rootURL).checkouts[$0.id] != nil }
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Skill").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. release-notes (optional)"))
                Picker("Where", selection: $scope) {
                    Text("For me, in every project").tag("")
                    ForEach(repos) { p in Text("Only in \(p.title)").tag(p.id) }
                }
            }
            .formStyle(.grouped)
            .frame(height: 120)
            Text("What should it do?").font(.headline)
            TextEditor(text: $what)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            Text("Describe it in your own words: when to use it, the steps, what to check. \(Brain.name) writes the skill and you can change it before saving.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Write It Myself") { finish(SkillCatalog.cleanDraft("---\nname: \(SkillCatalog.safeName(name))\ndescription: \(what.split(separator: "\n").first ?? "")\n---\n\n")) }
                    .disabled(SkillCatalog.safeName(name).isEmpty)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Write It with \(Brain.name)") { draft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || what.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func draft() {
        working = true
        error = nil
        Task {
            do {
                finish(try await model.engine.draftSkill(description: what, name: name.isEmpty ? nil : name, current: nil))
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    private func finish(_ content: String) {
        let drafted = SkillCatalog.frontmatter(content).name ?? name
        onDraft(SkillEditRequest(name: SkillCatalog.safeName(drafted.isEmpty ? name : drafted), location: scope.isEmpty ? .user : .project,
                                 scope: scope.isEmpty ? nil : scope, content: content, isNew: true))
        dismiss()
    }
}

/// A skill's SKILL.md to read and change by hand, or by telling the brain what to change.
private struct SkillEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SkillEditRequest
    @State private var content = ""
    @State private var change = ""
    @State private var working = false
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("/\(request.name)").font(.title3.weight(.semibold).monospaced())
                Spacer()
                Text(request.location == .user ? "For me, in every project" : "Only in \(model.index.project(request.scope ?? "")?.title ?? request.scope ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $content)
                .font(.body.monospaced())
                .frame(minHeight: 320)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            HStack(spacing: 8) {
                TextField("Change it: tell \(Brain.name) what to change", text: $change, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit(redraft)
                Button("Change It") { redraft() }
                    .disabled(working || change.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if !request.isNew {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(working || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear { content = request.content }
        .confirmationDialog("Delete /\(request.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                do {
                    try model.engine.deleteSkill(name: request.name, location: request.location, scope: request.scope)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func redraft() {
        working = true
        error = nil
        let ask = change
        Task {
            do {
                content = try await model.engine.draftSkill(description: ask, name: request.name, current: content)
                change = ""
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    private func save() {
        do {
            try model.engine.saveSkill(name: request.name, location: request.location, scope: request.scope, content: content)
            model.notice = "Saved /\(request.name). Sessions started from now on can use it."
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Plugins

private struct PluginsList: View {
    @Environment(AppModel.self) private var model
    @State private var installed: [AIExtensions.InstalledPlugin] = []
    @State private var available: [AIExtensions.AvailablePlugin] = []
    @State private var allAvailable: [AIExtensions.AvailablePlugin] = []
    @State private var query = ""
    @State private var busy: Set<String> = []
    @State private var loading = false
    @State private var error: String?
    @State private var removing: AIExtensions.InstalledPlugin?

    var body: some View {
        Form {
            Section {
                Text("Plugins bring skills, commands and tools to \(Brain.name). Changes work in sessions started afterwards.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
            Section("Installed") {
                if loading && installed.isEmpty { ProgressView().controlSize(.small) }
                ForEach(installed) { p in
                    AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 240) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.body.weight(.medium))
                            Text([p.marketplace, p.version, p.scope == "user" ? nil : "only in one project"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            if busy.contains(p.id) { ProgressView().controlSize(.small) }
                            Toggle("On", isOn: Binding(get: { p.enabled }, set: { on in run(p.id, ["plugin", on ? "enable" : "disable", p.id]) }))
                                .toggleStyle(.switch).labelsHidden()
                            Button("Uninstall…") { removing = p }
                        }
                        .fixedSize()
                        .disabled(busy.contains(p.id))
                    }
                }
            }
            Section("Get more") {
                TextField("Search the marketplaces", text: $query).textFieldStyle(.roundedBorder)
                ForEach(available) { p in
                    AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 240) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.body.weight(.medium))
                            if !p.description.isEmpty { Text(p.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            Text(p.marketplace + (p.installs.map { " · \($0) installs" } ?? "")).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            if busy.contains(p.id) { ProgressView().controlSize(.small) }
                            Button("Install") { run(p.id, ["plugin", "install", p.id]) }.disabled(busy.contains(p.id))
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: query) { _, q in available = AIExtensions.search(allAvailable, query: q, limit: 40) }
        .confirmationDialog("Uninstall \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Uninstall", role: .destructive) { if let p = removing { run(p.id, ["plugin", "uninstall", p.id]) } }
        }
    }

    private func load() {
        loading = true
        Task {
            if let r = await model.engine.runClaudeCLI(["plugin", "list", "--available", "--json"]), r.status == 0 {
                let both = AIExtensions.parsePlugins(r.stdout)
                installed = both.installed
                allAvailable = both.available
                available = AIExtensions.search(allAvailable, query: query, limit: 40)
            } else {
                installed = await model.engine.installedPlugins(refresh: true)
            }
            loading = false
        }
    }

    private func run(_ id: String, _ args: [String]) {
        busy.insert(id)
        error = nil
        Task {
            do { try await model.engine.claudeChange(args) } catch { self.error = error.localizedDescription }
            busy.remove(id)
            load()
        }
    }
}

// MARK: Tools

private struct ToolsList: View {
    @Environment(AppModel.self) private var model
    @State private var servers: [ClaudeConnectors.Server] = []
    @State private var loading = false
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Tools (MCP servers) let \(Brain.name) reach other systems. Connectors you add on your account work in every session too.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ChipRow(spacing: 8) {
                    Button { adding = true } label: { Label("Add a Tool…", systemImage: "plus") }
                    if let url = model.engine.connectorsURL {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Manage Connectors", systemImage: "arrow.up.right.square") }
                    }
                    if loading { ProgressView().controlSize(.small) }
                    Button { load() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Check again")
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
            Section("Connected") {
                ForEach(servers) { s in
                    AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 240) {
                        Circle().fill(s.status == .connected ? Color.green : Color.orange).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.displayName).font(.body.weight(.medium))
                            Text(s.fromClaudeAI ? "Connector on your account" : s.fromPlugin ? "From a plugin" : s.target)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !s.fromClaudeAI && !s.fromPlugin {
                            Button("Remove") { remove(s) }.fixedSize()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .sheet(isPresented: $adding) { AddToolSheet { load() } }
    }

    private func load() {
        loading = true
        Task {
            let r = await model.engine.runClaudeCLI(["mcp", "list"])
            servers = r.map { ClaudeConnectors.parse($0.stdout) } ?? []
            if r == nil { error = model.engine.claudeMissingExplanation }
            loading = false
        }
    }

    private func remove(_ s: ClaudeConnectors.Server) {
        Task {
            do { try await model.engine.claudeChange(["mcp", "remove", s.name]) } catch {
                do { try await model.engine.claudeChange(["mcp", "remove", s.name, "--scope", "user"]) } catch { self.error = error.localizedDescription }
            }
            load()
        }
    }
}
