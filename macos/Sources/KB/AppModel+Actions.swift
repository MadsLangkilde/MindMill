import Foundation
import KBCore
import KBEngine

/// The handlers behind the action catalog that need the app (the engine registers the rest, sessions and factories
/// among them). Each calls the same function the matching button calls, so whatever voice or the phone does shows in
/// the UI at once, and the other way round.
extension AppModel {
    func registerActions() {
        let a = actions
        a.confirmsRisky = VoicePreferences.load().confirmsRisky

        a.register("fact.approve") { [unowned self] p in
            approveInbox([try entryParam(p)])
            return ActionResult("Approved.")
        }

        a.register("fact.decline") { [unowned self] p in
            rejectInbox([try entryParam(p)])
            return ActionResult("Declined.")
        }

        a.register("followup.update") { [unowned self] p in
            guard let id = p["id"]?.string else { throw ActionError("Which follow-up?") }
            var said: [String] = []
            if let note = p["note"]?.string, !note.isEmpty {
                _ = try await cli.run(["followup", "note", id, "--text", note])
                said.append("Noted")
            }
            if let raw = p["status"]?.string, let status = FollowupStatus(rawValue: raw), let entry = EntryID(id) {
                closeFollowup(entry, status: status, resolvedBy: p["resolved_by"]?.string, answer: p["answer"]?.string)
                said.append(status == .open ? "Reopened" : status == .done ? "Closed" : "Dropped")
            }
            reload()
            return ActionResult(said.isEmpty ? "Nothing to change." : said.joined(separator: " and ") + ".")
        }

        a.register("backlog.list") { [unowned self] p in
            let scope = try scopeParam(p)
            var items = trackerItems(scope: scope).filter { $0.stage != .done }
            if p["mine"]?.bool == true { items = items.filter(\.mine) }
            if let state = p["state"]?.string, !state.isEmpty { items = items.filter { $0.state.lowercased() == state.lowercased() } }
            guard let first = items.first else { return ActionResult("No work items match.") }
            return ActionResult("\(Self.count(items.count, "work item")). The first is \(first.id), \(first.title), \(first.state).",
                                data: ["items": .from(items)])
        }

        a.register("workitem.get") { [unowned self] p in
            guard let id = Self.intParam(p["id"]) else { throw ActionError("Which work item?") }
            let out = try await cli.run(["tracker", "item", String(id)] + engine.workItemScopeArgs(id, p))
            let item = tracker?.items.first { $0.id == id }
            return ActionResult(item.map { "\($0.id): \($0.title), \($0.state), assigned to \($0.assignee.isEmpty ? "nobody" : $0.assignee)." } ?? "Work item \(id).",
                                data: ["id": .number(Double(id)), "text": .string(String(out.prefix(12000)))])
        }

        a.register("workitem.update") { [unowned self] p in
            guard let n = Self.intParam(p["id"]) else { throw ActionError("Which work item?") }
            let id = String(n), at = engine.workItemScopeArgs(n, p)
            var said: [String] = []
            if let state = p["state"]?.string, !state.isEmpty {
                _ = try await cli.run(["tracker", "state", "--state", state, id] + at); said.append("set to \(state)")
            }
            if let who = p["assignee"]?.string, !who.isEmpty {
                _ = try await cli.run(["tracker", "assign", "--to", who, id] + at); said.append("assigned to \(who)")
            }
            if let sprint = p["sprint"]?.string, !sprint.isEmpty {
                _ = try await cli.run(["tracker", "move", "--sprint", sprint, id] + at); said.append("moved to \(sprint)")
            }
            if let comment = p["comment"]?.string, !comment.isEmpty {
                _ = try await cli.run(TrackerNote.args(id, comment, scopeArgs: at, local: at.last.map(trackerKind) == "local"))
                said.append("commented")
            }
            refreshTracker(force: true)
            return ActionResult(said.isEmpty ? "Nothing to change." : "Work item \(id) " + Self.list(said) + ".")
        }


        registerPlanActions()
        registerWorkActions()
        registerAppActions()
        assert(a.unhandled.isEmpty, "Actions without a handler: \(a.unhandled)")
    }

    // MARK: Helpers

    func scopeParam(_ p: JSONValue) throws -> String { try engine.scopeParam(p) }

    func factoryParam(_ p: JSONValue) throws -> Factory { try engine.factories.param(p) }

    func openFollowups(_ scope: String) -> [KBEntry] { engine.openFollowups(scope) }

    static func factoryJSON(_ f: Factory) -> JSONValue { RemotePayloads.factory(f) }

    static func intParam(_ v: JSONValue?) -> Int? { ActionText.intParam(v) }

    static func day(_ raw: String?, now: Date = Date()) -> String { ActionText.day(raw, now: now) }

    static func count(_ n: Int, _ word: String, plural: String? = nil) -> String { ActionText.count(n, word, plural: plural) }

    static func list(_ parts: [String], or: Bool = false) -> String { ActionText.list(parts, or: or) }
}
