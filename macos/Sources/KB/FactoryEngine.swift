import KBCore
import SwiftUI

struct FactoryEditRequest: Identifiable {
    let id = UUID()
    /// Nil for a new factory.
    var factoryID: String?
}

/// The software factories: their rules, the runs, and the loop that picks work items and starts sessions on them.
extension AppModel {
    static let factoryTag = "factory:"

    private var factoriesURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KB/factories.json")
    }

    func loadFactoriesIfNeeded() {
        guard !factoriesLoaded else { return }
        factoriesLoaded = true
        if let data = try? Data(contentsOf: factoriesURL) { factories = Factory.decodeList(data) }
    }

    /// Saves the factories, and mirrors them into the crew folder for `kb factory status`.
    func saveFactories() {
        guard let data = Factory.encodeList(factories) else { return }
        try? FileManager.default.createDirectory(at: factoriesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: factoriesURL, options: .atomic)
        if let list = try? JSONSerialization.jsonObject(with: data),
           let mirror = try? JSONSerialization.data(withJSONObject: ["factories": list], options: [.prettyPrinted]) {
            try? FileManager.default.createDirectory(at: crewDirectory, withIntermediateDirectories: true)
            try? mirror.write(to: crewDirectory.appendingPathComponent("factory.json"), options: .atomic)
        }
    }

    func factory(_ id: String?) -> Factory? { factories.first { $0.id == id } }

    private func change(_ id: String, _ edit: (inout Factory) -> Void) {
        guard let i = factories.firstIndex(where: { $0.id == id }) else { return }
        let before = factories[i].run?.status
        let paused = factories[i].run?.isPaused
        edit(&factories[i])
        saveFactories()
        let f = factories[i]
        if remote.isRunning, f.run?.status != before || f.run?.isPaused != paused || f.run?.events.last?.at ?? .distantPast > Date().addingTimeInterval(-1) {
            remote.broadcast("factory.changed", ["id": .string(f.id), "status": .string(f.run.map { $0.isPaused ? "paused" : $0.status.rawValue } ?? "never")])
        }
    }

    var selectedFactoryID: String? {
        guard let raw = buildSelection, raw.hasPrefix(Self.factoryTag) else { return nil }
        return String(raw.dropFirst(Self.factoryTag.count))
    }

    func showFactory(_ id: String?) {
        mode = .build
        buildSelection = Self.factoryTag + (id ?? factories.first?.id ?? "")
    }

    /// Questions waiting on the user, across the factories.
    var factoryQuestionCount: Int { factories.reduce(0) { $0 + ($1.run?.openQuestions.count ?? 0) } }

    // MARK: Setting up

    @discardableResult
    func saveFactory(id: String?, name: String, rules: FactoryRules) -> String {
        let clean = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Software Factory" : name.trimmingCharacters(in: .whitespaces)
        if let id, factories.contains(where: { $0.id == id }) {
            change(id) { f in
                let before = f.rules
                f.name = clean
                f.rules = rules
                if f.isRunning, before != rules, var run = f.run {
                    for t in run.activeTasks {
                        if let s = session(t.sessionID) { deliver(FactoryBrief.rulesChanged(rules, scope: t.scope, item: t.workItem), to: s, from: "the factory") }
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
        factories.append(f)
        saveFactories()
        return f.id
    }

    func renameFactory(_ id: String, _ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, factory(id)?.name != t else { return }
        change(id) { $0.name = t }
    }

    func editFactoryDashboard(_ id: String, _ edit: (inout FactoryDashboard) -> Void) {
        change(id) { edit(&$0.dashboard) }
    }

    /// Fetches a work item's description and criteria once, for the context of a question about it.
    func loadWorkItemDetail(_ id: Int, scope: String) {
        guard workItemDetails[id] == nil, !workItemDetailLoading.contains(id) else { return }
        workItemDetailLoading.insert(id)
        let cli = cli
        Task {
            if let out = try? await cli.run(["tracker", "item", String(id), "--json", "--scope", scope]),
               let detail = try? WorkItemDetail.decode(out) {
                workItemDetails[id] = detail
            }
            workItemDetailLoading.remove(id)
        }
    }

    func deleteFactory(_ id: String) {
        factories.removeAll { $0.id == id }
        saveFactories()
        if selectedFactoryID == id { buildSelection = factories.first.map { Self.factoryTag + $0.id } }
    }

    /// The scopes a factory can work in: those with a tracker.
    var factoryScopes: [KBProject] {
        index.projects.filter { p in !p.wide && ProjectSettings.load(project: p.id, root: rootURL).tracker != nil }
    }

    var overviewScopeID: String? { index.projects.first { $0.wide }?.id }

    // MARK: Running

    func startFactory(_ id: String) {
        guard let f = factory(id), f.rules.problems.isEmpty else { return }
        startCrewEngine()
        refreshTracker(force: true)
        refreshPullRequests(force: true)
        refreshMyWork(force: true)
        change(id) { f in
            // Starting again carries on the same run: its board, questions and history stay.
            var run = f.run ?? FactoryRun(endsAt: nil)
            if f.run != nil { run.resume(endsAt: f.rules.endDate(from: Date())) } else { run.endsAt = f.rules.endDate(from: Date()) }
            run.facts = factFingerprints(f.rules)
            run.log(Self.startLine(f.rules, again: f.run != nil), kind: .run)
            f.run = run
        }
        adoptLostTasks(id)
        factoryLastTick = .distantPast
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
    func stopFactory(_ id: String, reason: String = "You stopped it.") {
        guard let f = factory(id), let run = f.run, run.status == .running else { return }
        for t in run.activeTasks {
            if let s = session(t.sessionID), occupiesSlot(t, in: f) { deliver(FactoryBrief.windDown, to: s, from: "the factory") }
        }
        change(id) { f in
            f.run?.status = .windingDown
            f.run?.log("Stopping: \(reason) Sessions working finish the step they're on.", kind: .run)
        }
    }

    /// Puts sessions this factory started back on its board when its run no longer lists them.
    private func adoptLostTasks(_ id: String) {
        guard let f = factory(id), f.run != nil, factories.filter({ $0.name == f.name }).count == 1 else { return }
        let info = sessions.filter { $0.space == .build }.map { s in
            FactorySessionInfo(id: s.id, title: s.title, project: s.project, about: s.about,
                               firstMessage: s.chat.items.first { $0.role == .user }?.text ?? "",
                               created: s.created, archived: isArchived(s))
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
    func pauseFactory(_ id: String) {
        guard let run = factory(id)?.run, run.status == .running, run.paused != true else { return }
        change(id) { f in
            f.run?.paused = true
            f.run?.log("Paused: it takes no new work items. Sessions working carry on.", kind: .run)
        }
    }

    func resumeFactory(_ id: String) {
        guard factory(id)?.run?.isPaused == true else { return }
        change(id) { f in
            f.run?.paused = nil
            f.run?.log("Resumed.", kind: .run)
        }
        factoryLastTick = .distantPast
    }

    func skipFactoryItem(_ id: String, _ item: Int) {
        change(id) { f in
            f.run?.skipped.append(item)
            f.run?.log("Left #\(item) alone for this run.", workItem: item)
        }
    }

    /// Every 15 seconds while Build's engine runs: end runs whose time is up, follow the tasks, pick new ones,
    /// and tell sessions about facts that changed.
    func factoryTick() {
        loadFactoriesIfNeeded()
        guard Date().timeIntervalSince(factoryLastTick) > 15 else { return }
        factoryLastTick = Date()
        for f in factories where f.isRunning { tick(f.id) }
    }

    private func tick(_ id: String) {
        adoptLostTasks(id)
        guard var f = factory(id), var run = f.run else { return }
        let before = run
        if run.status == .running, let end = run.endsAt, Date() >= end {
            stopFactory(id, reason: "Its time is up.")
            guard let again = factory(id), let r = again.run else { return }
            f = again
            run = r
        }
        followTasks(f, &run)
        if run.status == .windingDown, !run.activeTasks.contains(where: { session($0.sessionID)?.chat.isBusy ?? false }) {
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
    func occupiesSlot(_ t: FactoryTask, in f: Factory) -> Bool {
        guard t.isActive, let s = session(t.sessionID) else { return false }
        if s.chat.isBusy || f.run?.openQuestions.contains(where: { $0.sessionID == s.id }) == true { return true }
        // It logged its part done (a pushed branch when PRs are off).
        if t.outcome != nil { return false }
        guard let work = badges(s).work else { return true }
        return ![.inReview, .approved, .readyToComplete, .completing, .building, .buildQueued, .comments, .draft, .inPR].contains(work)
    }

    private func followTasks(_ f: Factory, _ run: inout FactoryRun) {
        for i in run.tasks.indices where run.tasks[i].isActive {
            let t = run.tasks[i]
            var outcome: String?
            if let s = session(t.sessionID) {
                let stage = tracker?.items.first { $0.id == t.workItem }?.stage
                if isArchived(s) { outcome = "Session archived" }
                else if badges(s).work == .done || badges(s).work == .resolved || stage == .resolved || stage == .done { outcome = "Resolved" }
            } else {
                outcome = "Session deleted"
            }
            if let outcome {
                run.tasks[i].finished = Date()
                if run.tasks[i].outcome == nil { run.tasks[i].outcome = outcome }
                run.log("#\(t.workItem) finished: \(outcome.lowercased()).", kind: .done, workItem: t.workItem)
            }
        }
    }

    private func pickNext(_ id: String) {
        guard let f = factory(id), let run = f.run, let backlog = tracker else {
            if tracker == nil { refreshTracker() }
            return
        }
        if let at = trackerFetched, Date().timeIntervalSince(at) > 300 { refreshTracker(force: true) }
        guard run.tasks.filter({ occupiesSlot($0, in: f) }).count < f.rules.maxParallel else { return }
        guard let item = nextItems(f, backlog: backlog).first else { return }
        if item.isUnassigned {
            factoryAssigning.insert(item.id)
            let cli = cli
            Task {
                do {
                    _ = try await cli.run(["tracker", "assign", String(item.id), "--to", "me"])
                    change(id) { $0.run?.log("Assigned #\(item.id) to you.", workItem: item.id) }
                    startFactoryTask(id, item)
                } catch {
                    change(id) { f in
                        f.run?.skipped.append(item.id)
                        f.run?.log("Couldn't assign #\(item.id) to you, so it's left alone: \(error.localizedDescription)", kind: .warning, workItem: item.id)
                    }
                }
                factoryAssigning.remove(item.id)
            }
        } else {
            startFactoryTask(id, item)
        }
    }

    /// What the factory would take next, best first.
    func nextItems(_ f: Factory, backlog: TrackerBacklog) -> [TrackerBacklog.Item] {
        let run = f.run
        var exclude = Set(run?.tasks.map(\.workItem) ?? []).union(run?.skipped ?? []).union(factoryAssigning)
        for item in backlog.items where sessions(forKey: item.sessionKey).contains(where: { !isArchived($0) }) { exclude.insert(item.id) }
        // Another running factory's tasks are its own.
        for other in factories where other.id != f.id { exclude.formUnion(other.run?.activeTasks.map(\.workItem) ?? []) }
        return FactoryPicker.candidates(backlog, rules: f.rules, exclude: exclude)
    }

    private func startFactoryTask(_ id: String, _ item: TrackerBacklog.Item) {
        guard let f = factory(id), f.run?.status == .running else { return }
        let slug = f.rules.strategy(for: item)
        let strategy = strategies.first { $0.slug == slug }
        let fast = f.rules.questions == .never && repoHasSkill("implement-fast", project: item.scope)
        let skill = fast ? "implement-fast" : repoHasSkill("implement", project: item.scope) ? "implement" : nil
        var brief = FactoryBrief.task(item, rules: f.rules, factory: f.name, overviewScope: overviewScopeID, skill: skill)
        if let strategy { brief += "\n\n" + ImplementWay.strategyNote(strategy, skill: skill, fast: f.rules.questions == .never) }
        brief += testingNote(item.scope)
        if let note = markWorkStarted(item.id, scope: item.scope, ref: "work item #\(item.id)") { brief = note + "\n\n" + brief }
        let s = newSession(title: "#\(item.id) \(item.title)", project: item.scope, message: brief,
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

    func factFingerprints(_ rules: FactoryRules) -> [String: String] {
        var out: [String: String] = [:]
        for p in factScopes(rules) {
            for section in [KBSection.facts, .decisions] {
                for e in index.entries(project: p, section: section) where !e.isDraft {
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
        for raw in changed {
            guard let id = EntryID(raw), let e = index.entry(id) else { continue }
            let everywhere = id.project == overviewScopeID
            let kind = id.section == .decisions ? "decision" : "fact"
            var told = 0
            for t in run.activeTasks where everywhere || t.scope == id.project {
                guard let s = session(t.sessionID) else { continue }
                deliver(FactoryBrief.factChanged(e.title, id: raw, summary: e.summary, kind: kind), to: s, from: "the factory")
                told += 1
            }
            run.log("\(kind.capitalized) “\(e.title)” changed" + (told > 0 ? "; told \(told) session\(told == 1 ? "" : "s")." : "."), kind: .fact)
        }
        let known = changed.compactMap { EntryID($0).flatMap { index.entry($0) } }.map(Self.known)
        checkCoverage(known: known, open: run.openQuestions)
    }

    /// Facts and work items the factory's sessions proposed, waiting in the Inbox.
    func factoryProposals(_ f: Factory) -> [KBEntry] {
        let ids = Set(f.run?.tasks.map { "session:\($0.sessionID)" } ?? [])
        guard !ids.isEmpty else { return [] }
        return factScopes(f.rules).flatMap { p in
            index.entries(project: p, section: .inbox).filter { e in e.proposedBy.map(ids.contains) ?? false }
        }
    }

    // MARK: Questions and progress from the sessions

    /// The factory and task a session (or one under it) works for.
    private func factoryOwning(_ sessionID: String) -> (String, FactoryTask)? {
        var ids = [sessionID]
        if let parent = session(sessionID)?.parentID { ids.append(parent) }
        for f in factories {
            for id in ids { if let t = f.run?.task(session: id) { return (f.id, t) } }
        }
        return nil
    }

    func factoryAsked(from: String, text: String, options: [String], checkpoint: String?) {
        guard let (fid, task) = factoryOwning(from) else {
            if let s = session(from), let o = overseer {
                deliver("NEEDS: \(text)" + (options.isEmpty ? "" : " Options: " + options.enumerated().map { "(\($0.offset + 1)) \($0.element)" }.joined(separator: " ")),
                        to: o, from: s.title)
            }
            return
        }
        let q = FactoryQuestion(sessionID: from, workItem: task.workItem, checkpoint: checkpoint, text: text, options: options)
        change(fid) { f in
            f.run?.questions.append(q)
            f.run?.log("#\(task.workItem) asks: \(text)", kind: .question, workItem: task.workItem)
        }
        notice = "The factory has a question about #\(task.workItem)."
        testingCheckpoint(sessionID: from, checkpoint: checkpoint)
        if let f = factory(fid) {
            checkCoverage(known: recentlySettled(scopes: factScopes(f.rules)), open: [q])
        }
    }

    func factoryLogged(from: String, text: String) {
        guard let (fid, task) = factoryOwning(from) else { return }
        change(fid) { f in
            f.run?.log(text, kind: text.lowercased().hasPrefix("done:") ? .done : .info, workItem: task.workItem)
            if text.lowercased().hasPrefix("done:"), let i = f.run?.tasks.firstIndex(where: { $0.workItem == task.workItem && $0.isActive }) {
                f.run?.tasks[i].outcome = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }
        if text.lowercased().hasPrefix("done:") { testingCheckpoint(sessionID: from, checkpoint: "done") }
    }

    func answerFactoryQuestion(_ fid: String, _ qid: UUID, answer: String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let q = factory(fid)?.run?.questions.first(where: { $0.id == qid }), q.isOpen else { return }
        endFactoryAside(qid)
        if let s = session(q.sessionID) {
            deliver(FactoryBrief.answer(q.text, text), to: s, from: "the user via the factory")
        }
        change(fid) { f in
            guard let i = f.run?.questions.firstIndex(where: { $0.id == qid }) else { return }
            f.run?.questions[i].answer = text
            f.run?.questions[i].answered = Date()
            f.run?.log("You answered #\(q.workItem.map(String.init) ?? "–"): \(text)", kind: .answer, workItem: q.workItem)
        }
        checkCoverage(known: [Self.known(q, answer: text)], open: allOpenQuestions().filter { $0.id != qid })
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

    func allOpenQuestions() -> [FactoryQuestion] { factories.flatMap { $0.run?.openQuestions ?? [] } }

    /// What the user answered in the factories over the last days, and the decisions and facts of the last two weeks
    /// in these scopes.
    private func recentlySettled(scopes: [String]) -> [FactoryCoverage.Known] {
        let since = Date().addingTimeInterval(-3 * 86_400)
        var asked: [FactoryQuestion] = []
        for f in factories {
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
                recent += index.entries(project: p, section: section).filter { e in !e.isDraft && e.date >= cutoff && e.supersededBy == nil }
            }
        }
        recent.sort { $0.date > $1.date }
        let entries: [FactoryCoverage.Known] = recent.prefix(25).map { Self.known($0) }
        return answers + entries
    }

    /// Asks Claude which open questions what the user answered or decided already settles; those are answered for
    /// the user, the sessions are told, and the user sees it.
    func checkCoverage(known: [FactoryCoverage.Known], open: [FactoryQuestion]) {
        let open = open.filter { $0.isOpen && !coverageChecking.contains($0.id) }
        guard !known.isEmpty, !open.isEmpty, case .found = claudeAvailability else { return }
        let items = open.map { FactoryCoverage.Open(id: $0.id, text: $0.text, workItem: $0.workItem) }
        coverageChecking.formUnion(open.map(\.id))
        Task {
            let reply = await claudeOnce(FactoryCoverage.prompt(known: known, open: items), system: FactoryCoverage.system)
            coverageChecking.subtract(open.map(\.id))
            guard let reply else { return }
            for v in FactoryCoverage.parse(reply, open: items) { answerForYou(v) }
        }
    }

    private func answerForYou(_ v: FactoryCoverage.Verdict) {
        guard let f = factories.first(where: { $0.run?.questions.contains { $0.id.uuidString.lowercased() == v.id.lowercased() && $0.isOpen } ?? false }),
              let q = f.run?.questions.first(where: { $0.id.uuidString.lowercased() == v.id.lowercased() }) else { return }
        endFactoryAside(q.id)
        if let s = session(q.sessionID) {
            deliver(FactoryCoverage.message(question: q.text, answer: v.answer, because: v.because), to: s, from: "the user via the factory")
        }
        change(f.id) { f in
            guard let i = f.run?.questions.firstIndex(where: { $0.id == q.id }) else { return }
            f.run?.questions[i].answer = v.answer
            f.run?.questions[i].answered = Date()
            f.run?.questions[i].indirect = true
            f.run?.questions[i].coveredBy = v.because
            f.run?.log("Answered for you on #\(q.workItem.map(String.init) ?? "–") (\(v.because)): \(v.answer)", kind: .answer, workItem: q.workItem)
        }
        notice = "A question on #\(q.workItem.map(String.init) ?? "–") was already answered (\(v.because)). It's under Answered for you."
    }

    func dismissAnsweredForYou(_ fid: String, _ qid: UUID) {
        change(fid) { f in
            if let i = f.run?.questions.firstIndex(where: { $0.id == qid }) { f.run?.questions[i].dismissed = true }
        }
    }

    /// The user adds to an answer given for them.
    func addToAnsweredForYou(_ fid: String, _ qid: UUID, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let q = factory(fid)?.run?.questions.first(where: { $0.id == qid }) else { return }
        if let s = session(q.sessionID) {
            deliver("The user adds to the answer to your question “\(q.text)”: \(t)", to: s, from: "the user via the factory")
        }
        change(fid) { f in
            guard let i = f.run?.questions.firstIndex(where: { $0.id == qid }) else { return }
            f.run?.questions[i].dismissed = true
            f.run?.log("You added to the answer on #\(q.workItem.map(String.init) ?? "–"): \(t)", kind: .answer, workItem: q.workItem)
        }
    }

    /// One prompt to Claude, never saved; nil when it fails or takes longer than `timeout`. Without `tools` it can
    /// only read files; it never writes.
    func claudeOnce(_ prompt: String, system: String, model: String = "sonnet", tools: [String] = [],
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
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // MARK: Side conversations on questions

    static let asideTools = ["Read", "Grep", "Glob", "Bash(kb:*)", "Bash(git log:*)", "Bash(git diff:*)", "Bash(git show:*)",
                             "Bash(git status:*)", "Bash(ls:*)"]

    /// Whether a side conversation can start: the asking session has a conversation to copy.
    func canStartAside(_ q: FactoryQuestion) -> Bool { session(q.sessionID)?.claudeSessionID != nil }

    /// Copies the asking session's conversation into a short side session that catches the user up and takes
    /// follow-up questions. It is never saved and never listed with the sessions.
    func startFactoryAside(_ q: FactoryQuestion) {
        guard factoryAsides[q.id] == nil, let s = session(q.sessionID), let sid = s.claudeSessionID else { return }
        guard var launch = launch(prompt: FactoryBrief.asideSystemPrompt, sessionID: sid, resume: true, model: defaultModel,
                                  cwd: s.workingDirectory, tools: Self.asideTools) else { return }
        launch.fork = true
        launch.persist = false
        launch.disallowedTools = ["Write", "Edit", "NotebookEdit", "AskUserQuestion", "Agent", "Task"]
        let chat = ClaudeChat()
        do { try chat.start(launch, mode: "aside") } catch { return }
        factoryAsides[q.id] = chat
        chat.send(FactoryBrief.catchUp(q.text), tag: "catchup", display: "Catch me up")
    }

    func askFactoryAside(_ qid: UUID, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let chat = factoryAsides[qid], chat.isRunning else { return }
        chat.send(t, tag: "ask-\(UUID().uuidString.prefix(8))")
    }

    func endFactoryAside(_ qid: UUID) {
        factoryAsides.removeValue(forKey: qid)?.stop()
    }

    func skipFactoryQuestion(_ fid: String, _ qid: UUID) {
        endFactoryAside(qid)
        guard let q = factory(fid)?.run?.questions.first(where: { $0.id == qid }), q.isOpen else { return }
        if let s = session(q.sessionID) {
            deliver("The user left your question “\(q.text)” to you: make the reasonable choice, note the assumption in your report, and carry on.",
                    to: s, from: "the user via the factory")
        }
        change(fid) { f in
            guard let i = f.run?.questions.firstIndex(where: { $0.id == qid }) else { return }
            f.run?.questions[i].answer = "Left to the session"
            f.run?.questions[i].answered = Date()
            f.run?.log("You left the question on #\(q.workItem.map(String.init) ?? "–") to the session.", kind: .answer, workItem: q.workItem)
        }
    }
}
