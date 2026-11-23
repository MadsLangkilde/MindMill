import Foundation

/// Mindmill's own work tracker for a scope that doesn't use Azure DevOps or Jira: features, PBIs, bugs and tasks, with
/// optional sprints, kept in `<scope>/work.json`. The `kb work` CLI reads and writes the same file; keys the app
/// doesn't know are kept when it saves.
public struct LocalTracker: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case feature, pbi, bug, task

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .feature: return "Feature"
            case .pbi: return "Product Backlog Item"
            case .bug: return "Bug"
            case .task: return "Task"
            }
        }

        public var short: String { self == .pbi ? "PBI" : title }

        public var icon: String {
            switch self {
            case .feature: return "trophy"
            case .pbi: return "doc.text"
            case .bug: return "ladybug"
            case .task: return "checklist"
            }
        }

        /// The states it moves through, in board order; Removed is left off the board.
        public var states: [String] {
            self == .task ? ["To Do", "In Progress", "Done", "Removed"] : ["New", "Approved", "Committed", "Done", "Removed"]
        }

        public var parentKinds: [Kind] {
            switch self {
            case .feature: return []
            case .pbi, .bug: return [.feature]
            case .task: return [.pbi, .bug]
            }
        }
    }

    public struct Sprint: Equatable, Sendable, Hashable, Identifiable {
        public var name: String
        public var start: String
        public var finish: String

        public var id: String { name }

        public init(name: String, start: String, finish: String) {
            self.name = name
            self.start = start
            self.finish = finish
        }

        public func contains(_ day: String) -> Bool { start <= day && day <= finish }
    }

    public struct Item: Equatable, Sendable, Identifiable {
        public var id: Int
        public var kind: Kind
        public var title: String
        public var state: String
        public var parent: Int?
        public var sprint: String
        public var assignee: String
        public var tags: [String]
        public var description: String
        public var acceptance: String
        public var repro: String
        public var effort: Double?
        public var order: Double
        public var created: String
        public var changed: String
        var extra: [String: AnyHashableSendable] = [:]

        public init(id: Int, kind: Kind, title: String, state: String? = nil, parent: Int? = nil, sprint: String = "",
                    assignee: String = "", tags: [String] = [], description: String = "", acceptance: String = "",
                    repro: String = "", effort: Double? = nil, order: Double = 0, created: String = "", changed: String = "") {
            self.id = id
            self.kind = kind
            self.title = title
            self.state = state ?? kind.states[0]
            self.parent = parent
            self.sprint = sprint
            self.assignee = assignee
            self.tags = tags
            self.description = description
            self.acceptance = acceptance
            self.repro = repro
            self.effort = effort
            self.order = order
            self.created = created
            self.changed = changed
        }

        public var isOpen: Bool { state != "Done" && state != "Removed" }

        public static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.kind == b.kind && a.title == b.title && a.state == b.state && a.parent == b.parent
                && a.sprint == b.sprint && a.assignee == b.assignee && a.tags == b.tags && a.description == b.description
                && a.acceptance == b.acceptance && a.repro == b.repro && a.effort == b.effort && a.order == b.order
                && a.created == b.created && a.changed == b.changed
        }
    }

    public var nextID = 1
    public var useSprints = false
    public var sprints: [Sprint] = []
    public var items: [Item] = []
    var raw: [String: AnyHashableSendable] = [:]

    public init() {}

    public static func == (a: LocalTracker, b: LocalTracker) -> Bool {
        a.nextID == b.nextID && a.useSprints == b.useSprints && a.sprints == b.sprints && a.items == b.items
    }

    // MARK: File

    public static func url(scope: String, root: URL) -> URL {
        KBLayout.of(root: root).privateDir(scope).appendingPathComponent("work.json")
    }

    public static func load(scope: String, root: URL) -> LocalTracker {
        guard let data = try? Data(contentsOf: url(scope: scope, root: root)) else { return LocalTracker() }
        return parse(data)
    }

    public static func parse(_ data: Data) -> LocalTracker {
        var t = LocalTracker()
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return t }
        t.raw = json.mapValues(AnyHashableSendable.init)
        t.nextID = (json["next_id"] as? NSNumber)?.intValue ?? 1
        t.useSprints = json["use_sprints"] as? Bool ?? false
        t.sprints = (json["sprints"] as? [[String: Any]] ?? []).map {
            Sprint(name: $0["name"] as? String ?? "", start: $0["start"] as? String ?? "", finish: $0["finish"] as? String ?? "")
        }
        t.items = (json["items"] as? [[String: Any]] ?? []).compactMap { d in
            guard let id = (d["id"] as? NSNumber)?.intValue, let kind = Kind(rawValue: d["type"] as? String ?? "") else { return nil }
            var item = Item(id: id, kind: kind, title: d["title"] as? String ?? "", state: d["state"] as? String,
                            parent: (d["parent"] as? NSNumber)?.intValue, sprint: d["sprint"] as? String ?? "",
                            assignee: d["assignee"] as? String ?? "", tags: d["tags"] as? [String] ?? [],
                            description: d["description"] as? String ?? "", acceptance: d["acceptance"] as? String ?? "",
                            repro: d["repro"] as? String ?? "", effort: (d["effort"] as? NSNumber)?.doubleValue,
                            order: (d["order"] as? NSNumber)?.doubleValue ?? Double(id),
                            created: d["created"] as? String ?? "", changed: d["changed"] as? String ?? "")
            let known: Set<String> = ["id", "type", "title", "state", "parent", "sprint", "assignee", "tags", "description",
                                      "acceptance", "repro", "effort", "order", "created", "changed"]
            item.extra = d.filter { !known.contains($0.key) }.mapValues(AnyHashableSendable.init)
            return item
        }
        t.nextID = max(t.nextID, (t.items.map(\.id).max() ?? 0) + 1)
        return t
    }

    public func serialized() throws -> Data {
        var json = raw.mapValues(\.value)
        json["version"] = json["version"] ?? 1
        json["next_id"] = nextID
        json["use_sprints"] = useSprints
        json["sprints"] = sprints.map { ["name": $0.name, "start": $0.start, "finish": $0.finish] }
        json["items"] = items.map { i -> [String: Any] in
            var d = i.extra.mapValues(\.value)
            d["id"] = i.id
            d["type"] = i.kind.rawValue
            d["title"] = i.title
            d["state"] = i.state
            d["parent"] = i.parent.map { $0 as Any } ?? NSNull()
            d["sprint"] = i.sprint
            d["assignee"] = i.assignee
            d["tags"] = i.tags
            d["description"] = i.description
            d["acceptance"] = i.acceptance
            d["repro"] = i.repro
            d["effort"] = i.effort.map { $0 as Any } ?? NSNull()
            d["order"] = i.order
            d["created"] = i.created
            d["changed"] = i.changed
            return d
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public func save(scope: String, root: URL) throws {
        let u = Self.url(scope: scope, root: root)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialized().write(to: u, options: .atomic)
    }

    // MARK: Reading

    public func item(_ id: Int?) -> Item? { id.flatMap { id in items.first { $0.id == id } } }

    public func children(of id: Int?) -> [Item] {
        items.filter { $0.parent == id }.sorted { $0.order < $1.order }
    }

    public func currentSprint(today: String) -> Sprint? { sprints.first { $0.contains(today) } }

    /// Parents an item of `kind` may have: the open ones of the kinds above it.
    public func possibleParents(for kind: Kind) -> [Item] {
        items.filter { kind.parentKinds.contains($0.kind) && $0.state != "Removed" }.sorted { $0.order < $1.order }
    }

    /// Tasks done out of all, for a PBI or bug's progress.
    public func taskProgress(_ id: Int) -> (done: Int, total: Int) {
        let tasks = items.filter { $0.parent == id && $0.kind == .task && $0.state != "Removed" }
        return (tasks.filter { $0.state == "Done" }.count, tasks.count)
    }

    // MARK: Changing

    public static func now(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Adds an item last among its siblings; returns its id.
    @discardableResult
    public mutating func add(_ kind: Kind, title: String, parent: Int? = nil, sprint: String = "", now: String = LocalTracker.now()) -> Int {
        let id = nextID
        nextID += 1
        let last = children(of: parent).map(\.order).max() ?? 0
        items.append(Item(id: id, kind: kind, title: title, parent: kind.parentKinds.isEmpty ? nil : parent, sprint: sprint,
                          order: last + 1, created: now, changed: now))
        return id
    }

    public mutating func update(_ item: Item, now: String = LocalTracker.now()) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        var next = item
        if next != items[i] { next.changed = now }
        items[i] = next
    }

    public mutating func setState(_ id: Int, _ state: String, now: String = LocalTracker.now()) {
        guard var item = item(id), item.kind.states.contains(state) else { return }
        item.state = state
        update(item, now: now)
    }

    /// Deletes an item and everything under it.
    public mutating func delete(_ id: Int) {
        let kids = items.filter { $0.parent == id }.map(\.id)
        for k in kids { delete(k) }
        items.removeAll { $0.id == id }
    }

    /// Moves an item to sit before `before` among its siblings (or last when nil).
    public mutating func reorder(_ id: Int, before: Int?) {
        guard let moving = item(id) else { return }
        let siblings = children(of: moving.parent).filter { $0.id != id }
        let orders = siblings.map(\.order)
        let at = before.flatMap { b in siblings.firstIndex { $0.id == b } } ?? siblings.count
        let below = at > 0 ? orders[at - 1] : (orders.first ?? 1) - 1
        let above = at < orders.count ? orders[at] : (orders.last ?? 0) + 1
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].order = (below + above) / 2 }
    }

    /// The backlog as indented rows: features with their PBIs and bugs, each with its tasks, then PBIs and bugs in no
    /// feature. `sprint` keeps PBIs and bugs of that sprint ("" for none, nil for all) and the features above them;
    /// done and removed items show only with `showDone`.
    public func tree(sprint: String?, showDone: Bool) -> [(item: Item, depth: Int)] {
        func shown(_ i: Item) -> Bool { i.state != "Removed" && (showDone || i.state != "Done") }
        func work(_ i: Item) -> Bool { shown(i) && (sprint == nil || i.sprint == sprint) }
        var out: [(item: Item, depth: Int)] = []
        func addWork(_ w: Item, depth: Int) {
            out.append((w, depth))
            for task in children(of: w.id) where task.kind == .task && shown(task) { out.append((task, depth + 1)) }
        }
        for f in children(of: nil) where f.kind == .feature && shown(f) {
            let kids = children(of: f.id).filter { $0.kind != .task && work($0) }
            if sprint != nil && kids.isEmpty { continue }
            out.append((f, 0))
            for k in kids { addWork(k, depth: 1) }
        }
        for w in children(of: nil) where w.kind != .feature && w.kind != .task && work(w) { addWork(w, depth: 0) }
        return out
    }

    /// The board's columns: a PBI or bug's states without Removed.
    public static let boardStates = ["New", "Approved", "Committed", "Done"]

    /// The PBIs and bugs on the board, for a sprint when sprints are used (empty: every open one not done long ago).
    public func boardItems(sprint: String?) -> [Item] {
        items.filter { ($0.kind == .pbi || $0.kind == .bug) && $0.state != "Removed" && (sprint == nil || $0.sprint == sprint) }
            .sorted { $0.order < $1.order }
    }

    /// A PBI or bug as My Work and Implement know work items.
    public func asMyWork(_ item: Item, scope: String) -> MyWork.Item {
        let stage: MyWork.Stage
        switch item.state {
        case "New", "Approved": stage = .notStarted
        case "Done", "Removed": stage = .resolved
        default: stage = .inProgress
        }
        return MyWork.Item(id: item.id, type: item.kind == .bug ? "bug" : "pbi", title: item.title, state: item.state,
                           sprint: item.sprint, project: scope, url: "", stage: stage, prs: [])
    }

    /// The text an implementing session gets: the item with its description, acceptance criteria and tasks.
    public func brief(_ item: Item) -> String {
        var out = "\(item.kind.short) #\(item.id) in Mindmill's own tracker: \(item.title)\n"
        if let p = self.item(item.parent) { out += "Part of feature #\(p.id): \(p.title)\n" }
        if !item.description.isEmpty { out += "\n## Description\n\n\(item.description)\n" }
        if item.kind == .bug, !item.repro.isEmpty { out += "\n## Steps to reproduce\n\n\(item.repro)\n" }
        if !item.acceptance.isEmpty { out += "\n## Acceptance criteria\n\n\(item.acceptance)\n" }
        let tasks = children(of: item.id).filter { $0.kind == .task && $0.state != "Removed" }
        if !tasks.isEmpty { out += "\n## Tasks\n\n" + tasks.map { "- #\($0.id) \($0.title) (\($0.state))" }.joined(separator: "\n") + "\n" }
        return out
    }
}
