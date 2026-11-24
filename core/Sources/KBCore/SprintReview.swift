import Foundation

/// `kb sprint review --json`: what a finished sprint left unfinished, the states its items can take in this tracker's
/// process, and the sprint to carry them over to.
public struct SprintReviewData: Codable, Equatable, Sendable {
    public var key: String
    public var kind: String
    public var scopes: [String]
    public var sprint: SprintInfo?
    /// The sprint running now, else the next one planned; nil when there is none.
    public var target: SprintInfo?
    public var items: [TrackerBacklog.Item]
    /// The states of `pbi`, `bug` and `task`, in workflow order.
    public var states: [String: [TrackerBacklog.WorkState]]
    /// Where "Move to backlog" puts an item, for the user.
    public var backlog: String

    public init(key: String = "", kind: String = "local", scopes: [String] = [], sprint: SprintInfo? = nil, target: SprintInfo? = nil,
                items: [TrackerBacklog.Item] = [], states: [String: [TrackerBacklog.WorkState]] = [:], backlog: String = "") {
        self.key = key
        self.kind = kind
        self.scopes = scopes
        self.sprint = sprint
        self.target = target
        self.items = items
        self.states = states
        self.backlog = backlog
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        sprint = try c.decodeIfPresent(SprintInfo.self, forKey: .sprint)
        target = try c.decodeIfPresent(SprintInfo.self, forKey: .target)
        items = try c.decodeIfPresent([TrackerBacklog.Item].self, forKey: .items) ?? []
        states = try c.decodeIfPresent([String: [TrackerBacklog.WorkState]].self, forKey: .states) ?? [:]
        backlog = try c.decodeIfPresent(String.self, forKey: .backlog) ?? ""
    }

    public static func decode(_ json: String) throws -> SprintReviewData {
        try JSONDecoder().decode(SprintReviewData.self, from: Data(json.utf8))
    }

    public func states(for item: TrackerBacklog.Item) -> [TrackerBacklog.WorkState] {
        let known = states[item.isBug ? "bug" : "pbi"] ?? []
        return known.isEmpty ? TrackerBacklog.WorkState.scrum : known
    }

    var taskStates: [TrackerBacklog.WorkState] { states["task"] ?? [] }

    /// The states that finish an item, as the tracker names them: Resolved and Closed in Agile, Done in Scrum.
    public func finishing(_ item: TrackerBacklog.Item) -> [TrackerBacklog.WorkState] {
        states(for: item).filter { $0.category == "Resolved" || $0.category == "Completed" }
    }

    /// The state that completes an item (Done, Closed), else the first finishing one.
    public func doneState(_ item: TrackerBacklog.Item) -> TrackerBacklog.WorkState? {
        let f = finishing(item)
        return f.first { $0.category == "Completed" } ?? f.first
    }

    /// "Won't do": the Removed state, when the process has one.
    public func removedState(_ item: TrackerBacklog.Item) -> TrackerBacklog.WorkState? {
        states(for: item).first(where: \.isRemoved)
    }

    /// What finishes a task alongside its item: the task's Completed state (Done, Closed).
    public var taskDoneState: String {
        taskStates.first { $0.category == "Completed" }?.name ?? "Done"
    }
}

/// What to do with one unfinished item at the end of a sprint.
public enum SprintDecision: Equatable, Sendable, Hashable {
    /// Leave it where it is.
    case keep
    /// Set it to this state (Done, Resolved, Closed, Removed…).
    case state(String)
    /// Move it, with its open tasks, to the sprint at this path.
    case move(String)
    /// Take it, with its open tasks, out of every sprint.
    case backlog

    public var changes: Bool { self != .keep }
}

/// A decision suggested for an item, and why, in a few words.
public struct SprintSuggestion: Equatable, Sendable {
    public var decision: SprintDecision
    public var reason: String
}

public enum SprintReview {
    /// The decision that fits an item best. Never applied without the user: the review shows it as the item's
    /// preselected choice.
    /// - Parameters:
    ///   - mergedPR: one of its pull requests was completed.
    ///   - hasSession: a Build session is working on it.
    public static func suggest(_ item: TrackerBacklog.Item, in review: SprintReviewData, mergedPR: Bool = false,
                               hasSession: Bool = false) -> SprintSuggestion {
        let done = review.doneState(item)
        let carry: SprintSuggestion? = review.target.map { .init(decision: .move($0.path), reason: "") }
        func carryOver(_ why: String) -> SprintSuggestion {
            guard var c = carry else { return .init(decision: .keep, reason: why + "; there is no next sprint yet") }
            c.reason = why
            return c
        }
        let tasksDone = item.tasksTotal > 0 && item.openTasks.isEmpty
        if item.stage == .resolved, let done, done.category == "Completed" {
            return .init(decision: .state(done.name), reason: "\(item.state); close it")
        }
        if mergedPR && item.openTasks.isEmpty, let done {
            return .init(decision: .state(done.name), reason: "Its pull request is merged")
        }
        if tasksDone && item.prs.isEmpty, let done {
            return .init(decision: .state(done.name), reason: "Every task is done")
        }
        if !item.prs.isEmpty || item.stage == .inPR { return carryOver("Its pull request is still open") }
        if mergedPR, let done {
            return .init(decision: .state(done.name), reason: "Its pull request is merged; \(item.openTasks.count) task(s) still open")
        }
        if item.stage == .inProgress || hasSession || item.tasksInProgress > 0 { return carryOver("Under way") }
        if item.isUnassigned { return .init(decision: .backlog, reason: "Not started and nobody has it") }
        return carryOver("Not started yet")
    }

