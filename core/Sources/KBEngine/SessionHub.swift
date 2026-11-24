import Foundation
import KBCore
import Observation

/// Every Claude session the user works with: Plan sessions, Build sessions with their leads and members, the overview
/// session and the assistant. It starts and wires their Claude Code processes, saves them, carries out the crew's
/// orders (`kb crew …`) and works out each Build session's status from the tracker. The host shows them; what a
/// window keeps of a session (its input box, which one is open, offers on screen) stays the host's, reached through
/// the hooks below.
@MainActor
@Observable
public final class SessionHub {
    public static let sessionTools = ClaudeLaunch.bridgeTools + [
        "Skill", "TodoWrite", "WebFetch", "WebSearch", "Bash(git status:*)", "Bash(git diff:*)", "Bash(git branch:*)",
        "Bash(git show:*)", "Bash(ls:*)", "Bash(open:*)",
    ]

    /// Build sessions implement: subagents and notebooks on top of the session tools. Anything else (builds,
    /// tests) is the permission mode's call, and a refusal shows "Allow for This Session".
    public static let buildTools = sessionTools + ["Agent", "Task", "NotebookEdit", "Bash(grep:*)", "Bash(find:*)", "Bash(cat:*)"]

    public static let doneSinceKey = "sessionsDoneSince"
    public static let finishedAskedKey = "finishedChecksAsked"
    public static let stuckPRsReportedKey = "stuckPRsReported"

    /// Newest first; saved to the data folder.
    public var list: [WorkSession] = []
    /// The Build strategies: built in, from the plugin, and the user's own.
    public var strategies: [Strategy] = []
    /// When each Build session was first seen done; nil until it has been worked out once (see `DoneArchive`).
    public var doneSince: [String: Date]?

    // MARK: Hooks for the host

    /// Show this session: the Mac opens it in its window; default: the platform's presenter (`desktop.show`).
    @ObservationIgnored public var onShow: ((WorkSession) -> Void)?
    /// A message went out: the host clears its input box and the files it sent.
    @ObservationIgnored public var onSent: ((WorkSession, [Attachment]) -> Void)?
    /// A turn ended without an error and nothing is queued: the host may offer things (research, testing). Default:
    /// testing delivers when its plan says every checkpoint.
    @ObservationIgnored public var afterTurn: ((WorkSession) -> Void)?
    /// A session was deleted.
    @ObservationIgnored public var onDeleted: ((WorkSession) -> Void)?
    /// Runs on every crew tick, after the orders and the factories (the Mac's scans).
    @ObservationIgnored public var onTick: [() -> Void] = []
    /// A crew order `CrewOrder` doesn't parse; true when the host took it. Default: `kb test suggest`.
    @ObservationIgnored public var orderHook: ((Data) -> Bool)?
    /// `kb sync` from a session (calendar, email, tracker, PRs): the host syncs and writes the result.
    @ObservationIgnored public var onSync: ((CrewOrder.SyncRequest) -> Void)?
    /// Conversations that live elsewhere but list with the Plan sessions (the Mac's meeting chats, goal coaches, Ask).
    @ObservationIgnored public var linkedItems: (String?) -> [LinkedItem] = { _ in [] }
    /// Archives a linked conversation by id; false when the id isn't one.
    @ObservationIgnored public var archiveLinked: (String, Bool) -> Bool = { _, _ in false }
    /// The `--mcp-config` for the assistant's sessions right now; default: the last one the action endpoint gave.
    @ObservationIgnored public lazy var mcpConfig: () -> String? = { [unowned self] in lastMCPConfig }
    /// Whether the background checks (asking quiet sessions whether they're done, stuck PRs) may run yet.
    @ObservationIgnored public var backgroundChecks = true

    /// A conversation from `linkedItems`: when it changed, whether it's archived, its `sessions.list` item.
    public struct LinkedItem {
        public var updated: Date
        public var archived: Bool
        public var json: JSONValue
        public init(updated: Date, archived: Bool, json: JSONValue) {
            self.updated = updated
            self.archived = archived
            self.json = json
        }
    }

