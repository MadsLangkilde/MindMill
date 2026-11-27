import Foundation
import KBCore

/// A new Build session. It leads (and may start sessions under it) only when it is given helpers.
public struct NewLeadRequest: Identifiable {
    public enum Helpers: String, CaseIterable { case alone, auto, fixed }

    public let id = UUID()
    public var title = ""
    public var project: String?
    public var about: String?
    public var brief = ""
    public var strategy: String?
    public var helpers: Helpers = .alone
    public var helperCount = 3
    /// Set when adding a session under a lead instead of starting a new lead.
    public var parent: String?

    public init(title: String = "", project: String? = nil, about: String? = nil, brief: String = "", strategy: String? = nil,
                helpers: Helpers = .alone, helperCount: Int = 3, parent: String? = nil) {
        self.title = title
        self.project = project
        self.about = about
        self.brief = brief
        self.strategy = strategy
        self.helpers = helpers
        self.helperCount = helperCount
        self.parent = parent
    }
}

/// The crew: the overview session, leads and the sessions under them, the orders sessions leave with `kb crew`, and
/// the crew tick that carries them out and keeps `state.json` current.
extension SessionHub {
    // MARK: The tick

    /// Starts the crew tick (every 1.5 s): orders, the factories, scans, the host's own work, done sessions, `state.json`.
    public func startTicking(every interval: TimeInterval = 1.5) {
        guard tickTask == nil else { return }
        loadIfNeeded()
        CrewFiles(directory: crewDirectory).prepare()
        tick()
        let nanos = UInt64(interval * 1_000_000_000)
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    public func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    public var isTicking: Bool { tickTask != nil }

    public func crewChanged() { crewDirty = true }

    public func tick() {
        processOrders()
        engine.factories.tick()
        engine.scans.tick()
        for hook in onTick { hook() }
        noteDoneSessions()
        let state = crewSnapshot()
        if CrewFiles.needsWrite(state, last: crewLastState, dirty: crewDirty, written: crewWritten) {
            writeCrewState(state)
        }
    }

    public func crewSnapshot() -> CrewState {
        let iso = ISO8601DateFormatter()
        let cutoff = Date().addingTimeInterval(-86_400)
        let listed = buildSessions.filter { $0.role != .solo || $0.chat.isRunning || $0.updated > cutoff }
        return CrewState(updated: iso.string(from: Date()), sessions: listed.map { s in
            CrewState.Session(id: s.id, title: s.title, role: s.role, lead: s.parentID, project: s.project, state: s.crewState,
                              activity: s.chat.activity ?? "", strategy: s.strategy, model: s.model,
                              updated: iso.string(from: s.updated), last: String(s.lastReply.prefix(300)), about: s.about)
        })
    }

    private func writeCrewState(_ state: CrewState) {
        do {
            try CrewFiles(directory: crewDirectory).write(state)
            crewLastState = state
            crewWritten = Date()
            crewDirty = false
        } catch {
            ClaudeChat.log("crew: state write failed: \(error.localizedDescription)")
        }
    }

    func processOrders() {
        for data in CrewFiles(directory: crewDirectory).takeOrders() {
            if let orderHook {
                if orderHook(data) { continue }
            } else if TestSuggestion.parse(data) != nil, engine.tests.suggested(data) {
                continue
            } else if engine.tests.deliveryRequested(data) {
                continue
            }
            guard let order = CrewOrder.parse(data) else { continue }
            ClaudeChat.log("crew: order \(order)")
            execute(order)
        }
    }

    public func execute(_ order: CrewOrder) {
        switch order {
        case .send(let to, let text, let from):
            guard let target = session(to) else { return }
            if target.role == .overseer { reportedToOverseer[from] = Date() }
            deliver(text, to: target, from: senderLabel(from))
        case .stop(let to, let from):
            guard let target = session(to) else { return }
            stop(target)
            engine.report("\(senderLabel(from)) stopped “\(target.title)”.")
        case .archive(let to, _):
            guard let target = session(to), target.role != .overseer else { return }
            archiveFinished(target)
        case .folder(let to, let path, _):
            guard let target = session(to) else { return }
            target.folders.removeAll { $0 == path }
            target.folders.append(path)
            save()
        case .link(let to, let about, _):
            guard let target = session(to), target.role == .solo || target.role == .lead else { return }
            link(target, to: about)
        case .factoryAsk(let from, let text, let options, let checkpoint):
            engine.factories.asked(from: from, text: text, options: options, checkpoint: checkpoint)
        case .factoryLog(let from, let text):
            engine.factories.logged(from: from, text: text)
        case .sync(let req):
            if let onSync { onSync(req) } else { engine.runSync(req) }
        case .start(let req):
            let sender = session(req.from)
            var parent = session(req.parent)
            if let p = parent, p.role == .member { parent = session(p.parentID) ?? p }
            // A session that starts sessions under it leads them, in Build.
            if let p = parent, p.role == .solo {
                p.role = .lead
                p.space = .build
            }
            let role: SessionRole = req.lead || (parent == nil && sender?.role == .overseer) ? .lead : (parent != nil ? .member : .solo)
            let strategy = req.strategy.flatMap { slug in strategies.first { $0.slug == slug } }
            let project = req.project ?? parent?.project ?? sender?.project
            let from = senderLabel(req.from)
            let brief = req.text.isEmpty ? "Start on: \(req.title)" : req.text
            var isDir: ObjCBool = false
            let repo = req.repo.map { URL(fileURLWithPath: KBConfig.expandTilde($0)) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue ? $0 : nil }
            newSession(title: req.title, project: project,
                       message: "[From \(from)]\n\(brief)", display: "✉ \(from)\n\(brief)",
                       role: role, parentID: role == .member ? parent?.id : nil, model: req.model, strategy: strategy,
                       about: req.about ?? (role == .member ? parent?.about : nil), show: false, space: .build,
                       workingDirectory: repo)
            engine.report("\(from) started “\(req.title)”.")
            crewChanged()
        }
    }

    func senderLabel(_ id: String) -> String {
        guard let s = session(id) else { return id == "user" ? "You" : "the command line" }
        switch s.role {
        case .overseer: return "the overview session"
        case .lead: return "\(s.title) (lead)"
        case .member, .solo: return s.title
        }
    }

    // MARK: Messages

    /// A message from another session or the user: sent now, or after the running turn.
    public func deliver(_ text: String, to s: WorkSession, from label: String) {
        let message = "[From \(label)]\n\(text)"
        let display = "✉ \(label)\n\(text)"
        if s.chat.isBusy {
            s.inbox.append((message, display))
        } else {
            send(message, in: s, display: display)
        }
        crewChanged()
    }

    /// Tells a running session about a change in the crew, without starting one that isn't.
    func deliverNote(_ text: String, to s: WorkSession) {
        guard s.chat.isRunning || s.claudeSessionID != nil else { return }
        deliver(text, to: s, from: "the Mindmill app")
    }

    /// The user's message to a session from the overview: sent now, or after the running turn.
    public func message(_ s: WorkSession, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if s.chat.isBusy {
            s.inbox.append((t, t))
            engine.report("“\(s.title)” gets it when its current step is done.")
        } else {
            send(t, in: s)
        }
    }

    /// The user answered a session's question in the session or the Waiting on you panel. When that session told
    /// the overview session about its work lately and the overview waits on the user, it may be asking the same
    /// thing: tell it, so it drops its copy.
    public func userAnswered(_ s: WorkSession, _ text: String) {
        guard s.role != .overseer, let o = overseer, o.crewState.needsUser,
              let at = reportedToOverseer[s.id], Date().timeIntervalSince(at) < 7200 else { return }
        let quoted = text.count > 160 ? String(text.prefix(157)) + "…" : text
        deliverNote("The user answered “\(s.title)” directly: “\(quoted)”. If your open question is about the same thing, drop it in one line, without a choices block.", to: o)
    }

    // MARK: The overview session

    @discardableResult
    public func ensureOverseer() -> WorkSession {
        if let o = overseer { return o }
        return newSession(title: "Overview", role: .overseer, show: false)
    }

    /// The user's message to the overview session, with every session's state in front of it.
    public func askOverseer(_ text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let o = ensureOverseer()
        send("Current sessions:\n\(crewSnapshot().statusText)\n\n---\n\n\(trimmed)", in: o, display: trimmed,
             attachments: attachments)
    }

    // MARK: Leads and members

    @discardableResult
    public func startLead(_ r: NewLeadRequest) -> WorkSession {
        let strategy = r.strategy.flatMap { slug in strategies.first { $0.slug == slug } }
        let brief = r.brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parentID = r.parent, let lead = session(parentID) {
            let s = newSession(title: title.isEmpty ? "Session" : title, project: lead.project,
                               message: brief.isEmpty ? nil : "[From you, through \(lead.title)'s crew]\n\(brief)",
                               display: brief.isEmpty ? nil : brief, role: .member, parentID: lead.id, strategy: strategy,
                               about: lead.about)
            if !brief.isEmpty { s.brief = brief }
            deliverNote("“\(s.title)” was added under you by the user; it reports to you with `kb crew send lead`.", to: lead)
            crewChanged()
            return s
        }
        let leads = r.helpers != .alone
        let index = engine.index
        let s = newSession(title: title.isEmpty ? "New session" : title, project: r.project,
                           subject: r.about.flatMap(EntryID.init).map { .entry($0, title: index.entry($0)?.title ?? $0.stem) },
                           role: leads ? .lead : .solo, about: r.about, space: .build)
        if let strategy {
            s.strategy = strategy.slug
            s.strategyOffered = true
        }
        if leads { s.strategyOffered = true }
        var setup: [String] = []
        if let strategy { setup.append(strategy.message) }
        switch r.helpers {
        case .alone:
            break
        case .auto where strategy?.spawns != true:
            setup.append("Lead this work. When parts can run in parallel or need their own expert, start up to \(r.helperCount) session\(r.helperCount == 1 ? "" : "s") under you with `kb crew start --under me --title \"<part>\" \"<brief: goal, files, done when>\"`. Work alone when the task is small. Review what they report before you call it done.")
        case .auto:
            break
        case .fixed:
            setup.append("Lead this work with exactly \(r.helperCount) session\(r.helperCount == 1 ? "" : "s") under you. Split it into \(r.helperCount) part\(r.helperCount == 1 ? "" : "s") that don't touch the same files, start each with `kb crew start --under me --title \"<part>\" \"<brief: goal, files, done when>\"`, then review and integrate what they report.")
        }
        s.pendingSetup = setup.isEmpty ? nil : setup.joined(separator: "\n\n")
        if !brief.isEmpty {
            s.brief = brief
            send(brief, in: s, display: brief)
        }
        crewChanged()
        return s
    }

    /// The work a session is about, with a pull request mapped to its work item when My Work knows it.
    public func workKey(_ about: String?) -> String? {
        guard let about else { return nil }
        if let pr = Self.number(about, "mypr:"),
           let item = engine.tracker.myWork?.items.first(where: { $0.prs.contains { $0.id == pr } }) {
            return item.sessionKey
        }
        return about
    }

    private func candidate(_ s: WorkSession) -> SessionGrouping.Candidate {
        .init(id: s.id, work: workKey(s.about), role: s.role, created: s.created, implements: s.about?.hasPrefix("wi:") ?? false)
    }

    private var topLevelWorkSessions: [WorkSession] {
        buildSessions.filter { ($0.role == .solo || $0.role == .lead) && !isArchived($0) }
    }

    /// The open session leading this work, if there is one.
    public func mainSession(forWork key: String) -> WorkSession? {
        SessionGrouping.main(of: topLevelWorkSessions.filter { workKey($0.about) == key }.map(candidate))
            .flatMap { session($0.id) }
    }

    /// Moves extra top-level sessions on the same work under the one leading it. Each hears about it with its next
    /// message, so nothing wakes up for it.
    public func groupSessionsByWork() {
        var changed = false
        for (leadID, memberIDs) in SessionGrouping.plan(topLevelWorkSessions.map(candidate)) {
            guard let lead = session(leadID) else { continue }
            for id in memberIDs {
                guard let s = session(id), !s.chat.isBusy, !s.crewState.needsUser else { continue }
                promoteToLead(lead)
                for m in members(of: s) { m.parentID = lead.id }
                s.role = .member
                s.parentID = lead.id
                s.pendingSetup = Self.joined(s.pendingSetup, Self.underLeadNote(lead))
                changed = true
            }
        }
        if changed {
            save()
            crewChanged()
        }
    }

    /// A single session that gets sessions under it leads them; it reads why with its next message.
    public func promoteToLead(_ s: WorkSession) {
        guard s.role == .solo else { return }
        s.role = .lead
        s.space = .build
        s.pendingSetup = Self.joined(s.pendingSetup, "You now lead this work: other sessions on it work under you and report to you. Start more with `kb crew start --under me --title \"<part>\" \"<brief: goal, files, done when>\"` when a part can run on its own. Post a one-line status to the overview session with `kb crew send overseer` when a part is done or you are blocked.")
    }

    public static func underLeadNote(_ lead: WorkSession) -> String {
        "You now work under “\(lead.title)” (`\(lead.id.prefix(8))`), which leads this work. When you are done or blocked, report to it with `kb crew send lead \"<short report>\"`."
    }

    static func joined(_ a: String?, _ b: String) -> String { [a, b].compactMap { $0 }.joined(separator: "\n\n") }

    public func makeLead(_ s: WorkSession) {
        let old = session(s.parentID)
        s.space = .build
        s.role = .lead
        s.parentID = nil
        save()
        deliverNote("You now lead this work in Build mode. Sessions you start with `kb crew start --under me --title \"<part>\" \"<brief>\"` work under you and report to you; post a one-line status to the overview session with `kb crew send overseer` when a part is done or you are blocked.", to: s)
        if let old { deliverNote("“\(s.title)” no longer works under you; the user made it a lead of its own.", to: old) }
        crewChanged()
    }

    public func move(_ s: WorkSession, under lead: WorkSession) {
        guard s.id != lead.id else { return }
        for m in members(of: s) { m.parentID = lead.id }
        s.space = .build
        s.role = .member
        s.parentID = lead.id
        save()
        deliverNote("You now work under “\(lead.title)” (`\(lead.id.prefix(8))`). Report to it with `kb crew send lead \"<short report>\"` when you are done or blocked.", to: s)
        deliverNote("“\(s.title)” (`\(s.id.prefix(8))`) now works under you; message it with `kb crew send \(s.id.prefix(8)) \"…\"`.", to: lead)
        crewChanged()
    }

    public func detach(_ s: WorkSession) {
        s.role = .solo
        s.parentID = nil
        save()
        crewChanged()
    }

    /// Starts a stopped session again: it continues its own conversation where it left off. False when it never
    /// started (nothing to resume; the host opens it instead).
    @discardableResult
    public func resume(_ s: WorkSession) -> Bool {
        guard !s.chat.isRunning else { return true }
        if s.claudeSessionID == nil, s.chat.items.isEmpty { return false }
        let text = s.role == .member
            ? "You were stopped. Continue the work where you left off. When it is done or blocked, report to your lead with `kb crew send lead`."
            : "You were stopped. Continue the work where you left off, and say briefly where things stand."
        send(text, in: s, display: "Resume")
        crewChanged()
        return true
    }

    public func deleteCrew(_ lead: WorkSession) {
        for m in members(of: lead) { delete(m) }
        delete(lead)
    }

    public func stopCrew(_ lead: WorkSession) {
        for m in members(of: lead) where m.chat.isRunning { stop(m) }
        stop(lead)
    }

    /// A Plan session continues in Build mode, for example once it turns into implementation work.
    public func moveToBuild(_ s: WorkSession) {
        s.space = .build
        save()
        crewChanged()
    }

    // MARK: Archiving

    /// The session reached its purpose and the user said to archive it: it and the sessions under it are archived and
    /// stopped once their turns end, and the overview session hears of it so it can drop its own question.
    public func archiveFinished(_ s: WorkSession) {
        setArchived(s, true)
        for m in [s] + members(of: s) {
            if m.chat.isBusy { m.stopAfterTurn = true } else if m.chat.isRunning { m.chat.stop() }
        }
        engine.report("“\(s.title)” is archived.")
        if let o = overseer, o !== s {
            deliver("“\(s.title)” (`\(s.id.prefix(8))`) is archived. If you asked the user about archiving it, that's settled: reply in one line.",
                    to: o, from: "the Mindmill app")
        }
        crewChanged()
    }

    /// A session that found out its work is a work item or a pull request: the app then shows its stage and archives
    /// it when that completes. One already tied to a work item or pull request keeps it.
    public func link(_ s: WorkSession, to about: String) {
        guard !FinishedCheck.isTracked(about: s.about) else {
            if s.about != about { deliverNote("This session is already tied to `\(s.about ?? "")`; it stays that way.", to: s) }
            return
        }
        s.about = about
        save()
        crewChanged()
    }

    public func setArchived(_ s: WorkSession, _ on: Bool) {
        s.archived = on
        for m in members(of: s) { m.archived = on }
        save()
    }

    /// Asks quiet sessions that no PR or work item tracks whether their work is done, a few at a time; each asks the
    /// user, and tells the overview session, when it is.
    public func askFinishedSessions() {
        guard backgroundChecks else { return }
        var asked = defaults.dictionary(forKey: Self.finishedAskedKey) as? [String: Double] ?? [:]
        let due = buildSessions.filter { s in
            FinishedCheck.shouldAsk(role: s.role, about: s.about, busy: s.chat.isBusy, needsUser: s.crewState.needsUser,
                                    archived: isArchived(s), hasMessages: !s.chat.items.isEmpty, updated: s.updated,
                                    askedAt: asked[s.id].map(Date.init(timeIntervalSince1970:)))
        }.sorted { $0.updated > $1.updated }.prefix(3)
        guard !due.isEmpty else { return }
        for s in due {
            asked[s.id] = Date().timeIntervalSince1970
            deliver(ClaudeModes.finishedCheck, to: s, from: "the Mindmill app")
        }
        let known = Set(list.map(\.id))
        defaults.set(asked.filter { known.contains($0.key) }, forKey: Self.finishedAskedKey)
    }

    // MARK: Strategies

    public func reloadStrategies() {
        strategies = StrategyStore.load(pluginRoot: URL(fileURLWithPath: KBConfig.expandTilde(engine.pluginRootPath)), kbRoot: engine.rootURL)
    }

    public func saveStrategy(_ st: Strategy) throws {
        try StrategyStore.save(st, kbRoot: engine.rootURL)
        reloadStrategies()
    }

    public func deleteStrategy(_ st: Strategy) throws {
        try StrategyStore.delete(st.slug, kbRoot: engine.rootURL)
        reloadStrategies()
    }

    /// The strategy by slug or title, or one whose title contains `key`.
    public func strategy(_ key: String) throws -> Strategy {
        if strategies.isEmpty { reloadStrategies() }
        let k = key.lowercased()
        if let st = strategies.first(where: { $0.slug == k || $0.title.lowercased() == k }) { return st }
        if !k.isEmpty, let st = strategies.first(where: { $0.title.lowercased().contains(k) }) { return st }
        throw ActionError("There's no strategy \(key).")
    }

    /// Returns a note for the host when a Plan session moved to Build because it now leads sessions.
    @discardableResult
    public func applyStrategy(_ st: Strategy, to s: WorkSession) -> String? {
        s.strategy = st.slug
        s.strategyOffered = true
        var note: String?
        if st.spawns, s.role == .solo {
            s.role = .lead
            if s.space == .plan {
                s.space = .build
                note = "“\(s.title)” now leads its own sessions, so it moved to Build."
            }
        }
        let display = "Strategy: \(st.title)"
        if s.chat.isBusy {
            s.inbox.append((st.message, display))
        } else {
            send(st.message, in: s, display: display)
        }
        crewChanged()
        if let note { engine.report(note) }
        return note
    }

    /// The first message of a session that starts with a strategy: the task and the strategy's instructions together.
    public func start(_ task: String, with st: Strategy, in s: WorkSession, attachments: [Attachment] = []) {
        s.strategy = st.slug
        s.strategyOffered = true
        if st.spawns, s.role == .solo {
            s.role = .lead
            if s.space == .plan {
                s.space = .build
                engine.report("“\(s.title)” leads its own sessions, so it moved to Build.")
            }
        }
        send(task + "\n\n" + st.message, in: s, display: task, attachments: attachments)
        crewChanged()
    }

    public func clearStrategy(_ s: WorkSession) {
        guard let current = s.strategy else { return }
        s.strategy = nil
        let title = strategies.first { $0.slug == current }?.title ?? current
        let text = "Stop following the strategy “\(title)”. Carry on with the task the usual way."
        if s.chat.isBusy { s.inbox.append((text, "Strategy: none")) } else { send(text, in: s, display: "Strategy: none") }
        crewChanged()
    }

    /// Opens a session that helps write a new strategy and saves it with `kb strategy new`.
    @discardableResult
    public func draftStrategy(space: SessionSpace, show: Bool = true) -> WorkSession {
        newSession(title: "New strategy",
                   message: "Help me create a new strategy for my \(Brain.name) sessions in the Mindmill app. Read `kb strategy list` and one or two with `kb strategy show <slug>` to see the format. Ask me what the strategy should achieve (one question at a time), draft it, show it, and when I agree save it with `kb strategy new … --body-stdin`.",
                   display: "Create a new strategy with \(Brain.name)", show: show, space: space)
    }

    public static func number(_ key: String, _ prefix: String) -> Int? {
        key.hasPrefix(prefix) ? Int(key.dropFirst(prefix.count)) : nil
    }
}
