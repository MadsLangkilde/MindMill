import AppKit
import KBCore
import KBEngine
import SwiftUI

enum ArchitectureTab: String {
    case notes, docs
}

struct DocScanRequest: Identifiable, Equatable {
    let id = UUID()
    let scope: String
}

struct NewDocRequest: Identifiable, Equatable {
    let id = UUID()
    let scope: String
}

struct SaveDocsRequest: Identifiable, Equatable {
    let id = UUID()
    let scope: String
    var only: String?
}

extension AppModel {
    func loadProjectDocs(_ scope: String) {
        guard !projectDocsLoading.contains(scope) else { return }
        projectDocsLoading.insert(scope)
        let cli = cli
        Task {
            do {
                projectDocs[scope] = try ProjectDocList.decode(try await cli.run(["docs", "list", "--scope", scope, "--json"]))
                projectDocsError[scope] = nil
            } catch {
                projectDocsError[scope] = (error as? KBCLIError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "kb: ", with: "") ?? error.localizedDescription
            }
            projectDocsLoading.remove(scope)
        }
    }

    func projectDoc(_ scope: String, _ path: String?) -> ProjectDocList.Doc? {
        guard let path else { return nil }
        return projectDocs[scope]?.docs.first { $0.path == path }
    }

    private func docsCLI(_ scope: String, _ args: [String], stdin: String? = nil, done: String?, then: (() -> Void)? = nil) {
        let cli = cli
        Task {
            do {
                _ = try await cli.run(["docs"] + args + ["--scope", scope], stdin: stdin)
                if let done { notice = done }
                then?()
            } catch {
                errorMessage = error.localizedDescription
            }
            loadProjectDocs(scope)
        }
    }

    func addDocs(_ scope: String, _ paths: [String]) {
        guard !paths.isEmpty else { return }
        docsCLI(scope, ["add"] + paths, done: "\(paths.count) doc\(paths.count == 1 ? "" : "s") added to Architecture.")
    }

    func saveDocDraft(_ scope: String, _ path: String, _ text: String) {
        docsCLI(scope, ["draft", path], stdin: text, done: "Saved as a draft. Save to Project puts it in a pull request.")
    }

    func discardDocDraft(_ scope: String, _ path: String) {
        docsCLI(scope, ["discard", path], done: "Draft discarded.")
    }

    func removeDoc(_ scope: String, _ path: String) {
        if selectedProjectDoc == path { selectedProjectDoc = nil }
        docsCLI(scope, ["remove", path], done: "Removed from the list. The file stays in the repository.")
    }

    func createDoc(_ scope: String, path: String, title: String) {
        docsCLI(scope, ["draft", path], stdin: "# \(title.trimmingCharacters(in: .whitespaces))\n\n", done: nil) { [weak self] in
            self?.selectedProjectDoc = path
            self?.editProjectDoc = path
        }
    }

    /// A Build session branches, commits, pushes and opens the pull request the way the repository does it.
    func saveDocsToProject(_ scope: String, _ docs: [ProjectDocList.Doc], note: String) {
        guard !docs.isEmpty else { return }
        let title = docs.count == 1 ? "Docs: \(docs[0].title)" : "Docs: \(docs.count) changes"
        newSession(title: title, project: scope, message: ProjectDocPath.prBrief(scope: scope, docs: docs, note: note),
                   display: "Put \(docs.count == 1 ? "“\(docs[0].title)”" : "\(docs.count) documentation changes") into a pull request",
                   about: "docs:\(scope)", space: .build)
    }

    /// Opens the diagram editor on diagram `index` of an entry, and saves the entry with the result.
    func editEntryDiagram(_ id: EntryID, index: Int) {
        guard document?.id == id, let body = document?.body else { return }
        let blocks = MermaidBlocks.find(in: body)
        diagramRequest = DiagramRequest(title: "Edit Diagram", source: blocks.indices.contains(index) ? blocks[index].source : "",
                                        project: id.project) { [weak self] source in
            guard let self, self.document?.id == id, let body = self.document?.body else { return }
            self.document?.body = MermaidBlocks.replacing(index, with: source, in: body)
            self.save()
        }
    }
}

