import Foundation
import KBCore

/// Plan mode's work on the knowledge base, as engine functions and actions: entries (delete, move, tags, scopes,
/// sharing, Ask), facts, the quiz, follow-ups, discussions, ideas, research, references, reminders, goals, the day's
/// plan, syncing, people and repositories. The Mac registers its own handlers over some of these (busy marks, its
/// open document, the Ask window, the meeting window) and calls the same functions underneath.
extension MindmillEngine {
    // MARK: Entries

    /// Deletes entries with `kb delete`; returns the failures.
    public func deleteEntries(_ ids: [EntryID]) async -> [String] {
        var failures: [String] = []
        for id in ids {
            do { try await cli.deleteEntry(id) } catch { failures.append(error.localizedDescription) }
        }
        reload()
        return failures
    }

    /// Moves an entry to another scope; returns its new id.
    public func moveEntry(_ id: EntryID, to scope: String) async throws -> EntryID? {
        defer { reload() }
        let out = try await cli.run(["move", id.rawValue, "--project", scope])
        return out.components(separatedBy: .newlines).first.flatMap(EntryID.init)
    }

    /// Sets an entry's tags in its file.
    public func setEntryTags(_ id: EntryID, _ tags: [String]) throws {
        var doc = try KBStore.load(id, root: rootURL)
        doc.frontmatter.set("tags", tags.isEmpty ? nil : .list(EntryTags.normalized(tags)))
        _ = try KBStore.save(&doc, root: rootURL)
        reload()
    }

    /// The entries `changeScope` would change: scoped elsewhere, in a project that has `scope`, not already so.
    public func scopeTargets(_ scope: String, on ids: [EntryID], add: Bool) -> [EntryID] {
        ids.filter { id in
            guard let e = index.entry(id), id.project != scope, index.group(of: id.project)?.scopes.contains(scope) == true else { return false }
            return add != e.isIn(scope: scope)
        }
    }

    /// Adds or removes one scope on entries (`kb scopes`); returns the failures.
    public func changeScope(_ scope: String, on targets: [EntryID], add: Bool) async -> [String] {
        var failures: [String] = []
        for id in targets {
            do { try await cli.run(["scopes", id.rawValue, add ? "--add" : "--remove", scope]) } catch { failures.append(error.localizedDescription) }
        }
        reload()
        return failures
    }

