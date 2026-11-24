import Foundation
import KBCore
import Observation

/// `engine.sprints`: each tracker's sprints around today (`kb sprint status`), what Mindmill remembers of them
/// (`SprintWatch`: a sprint that ended, a review waiting or snoozed), the sprint review and its decisions, and what is
/// ready to start. The Mac's sprint banners and review sheet and the `sprint.*` actions share it.
@MainActor
@Observable
public final class SprintCenter {
    public var report: SprintReport?
    public var watch: SprintWatch
    public var checking = false
    @ObservationIgnored public var checked: Date?
    /// Where `watch` is saved.
    @ObservationIgnored public var watchURL: URL {
        didSet { watch = SprintWatch.load(from: watchURL) }
    }
    /// Mindmill's own tracker changed for these scopes (a sprint added, decisions applied): the host rereads its copy.
    @ObservationIgnored public var onLocalTrackerChanged: (([String]) -> Void)?

    @ObservationIgnored unowned let engine: MindmillEngine

    init(engine: MindmillEngine, watchURL: URL) {
        self.engine = engine
        self.watchURL = watchURL
        watch = SprintWatch.load(from: watchURL)
    }

    /// Reads every tracker's sprints and notices a new sprint, or one that ended with nothing after it. At most once
    /// an hour unless forced (Sync, the morning routine, Review Last Sprint).
    public func check(force: Bool = false) {
        guard !checking else { return }
        if !force, let at = checked, Date().timeIntervalSince(at) < 3600 { return }
        checking = true
        let cli = engine.cli
        Task {
            defer { checking = false }
            guard let out = try? await cli.run(["sprint", "status", "--json"]), let report = try? SprintReport.decode(out) else { return }
            checked = Date()
            let fresh = take(report)
            if let (t, p) = fresh.first {
                engine.report(p.target.map { "\($0.name) has started in \(t.trackerName). Review what \(p.sprint.name) left unfinished from Build or Today." }
                              ?? "\(p.sprint.name) has ended in \(t.trackerName). Review what it left unfinished from Build or Today.")
            }
        }
    }

    /// Keeps a fresh report and remembers what it shows; returns the trackers with news.
    @discardableResult
    public func take(_ report: SprintReport, today: String = KBDate.today()) -> [(TrackerSprints, SprintWatch.Pending)] {
        self.report = report
        var w = watch
        let fresh = report.trackers.compactMap { t in w.observe(t, today: today).map { (t, $0) } }
        if w != watch {
            watch = w
            save()
        }
        return fresh
    }

    /// Reads the sprints now (the actions), unless a report is there and `force` is false.
    public func load(force: Bool = false) async throws {
        if report != nil, !force { return }
        take(try SprintReport.decode(try await engine.cli.run(["sprint", "status", "--json"])))
        checked = Date()
    }

    public func save() {
        do { try watch.save(to: watchURL) } catch { engine.report("Could not save the sprint state: \(error.localizedDescription)", error: true) }
    }

    /// The tracker a scope's work is in, as `kb sprint status` saw it.
    public func tracker(scope: String) -> TrackerSprints? {
        report?.tracker(scope: scope) ?? engine.index.members(of: scope).lazy.compactMap { self.report?.tracker(scope: $0) }.first
    }

    /// The sprint news for a scope's trackers (all of them for nil).
    public func moments(scope: String?) -> [SprintMoment] {
        guard let report else { return [] }
        let all = SprintMoment.list(report, watch: watch, today: KBDate.today())
        guard let scope else { return all }
        let here = engine.index.members(of: scope)
        return all.filter { !here.isDisjoint(with: $0.tracker.scopes) }
    }

    public func snooze(_ key: String) {
        watch.snooze(key, today: KBDate.today())
        save()
    }

    public func finish(_ key: String, sprint: String) {
        watch.finish(key, sprint: sprint)
        save()
    }

    public func request(_ key: String, sprint: SprintInfo, target: SprintInfo?) {
        watch.request(key, sprint: sprint, target: target, today: KBDate.today())
        save()
    }

    public func loadReview(scope: String, sprint: SprintInfo) async throws -> SprintReviewData {
        try SprintReviewData.decode(try await engine.cli.run(["sprint", "review", "--scope", scope, "--sprint", sprint.path, "--json"]))
    }

