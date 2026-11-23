import AppKit
import KBCore
import Observation
import SwiftUI

/// One Claude session window conversation: a task the user works on with Claude, often a skill.
@MainActor
@Observable
final class WorkSession: Identifiable {
    let id: String
    var title: String
    let project: String?
    let workingDirectory: URL
    var claudeSessionID: String?
    var extraTools: [String]
    let created: Date
    var updated: Date
    let chat = ClaudeChat()
    var input = ""
    /// Files and images waiting in the input box, sent with the next message.
    var pendingAttachments: [Attachment] = []
    /// Context from "Work on it with Claude", sent with the first message and shown as a chip until then.
    var subject: AskSubject?
    var role: SessionRole
    var parentID: String?
    var strategy: String?
    var model: String?
    var about: String?
    var strategyOffered: Bool
    var space: SessionSpace
    var archived: Bool?
    var researchOffered: Bool
    /// The research question shows under this Build session until the user answers it or writes again.
    var researchAskShown = false
    /// "Set up testing?" shows under this Build session until answered.
    var testAskShown = false
    /// Messages from other sessions that arrived during a turn; each is sent when the turn ends.
    var inbox: [(text: String, display: String)] = []
    /// How to work (a strategy, sessions to start), sent in front of the first message.
    var pendingSetup: String?
    /// A message the user took back after Claude had read it; the next message says so.
    var withdrawn: String?
    /// When the current state began, for "working 3m" in the overview.
    var stateSince = Date()
    @ObservationIgnored var createdItemsCache: (count: Int, ids: [Int]) = (-1, [])
    /// Archived during its turn: the process stops once the turn ends.
    var stopAfterTurn = false
    /// The reply that ended with a bare question the app already asked the session to put as options.
    @ObservationIgnored var openQuestionAsked: UUID?

    init(record: SessionRecord) {
        id = record.id
        title = record.title
        project = record.project
        workingDirectory = URL(fileURLWithPath: record.workingDirectory)
        claudeSessionID = record.claudeSessionID
        extraTools = record.extraTools
        created = record.created
        updated = record.updated
        role = record.role
        parentID = record.parentID
        strategy = record.strategy
        model = record.model
        about = record.about
        strategyOffered = record.strategyOffered
        space = record.space
        archived = record.archived
        researchOffered = record.researchOffered ?? false
        chat.showsTools = true
        chat.items = record.messages.map {
            ClaudeChat.Item(role: ClaudeChat.Role(rawValue: $0.role) ?? .status, text: $0.text, attachments: $0.attachments ?? [])
        }
    }

    var record: SessionRecord {
        SessionRecord(id: id, title: title, project: project, claudeSessionID: claudeSessionID,
                      workingDirectory: workingDirectory.path, created: created, updated: updated, extraTools: extraTools,
                      messages: chat.items.filter { $0.role != .status }.map { .init(role: $0.role.rawValue, text: $0.text, attachments: $0.attachments.isEmpty ? nil : $0.attachments) },
                      role: role, parentID: parentID, strategy: strategy, model: model, about: about,
                      strategyOffered: strategyOffered, space: space, archived: archived,
                      researchOffered: researchOffered ? true : nil)
    }

    /// The last assistant message, when the conversation is waiting on the user.
    var waitingChoices: (itemID: UUID, multi: Bool, options: [String])? {
        guard !chat.isBusy, let last = chat.items.last(where: { $0.role != .tool && $0.role != .status }),
              last.role == .assistant, let c = MarkdownBlocks.trailingChoices(last.text) else { return nil }
        return (last.id, c.multi, c.options)
    }

    /// What the overview shows: working, waiting on the user, refused a tool, idle or not running.
    var crewState: CrewSessionState {
        if chat.isBusy { return .working }
        if !chat.denials.isEmpty { return .blocked }
        if let last = chat.items.last(where: { $0.role == .assistant || $0.role == .user }), last.role == .assistant {
            if OpenQuestion.waitsOnUser(last.text) { return .waiting }
        }
        return chat.isRunning ? .idle : .stopped
    }

    /// The start of the last reply, one line.
    var lastReply: String {
        guard let last = chat.items.last(where: { $0.role == .assistant }) else { return "" }
        let blocks = MarkdownBlocks.parse(last.text)
        for b in blocks.reversed() {
            switch b {
            case .paragraph(let t), .heading(_, let t), .quote(let t): return Self.plain(t)
            case .listItem(_, _, _, let t): return Self.plain(t)
            default: continue
            }
        }
        return Self.plain(last.text)
    }

