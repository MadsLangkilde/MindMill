import Foundation
import KBCore

/// Build mode in the engine: the sessions, the crew, the factories and the tracker cache, as remote-api methods and
/// actions. A host may register richer handlers over these (the Mac adds busy marks and navigation).
extension MindmillEngine {
    // MARK: Messages for the user

    /// Tells the user something: the desktop shells' notice bar, and the host's own (`onReport`).
    public func report(_ text: String, error: Bool = false) {
        tell(text)
        onReport?(text, error)
    }

    /// Keeps the sessions, the crew folder and the factories in `folder` instead of the data folder (tests, a second
    /// engine). Call it before anything loads them.
    public func isolate(in folder: URL) {
        dataFolder = folder
        sessions.storeURL = folder.appendingPathComponent("sessions.json")
        sessions.crewDirectory = folder.appendingPathComponent("crew")
        factories.storeURL = folder.appendingPathComponent("factories.json")
        scans.directory = folder.appendingPathComponent("scans")
        sprints.watchURL = folder.appendingPathComponent("sprints.json")
        backlog.verdictsURL = folder.appendingPathComponent("duplicate-checks.json")
    }

    // MARK: One-off prompts

    /// One prompt to Claude, never saved; nil when it fails or takes longer than `timeout`. Without `tools` it can
    /// only read files; it never writes.
    public func claudeOnce(_ prompt: String, system: String, model: String = "sonnet", tools: [String] = [],
                           timeout: TimeInterval = 120) async -> String? {
        guard var launch = launch(prompt: system, sessionID: UUID().uuidString.lowercased(), resume: false, model: model,
                                  cwd: rootURL, tools: tools.isEmpty ? ["Read"] : tools) else { return nil }
        launch.persist = false
        let usesBash = tools.contains { $0.hasPrefix("Bash(") }
        launch.disallowedTools = (usesBash ? [] : ["Bash"]) + ["Write", "Edit", "NotebookEdit", "AskUserQuestion", "Agent", "Task", "WebFetch", "WebSearch"]
        let chat = ClaudeChat()
        do { try chat.start(launch, mode: "once") } catch { return nil }
        return await withCheckedContinuation { @MainActor cont in
            var finished = false
            @MainActor func finish(_ value: String?) {
                guard !finished else { return }
                finished = true
                chat.onEvent = nil
                chat.stop()
                cont.resume(returning: value)
            }
            chat.onEvent = { event in
                MainActor.assumeIsolated {
                    switch event {
                    case .turnResult(let text, let isError, _):
                        let said = chat.items.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n")
                        finish(isError ? nil : (text.isEmpty ? said : text))
                    case .exited:
                        finish(nil)
                    default:
                        break
                    }
                }
            }
            chat.send(prompt, tag: "once")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish(nil)
            }
        }
    }

    // MARK: `kb sync` from a session

    /// Refreshes what a session asked for, then writes how it went to `<crew>/sync/<id>.json`, where the command
    /// waits. The tracker and pull requests are the engine's; calendar and email are the host's (`syncSource`).
    public func runSync(_ req: CrewOrder.SyncRequest) {
        Task {
            var results: [JSONValue] = []
            for what in req.what {
                let (ok, line) = await syncOne(what, range: req.range)
                results.append(["what": .string(what), "ok": .bool(ok), "line": .string(line)])
            }
            let dir = sessions.crewDirectory.appendingPathComponent("sync")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            if let data = try? encoder.encode(JSONValue.object(["results": .array(results)])) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: dir.appendingPathComponent("\(req.id).json"), options: .atomic)
            }
            let failed = results.filter { $0["ok"]?.bool != true }.compactMap { $0["what"]?.string }
            report(failed.isEmpty ? "A session synced \(req.what.joined(separator: ", "))."
                   : "A session's sync of \(failed.joined(separator: ", ")) failed.")
        }
    }

    private func syncOne(_ what: String, range: (from: String, to: String)?) async -> (Bool, String) {
        switch what {
        case "tracker":
            tracker.refreshBacklog(force: true)
            tracker.refreshMyWork(force: true)
            _ = await waitUntil(seconds: 90) { [tracker] in !tracker.backlogLoading && !tracker.myWorkLoading }
            if let e = tracker.backlogError ?? tracker.myWorkError { return (false, e) }
            return (true, "\(tracker.backlog?.items.count ?? 0) work items")
        case "prs":
            tracker.refreshPullRequests(force: true)
            _ = await waitUntil(seconds: 90) { [tracker] in !tracker.pullRequestsLoading }
            if let e = tracker.pullRequestsError { return (false, e) }
            return (true, "\(tracker.pullRequests?.prs.count ?? 0) open pull requests")
        default:
            if let source = syncSource, let result = await source(what, range) { return result }
            return await routines.sync(what, range: range)
        }
    }

    public func waitUntil(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return condition()
    }

    // MARK: JSON

    /// A Build or Plan session as `sessions.list` lists it (remote-api.md).
    public func sessionJSON(_ s: WorkSession) -> JSONValue {
        let archived = sessions.sessionArchived(s)
        var o: [String: JSONValue] = [
            "id": .string(s.id), "title": .string(s.title), "space": .string(s.space.rawValue),
            "role": .string(s.isAssistant ? "assistant" : s.role.rawValue),
            "scope": s.project.map(JSONValue.string) ?? .null, "state": .string(s.crewState.rawValue),
            "busy": .bool(s.chat.isBusy), "updated": .number(s.updated.timeIntervalSince1970),
            "count": .number(Double(s.chat.items.count)), "archived": .bool(archived),
            "needsYou": .bool(!archived && s.crewState.needsUser),
        ]
        if s.space == .plan {
            o["kind"] = .string(s.planKind.rawValue)
            o["kindTitle"] = .string(s.planKind.title)
        }
        if let origin = PlanSessions.origin(about: s.about) { o["origin"] = .string(origin) }
        if s.role == .member, let lead = s.parentID { o["lead"] = .string(lead) }
        return .object(o)
    }

    /// `sessions.list`: Plan sessions with the host's linked conversations, and Build sessions, newest first.
    public func sessionItems(scope: String?, archived withArchived: Bool) -> [JSONValue] {
        sessions.loadIfNeeded()
        let index = index
        let shows: (String?, String?) -> Bool = { project, about in
            scope.map { PlanSessions.shows(project: project, about: about, in: $0, index: index) } ?? true
        }
        let plan = sessions.planSessions.filter { shows($0.project, $0.about) }
            .map { ($0.updated, $0.archived == true, sessionJSON($0)) }
        let linked = sessions.linkedItems(scope).map { ($0.updated, $0.archived, $0.json) }
        let build = sessions.buildSessions.filter { shows($0.project, $0.about) }
            .map { ($0.updated, sessions.sessionArchived($0), sessionJSON($0)) }
        return (plan + linked + build).filter { withArchived || !$0.1 }.sorted { $0.0 > $1.0 }.map(\.2)
    }

    /// What waits for the user now: sessions that need them, as `sessions.list` items.
    public func waitingSessionItems() -> [JSONValue] {
        sessions.list.filter { !sessions.sessionArchived($0) && $0.crewState.needsUser }
            .sorted { $0.updated > $1.updated }.map(sessionJSON)
    }

    /// What `app.structure` shows of Build and the sessions.
    public func buildStructureExtras(scope: String?) -> StructureExtras {
        sessions.loadIfNeeded()
        factories.loadIfNeeded()
        var x = StructureExtras()
        if let scope {
            scans.loadIfNeeded()
            x.projectPending = index.group(of: scope).map { scans.pendingFindings(group: $0.id) } ?? 0
            let items = sessionItems(scope: scope, archived: false).filter { $0["space"]?.string == "plan" }
            x.planSessions = items.count
            x.planSessionsNeedYou = items.filter { $0["needsYou"]?.bool == true }.count
        }
        x.pullRequestsWaiting = tracker.pullRequests?.needingAnswers ?? 0
        x.overseerNeedsYou = sessions.overseer?.crewState.needsUser ?? false
        x.factoriesRunning = factories.list.filter(\.isRunning).count
        x.factoryQuestions = factories.questionCount
        for section in ScopeSections.split(sessions.topLevelBuildSessions, order: index.projects.map(\.id), scope: { $0.project }) {
            let all = section.items + section.items.flatMap { sessions.members(of: $0) }
            x.buildScopes.append((section.scope, section.items.count, all.filter { $0.crewState.needsUser }.count))
        }
        x.archivedBuild = sessions.archivedBuildSessions.count
        return x
    }

    // MARK: Remote methods

    func registerBuildMethods() {
        let m = methods
        m.register("tracker.items") { [unowned self] _, p in
            guard let scope = p["scope"]?.string ?? scope else { throw RemoteError.badParams("scope") }
            await tracker.freshBacklog()
            var items = tracker.items(scope: scope)
            if p["mine"]?.bool == true { items = items.filter(\.mine) }
            return ["me": .string(tracker.backlog?.me ?? ""), "items": .from(items)]
        }

        m.register("sessions.list") { [unowned self] _, p in
            ["sessions": .array(sessionItems(scope: p["scope"]?.string, archived: p["archived"]?.bool == true))]
        }

        m.register("session.get") { [unowned self] _, p in
            sessions.loadIfNeeded()
            guard let s = sessions.session(p["id"]?.string) else { throw RemoteError.notFound("No such session") }
            let since = max(0, p["since"]?.int ?? 0)
            let items = s.chat.items.dropFirst(since).map(Self.itemJSON)
            return ["session": sessionJSON(s), "items": .array(items), "count": .number(Double(s.chat.items.count)),
                    "denials": .array(s.chat.denials.map(JSONValue.string))]
        }

        m.register("session.send") { [unowned self] _, p in
            sessions.loadIfNeeded()
            guard let s = sessions.session(p["id"]?.string), let text = p["text"]?.string, !text.isEmpty else { throw RemoteError.badParams("id and text") }
            if p["spoken"]?.bool == true {
                sessions.send(SpokenReply.message(text), in: s, display: text)
            } else {
                sessions.send(text, in: s)
            }
            return ["sent": true]
        }

        m.register("session.new") { [unowned self] _, p in
            let space: SessionSpace = p["space"]?.string == "build" ? .build : .plan
            let assistant = p["assistant"]?.bool == true && space == .plan
            if assistant { await sessions.prepareActionEndpoint() }
            let message = p["message"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            let spoken = p["spoken"]?.bool == true && message != nil
            let s = sessions.newSession(title: p["title"]?.string, project: p["scope"]?.string ?? scope,
                                        message: spoken ? message.map(SpokenReply.message) : message, display: spoken ? message : nil,
                                        about: assistant ? SessionRecord.assistantAbout : nil, show: false, space: space)
            return ["id": .string(s.id)]
        }

        m.register("session.stop") { [unowned self] _, p in
            sessions.loadIfNeeded()
            guard let s = sessions.session(p["id"]?.string) else { throw RemoteError.notFound("No such session") }
            if s.chat.isBusy { sessions.stop(s) }
            return ["stopped": true]
        }

        m.register("session.archive") { [unowned self] _, p in
            guard let id = p["id"]?.string, let on = p["archived"]?.bool else { throw RemoteError.badParams("id and archived") }
            sessions.loadIfNeeded()
            if let s = sessions.session(id) {
                sessions.setArchived(s, on)
            } else if !sessions.archiveLinked(id, on) {
                throw RemoteError.notFound("No such session")
            }
            return ["archived": .bool(on)]
        }

        m.register("assistant.open") { [unowned self] _, p in
            let (s, created) = await sessions.assistant(scope: p["scope"]?.string, new: p["new"]?.bool ?? false)
            return ["session": sessionJSON(s), "created": .bool(created)]
        }

        m.register("factory.config.get") { [unowned self] _, p in
            factories.loadIfNeeded()
            if sessions.strategies.isEmpty { sessions.reloadStrategies() }
            let f = try p["id"]?.string.map { id -> Factory in
                guard let f = factories.factory(id) else { throw RemoteError.notFound("No such factory") }
                return f
            }
            let rules = f?.rules ?? factories.newRules()
            let count = factories.list.count
            let name = f?.name ?? (count == 0 ? "Software Factory" : "Software Factory \(count + 1)")
            let options = FactoryConfig.options(scopes: factories.scopes.map { .init(id: $0.id, title: $0.title) },
                                                strategies: sessions.strategies.map { ($0.slug, $0.title) })
            let factoryJSON: JSONValue = f.map { f in
                let status = f.run == nil ? "never" : f.run!.isPaused ? "paused" : f.run!.status.rawValue
                return ["id": .string(f.id), "name": .string(f.name), "status": .string(status), "running": .bool(f.isRunning)]
            } ?? .null
            return ["factory": factoryJSON, "name": .string(name), "rules": FactoryConfig.json(rules),
                    "problems": .array(rules.problems.map(JSONValue.string)), "options": options]
        }

        m.register("factory.config.save") { [unowned self] _, p in
            factories.loadIfNeeded()
            let existing = try p["id"]?.string.flatMap { $0.isEmpty ? nil : $0 }.map { id -> Factory in
                guard let f = factories.factory(id) else { throw RemoteError.notFound("No such factory") }
                return f
            }
            let rules: FactoryRules
            do {
                rules = try FactoryConfig.merge(existing?.rules ?? factories.newRules(), with: p["rules"] ?? [:])
            } catch {
                throw RemoteError.badParams(error.localizedDescription)
            }
            let problems = rules.problems
            guard problems.isEmpty else { throw RemoteError.badParams(problems.joined(separator: " ")) }
            let id = factories.save(id: existing?.id, name: p["name"]?.string ?? existing?.name ?? "", rules: rules)
            return ["id": .string(id)]
        }

        m.register("factory.config.delete") { [unowned self] _, p in
            factories.loadIfNeeded()
            guard let id = p["id"]?.string, let f = factories.factory(id) else { throw RemoteError.notFound("No such factory") }
            if f.run?.status == .running { factories.stop(f.id) }
            factories.delete(f.id)
            return ["deleted": true]
        }
    }

    // MARK: Actions

    func registerBuildActions() {
        let a = actions

        a.register("sessions.list") { [unowned self] _ in
            sessions.loadIfNeeded()
            let list = sessions.list.filter { !sessions.sessionArchived($0) }.sorted { $0.updated > $1.updated }
            let waiting = list.filter { $0.crewState.needsUser }
            let speech = waiting.isEmpty ? "\(ActionText.count(list.count, "session")), none waiting for you."
                : "\(ActionText.count(waiting.count, "session")) waiting for you: " + ActionText.list(waiting.prefix(3).map(\.title)) + "."
            return ActionResult(speech, data: ["sessions": .array(list.prefix(40).map(sessionJSON))])
        }
        a.register("session.read") { [unowned self] p in
            sessions.loadIfNeeded()
            guard let s = sessions.session(p["id"]?.string) else { throw ActionError("No such session.") }
            let items = s.chat.items.filter { $0.role == .user || $0.role == .assistant }.suffix(p["last"]?.int ?? 4)
            let last = items.last { $0.role == .assistant }?.text ?? ""
            return ActionResult(last.isEmpty ? "Nothing from \(Brain.name) yet." : String(last.prefix(600)),
                                data: ["items": .array(items.map(Self.itemJSON))])
        }
        a.register("session.start") { [unowned self] p in
            let space: SessionSpace = p["space"]?.string == "build" ? .build : .plan
            let s = sessions.newSession(title: p["title"]?.string, project: p["scope"]?.string ?? scope, message: p["message"]?.string,
                                        show: false, space: space)
            return ActionResult("Started a \(space == .build ? "Build" : "Plan") session.", data: ["id": .string(s.id)])
        }
        a.register("session.send") { [unowned self] p in
            sessions.loadIfNeeded()
            guard let s = sessions.session(p["id"]?.string), let text = p["text"]?.string else { throw ActionError("No such session.") }
            sessions.send(text, in: s)
            return ActionResult("Sent.")
        }
        a.register("session.lead") { [unowned self] p in
            let scope = try scopeParam(p)
            var r = NewLeadRequest(title: p["title"]?.string ?? "", project: scope, brief: p["brief"]?.string ?? "")
            r.strategy = try p["strategy"]?.string.map { try sessions.strategy($0).slug }
            if let n = ActionText.intParam(p["helpers"]) { r.helpers = .fixed; r.helperCount = max(1, min(8, n)) } else { r.helpers = .auto }
            let s = sessions.startLead(r)
            return ActionResult("Started a lead session in Build.", data: ["id": .string(s.id)])
        }
        a.register("session.stop") { [unowned self] p in
            let s = try sessionParam(p)
            sessions.stop(s)
            return ActionResult("Stopped \(s.title).")
        }
        a.register("session.retry") { [unowned self] p in
            sessions.retryLast(in: try sessionParam(p))
            return ActionResult("Sent it again.")
        }
        a.register("session.allow") { [unowned self] p in
            sessions.allowDenied(in: try sessionParam(p))
            return ActionResult("Allowed it for that session.")
        }
        a.register("session.strategy") { [unowned self] p in
            let s = try sessionParam(p)
            let slug = p["strategy"]?.string ?? ""
            if slug.isEmpty {
                sessions.clearStrategy(s)
                return ActionResult("It follows no strategy now.")
            }
            let st = try sessions.strategy(slug)
            sessions.applyStrategy(st, to: s)
            return ActionResult("It follows \(st.title) now.")
        }
        a.register("session.to_build") { [unowned self] p in
            let s = try sessionParam(p)
            guard s.space == .plan else { throw ActionError("It's already in Build.") }
            sessions.moveToBuild(s)
            sessions.show(s)
            return ActionResult("Moved it to Build.")
        }
        a.register("session.archive") { [unowned self] p in
            let on = p["archived"]?.bool ?? true
            sessions.loadIfNeeded()
            if let s = sessions.session(p["id"]?.string) {
                sessions.setArchived(s, on)
            } else if !sessions.archiveLinked(p["id"]?.string ?? "", on) {
                throw ActionError("No such session.")
            }
            return ActionResult(on ? "Archived it." : "Took it out of the archive.")
        }
        a.register("session.delete") { [unowned self] p in
            let s = try sessionParam(p)
            sessions.delete(s)
            return ActionResult("Deleted \(s.title).")
        }

        // MARK: Strategies

        a.register("strategies.list") { [unowned self] _ in
            if sessions.strategies.isEmpty { sessions.reloadStrategies() }
            let list = sessions.strategies
            return ActionResult("\(ActionText.count(list.count, "strategy", plural: "strategies")): " + ActionText.list(list.prefix(5).map(\.title)) + ".",
                                data: ["strategies": .array(list.map(RemotePayloads.strategy))])
        }
        a.register("strategy.get") { [unowned self] p in
            let st = try sessions.strategy(p["slug"]?.string ?? "")
            var data = RemotePayloads.strategy(st)
            if case .object(var o) = data { o["instructions"] = .string(st.instructions); data = .object(o) }
            return ActionResult("\(st.title). \(st.summary)", data: data)
        }
        a.register("strategy.save") { [unowned self] p in
            if sessions.strategies.isEmpty { sessions.reloadStrategies() }
            let title = (p["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ActionError("A strategy needs a title.") }
            var st: Strategy
            if let slug = p["slug"]?.string, !slug.isEmpty {
                st = try sessions.strategy(slug)
            } else {
                var slug = Strategy.slugify(title)
                var n = 2
                while sessions.strategies.contains(where: { $0.slug == slug }) { slug = Strategy.slugify(title) + "-\(n)"; n += 1 }
                st = Strategy(slug: slug, title: title)
            }
            st.title = title
            if let s = p["summary"]?.string { st.summary = s }
            if let s = p["instructions"]?.string { st.instructions = s }
            if let s = p["model"]?.string { st.model = s }
            st.origin = .custom
            st.spawns = !st.roles.isEmpty
            do { try sessions.saveStrategy(st) } catch {
                throw ActionError("Could not save the strategy: \(error.localizedDescription)")
            }
            return ActionResult("Saved the strategy \(st.title).", data: ["slug": .string(st.slug)])
        }
        a.register("strategy.delete") { [unowned self] p in
            let st = try sessions.strategy(p["slug"]?.string ?? "")
            guard st.origin != .builtIn else { throw ActionError("\(st.title) is built in; it can't be deleted.") }
            do { try sessions.deleteStrategy(st) } catch {
                throw ActionError("Could not delete the strategy: \(error.localizedDescription)")
            }
            return ActionResult(st.origin == .override ? "\(st.title) is back to the original." : "Deleted \(st.title).")
        }
        a.register("strategy.draft") { [unowned self] _ in
            sessions.draftStrategy(space: currentMode() == "build" ? .build : .plan)
            return ActionResult("Started a session to draft a strategy with you.")
        }

        // MARK: Factories

        a.register("factories.status") { [unowned self] _ in
            factories.loadIfNeeded()
            let list = factories.list
            guard !list.isEmpty else { return ActionResult("There are no factories yet.") }
            let lines = list.map { f -> String in
                guard let run = f.run else { return "\(f.name) hasn't run" }
                let state = run.isPaused ? "is paused" : run.status == .running ? "is running" : run.status == .windingDown ? "is finishing up" : "is stopped"
                let working = run.activeTasks.count
                return "\(f.name) \(state)" + (working > 0 ? ", working on \(ActionText.count(working, "item"))" : "")
                    + (run.openQuestions.isEmpty ? "" : ", with \(ActionText.count(run.openQuestions.count, "question"))")
            }
            return ActionResult(ActionText.list(lines) + ".", data: ["factories": .array(list.map(RemotePayloads.factory))])
        }
        a.register("factory.start") { [unowned self] p in
            let f = try factories.param(p)
            guard f.rules.problems.isEmpty else { throw ActionError(f.rules.problems.joined(separator: " ")) }
            factories.start(f.id)
            return ActionResult("Started \(f.name).")
        }
        a.register("factory.pause") { [unowned self] p in
            let f = try factories.param(p)
            guard f.run?.status == .running else { throw ActionError("\(f.name) isn't running.") }
            factories.pause(f.id)
            return ActionResult("Paused \(f.name). Sessions working carry on.")
        }
        a.register("factory.resume") { [unowned self] p in
            let f = try factories.param(p)
            guard f.run?.isPaused == true else { throw ActionError("\(f.name) isn't paused.") }
            factories.resume(f.id)
            return ActionResult("Resumed \(f.name).")
        }
        a.register("factory.stop") { [unowned self] p in
            let f = try factories.param(p)
            guard f.run?.status == .running else { throw ActionError("\(f.name) isn't running.") }
            factories.stop(f.id)
            return ActionResult("Stopping \(f.name). Its sessions finish the step they're on.")
        }
        a.register("factory.settings") { [unowned self] p in
            let f = try factories.param(p)
            var rules = f.rules
            var said: [String] = []
            if let n = ActionText.intParam(p["max_parallel"]) {
                rules.maxParallel = max(1, min(10, n)); said.append("\(rules.maxParallel) at a time")
            }
            if let q = p["questions"]?.string.flatMap(FactoryRules.Questions.init(rawValue:)) {
                rules.questions = q; said.append(q.title.lowercased())
            }
            if case .number(let h)? = p["hours"] {
                if h <= 0 { rules.duration = .untilStopped; said.append("runs until stopped") }
                else { rules.duration = .hours; rules.hours = h; said.append("runs for \(h.formatted()) hours") }
            }
            _ = factories.save(id: f.id, name: f.name, rules: rules)
            return ActionResult(said.isEmpty ? "Nothing to change." : "\(f.name) now " + ActionText.list(said) + ".")
        }
        a.register("factory.answer") { [unowned self] p in
            guard let raw = p["question"]?.string, let answer = p["answer"]?.string else { throw ActionError("Which question?") }
            factories.loadIfNeeded()
            let (f, q) = try factories.question(raw)
            factories.answer(f.id, q.id, answer: answer)
            return ActionResult("Answered.")
        }
        a.register("factory.get") { [unowned self] p in
            let f = try factories.param(p)
            var data = RemotePayloads.factory(f)
            if case .object(var o) = data {
                o["rules"] = FactoryConfig.json(f.rules)
                o["problems"] = .array(f.rules.problems.map(JSONValue.string))
                data = .object(o)
            }
            let scopes = f.rules.scopes.map { index.project($0)?.title ?? $0 }
            return ActionResult("\(f.name) takes work from \(scopes.isEmpty ? "no scope yet" : ActionText.list(scopes)), \(f.rules.maxParallel) at a time.",
                                data: data)
        }
        a.register("factory.create") { [unowned self] p in
            factories.loadIfNeeded()
            let rules = try FactoryConfig.merge(factories.newRules(), with: FactoryConfig.patch(fromAction: p))
            let id = factories.save(id: nil, name: p["name"]?.string ?? "", rules: rules)
            let problems = rules.problems
            return ActionResult("Made the factory." + (problems.isEmpty ? " Start it when you're ready." : " Before it can start: " + problems.joined(separator: " ")),
                                data: ["id": .string(id), "problems": .array(problems.map(JSONValue.string))])
        }
        a.register("factory.update") { [unowned self] p in
            let f = try factories.param(p)
            let rules = try FactoryConfig.merge(f.rules, with: FactoryConfig.patch(fromAction: p))
            let name = p["name"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? f.name
            guard rules != f.rules || name != f.name else { return ActionResult("Nothing to change.") }
            factories.save(id: f.id, name: name, rules: rules)
            return ActionResult("Changed \(name)." + (f.isRunning && rules != f.rules ? " The sessions at work were told." : ""))
        }
        a.register("factory.duplicate") { [unowned self] p in
            let f = try factories.param(p)
            let name = p["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "\(f.name) copy"
            let id = factories.save(id: nil, name: name, rules: f.rules)
            return ActionResult("Made \(name).", data: ["id": .string(id)])
        }
        a.register("factory.delete") { [unowned self] p in
            let f = try factories.param(p)
            if f.run?.status == .running { factories.stop(f.id) }
            factories.delete(f.id)
            return ActionResult("Deleted \(f.name).")
        }
        a.register("factory.question.skip") { [unowned self] p in
            factories.loadIfNeeded()
            let (f, q) = try factories.question(p["question"]?.string ?? "")
            factories.skipQuestion(f.id, q.id)
            return ActionResult("It decides that one itself.")
        }
        a.register("factory.item.skip") { [unowned self] p in
            let f = try factories.param(p)
            guard let item = ActionText.intParam(p["work_item"]) else { throw ActionError("Which work item?") }
            factories.skipItem(f.id, item)
            return ActionResult("\(f.name) skips \(item) this run.")
        }

        registerTrackerActions()
        scans.register(on: a)
    }

    public func sessionParam(_ p: JSONValue) throws -> WorkSession {
        sessions.loadIfNeeded()
        guard let s = sessions.session(p["id"]?.string) else { throw ActionError("No such session.") }
        return s
    }
}

extension MindmillEngine {
    /// A transcript item for the phones: `at` (ISO 8601) only when the time is known.
    static func itemJSON(_ item: ClaudeChat.Item) -> JSONValue {
        var o: [String: JSONValue] = ["role": .string(item.role.rawValue), "text": .string(item.text)]
        if let at = item.at { o["at"] = .string(ISO8601DateFormatter().string(from: at)) }
        return .object(o)
    }
}
