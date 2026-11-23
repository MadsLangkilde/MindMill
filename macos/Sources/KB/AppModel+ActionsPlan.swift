import AppKit
import Foundation
import KBCore

/// Handlers for Plan mode: the knowledge base, facts, follow-ups, discussions, ideas, research, references,
/// reminders, goals and the day's plan. Each calls the function its button calls.
extension AppModel {
    func registerPlanActions() {
        let a = actions

        // MARK: Knowledge

        a.register("entries.list") { [unowned self] p in
            let scope = try scopeParam(p)
            guard let section = p["section"]?.string.flatMap(KBSection.init(rawValue:)) else { throw ActionError("Which section?") }
            var list = index.entries(project: scope, section: section).filter { !$0.isDraft }.sorted { $0.date > $1.date }
            if let q = p["query"]?.string, !q.isEmpty { list = list.filter { $0.matches(q) } }
            let tags = Set(p["tags"]?.strings ?? [])
            if !tags.isEmpty { list = list.filter { EntryTags.matches($0.tags, selected: tags) } }
            let shown = list.prefix(p["limit"]?.int ?? 50)
            guard let first = list.first else { return ActionResult("No \(section.title.lowercased()) match.") }
            return ActionResult("\(Self.count(list.count, section.singularTitle.lowercased())). The newest: \(first.title).",
                                data: ["entries": .array(shown.map(Self.remoteSummary))])
        }

        a.register("entry.create") { [unowned self] p in
            let scope = try scopeParam(p)
            guard let section = p["section"]?.string, let title = p["title"]?.string else { throw ActionError("A section and a title, please.") }
            var fields: [String: String] = [:]
            for kv in p["fields"]?.strings ?? [] {
                let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { fields[parts[0]] = parts[1] }
            }
            let id = try await createEntryWithCLI(scope: scope, section: section, title: title, summary: p["summary"]?.string,
                                                  tags: p["tags"]?.strings ?? [], fields: fields, body: p["body"]?.string)
            return ActionResult("Wrote “\(title)”.", data: ["id": .string(id)])
        }

        a.register("entry.update") { [unowned self] p in
            let id = try entryParam(p)
            var doc = try KBStore.load(id, root: rootURL)
            var said: [String] = []
            for key in ["title", "summary", "status"] {
                if let v = p[key]?.string { doc.frontmatter.set(key, v.isEmpty ? nil : .string(v)); said.append(key) }
            }
            if let field = p["field"]?.string, !field.isEmpty {
                let v = p["value"]?.string ?? ""
                doc.frontmatter.set(field, v.isEmpty ? nil : .string(v))
                said.append(field)
            }
            if let body = p["body"]?.string { doc.body = body; said.append("text") }
            if let more = p["append"]?.string, !more.isEmpty {
                doc.body = doc.body.trimmingCharacters(in: .newlines) + "\n\n" + more + "\n"
                said.append("text")
            }
            guard !said.isEmpty else { return ActionResult("Nothing to change.") }
            _ = try KBStore.save(&doc, root: rootURL)
            reload()
            var seen = Set<String>()
            return ActionResult("Changed the " + Self.list(said.filter { seen.insert($0).inserted }) + ".")
        }

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

        a.register("fact.propose") { [unowned self] p in
            let scope = try scopeParam(p)
            let title = p["title"]?.string ?? ""
            let out = try await cli.addInboxFact(project: scope, title: title, proposedBy: "voice",
                                                 reason: p["reason"]?.string ?? "Said by the user", body: p["body"]?.string ?? title)
            reload()
            return ActionResult("Proposed it. Approve it when you're ready.", data: ["output": .string(out)])
        }

        a.register("fact.links") { [unowned self] p in
            let id = try entryParam(p)
            let linked = index.linkedFacts(of: id)
            guard !linked.isEmpty else { return ActionResult("No facts are linked to it.") }
            return ActionResult("\(Self.count(linked.count, "linked fact")): " + Self.list(linked.prefix(3).map(\.title)) + ".",
                                data: ["entries": .array(linked.map(Self.remoteSummary))])
        }

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

        a.register("quiz.round") { [unowned self] p in
            let scope = try scopeParam(p)
            let facts = index.entries(project: scope, section: .facts).filter { !$0.isDraft }
            guard !facts.isEmpty else { return ActionResult("There are no facts to quiz on yet.") }
            let qs = await quizRound(from: facts, count: max(1, min(10, p["count"]?.int ?? 5)))
            guard let first = qs.first else { throw ActionError("Couldn't make questions right now.") }
            return ActionResult("First question: \(first.question)", data: ["questions": .array(qs.map {
                ["fact": .string($0.fact), "question": .string($0.question), "answer": .string($0.answer)]
            })])
        }

        a.register("quiz.answer") { [unowned self] p in
            guard let fact = p["fact"]?.string else { throw ActionError("Which fact?") }
            recordQuizAnswer(fact, correct: p["correct"]?.bool ?? false)
            return ActionResult("Noted.")
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

        a.register("reminders.list") { [unowned self] p in
            let which = p["status"]?.string ?? "open"
            let list = reminders.filter { which == "all" || $0.status.rawValue == which }.sorted { ($0.due.isEmpty ? "9" : $0.due) < ($1.due.isEmpty ? "9" : $1.due) }
            guard let first = list.first else { return ActionResult("No \(which == "all" ? "" : which + " ")reminders.") }
            return ActionResult("\(Self.count(list.count, "reminder")). The first: \(first.title)" + (first.due.isEmpty ? "." : ", due \(first.due)."),
                                data: ["reminders": .array(list.map(Self.reminderJSON))])
        }

        a.register("reminder.create") { [unowned self] p in
            let title = p["title"]?.string ?? ""
            let due = p["due"]?.string.map { Self.day($0) } ?? ""
            let r = try Reminders.create(title: title, due: due, note: p["note"]?.string ?? "",
                                         project: try p["scope"]?.string.map { try scopeParam(["scope": .string($0)]) },
                                         link: p["link"]?.string ?? "", root: rootURL)
            reload()
            return ActionResult("I'll remind you" + (due.isEmpty ? "." : " on \(due)."), data: Self.reminderJSON(r))
        }

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

        a.register("goals.list") { [unowned self] _ in
            guard !goals.isEmpty else { return ActionResult("No goals yet.") }
            let active = goals.filter { $0.status == .active }
            return ActionResult("\(Self.count(active.count, "active goal")): " + Self.list(active.prefix(3).map(\.title)) + ".",
                                data: ["goals": .array(goals.map { g in
                                    ["id": .string(g.id), "title": .string(g.title), "horizon": .string(g.horizon),
                                     "status": .string(g.status.rawValue), "lastProgress": g.lastProgress.map(JSONValue.string) ?? .null,
                                     "openSuggestions": .number(Double(g.openSuggestions))]
                                })])
        }

        a.register("goal.create") { [unowned self] p in
            let g = try Goals.create(title: p["title"]?.string ?? "", horizon: p["horizon"]?.string ?? "", why: p["why"]?.string ?? "", root: rootURL)
            reload()
            return ActionResult("Added the goal.", data: ["id": .string(g.id)])
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

        a.register("today.plan") { [unowned self] p in
            let day = Self.day(p["day"]?.string)
            guard let plan = DailyPlan.load(date: day, root: rootURL) else {
                return ActionResult(day == KBDate.today() ? "There's no plan for today yet. Run the morning routine to make one." : "No plan for \(day).")
            }
            func items(_ l: [DailyPlan.Item]) -> JSONValue {
                .array(l.map { ["item": .number(Double($0.line)), "text": .string($0.text), "done": .bool($0.done == true),
                                "notRelevant": .bool($0.notRelevant), "scope": $0.project.map(JSONValue.string) ?? .null,
                                "ref": $0.ref.map(JSONValue.string) ?? .null] })
            }
            let open = plan.today.filter { $0.done != true && !$0.notRelevant }
            return ActionResult(open.isEmpty ? "Everything on the plan is done." : "\(Self.count(open.count, "thing")) left today. First: \(open[0].text).",
                                data: ["day": .string(day), "today": items(plan.today), "toDecide": items(plan.toDecide), "sideGoal": items(plan.sideGoal)])
        }

        a.register("today.check") { [unowned self] p in
            let today = KBDate.today()
            guard let line = Self.intParam(p["item"]), let plan = DailyPlan.load(date: today, root: rootURL),
                  let item = (plan.today + plan.toDecide + plan.sideGoal).first(where: { $0.line == line }) else { throw ActionError("That isn't on today's plan.") }
            let done = p["done"]?.bool ?? true
            if dailyDate == today {
                setChecked(item, done: done)
            } else {
                try DailyPlan.setDone(date: today, lineText: item.lineText, done: done, root: rootURL)
                reload()
            }
            return ActionResult(done ? "Ticked it off." : "Unticked it.")
        }

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

    func entryParam(_ p: JSONValue, _ key: String = "id") throws -> EntryID {
        guard let raw = p[key]?.string, let id = EntryID(raw) else { throw ActionError("That isn't an entry id.") }
        return id
    }

    private func reminderParam(_ p: JSONValue) throws -> Reminder {
        let key = (p["id"]?.string ?? "").lowercased()
        if let r = reminders.first(where: { $0.id.lowercased() == key || $0.stem.lowercased() == key }) { return r }
        if !key.isEmpty, let r = reminders.first(where: { $0.title.lowercased().contains(key) }) { return r }
        throw ActionError("I can't find that reminder.")
    }

    private func goalParam(_ p: JSONValue) throws -> Goal {
        let key = (p["id"]?.string ?? "").lowercased()
        if let g = goals.first(where: { $0.id.lowercased() == key || $0.stem.lowercased() == key }) { return g }
        if !key.isEmpty, let g = goals.first(where: { $0.title.lowercased().contains(key) }) { return g }
        throw ActionError("I can't find that goal.")
    }

    static func reminderJSON(_ r: Reminder) -> JSONValue {
        ["id": .string(r.id), "title": .string(r.title), "due": .string(r.due), "status": .string(r.status.rawValue),
         "note": .string(r.note), "scope": r.project.map(JSONValue.string) ?? .null, "link": r.link.map { .string($0.absoluteString) } ?? .null]
    }

    /// `kb new` for a section, as the phone's `entry.new` and the `entry.create` action do. Returns the new id.
    func createEntryWithCLI(scope: String, section: String, title: String, summary: String?, tags: [String],
                            fields: [String: String], body: String?) async throws -> String {
        var args = ["new", String(section.dropLast(section.hasSuffix("s") ? 1 : 0)), "--project", scope, "--cross-project", "--title", title]
        if let summary, !summary.isEmpty { args += ["--summary", summary] }
        if !tags.isEmpty { args += ["--tags", tags.joined(separator: ",")] }
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) { args += ["--field", "\(k)=\(v)"] }
        if body != nil { args.append("--body-stdin") }
        let out = try await cli.run(args, stdin: body)
        reload()
        return out.split(separator: " ").first.map(String.init) ?? ""
    }
}
