import AppKit
import KBCore
import SwiftUI

/// Plan is the knowledge base and planning; Build is the implementation sessions.
enum AppMode: String, CaseIterable, Identifiable {
    case plan, build

    var id: String { rawValue }
    var title: String { self == .plan ? "Plan" : "Build" }
    var icon: String { self == .plan ? "books.vertical" : "hammer" }
}

/// A new Build session. It leads (and may start sessions under it) only when it is given helpers.
struct NewLeadRequest: Identifiable {
    enum Helpers: String, CaseIterable { case alone, auto, fixed }

    let id = UUID()
    var title = ""
    var project: String?
    var about: String?
    var brief = ""
    var strategy: String?
    var helpers: Helpers = .alone
    var helperCount = 3
    /// Set when adding a session under a lead instead of starting a new lead.
    var parent: String?
}

struct StrategiesSheetRequest: Identifiable {
    let id = UUID()
    var selected: String?
}

extension AppModel {
    var crewDirectory: URL { CrewDir.url() }

    var overseer: WorkSession? { sessions.first { $0.role == .overseer } }
    /// Build mode's sessions; Plan's live in the Claude window.
    var buildSessions: [WorkSession] { sessions.filter { $0.space == .build } }
    var buildSessionsNeedingUser: [WorkSession] {
        buildSessions.filter { $0.role != .overseer && $0.crewState.needsUser }
    }
    /// The overview session is waiting on the user: a question or a choice it asked.
    var overseerNeedsUser: Bool { overseer?.crewState.needsUser ?? false }
    /// Everything in Build that waits on the user, the overview session included.
    var waitingTally: WaitingTally {
        WaitingTally(buildSessions: buildSessionsNeedingUser.count, overseer: overseerNeedsUser,
                     factoryQuestions: factoryQuestionCount, planSessions: planSessionsNeedingUser.count)
    }
    var leads: [WorkSession] { buildSessions.filter { $0.role == .lead && !isArchived($0) }.sorted { $0.created < $1.created } }

    /// Build's list: leads and single sessions together, newest first; members sit under their lead.
    var topLevelBuildSessions: [WorkSession] {
        let leadIDs = Set(leads.map(\.id))
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        return buildSessions.filter { s in
            !isArchived(s) && (s.role == .lead || ((s.role == .solo || (s.role == .member && !leadIDs.contains(s.parentID ?? "")))
                                && (s.chat.isRunning || s.updated > cutoff)))
        }.sorted { $0.created > $1.created }
    }

    func members(of lead: WorkSession) -> [WorkSession] {
        sessions.filter { $0.role == .member && $0.parentID == lead.id }.sorted { $0.created < $1.created }
    }

    /// Sessions in no crew: recent ones, and any that are running.
    var otherSessions: [WorkSession] {
        let leadIDs = Set(leads.map(\.id))
        let cutoff = Date().addingTimeInterval(-3 * 86_400)
        return buildSessions.filter { s in
            !isArchived(s) && (s.role == .solo || (s.role == .member && !leadIDs.contains(s.parentID ?? "")))
                && (s.chat.isRunning || s.updated > cutoff)
        }.sorted { $0.updated > $1.updated }
    }

    func session(_ id: String?) -> WorkSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    /// Sessions working on a KB entry, for Plan mode's "in Build" marks.
    func sessions(about id: EntryID) -> [WorkSession] {
        buildSessions.filter { $0.about == id.rawValue && $0.role != .overseer }
    }

    // MARK: Engine