    private static func plain(_ t: String) -> String {
        t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    var isLead: Bool { role == .lead }
}

extension AppModel {
    static let sessionTools = ClaudeLaunch.bridgeTools + [
        "Skill", "TodoWrite", "WebFetch", "WebSearch", "Bash(git status:*)", "Bash(git diff:*)", "Bash(git branch:*)",
        "Bash(git show:*)", "Bash(ls:*)", "Bash(open:*)",
    ]

    /// Build sessions implement: subagents and notebooks on top of the session tools. Anything else (builds,
    /// tests) is the permission mode's call, and a refusal shows "Allow for This Session".
    static let buildTools = sessionTools + ["Agent", "Task", "NotebookEdit", "Bash(grep:*)", "Bash(find:*)", "Bash(cat:*)"]

    private var sessionsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KB/sessions.json")
    }

    func loadSessionsIfNeeded() {
        guard !sessionsLoaded else { return }
        sessionsLoaded = true
        let loaded = SessionStore.load(from: sessionsURL).map(WorkSession.init(record:))
        let known = Set(sessions.map(\.id))
        sessions += loaded.filter { !known.contains($0.id) }
        for s in loaded where !known.contains(s.id) { wire(s) }
        groupSessionsByWork()
    }

    func saveSessions() {
        do { try SessionStore.save(sessions.map(\.record), to: sessionsURL) } catch {
            ClaudeChat.log("sessions: save failed: \(error.localizedDescription)")
        }
    }

    var selectedSession: WorkSession? { sessions.first { $0.id == selectedSessionID } }

    func openSessions() {
        loadSessionsIfNeeded()
        openWindowAction?("claude", nil)
    }

    /// Where a session in `scope` starts: the scope's own checkout, else the first repository it works on, else the KB.
    func sessionDirectory(scope: String?) -> URL {
        guard let scope, let p = index.project(scope) else { return rootURL }
        let own = ClaudeLaunch.workingDirectory(project: p, root: rootURL)
        if own != rootURL || p.wide { return own }
        return repositories(of: scope).workingDirectory ?? rootURL
    }