    /// "Move all unfinished to the new sprint": every listed item moved, the rest of the choices left as they are.
    public static func moveAll(_ items: [TrackerBacklog.Item], to target: SprintInfo,
                               decisions: [Int: SprintDecision]) -> [Int: SprintDecision] {
        var out = decisions
        for i in items { out[i.id] = .move(target.path) }
        return out
    }

    /// One decision as `kb sprint apply` takes it: open tasks go along on a move, and are finished with the item
    /// when it is set to a Completed state.
    public static func payload(_ item: TrackerBacklog.Item, _ decision: SprintDecision, in review: SprintReviewData) -> [String: JSONValue]? {
        let open = item.openTasks.map { JSONValue.number(Double($0.id)) }
        var out: [String: JSONValue] = ["id": .number(Double(item.id))]
        switch decision {
        case .keep: return nil
        case .state(let s):
            out["do"] = "state"
            out["state"] = .string(s)
            let completes = review.states(for: item).first { $0.name == s }?.category == "Completed"
            if completes, !open.isEmpty {
                out["tasks"] = .array(open)
                out["task_state"] = .string(review.taskDoneState)
            }
        case .move(let path):
            out["do"] = "move"
            out["sprint"] = .string(path)
            if !open.isEmpty { out["tasks"] = .array(open) }
        case .backlog:
            out["do"] = "backlog"
            if !open.isEmpty { out["tasks"] = .array(open) }
        }
        return out
    }

    /// The decisions that change something, as the JSON list `kb sprint apply` reads.
    public static func applyJSON(_ decisions: [Int: SprintDecision], in review: SprintReviewData) -> String {
        let list = review.items.compactMap { i in decisions[i.id].flatMap { payload(i, $0, in: review) } }.map(JSONValue.object)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(JSONValue.array(list))).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    /// How a decision reads in the review.
    public static func title(_ d: SprintDecision, in review: SprintReviewData) -> String {
        switch d {
        case .keep: return "Leave as is"
        case .state(let s): return review.states.values.joined().first { $0.name == s }?.isRemoved == true ? "Remove (won't do)" : "Mark \(s)"
        case .move(let path): return "Move to \(review.target?.path == path ? review.target!.name : path.split(separator: "\\").last.map(String.init) ?? path)"
        case .backlog: return "Move to backlog"
        }
    }

    /// Parses `id:action[:value]` lines from voice or the phone: `12:done`, `12:move`, `12:backlog`, `12:remove`,
    /// `12:keep`, `12:state:Resolved`. Unknown items or actions are reported, not guessed.
    public static func parse(_ lines: [String], in review: SprintReviewData) -> (decisions: [Int: SprintDecision], problems: [String]) {
        var out: [Int: SprintDecision] = [:]
        var problems: [String] = []
        for raw in lines {
            let parts = raw.split(separator: ":", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, let id = Int(first.trimmingCharacters(in: CharacterSet(charactersIn: "#"))),
                  let item = review.items.first(where: { $0.id == id }), parts.count >= 2 else {
                problems.append("\(raw): not an unfinished item of this sprint")
                continue
            }
            switch parts[1].lowercased() {
            case "done", "close", "closed", "resolve", "resolved":
                let want = parts[1].lowercased().hasPrefix("resolve") ? "Resolved" : nil
                if let s = want.flatMap({ w in review.finishing(item).first { $0.category == w } }) ?? review.doneState(item) {
                    out[id] = .state(s.name)
                } else { problems.append("#\(id): this process has no done state") }
            case "move":
                if let t = review.target { out[id] = .move(t.path) } else { problems.append("#\(id): there is no next sprint to move to") }
            case "backlog": out[id] = .backlog
            case "remove", "wontdo", "won't do":
                if let s = review.removedState(item) { out[id] = .state(s.name) } else { problems.append("#\(id): this process has no Removed state") }
            case "keep": out[id] = .keep
            case "state" where parts.count == 3:
                if let s = review.states(for: item).first(where: { $0.name.lowercased() == parts[2].lowercased() }) {
                    out[id] = .state(s.name)
                } else { problems.append("#\(id): no state \(parts[2])") }
            default: problems.append("\(raw): unknown action")
            }
        }
        return (out, problems)
    }
}

/// One line of `kb sprint apply --json`.
public struct SprintApplyResult: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var ok: Bool
    public var message: String

    public init(id: Int, ok: Bool, message: String) {
        self.id = id
        self.ok = ok
        self.message = message
    }

    public static func decode(_ json: String) throws -> [SprintApplyResult] {
        struct Wrap: Decodable { var results: [Loose] }
        struct Loose: Decodable { var id: Int?; var ok: Bool; var message: String }
        return try JSONDecoder().decode(Wrap.self, from: Data(json.utf8)).results.map { SprintApplyResult(id: $0.id ?? 0, ok: $0.ok, message: $0.message) }
    }
}
