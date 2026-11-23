import KBCore
import SwiftUI

/// Proposed PBIs and bugs to create in Azure DevOps together, after a meeting or from the backlog.
struct BacklogBatchRequest: Identifiable, Equatable {
    let id = UUID()
    let entries: [EntryID]
    /// Shown under the title, e.g. the meeting's name.
    var context: String?
    /// People to offer first as assignee, e.g. the meeting's attendees.
    var people: [String] = []
}

/// One sheet for creating work items: each item with its sprint, assignee and parent, then Create or Not Now.
/// Not Now leaves them under the backlog's "Waiting to be created".
struct BacklogBatchCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: BacklogBatchRequest

    struct Item: Identifiable {
        let id: EntryID
        var include = true
        var title: String
        var kind: String
        var sprint: Sprint
        /// Empty: unassigned.
        var assignee: String
        var parent: String
        var result: Result?
    }

    enum Result {
        case creating
        case created(String, String)
        case failed(String)
    }

    @State private var items: [Item] = []
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(items.count == 1 ? "Create the work item" : "Create \(items.count) work items").font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($items) { $item in
                        ItemCard(item: $item, people: request.people, me: model.tracker?.me ?? "",
                                 sprintNames: sprintNames, prefix: prefix(item.id), locked: running || item.isDone)
                    }
                }
                .padding(18)
            }
            .frame(minHeight: 240, idealHeight: CGFloat(min(items.count, 3)) * 190 + 40, maxHeight: 620)
            Divider()
            HStack {
                if allDone {
                    Text(created == items.count ? "Created." : "\(created) created. The rest wait under Backlog → Waiting to be created.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Not Now keeps them under Backlog → Waiting to be created.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if allDone {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(running)
                    Button(createTitle) { create() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(running || toCreate.isEmpty || !trackerReady)
                }
            }
            .padding(16)
        }
        .frame(width: 620)
        .onAppear(perform: load)
    }

    private var subtitle: String {
        var s = "Pick the sprint and who it goes to. Untick what shouldn't be created yet."
        if let c = request.context { s = "From \(c). " + s }
        if !trackerReady { s += " The tracker settings are missing the organization or project." }
        return s
    }

    private var toCreate: [Item] { items.filter { $0.include && !$0.isDone } }
    private var created: Int { items.filter(\.isDone).count }
    private var allDone: Bool { !items.isEmpty && !running && items.allSatisfy { $0.isDone || $0.isFailed || !$0.include } && items.contains { $0.result != nil } }
    private var createTitle: String { toCreate.count == 1 ? "Create in Azure DevOps" : "Create \(toCreate.count) in Azure DevOps" }

    private var trackerReady: Bool {
        Set(items.map(\.id.project)).allSatisfy { p in
            let t = model.settings(for: p).tracker
            return t.kind == "azure-devops" && !t.organization.isEmpty && !t.project.isEmpty
        }
    }

    private var sprintNames: [Sprint: String] {
        var out: [Sprint: String] = [:]
        if let c = model.tracker?.sprint(.current) { out[.current] = c.name }
        if let n = model.tracker?.sprint(.next) { out[.next] = n.name }
        return out
    }

    private func prefix(_ id: EntryID) -> String { model.settings(for: id.project).tracker.titlePrefix }

    private func load() {
        guard items.isEmpty else { return }
        items = request.entries.compactMap { id in
            guard let e = model.index.entry(id), e.backlogStatus == .proposed else { return nil }
            let t = model.settings(for: id.project).tracker
            let assignee = e.field("assignee") ?? t.assignee
            return Item(id: id, title: e.title, kind: e.backlogKind ?? "pbi",
                        sprint: e.field("sprint").flatMap(Sprint.init(rawValue:)) ?? .current,
                        assignee: assignee == "none" ? "" : assignee,
                        parent: e.field("parent") ?? t.defaultParent)
        }
    }

    private func create() {
        running = true
        let root = model.rootURL
        let cli = model.cli
        let queue = toCreate
        Task {
            for item in queue {
                guard let i = items.firstIndex(where: { $0.id == item.id }) else { continue }
                items[i].result = .creating
                do {
                    var doc = try KBStore.load(item.id, root: root)
                    do {
                        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !title.isEmpty { doc.frontmatter.set("title", .string(title)) }
                        doc.frontmatter.set("sprint", .string(item.sprint.rawValue))
                        let who = item.assignee.trimmingCharacters(in: .whitespaces)
                        doc.frontmatter.set("assignee", .string(who.isEmpty ? "none" : who))
                        let parent = item.parent.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                        doc.frontmatter.set("parent", .string(parent.isEmpty ? "none" : parent))
                    }
                    if doc.isDirty { _ = try KBStore.save(&doc, root: root) }
                    let made = try await cli.createBacklog(item.id, sprint: item.sprint)
                    items[i].result = .created(made?.id ?? "", made?.url ?? "")
                } catch {
                    items[i].result = .failed(error.localizedDescription)
                }
            }
            running = false
            model.reload()
            model.refreshTracker(force: true)
        }
    }

    private struct ItemCard: View {
        @Binding var item: Item
        let people: [String]
        let me: String
        let sprintNames: [Sprint: String]
        let prefix: String
        let locked: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Toggle("", isOn: $item.include).labelsHidden().disabled(locked)
                    Text(item.kind == "bug" ? "Bug" : "PBI")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((item.kind == "bug" ? Color.red : Color.blue).opacity(0.15), in: Capsule())
                    if !prefix.isEmpty { Text(prefix).foregroundStyle(.secondary) }
                    TextField("Title", text: $item.title).textFieldStyle(.plain).font(.body.weight(.semibold)).disabled(locked)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Sprint").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Picker("Sprint", selection: $item.sprint) {
                                Text("Current").tag(Sprint.current)
                                Text("Next").tag(Sprint.next)
                                Text("None").tag(Sprint.none)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                            if let name = sprintNames[item.sprint] { Text(name).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    GridRow {
                        Text("Assignee").foregroundStyle(.secondary)
                        AssigneePicker(name: $item.assignee, me: me, people: people)
                    }
                    GridRow {
                        Text("Parent").foregroundStyle(.secondary)
                        TextField("work item number, optional", text: $item.parent).frame(width: 200)
                    }
                }
                .font(.callout)
                .disabled(locked || !item.include)
                .opacity(item.include ? 1 : 0.5)
                if let result = item.result { status(result) }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }

        @ViewBuilder
        private func status(_ r: Result) -> some View {
            switch r {
            case .creating:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Creating…").foregroundStyle(.secondary) }.font(.callout)
            case .created(let id, let url):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    if let link = URL(string: url), !id.isEmpty { Link("Created #\(id)", destination: link) } else { Text("Created") }
                }
                .font(.callout)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension BacklogBatchCreateSheet.Item {
    var isDone: Bool { if case .created = result { return true } else { return false } }
    var isFailed: Bool { if case .failed = result { return true } else { return false } }
}

/// Unassigned, me, the people offered first (attendees), or anyone in the directory by name.
struct AssigneePicker: View {
    @Environment(AppModel.self) private var model
    @Binding var name: String
    let me: String
    let people: [String]
    @State private var searching = false
    @State private var query = ""

    var body: some View {
        HStack(spacing: 6) {
            Menu(name.isEmpty ? "Unassigned" : (name == me ? "\(name) (me)" : name)) {
                Button("Unassigned") { name = "" }
                if !me.isEmpty { Button("\(me) (me)") { name = me } }
                let others = people.filter { $0 != me && !$0.isEmpty }
                if !others.isEmpty {
                    Section("In the meeting") {
                        ForEach(others, id: \.self) { p in Button(p) { name = p } }
                    }
                }
                Divider()
                Button("Someone Else…") { searching = true }
            }
            .fixedSize()
        }
        .popover(isPresented: $searching, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name or initials", text: $query).textFieldStyle(.roundedBorder).frame(width: 260)
                ForEach(model.people.search(query, limit: 8)) { p in
                    Button {
                        name = p.name
                        searching = false
                        query = ""
                    } label: {
                        HStack {
                            Text(p.name)
                            Spacer()
                            Text(p.initials).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }
}