    /// Opens a new session. With `message`, it starts at once (for example `/kb:create-pbi <id>`).
    @discardableResult
    func newSession(title: String? = nil, project: String? = nil, subject: AskSubject? = nil,
                    message: String? = nil, display: String? = nil, role: SessionRole = .solo, parentID: String? = nil,
                    model: String? = nil, strategy: Strategy? = nil, about: String? = nil, show: Bool = true,
                    space: SessionSpace? = nil) -> WorkSession {
        loadSessionsIfNeeded()
        var role = role, parentID = parentID
        // More work on something that already has a session goes under it.
        if role == .solo, parentID == nil, space == .build, let key = workKey(about), let main = mainSession(forWork: key) {
            promoteToLead(main)
            role = .member
            parentID = main.id
        }
        let p = role == .overseer ? nil : (project ?? subject?.project ?? projectID).flatMap { index.project($0) != nil ? $0 : nil }
        let cwd = role == .overseer ? rootURL : sessionDirectory(scope: p)
        var aboutID = about
        if aboutID == nil, case .entry(let id, _) = subject { aboutID = id.rawValue }
        let s = WorkSession(record: SessionRecord(title: title ?? subject?.title ?? "New session", project: p,
                                                  workingDirectory: cwd.path, role: role, parentID: parentID,
                                                  model: model, about: aboutID, space: space))
        s.subject = subject
        wire(s)
        sessions.insert(s, at: 0)
        if show {
            if s.space == .build {
                mode = .build
                buildSelection = s.id
            } else {
                selectedSessionID = s.id
                if !(mode == .plan && sidebarSelection == .sessions) { openWindowAction?("claude", nil) }
            }
        }
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

    func workWithClaude(_ subject: AskSubject) {
        newSession(subject: subject)
    }

    /// Runs the create-PBI skill on a KB entry, usually a follow-up.
    func createWorkItem(from id: EntryID) {
        let title = index.entry(id)?.title ?? id.stem
        newSession(title: "PBI: \(title)", project: id.project, message: "/kb:create-pbi \(id.rawValue)",
                   display: "Create a PBI from “\(title)”")
    }

    /// `attachments` go with the message as pictures (images) and paths; `listed: true` means `text` already
    /// lists them (sending a message again).
    func send(_ text: String, in s: WorkSession, display: String? = nil, attachments files: [Attachment] = [],
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
        s.input = ""
        s.researchAskShown = false
        if !files.isEmpty { s.pendingAttachments.removeAll { files.contains($0) } }
        s.updated = Date()
        let shown = display ?? (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !files.isEmpty ? "" : trimmed)
        s.chat.send(message, tag: UUID().uuidString, display: shown, attachments: files, images: images)
        saveSessions()
    }

    @discardableResult
    private func startProcess(for s: WorkSession) -> Bool {
        let resume = s.claudeSessionID != nil
        let sid = s.claudeSessionID ?? UUID().uuidString.lowercased()
        let title = s.project.flatMap { index.project($0)?.title }
        let lead = s.parentID.flatMap { id in sessions.first { $0.id == id } }
        let prompt = s.role == .overseer
            ? ClaudeModes.overseer(kbRoot: rootURL.path)
            : ClaudeModes.session(project: s.project, projectTitle: title, kbRoot: rootURL.path) + "\n"
                + ClaudeModes.crew(role: s.role, sessionID: s.id, leadTitle: lead?.title, leadID: lead?.id, project: s.project)
                + (s.space == .build ? testingNote(s.project) : "")
                + (s.isAssistant ? "\n" + ClaudeModes.assistant : "")
        let tools = (s.role == .overseer ? Self.sessionTools : Self.buildTools) + s.extraTools
            + (s.isAssistant ? MCPActions.allowedTools : [])
        let model = s.model.flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        guard var launch = launch(prompt: prompt, sessionID: sid, resume: resume, model: model, cwd: s.workingDirectory,
                                  tools: tools) else {
            errorMessage = claudeMissingExplanation
            return false
        }
        launch.disallowedTools = ["AskUserQuestion"]
        if s.isAssistant { launch.mcpConfig = actionServer.mcpConfig }
        if s.role != .overseer, let scope = s.project, index.project(scope) != nil {
            launch.environment["KB_SCOPE"] = scope
            let start = s.workingDirectory.standardizedFileURL
            launch.additionalDirectories = repositories(of: scope).all.compactMap(\.checkout)
                .filter { start != $0.standardizedFileURL && !start.path.hasPrefix($0.standardizedFileURL.path + "/") }
        }
        launch.environment["KB_SESSION_ID"] = s.id
        launch.environment["KB_CREW_DIR"] = crewDirectory.path
        do { try s.chat.start(launch, mode: "session") } catch {
            errorMessage = "Could not start claude: \(error.localizedDescription)"
            return false
        }
        s.claudeSessionID = sid
        s.chat.send(ClaudeModes.warmup, tag: "connect", show: false)
        return true
    }

    private func wire(_ s: WorkSession) {
        s.chat.onEvent = { [weak self, weak s] event in
            guard let self, let s else { return }
            self.remoteSessionChanged(s)
            switch event {
            case .sessionStarted(let id):
                s.claudeSessionID = id
            case .turnResult(_, let isError, let tag):
                s.updated = Date()
                s.stateSince = Date()
                self.saveSessions()
                self.crewChanged()
                if !s.inbox.isEmpty, !s.chat.isBusy {
                    let next = s.inbox.removeFirst()
                    self.send(next.text, in: s, display: next.display)
                } else if s.stopAfterTurn, !s.chat.isBusy {
                    s.stopAfterTurn = false
                    s.chat.stop()
                } else if !isError, !s.chat.isBusy {
                    self.askForOptions(in: s, turnTag: tag)
                    self.offerResearch(s)
                    self.offerTesting(s)
                    self.testingAfterTurn(s)
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

    /// Takes back a message: it goes back into the input box to change, and Claude stops if it had started on it.
    func cancelMessage(_ item: ClaudeChat.Item, in s: WorkSession) {
        guard let taken = s.chat.cancel(item) else { return }
        if taken.reachedClaude { s.withdrawn = taken.text }
        s.pendingAttachments = item.attachments + s.pendingAttachments.filter { !item.attachments.contains($0) }
        let current = s.input.trimmingCharacters(in: .whitespacesAndNewlines)
        s.input = current.isEmpty ? taken.text : "\(taken.text)\n\n\(current)"
        saveSessions()
    }

    /// Sends the message whose turn failed again, exactly as it went the first time.
    func retryLast(in s: WorkSession) {
        guard let last = s.chat.takeRetry() else { return }
        send(last.text, in: s, display: last.display, attachments: last.attachments, listed: true)
    }

    /// Allows what Claude was refused in the last turn, for this session, and asks it to try again.
    func allowDenied(in s: WorkSession) {
        let patterns = s.chat.denials.map(Self.allowPattern)
        guard !patterns.isEmpty else { return }
        s.extraTools = Array(Set(s.extraTools + patterns)).sorted()
        s.chat.stop()
        send("I allowed \(patterns.joined(separator: ", ")) for this session. Try again.", in: s)
    }

    /// `Bash(npm run build)` → `Bash(npm:*)`; any other tool → the tool itself.
    static func allowPattern(_ denial: String) -> String {
        guard let open = denial.firstIndex(of: "(") else { return denial }
        let name = String(denial[..<open])
        guard name == "Bash" else { return name }
        let inner = denial[denial.index(after: open)...].dropLast()
        let first = inner.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Bash" : "Bash(\(first):*)"
    }

    func stopSession(_ s: WorkSession) {
        s.chat.stop()
        s.inbox = []
        s.chat.items.append(.init(role: .status, text: "Stopped. Send a message to continue where it left off."))
        crewChanged()
    }

    /// Starts Claude again on the same conversation, so tools that dropped out (a claude.ai connector such as Claude
    /// Docs or Microsoft 365) connect again, and tells it so it can carry on.
    func reconnectSession(_ s: WorkSession) {
        guard !s.chat.isBusy else { return }
        s.chat.stop()
        send("I restarted you so your tools connect again, the claude.ai connectors included. Check that the ones you were missing are there now (load them with ToolSearch), then carry on with what you were waiting for.",
             in: s, display: "Reconnect tools")
    }

    func deleteSession(_ s: WorkSession) {
        s.chat.stop()
        for m in sessions where m.parentID == s.id {
            m.parentID = nil
            m.role = .solo
        }
        sessions.removeAll { $0.id == s.id }
        removeAttachmentFolder(for: s)
        if selectedSessionID == s.id { selectedSessionID = sessions.first(where: { $0.role != .overseer })?.id }
        if buildSelection == s.id { buildSelection = nil }
        saveSessions()
        crewChanged()
    }

    /// Continues the session in Terminal with `claude --resume`.
    func openSessionInTerminal(_ s: WorkSession) {
        guard case .found(let exe) = claudeAvailability, let sid = s.claudeSessionID else {
            errorMessage = s.claudeSessionID == nil ? "Send a message first; there is no \(Brain.name) session yet." : claudeMissingExplanation
            return
        }
        s.chat.stop()
        func quote(_ v: String) -> String { "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/zsh -il
        cd \(quote(s.workingDirectory.path))
        export KB_ROOT=\(quote(rootURL.path))
        clear
        \(quote(exe.path)) --resume \(sid) --plugin-dir \(quote(KBConfig.expandTilde(pluginRootPath)))
        """
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KB")
        let url = dir.appendingPathComponent("session-\(s.id.prefix(8)).command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            errorMessage = "Could not write \(url.path): \(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Skills to suggest after `/` before the session has reported its own list.
    func fallbackCommands(for s: WorkSession) -> [String] {
        var names: [String] = []
        let plugin = URL(fileURLWithPath: KBConfig.expandTilde(pluginRootPath)).appendingPathComponent("skills")
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: plugin.path)) ?? [] {
            names.append("kb:\(dir)")
        }
        for base in [s.workingDirectory.appendingPathComponent(".claude/skills"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")] {
            names += (try? FileManager.default.contentsOfDirectory(atPath: base.path))?.filter { !$0.hasPrefix(".") } ?? []
        }
        return Array(Set(names)).sorted()
    }
}

extension WorkSession {
    func matches(_ query: String) -> Bool {
        KBSearch.matches(query, in: [title, about ?? "", project ?? "", strategy ?? "", subject?.title ?? ""]
            .joined(separator: "\n").lowercased())
    }
}