    /// Carries out the decisions in the tracker, each on its own, and refreshes what shows the items.
    public func apply(_ decisions: [Int: SprintDecision], review: SprintReviewData, scope: String) async throws -> [SprintApplyResult] {
        let json = SprintReview.applyJSON(decisions, in: review)
        let out = try await engine.cli.run(["sprint", "apply", "--scope", scope, "--yes", "--json"], stdin: json)
        let results = try SprintApplyResult.decode(out)
        if review.kind == "local" { onLocalTrackerChanged?(review.scopes) }
        engine.tracker.refreshBacklog(force: true)
        engine.tracker.refreshMyWork(force: true)
        return results
    }

    /// Adds the next sprint to Mindmill's own tracker of `t`.
    public func createNext(_ t: TrackerSprints, scope: String, name: String? = nil, start: String? = nil,
                           finish: String? = nil) async throws -> SprintInfo {
        var args = ["sprint", "create", "--scope", t.scopes.first ?? scope, "--json"]
        for (k, v) in [("name", name), ("start", start), ("finish", finish)] { if let v, !v.isEmpty { args += ["--\(k)", v] } }
        let made = try JSONDecoder().decode(SprintInfo.self, from: Data(try await engine.cli.run(args).utf8))
        onLocalTrackerChanged?(t.scopes)
        check(force: true)
        engine.tracker.refreshBacklog(force: true)
        return made
    }

    // MARK: Who and what

    /// Names that mean the user on a work item: Settings' name, the tracker account, and this computer's user.
    public var workItemNames: [String] { engine.myNames() + [NSFullUserName()].filter { !$0.isEmpty } }

    /// Whether a Build session (not archived) works on this key.
    public func hasBuildSession(_ key: String) -> Bool {
        engine.sessions.sessions(forKey: key).contains { !engine.sessions.isArchived($0) }
    }

    public var activeSessionKeys: Set<String> {
        Set(engine.sessions.buildSessions.filter { !engine.sessions.isArchived($0) }.compactMap(\.about))
    }

    /// What can be started now in a scope, as Build's Ready to Start shows it.
    public func startable(scope: String, filter: WorkFilter) -> [StartableWork] {
        guard let backlog = engine.tracker.backlog else { return [] }
        return Startable.items(backlog, scopes: engine.index.members(of: scope), filter: filter, me: workItemNames,
                               sessionKeys: activeSessionKeys)
    }

    /// The review's unfinished items for an owner.
    public func items(_ review: SprintReviewData, owner: WorkFilter.Owner) -> [TrackerBacklog.Item] {
        let names = workItemNames
        return review.items.filter { owner.accepts(mine: Startable.isMine($0.assignee, flagged: $0.mine, me: names), unassigned: $0.isUnassigned) }
    }

    public func suggestion(_ item: TrackerBacklog.Item, _ review: SprintReviewData) -> SprintSuggestion {
        let merged = engine.tracker.pullRequests?.closed.contains { $0.completed && $0.workItems.contains(item.id) } ?? false
        return SprintReview.suggest(item, in: review, mergedPR: merged, hasSession: hasBuildSession(item.sessionKey))
    }

    /// The scope, its tracker and the sprint a sprint action is about: the pending review's, else the one before today's.
    public func forAction(_ p: JSONValue) async throws -> (String, TrackerSprints, SprintInfo) {
        let scope = try engine.scopeParam(p)
        if tracker(scope: scope) == nil { try await load(force: true) }
        guard let t = tracker(scope: scope) else { throw ActionError("\(scope) has no tracker with sprints.") }
        if t.throughClaude { throw ActionError("\(t.trackerName)'s sprints are read through \(Brain.name). Start a session to review them with its connector.") }
        guard t.reachable else { throw ActionError("Mindmill can't read the sprints: \(t.note)") }
        guard let sprint = watch.pending(t.key, today: KBDate.today())?.sprint ?? t.previous
        else { throw ActionError("No sprint has finished yet in \(t.trackerName).") }
        return (t.scopes.first ?? scope, t, sprint)
    }

    public static func decisionCode(_ d: SprintDecision) -> String {
        switch d {
        case .keep: return "keep"
        case .state(let s): return "state:\(s)"
        case .move: return "move"
        case .backlog: return "backlog"
        }
    }

