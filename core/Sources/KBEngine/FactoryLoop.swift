import Foundation
import KBCore
import Observation

/// The software factories: their rules, the runs, and the loop that picks work items from the tracker and starts
/// Build sessions on them, follows them, passes their questions to the user and tells them what changed.
/// `FactoryDecisions` holds the loop's decisions; this carries them out on the engine's sessions and tracker.
@MainActor
@Observable
public final class FactoryLoop {
    public static let parallelKey = "factoryMaxParallel"

    public var list: [Factory] = []
    /// Side conversations on factory questions, by question id: copies of the asking session, never saved.
    public var asides: [UUID: ClaudeChat] = [:]

    /// A factory session reached a checkpoint where testing makes sense (`kb factory ask --checkpoint`, "done:").
    @ObservationIgnored public var onCheckpoint: ((_ sessionID: String, _ checkpoint: String?) -> Void)?
    /// A factory was deleted (the host moves away from it).
    @ObservationIgnored public var onDeleted: ((String) -> Void)?

    @ObservationIgnored unowned let engine: MindmillEngine
    @ObservationIgnored public private(set) var loaded = false
    @ObservationIgnored public var lastTick = Date.distantPast
    @ObservationIgnored public var assigning: Set<Int> = []
    @ObservationIgnored var coverageChecking: Set<UUID> = []
    /// Where the factories are saved; tests point it elsewhere.
    @ObservationIgnored public var storeURL = AppPaths.instanceFile("factories.json")

    init(engine: MindmillEngine) {
        self.engine = engine
    }

