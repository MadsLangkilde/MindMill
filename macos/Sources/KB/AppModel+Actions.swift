import Foundation
import KBCore

struct ActionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The handlers behind the action catalog. Each calls the same function the matching button calls, so whatever
/// voice or the phone does shows in the UI at once, and the other way round.
extension AppModel {
    func registerActions() {
        let a = actions
        a.confirmsRisky = VoicePreferences.load().confirmsRisky
        a.onRun = { [unowned self] name, channel, result in forwardVoiceAction(name, channel, result) }

        a.register("overview") { [unowned self] p in
            let scope = try scopeParam(p)
            let proposed = factProposals(project: scope).count
            let open = openFollowups(scope)
            let mine = open.filter { $0.responsibility(me: myNames) == .me }.count
            let items = trackerItems(scope: scope).filter { $0.mine && $0.stage != .done && $0.stage != .resolved }
            let running = factories.filter(\.isRunning)
            let questions = allOpenQuestions().count
            let waiting = sessions.filter { !sessionArchived($0) && $0.crewState.needsUser }
            var parts: [String] = []
            if proposed > 0 { parts.append(Self.count(proposed, "proposed fact")) }
            if mine > 0 { parts.append(Self.count(mine, "follow-up") + " on you") }
            if open.count > mine { parts.append("\(open.count - mine) waiting on others") }
            if !items.isEmpty { parts.append(Self.count(items.count, "work item") + " assigned to you") }
            if !running.isEmpty { parts.append(Self.count(running.count, "factory", plural: "factories") + " running") }
            if questions > 0 { parts.append(Self.count(questions, "factory question")) }
            if !waiting.isEmpty { parts.append(Self.count(waiting.count, "session") + " waiting for you") }
            let speech = parts.isEmpty ? "Nothing needs you right now." : "You have " + Self.list(parts) + "."
            return ActionResult(speech, data: [
                "scope": .string(scope), "proposedFacts": .number(Double(proposed)), "followupsMine": .number(Double(mine)),
                "followupsWaiting": .number(Double(open.count - mine)), "workItems": .number(Double(items.count)),
                "factoriesRunning": .number(Double(running.count)), "factoryQuestions": .number(Double(questions)),
                "sessionsWaiting": .array(waiting.map(remoteSession)),
            ])
        }

        a.register("projects.list") { [unowned self] _ in
            let list = index.projects.map { p -> JSONValue in ["id": .string(p.id), "title": .string(p.title), "current": .bool(p.id == projectID)] }
            let current = index.projects.first { $0.id == projectID }?.title
            return ActionResult(current.map { "The current project is \($0), of \(index.projects.count)." } ?? "\(index.projects.count) projects.",
                                data: ["projects": .array(list)])
        }

        a.register("knowledge.search") { [unowned self] p in
            let q = p["query"]?.string ?? ""
            let found = index.search(q, project: p["scope"]?.string).flatMap(\.entries).filter { !$0.isDraft }.prefix(12)
            guard !found.isEmpty else { return ActionResult("I found nothing about \(q).") }
            let top = found.prefix(3).map { "\($0.title)" }
            return ActionResult("I found \(Self.count(found.count, "entry", plural: "entries")). The first: " + Self.list(top) + ".",
                                data: ["entries": .array(found.map(Self.remoteSummary))])
        }

        a.register("entry.read") { [unowned self] p in
            guard let raw = p["id"]?.string, let id = EntryID(raw) else { throw ActionError("That isn't an entry id.") }
            let doc = try KBStore.load(id, root: rootURL)
            let title = doc.frontmatter["title"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? raw
            return ActionResult(title, data: ["id": .string(raw), "title": .string(title), "body": .string(String(doc.body.prefix(12000)))])
        }

        a.register("facts.list") { [unowned self] p in
            let scope = try scopeParam(p)
            let facts = index.entries(project: scope, section: .facts).filter { !$0.isDraft }.sorted { $0.date > $1.date }
            let list = facts.prefix(p["limit"]?.int ?? 20)
            return ActionResult(Self.count(facts.count, "fact") + ".", data: ["entries": .array(list.map(Self.remoteSummary))])
        }

        a.register("facts.proposed") { [unowned self] p in
            let scope = try scopeParam(p)
            let list = factProposals(project: scope)
            guard let first = list.first else { return ActionResult("No proposed facts are waiting.") }
            return ActionResult("\(Self.count(list.count, "proposed fact")) waiting. The first: \(first.title). \(first.summary)",
                                data: ["entries": .array(list.map(Self.remoteSummary))])
        }

        a.register("fact.approve") { [unowned self] p in
            approveInbox([try entryParam(p)])
            return ActionResult("Approved.")
        }

        a.register("fact.decline") { [unowned self] p in
            rejectInbox([try entryParam(p)])
            return ActionResult("Declined.")
        }

        a.register("meetings.list") { [unowned self] p in
            let scope = try scopeParam(p)
            let day = Self.day(p["day"]?.string)
            let list = index.entries(project: scope, section: .meetings).filter { $0.date.hasPrefix(day) }
                .sorted { ($0.field("start") ?? "") < ($1.field("start") ?? "") }
            guard !list.isEmpty else { return ActionResult("No meetings on \(day).") }
            return ActionResult("\(Self.count(list.count, "meeting")): " + Self.list(list.prefix(5).map(\.title)) + ".",
                                data: ["day": .string(day), "entries": .array(list.map(Self.remoteSummary))])
        }

        a.register("followups.list") { [unowned self] p in
            let scope = try scopeParam(p)
            let filter = p["filter"]?.string ?? "mine"
            var list = openFollowups(scope)
            if filter == "mine" { list = list.filter { $0.responsibility(me: myNames) == .me } }
            if filter == "waiting" { list = list.filter { $0.responsibility(me: myNames) == .others } }
            guard !list.isEmpty else { return ActionResult(filter == "waiting" ? "Nothing is waiting on others." : "No open follow-ups.") }
            return ActionResult("\(Self.count(list.count, "follow-up")). The first: " + Self.list(list.prefix(3).map(\.title)) + ".",
                                data: ["entries": .array(list.map(Self.remoteSummary))])
        }

        a.register("followup.create") { [unowned self] p in
            let scope = try scopeParam(p)
            let title = p["title"]?.string ?? ""
            var args = ["new", "followup", "--project", scope, "--cross-project", "--title", title,
                        "--type", p["kind"]?.string ?? "action", "--status", "open"]
            if let owner = p["owner"]?.string, !owner.isEmpty { args += ["--field", "owner=\(owner)"] }
            if let due = p["due"]?.string, !due.isEmpty { args += ["--field", "due=\(due)"] }
            let out = try await cli.run(args)
            reload()
            let id = out.split(separator: " ").first.map(String.init) ?? ""
            return ActionResult("Added the follow-up.", data: ["id": .string(id)])
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
            let out = try await cli.run(["tracker", "item", String(id)])
            let item = tracker?.items.first { $0.id == id }
            return ActionResult(item.map { "\($0.id): \($0.title), \($0.state), assigned to \($0.assignee.isEmpty ? "nobody" : $0.assignee)." } ?? "Work item \(id).",
                                data: ["id": .number(Double(id)), "text": .string(String(out.prefix(12000)))])
        }

        a.register("workitem.create") { [unowned self] p in
            let scope = try scopeParam(p)
            let title = p["title"]?.string ?? ""
            var args = ["new", "backlog", "--project", scope, "--cross-project", "--title", title, "--type", p["kind"]?.string ?? "pbi"]
            let body = p["description"]?.string
            if body != nil { args.append("--body-stdin") }
            let out = try await cli.run(args, stdin: body)
            let entry = out.split(separator: " ").first.map(String.init) ?? ""
            guard !entry.isEmpty else { throw ActionError("Couldn't write the backlog entry.") }
            let posted = try await cli.run(["backlog", "create", entry, "--sprint", p["sprint"]?.string ?? "none", "--yes"])
            reload()
            refreshTracker(force: true)
            let number = posted.range(of: "#[0-9]+", options: .regularExpression).map { String(posted[$0].dropFirst()) }
            return ActionResult(number.map { "Created work item \($0)." } ?? "Created it.", data: ["entry": .string(entry), "output": .string(posted)])
        }

        a.register("workitem.update") { [unowned self] p in
            guard let id = Self.intParam(p["id"]).map(String.init) else { throw ActionError("Which work item?") }
            var said: [String] = []
            if let state = p["state"]?.string, !state.isEmpty {
                _ = try await cli.run(["tracker", "state", "--state", state, id]); said.append("set to \(state)")
            }
            if let who = p["assignee"]?.string, !who.isEmpty {
                _ = try await cli.run(["tracker", "assign", "--to", who, id]); said.append("assigned to \(who)")
            }
            if let sprint = p["sprint"]?.string, !sprint.isEmpty {
                var args = ["tracker", "move", "--sprint", sprint, id]
                if let scope = p["scope"]?.string { args += ["--project", scope] }
                _ = try await cli.run(args); said.append("moved to \(sprint)")
            }
            if let comment = p["comment"]?.string, !comment.isEmpty {
                _ = try await cli.run(["tracker", "note", id, "--text", comment, "--comment"]); said.append("commented")
            }
            refreshTracker(force: true)
            return ActionResult(said.isEmpty ? "Nothing to change." : "Work item \(id) " + Self.list(said) + ".")
        }

        a.register("factories.status") { [unowned self] _ in
            loadFactoriesIfNeeded()
            guard !factories.isEmpty else { return ActionResult("There are no factories yet.") }
            let lines = factories.map { f -> String in
                guard let run = f.run else { return "\(f.name) hasn't run" }
                let state = run.isPaused ? "is paused" : run.status == .running ? "is running" : run.status == .windingDown ? "is finishing up" : "is stopped"
                let working = run.activeTasks.count
                return "\(f.name) \(state)" + (working > 0 ? ", working on \(Self.count(working, "item"))" : "")
                    + (run.openQuestions.isEmpty ? "" : ", with \(Self.count(run.openQuestions.count, "question"))")
            }
            return ActionResult(Self.list(lines) + ".", data: ["factories": .array(factories.map(Self.factoryJSON))])
        }

        a.register("factory.start") { [unowned self] p in
            let f = try factoryParam(p)
            guard f.rules.problems.isEmpty else { throw ActionError(f.rules.problems.joined(separator: " ")) }
            startFactory(f.id)
            return ActionResult("Started \(f.name).")
        }
        a.register("factory.pause") { [unowned self] p in
            let f = try factoryParam(p)
            guard f.run?.status == .running else { throw ActionError("\(f.name) isn't running.") }
            pauseFactory(f.id)
            return ActionResult("Paused \(f.name). Sessions working carry on.")
        }
        a.register("factory.resume") { [unowned self] p in
            let f = try factoryParam(p)
            guard f.run?.isPaused == true else { throw ActionError("\(f.name) isn't paused.") }
            resumeFactory(f.id)
            return ActionResult("Resumed \(f.name).")
        }
        a.register("factory.stop") { [unowned self] p in
            let f = try factoryParam(p)
            guard f.run?.status == .running else { throw ActionError("\(f.name) isn't running.") }
            stopFactory(f.id)
            return ActionResult("Stopping \(f.name). Its sessions finish the step they're on.")
        }
        a.register("factory.settings") { [unowned self] p in
            let f = try factoryParam(p)
            var rules = f.rules
            var said: [String] = []
            if let n = Self.intParam(p["max_parallel"]) {
                rules.maxParallel = max(1, min(10, n)); said.append("\(rules.maxParallel) at a time")
            }
            if let q = p["questions"]?.string.flatMap(FactoryRules.Questions.init(rawValue:)) {
                rules.questions = q; said.append(q.title.lowercased())
            }
            if case .number(let h)? = p["hours"] {
                if h <= 0 { rules.duration = .untilStopped; said.append("runs until stopped") }
                else { rules.duration = .hours; rules.hours = h; said.append("runs for \(h.formatted()) hours") }
            }
            _ = saveFactory(id: f.id, name: f.name, rules: rules)
            return ActionResult(said.isEmpty ? "Nothing to change." : "\(f.name) now " + Self.list(said) + ".")
        }
        a.register("factory.answer") { [unowned self] p in
            guard let raw = p["question"]?.string, let answer = p["answer"]?.string else { throw ActionError("Which question?") }
            guard let (f, q) = factories.lazy.compactMap({ f in f.run?.openQuestions.first { $0.id.uuidString.lowercased().hasPrefix(raw.lowercased()) }.map { (f, $0) } }).first
            else { throw ActionError("That question is already answered or gone.") }
            answerFactoryQuestion(f.id, q.id, answer: answer)
            return ActionResult("Answered.")
        }

        a.register("sessions.list") { [unowned self] _ in
            loadSessionsIfNeeded()
            let list = sessions.filter { !sessionArchived($0) }.sorted { $0.updated > $1.updated }
            let waiting = list.filter { $0.crewState.needsUser }
            let speech = waiting.isEmpty ? "\(Self.count(list.count, "session")), none waiting for you."
                : "\(Self.count(waiting.count, "session")) waiting for you: " + Self.list(waiting.prefix(3).map(\.title)) + "."
            return ActionResult(speech, data: ["sessions": .array(list.prefix(40).map(remoteSession))])
        }
        a.register("session.read") { [unowned self] p in
            guard let s = session(p["id"]?.string) else { throw ActionError("No such session.") }
            let items = s.chat.items.filter { $0.role == .user || $0.role == .assistant }.suffix(p["last"]?.int ?? 4)
            let last = items.last { $0.role == .assistant }?.text ?? ""
            return ActionResult(last.isEmpty ? "Nothing from \(Brain.name) yet." : String(last.prefix(600)),
                                data: ["items": .array(items.map { ["role": .string($0.role.rawValue), "text": .string($0.text)] })])
        }
        a.register("session.start") { [unowned self] p in
            let space: SessionSpace = p["space"]?.string == "build" ? .build : .plan
            let s = newSession(title: p["title"]?.string, project: p["scope"]?.string ?? projectID, message: p["message"]?.string,
                               show: false, space: space)
            return ActionResult("Started a \(space == .build ? "Build" : "Plan") session.", data: ["id": .string(s.id)])
        }
        a.register("session.send") { [unowned self] p in
            guard let s = session(p["id"]?.string), let text = p["text"]?.string else { throw ActionError("No such session.") }
            send(text, in: s)
            return ActionResult("Sent.")
        }
        a.register("test.status") { [unowned self] p in
            let scope = try scopeParam(p)
            return testStatusResult(scope: scope)
        }

        registerPlanActions()
        registerWorkActions()
        registerAppActions()
        assert(a.unhandled.isEmpty, "Actions without a handler: \(a.unhandled)")
    }

    // MARK: Helpers

    func scopeParam(_ p: JSONValue) throws -> String {
        if let s = p["scope"]?.string, !s.isEmpty {
            if let match = index.projects.first(where: { $0.id == s || $0.title.lowercased() == s.lowercased() }) { return match.id }
            throw ActionError("I don't know the project \(s).")
        }
        guard let id = projectID ?? index.projects.first?.id else { throw ActionError("Open a project first.") }
        return id
    }

    func factoryParam(_ p: JSONValue) throws -> Factory {
        loadFactoriesIfNeeded()
        let key = (p["factory"]?.string ?? "").lowercased()
        if let f = factories.first(where: { $0.id.lowercased() == key || $0.name.lowercased() == key }) { return f }
        if let f = factories.first(where: { $0.name.lowercased().contains(key) }), !key.isEmpty { return f }
        if factories.count == 1, let f = factories.first { return f }
        throw ActionError(factories.isEmpty ? "There are no factories yet." : "Which factory: " + Self.list(factories.map(\.name), or: true) + "?")
    }

    func openFollowups(_ scope: String) -> [KBEntry] {
        index.entries(project: scope, section: .followups).filter { !$0.isDraft && ($0.rawStatus.isEmpty || $0.rawStatus == "open") }
    }

    static func factoryJSON(_ f: Factory) -> JSONValue {
        let run = f.run
        let status = run == nil ? "never" : run!.isPaused ? "paused" : run!.status.rawValue
        return [
            "id": .string(f.id), "name": .string(f.name), "status": .string(status),
            "progress": run?.progress().map { .number($0) } ?? .null,
            "maxParallel": .number(Double(f.rules.maxParallel)), "questionsMode": .string(f.rules.questions.rawValue),
            "tasks": .array((run?.activeTasks ?? []).map { t in
                ["workItem": .number(Double(t.workItem)), "title": .string(t.title), "session": .string(t.sessionID),
                 "milestone": run?.lastMilestone(for: t.workItem).map { .string($0.text) } ?? .null]
            }),
            "questions": .array((run?.openQuestions ?? []).map { q in
                ["id": .string(q.id.uuidString), "text": .string(q.text), "options": .array(q.options.map(JSONValue.string)),
                 "workItem": q.workItem.map { .number(Double($0)) } ?? .null]
            }),
        ]
    }

    static func intParam(_ v: JSONValue?) -> Int? {
        switch v {
        case .number(let n)?: return Int(n)
        case .string(let s)?: return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
        default: return nil
        }
    }

    static func day(_ raw: String?, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        switch raw?.lowercased() {
        case "tomorrow"?: return f.string(from: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now)
        case "yesterday"?: return f.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now)
        case let s? where s.count == 10 && s.first?.isNumber == true: return s
        default: return f.string(from: now)
        }
    }

    static func count(_ n: Int, _ word: String, plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? word : plural ?? word + "s")
    }

    static func list(_ parts: [String], or: Bool = false) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + (or ? " or " : " and ") + parts.last!
        }
    }
}