    func startCrewEngine() {
        guard crewTimer == nil else { return }
        loadSessionsIfNeeded()
        try? FileManager.default.createDirectory(at: crewDirectory.appendingPathComponent("orders"), withIntermediateDirectories: true)
        crewTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.crewTick() }
        }
        crewTick()
    }

    func crewChanged() { crewDirty = true }

    private func crewTick() {
        processOrders()
        factoryTick()
        scanTick()
        noteDoneSessions()
        let state = crewSnapshot()
        if crewDirty || state.sessions != crewLastState?.sessions || Date().timeIntervalSince(crewWritten) > 30 {
            writeCrewState(state)
        }
    }

    func crewSnapshot() -> CrewState {
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        do {
            try FileManager.default.createDirectory(at: crewDirectory, withIntermediateDirectories: true)
            try data.write(to: crewDirectory.appendingPathComponent("state.json"), options: .atomic)
            crewLastState = state
            crewWritten = Date()
            crewDirty = false
        } catch {
            ClaudeChat.log("crew: state write failed: \(error.localizedDescription)")
        }
    }

    private func processOrders() {
        let dir = crewDirectory.appendingPathComponent("orders")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let data = try? Data(contentsOf: file)
            try? FileManager.default.removeItem(at: file)
            guard let data else { continue }
            if testSuggested(data) { continue }
            guard let order = CrewOrder.parse(data) else { continue }
            ClaudeChat.log("crew: order \(order)")
            execute(order)
        }
    }

    private func execute(_ order: CrewOrder) {
        switch order {
        case .send(let to, let text, let from):
            guard let target = session(to) else { return }
            if target.role == .overseer { reportedToOverseer[from] = Date() }
            deliver(text, to: target, from: senderLabel(from))
        case .stop(let to, let from):
            guard let target = session(to) else { return }
            stopSession(target)
            notice = "\(senderLabel(from)) stopped “\(target.title)”."
        case .archive(let to, _):
            guard let target = session(to), target.role != .overseer else { return }
            archiveFinished(target)
        case .factoryAsk(let from, let text, let options, let checkpoint):
            factoryAsked(from: from, text: text, options: options, checkpoint: checkpoint)
        case .factoryLog(let from, let text):
            factoryLogged(from: from, text: text)
        case .sync(let req):
            runSync(req)
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
            newSession(title: req.title, project: project,
                       message: "[From \(from)]\n\(brief)", display: "✉ \(from)\n\(brief)",
                       role: role, parentID: role == .member ? parent?.id : nil, model: req.model, strategy: strategy,
                       about: req.about ?? (role == .member ? parent?.about : nil), show: false, space: .build)
            notice = "\(from) started “\(req.title)”."
            crewChanged()
        }
    }

    private func senderLabel(_ id: String) -> String {
        guard let s = session(id) else { return id == "user" ? "You" : "the command line" }
        switch s.role {
        case .overseer: return "the overview session"
        case .lead: return "\(s.title) (lead)"
        case .member, .solo: return s.title
        }
    }

    /// The session reached its purpose and the user said to archive it: it and the sessions under it are archived and
    /// stopped once their turns end, and the overview session hears of it so it can drop its own question.
    func archiveFinished(_ s: WorkSession) {
        setArchived(s, true)
        for m in [s] + members(of: s) {
            if m.chat.isBusy { m.stopAfterTurn = true } else if m.chat.isRunning { m.chat.stop() }
        }
        notice = "“\(s.title)” is archived."
        if let o = overseer, o !== s {
            deliver("“\(s.title)” (`\(s.id.prefix(8))`) is archived. If you asked the user about archiving it, that's settled: reply in one line.",
                    to: o, from: "the Mindmill app")
        }
        crewChanged()
    }

    static let finishedAskedKey = "finishedChecksAsked"

    /// Asks quiet sessions that no PR or work item tracks whether their work is done, a few at a time; each asks the
    /// user, and tells the overview session, when it is.
    func askFinishedSessions() {
        guard backgroundStarted else { return }
        var asked = UserDefaults.standard.dictionary(forKey: Self.finishedAskedKey) as? [String: Double] ?? [:]
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
        let known = Set(sessions.map(\.id))
        UserDefaults.standard.set(asked.filter { known.contains($0.key) }, forKey: Self.finishedAskedKey)
    }

    /// A message from another session or the user: sent now, or after the running turn.
    func deliver(_ text: String, to s: WorkSession, from label: String) {
        let message = "[From \(label)]\n\(text)"
        let display = "✉ \(label)\n\(text)"
        if s.chat.isBusy {
            s.inbox.append((message, display))
        } else {
            send(message, in: s, display: display)
        }
        crewChanged()
    }

    // MARK: Actions

    @discardableResult
    func ensureOverseer() -> WorkSession {
        if let o = overseer { return o }
        return newSession(title: "Overview", role: .overseer, show: false)
    }

    /// The user's message to the overview session, with every session's state in front of it.
    func askOverseer(_ text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let o = ensureOverseer()
        o.input = ""
        send("Current sessions:\n\(crewSnapshot().statusText)\n\n---\n\n\(trimmed)", in: o, display: trimmed,
             attachments: attachments)
    }

    func startLead(_ r: NewLeadRequest) {
        let strategy = r.strategy.flatMap { slug in strategies.first { $0.slug == slug } }
        let brief = r.brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parentID = r.parent, let lead = session(parentID) {
            let s = newSession(title: title.isEmpty ? "Session" : title, project: lead.project,
                               message: brief.isEmpty ? nil : "[From you, through \(lead.title)'s crew]\n\(brief)",
                               display: brief.isEmpty ? nil : brief, role: .member, parentID: lead.id, strategy: strategy,
                               about: lead.about)
            if brief.isEmpty { s.input = "" }
            deliverNote("“\(s.title)” was added under you by the user; it reports to you with `kb crew send lead`.", to: lead)
        } else {
            let leads = r.helpers != .alone
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
                send(brief, in: s, display: brief + (strategy.map { "\n\nStrategy: \($0.title)" } ?? ""))
            }
        }
        crewChanged()
    }

    /// Tells a running session about a change in the crew, without starting one that isn't.
    /// The user answered a session's question in the session or the Waiting on you panel. When that session told
    /// the overview session about its work lately and the overview waits on the user, it may be asking the same
    /// thing: tell it, so it drops its copy.
    func userAnswered(_ s: WorkSession, _ text: String) {
        guard s.role != .overseer, let o = overseer, o.crewState.needsUser,
              let at = reportedToOverseer[s.id], Date().timeIntervalSince(at) < 7200 else { return }
        let quoted = text.count > 160 ? String(text.prefix(157)) + "…" : text
        deliverNote("The user answered “\(s.title)” directly: “\(quoted)”. If your open question is about the same thing, drop it in one line, without a choices block.", to: o)
    }

    private func deliverNote(_ text: String, to s: WorkSession) {
        guard s.chat.isRunning || s.claudeSessionID != nil else { return }
        deliver(text, to: s, from: "the Mindmill app")
    }

    // MARK: One lead per piece of work

    /// The work a session is about, with a pull request mapped to its work item when My Work knows it.
    func workKey(_ about: String?) -> String? {
        guard let about else { return nil }
        if let pr = Self.number(about, "mypr:"), let item = myWork?.items.first(where: { $0.prs.contains { $0.id == pr } }) {
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
    func mainSession(forWork key: String) -> WorkSession? {
        SessionGrouping.main(of: topLevelWorkSessions.filter { workKey($0.about) == key }.map(candidate))
            .flatMap { session($0.id) }
    }

    /// Moves extra top-level sessions on the same work under the one leading it. Each hears about it with its next
    /// message, so nothing wakes up for it.
    func groupSessionsByWork() {
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
            saveSessions()
            crewChanged()
        }
    }

    /// A single session that gets sessions under it leads them; it reads why with its next message.
    func promoteToLead(_ s: WorkSession) {
        guard s.role == .solo else { return }
        s.role = .lead
        s.space = .build
        s.pendingSetup = Self.joined(s.pendingSetup, "You now lead this work: other sessions on it work under you and report to you. Start more with `kb crew start --under me --title \"<part>\" \"<brief: goal, files, done when>\"` when a part can run on its own. Post a one-line status to the overview session with `kb crew send overseer` when a part is done or you are blocked.")
    }

    static func underLeadNote(_ lead: WorkSession) -> String {
        "You now work under “\(lead.title)” (`\(lead.id.prefix(8))`), which leads this work. When you are done or blocked, report to it with `kb crew send lead \"<short report>\"`."
    }

    static func joined(_ a: String?, _ b: String) -> String { [a, b].compactMap { $0 }.joined(separator: "\n\n") }

    func makeLead(_ s: WorkSession) {
        let old = session(s.parentID)
        s.space = .build
        s.role = .lead
        s.parentID = nil
        saveSessions()
        deliverNote("You now lead this work in Build mode. Sessions you start with `kb crew start --under me --title \"<part>\" \"<brief>\"` work under you and report to you; post a one-line status to the overview session with `kb crew send overseer` when a part is done or you are blocked.", to: s)
        if let old { deliverNote("“\(s.title)” no longer works under you; the user made it a lead of its own.", to: old) }
        crewChanged()
    }

    func move(_ s: WorkSession, under lead: WorkSession) {
        guard s.id != lead.id else { return }
        for m in members(of: s) { m.parentID = lead.id }
        s.space = .build
        s.role = .member
        s.parentID = lead.id
        saveSessions()
        deliverNote("You now work under “\(lead.title)” (`\(lead.id.prefix(8))`). Report to it with `kb crew send lead \"<short report>\"` when you are done or blocked.", to: s)
        deliverNote("“\(s.title)” (`\(s.id.prefix(8))`) now works under you; message it with `kb crew send \(s.id.prefix(8)) \"…\"`.", to: lead)
        crewChanged()
    }

    func detach(_ s: WorkSession) {
        s.role = .solo
        s.parentID = nil
        saveSessions()
        crewChanged()
    }

    /// Starts a stopped session again: it continues its own conversation where it left off.
    func resumeSession(_ s: WorkSession) {
        guard !s.chat.isRunning else { return }
        if s.claudeSessionID == nil, s.chat.items.isEmpty {
            buildSelection = s.id
            return
        }
        let text = s.role == .member
            ? "You were stopped. Continue the work where you left off. When it is done or blocked, report to your lead with `kb crew send lead`."
            : "You were stopped. Continue the work where you left off, and say briefly where things stand."
        send(text, in: s, display: "Resume")
        crewChanged()
    }

    func deleteCrew(_ lead: WorkSession) {
        for m in members(of: lead) { deleteSession(m) }
        deleteSession(lead)
    }

    func stopCrew(_ lead: WorkSession) {
        for m in members(of: lead) where m.chat.isRunning { stopSession(m) }
        stopSession(lead)
    }

    /// The user's message to a session from the overview: sent now, or after the running turn.
    func message(_ s: WorkSession, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if s.chat.isBusy {
            s.inbox.append((t, t))
            notice = "“\(s.title)” gets it when its current step is done."
        } else {
            send(t, in: s)
        }
    }

    func applyStrategy(_ st: Strategy, to s: WorkSession) {
        s.strategy = st.slug
        s.strategyOffered = true
        if st.spawns, s.role == .solo {
            s.role = .lead
            if s.space == .plan {
                s.space = .build
                notice = "“\(s.title)” now leads its own sessions, so it moved to Build."
            }
        }
        let display = "Strategy: \(st.title)"
        if s.chat.isBusy {
            s.inbox.append((st.message, display))
        } else {
            send(st.message, in: s, display: display)
        }
        crewChanged()
    }

    /// The first message of a session that starts with a strategy: the task and the strategy's instructions together.
    func start(_ task: String, with st: Strategy, in s: WorkSession, attachments: [Attachment] = []) {
        s.strategy = st.slug
        s.strategyOffered = true
        if st.spawns, s.role == .solo {
            s.role = .lead
            if s.space == .plan {
                s.space = .build
                notice = "“\(s.title)” leads its own sessions, so it moved to Build."
            }
        }
        send(task + "\n\n" + st.message, in: s, display: task, attachments: attachments)
        crewChanged()
    }

    func clearStrategy(_ s: WorkSession) {
        guard let current = s.strategy else { return }
        s.strategy = nil
        let title = strategies.first { $0.slug == current }?.title ?? current
        let text = "Stop following the strategy “\(title)”. Carry on with the task the usual way."
        if s.chat.isBusy { s.inbox.append((text, "Strategy: none")) } else { send(text, in: s, display: "Strategy: none") }
        crewChanged()
    }

    func reloadStrategies() {
        strategies = StrategyStore.load(pluginRoot: URL(fileURLWithPath: KBConfig.expandTilde(pluginRootPath)), kbRoot: rootURL)
    }

    func saveStrategy(_ st: Strategy) {
        do {
            try StrategyStore.save(st, kbRoot: rootURL)
            reloadStrategies()
        } catch {
            errorMessage = "Could not save the strategy: \(error.localizedDescription)"
        }
    }

    func deleteStrategy(_ st: Strategy) {
        do {
            try StrategyStore.delete(st.slug, kbRoot: rootURL)
            reloadStrategies()
        } catch {
            errorMessage = "Could not delete the strategy: \(error.localizedDescription)"
        }
    }

    /// Opens a session that helps write a new strategy and saves it with `kb strategy new`.
    func draftStrategyWithClaude() {
        strategiesSheet = nil
        newSession(title: "New strategy",
                   message: "Help me create a new strategy for my \(Brain.name) sessions in the Mindmill app. Read `kb strategy list` and one or two with `kb strategy show <slug>` to see the format. Ask me what the strategy should achieve (one question at a time), draft it, show it, and when I agree save it with `kb strategy new … --body-stdin`.",
                   display: "Create a new strategy with \(Brain.name)", space: mode == .build ? .build : .plan)
    }

    /// Switches to Build mode on a session.
    /// A Plan session continues in Build mode, for example once it turns into implementation work.
    func moveToBuild(_ s: WorkSession) {
        s.space = .build
        saveSessions()
        crewChanged()
        showInBuild(s)
    }

    func showInBuild(_ s: WorkSession) {
        mode = .build
        buildSelection = s.id
    }
}
