import KBCore
import KBEngine
import SwiftUI

/// Proposed PBIs and bugs to create in the tracker together, after a meeting or from the backlog.
struct BacklogBatchRequest: Identifiable, Equatable {
    let id = UUID()
    let entries: [EntryID]
    /// Shown under the title, e.g. the meeting's name.
    var context: String?
    /// People to offer first as assignee, e.g. the meeting's attendees.
    var people: [String] = []
}

/// One sheet for creating work items: each item with its sprint, assignee, parent and related items, then Create or
/// Not Now. A possible duplicate keeps its item from being created until the user drops it or says it isn't one.
/// Not Now leaves them under the backlog's "Suggested backlog items".
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
        /// Work item numbers and backlog entry ids.
        var related: [String]
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
                    let findings = model.duplicateFindings(for: items.compactMap { model.index.entry($0.id) })
                    ForEach($items) { $item in
                        let duplicate = item.isDone ? nil : findings[item.id].flatMap { $0.verdict == .none ? nil : $0 }
                        ItemCard(item: $item, single: items.count == 1, people: request.people, me: model.tracker?.me ?? "",
                                 sprintNames: sprintNames, prefix: prefix(item.id), locked: running || item.isDone,
                                 siblings: items.filter { $0.id != item.id }.map { ($0.id.rawValue, $0.title) },
                                 parentHint: model.index.entry(item.id).flatMap { model.inferredParent($0) },
                                 duplicate: duplicate)
                    }
                }
                .padding(18)
            }
            .frame(minHeight: 240, idealHeight: CGFloat(min(items.count, 3)) * 230 + 40, maxHeight: 620)
            Divider()
            HStack {
                if allDone {
                    Text(created == items.count ? "Created." : "\(created) created. The rest wait under Backlog → Suggested backlog items.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Not Now keeps them under Backlog → Suggested backlog items.")
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
        .task {
            for scope in Set(request.entries.map(\.project)) { model.checkDuplicates(scope: scope) }
        }
    }

    static func createLabel(_ kind: String) -> String { "Create in " + TrackerLink.name(kind) }

    private var subtitle: String {
        var s = items.count == 1 ? "Pick the sprint and who it goes to." : "Pick the sprint and who it goes to. Untick what shouldn't be created yet."
        if let c = request.context { s = "From \(c). " + s }
        if !trackerReady { s += " The tracker settings are missing the organization or project." }
        return s
    }

    private var toCreate: [Item] {
        items.filter {
            $0.include && !$0.isDone && model.index.entry($0.id)?.backlogStatus == .proposed && model.unresolvedDuplicate($0.id) == nil
        }
    }
    private var created: Int { items.filter(\.isDone).count }
    private var allDone: Bool { !items.isEmpty && !running && items.allSatisfy { $0.isDone || $0.isFailed || !$0.include } && items.contains { $0.result != nil } }
    private var createTitle: String {
        let kinds = Set(items.map { model.settings(for: $0.id.project).tracker.kind })
        let label = Self.createLabel(kinds.count == 1 ? kinds.first! : "azure-devops")
        if kinds.count > 1 { return toCreate.count == 1 ? "Create It" : "Create \(toCreate.count)" }
        return toCreate.count <= 1 ? label : label.replacingOccurrences(of: "Create", with: "Create \(toCreate.count)")
    }

    private var trackerReady: Bool {
        Set(items.map(\.id.project)).allSatisfy { p in
            let t = model.settings(for: p).tracker
            return t.kind == "local" || (t.kind == "azure-devops" && !t.organization.isEmpty && !t.project.isEmpty)
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
            let parent = WorkItemLinks.parentNumber(e.field("parent")).map(String.init)
                ?? model.inferredParent(e).map { String($0.number) }
                ?? (e.field("parent") == nil ? t.defaultParent : "")
            return Item(id: id, title: e.title, kind: e.backlogKind,
                        sprint: e.field("sprint").flatMap(Sprint.init(rawValue:)) ?? .current,
                        assignee: assignee == "none" ? "" : assignee,
                        parent: parent, related: WorkItemLinks.relatedValues(e.listField("related")))
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
                        doc.frontmatter.set("parent", .string(item.parentNumber.isEmpty ? "none" : item.parentNumber))
                        let related = WorkItemLinks.relatedValues(item.related)
                        doc.frontmatter.set("related", related.isEmpty ? nil : .list(related))
                    }
                    if doc.isDirty { _ = try KBStore.save(&doc, root: root) }
                    let made = try await cli.createBacklog(item.id, sprint: item.sprint, parent: item.parentNumber)
                    items[i].result = .created(made?.id ?? "", made?.url ?? "")
                } catch {
                    items[i].result = .failed(error.localizedDescription)
                }
            }
            running = false
            model.reload()
            model.refreshTracker(force: true)
            let made = items.filter(\.isDone)
            if !made.isEmpty, !items.contains(where: { $0.include && !$0.isDone }) {
                let numbers = made.compactMap { if case .created(let id, _) = $0.result, !id.isEmpty { return "#" + id } else { return nil } }
                model.notice = made.count == 1 ? "Created \(numbers.first ?? "the work item")." : "Created \(numbers.joined(separator: ", "))."
                dismiss()
            }
        }
    }

    private struct ItemCard: View {
        @Environment(AppModel.self) private var model
        @Binding var item: Item
        /// The only item in the sheet: nothing to untick.
        let single: Bool
        let people: [String]
        let me: String
        let sprintNames: [Sprint: String]
        let prefix: String
        let locked: Bool
        /// The other items in this sheet, as (entry id, title).
        let siblings: [(String, String)]
        let parentHint: (number: Int, from: String)?
        let duplicate: DuplicateFinding?
        /// Titles of the work items shown as parent or related, as the tracker search found them.
        @State private var titles: [Int: String] = [:]

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                if let duplicate, let entry = model.index.entry(item.id) {
                    DuplicateBox(entry: entry, finding: duplicate)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !single {
                        Toggle("", isOn: $item.include).labelsHidden().disabled(locked || duplicate != nil)
                            .help("Untick to leave it out of this batch")
                    }
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
                    GridRow(alignment: .top) {
                        Text("Parent").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            if let number = Int(item.parentNumber) {
                                LinkedItemChip(label: label(String(number)), help: "No parent") { item.parent = "" }
                            } else {
                                WorkItemSearchField(scope: item.id.project, prompt: "Search by id or title, optional") { found in
                                    titles[found.id] = found.title
                                    item.parent = String(found.id)
                                }
                            }
                            if let hint = parentHint, String(hint.number) != item.parentNumber {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    Text("\(hint.from.prefix(1).uppercased() + hint.from.dropFirst()) names #\(hint.number) as the parent.")
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button("Use #\(hint.number)") { item.parent = String(hint.number) }.buttonStyle(.link)
                                }
                                .font(.caption)
                            } else if let hint = parentHint, String(hint.number) == item.parentNumber {
                                Text("Read from \(hint.from).").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    GridRow(alignment: .top) {
                        Text("Related").foregroundStyle(.secondary)
                        relatedEditor
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

        private var relatedEditor: some View {
            VStack(alignment: .leading, spacing: 4) {
                if !item.related.isEmpty {
                    ChipRow(spacing: 4) {
                        ForEach(item.related, id: \.self) { r in
                            LinkedItemChip(label: label(r), help: "Don't link it") { item.related.removeAll { $0 == r } }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    WorkItemSearchField(scope: item.id.project, exclude: Set(item.related.compactMap(Int.init))) { found in
                        titles[found.id] = found.title
                        if !item.related.contains(String(found.id)) { item.related.append(String(found.id)) }
                    }
                    let others = siblings.filter { !item.related.contains($0.0) }
                    if !others.isEmpty {
                        Menu("This Batch") {
                            ForEach(others, id: \.0) { s in Button(s.1) { item.related.append(s.0) } }
                        }
                        .fixedSize()
                        .help("Link it with another item created here, e.g. the other platform's")
                    }
                }
            }
            .task(id: item.related.joined(separator: ",") + "|" + item.parentNumber) { await loadTitles() }
        }

        private func label(_ r: String) -> String {
            if let n = Int(r) { return titles[n].map { "#\(n) \(AppModel.shortTitle($0))" } ?? "#\(n)" }
            if let s = siblings.first(where: { $0.0 == r }) { return AppModel.shortTitle(s.1) }
            return AppModel.shortTitle(EntryID(r).flatMap { model.index.entry($0) }?.title ?? r)
        }

        /// Looks up the titles of numbers that came with the entry, so they show as "#123 Title".
        private func loadTitles() async {
            let numbers = (item.related + [item.parentNumber]).compactMap(Int.init).filter { titles[$0] == nil }
            for n in numbers {
                guard let found = try? await model.cli.trackerFind(String(n), scope: item.id.project, limit: 1),
                      let hit = found.first(where: { $0.id == n }) else { continue }
                titles[n] = hit.title
            }
        }

        @ViewBuilder
        private func status(_ r: Result) -> some View {
            switch r {
            case .creating:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Creating…").foregroundStyle(.secondary) }.font(.callout)
            case .created(let id, let url):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    if url.hasPrefix("http"), let link = URL(string: url), !id.isEmpty {
                        Link("Created #\(id)", destination: link)
                    } else {
                        Text(id.isEmpty ? "Created" : "Created #\(id)")
                    }
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
    /// The parent as the CLI takes it: digits, or empty for none.
    var parentNumber: String { parent.filter(\.isNumber) }
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

/// A linked work item or entry with a remove button.
struct LinkedItemChip: View {
    let label: String
    let help: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(label).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .help(help)
        }
        .font(.caption)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.teal.opacity(0.14), in: Capsule())
    }
}