    /// Shares an entry with the team (a copy in its repository's `knowledgebase/`) or makes it private.
    public func setShared(_ id: EntryID, _ shared: Bool) async throws {
        let r = await cli.result(["share", "set", id.rawValue, shared ? "shared" : "private"])
        guard r.status == 0 else {
            throw ActionError(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "kb: ", with: ""))
        }
    }

    // MARK: Facts

    /// Settles a proposed change to a fact: `update`, `keep` or `remove`.
    public func resolveFactChange(_ change: EntryID, how: String) async throws {
        defer { reload() }
        try await cli.run(["fact", "resolve", change.rawValue, "--\(how)"])
    }

    // MARK: Discussions, ideas and research

    /// Claude runs one of the kb:discussion skill's actions on a discussion, in a Plan session.
    @discardableResult
    public func discussionSession(_ action: String, _ id: EntryID, display: String, show: Bool = true) -> WorkSession {
        let title = index.entry(id)?.title ?? id.stem
        return sessions.newSession(title: "Discussion: \(title)", project: id.project, message: "/mindmill:discussion \(action) \(id.rawValue)",
                                   display: "\(display): \(title)", about: "discussion:\(id.rawValue)", show: show)
    }

    @discardableResult
    public func startDiscussion(project: String, lookFor: String, show: Bool = true) -> WorkSession? {
        let q = lookFor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return sessions.newSession(title: "New discussion", project: project, message: "/mindmill:discussion start \(project) \(q)",
                                   display: "Start a discussion from mail or Teams: \(q)", show: show)
    }

    public func setDiscussion(_ id: EntryID, status: DiscussionStatus, outcome: String? = nil, waitingOn: WaitingOn? = nil) async throws {
        defer { reload() }
        var args = ["discussion", "status", id.rawValue, status.rawValue]
        if let o = outcome?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty { args += ["--outcome", o] }
        if let waitingOn { args += ["--waiting-on", waitingOn.rawValue] }
        try await cli.run(args)
    }

    /// Claude runs one of the kb:idea skill's actions on an idea, in a Plan session.
    @discardableResult
    public func ideaSession(_ action: String, _ id: EntryID, display: String, show: Bool = true) -> WorkSession {
        let title = index.entry(id)?.title ?? id.stem
        return sessions.newSession(title: "Idea: \(title)", project: id.project, message: "/mindmill:idea \(action) \(id.rawValue)",
                                   display: "\(display): \(title)", about: "idea:\(id.rawValue)", show: show)
    }

    public static func noteKey(_ id: EntryID) -> String { "note:\(id.rawValue)" }

    /// The note's own Plan session, where it is talked through and sorted.
    public func noteSession(_ id: EntryID) -> WorkSession? {
        sessions.loadIfNeeded()
        return sessions.list.first { $0.about == Self.noteKey(id) }
    }

    /// Runs one of the mindmill:notes skill's actions on a note in its session, starting it the first time. `spoken`:
    /// the user talks out loud, so replies are short and read aloud.
    @discardableResult
    public func noteSession(_ action: NoteAction, _ id: EntryID, spoken: Bool = false, show: Bool = true) -> WorkSession {
        let title = index.entry(id)?.title ?? id.stem
        let command = "/mindmill:notes \(action.rawValue) \(id.rawValue)"
        let message = spoken ? SpokenReply.message(command) : command
        let display = "\(action.display): \(title)"
        if let s = noteSession(id) {
            if s.archived == true { s.archived = nil }
            sessions.send(message, in: s, display: display)
            return s
        }
        return sessions.newSession(title: "Note: \(title)", project: id.project, message: message, display: display,
                                   about: Self.noteKey(id), show: show)
    }

    /// Writes a note down; returns its id.
    public func addNote(scope: String, text: String, title: String? = nil) async throws -> EntryID {
        var args = ["note", "add", "--project", scope, "--text", text]
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { args += ["--title", t] }
        let out = try await cli.run(args)
        guard let line = out.components(separatedBy: .newlines).first, let id = EntryID(line) else {
            throw ActionError("kb note add didn't say what it made: \(out)")
        }
        reload()
        suggestForNote(id)
        return id
    }

    /// After a note is written or changed: the background model suggests where its clear parts belong, as inbox
    /// entries shown on the note, at most every two minutes per note.
    public func suggestForNote(_ id: EntryID) {
        guard id.section == .notes, claudeExecutable != nil else { return }
        if let last = noteSuggestedAt[id.rawValue], Date().timeIntervalSince(last) < 120 { return }
        noteSuggestedAt[id.rawValue] = Date()
        let waiting = suggestions(from: [id.rawValue]).map { "- \($0.proposedSection?.rawValue ?? ""): \($0.title)" }.joined(separator: "\n")
        let prompt = """
        The user just wrote or changed their note `\(id.rawValue)`. Read it with `kb show \(id.rawValue)`. For each part of it that \
        clearly belongs somewhere in their knowledge base (a fact, a decision, an idea, a follow-up, a reference, an architecture \
        note), check with `kb search "<a few words>"` that it isn't there yet, then suggest it: `kb inbox add --project \(id.project) \
        --cross-project --section <facts|decisions|ideas|followups|references|architecture> --proposed-by \(id.rawValue) --source \
        \(id.rawValue) --title "<it as a statement>" --summary "<one line>" --reason "From your note" --body "<the details>"`. \
        At most three, only clear ones; nothing when nothing fits. Already suggested, don't repeat:
        \(waiting.isEmpty ? "(none)" : waiting)
        Reply with one line: how many you suggested.
        """
        Task {
            _ = await claudeOnce(prompt, system: "You sort the user's notes into their knowledge base by suggesting entries; you never write entries directly.",
                                 model: model(for: .background), tools: ["Bash(kb:*)"], timeout: 240)
            reload()
        }
    }

    public func setNote(_ id: EntryID, status: NoteStatus) async throws {
        defer { reload() }
        try await cli.run(["note", "status", id.rawValue, status.rawValue])
    }

    public func setIdea(_ id: EntryID, status: IdeaStatus) async throws {
        defer { reload() }
        try await cli.run(["idea", "status", id.rawValue, status.rawValue])
    }

    public static func researchKey(_ id: EntryID) -> String { "research:\(id.rawValue)" }

    public func researchSession(_ id: EntryID) -> WorkSession? {
        sessions.loadIfNeeded()
        return sessions.list.first { $0.about == Self.researchKey(id) }
    }

    /// What a research is for, in words: "#1234 Title", or the entry's title.
    public func researchTargetTitle(_ target: ResearchTarget) -> String {
        switch target {
        case .workItem(let n): return "#\(n)" + (tracker.backlog?.item(n).map { " \($0.title)" } ?? "")
        case .entry(let id): return index.entry(id)?.title ?? id.stem
        }
    }

    /// Writes the research down (`kb new research`); returns its id.
    public func createResearch(scope: String, title: String, question: String, target: ResearchTarget?) async throws -> EntryID {
        var args = ["new", "research", "--scope", scope, "--title", title, "--body-stdin", "--cross-project"]
        if let target { args += ["--field", "for=\(target.rawValue)"] }
        let out = try await cli.run(args, stdin: ResearchBody.template(question: question))
        guard let line = out.components(separatedBy: .newlines).first, let id = EntryID(line) else {
            throw ActionError("kb new research didn't say what it made: \(out)")
        }
        reload()
        return id
    }

    /// The title a new research gets: the given one, else the question's first line, else what it's for.
    public func researchTitle(title: String, question: String, target: ResearchTarget?) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            let first = question.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
            t = first.count > 70 ? String(first.prefix(67)) + "…" : first
        }
        if t.isEmpty, let target { t = researchTargetTitle(target) }
        return t
    }

    /// Writes the research down and starts its session in Plan.
    public func startResearch(scope: String, target: ResearchTarget?, title: String, question: String) async throws -> (EntryID, WorkSession) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = researchTitle(title: title, question: q, target: target)
        guard !t.isEmpty else { throw ActionError("What should it research?") }
        let id = try await createResearch(scope: scope, title: t, question: q, target: target)
        let s = startResearchSession(id, message: "/mindmill:research start \(id.rawValue)", display: "Research: \(t)")
        return (id, s)
    }

    @discardableResult
    public func startResearchSession(_ id: EntryID, message: String, display: String) -> WorkSession {
        let title = index.entry(id)?.title ?? id.stem
        return sessions.newSession(title: "Research: \(title)", project: id.project, message: message, display: display,
                                   about: Self.researchKey(id), show: false, space: .plan)
    }

    /// Sends a kb:research action to the research's session, starting one when it has none. Returns a notice when it
    /// waits for the current reply.
    @discardableResult
    public func researchAction(_ action: String, _ id: EntryID, display: String) -> String? {
        let message = "/mindmill:research \(action) \(id.rawValue)"
        guard let s = researchSession(id) else {
            startResearchSession(id, message: message, display: display)
            return nil
        }
        if s.chat.isBusy {
            s.inbox.append((text: message, display: display))
            return "\(Brain.name) is busy; it does this when the current reply ends."
        }
        sessions.send(message, in: s, display: display)
        return nil
    }

    public func setResearch(_ id: EntryID, status: ResearchStatus) async throws {
        defer { reload() }
        try await cli.run(["research", "status", id.rawValue, status.rawValue])
    }

    // MARK: References

    /// Writes a reference entry. Returns its id.
    @discardableResult
    public func saveReference(project: String, title: String, kind: ReferenceKind, url: URL?, note: String, content: String,
                              fields: [String: String] = [:]) throws -> EntryID {
        var doc = try KBStore.newDocument(project: project, section: .references, title: title, root: rootURL)
        doc.frontmatter.setString("kind", kind.rawValue)
        if let url { doc.frontmatter.setString("url", url.absoluteString) }
        doc.frontmatter.setString("captured", KBDate.today())
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) { doc.frontmatter.setString(k, v) }
        doc.body = ReferenceBody.make(note: note, content: content)
        try KBStore.save(&doc, root: rootURL)
        reload()
        return doc.id
    }

    /// A Plan session that finds an email or a Teams chat and saves it to References.
    @discardableResult
    public func referenceFromMail(project: String, kind: ReferenceKind, lookFor: String, note: String, show: Bool = true) -> WorkSession? {
        let q = lookFor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = kind == .teams ? "teams" : "email"
        return sessions.newSession(title: "Save \(kind.title.lowercased())", project: project,
                                   message: "/mindmill:reference \(action) \(project) \(q)" + (n.isEmpty ? "" : "\n\nWhy it matters: \(n)"),
                                   display: "Save \(kind == .teams ? "a Teams chat" : "an email") to References: \(q)", show: show)
    }

    // MARK: Reminders

    /// A reminder by id, file stem or a word of its title.
    public func reminder(_ key: String) throws -> Reminder {
        let reminders = Reminders.load(root: rootURL)
        let k = key.lowercased()
        if let r = reminders.first(where: { $0.id.lowercased() == k || $0.stem.lowercased() == k }) { return r }
        if !k.isEmpty, let r = reminders.first(where: { $0.title.lowercased().contains(k) }) { return r }
        throw ActionError("I can't find that reminder.")
    }

    public func setReminder(_ r: Reminder, status: Reminder.Status) throws {
        defer { reload() }
        try Reminders.setStatus(r, status)
    }

    /// Sets the due day (empty: none); a done or dismissed reminder opens again.
    public func setReminder(_ r: Reminder, due: String) throws {
        defer { reload() }
        try Reminders.setDue(r, due)
        if r.status == .done || r.status == .dismissed { try Reminders.setStatus(r, .open) }
    }

    public func deleteReminder(_ r: Reminder) throws {
        defer { reload() }
        try Reminders.delete(r)
    }

    // MARK: The day's plan

    /// Ticks an item on a day's plan, and the reminder it comes from.
    public func setPlanItem(_ item: DailyPlan.Item, date: String, done: Bool) throws {
        defer { reload() }
        try DailyPlan.setDone(date: date, lineText: item.lineText, done: done, root: rootURL)
        if let ref = item.ref, let r = Reminders.load(root: rootURL).first(where: { $0.id == ref }), (r.status == .done) != done {
            try Reminders.setStatus(r, done ? .done : .open)
        }
    }

    public static func planItemsJSON(_ l: [DailyPlan.Item]) -> JSONValue {
        .array(l.map { ["item": .number(Double($0.line)), "text": .string($0.text), "done": .bool($0.done == true),
                        "notRelevant": .bool($0.notRelevant), "scope": $0.project.map(JSONValue.string) ?? .null,
                        "ref": $0.ref.map(JSONValue.string) ?? .null] })
    }

    // MARK: Syncing and repositories

    /// The Sync button: rereads the knowledge base and fetches the tracker, sprints, pull requests and the calendar again.
    public func syncAll(calendar: Bool = true) {
        reload()
        tracker.refreshBacklog(force: true)
        sprints.check(force: true)
        tracker.refreshMyWork(force: true)
        tracker.refreshPullRequests(force: true)
        if calendar, !routines.calendar.isRunning, !routines.morning.isBusy { routines.syncCalendar() }
    }

    /// Fast-forwards a scope's repositories to their remotes; never merges or overwrites local work.
    public func pullRepos(scope: String, only repo: String? = nil) async -> (ok: Bool, message: String) {
        let count = repo == nil ? ScopeRepositories.of(scope, in: index).all.filter { $0.checkout != nil }.count : 1
        let r = await cli.result(["repos", "pull", "--scope", scope] + (repo.map { ["--repo", $0] } ?? []))
        reload()
        return Self.pullOutcome(r.stdout + r.stderr, count: count, machine: platform.machineWord)
    }

    static func pullOutcome(_ output: String, count: Int, machine: String = "Mac") -> (ok: Bool, message: String) {
        let lines = output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("  ") && !$0.isEmpty }
        let failed = lines.filter { $0.contains("not pulled") || $0.contains("not on this \(machine)") || $0.contains("not on this Mac") }
        if !failed.isEmpty { return (false, failed.joined(separator: "\n")) }
        return (true, count == 1 ? "Pulled \(lines.first.map { $0.components(separatedBy: ":").first ?? "" } ?? "the repository")." : "Pulled \(count) repositories.")
    }

    // MARK: Meetings

    /// A meeting as `calendar.upcoming` lists it; `open` is whether a host has it open (the Mac's meeting window).
    public func meetingEventJSON(_ e: KBEntry, open: Bool = false) -> JSONValue {
        ["id": .string(e.id.rawValue), "title": .string(e.title), "scope": .string(e.project), "date": .string(e.date),
         "start": .string(e.field("start") ?? ""), "end": .string(e.field("end") ?? ""),
         "attendees": .array(e.listField("attendees").map(JSONValue.string)),
         "online": e.field("online_url").map(JSONValue.string) ?? .null,
         "status": .string((e.meetingStatus ?? .scheduled).rawValue), "open": .bool(open)]
    }

    /// The meetings of the next `days` days (today first), and the next one that hasn't ended.
    public func upcomingMeetings(days: Int, scopes: [String], now: Date = Date()) -> (events: [KBEntry], next: KBEntry?) {
        let from = KBDate.today(now)
        let to = KBDate.today(Calendar(identifier: .gregorian).date(byAdding: .day, value: days - 1, to: now) ?? now)
        var seen = Set<EntryID>()
        let events = scopes.flatMap { index.entries(project: $0, section: .meetings) }
            .filter { $0.date >= from && $0.date <= to && !$0.isDraft && seen.insert($0.id).inserted }
            .sorted { ($0.date, $0.field("start") ?? "") < ($1.date, $1.field("start") ?? "") }
        let clock = ActionText.clock(now)
        let next = events.first { $0.meetingStatus == .live }
            ?? events.first { $0.meetingStatus != .cancelled && ($0.date > from || ($0.field("end") ?? $0.field("start") ?? "99:99") >= clock) }
        return (events, next)
    }

    /// A Plan session that prepares a meeting with the kb:prep skill (where there is no meeting window).
    @discardableResult
    public func prepareMeeting(_ id: EntryID, show: Bool = true) -> WorkSession {
        let title = index.entry(id)?.title ?? id.stem
        return sessions.newSession(title: "Prepare: \(title)", project: id.project,
                                   message: "/mindmill:prep \(id.rawValue)", display: "Prepare “\(title)”", show: show, space: .plan)
    }

    // MARK: Actions

    func registerPlanActions() {
        let a = actions

        // MARK: Knowledge

        a.register("entry.delete") { [unowned self] p in
            let id = try entryParam(p)
            let title = index.entry(id)?.title ?? id.rawValue
            let failures = await deleteEntries([id])
            if let f = failures.first { throw ActionError(f) }
            return ActionResult("Deleted “\(title)”.")
        }

        a.register("entry.move") { [unowned self] p in
            let id = try entryParam(p)
            let to = try scopeParam(["scope": p["to"] ?? .null])
            let new = try await moveEntry(id, to: to)
            return ActionResult("Moved it to \(index.project(to)?.title ?? to).", data: ["id": new.map { .string($0.rawValue) } ?? .null])
        }

        a.register("entry.tags") { [unowned self] p in
            let id = try entryParam(p)
            let tags = p["tags"]?.strings ?? []
            try setEntryTags(id, tags)
            return ActionResult(tags.isEmpty ? "Removed its tags." : "Tagged it " + ActionText.list(tags) + ".")
        }

        a.register("entry.scopes") { [unowned self] p in
            let id = try entryParam(p)
            let scope = try scopeParam(p)
            let add = p["add"]?.bool ?? true
            let targets = scopeTargets(scope, on: [id], add: add)
            if !targets.isEmpty, let f = await changeScope(scope, on: targets, add: add).first { throw ActionError(f) }
            return ActionResult(add ? "Added it to \(scope)." : "Took it out of \(scope).")
        }

        a.register("entry.share") { [unowned self] p in
            let id = try entryParam(p)
            let shared = p["shared"]?.bool ?? true
            try await setShared(id, shared)
            return ActionResult(shared ? "Shared it with the team." : "Made it private.")
        }

        a.register("entry.ask") { [unowned self] p in
            let id = try entryParam(p)
            let s = sessions.newSession(subject: .entry(id, title: index.entry(id)?.title ?? id.stem), space: .plan)
            return ActionResult("Opened a session about it on the \(platform.machineWord).", data: ["session": .string(s.id)])
        }

        // MARK: Facts

        a.register("fact.link") { [unowned self] p in
            let a = try entryParam(p)
            guard let raw = p["other"]?.string, let b = EntryID(raw) else { throw ActionError("Which other fact?") }
            let remove = p["remove"]?.bool ?? false
            try await plan.linkFacts(a, b, remove: remove)
            return ActionResult(remove ? "Unlinked them." : "Linked them.")
        }

        a.register("fact.links.suggest") { [unowned self] p in
            let id = try entryParam(p)
            guard let found = await plan.suggestFactLinks(id) else { return ActionResult("Already looking for its links.") }
            let titled: [JSONValue] = found.map { s in
                ["id": .string(s.id), "why": .string(s.why), "title": .string(EntryID(s.id).flatMap { index.entry($0)?.title } ?? s.id)]
            }
            return ActionResult(found.isEmpty ? "\(Brain.name) found no closely related facts."
                                : "\(ActionText.count(found.count, "possible link")). The first: \(titled[0]["title"]?.string ?? "").",
                                data: ["suggestions": .array(titled)])
        }

        a.register("fact.change.resolve") { [unowned self] p in
            let id = try entryParam(p)
            let update = p["how"]?.string == "update"
            try await resolveFactChange(id, how: update ? "update" : "keep")
            return ActionResult(update ? "Updated the fact." : "Kept the fact as it is.")
        }

        a.register("fact.change.remove") { [unowned self] p in
            try await resolveFactChange(try entryParam(p), how: "remove")
            return ActionResult("Removed the fact.")
        }

        a.register("quiz.round") { [unowned self] p in
            let scope = try scopeParam(p)
            let facts = index.entries(project: scope, section: .facts).filter { !$0.isDraft }
            guard !facts.isEmpty else { return ActionResult("There are no facts to quiz on yet.") }
            let qs = await plan.quizRound(from: facts, count: max(1, min(10, p["count"]?.int ?? 5)))
            guard let first = qs.first else { throw ActionError("Couldn't make questions right now.") }
            return ActionResult("First question: \(first.question)", data: ["questions": .array(qs.map {
                ["fact": .string($0.fact), "question": .string($0.question), "answer": .string($0.answer)]
            })])
        }

        a.register("quiz.answer") { [unowned self] p in
            guard let fact = p["fact"]?.string else { throw ActionError("Which fact?") }
            try plan.recordQuizAnswer(fact, correct: p["correct"]?.bool ?? false)
            return ActionResult("Noted.")
        }

        // MARK: Follow-ups

        a.register("followups.duplicates") { [unowned self] p in
            let scope = try scopeParam(p)
            guard let n = await plan.findDuplicateFollowups(project: scope) else { return ActionResult("Already looking for duplicates.") }
            return ActionResult(n == 0 ? "No duplicate follow-ups found." : "Found \(n) possible duplicate\(n == 1 ? "" : "s"). Review them at the top of Follow-ups.",
                                data: ["proposed": .number(Double(n))])
        }

        a.register("followup.merge") { [unowned self] p in
            guard let keep = p["keep"]?.string, let other = p["other"]?.string else { throw ActionError("Which two?") }
            try await plan.mergeFollowups(keep: keep, other: other)
            return ActionResult("Merged them.")
        }

        a.register("followups.check") { [unowned self] p in
            if let nothing = plan.checkFollowupsNow(project: try scopeParam(p)) { return ActionResult(nothing) }
            return ActionResult("Checking the open follow-ups.")
        }

        // MARK: Discussions

        a.register("discussion.start") { [unowned self] p in
            let scope = try scopeParam(p)
            guard startDiscussion(project: scope, lookFor: p["look_for"]?.string ?? "", show: false) != nil else {
                throw ActionError("What should it look for?")
            }
            return ActionResult("Looking for that discussion; it shows under Discussions when found.")
        }

        a.register("discussion.status") { [unowned self] p in
            let id = try entryParam(p)
            guard let status = p["status"]?.string.flatMap(DiscussionStatus.init(rawValue:)) else { throw ActionError("Which status?") }
            if status == .concluded, (p["outcome"]?.string ?? "").isEmpty {
                discussionSession("conclude", id, display: "Conclude the discussion", show: false)
                return ActionResult("Concluding it in a session.")
            }
            try await setDiscussion(id, status: status, outcome: p["outcome"]?.string)
            return ActionResult("It's \(status.rawValue) now.")
        }

        a.register("discussion.waiting") { [unowned self] p in
            let id = try entryParam(p)
            guard let who = p["on"]?.string.flatMap(WaitingOn.init(rawValue:)) else { throw ActionError("Waiting on whom?") }
            guard let e = index.entry(id) else { throw ActionError("I can't find that discussion.") }
            try await setDiscussion(id, status: e.discussionStatus, waitingOn: who)
            return ActionResult(who == .nobody ? "It waits on nobody." : "It waits on \(who == .me ? "you" : "others").")
        }

        a.register("discussion.refresh") { [unowned self] p in
            discussionSession("refresh", try entryParam(p), display: "Check for new replies", show: false)
            return ActionResult("Checking for new replies.")
        }

        a.register("discussion.file") { [unowned self] p in
            discussionSession("file", try entryParam(p), display: "File the findings", show: false)
            return ActionResult("Filing what it found.")
        }

        // MARK: Ideas and research

        a.register("idea.status") { [unowned self] p in
            let id = try entryParam(p)
            guard let s = p["status"]?.string.flatMap(IdeaStatus.init(rawValue:)) else { throw ActionError("Which status?") }
            try await setIdea(id, status: s)
            return ActionResult("The idea is \(s.rawValue) now.")
        }

        a.register("idea.turn") { [unowned self] p in
            let id = try entryParam(p)
            guard let into = p["into"]?.string.flatMap(IdeaOutcome.init(rawValue:)) else { throw ActionError("Into what?") }
            ideaSession("turn \(into.rawValue)", id, display: "Turn it into \(into.title.lowercased())", show: false)
            return ActionResult("Turning it into a \(into.rawValue) in a session.")
        }

        a.register("note.add") { [unowned self] p in
            guard let text = p["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ActionError("What should the note say?") }
            let id = try await addNote(scope: try scopeParam(p), text: text, title: p["title"]?.string)
            return ActionResult("Noted.", data: ["id": .string(id.rawValue)])
        }

        a.register("note.discuss") { [unowned self] p in
            let s = noteSession(.discuss, try entryParam(p), spoken: p["spoken"]?.bool == true, show: false)
            return ActionResult("Talking it through in its session.", data: ["session": .string(s.id)])
        }

        a.register("note.sort") { [unowned self] p in
            let s = noteSession(.sort, try entryParam(p), show: false)
            return ActionResult("Sorting it in its session; the suggestions show on the note.", data: ["session": .string(s.id)])
        }

        a.register("note.status") { [unowned self] p in
            let id = try entryParam(p)
            guard let s = p["status"]?.string.flatMap(NoteStatus.init(rawValue:)) else { throw ActionError("Which status?") }
            try await setNote(id, status: s)
            return ActionResult(s == .filed ? "Marked as filed." : "Open again.")
        }

        a.register("idea.brainstorm") { [unowned self] p in
            ideaSession("brainstorm", try entryParam(p), display: "Brainstorm", show: false)
            return ActionResult("Started brainstorming in a session.")
        }

        a.register("research.start") { [unowned self] p in
            let scope = try scopeParam(p)
            var target: ResearchTarget?
            if let n = ActionText.intParam(p["work_item"]) { target = .workItem(n) }
            if let raw = p["entry"]?.string, let e = EntryID(raw) { target = .entry(e) }
            let (id, s) = try await startResearch(scope: scope, target: target, title: p["title"]?.string ?? "",
                                                  question: p["question"]?.string ?? "")
            return ActionResult("Started the research.", data: ["id": .string(id.rawValue), "session": .string(s.id)])
        }

        a.register("research.continue") { [unowned self] p in
            let said = researchAction("continue", try entryParam(p), display: "Continue")
            return ActionResult(said ?? "Carrying on with it.")
        }

        a.register("research.finish") { [unowned self] p in
            let said = researchAction("finish", try entryParam(p), display: "Finish")
            return ActionResult(said ?? "Summarising it; pick what to keep on the \(platform.machineWord) or the phone.")
        }

        a.register("research.status") { [unowned self] p in
            let id = try entryParam(p)
            guard let s = p["status"]?.string.flatMap(ResearchStatus.init(rawValue:)) else { throw ActionError("Which status?") }
            try await setResearch(id, status: s)
            return ActionResult("The research is \(s.rawValue) now.")
        }

        // MARK: References

        a.register("reference.save") { [unowned self] p in
            let scope = try scopeParam(p)
            let url = p["url"]?.string.flatMap(URL.init(string:))
            let kind = p["kind"]?.string.flatMap(ReferenceKind.init(rawValue:)) ?? (url == nil ? .note : .web)
            let id = try saveReference(project: scope, title: p["title"]?.string ?? "", kind: kind, url: url,
                                       note: p["note"]?.string ?? "", content: "")
            return ActionResult("Saved it to References.", data: ["id": .string(id.rawValue)])
        }

        a.register("reference.from_mail") { [unowned self] p in
            let scope = try scopeParam(p)
            let kind: ReferenceKind = p["kind"]?.string == "teams" ? .teams : .email
            guard referenceFromMail(project: scope, kind: kind, lookFor: p["look_for"]?.string ?? "", note: p["note"]?.string ?? "",
                                    show: false) != nil else { throw ActionError("What should it look for?") }
            return ActionResult("Looking for it; it shows under References when saved.")
        }

        // MARK: Reminders and goals

        a.register("reminder.create") { [unowned self] p in
            let title = p["title"]?.string ?? ""
            let due = p["due"]?.string.map { ActionText.day($0) } ?? ""
            let r = try Reminders.create(title: title, due: due, note: p["note"]?.string ?? "",
                                         project: try p["scope"]?.string.map { try scopeParam(["scope": .string($0)]) },
                                         link: p["link"]?.string ?? "", root: rootURL)
            reload()
            return ActionResult("I'll remind you" + (due.isEmpty ? "." : " on \(due)."), data: Self.reminderJSON(r))
        }

        a.register("reminder.update") { [unowned self] p in
            var r = try reminder(p["id"]?.string ?? "")
            var said: [String] = []
            if let s = p["status"]?.string.flatMap(Reminder.Status.init(rawValue:)) {
                try setReminder(r, status: s)
                said.append(s.rawValue)
                r = (try? reminder(r.id)) ?? r
            }
            if let d = p["due"]?.string {
                let due = d == "none" || d.isEmpty ? "" : ActionText.day(d)
                try setReminder(r, due: due)
                said.append(due.isEmpty ? "without a date" : "due \(due)")
            }
            return ActionResult(said.isEmpty ? "Nothing to change." : "It's " + ActionText.list(said) + " now.")
        }

        a.register("reminder.delete") { [unowned self] p in
            try deleteReminder(try reminder(p["id"]?.string ?? ""))
            return ActionResult("Deleted it.")
        }

        a.register("goal.status") { [unowned self] p in
            let g = try plan.goal(p["id"]?.string ?? "")
            guard let s = p["status"]?.string.flatMap(Goal.Status.init(rawValue:)) else { throw ActionError("Which status?") }
            try plan.updateGoal(g) { $0.frontmatter.set("status", .string(s.rawValue)) }
            return ActionResult("The goal is \(s.rawValue) now.")
        }

        a.register("goal.progress") { [unowned self] p in
            guard try plan.logGoalProgress(try plan.goal(p["id"]?.string ?? ""), p["text"]?.string ?? "") else {
                throw ActionError("What did you do?")
            }
            return ActionResult("Logged it.")
        }

        a.register("goal.coach") { [unowned self] p in
            try plan.sendToGoalCoach(try plan.goal(p["id"]?.string ?? ""), p["text"]?.string ?? "", show: false)
            return ActionResult("Asked the coach; the answer shows with the goal.")
        }

        a.register("goal.delete") { [unowned self] p in
            try plan.deleteGoal(try plan.goal(p["id"]?.string ?? ""))
            return ActionResult("Deleted the goal.")
        }

        // MARK: Today

        a.register("today.plan") { [unowned self] p in
            let day = ActionText.day(p["day"]?.string)
            guard let plan = DailyPlan.load(date: day, root: rootURL) else {
                return ActionResult(day == KBDate.today() ? "There's no plan for today yet. Run the morning routine to make one." : "No plan for \(day).")
            }
            let open = plan.today.filter { $0.done != true && !$0.notRelevant }
            return ActionResult(open.isEmpty ? "Everything on the plan is done." : "\(ActionText.count(open.count, "thing")) left today. First: \(open[0].text).",
                                data: ["day": .string(day), "today": Self.planItemsJSON(plan.today), "toDecide": Self.planItemsJSON(plan.toDecide),
                                       "sideGoal": Self.planItemsJSON(plan.sideGoal)])
        }

        a.register("today.check") { [unowned self] p in
            let today = KBDate.today()
            guard let line = ActionText.intParam(p["item"]), let plan = DailyPlan.load(date: today, root: rootURL),
                  let item = (plan.today + plan.toDecide + plan.sideGoal).first(where: { $0.line == line }) else { throw ActionError("That isn't on today's plan.") }
            let done = p["done"]?.bool ?? true
            try setPlanItem(item, date: today, done: done)
            return ActionResult(done ? "Ticked it off." : "Unticked it.")
        }

        a.register("today.morning") { [unowned self] _ in
            guard !routines.morning.isBusy else { return ActionResult("The morning routine is running already.") }
            guard routines.runMorning() else { throw ActionError(claudeMissingExplanation) }
            return ActionResult("Running the morning routine.")
        }

        a.register("sync.calendar") { [unowned self] _ in
            guard await resolveCalendarSource().isSet else { throw ActionError(RoutineCenter.noCalendar) }
            guard routines.syncCalendar() else {
                throw ActionError(claudeExecutable == nil ? claudeMissingExplanation : "The calendar is syncing already.")
            }
            return ActionResult("Syncing the calendar.")
        }

        a.register("sync.email") { [unowned self] _ in
            guard routines.syncEmail() else { throw ActionError(claudeExecutable == nil ? claudeMissingExplanation : "Mail is being read already.") }
            return ActionResult("Reading new mail.")
        }

        a.register("sync.all") { [unowned self] _ in
            syncAll()
            return ActionResult("Syncing everything.")
        }

        // MARK: Meetings

        a.register("calendar.upcoming") { [unowned self] p in
            let days = max(1, min(14, p["days"]?.int ?? 1))
            let scopes = try p["scope"]?.string.map { [try scopeParam(["scope": .string($0)])] } ?? index.projects.map(\.id)
            let (events, next) = upcomingMeetings(days: days, scopes: scopes)
            let from = KBDate.today()
            let speech: String
            if let next {
                let when = next.meetingStatus == .live ? "running now" : next.date == from ? "at \(next.field("start") ?? "a time not set")" : "on \(next.date) at \(next.field("start") ?? "?")"
                speech = "\(ActionText.count(events.count, "meeting")). Next: \(next.title), \(when)."
            } else {
                speech = events.isEmpty ? "No meetings coming up." : "No more meetings \(days == 1 ? "today" : "in that time")."
            }
            return ActionResult(speech, data: ["events": .array(events.map { meetingEventJSON($0) }),
                                               "next": next.map { .string($0.id.rawValue) } ?? .null])
        }

        a.register("meeting.prepare") { [unowned self] p in
            let id = try entryParam(p, "meeting")
            guard id.section == .meetings else { throw ActionError("That isn't a meeting.") }
            let s = prepareMeeting(id, show: false)
            return ActionResult("Preparing it in a session.", data: ["session": .string(s.id)])
        }

        // MARK: People and repositories

        a.register("people.list") { [unowned self] p in
            if !plan.peopleLoaded { plan.loadPeople() }
            let q = (p["query"]?.string ?? "").lowercased()
            let list = plan.people.all.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.email.lowercased().contains(q) }
            return ActionResult("\(ActionText.count(list.count, "person", plural: "people")).",
                                data: ["people": .array(list.prefix(100).map { ["name": .string($0.name), "email": .string($0.email)] })])
        }

        a.register("people.refresh") { [unowned self] _ in
            plan.refreshPeople(force: true)
            return ActionResult("Reading the people directory again.")
        }

        a.register("repos.pull") { [unowned self] p in
            let (ok, message) = await pullRepos(scope: try scopeParam(p))
            if !ok { throw ActionError(message) }
            return ActionResult(message)
        }
    }
}
