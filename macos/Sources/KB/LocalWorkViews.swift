import KBCore
import KBEngine
import SwiftUI

extension LocalTracker.Kind {
    var color: Color {
        switch self {
        case .feature: return .purple
        case .pbi: return .blue
        case .bug: return .red
        case .task: return .orange
        }
    }
}

enum LocalWorkFilter {
    static let sprintKey = "localWorkSprint"
    static let showDoneKey = "localWorkShowDone"

    /// `all`, `none` (no sprint) or a sprint's name, as the tree and board take it.
    static func sprint(_ raw: String, _ t: LocalTracker) -> String? {
        guard t.useSprints else { return nil }
        switch raw {
        case "all": return nil
        case "none": return ""
        default: return t.sprints.contains { $0.name == raw } ? raw : nil
        }
    }
}

/// Plan → Backlog for a scope that uses Mindmill's own tracker: features, PBIs, bugs and tasks.
struct LocalBacklogView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    @AppStorage(LocalWorkFilter.sprintKey) private var sprint = "all"
    @AppStorage(LocalWorkFilter.showDoneKey) private var showDone = false
    @State private var newTitle = ""
    @State private var newKind: LocalTracker.Kind = .pbi
    @State private var sprintsSheet = false

    var body: some View {
        @Bindable var model = model
        let t = model.localTracker(project.id)
        let rows = t.tree(sprint: LocalWorkFilter.sprint(sprint, t), showDone: showDone)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Backlog").font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                    Button { model.selectedLocalItem = nil } label: { Label("Board", systemImage: "rectangle.split.3x1") }
                        .help("Show the board on the right")
                    Menu {
                        Button("Sprints…") { sprintsSheet = true }
                        Toggle("Show Done Items", isOn: $showDone)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
                if t.useSprints {
                    ChipRow(spacing: 6) {
                        pill("All", tag: "all")
                        ForEach(t.sprints) { s in
                            pill(s.name + (s.contains(KBDate.today()) ? " · now" : ""), tag: s.name)
                        }
                        pill("No sprint", tag: "none")
                    }
                }
                HStack(spacing: 6) {
                    Picker("Kind", selection: $newKind) {
                        ForEach([LocalTracker.Kind.feature, .pbi, .bug]) { k in Label(k.short, systemImage: k.icon).tag(k) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("Add a \(newKind.short)…", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
            Divider()
            List(selection: $model.selectedLocalItem) {
                if rows.isEmpty {
                    ListEmptyState(title: t.items.isEmpty ? "No work items yet" : "Nothing here",
                                   systemImage: "list.bullet.rectangle",
                                   message: t.items.isEmpty
                                       ? "Add a feature, PBI or bug above. Give PBIs tasks, plan them in sprints if you like, and move them on the board."
                                       : "Nothing matches this sprint. Pick All, or show done items.")
                }
                ForEach(rows, id: \.item.id) { row in
                    LocalItemRow(item: row.item, depth: row.depth, tracker: t, showSprint: t.useSprints && sprint == "all")
                        .tag(row.item.id)
                        .contextMenu { menu(row.item) }
                }
            }
            .listStyle(.inset)
        }
        .navigationSubtitle("Backlog")
        .onAppear { model.loadLocalTracker(project.id) }
        .sheet(isPresented: $sprintsSheet) { LocalSprintsSheet(scope: project.id) }
    }

    private func pill(_ title: String, tag: String) -> some View {
        Button { sprint = tag } label: {
            Text(title).font(.caption.weight(sprint == tag ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(sprint == tag ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let parent = newKind == .feature ? nil : model.localTracker(project.id).item(model.selectedLocalItem).flatMap { sel in
            sel.kind == .feature ? sel.id : nil
        }
        let id = model.addLocalItem(project.id, newKind, title: title, parent: parent)
        if let s = LocalWorkFilter.sprint(sprint, model.localTracker(project.id)), !s.isEmpty, newKind != .feature {
            model.editLocalTracker(project.id) { t in
                if var i = t.item(id) { i.sprint = s; t.update(i) }
            }
        }
        newTitle = ""
        model.selectedLocalItem = id
    }

    @ViewBuilder
    private func menu(_ item: LocalTracker.Item) -> some View {
        Menu("State") {
            ForEach(item.kind.states, id: \.self) { s in
                Button(s) { model.editLocalTracker(project.id) { $0.setState(item.id, s) } }
            }
        }
        if item.kind == .feature {
            Button("Add a PBI to It") {
                model.selectedLocalItem = model.addLocalItem(project.id, .pbi, title: "New PBI", parent: item.id)
            }
        } else if item.kind != .task {
            Button("Add a Task") {
                model.selectedLocalItem = model.addLocalItem(project.id, .task, title: "New task", parent: item.id)
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            if model.selectedLocalItem == item.id { model.selectedLocalItem = nil }
            model.editLocalTracker(project.id) { $0.delete(item.id) }
        }
    }
}

struct LocalItemRow: View {
    let item: LocalTracker.Item
    var depth = 0
    let tracker: LocalTracker
    var showSprint = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.kind.icon)
                .foregroundStyle(item.kind.color)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(item.kind == .feature ? .body.weight(.semibold) : .body)
                    .strikethrough(item.state == "Done", color: .secondary)
                    .foregroundStyle(item.state == "Done" ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                ChipRow(spacing: 5) {
                    Chip(text: item.state, color: LocalItemRow.stateColor(item.state))
                    if showSprint, !item.sprint.isEmpty { Chip(text: item.sprint, color: .secondary) }
                    if item.kind == .pbi || item.kind == .bug {
                        let p = tracker.taskProgress(item.id)
                        if p.total > 0 { Chip(text: "\(p.done)/\(p.total) tasks", color: .secondary) }
                    }
                    Text("#\(item.id)").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .padding(.vertical, 2)
    }

    static func stateColor(_ s: String) -> Color {
        switch s {
        case "Done": return .green
        case "Committed", "In Progress": return .blue
        case "Approved": return .teal
        case "Removed": return .gray
        default: return .secondary
        }
    }
}

/// The detail column: the picked item, or the board.
struct LocalWorkDetail: View {
    @Environment(AppModel.self) private var model
    let project: KBProject

    var body: some View {
        if let id = model.selectedLocalItem, model.localTracker(project.id).item(id) != nil {
            LocalItemEditor(scope: project.id, id: id).id(id)
        } else {
            LocalBoardView(scope: project.id)
        }
    }
}

/// PBIs and bugs by state; drag a card to another column to move it.
struct LocalBoardView: View {
    @Environment(AppModel.self) private var model
    let scope: String
    @AppStorage(LocalWorkFilter.sprintKey) private var sprint = "all"
    @State private var targeted: String?

    var body: some View {
        let t = model.localTracker(scope)
        let filter = LocalWorkFilter.sprint(sprint, t)
        let items = t.boardItems(sprint: filter)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Board").font(.title2.weight(.semibold))
                    Text(filter.map { $0.isEmpty ? "No sprint" : $0 } ?? (t.useSprints ? "All sprints" : "All work"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                BoardLayout(minColumnWidth: 190, spacing: 12) {
                    ForEach(LocalTracker.boardStates, id: \.self) { state in
                        column(state, items.filter { $0.state == state }, t)
                    }
                }
            }
            .padding(18)
        }
        .onAppear { model.loadLocalTracker(scope) }
    }

    private func column(_ state: String, _ cards: [LocalTracker.Item], _ t: LocalTracker) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(LocalItemRow.stateColor(state)).frame(width: 8, height: 8)
                Text(state).font(.callout.weight(.semibold))
                Text("\(cards.count)").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            ForEach(cards) { item in
                Button { model.selectedLocalItem = item.id } label: { card(item, t) }
                    .buttonStyle(.plain)
                    .draggable(String(item.id))
            }
            if cards.isEmpty {
                Text("Drop here").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(targeted == state ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { ids, _ in
            let picked = ids.compactMap(Int.init)
            guard !picked.isEmpty else { return false }
            withAnimation(.snappy) {
                model.editLocalTracker(scope) { t in for id in picked { t.setState(id, state) } }
            }
            return true
        } isTargeted: { on in targeted = on ? state : (targeted == state ? nil : targeted) }
    }

    private func card(_ item: LocalTracker.Item, _ t: LocalTracker) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: item.kind.icon).foregroundStyle(item.kind.color).font(.caption)
                Text(item.title).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            ChipRow(spacing: 5) {
                Text("#\(item.id)").font(.caption).foregroundStyle(.tertiary)
                if let f = t.item(item.parent) { Text(f.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                let p = t.taskProgress(item.id)
                if p.total > 0 { Chip(text: "\(p.done)/\(p.total)", color: .secondary) }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15)))
        .contentShape(Rectangle())
    }
}

/// One work item: its fields, description, acceptance criteria, and the items under it.
struct LocalItemEditor: View {
    @Environment(AppModel.self) private var model
    let scope: String
    let id: Int
    @State private var draft: LocalTracker.Item?
    @State private var saveTask: Task<Void, Never>?
    @State private var newChild = ""
    @State private var confirmDelete = false

    var body: some View {
        let t = model.localTracker(scope)
        ScrollView {
            if let item = draft {
                VStack(alignment: .leading, spacing: 16) {
                    header(item)
                    TextField("Title", text: binding(\.title), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1...4)
                    fields(item, t)
                    textArea("Description", binding(\.description), prompt: "What it is and why")
                    if item.kind == .bug { textArea("Steps to reproduce", binding(\.repro), prompt: "1. …\n2. …\nExpected / actual") }
                    if item.kind != .task { textArea("Acceptance criteria", binding(\.acceptance), prompt: "- It does …") }
                    if item.kind != .task { children(item, t) }
                    if item.kind == .pbi || item.kind == .bug {
                        ResearchLinks(target: .workItem(item.id), project: scope, title: item.title)
                    }
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { draft = t.item(id) }
        .onChange(of: model.localTracker(scope).item(id)) { _, fresh in
            // Changed elsewhere (the board, the CLI): take it unless an edit waits to be saved.
            if saveTask == nil, let fresh, fresh != draft { draft = fresh }
        }
        .onChange(of: draft) { _, d in scheduleSave(d) }
        .onDisappear { saveNow() }
        .confirmationDialog("Delete “\(draft?.title ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                saveTask?.cancel()
                saveTask = nil
                model.selectedLocalItem = nil
                model.editLocalTracker(scope) { $0.delete(id) }
            }
        } message: {
            Text("Everything under it is deleted too. Set its state to Removed instead to keep it.")
        }
    }

    private func binding<V>(_ key: WritableKeyPath<LocalTracker.Item, V>) -> Binding<V> {
        Binding(get: { draft![keyPath: key] }, set: { draft?[keyPath: key] = $0 })
    }

    private func header(_ item: LocalTracker.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.icon).foregroundStyle(item.kind.color)
            Text("\(item.kind.title) #\(item.id)").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if item.kind == .pbi || item.kind == .bug {
                let key = "wi:\(item.id)"
                if let s = model.sessions(forKey: key).first {
                    Button("Open in Build") { model.openSession(s) }
                } else {
                    Button { implement(item) } label: { Label("Implement…", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .help("Start it in Build with its description, acceptance criteria and tasks")
                }
            }
            Button { model.selectedLocalItem = nil } label: { Label("Board", systemImage: "rectangle.split.3x1") }
            Menu {
                Button("Delete…", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
    }

    private func implement(_ item: LocalTracker.Item) {
        saveNow()
        let t = model.localTracker(scope)
        if let fresh = t.item(item.id) { model.startImplement(t.asMyWork(fresh, scope: scope), show: true) }
    }

    @ViewBuilder
    private func fields(_ item: LocalTracker.Item, _ t: LocalTracker) -> some View {
        let columns = [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .topLeading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            field("State") {
                Picker("State", selection: binding(\.state)) {
                    ForEach(item.kind.states, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            if !item.kind.parentKinds.isEmpty {
                field(item.kind == .task ? "Belongs to" : "Feature") {
                    Picker("Parent", selection: binding(\.parent)) {
                        Text("None").tag(Int?.none)
                        ForEach(t.possibleParents(for: item.kind)) { p in Text("#\(p.id) \(p.title)").tag(Optional(p.id)) }
                    }
                    .labelsHidden()
                }
            }
            if t.useSprints, item.kind == .pbi || item.kind == .bug {
                field("Sprint") {
                    Picker("Sprint", selection: binding(\.sprint)) {
                        Text("None").tag("")
                        ForEach(t.sprints) { s in Text(s.name).tag(s.name) }
                    }
                    .labelsHidden()
                }
            }
            field("Assigned to") {
                TextField("Nobody", text: binding(\.assignee)).textFieldStyle(.roundedBorder)
            }
            if item.kind == .pbi || item.kind == .bug {
                field("Effort") {
                    TextField("Points", value: binding(\.effort), format: .number).textFieldStyle(.roundedBorder)
                }
            }
            field("Tags") {
                ListField(placeholder: "comma, separated", items: Binding(get: { draft?.tags ?? [] }, set: { draft?.tags = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func textArea(_ title: String, _ text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(prompt).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
            }
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        }
    }

    @ViewBuilder
    private func children(_ item: LocalTracker.Item, _ t: LocalTracker) -> some View {
        let kids = t.children(of: item.id).filter { $0.state != "Removed" }
        let childKind: LocalTracker.Kind = item.kind == .feature ? .pbi : .task
        VStack(alignment: .leading, spacing: 8) {
            Text(item.kind == .feature ? "PBIs and bugs" : "Tasks").font(.headline)
            ForEach(kids) { k in
                HStack(spacing: 8) {
                    if k.kind == .task {
                        Toggle(isOn: Binding(get: { k.state == "Done" }, set: { on in
                            model.editLocalTracker(scope) { $0.setState(k.id, on ? "Done" : "To Do") }
                        })) { EmptyView() }
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                    } else {
                        Image(systemName: k.kind.icon).foregroundStyle(k.kind.color)
                    }
                    Button { saveNow(); model.selectedLocalItem = k.id } label: {
                        Text(k.title).strikethrough(k.state == "Done", color: .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Chip(text: k.state, color: LocalItemRow.stateColor(k.state))
                }
            }
            HStack(spacing: 6) {
                TextField(item.kind == .feature ? "Add a PBI…" : "Add a task…", text: $newChild)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addChild(childKind, under: item.id) }
                Button("Add") { addChild(childKind, under: item.id) }
                    .disabled(newChild.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addChild(_ kind: LocalTracker.Kind, under parent: Int) {
        let title = newChild.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        saveNow()
        model.addLocalItem(scope, kind, title: title, parent: parent)
        newChild = ""
    }

    private func scheduleSave(_ d: LocalTracker.Item?) {
        guard let d, d != model.localTracker(scope).item(id) else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            model.editLocalTracker(scope) { $0.update(d) }
            saveTask = nil
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let d = draft, d != model.localTracker(scope).item(id) else { return }
        model.editLocalTracker(scope) { $0.update(d) }
    }
}

/// Turn sprints on or off and keep their dates.
struct LocalSprintsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let scope: String

    var body: some View {
        let t = model.localTracker(scope)
        VStack(alignment: .leading, spacing: 12) {
            Text("Sprints").font(.title3.weight(.semibold))
            Toggle("Plan work in sprints", isOn: Binding(get: { t.useSprints }, set: { on in
                model.editLocalTracker(scope) { $0.useSprints = on }
            }))
            if t.useSprints {
                List {
                    ForEach(t.sprints) { s in sprintRow(s) }
                }
                .frame(minHeight: 160)
                HStack {
                    Button("Add the Next Sprint") { addNext() }
                    Spacer()
                }
            } else {
                Text("Without sprints, the backlog and board show all open work.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func sprintRow(_ s: LocalTracker.Sprint) -> some View {
        HStack(spacing: 8) {
            Text(s.name).frame(minWidth: 80, alignment: .leading)
            DatePicker("", selection: date(s, \.start), displayedComponents: .date).labelsHidden()
            Text("–")
            DatePicker("", selection: date(s, \.finish), displayedComponents: .date).labelsHidden()
            Spacer(minLength: 0)
            Button { model.editLocalTracker(scope) { $0.sprints.removeAll { $0.name == s.name } } } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this sprint; its items keep their sprint name")
        }
    }

    private func date(_ s: LocalTracker.Sprint, _ key: WritableKeyPath<LocalTracker.Sprint, String>) -> Binding<Date> {
        Binding(get: { KBDate.parse(s[keyPath: key]) ?? Date() }, set: { d in
            model.editLocalTracker(scope) { t in
                if let i = t.sprints.firstIndex(where: { $0.name == s.name }) { t.sprints[i][keyPath: key] = KBDate.today(d) }
            }
        })
    }

    /// Two weeks after the last one, or from today.
    private func addNext() {
        model.editLocalTracker(scope) { t in
            let cal = Calendar.current
            let start = t.sprints.last.flatMap { KBDate.parse($0.finish) }.flatMap { cal.date(byAdding: .day, value: 1, to: $0) } ?? Date()
            let finish = cal.date(byAdding: .day, value: 13, to: start) ?? start
            t.sprints.append(.init(name: "Sprint \(t.sprints.count + 1)", start: KBDate.today(start), finish: KBDate.today(finish)))
        }
    }
}
