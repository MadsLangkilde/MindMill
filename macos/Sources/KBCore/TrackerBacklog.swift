import Foundation

/// `kb tracker backlog --json`: every open PBI and bug in the trackers, and the ones done lately.
public struct TrackerBacklog: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case notStarted = "not_started", inProgress = "in_progress", inPR = "in_pr", resolved, done

        public var title: String {
            switch self {
            case .notStarted: return "Not started"
            case .inProgress: return "In progress"
            case .inPR: return "In PR"
            case .resolved: return "Resolved"
            case .done: return "Done"
            }
        }

        /// 0 to 1 along the way from New to Done.
        public var fraction: Double {
            switch self {
            case .notStarted: return 0
            case .inProgress: return 0.4
            case .inPR: return 0.7
            case .resolved: return 0.85
            case .done: return 1
            }
        }
    }

    /// A child task of a PBI or bug.
    public struct Task: Codable, Equatable, Sendable, Identifiable, Hashable {
        public var id: Int
        public var title: String
        public var state: String
        public var assignee: String

        public init(id: Int, title: String, state: String, assignee: String = "") {
            self.id = id
            self.title = title
            self.state = state
            self.assignee = assignee
        }

        public var isDone: Bool { ["done", "closed"].contains(state.lowercased()) }
        public var isInProgress: Bool { state.lowercased() == "in progress" }
    }

    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        public var type: String
        public var title: String
        public var state: String
        public var stage: Stage
        public var scope: String
        public var scopes: [String]
        public var tags: [String]
        public var assignee: String
        public var mine: Bool
        public var sprint: String
        public var changed: String
        public var url: String
        public var prs: [Int]
        public var tasksDone: Int
        public var tasksTotal: Int
        public var tasks: [Task]

        enum CodingKeys: String, CodingKey {
            case id, type, title, state, stage, scope, scopes, tags, assignee, mine, sprint, changed, url, prs, tasks
            case tasksDone = "tasks_done", tasksTotal = "tasks_total"
        }

        public init(id: Int, type: String = "pbi", title: String, state: String = "New", stage: Stage = .notStarted,
                    scope: String, scopes: [String]? = nil, tags: [String] = [], assignee: String = "", mine: Bool = false,
                    sprint: String = "", changed: String = "", url: String = "", prs: [Int] = [], tasksDone: Int = 0, tasksTotal: Int = 0,
                    tasks: [Task] = []) {
            self.id = id
            self.type = type
            self.title = title
            self.state = state
            self.stage = stage
            self.scope = scope
            self.scopes = scopes ?? [scope]
            self.tags = tags
            self.assignee = assignee
            self.mine = mine
            self.sprint = sprint
            self.changed = changed
            self.url = url
            self.prs = prs
            self.tasksDone = tasksDone
            self.tasksTotal = tasks.isEmpty ? tasksTotal : tasks.count
            self.tasks = tasks
            if !tasks.isEmpty { self.tasksDone = tasks.filter(\.isDone).count }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? "pbi"
            title = try c.decode(String.self, forKey: .title)
            state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
            stage = (try? c.decode(Stage.self, forKey: .stage)) ?? .inProgress
            scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
            scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? [scope]
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            assignee = try c.decodeIfPresent(String.self, forKey: .assignee) ?? ""
            mine = try c.decodeIfPresent(Bool.self, forKey: .mine) ?? false
            sprint = try c.decodeIfPresent(String.self, forKey: .sprint) ?? ""
            changed = try c.decodeIfPresent(String.self, forKey: .changed) ?? ""
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
            prs = try c.decodeIfPresent([Int].self, forKey: .prs) ?? []
            tasksDone = try c.decodeIfPresent(Int.self, forKey: .tasksDone) ?? 0
            tasksTotal = try c.decodeIfPresent(Int.self, forKey: .tasksTotal) ?? 0
            tasks = try c.decodeIfPresent([Task].self, forKey: .tasks) ?? []
        }

        public var isBug: Bool { type == "bug" }
        public var isUnassigned: Bool { assignee.isEmpty }
        public var sprintName: String { sprint.split(separator: "\\").last.map(String.init) ?? sprint }
        public var sessionKey: String { "wi:\(id)" }

        public var openTasks: [Task] { tasks.filter { !$0.isDone } }
        public var tasksInProgress: Int { tasks.filter(\.isInProgress).count }
        /// Nobody has started it, so a new implementation can begin.
        public var canStart: Bool { stage == .notStarted }
        public var isFinished: Bool { stage == .resolved || stage == .done }
        /// Resolved or done, but some of its tasks are still open.
        public var hasLooseTasks: Bool { isFinished && !openTasks.isEmpty }
        /// Not Done yet: what moving a sprint's leftovers takes along.
        public var isUnfinished: Bool { stage != .done }
        /// Something is left to do: the item itself, or tasks under a finished one.
        public var needsAttention: Bool { isUnfinished || hasLooseTasks }
    }

    /// A state a PBI or bug can be set to, and what kind of state it is in Azure DevOps.
    public struct WorkState: Codable, Equatable, Sendable, Hashable {
        public var name: String
        /// Proposed, InProgress, Resolved, Completed or Removed.
        public var category: String

        public init(name: String, category: String) {
            self.name = name
            self.category = category
        }

        public var stage: Stage? {
            switch category {
            case "Proposed": return .notStarted
            case "InProgress": return .inProgress
            case "Resolved": return .resolved
            case "Completed": return .done
            default: return nil
            }
        }

        public var isRemoved: Bool { category == "Removed" }

        /// The Scrum process's states, for when the tracker didn't say.
        public static let scrum: [WorkState] = [
            .init(name: "New", category: "Proposed"), .init(name: "Approved", category: "Proposed"),
            .init(name: "Committed", category: "InProgress"), .init(name: "Done", category: "Completed"),
            .init(name: "Removed", category: "Removed"),
        ]
    }

    public enum Owner: String, CaseIterable, Sendable {
        case me, others, nobody

        public var title: String {
            switch self {
            case .me: return "Assigned to me"
            case .others: return "Assigned to others"
            case .nobody: return "Not assigned"
            }
        }
    }

    public struct Sprint: Codable, Equatable, Sendable, Hashable {
        public var name: String
        public var path: String
        public var start: String
        public var finish: String
        /// past, current or future
        public var when: String

        public init(name: String, path: String, start: String = "", finish: String = "", when: String) {
            self.name = name
            self.path = path
            self.start = start
            self.finish = finish
            self.when = when
        }
    }

    /// Which sprint the backlog shows, relative to today.
    public enum SprintFilter: String, CaseIterable, Sendable {
        case all, previous, current, next, none

        public var title: String {
            switch self {
            case .all: return "All sprints"
            case .previous: return "Previous sprint"
            case .current: return "Current sprint"
            case .next: return "Next sprint"
            case .none: return "No sprint"
            }
        }
    }

    public var fetched: String
    public var me: String
    public var items: [Item]
    public var sprints: [String: String]
    /// The iteration roots' sprints, oldest first.
    public var sprintList: [Sprint]?
    /// The states PBIs (`pbi`) and bugs (`bug`) can have, in workflow order.
    public var states: [String: [WorkState]]?

    enum CodingKeys: String, CodingKey {
        case fetched, me, items, sprints, states
        case sprintList = "sprint_list"
    }

    /// The sprint `filter` names: the one running today, the one before it, or the one after it.
    public func sprint(_ filter: SprintFilter) -> Sprint? {
        let list = sprintList ?? []
        let current = list.firstIndex { $0.when == "current" }
        switch filter {
        case .current: return current.map { list[$0] }
        case .previous:
            if let c = current { return c > 0 ? list[c - 1] : nil }
            return list.last { $0.when == "past" }
        case .next:
            if let c = current { return c + 1 < list.count ? list[c + 1] : nil }
            return list.first { $0.when == "future" }
        case .all, .none: return nil
        }
    }

    public func matches(_ item: Item, _ filter: SprintFilter) -> Bool {
        switch filter {
        case .all: return true
        case .none: return !(sprintList ?? []).contains { $0.path == item.sprint }
        default: return sprint(filter).map { $0.path == item.sprint } ?? false
        }
    }

    public init(fetched: String = "", me: String = "", items: [Item] = [], sprints: [String: String] = [:],
                sprintList: [Sprint]? = nil, states: [String: [WorkState]]? = nil) {
        self.fetched = fetched
        self.me = me
        self.items = items
        self.sprints = sprints
        self.sprintList = sprintList
        self.states = states
    }

    public static func decode(_ json: String) throws -> TrackerBacklog {
        try JSONDecoder().decode(TrackerBacklog.self, from: Data(json.utf8))
    }

    /// Items belonging to any of `scopes`, most advanced first, then most recently changed.
    public func items(in scopes: Set<String>) -> [Item] {
        items.filter { !scopes.isDisjoint(with: $0.scopes) }.sorted { a, b in
            if a.stage != b.stage { return a.stage.fraction > b.stage.fraction }
            return a.changed > b.changed
        }
    }

    public static func owner(_ item: Item) -> Owner {
        item.mine ? .me : item.isUnassigned ? .nobody : .others
    }

    public func item(_ id: Int) -> Item? { items.first { $0.id == id } }

    /// The order Backlog lists stages in: what can be started first, then work under way, then finished.
    public static let listOrder: [Stage] = [.notStarted, .inProgress, .inPR, .resolved]

    /// The work item with these tasks set to `state`, as Azure DevOps will have it after the change.
    public func settingTasks(_ ids: Set<Int>, to state: String) -> TrackerBacklog {
        var copy = self
        copy.items = items.map { item in
            guard item.tasks.contains(where: { ids.contains($0.id) }) else { return item }
            var i = item
            i.tasks = item.tasks.map { t in ids.contains(t.id) ? Task(id: t.id, title: t.title, state: state, assignee: t.assignee) : t }
            i.tasksDone = i.tasks.filter(\.isDone).count
            return i
        }
        return copy
    }

    /// The pills Backlog shows: past sprints with something left to do in `items`, the current and next
    /// sprint, and later ones with work planned. Oldest first.
    public func shownSprints(for items: [Item]) -> [Sprint] {
        let list = sprintList ?? []
        let next = sprint(.next)?.path
        return list.filter { sp in
            switch sp.when {
            case "current": return true
            case "past": return items.contains { $0.sprint == sp.path && $0.needsAttention }
            default: return sp.path == next || items.contains { $0.sprint == sp.path }
            }
        }
    }

    /// Past sprints Backlog leaves out because nothing in them is left to do, newest first.
    public func olderSprints(for items: [Item]) -> [Sprint] {
        let shown = Set(shownSprints(for: items).map(\.path))
        return (sprintList ?? []).filter { $0.when == "past" && !shown.contains($0.path) }.reversed()
    }

    public func sprint(path: String) -> Sprint? { sprintList?.first { $0.path == path } }

    /// The sprint running now for this scope's iteration root, or the first one running anywhere.
    public func currentSprint(scope: String) -> Sprint? {
        sprints[scope].flatMap { sprint(path: $0) } ?? sprint(.current)
    }

    /// The sprints a work item can be moved to: the current one and those after it, under the same root.
    public func moveTargets(for item: Item) -> [Sprint] {
        let list = (sprintList ?? []).filter { $0.when != "past" }
        guard let current = currentSprint(scope: item.scope) else { return list }
        let parent = current.path.split(separator: "\\").dropLast().joined(separator: "\\")
        return list.filter { $0.path.split(separator: "\\").dropLast().joined(separator: "\\") == parent }
    }

    public func states(for item: Item) -> [WorkState] {
        let known = states?[item.isBug ? "bug" : "pbi"] ?? []
        return known.isEmpty ? WorkState.scrum : known
    }

    /// The items as Azure DevOps will have them after moving `ids` to the sprint at `path`.
    public func moving(_ ids: Set<Int>, to path: String) -> TrackerBacklog {
        var copy = self
        copy.items = items.map { item in
            guard ids.contains(item.id) else { return item }
            var i = item
            i.sprint = path
            return i
        }
        return copy
    }

    /// The items as Azure DevOps will have them after setting `ids` to `state`. Removed ones drop out.
    public func setting(_ ids: Set<Int>, to state: WorkState) -> TrackerBacklog {
        var copy = self
        copy.items = items.compactMap { item in
            guard ids.contains(item.id) else { return item }
            if state.isRemoved { return nil }
            var i = item
            i.state = state.name
            if let stage = state.stage { i.stage = stage }
            return i
        }
        return copy
    }

    /// `base` with the items of `extra` it doesn't have, such as a past sprint's finished work read separately.
    public static func merge(_ base: [Item], _ extra: [Item]) -> [Item] {
        let known = Set(base.map(\.id))
        return base + extra.filter { !known.contains($0.id) }
    }

    public func isInCurrentSprint(_ item: Item) -> Bool {
        guard let current = sprints[item.scope] ?? sprints.values.first else { return false }
        return item.sprint == current
    }
}

extension TrackerBacklog.Item {
    /// The same work item as My Work sees it, for starting a session on it.
    public var asMyWork: MyWork.Item {
        let stage: MyWork.Stage
        switch self.stage {
        case .notStarted: stage = .notStarted
        case .inProgress: stage = .inProgress
        case .inPR: stage = .inPR
        case .resolved, .done: stage = .resolved
        }
        return MyWork.Item(id: id, type: type, title: title, state: state, sprint: sprint, project: scope, url: url, stage: stage, prs: [])
    }
}