    /// The message for a session that reviews a sprint in a tracker only Claude's connector can read.
    public static func claudeReviewMessage(_ name: String) -> String {
        """
        Help me close the last sprint in \(name) for this scope, using your \(name) connector. If no \(name) connector is available, say so and stop.
        1. Find the board's sprint that ended most recently and the one active now (or say there is none yet).
        2. List what the ended sprint left unfinished (stories, bugs and their sub-tasks): key, title, status, assignee, open sub-tasks and linked pull requests. Start with the ones assigned to me, then unassigned ones; ask before going through the rest of the team's.
        3. Suggest one decision per issue: done/resolved (in this workflow's own status names), move to the active sprint, move to the backlog, or won't do. Explain each in a few words.
        4. Ask me to confirm or change them with choices, then make only the changes I confirmed, all in one go, and report each issue's result. Retry failures only if I ask.
        If there is no active sprint yet, tell me and where to create it; don't create one yourself.
        """
    }
}

extension MindmillEngine {
    func registerSprintActions() {
        let a = actions

        a.register("work.startable") { [unowned self] p in
            let scope = try scopeParam(p)
            await tracker.freshBacklog()
            if tracker.backlog == nil { tracker.backlog = try TrackerBacklog.decode(try await cli.run(["tracker", "backlog", "--json"])) }
            var filter = WorkFilter.load(scope: scope, defaults: platform.defaults)
            if let o = p["owner"]?.string.flatMap(WorkFilter.Owner.init(rawValue:)) { filter.owner = o }
            let types = p["types"]?.strings ?? p["types"]?.string.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } } ?? []
            if !types.isEmpty {
                let t = Set(types.map { $0.lowercased() })
                filter.pbis = t.contains("pbi") || t.contains("pbis")
                filter.bugs = t.contains("bug") || t.contains("bugs")
                filter.tasks = t.contains("task") || t.contains("tasks")
            }
            let work = sprints.startable(scope: scope, filter: filter)
            let rows: [JSONValue] = work.map { w in
                ["id": .number(Double(w.number)), "kind": .string(w.kind), "title": .string(w.title), "state": .string(w.state),
                 "assignee": .string(w.assignee), "mine": .bool(w.mine), "scope": .string(w.item.scope), "sprint": .string(w.item.sprint),
                 "parent": w.task == nil ? .null : .number(Double(w.item.id))]
            }
            guard let first = work.first else {
                return ActionResult("Nothing is ready to start for \(filter.owner.title.lowercased()).", data: ["items": [], "owner": .string(filter.owner.rawValue)])
            }
            return ActionResult("\(ActionText.count(work.count, "item")) ready to start. The first is \(first.number), \(first.title)"
                                + (first.mine ? ", yours." : first.isUnassigned ? ", unassigned." : ", \(first.assignee)'s."),
                                data: ["items": .array(rows), "owner": .string(filter.owner.rawValue)])
        }

        a.register("sprint.status") { [unowned self] p in
            let only = p["scope"]?.string == nil ? nil : try scopeParam(p)
            try await sprints.load(force: true)
            let report = sprints.report ?? SprintReport()
            let today = KBDate.today()
            let shown = report.trackers.filter { t in only.map { !index.members(of: $0).isDisjoint(with: t.scopes) } ?? true }
            let lines = shown.map { t -> String in
                switch t.state {
                case .running: return "\(t.trackerName): \(t.current!.name) runs until \(ActionText.shortDate(t.current!.finish))"
                case .ended: return "\(t.trackerName): \(t.previous?.name ?? "the last sprint") has ended and no sprint follows it"
                case .between: return "\(t.trackerName): between sprints" + (t.next.map { ", \($0.name) starts \(ActionText.shortDate($0.start))" } ?? "")
                case .off: return "\(t.trackerName): sprints are off"
                case .unknown: return t.throughClaude ? "\(t.trackerName) is read through \(Brain.name), not by Mindmill" : "\(t.trackerName): \(t.note)"
                case .none, .upcoming: return "\(t.trackerName): no sprint running"
                }
            }
            let reviews: [JSONValue] = shown.compactMap { t in
                sprints.watch.pending(t.key, today: today).map { r in
                    ["key": .string(t.key), "sprint": .from(r.sprint), "target": r.target.map { .from($0) } ?? .null]
                }
            }
            var speech = lines.isEmpty ? "No tracker with sprints." : ActionText.list(lines) + "."
            if !reviews.isEmpty { speech += " A review of the last sprint is waiting." }
            return ActionResult(speech, data: ["trackers": .from(shown), "reviews": .array(reviews)])
        }

        a.register("sprint.review") { [unowned self] p in
            let (scope, t, sprint) = try await sprints.forAction(p)
            let review = try await sprints.loadReview(scope: scope, sprint: sprint)
            let owner = p["owner"]?.string.flatMap(WorkFilter.Owner.init(rawValue:)) ?? .me
            let items = sprints.items(review, owner: owner)
            let rows: [JSONValue] = items.map { item in
                let s = sprints.suggestion(item, review)
                var o = JSONValue.from(item)
                if case .object(var d) = o {
                    d["suggestion"] = ["decision": .string(SprintReview.title(s.decision, in: review)), "reason": .string(s.reason),
                                       "code": .string(SprintCenter.decisionCode(s.decision))]
                    o = .object(d)
                }
                return o
            }
            let speech = items.isEmpty
                ? "\(sprint.name) left nothing unfinished for \(owner.title.lowercased())."
                : "\(sprint.name) left \(ActionText.count(items.count, "item")) unfinished" + (review.target.map { "; the new sprint is \($0.name)." } ?? "; there's no next sprint yet.")
            return ActionResult(speech, data: ["key": .string(t.key), "sprint": .from(sprint), "target": review.target.map { .from($0) } ?? .null,
                                               "backlog": .string(review.backlog), "items": .array(rows)])
        }

        a.register("sprint.apply") { [unowned self] p in
            let (scope, _, sprint) = try await sprints.forAction(p)
            let review = try await sprints.loadReview(scope: scope, sprint: sprint)
            let (given, problems) = SprintReview.parse(p["decisions"]?.strings ?? p["decisions"]?.string.map { [$0] } ?? [], in: review)
            var decisions = given
            if p["accept_suggestions"]?.bool == true {
                let owner = p["owner"]?.string.flatMap(WorkFilter.Owner.init(rawValue:)) ?? .me
                for item in sprints.items(review, owner: owner) where decisions[item.id] == nil {
                    decisions[item.id] = sprints.suggestion(item, review).decision
                }
            }
            decisions = decisions.filter { $0.value.changes }
            guard !decisions.isEmpty else {
                throw ActionError(problems.isEmpty ? "No decisions to apply." : "Nothing applied: " + problems.joined(separator: "; "))
            }
            let results = try await sprints.apply(decisions, review: review, scope: scope)
            let failed = results.filter { !$0.ok }
            var speech = failed.isEmpty ? "Applied \(ActionText.count(results.count, "change"))." : "Applied \(results.count - failed.count) of \(results.count); failed: " + failed.map(\.message).joined(separator: "; ") + "."
            if !problems.isEmpty { speech += " Skipped: " + problems.joined(separator: "; ") + "." }
            return ActionResult(speech, data: ["results": .from(results)])
        }

        a.register("sprint.create") { [unowned self] p in
            let scope = try scopeParam(p)
            if sprints.tracker(scope: scope) == nil { try await sprints.load(force: true) }
            guard let t = sprints.tracker(scope: scope) else { throw ActionError("\(scope) has no tracker with sprints.") }
            guard t.canCreate else {
                throw ActionError(t.createURL.isEmpty ? "Mindmill can't add sprints to \(t.trackerName)."
                                  : "Mindmill doesn't create iterations in \(t.trackerName). Add the next sprint at \(t.createURL) and select it for the team.")
            }
            let made = try await sprints.createNext(t, scope: scope, name: p["name"]?.string, start: p["start"]?.string, finish: p["finish"]?.string)
            return ActionResult("Added \(made.name), \(ActionText.shortDate(made.start)) to \(ActionText.shortDate(made.finish)).", data: .from(made))
        }

        a.register("sprint.dismiss") { [unowned self] p in
            let (_, t, sprint) = try await sprints.forAction(p)
            if p["how"]?.string == "done" {
                sprints.finish(t.key, sprint: sprint.path)
                return ActionResult("Done with \(sprint.name)'s review.")
            }
            sprints.snooze(t.key)
            return ActionResult("I'll bring \(sprint.name)'s review back tomorrow.")
        }
    }
}