// MARK: Architecture

/// Architecture: the knowledge base's notes, and documentation files from the scope's repository.
struct ArchitectureView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Show", selection: $model.architectureTab) {
                Text("Notes").tag(ArchitectureTab.notes)
                Text("Project Docs").tag(ArchitectureTab.docs)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 8)
            switch model.architectureTab {
            case .notes: EntryListView(project: project, section: .architecture)
            case .docs: ProjectDocsList(project: project)
            }
        }
    }
}

struct ProjectDocsList: View {
    @Environment(AppModel.self) private var model
    let project: KBProject

    var body: some View {
        let list = model.projectDocs[project.id]
        let query = model.listQuery(.projectDocs)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(list.map { "\($0.docs.count) doc\($0.docs.count == 1 ? "" : "s")" } ?? "Project docs").font(.headline)
                if model.projectDocsLoading.contains(project.id) { ProgressView().controlSize(.small) }
                Spacer()
                Button { model.loadProjectDocs(project.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Read the repository again")
                Menu {
                    Button("Scan the Repository…") { model.docScanRequest = DocScanRequest(scope: project.id) }
                    Button("New Document…") { model.newDocRequest = NewDocRequest(scope: project.id) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .fixedSize()
                .disabled(model.projectDocsError[project.id] != nil)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            if let drafts = list?.drafts, !drafts.isEmpty {
                AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 160) {
                    Image(systemName: "pencil.and.list.clipboard").foregroundStyle(.orange)
                    Text("\(drafts.count) change\(drafts.count == 1 ? "" : "s") not in the repository yet")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Save to Project…") { model.saveDocsRequest = SaveDocsRequest(scope: project.id) }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            if !(list?.docs.isEmpty ?? true) { ListSearchField(key: .projectDocs, prompt: "Search docs") }
            Divider().padding(.top, 6)
            if let error = model.projectDocsError[project.id] {
                ListEmptyState(title: "No repository", systemImage: "folder.badge.questionmark",
                               message: error.contains("no repository") ? "\(project.title) has no repository on this Mac. Add its folder in the scope's settings to bring in its docs." : error)
            } else if let list {
                let groups = list.byFolder.map { ($0.folder, $0.docs.filter { $0.matches(query) }) }.filter { !$0.1.isEmpty }
                if list.docs.isEmpty {
                    ListEmptyState(title: "No Project Docs Yet", systemImage: "doc.richtext", message: "Bring in the documentation that lives in the repository, such as docs/ and READMEs, to read and edit it here. Changes go back to the repository as a pull request when you choose.") {
                        Button("Scan the Repository…") { model.docScanRequest = DocScanRequest(scope: project.id) }
                        Button("New Document…") { model.newDocRequest = NewDocRequest(scope: project.id) }
                    }
                } else if groups.isEmpty {
                    ListEmptyState(title: "No docs match “\(query)”", systemImage: "magnifyingglass")
                } else {
                    List(selection: Binding(get: { model.selectedProjectDoc }, set: { model.selectedProjectDoc = $0 })) {
                        ForEach(groups, id: \.0) { folder, docs in
                            Section(folder.isEmpty ? "Top level" : folder) {
                                ForEach(docs) { doc in
                                    ProjectDocRow(doc: doc).tag(doc.path)
                                        .contextMenu {
                                            Button("Open in Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: doc.file)) }
                                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: doc.file)]) }
                                            if doc.hasDraft {
                                                Button("Save to Project…") { model.saveDocsRequest = SaveDocsRequest(scope: project.id, only: doc.path) }
                                                Button("Discard Draft", role: .destructive) { model.discardDocDraft(project.id, doc.path) }
                                            }
                                            Divider()
                                            Button("Remove from List") { model.removeDoc(project.id, doc.path) }
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            } else {
                ListEmptyState(title: "Reading the repository…", systemImage: "doc.richtext")
            }
        }
        .onAppear { model.loadProjectDocs(project.id) }
        .onChange(of: project.id) { _, id in model.loadProjectDocs(id) }
    }
}

struct ProjectDocRow: View {
    let doc: ProjectDocList.Doc

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(doc.title).font(.headline).lineLimit(2)
            Text(doc.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if doc.hasDraft || doc.stale {
                ChipRow(spacing: 6) {
                    if let draft = doc.draft {
                        Chip(text: draft == "new" ? "New · not in the repository" : "Edited · not in the repository", color: .orange,
                             systemImage: "pencil")
                    }
                    if doc.stale { Chip(text: "Repository changed since", color: .red, systemImage: "exclamationmark.triangle") }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: Detail

struct ProjectDocDetail: View {
    @Environment(AppModel.self) private var model
    let scope: String
    let doc: ProjectDocList.Doc
    @State private var editing = false
    @State private var text = ""
    @State private var bodyHeight: CGFloat = 200

    private var content: String { (try? String(contentsOfFile: doc.file, encoding: .utf8)) ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if editing {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            } else {
                let html = MarkdownRenderer(diagramLinks: true).render(content)
                ScrollView(.vertical) {
                    MarkdownWebView(html: MarkdownRenderer.page(body: html, accentHex: NSColor.controlAccentColor.hexString),
                                    baseURL: URL(fileURLWithPath: doc.repoFile).deletingLastPathComponent(),
                                    onLink: link, contentHeight: $bodyHeight)
                        .frame(height: max(bodyHeight, 40))
                }
            }
        }
        .onAppear {
            if model.editProjectDoc == doc.path {
                model.editProjectDoc = nil
                startEditing()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(doc.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            ChipRow(spacing: 6) {
                Text(doc.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let draft = doc.draft {
                    Chip(text: draft == "new" ? "New · not in the repository" : "Edited · not in the repository", color: .orange, systemImage: "pencil")
                }
                if doc.stale {
                    Chip(text: "The repository changed it since your draft began", color: .red, systemImage: "exclamationmark.triangle")
                }
            }
            ChipRow(spacing: 8) {
                if editing {
                    Button("Cancel") { editing = false }
                    Button("Insert Diagram…") {
                        model.diagramRequest = DiagramRequest(title: "New Diagram", source: MermaidBlocks.templates[0].source,
                                                              project: scope) { source in
                            text = MermaidBlocks.replacing(Int.max, with: source, in: text)
                        }
                    }
                    Button("Save Draft") {
                        model.saveDocDraft(scope, doc.path, text)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                } else {
                    Button { startEditing() } label: { Label("Edit", systemImage: "pencil") }
                        .keyboardShortcut("e", modifiers: .command)
                    Button {
                        model.diagramRequest = DiagramRequest(title: "New Diagram", source: MermaidBlocks.templates[0].source,
                                                              project: scope) { source in
                            model.saveDocDraft(scope, doc.path, MermaidBlocks.replacing(Int.max, with: source, in: content))
                        }
                    } label: { Label("Add Diagram…", systemImage: "point.3.connected.trianglepath.dotted") }
                    if doc.hasDraft {
                        Button("Discard Draft", role: .destructive) { model.discardDocDraft(scope, doc.path) }
                        Button("Save to Project…") { model.saveDocsRequest = SaveDocsRequest(scope: scope, only: doc.path) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button { model.askAbout(.text("The project document `\(doc.path)` (read it at `\(doc.file)`).", title: doc.title, project: scope)) } label: {
                        Label("Ask \(Brain.name)", systemImage: "questionmark.bubble")
                    }
                }
            }
            .font(.callout)
            if !editing, !doc.hasDraft {
                Text("Edits are kept as a draft here. Save to Project puts them in the repository with a pull request.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func startEditing() {
        text = content
        editing = true
    }

    private func link(_ url: String) {
        guard url.hasPrefix("kb://diagram"), let index = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "index" })?.value.flatMap(Int.init) else {
            model.openLink(url)
            return
        }
        let current = content
        let blocks = MermaidBlocks.find(in: current)
        guard blocks.indices.contains(index) else { return }
        model.diagramRequest = DiagramRequest(title: "Edit Diagram", source: blocks[index].source, project: scope) { source in
            model.saveDocDraft(scope, doc.path, MermaidBlocks.replacing(index, with: source, in: current))
        }
    }
}

// MARK: Sheets

struct DocScanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: DocScanRequest
    @State private var scan: DocScan?
    @State private var error: String?
    @State private var picked: Set<String> = []
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Documentation in the Repository").font(.title2.weight(.semibold))
            Text("Pick the docs to read and edit in Architecture. They stay in the repository; Mindmill lists them and keeps your edits as drafts until you save them to the project.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(.red)
            } else if let scan {
                let shown = scan.docs.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query) }
                HStack {
                    TextField("Filter", text: $query).textFieldStyle(.roundedBorder)
                    Button("Select All") { picked.formUnion(shown.filter { !$0.added }.map(\.path)) }
                    Button("None") { picked.subtract(shown.map(\.path)) }
                }
                List {
                    ForEach(shown) { d in
                        Toggle(isOn: Binding(get: { d.added || picked.contains(d.path) },
                                             set: { on in if on { picked.insert(d.path) } else { picked.remove(d.path) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.title).lineLimit(2)
                                Text(d.path + (d.added ? " · added" : "")).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(d.added)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 280)
                if scan.docs.isEmpty { Text("No documentation files found.").foregroundStyle(.secondary) }
            } else {
                ProgressView("Scanning…").frame(maxWidth: .infinity, minHeight: 200)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
                    model.addDocs(request.scope, picked.sorted())
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 580, height: 560)
        .task {
            do {
                scan = try DocScan.decode(try await model.cli.run(["docs", "scan", "--scope", request.scope, "--json"]))
            } catch {
                self.error = (error as? KBCLIError)?.stderr ?? error.localizedDescription
            }
        }
    }
}

struct NewDocSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NewDocRequest
    @State private var title = ""
    @State private var path = ""
    @State private var pathEdited = false

    var body: some View {
        let taken = model.projectDocs[request.scope]?.docs.contains { $0.path == path } ?? false
        VStack(alignment: .leading, spacing: 14) {
            Text("New Document").font(.title2.weight(.semibold))
            TextField("Title, e.g. BLE reconnect flow", text: $title)
                .textFieldStyle(.roundedBorder)
                .onChange(of: title) { _, t in if !pathEdited { path = ProjectDocPath.suggested(title: t) } }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Path in the repository", text: Binding(get: { path }, set: { path = $0; pathEdited = true }))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Text(!path.isEmpty && !ProjectDocPath.isValid(path) ? "Use a Markdown path inside the repository, such as docs/name.md."
                     : taken ? "That document is already in the list." : "It starts as a draft here, and goes into the repository when you save it to the project.")
                    .font(.caption)
                    .foregroundStyle(!path.isEmpty && (!ProjectDocPath.isValid(path) || taken) ? .red : .secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.architectureTab = .docs
                    model.createDoc(request.scope, path: path, title: title)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || !ProjectDocPath.isValid(path) || taken)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

struct SaveDocsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SaveDocsRequest
    @State private var picked: Set<String> = []
    @State private var note = ""

    var body: some View {
        let drafts = model.projectDocs[request.scope]?.drafts ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text("Save to Project").font(.title2.weight(.semibold))
            Text("A Build session makes a branch, commits these, pushes and opens a pull request the way this repository does it. It asks you when it isn't sure, such as which work item to link.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(drafts) { d in
                Toggle(isOn: Binding(get: { picked.contains(d.path) }, set: { on in if on { picked.insert(d.path) } else { picked.remove(d.path) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.title)
                        Text(d.path + (d.draft == "new" ? " · new" : " · edited") + (d.stale ? " · the repository changed it since" : ""))
                            .font(.caption.monospaced())
                            .foregroundStyle(d.stale ? .red : .secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What changed and why (optional, for the pull request)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make a Pull Request") {
                    model.saveDocsToProject(request.scope, drafts.filter { picked.contains($0.path) }, note: note)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { picked = Set(request.only.map { [$0] } ?? drafts.map(\.path)) }
    }
}