    @ObservationIgnored unowned let engine: MindmillEngine
    @ObservationIgnored public private(set) var loaded = false
    /// When each session last sent the overview session a message.
    @ObservationIgnored public var reportedToOverseer: [String: Date] = [:]
    @ObservationIgnored var crewDirty = true
    @ObservationIgnored var crewWritten = Date.distantPast
    @ObservationIgnored var crewLastState: CrewState?
    @ObservationIgnored var tickTask: Task<Void, Never>?
    @ObservationIgnored var lastMCPConfig: String?
    /// Sessions the platform's notifier was told about while they wait on the user.
    @ObservationIgnored var waitingNotified: Set<String> = []
    /// Where the sessions are saved; tests point it elsewhere.
    @ObservationIgnored public var storeURL = AppPaths.file("sessions.json")
    @ObservationIgnored public var crewDirectory: URL = CrewDir.url()

    init(engine: MindmillEngine) {
        self.engine = engine
        doneSince = (engine.platform.defaults.dictionary(forKey: Self.doneSinceKey) as? [String: Double])?
            .mapValues(Date.init(timeIntervalSince1970:))
    }

    var defaults: UserDefaults { engine.platform.defaults }

    // MARK: Loading and saving

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let fresh = SessionStore.load(from: storeURL).map(WorkSession.init(record:))
        let known = Set(list.map(\.id))
        list += fresh.filter { !known.contains($0.id) }
        for s in fresh where !known.contains(s.id) { wire(s) }
        if strategies.isEmpty { reloadStrategies() }
        groupSessionsByWork()
    }

    public func save() {
        do { try SessionStore.save(list.map(\.record), to: storeURL) } catch {
            ClaudeChat.log("sessions: save failed: \(error.localizedDescription)")
        }
    }

    public func session(_ id: String?) -> WorkSession? {
        guard let id else { return nil }
        return list.first { $0.id == id }
    }

    /// Asks the action endpoint for its MCP config once it listens, for the assistant's sessions.
    public func prepareActionEndpoint() async {
        if let c = await engine.platform.actionEndpoint?.mcpConfig() { lastMCPConfig = c }
    }

    // MARK: Starting and sending

    /// Where a session in `scope` starts: the scope's own checkout, else the first repository it works on, else the KB.
    public func directory(scope: String?) -> URL {
        let root = engine.rootURL
        guard let scope, let p = engine.index.project(scope) else { return root }
        let own = ClaudeLaunch.workingDirectory(project: p, root: root)
        if own != root || p.wide { return own }
        return ScopeRepositories.of(scope, in: engine.index).workingDirectory ?? root
    }

    /// Opens a new session. With `message`, it starts at once (for example `/kb:create-pbi <id>`).
    @discardableResult
    public func newSession(title: String? = nil, project: String? = nil, subject: AskSubject? = nil,
                           message: String? = nil, display: String? = nil, role: SessionRole = .solo, parentID: String? = nil,
                           model: String? = nil, strategy: Strategy? = nil, about: String? = nil, show: Bool = true,
                           space: SessionSpace? = nil) -> WorkSession {
        loadIfNeeded()
        var role = role, parentID = parentID
        // More work on something that already has a session goes under it.
        if role == .solo, parentID == nil, space == .build, let key = workKey(about), let main = mainSession(forWork: key) {
            promoteToLead(main)
            role = .member
            parentID = main.id
        }
        let index = engine.index
        let p = role == .overseer ? nil : (project ?? subject?.project ?? engine.scope).flatMap { index.project($0) != nil ? $0 : nil }
        let cwd = role == .overseer ? engine.rootURL : directory(scope: p)
        var aboutID = about
        if aboutID == nil, case .entry(let id, _) = subject { aboutID = id.rawValue }
        let s = WorkSession(record: SessionRecord(title: title ?? subject?.title ?? "New session", project: p,
                                                  workingDirectory: cwd.path, role: role, parentID: parentID,
                                                  model: model, about: aboutID, space: space))
        s.subject = subject
        wire(s)
        list.insert(s, at: 0)
        if show { self.show(s) }
        if let strategy {
            s.strategy = strategy.slug
            s.strategyOffered = true
            if strategy.spawns, s.role == .solo {
                s.role = .lead
                s.space = .build
            }
            let first = message ?? ""
            send(strategy.message + (first.isEmpty ? "" : "\n\n## The task\n\n" + first), in: s,
                 display: (display ?? (first.isEmpty ? nil : first)).map { "\($0)\n\nStrategy: \(strategy.title)" } ?? "Strategy: \(strategy.title)")
        } else if let message {
            send(message, in: s, display: display)
        }
        return s
    }

    public func show(_ s: WorkSession) {
        if let onShow { onShow(s) } else { try? engine.platform.presenter?.show(screen: "session", id: s.id) }
    }

    /// `attachments` go with the message as pictures (images) and paths; `listed: true` means `text` already
    /// lists them (sending a message again).
    public func send(_ text: String, in s: WorkSession, display: String? = nil, attachments files: [Attachment] = [],
                     listed: Bool = false) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty else { return }
        if s.space == .plan, s.archived == true { s.archived = nil }
        if !s.chat.isRunning, !startProcess(for: s) { return }
        var message = trimmed
        if let subject = s.subject {
            let context = subject.context.replacingOccurrences(of: "This question is about", with: "This session is about")
            message = "\(context)\n\n\(trimmed)"
            s.subject = nil
        }
        if let setup = s.pendingSetup {
            message = "\(setup)\n\n## The task\n\n\(message)"
            s.pendingSetup = nil
        }
        if let old = s.withdrawn {
            let quoted = old.count > 200 ? String(old.prefix(197)) + "…" : old
            message = "(I stopped you and took back my previous message, “\(quoted)”. Don't act on it.)\n\n\(message)"
            s.withdrawn = nil
        }
        var images: [ImageBlock] = []
        var inline: Set<String> = []
        for a in files where a.isImage && images.count < AttachmentPrompt.maxInlineImages {
            if let block = ImageBlock.make(from: a.url) {
                images.append(block)
                inline.insert(a.path)
            }
        }
        if !files.isEmpty, !listed { message = AttachmentPrompt.text(message, attachments: files, inline: inline) }
        if trimmed.isEmpty { trimmed = files.count == 1 ? files[0].name : "\(files.count) files" }
        if s.chat.items.filter({ $0.role == .user }).isEmpty, s.title == "New session" {
            let first = (display ?? trimmed).components(separatedBy: "\n")[0]
            s.title = first.count > 60 ? String(first.prefix(57)) + "…" : first
        }
        onSent?(s, files)
        s.updated = Date()
        let shown = display ?? (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !files.isEmpty ? "" : trimmed)
        s.chat.send(message, tag: UUID().uuidString, display: shown, attachments: files, images: images)
        save()
    }

    @discardableResult
    private func startProcess(for s: WorkSession) -> Bool {
        let resume = s.claudeSessionID != nil
        let sid = s.claudeSessionID ?? UUID().uuidString.lowercased()
        let root = engine.rootURL
        let title = s.project.flatMap { engine.index.project($0)?.title }
        let lead = s.parentID.flatMap { id in list.first { $0.id == id } }
        let prompt = s.role == .overseer
            ? ClaudeModes.overseer(kbRoot: root.path)
            : ClaudeModes.session(project: s.project, projectTitle: title, kbRoot: root.path) + "\n"
                + ClaudeModes.crew(role: s.role, sessionID: s.id, leadTitle: lead?.title, leadID: lead?.id, project: s.project)
                + (s.space == .build ? engine.testingNote(s.project) : "")
                + (s.isAssistant ? "\n" + ClaudeModes.assistant : "")
        let tools = (s.role == .overseer ? Self.sessionTools : Self.buildTools) + s.extraTools
            + (s.isAssistant ? MCPActions.allowedTools : [])
        let model = s.model.flatMap { $0.isEmpty ? nil : $0 } ?? engine.model(for: .work)
        guard var launch = engine.launch(prompt: prompt, sessionID: sid, resume: resume, model: model, cwd: s.workingDirectory,
                                         tools: tools) else {
            engine.report(engine.claudeMissingExplanation, error: true)
            return false
        }
        launch.disallowedTools = ["AskUserQuestion"]
        if s.isAssistant { launch.mcpConfig = mcpConfig() }
        if s.role != .overseer, let scope = s.project, engine.index.project(scope) != nil {
            launch.environment["KB_SCOPE"] = scope
            let start = s.workingDirectory.standardizedFileURL
            launch.additionalDirectories = ScopeRepositories.of(scope, in: engine.index).all.compactMap(\.checkout)
                .filter { start != $0.standardizedFileURL && !start.path.hasPrefix($0.standardizedFileURL.path + "/") }
        }
        launch.environment["KB_SESSION_ID"] = s.id
        launch.environment["KB_CREW_DIR"] = crewDirectory.path
        do { try s.chat.start(launch, mode: "session") } catch {
            engine.report("Could not start claude: \(error.localizedDescription)", error: true)
            return false
        }
        s.claudeSessionID = sid
        s.chat.send(ClaudeModes.warmup, tag: "connect", show: false)
        return true
    }

    func wire(_ s: WorkSession) {
        s.chat.onEvent = { [weak self, weak s] event in
            guard let self, let s else { return }
            self.remoteChanged(s)
            switch event {
            case .sessionStarted(let id):
                s.claudeSessionID = id
            case .turnResult(_, let isError, let tag):
                s.updated = Date()
                s.stateSince = Date()
                self.save()
                self.crewChanged()
                if !s.inbox.isEmpty, !s.chat.isBusy {
                    let next = s.inbox.removeFirst()
                    self.send(next.text, in: s, display: next.display)
                } else if s.stopAfterTurn, !s.chat.isBusy {
                    s.stopAfterTurn = false
                    s.chat.stop()
                } else if !isError, !s.chat.isBusy {
                    self.askForOptions(in: s, turnTag: tag)
                    if let afterTurn = self.afterTurn { afterTurn(s) } else { self.engine.tests.afterTurn(s) }
                }
            case .turnStarted:
                s.stateSince = Date()
                self.crewChanged()
            case .exited:
                self.crewChanged()
            default:
                break
            }
        }
    }

    /// A reply that ends with a bare question doesn't count as waiting on the user; the session is asked once to put
    /// the question as options when it is for the user.
    private func askForOptions(in s: WorkSession, turnTag: String?) {
        guard let last = s.chat.items.last(where: { $0.role == .assistant || $0.role == .user }), last.role == .assistant,
              OpenQuestion.shouldAsk(reply: last.text, turnTag: turnTag, alreadyAsked: s.openQuestionAsked == last.id),
              let question = OpenQuestion.of(last.text) else { return }
        s.openQuestionAsked = last.id
        s.chat.note(OpenQuestion.status)
        s.chat.send(OpenQuestion.request(question), tag: "\(OpenQuestion.tagPrefix)-\(UUID().uuidString)", show: false,
                    hideReply: false)
    }

    /// Tells the phones and desktop shells a session changed, so they fetch what's new with `session.get` and `since`.
    func remoteChanged(_ s: WorkSession) {
        let remote = engine.remote
        if remote.isRunning { remote.sessionStateChanged(id: s.id, title: s.title, state: s.crewState.rawValue) }
        if !remote.connected.isEmpty || !remote.desktops.isEmpty {
            remote.broadcast("session.changed", ["id": .string(s.id), "count": .number(Double(s.chat.items.count)),
                                                 "busy": .bool(s.chat.isBusy), "state": .string(s.crewState.rawValue)])
        }
        if !remote.desktops.isEmpty { engine.needsYouChanged() }
        let state = s.crewState
        if state.needsUser, !waitingNotified.contains(s.id) {
            waitingNotified.insert(s.id)
            engine.platform.notifier?.notify(title: s.title, body: state == .blocked ? "It needs your permission to go on." : "It's waiting for your answer.",
                                             action: "session:\(s.id)")
        } else if !state.needsUser {
            waitingNotified.remove(s.id)
        }
    }

    /// Takes back a message: Claude stops if it had started on it. Returns the text and files to put back in the
    /// input box.
    public func cancelMessage(_ item: ClaudeChat.Item, in s: WorkSession) -> (text: String, attachments: [Attachment])? {
        guard let taken = s.chat.cancel(item) else { return nil }
        if taken.reachedClaude { s.withdrawn = taken.text }
        save()
        return (taken.text, item.attachments)
    }

    /// Sends the message whose turn failed again, exactly as it went the first time.
    public func retryLast(in s: WorkSession) {
        guard let last = s.chat.takeRetry() else { return }
        send(last.text, in: s, display: last.display, attachments: last.attachments, listed: true)
    }

    /// Allows what Claude was refused in the last turn, for this session, and asks it to try again.
    public func allowDenied(in s: WorkSession) {
        let patterns = s.chat.denials.map(Self.allowPattern)
        guard !patterns.isEmpty else { return }
        s.extraTools = Array(Set(s.extraTools + patterns)).sorted()
        s.chat.stop()
        send("I allowed \(patterns.joined(separator: ", ")) for this session. Try again.", in: s)
    }

    /// `Bash(npm run build)` → `Bash(npm:*)`; any other tool → the tool itself.
    public static func allowPattern(_ denial: String) -> String {
        guard let open = denial.firstIndex(of: "(") else { return denial }
        let name = String(denial[..<open])
        guard name == "Bash" else { return name }
        let inner = denial[denial.index(after: open)...].dropLast()
        let first = inner.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Bash" : "Bash(\(first):*)"
    }

    public func stop(_ s: WorkSession) {
        s.chat.stop()
        s.inbox = []
        s.chat.items.append(.init(role: .status, text: "Stopped. Send a message to continue where it left off."))
        crewChanged()
    }

    /// Starts Claude again on the same conversation, so tools that dropped out (a claude.ai connector such as Claude
    /// Docs or Microsoft 365) connect again, and tells it so it can carry on.
    public func reconnect(_ s: WorkSession) {
        guard !s.chat.isBusy else { return }
        s.chat.stop()
        send("I restarted you so your tools connect again, the claude.ai connectors included. Check that the ones you were missing are there now (load them with ToolSearch), then carry on with what you were waiting for.",
             in: s, display: "Reconnect tools")
    }

    public func delete(_ s: WorkSession) {
        s.chat.stop()
        for m in list where m.parentID == s.id {
            m.parentID = nil
            m.role = .solo
        }
        list.removeAll { $0.id == s.id }
        onDeleted?(s)
        save()
        crewChanged()
    }

    // MARK: The assistant

    /// The most recent assistant session (in `scope` when given), or a new one when there is none or `new` is set.
    public func assistant(scope: String? = nil, new: Bool = false) async -> (session: WorkSession, created: Bool) {
        loadIfNeeded()
        await prepareActionEndpoint()
        let wanted = scope.flatMap { engine.index.project($0) != nil ? $0 : nil }
        if !new, let r = SessionRecord.latestAssistant(list.map(\.record), scope: wanted), let s = session(r.id) {
            return (s, false)
        }
        let s = newSession(title: "Assistant", project: wanted ?? engine.scope, about: SessionRecord.assistantAbout, show: false,
                           space: .plan)
        return (s, true)
    }

    // MARK: Lists

    public var overseer: WorkSession? { list.first { $0.role == .overseer } }
    /// Build mode's sessions.
    public var buildSessions: [WorkSession] { list.filter { $0.space == .build } }
    public var planSessions: [WorkSession] {
        list.filter { $0.space == .plan && $0.role != .overseer }.sorted { $0.updated > $1.updated }
    }
    public var buildSessionsNeedingUser: [WorkSession] {
        buildSessions.filter { $0.role != .overseer && $0.crewState.needsUser }
    }
    public var leads: [WorkSession] { buildSessions.filter { $0.role == .lead && !isArchived($0) }.sorted { $0.created < $1.created } }

    /// Build's list: leads and single sessions together, newest first; members sit under their lead.
    public var topLevelBuildSessions: [WorkSession] {
        let leadIDs = Set(leads.map(\.id))
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        return buildSessions.filter { s in
            !isArchived(s) && (s.role == .lead || ((s.role == .solo || (s.role == .member && !leadIDs.contains(s.parentID ?? "")))
                                && (s.chat.isRunning || s.updated > cutoff)))
        }.sorted { $0.created > $1.created }
    }

    public func members(of lead: WorkSession) -> [WorkSession] {
        list.filter { $0.role == .member && $0.parentID == lead.id }.sorted { $0.created < $1.created }
    }

    /// Sessions in no crew: recent ones, and any that are running.
    public var otherSessions: [WorkSession] {
        let leadIDs = Set(leads.map(\.id))
        let cutoff = Date().addingTimeInterval(-3 * 86_400)
        return buildSessions.filter { s in
            !isArchived(s) && (s.role == .solo || (s.role == .member && !leadIDs.contains(s.parentID ?? "")))
                && (s.chat.isRunning || s.updated > cutoff)
        }.sorted { $0.updated > $1.updated }
    }

    /// Sessions working on a KB entry, for Plan mode's "in Build" marks.
    public func sessions(about id: EntryID) -> [WorkSession] {
        buildSessions.filter { $0.about == id.rawValue && $0.role != .overseer }
    }

    public func sessions(forKey key: String) -> [WorkSession] {
        buildSessions.filter { $0.about == key }.sorted { $0.updated > $1.updated }
    }

    /// The Plan session that created this work item, for "Planned in" on its Build session.
    public func planSession(creating item: Int) -> WorkSession? {
        planSessions.first { $0.createdItems.contains(item) }
    }
}