    var sessions: SessionHub { engine.sessions }
    var tracker: TrackerCache { engine.tracker }

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: storeURL) { list = Factory.decodeList(data) }
    }

    /// Saves the factories, and mirrors them into the crew folder for `kb factory status`.
    public func save() {
        guard let data = Factory.encodeList(list) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
        if let json = try? JSONSerialization.jsonObject(with: data),
           let mirror = try? JSONSerialization.data(withJSONObject: ["factories": json], options: [.prettyPrinted]) {
            let crew = sessions.crewDirectory
            try? FileManager.default.createDirectory(at: crew, withIntermediateDirectories: true)
            try? mirror.write(to: crew.appendingPathComponent("factory.json"), options: .atomic)
        }
    }

    public func factory(_ id: String?) -> Factory? { list.first { $0.id == id } }

    func change(_ id: String, _ edit: (inout Factory) -> Void) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        let before = list[i].run?.status
        let paused = list[i].run?.isPaused
        edit(&list[i])
        save()
        let f = list[i]
        let remote = engine.remote
        let listening = remote.isRunning || !remote.desktops.isEmpty
        if listening, f.run?.status != before || f.run?.isPaused != paused || f.run?.events.last?.at ?? .distantPast > Date().addingTimeInterval(-1) {
            remote.broadcast("factory.changed", ["id": .string(f.id), "status": .string(f.run.map { $0.isPaused ? "paused" : $0.status.rawValue } ?? "never")])
        }
        if remote.isRunning { remote.factoryQuestionsChanged(id: f.id, count: f.run?.openQuestions.count ?? 0) }
    }

    /// Questions waiting on the user, across the factories.
    public var questionCount: Int { list.reduce(0) { $0 + ($1.run?.openQuestions.count ?? 0) } }

    public func allOpenQuestions() -> [FactoryQuestion] { list.flatMap { $0.run?.openQuestions ?? [] } }

    // MARK: Setting up

    @discardableResult
    public func save(id: String?, name: String, rules: FactoryRules) -> String {
        loadIfNeeded()
        let clean = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Software Factory" : name.trimmingCharacters(in: .whitespaces)
        if let id, list.contains(where: { $0.id == id }) {
            change(id) { f in
                let before = f.rules
                f.name = clean
                f.rules = rules
                if f.isRunning, before != rules, var run = f.run {
                    for t in run.activeTasks {
                        if let s = sessions.session(t.sessionID) {
                            sessions.deliver(FactoryBrief.rulesChanged(rules, scope: t.scope, item: t.workItem), to: s, from: "the factory")
                        }
                    }
                    run.log("Rules changed; the sessions at work were told.", kind: .run)
                    if before.endDate(from: run.since) != rules.endDate(from: run.since) {
                        run.endsAt = rules.endDate(from: run.since)
                    }
                    f.run = run
                }
            }
            return id
        }
        let f = Factory(name: clean, rules: rules)
        list.append(f)
        save()
        return f.id
    }

    public func rename(_ id: String, _ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, factory(id)?.name != t else { return }
        change(id) { $0.name = t }
    }

    public func editDashboard(_ id: String, _ edit: (inout FactoryDashboard) -> Void) {
        change(id) { edit(&$0.dashboard) }
    }

    public func delete(_ id: String) {
        list.removeAll { $0.id == id }
        save()
        onDeleted?(id)
    }

    /// The scopes a factory can work in: those with a tracker.
    public var scopes: [KBProject] {
        engine.index.projects.filter { p in !p.wide && ProjectSettings.load(project: p.id, root: engine.rootURL).tracker != nil }
    }

    public var overviewScopeID: String? { engine.index.projects.first { $0.wide }?.id }

    /// A new factory's rules as the editor starts them: the current scope when it has a tracker, the last
    /// parallel count used.
    public func newRules() -> FactoryRules {
        var rules = FactoryRules()
        if let p = engine.scope, scopes.contains(where: { $0.id == p }) { rules.scopes = [p] }
        let last = engine.platform.defaults.integer(forKey: Self.parallelKey)
        if last > 0 { rules.maxParallel = last }
        return rules
    }

    /// The factory a call names (by id or name), or the only one.
    public func param(_ p: JSONValue) throws -> Factory {
        loadIfNeeded()
        let key = (p["factory"]?.string ?? "").lowercased()
        if let f = list.first(where: { $0.id.lowercased() == key || $0.name.lowercased() == key }) { return f }
        if let f = list.first(where: { $0.name.lowercased().contains(key) }), !key.isEmpty { return f }
        if list.count == 1, let f = list.first { return f }
        throw ActionError(list.isEmpty ? "There are no factories yet." : "Which factory: " + ActionText.list(list.map(\.name), or: true) + "?")
    }

    /// An open question by the start of its id.
    public func question(_ raw: String) throws -> (Factory, FactoryQuestion) {
        let raw = raw.lowercased()
        guard !raw.isEmpty, let found = list.lazy.compactMap({ f in
            f.run?.openQuestions.first { $0.id.uuidString.lowercased().hasPrefix(raw) }.map { (f, $0) }
        }).first else { throw ActionError("That question is already answered or gone.") }
        return found
    }

    // MARK: Running

    public func start(_ id: String) {
        guard let f = factory(id), f.rules.problems.isEmpty else { return }
        sessions.startTicking()
        tracker.refreshAll()
        change(id) { f in
            // Starting again carries on the same run: its board, questions and history stay.
            var run = f.run ?? FactoryRun(endsAt: nil)
            if f.run != nil { run.resume(endsAt: f.rules.endDate(from: Date())) } else { run.endsAt = f.rules.endDate(from: Date()) }
            run.facts = factFingerprints(f.rules)
            run.log(Self.startLine(f.rules, again: f.run != nil), kind: .run)
            f.run = run
        }
        adoptLostTasks(id)
        lastTick = .distantPast
    }

    private static func startLine(_ rules: FactoryRules, again: Bool) -> String {
        var s = again ? "Started again" : "Started"
        if let end = rules.endDate(from: Date()) {
            s += ", runs until \(end.formatted(date: .omitted, time: .shortened))"
        } else {
            s += ", runs until you stop it"
        }
        return s + ". Up to \(rules.maxParallel) task\(rules.maxParallel == 1 ? "" : "s") at a time."
    }

    /// Starts nothing new; the sessions working finish the step they're on and push.
    public func stop(_ id: String, reason: String = "You stopped it.") {
        guard let f = factory(id), let run = f.run, run.status == .running else { return }
        for t in run.activeTasks {
            if let s = sessions.session(t.sessionID), occupiesSlot(t, in: f) { sessions.deliver(FactoryBrief.windDown, to: s, from: "the factory") }
        }
        change(id) { f in
            f.run?.status = .windingDown
            f.run?.log("Stopping: \(reason) Sessions working finish the step they're on.", kind: .run)
        }
    }

    /// Puts sessions this factory started back on its board when its run no longer lists them.
    private func adoptLostTasks(_ id: String) {
        guard let f = factory(id), f.run != nil, list.filter({ $0.name == f.name }).count == 1 else { return }
        let info = sessions.list.filter { $0.space == .build }.map { s in
            FactorySessionInfo(id: s.id, title: s.title, project: s.project, about: s.about,
                               firstMessage: s.chat.items.first { $0.role == .user }?.text ?? "",
                               created: s.created, archived: sessions.isArchived(s))
        }
        let lost = f.lostTasks(info)
        guard !lost.isEmpty else { return }
        change(id) { f in
            for t in lost {
                f.run?.tasks.append(t)
                f.run?.log("Picked #\(t.workItem) up again: this factory started its session earlier.", workItem: t.workItem)
            }
        }
    }

    /// Takes no new work items until resumed; the sessions working carry on.
    public func pause(_ id: String) {
        guard let run = factory(id)?.run, run.status == .running, run.paused != true else { return }
        change(id) { f in
            f.run?.paused = true
            f.run?.log("Paused: it takes no new work items. Sessions working carry on.", kind: .run)
        }
    }

    public func resume(_ id: String) {
        guard factory(id)?.run?.isPaused == true else { return }
        change(id) { f in
            f.run?.paused = nil
            f.run?.log("Resumed.", kind: .run)
        }
        lastTick = .distantPast
    }

    public func skipItem(_ id: String, _ item: Int) {
        change(id) { f in
            f.run?.skipped.append(item)
            f.run?.log("Left #\(item) alone for this run.", workItem: item)
        }
    }

    /// Every 15 seconds while the crew tick runs: end runs whose time is up, follow the tasks, pick new ones, and
    /// tell sessions about facts that changed.
    public func tick() {
        loadIfNeeded()
        guard Date().timeIntervalSince(lastTick) > 15 else { return }
        lastTick = Date()
        for f in list where f.isRunning { tick(f.id) }
    }

    private func tick(_ id: String) {
        adoptLostTasks(id)
        guard var f = factory(id), var run = f.run else { return }
        let before = run
        if FactoryDecisions.timeIsUp(run) {
            stop(id, reason: "Its time is up.")
            guard let again = factory(id), let r = again.run else { return }
            f = again
            run = r
        }
        followTasks(f, &run)
        if FactoryDecisions.windDownComplete(run, anyBusy: run.activeTasks.contains { sessions.session($0.sessionID)?.chat.isBusy ?? false }) {
            run.status = .stopped
            run.stopped = Date()
            run.log("Stopped.", kind: .run)
        }
        noticeFactChanges(f, &run)
        if run != before { change(id) { $0.run = run } }
        if run.takesNewWork { pickNext(id) }
    }

    /// Whether the task still takes one of the factory's places: it does until its pull request is open and the
    /// session has nothing left to do or answer.
    public func occupiesSlot(_ t: FactoryTask, in f: Factory) -> Bool {
        guard t.isActive, let s = sessions.session(t.sessionID) else { return false }
        return FactoryDecisions.occupiesSlot(t, session: view(s),
                                             hasOpenQuestion: f.run?.openQuestions.contains { $0.sessionID == s.id } == true)
    }

    /// What the factory loop needs to know about a session.
    private func view(_ s: WorkSession) -> FactoryDecisions.SessionView {
        FactoryDecisions.SessionView(exists: true, busy: s.chat.isBusy, archived: sessions.isArchived(s), work: sessions.badges(s).work)
    }

    private func followTasks(_ f: Factory, _ run: inout FactoryRun) {
        for i in run.tasks.indices where run.tasks[i].isActive {
            let t = run.tasks[i]
            let v = sessions.session(t.sessionID).map(view) ?? FactoryDecisions.SessionView(exists: false)
            let stage = tracker.backlog?.items.first { $0.id == t.workItem }?.stage
            if let outcome = FactoryDecisions.outcome(session: v, stage: stage) {
                run.tasks[i].finished = Date()
                if run.tasks[i].outcome == nil { run.tasks[i].outcome = outcome }
                run.log("#\(t.workItem) finished: \(outcome.lowercased()).", kind: .done, workItem: t.workItem)
            }
        }
    }

    private func pickNext(_ id: String) {
        guard let f = factory(id), let run = f.run, let backlog = tracker.backlog else {
            if tracker.backlog == nil { tracker.refreshBacklog() }
            return
        }
        if let at = tracker.backlogFetched, Date().timeIntervalSince(at) > 300 { tracker.refreshBacklog(force: true) }
        guard FactoryDecisions.hasFreeSlot(occupied: run.tasks.filter({ occupiesSlot($0, in: f) }).count, rules: f.rules) else { return }
        guard let item = nextItems(f, backlog: backlog).first else { return }
        if item.isUnassigned {
            assigning.insert(item.id)
            let cli = engine.cli
            Task {
                do {
                    _ = try await cli.run(["tracker", "assign", String(item.id), "--to", "me", "--project", item.scope])
                    change(id) { $0.run?.log("Assigned #\(item.id) to you.", workItem: item.id) }
                    startTask(id, item)
                } catch {
                    change(id) { f in
                        f.run?.skipped.append(item.id)
                        f.run?.log("Couldn't assign #\(item.id) to you, so it's left alone: \(error.localizedDescription)", kind: .warning, workItem: item.id)
                    }
                }
                assigning.remove(item.id)
            }
        } else {
            startTask(id, item)
        }
    }

    /// What the factory would take next, best first.
    public func nextItems(_ f: Factory, backlog: TrackerBacklog) -> [TrackerBacklog.Item] {
        let live = Set(backlog.items.filter { item in sessions.sessions(forKey: item.sessionKey).contains { !sessions.isArchived($0) } }.map(\.id))
        let exclude = FactoryDecisions.excluded(run: f.run, assigning: assigning, withLiveSession: live,
                                                otherFactories: list.filter { $0.id != f.id })
        return FactoryPicker.candidates(backlog, rules: f.rules, exclude: exclude, me: engine.myNames())
    }

    private func startTask(_ id: String, _ item: TrackerBacklog.Item) {
        guard let f = factory(id), f.run?.status == .running else { return }
        let slug = f.rules.strategy(for: item)
        let strategy = sessions.strategies.first { $0.slug == slug }
        let fast = f.rules.questions == .never && sessions.repoHasSkill("implement-fast", project: item.scope)
        let skill = fast ? "implement-fast" : sessions.repoHasSkill("implement", project: item.scope) ? "implement" : nil
        var brief = FactoryBrief.task(item, rules: f.rules, factory: f.name, overviewScope: overviewScopeID, skill: skill)
        if let strategy { brief += "\n\n" + ImplementWay.strategyNote(strategy, skill: skill, fast: f.rules.questions == .never) }
        brief += engine.testingNote(item.scope)
        if let note = tracker.markWorkStarted(item.id, scope: item.scope, ref: "work item #\(item.id)") { brief = note + "\n\n" + brief }
        let s = sessions.newSession(title: "#\(item.id) \(item.title)", project: item.scope, message: brief,
                                    display: Factory.sessionLabel(factory: f.name, item: item.id, title: item.title),
                                    model: strategy.flatMap { $0.leadModel.isEmpty ? nil : $0.leadModel },
                                    strategy: strategy, about: item.sessionKey, show: false, space: .build)
        change(id) { f in
            f.run?.tasks.append(FactoryTask(workItem: item.id, title: item.title, scope: item.scope, sessionID: s.id,
                                            strategy: strategy?.title ?? ""))
            f.run?.log("Started #\(item.id) \(item.title)" + (strategy.map { " with \($0.title)" } ?? ""), kind: .started, workItem: item.id)
        }
    }

    // MARK: Facts

    private func factScopes(_ rules: FactoryRules) -> [String] { rules.scopes + (overviewScopeID.map { [$0] } ?? []) }

    public func factFingerprints(_ rules: FactoryRules) -> [String: String] {
        var out: [String: String] = [:]
        for p in factScopes(rules) {
            for section in [KBSection.facts, .decisions] {
                for e in engine.index.entries(project: p, section: section) where !e.isDraft {
                    out[e.id.rawValue] = FactoryRun.fingerprint(e.title + "\n" + e.summary + "\n" + e.body)
                }
            }
        }
        return out
    }

    /// A fact that is new or changed reaches the sessions working in its scope (all of them for the Overview).
    private func noticeFactChanges(_ f: Factory, _ run: inout FactoryRun) {
        let now = factFingerprints(f.rules)
        let changed = run.changedFacts(now)
        run.facts = now
        guard !changed.isEmpty else { return }
        let index = engine.index
        var bySession: [String: [FactoryBrief.FactChange]] = [:]
        for raw in changed {
            guard let id = EntryID(raw), let e = index.entry(id) else { continue }
            let everywhere = id.project == overviewScopeID
            let kind = id.section == .decisions ? "decision" : "fact"
            var told = 0
            for t in run.activeTasks where everywhere || t.scope == id.project {
                guard sessions.session(t.sessionID) != nil else { continue }
                bySession[t.sessionID, default: []].append(.init(kind: kind, title: e.title, id: raw, summary: e.summary))
                told += 1
            }
            run.log("\(kind.capitalized) “\(e.title)” changed" + (told > 0 ? "; told \(told) session\(told == 1 ? "" : "s")." : "."), kind: .fact)
        }
        for t in run.activeTasks {
            guard let changes = bySession.removeValue(forKey: t.sessionID), let s = sessions.session(t.sessionID),
                  let text = FactoryBrief.factsChanged(changes) else { continue }
            sessions.deliver(text, to: s, from: "the factory")
        }
        let known = changed.compactMap { EntryID($0).flatMap { index.entry($0) } }.map(Self.known)
        checkCoverage(known: known, open: run.openQuestions)
    }

    /// Facts and work items the factory's sessions proposed, waiting in the Inbox.
    public func proposals(_ f: Factory) -> [KBEntry] {
        let ids = Set(f.run?.tasks.map { "session:\($0.sessionID)" } ?? [])
        guard !ids.isEmpty else { return [] }
        return factScopes(f.rules).flatMap { p in
            engine.index.entries(project: p, section: .inbox).filter { e in e.proposedBy.map(ids.contains) ?? false }
        }
    }

    // MARK: Questions and progress from the sessions

    /// The factory and task a session (or one under it) works for.
    public func owning(_ sessionID: String) -> (String, FactoryTask)? {
        var ids = [sessionID]
        if let parent = sessions.session(sessionID)?.parentID { ids.append(parent) }
        for f in list {
            for id in ids { if let t = f.run?.task(session: id) { return (f.id, t) } }
        }
        return nil
    }

    /// `kb factory ask` from a session.
    public func asked(from: String, text: String, options: [String], checkpoint: String?) {
        loadIfNeeded()
        guard let (fid, task) = owning(from) else {
            if let s = sessions.session(from), let o = sessions.overseer {
                sessions.deliver("NEEDS: \(text)" + (options.isEmpty ? "" : " Options: " + options.enumerated().map { "(\($0.offset + 1)) \($0.element)" }.joined(separator: " ")),
                                 to: o, from: s.title)
            }
            return
        }
        let q = FactoryQuestion(sessionID: from, workItem: task.workItem, checkpoint: checkpoint, text: text, options: options)
        change(fid) { f in
            f.run?.questions.append(q)
            f.run?.log("#\(task.workItem) asks: \(text)", kind: .question, workItem: task.workItem)
        }
        engine.report("The factory has a question about #\(task.workItem).")
        engine.platform.notifier?.notify(title: "The factory has a question", body: "#\(task.workItem): \(text)", action: "factory:\(fid)")
        if !engine.remote.desktops.isEmpty { engine.remote.broadcastDesktop("desktop.state", engine.desktopState()) }
        reachedCheckpoint(from, checkpoint)
        if let f = factory(fid) {
            checkCoverage(known: recentlySettled(scopes: factScopes(f.rules)), open: [q])
        }
    }

    private func reachedCheckpoint(_ sessionID: String, _ checkpoint: String?) {
        if let onCheckpoint { onCheckpoint(sessionID, checkpoint) } else { engine.tests.checkpoint(sessionID: sessionID, checkpoint: checkpoint) }
    }

    /// `kb factory log` from a session.
    public func logged(from: String, text: String) {
        loadIfNeeded()
        guard let (fid, task) = owning(from) else { return }
        change(fid) { f in
            f.run?.log(text, kind: text.lowercased().hasPrefix("done:") ? .done : .info, workItem: task.workItem)
            if text.lowercased().hasPrefix("done:"), let i = f.run?.tasks.firstIndex(where: { $0.workItem == task.workItem && $0.isActive }) {
                f.run?.tasks[i].outcome = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }
        if text.lowercased().hasPrefix("done:") { reachedCheckpoint(from, "done") }
    }

    public func answer(_ fid: String, _ qid: UUID, answer: String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let q = factory(fid)?.run?.questions.first(where: { $0.id == qid }), q.isOpen else { return }
        endAside(qid)
        if let s = sessions.session(q.sessionID) {
            sessions.deliver(FactoryBrief.answer(q.text, text), to: s, from: "the user via the factory")
        }
        change(fid) { f in
            guard let i = f.run?.questions.firstIndex(where: { $0.id == qid }) else { return }
            f.run?.questions[i].answer = text
            f.run?.questions[i].answered = Date()
            f.run?.log("You answered #\(q.workItem.map(String.init) ?? "–"): \(text)", kind: .answer, workItem: q.workItem)
        }
        checkCoverage(known: [Self.known(q, answer: text)], open: allOpenQuestions().filter { $0.id != qid })
    }

    public func skipQuestion(_ fid: String, _ qid: UUID) {
        endAside(qid)
        guard let q = factory(fid)?.run?.questions.first(where: { $0.id == qid }), q.isOpen else { return }
        if let s = sessions.session(q.sessionID) {
            sessions.deliver("The user left your question “\(q.text)” to you: make the reasonable choice, note the assumption in your report, and carry on.",
                             to: s, from: "the user via the factory")
        }
        change(fid) { f in
            guard let i = f.run?.questions.firstIndex(where: { $0.id == qid }) else { return }
            f.run?.questions[i].answer = "Left to the session"
            f.run?.questions[i].answered = Date()
            f.run?.log("You left the question on #\(q.workItem.map(String.init) ?? "–") to the session.", kind: .answer, workItem: q.workItem)
        }
    }

    public func dismissAnsweredForYou(_ fid: String, _ qid: UUID) {
        change(fid) { f in
            if let i = f.run?.questions.firstIndex(where: { $0.id == qid }) { f.run?.questions[i].dismissed = true }
        }
    }

    /// The user adds to an answer given for them.
    public func addToAnsweredForYou(_ fid: String, _ qid: UUID, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let q = factory(fid)?.run?.questions.first(where: { $0.id == qid }) else { return }
        if let s = sessions.session(q.sessionID) {
            sessions.deliver("The user adds to the answer to your question “\(q.text)”: \(t)", to: s, from: "the user via the factory")
        }
        change(fid) { f in
            guard let i = f.run?.questions.firstIndex(where: { $0.id == qid }) else { return }
            f.run?.questions[i].dismissed = true
            f.run?.log("You added to the answer on #\(q.workItem.map(String.init) ?? "–"): \(t)", kind: .answer, workItem: q.workItem)
        }
    }

    // MARK: Questions already settled elsewhere

    private static func known(_ q: FactoryQuestion, answer: String) -> FactoryCoverage.Known {
        FactoryCoverage.Known(id: "answer:\(q.id.uuidString.prefix(8))",
                              text: "Asked about work item #\(q.workItem.map(String.init) ?? "–"): “\(q.text)”. The user answered: \(answer)")
    }

    private static func known(_ e: KBEntry) -> FactoryCoverage.Known {
        let kind = e.section == .decisions ? "Decision" : "Fact"
        return FactoryCoverage.Known(id: e.id.rawValue, text: "\(kind): \(e.title)" + (e.summary.isEmpty ? "" : " — \(e.summary)"))
    }

    /// What the user answered in the factories over the last days, and the decisions and facts of the last two weeks
    /// in these scopes.
    private func recentlySettled(scopes: [String]) -> [FactoryCoverage.Known] {
        let since = Date().addingTimeInterval(-3 * 86_400)
        var asked: [FactoryQuestion] = []
        for f in list {
            for q in f.run?.questions ?? [] {
                guard let a = q.answer, a != "Left to the session", let at = q.answered, at > since else { continue }
                asked.append(q)
            }
        }
        asked.sort { ($0.answered ?? .distantPast) > ($1.answered ?? .distantPast) }
        let answers: [FactoryCoverage.Known] = asked.prefix(25).map { Self.known($0, answer: $0.answer ?? "") }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let cutoff = day.string(from: Date().addingTimeInterval(-14 * 86_400))
        var recent: [KBEntry] = []
        for p in scopes {
            for section in [KBSection.decisions, .facts] {
                recent += engine.index.entries(project: p, section: section).filter { e in !e.isDraft && e.date >= cutoff && e.supersededBy == nil }
            }
        }
        recent.sort { $0.date > $1.date }
        let entries: [FactoryCoverage.Known] = recent.prefix(25).map { Self.known($0) }
        return answers + entries
    }

    /// Asks Claude which open questions what the user answered or decided already settles; those are answered for
    /// the user, the sessions are told, and the user sees it.
    public func checkCoverage(known: [FactoryCoverage.Known], open: [FactoryQuestion]) {
        let open = open.filter { $0.isOpen && !coverageChecking.contains($0.id) }
        guard !known.isEmpty, !open.isEmpty, engine.claudeExecutable != nil else { return }
        let items = open.map { FactoryCoverage.Open(id: $0.id, text: $0.text, workItem: $0.workItem) }
        coverageChecking.formUnion(open.map(\.id))
        Task {
            let reply = await engine.claudeOnce(FactoryCoverage.prompt(known: known, open: items), system: FactoryCoverage.system)
            coverageChecking.subtract(open.map(\.id))
            guard let reply else { return }
            for v in FactoryCoverage.parse(reply, open: items) { answerForYou(v) }
        }
    }

    private func answerForYou(_ v: FactoryCoverage.Verdict) {
        guard let f = list.first(where: { $0.run?.questions.contains { $0.id.uuidString.lowercased() == v.id.lowercased() && $0.isOpen } ?? false }),
              let q = f.run?.questions.first(where: { $0.id.uuidString.lowercased() == v.id.lowercased() }) else { return }
        endAside(q.id)
        if let s = sessions.session(q.sessionID) {
            sessions.deliver(FactoryCoverage.message(question: q.text, answer: v.answer, because: v.because), to: s, from: "the user via the factory")
        }
        change(f.id) { f in
            guard let i = f.run?.questions.firstIndex(where: { $0.id == q.id }) else { return }
            f.run?.questions[i].answer = v.answer
            f.run?.questions[i].answered = Date()
            f.run?.questions[i].indirect = true
            f.run?.questions[i].coveredBy = v.because
            f.run?.log("Answered for you on #\(q.workItem.map(String.init) ?? "–") (\(v.because)): \(v.answer)", kind: .answer, workItem: q.workItem)
        }
        engine.report("A question on #\(q.workItem.map(String.init) ?? "–") was already answered (\(v.because)). It's under Answered for you.")
    }

    // MARK: Side conversations on questions

    public static let asideTools = ["Read", "Grep", "Glob", "Bash(kb:*)", "Bash(git log:*)", "Bash(git diff:*)", "Bash(git show:*)",
                                    "Bash(git status:*)", "Bash(ls:*)"]

    /// Whether a side conversation can start: the asking session has a conversation to copy.
    public func canStartAside(_ q: FactoryQuestion) -> Bool { sessions.session(q.sessionID)?.claudeSessionID != nil }

    /// Copies the asking session's conversation into a short side session that catches the user up and takes
    /// follow-up questions. It is never saved and never listed with the sessions.
    public func startAside(_ q: FactoryQuestion) {
        guard asides[q.id] == nil, let s = sessions.session(q.sessionID), let sid = s.claudeSessionID else { return }
        guard var launch = engine.launch(prompt: FactoryBrief.asideSystemPrompt, sessionID: sid, resume: true,
                                         model: engine.model(for: .work), cwd: s.workingDirectory, tools: Self.asideTools) else { return }
        launch.fork = true
        launch.persist = false
        launch.disallowedTools = ["Write", "Edit", "NotebookEdit", "AskUserQuestion", "Agent", "Task"]
        let chat = ClaudeChat()
        do { try chat.start(launch, mode: "aside") } catch { return }
        asides[q.id] = chat
        chat.send(FactoryBrief.catchUp(q.text), tag: "catchup", display: "Catch me up")
    }

    public func askAside(_ qid: UUID, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let chat = asides[qid], chat.isRunning else { return }
        chat.send(t, tag: "ask-\(UUID().uuidString.prefix(8))")
    }

    public func endAside(_ qid: UUID) {
        asides.removeValue(forKey: qid)?.stop()
    }
}
