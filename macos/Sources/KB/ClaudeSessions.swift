import AppKit
import KBCore
import KBEngine
import Observation
import SwiftUI

/// What the Mac's windows keep of a session, apart from the session itself (`WorkSession`, in the engine): the text
/// being typed, files waiting to go with it, and the offers shown under a Build session.
@MainActor
@Observable
final class SessionUIState {
    var input = ""
    /// Files and images waiting in the input box, sent with the next message.
    var pendingAttachments: [Attachment] = []
    /// The research question shows under this Build session until the user answers it or writes again.
    var researchAskShown = false
    /// "Set up testing?" shows under this Build session until answered.
    var testAskShown = false
}

@MainActor
enum SessionUI {
    private static var states: [String: SessionUIState] = [:]

    static func of(_ id: String) -> SessionUIState {
        if let s = states[id] { return s }
        let s = SessionUIState()
        states[id] = s
        return s
    }

    static func forget(_ id: String) { states[id] = nil }
}

extension WorkSession {
    var ui: SessionUIState { SessionUI.of(id) }

    var input: String {
        get { ui.input }
        set { ui.input = newValue }
    }

    var pendingAttachments: [Attachment] {
        get { ui.pendingAttachments }
        set { ui.pendingAttachments = newValue }
    }

    var researchAskShown: Bool {
        get { ui.researchAskShown }
        set { ui.researchAskShown = newValue }
    }

    var testAskShown: Bool {
        get { ui.testAskShown }
        set { ui.testAskShown = newValue }
    }
}

extension AppModel {
    static let sessionTools = SessionHub.sessionTools
    static let buildTools = SessionHub.buildTools

    /// The engine runs the sessions; the app shows them and keeps what its windows hold of each.
    func wireSessions() {
        let hub = engine.sessions
        hub.onShow = { [weak self] s in self?.showSession(s) }
        hub.onSent = { s, files in
            s.input = ""
            s.researchAskShown = false
            if !files.isEmpty { s.pendingAttachments.removeAll { files.contains($0) } }
        }
        hub.afterTurn = { [weak self] s in
            guard let self else { return }
            offerResearch(s)
            offerTesting(s)
            testingAfterTurn(s)
        }
        hub.onDeleted = { [weak self] s in
            guard let self else { return }
            removeAttachmentFolder(for: s)
            SessionUI.forget(s.id)
            if selectedSessionID == s.id { selectedSessionID = sessions.first(where: { $0.role != .overseer })?.id }
            if buildSelection == s.id { buildSelection = nil }
        }
        hub.mcpConfig = { [weak self] in self?.actionServer.mcpConfig }
        engine.scans.onStarted = { [weak self] id in self?.projectPane = .run(id) }
        engine.scans.onDeleted = { [weak self] id in
            if self?.projectPane == .run(id) { self?.projectPane = .home }
        }
        hub.linkedItems = { [weak self] scope in self?.linkedSessionItems(scope: scope) ?? [] }
        hub.archiveLinked = { [weak self] id, on in
            guard let self else { return false }
            loadMeetingChatsIfNeeded()
            guard let item = planItem(id), case .linked = item else { return false }
            setArchived(item, on)
            return true
        }
        hub.backgroundChecks = backgroundStarted
        engine.factories.onDeleted = { [weak self] id in
            guard let self, selectedFactoryID == id else { return }
            buildSelection = factories.first.map { Self.factoryTag + $0.id }
        }
        engine.tracker.editLocal = { [weak self] scope, change in self?.editLocalTracker(scope, change) }
        engine.sprints.onLocalTrackerChanged = { [weak self] scopes in
            guard let self else { return }
            for s in scopes { localTrackers[s] = nil; loadLocalTracker(s) }
        }
        engine.tracker.willRefreshBacklog = { [weak self] in self?.startTrackerTimer() }
        engine.tracker.willRefreshPullRequests = { [weak self] in self?.startPullRequestTimer() }
        engine.tracker.onPullRequests = { [weak self] before in
            guard let self, PRAutoCleanup.isOn, !before.subtracting(pullRequests?.prs.map(\.id) ?? []).isEmpty else { return }
            refreshDonePRs(force: true)
        }
        engine.tests.platform = testPlatform
        engine.tests.onAskToSetUp = { $0.testAskShown = true }
        wireRoutines()
        engine.currentMode = { [weak self] in self?.mode.rawValue ?? "plan" }
        engine.onReport = { [weak self] text, error in
            if error { self?.errorMessage = text } else { self?.notice = text }
        }
    }

