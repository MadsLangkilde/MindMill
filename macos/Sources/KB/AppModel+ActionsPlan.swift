import AppKit
import Foundation
import KBCore
import KBEngine

/// Handlers for Plan mode: the knowledge base, facts, follow-ups, discussions, ideas, research, references,
/// reminders, goals and the day's plan. Each calls the function its button calls.
extension AppModel {
    func registerPlanActions() {
        let a = actions

        // MARK: Knowledge

        a.register("entry.delete") { [unowned self] p in
            let id = try entryParam(p)
            let title = index.entry(id)?.title ?? id.rawValue
            deleteEntries([id])
            return ActionResult("Deleting “\(title)”.")
        }

        a.register("entry.move") { [unowned self] p in
            let id = try entryParam(p)
            let to = try scopeParam(["scope": p["to"] ?? .null])
            moveEntry(id, to: to)
            return ActionResult("Moving it to \(index.project(to)?.title ?? to).")
        }

        a.register("entry.tags") { [unowned self] p in
            let id = try entryParam(p)
            let tags = p["tags"]?.strings ?? []
            if document?.id == id {
                setTags(tags)
            } else {
                var doc = try KBStore.load(id, root: rootURL)
                doc.frontmatter.set("tags", tags.isEmpty ? nil : .list(tags))
                _ = try KBStore.save(&doc, root: rootURL)
                reload()
            }
            return ActionResult(tags.isEmpty ? "Removed its tags." : "Tagged it " + Self.list(tags) + ".")
        }

        a.register("entry.scopes") { [unowned self] p in
            let id = try entryParam(p)
            let scope = try scopeParam(p)
            let add = p["add"]?.bool ?? true
            changeScope(scope, on: [id], add: add)
            return ActionResult(add ? "Added it to \(scope)." : "Took it out of \(scope).")
        }

        a.register("entry.share") { [unowned self] p in
            let id = try entryParam(p)
            let shared = p["shared"]?.bool ?? true
            setShared(id, shared)
            return ActionResult(shared ? "Shared it with the team." : "Made it private.")
        }

        a.register("entry.ask") { [unowned self] p in
            let id = try entryParam(p)
            NSApp.activate(ignoringOtherApps: true)
            askAbout(.entry(id, title: index.entry(id)?.title ?? id.stem))
            return ActionResult("The Ask window is open on the Mac.")
        }

        // MARK: Facts

        a.register("fact.link") { [unowned self] p in
            let a = try entryParam(p)
            guard let raw = p["other"]?.string, let b = EntryID(raw) else { throw ActionError("Which other fact?") }
            let remove = p["remove"]?.bool ?? false
            linkFacts(a, b, remove: remove)
            return ActionResult(remove ? "Unlinked them." : "Linked them.")
        }

        a.register("fact.links.suggest") { [unowned self] p in
            suggestFactLinks(try entryParam(p))
            return ActionResult("Looking for links; the suggestions show beside the fact on the Mac.")
        }

        a.register("fact.change.resolve") { [unowned self] p in
            let id = try entryParam(p)
            let how: FactResolution = p["how"]?.string == "update" ? .update : .keep
            resolveFactChange(id, how)
            return ActionResult(how == .update ? "Updating the fact." : "Kept the fact as it is.")
        }

        a.register("fact.change.remove") { [unowned self] p in
            resolveFactChange(try entryParam(p), .remove)
            return ActionResult("Removing the fact.")
        }

        // MARK: Follow-ups

        a.register("followups.duplicates") { [unowned self] p in
            findDuplicateFollowups(project: try scopeParam(p))
            return ActionResult("Looking for duplicates; proposals to merge show under Follow-ups.")
        }

        a.register("followup.merge") { [unowned self] p in
            guard let keep = p["keep"]?.string, let other = p["other"]?.string else { throw ActionError("Which two?") }
            mergeFollowups(keep: keep, other: other)
            return ActionResult("Merged them.")
        }

        a.register("followups.check") { [unowned self] p in
            checkFollowupsNow(project: try scopeParam(p))
            return ActionResult("Checking the open follow-ups.")
        }

        // MARK: Discussions

        a.register("discussion.start") { [unowned self] p in
            let scope = try scopeParam(p)
            startDiscussion(project: scope, lookFor: p["look_for"]?.string ?? "")
            return ActionResult("Looking for that discussion; it shows under Discussions when found.")
        }

        a.register("discussion.status") { [unowned self] p in
            let id = try entryParam(p)
            guard let status = p["status"]?.string.flatMap(DiscussionStatus.init(rawValue:)) else { throw ActionError("Which status?") }
            if status == .concluded, (p["outcome"]?.string ?? "").isEmpty {
                discussionSession("conclude", id, display: "Conclude the discussion")
                return ActionResult("Concluding it in a session.")
            }
            setDiscussion(id, status: status, outcome: p["outcome"]?.string)
            return ActionResult("It's \(status.rawValue) now.")
        }

        a.register("discussion.waiting") { [unowned self] p in
            let id = try entryParam(p)
            guard let who = p["on"]?.string.flatMap(WaitingOn.init(rawValue:)) else { throw ActionError("Waiting on whom?") }
            setWaitingOn(id, who)
            return ActionResult(who == .nobody ? "It waits on nobody." : "It waits on \(who == .me ? "you" : "others").")
        }

        a.register("discussion.refresh") { [unowned self] p in
            discussionSession("refresh", try entryParam(p), display: "Check for new replies")
            return ActionResult("Checking for new replies.")
        }

        a.register("discussion.file") { [unowned self] p in
            discussionSession("file", try entryParam(p), display: "File the findings")
            return ActionResult("Filing what it found.")
        }

        // MARK: Ideas and research

        a.register("idea.status") { [unowned self] p in
            let id = try entryParam(p)
            guard let s = p["status"]?.string.flatMap(IdeaStatus.init(rawValue:)) else { throw ActionError("Which status?") }
            setIdea(id, status: s)
            return ActionResult("The idea is \(s.rawValue) now.")
        }

        a.register("idea.turn") { [unowned self] p in
            let id = try entryParam(p)
            guard let into = p["into"]?.string.flatMap(IdeaOutcome.init(rawValue:)) else { throw ActionError("Into what?") }
            turnIdea(id, into: into)
            return ActionResult("Turning it into a \(into.rawValue) in a session.")
        }

        a.register("idea.brainstorm") { [unowned self] p in
            ideaSession("brainstorm", try entryParam(p), display: "Brainstorm")
            return ActionResult("Started brainstorming in a session.")
        }

        a.register("research.start") { [unowned self] p in
            let scope = try scopeParam(p)
            var target: ResearchTarget?
            if let n = Self.intParam(p["work_item"]) { target = .workItem(n) }
            if let raw = p["entry"]?.string, let e = EntryID(raw) { target = .entry(e) }
            startResearch(NewResearchRequest(project: scope, target: target, title: p["title"]?.string ?? "",
                                             question: p["question"]?.string ?? ""))
            return ActionResult("Started the research.")
        }

        a.register("research.continue") { [unowned self] p in
            researchAction("continue", try entryParam(p), display: "Continue")
            return ActionResult("Carrying on with it.")
        }

        a.register("research.finish") { [unowned self] p in
            researchAction("finish", try entryParam(p), display: "Finish")
            return ActionResult("Summarising it; pick what to keep on the Mac or the phone.")
        }

        a.register("research.status") { [unowned self] p in
            let id = try entryParam(p)
            guard let s = p["status"]?.string.flatMap(ResearchStatus.init(rawValue:)) else { throw ActionError("Which status?") }
            setResearch(id, status: s)
            return ActionResult("The research is \(s.rawValue) now.")
        }

        // MARK: References

        a.register("reference.save") { [unowned self] p in
            let scope = try scopeParam(p)
            let url = p["url"]?.string.flatMap(URL.init(string:))
            let kind = p["kind"]?.string.flatMap(ReferenceKind.init(rawValue:)) ?? (url == nil ? .note : .web)
            guard let id = saveReference(project: scope, title: p["title"]?.string ?? "", kind: kind, url: url,
                                         note: p["note"]?.string ?? "", content: "") else { throw ActionError("Couldn't save it.") }
            return ActionResult("Saved it to References.", data: ["id": .string(id.rawValue)])
        }

        a.register("reference.from_mail") { [unowned self] p in
            let scope = try scopeParam(p)
            let kind: ReferenceKind = p["kind"]?.string == "teams" ? .teams : .email
            referenceFromMail(project: scope, kind: kind, lookFor: p["look_for"]?.string ?? "", note: p["note"]?.string ?? "")
            return ActionResult("Looking for it; it shows under References when saved.")
        }

        // MARK: Reminders and goals

        a.register("reminder.update") { [unowned self] p in
            let r = try reminderParam(p)
            var said: [String] = []
            if let s = p["status"]?.string.flatMap(Reminder.Status.init(rawValue:)) { setReminder(r, status: s); said.append(s.rawValue) }
            if let d = p["due"]?.string {
                let due = d == "none" || d.isEmpty ? "" : Self.day(d)
                setReminder(reminders.first { $0.id == r.id } ?? r, due: due)
                said.append(due.isEmpty ? "without a date" : "due \(due)")
            }
            return ActionResult(said.isEmpty ? "Nothing to change." : "It's " + Self.list(said) + " now.")
        }

        a.register("reminder.delete") { [unowned self] p in
            deleteReminder(try reminderParam(p))
            return ActionResult("Deleted it.")
        }

        a.register("goal.status") { [unowned self] p in
            let g = try goalParam(p)
            guard let s = p["status"]?.string.flatMap(Goal.Status.init(rawValue:)) else { throw ActionError("Which status?") }
            updateGoal(g) { $0.frontmatter.set("status", .string(s.rawValue)) }
            return ActionResult("The goal is \(s.rawValue) now.")
        }

        a.register("goal.progress") { [unowned self] p in
            logGoalProgress(try goalParam(p), p["text"]?.string ?? "")
            return ActionResult("Logged it.")
        }

        a.register("goal.coach") { [unowned self] p in
            sendToGoalCoach(try goalParam(p), p["text"]?.string ?? "", show: false)
            return ActionResult("Asked the coach; the answer shows with the goal.")
        }

        a.register("goal.delete") { [unowned self] p in
            deleteGoal(try goalParam(p))
            return ActionResult("Deleted the goal.")
        }

        // MARK: Today

        a.register("today.morning") { [unowned self] _ in
            runMorningRoutine()
            return ActionResult("Running the morning routine.")
        }
        a.register("sync.calendar") { [unowned self] _ in
            syncCalendar()
            return ActionResult("Syncing the calendar.")
        }
        a.register("sync.email") { [unowned self] _ in
            syncEmail()
            return ActionResult("Reading new mail.")
        }
    }

    // MARK: Helpers

    func entryParam(_ p: JSONValue, _ key: String = "id") throws -> EntryID { try engine.entryParam(p, key) }

    private func reminderParam(_ p: JSONValue) throws -> Reminder { try engine.reminder(p["id"]?.string ?? "") }

    private func goalParam(_ p: JSONValue) throws -> Goal { try engine.plan.goal(p["id"]?.string ?? "") }

    static func reminderJSON(_ r: Reminder) -> JSONValue { MindmillEngine.reminderJSON(r) }

    /// `kb new` for a section, as the phone's `entry.new` and the `entry.create` action do. Returns the new id.
    func createEntryWithCLI(scope: String, section: String, title: String, summary: String?, tags: [String],
                            fields: [String: String], body: String?) async throws -> String {
        try await engine.createEntry(scope: scope, section: section, title: title, summary: summary, tags: tags, fields: fields, body: body)
    }
}
