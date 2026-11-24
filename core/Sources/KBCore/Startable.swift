import Foundation

/// Which work Build's "Ready to Start" shows: whose, and which kinds. Remembered per scope.
public struct WorkFilter: Codable, Equatable, Sendable {
    public enum Owner: String, Codable, CaseIterable, Sendable {
        case me, meAndUnassigned, everyone

        public var title: String {
            switch self {
            case .me: return "Assigned to me"
            case .meAndUnassigned: return "Me + unassigned"
            case .everyone: return "Everyone"
            }
        }

        public func accepts(mine: Bool, unassigned: Bool) -> Bool {
            switch self {
            case .me: return mine
            case .meAndUnassigned: return mine || unassigned
            case .everyone: return true
            }
        }
    }

    public var owner: Owner = .me
    public var pbis = true
    public var bugs = true
    public var tasks = false

    public init(owner: Owner = .me, pbis: Bool = true, bugs: Bool = true, tasks: Bool = false) {
        self.owner = owner
        self.pbis = pbis
        self.bugs = bugs
        self.tasks = tasks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = (try? c.decode(Owner.self, forKey: .owner)) ?? .me
        pbis = try c.decodeIfPresent(Bool.self, forKey: .pbis) ?? true
        bugs = try c.decodeIfPresent(Bool.self, forKey: .bugs) ?? true
        tasks = try c.decodeIfPresent(Bool.self, forKey: .tasks) ?? false
    }

    public static func key(scope: String) -> String { "readyFilter.\(scope)" }

    public static func load(scope: String, defaults: UserDefaults = .standard) -> WorkFilter {
        defaults.data(forKey: key(scope: scope)).flatMap { try? JSONDecoder().decode(WorkFilter.self, from: $0) } ?? WorkFilter()
    }

    public func save(scope: String, defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key(scope: scope)) }
    }

    /// The filter a factory's rules amount to, so Build shows what the factory would take.
    public static func of(_ rules: FactoryRules) -> WorkFilter {
        WorkFilter(owner: rules.unassigned ? .meAndUnassigned : .me, pbis: rules.pbis, bugs: rules.bugs, tasks: false)
    }
}

/// Something in the current sprint that can be started now: a PBI or bug nobody has started, or a task still to do
/// under one that isn't finished. Neither has a session working on it yet.
public struct StartableWork: Equatable, Sendable, Identifiable {
    public var item: TrackerBacklog.Item
    /// Set when this is one of the item's tasks rather than the item itself.
    public var task: TrackerBacklog.Task?
    public var mine: Bool

    public var id: String { sessionKey }
    public var number: Int { task?.id ?? item.id }
    public var title: String { task?.title ?? item.title }
    public var state: String { task?.state ?? item.state }
    public var assignee: String { task?.assignee ?? item.assignee }
    public var kind: String { task == nil ? item.type : "task" }
    public var isUnassigned: Bool { assignee.isEmpty }
    /// The key a Build session working on it carries in `about`.
    public var sessionKey: String { "wi:\(number)" }

    /// As My Work and Implement know work items, so Start runs the usual implement path.
    public var asMyWork: MyWork.Item {
        guard let task else { return item.asMyWork }
        return MyWork.Item(id: task.id, type: "task", title: task.title, state: task.state, sprint: item.sprint,
                           project: item.scope, url: "", stage: .notStarted, prs: [])
    }
}

public enum Startable {
    /// Task states nobody has started: To Do in Scrum and Basic, New in Agile and CMMI.
    public static let unstartedTaskStates: Set<String> = ["to do", "new", "proposed"]

    /// Whether the item is the user's: the tracker says so, or its assignee is one of the names the user goes by.
    public static func isMine(_ assignee: String, flagged: Bool = false, me: [String]) -> Bool {
        flagged || (!assignee.isEmpty && me.contains { $0.caseInsensitiveCompare(assignee) == .orderedSame })
    }

    /// In the sprint running now for its scope. A scope whose tracker has no sprints (or none running) has no
    /// "current sprint" to hold to, so everything in it counts.
    public static func inCurrentSprint(_ item: TrackerBacklog.Item, _ backlog: TrackerBacklog) -> Bool {
        let known = ([item.scope] + item.scopes).compactMap { backlog.sprints[$0] }
        guard !known.isEmpty else { return true }
        return known.contains(item.sprint)
    }

    /// What can be started now in `scopes`, best first: the user's, then unassigned, then the rest; PBIs and bugs
    /// before tasks; then by number.
    /// - Parameter sessionKeys: the `about` keys of Build sessions, so work someone already started here is left out.
    public static func items(_ backlog: TrackerBacklog, scopes: Set<String>, filter: WorkFilter, me: [String],
                             sessionKeys: Set<String>) -> [StartableWork] {
        var out: [StartableWork] = []
        for item in backlog.items where !scopes.isDisjoint(with: Set([item.scope] + item.scopes)) {
            guard inCurrentSprint(item, backlog) else { continue }
            if item.canStart, item.isBug ? filter.bugs : filter.pbis, !sessionKeys.contains(item.sessionKey) {
                let mine = isMine(item.assignee, flagged: item.mine, me: me)
                if filter.owner.accepts(mine: mine, unassigned: item.isUnassigned) {
                    out.append(StartableWork(item: item, task: nil, mine: mine))
                }
            }
            guard filter.tasks, !item.isFinished else { continue }
            for t in item.tasks where unstartedTaskStates.contains(t.state.lowercased()) && !sessionKeys.contains("wi:\(t.id)") {
                let mine = isMine(t.assignee, me: me)
                if filter.owner.accepts(mine: mine, unassigned: t.assignee.isEmpty) {
                    out.append(StartableWork(item: item, task: t, mine: mine))
                }
            }
        }
        func rank(_ w: StartableWork) -> Int { w.mine ? 0 : w.isUnassigned ? 1 : 2 }
        return out.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if (a.task == nil) != (b.task == nil) { return a.task == nil }
            return a.number < b.number
        }
    }
}