    /// Where a new or moved session shows: Build's detail, or the Plan session in the Claude window.
    private func showSession(_ s: WorkSession) {
        if s.space == .build {
            mode = .build
            buildSelection = s.id
        } else {
            selectedSessionID = s.id
            if !(mode == .plan && sidebarSelection == .sessions) { openWindowAction?("claude", nil) }
        }
    }

    var sessions: [WorkSession] { engine.sessions.list }

    func loadSessionsIfNeeded() { engine.sessions.loadIfNeeded() }

    func saveSessions() { engine.sessions.save() }

    var selectedSession: WorkSession? { sessions.first { $0.id == selectedSessionID } }

    func openSessions() {
        loadSessionsIfNeeded()
        openWindowAction?("claude", nil)
    }

    /// Where a session in `scope` starts: the scope's own checkout, else the first repository it works on, else the KB.
    func sessionDirectory(scope: String?) -> URL { engine.sessions.directory(scope: scope) }

    /// Opens a new session. With `message`, it starts at once (for example `/mindmill:create-pbi <id>`).
    @discardableResult
    func newSession(title: String? = nil, project: String? = nil, subject: AskSubject? = nil,
                    message: String? = nil, display: String? = nil, role: SessionRole = .solo, parentID: String? = nil,
                    model: String? = nil, strategy: Strategy? = nil, about: String? = nil, show: Bool = true,
                    space: SessionSpace? = nil) -> WorkSession {
        engine.sessions.newSession(title: title, project: project, subject: subject, message: message, display: display,
                                   role: role, parentID: parentID, model: model, strategy: strategy, about: about, show: show,
                                   space: space)
    }

    func workWithClaude(_ subject: AskSubject) {
        newSession(subject: subject)
    }

    /// Runs the create-PBI skill on a KB entry, usually a follow-up.
    func createWorkItem(from id: EntryID) {
        let title = index.entry(id)?.title ?? id.stem
        newSession(title: "PBI: \(title)", project: id.project, message: "/mindmill:create-pbi \(id.rawValue)",
                   display: "Create a PBI from “\(title)”")
    }

    func send(_ text: String, in s: WorkSession, display: String? = nil, attachments files: [Attachment] = [],
              listed: Bool = false) {
        engine.sessions.send(text, in: s, display: display, attachments: files, listed: listed)
    }

    /// Takes back a message: it goes back into the input box to change, and Claude stops if it had started on it.
    func cancelMessage(_ item: ClaudeChat.Item, in s: WorkSession) {
        guard let taken = engine.sessions.cancelMessage(item, in: s) else { return }
        s.pendingAttachments = taken.attachments + s.pendingAttachments.filter { !taken.attachments.contains($0) }
        let current = s.input.trimmingCharacters(in: .whitespacesAndNewlines)
        s.input = current.isEmpty ? taken.text : "\(taken.text)\n\n\(current)"
    }

    func retryLast(in s: WorkSession) { engine.sessions.retryLast(in: s) }

    func allowDenied(in s: WorkSession) { engine.sessions.allowDenied(in: s) }

    static func allowPattern(_ denial: String) -> String { SessionHub.allowPattern(denial) }

    func stopSession(_ s: WorkSession) { engine.sessions.stop(s) }

    func reconnectSession(_ s: WorkSession) { engine.sessions.reconnect(s) }

    func deleteSession(_ s: WorkSession) { engine.sessions.delete(s) }

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
            names.append("mindmill:\(dir)")
        }
        for base in [s.workingDirectory.appendingPathComponent(".claude/skills"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")] {
            names += (try? FileManager.default.contentsOfDirectory(atPath: base.path))?.filter { !$0.hasPrefix(".") } ?? []
        }
        return Array(Set(names)).sorted()
    }
}
