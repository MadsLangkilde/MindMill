import Foundation
import KBCore
import Observation

/// A `ClaudeSession` as SwiftUI state: the visible transcript, whether a turn is running, and the last tool used.
@MainActor
@Observable
final class ClaudeChat {
    enum Role: String { case user, assistant, error, status, tool }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        var text: String
        var tag: String?
        /// Files and images sent with a user message, shown with it.
        var attachments: [Attachment] = []
    }

    var items: [Item] = []
    /// Messages sent and not yet answered, including the one running.
    private(set) var pending = 0
    private(set) var activity: String?
    private(set) var sessionID: String?
    private(set) var isRunning = false
    private(set) var mode: String?
    var lastError: String?
    /// Slash commands the session knows, from its init line.
    private(set) var commands: [String] = []
    /// Tool calls refused in the last turn, as `Tool(detail)`.
    private(set) var denials: [String] = []
    /// Session windows show each tool call as a `.tool` item; other chats only show the activity.
    @ObservationIgnored var showsTools = false

    /// Every session's MCP connector statuses, so the app can say when Microsoft 365 needs signing in.
    @ObservationIgnored static var onConnectors: (([String: String]) -> Void)?
    /// A chat whose Claude failed to sign in, with the error. The app asks the user to sign in again.
    @ObservationIgnored static var onSignInProblem: ((ClaudeChat, String) -> Void)?
    /// A chat that says the Azure CLI sign-in the Azure DevOps tools use has expired, with what it said.
    @ObservationIgnored static var onAzureSignInProblem: ((ClaudeChat, String) -> Void)?
    /// Claude said the Azure CLI sign-in has expired; the session offers to sign in from KB until it's done or dismissed.
    var needsAzureSignIn = false
    /// Turns left to end before a reply mentioning az login counts again, once the Azure sign-in works.
    @ObservationIgnored private var azureGraceTurns = 0
    /// The last turn failed because Claude isn't signed in; cleared once the user signs in again.
    private(set) var needsSignIn = false
    /// The last message the transcript showed, as sent and as shown, until its turn succeeds: what to send
    /// again after signing in.
    private(set) var lastShown: (text: String, display: String, tag: String?, attachments: [Attachment])?
    private var retry = RetryOffer()
    /// The error line that offers to send the failed message again.
    var retryItemID: UUID? { lastShown == nil ? nil : retry.errorItem }
    /// Tags of shown messages whose turn hasn't ended: they can still be cancelled.
    private(set) var pendingTags: Set<String> = []
    @ObservationIgnored private var cancelledTags: Set<String> = []

    /// Called for every event, after the transcript is updated.
    @ObservationIgnored var onEvent: ((ClaudeEvent) -> Void)?
    @ObservationIgnored private var session: ClaudeSession?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var turnHadText = false
    @ObservationIgnored private var hiddenTags: Set<String> = []

    var isBusy: Bool { pending > 0 }

    func start(_ launch: ClaudeLaunch, mode: String) throws {
        stop()
        let s = ClaudeSession(process: ClaudeSubprocess(launch))
        session = s
        self.mode = mode
        sessionID = nil
        pending = 0
        activity = nil
        lastError = nil
        listener = Task { [weak self] in
            for await event in s.events {
                guard let self else { return }
                self.handle(event, from: s)
            }
        }
        Self.log("[\(mode)] start: \(([launch.executable.path] + launch.arguments.map { $0.count > 80 ? String($0.prefix(80)) + "…" : $0 }).joined(separator: " ")) cwd=\(launch.workingDirectory.path)")
        try s.start()
        isRunning = true
    }

    /// `show: false` keeps the message out of the transcript (live notes, warm-ups).
    /// `display` is what the transcript shows instead of `text` (a short label for a long prompt).
    /// `hideReply` keeps the reply out too; it defaults to hiding it when the message is hidden.
    func send(_ text: String, tag: String? = nil, show: Bool = true, hideReply: Bool? = nil, display: String? = nil,
              attachments: [Attachment] = [], images: [ImageBlock] = []) {
        guard let session, isRunning else {
            lastError = "\(Brain.name) is not running."
            return
        }
        Self.log("[\(mode ?? "-")] send \(tag ?? "-"): \(text.prefix(160))")
        if show {
            items.append(Item(role: .user, text: display ?? text, tag: tag, attachments: attachments))
            lastShown = (text, display ?? text, tag, attachments)
            retry.clear()
            if let tag { pendingTags.insert(tag) }
        }
        denials = []
        if hideReply ?? !show, let tag { hiddenTags.insert(tag) }
        pending += 1
        session.send(text, tag: tag, images: images)
    }

    /// Stops the turn of a tagged message, or drops it if it hasn't started; for voice barge-in.
    func interrupt(tag: String) {
        guard let session, pendingTags.contains(tag) else { return }
        if session.cancel(tag: tag) == .removed {
            pendingTags.remove(tag)
            pending = max(0, pending - 1)
        } else {
            cancelledTags.insert(tag)
        }
    }

    /// Takes back a message the transcript shows: one still waiting is removed, one Claude is working on is
    /// interrupted. Returns the text as shown, to edit and send again, and whether Claude had already read it;
    /// nil when its turn already finished.
    func cancel(_ item: Item) -> (text: String, reachedClaude: Bool)? {
        guard let tag = item.tag, pendingTags.contains(tag), let session else { return nil }
        switch session.cancel(tag: tag) {
        case .removed:
            pendingTags.remove(tag)
            pending = max(0, pending - 1)
            items.removeAll { $0.id == item.id }
            if let shown = lastShown, shown.tag == tag { lastShown = nil }
            return (item.text, false)
        case .interrupted:
            cancelledTags.insert(tag)
            items.removeAll { $0.id == item.id }
            // If Claude doesn't end the turn, stop the process; the next message continues the conversation.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.cancelledTags.contains(tag) else { return }
                self.cancelledTags.remove(tag)
                self.pendingTags.remove(tag)
                self.stop()
                self.items.append(Item(role: .status, text: "Cancelled. \(Brain.name) was stopped; your next message continues the conversation."))
            }
            return (item.text, true)
        case .notFound:
            pendingTags.remove(tag)
            return nil
        }
    }

    /// The failed message to send again, as `lastShown`; the offer goes with it.
    func takeRetry() -> (text: String, display: String, attachments: [Attachment])? {
        guard retry.errorItem != nil, let shown = lastShown else { return nil }
        retry.clear()
        return (shown.text, shown.display, shown.attachments)
    }

    /// A line from the app in the transcript, not sent to Claude and not kept.
    func note(_ text: String) {
        items.append(Item(role: .status, text: text))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        session?.terminate()
        session = nil
        isRunning = false
        pending = 0
        pendingTags = []
        activity = nil
        mode = nil
    }

    func reset() {
        stop()
        items = []
        sessionID = nil
        lastError = nil
        lastShown = nil
        retry.clear()
    }

    private func handle(_ event: ClaudeEvent, from s: ClaudeSession) {
        guard s === session else { return }
        Self.log("[\(mode ?? "-")] \(event)")
        switch event {
        case .sessionStarted(let id):
            sessionID = id
        case .connectors(let status):
            Self.onConnectors?(status)
        case .turnStarted(let tag):
            currentTag = tag
            turnHadText = false
            activity = nil
        case .assistantText(let t):
            turnHadText = true
            if !isHiddenTurn {
                items.append(Item(role: .assistant, text: t))
                flagAzureSignIn(t)
            }
        case .textDelta:
            break
        case .toolUse(let name):
            activity = name
        case .toolDetail(let name, let summary):
            activity = "\(name): \(summary)"
            if showsTools && !isHiddenTurn { items.append(Item(role: .tool, text: "\(name)\t\(summary)")) }
        case .commands(let list):
            commands = list
        case .denied(let list):
            denials = list
        case .turnResult(let text, let isError, let tag):
            pending = max(0, pending - 1)
            activity = nil
            let hidden = tag.map { hiddenTags.contains($0) } ?? false
            if let tag { hiddenTags.remove(tag) }
            if let tag { pendingTags.remove(tag) }
            if let tag, cancelledTags.remove(tag) != nil {
                if let shown = lastShown, shown.tag == tag { lastShown = nil }
                items.append(Item(role: .status, text: "Cancelled. \(Brain.name) stopped before finishing it."))
                onEvent?(event)
                return
            }
            if !isError, let shown = lastShown, shown.tag == tag { lastShown = nil }
            if isError {
                lastError = text.isEmpty ? "\(Brain.name) reported an error." : text
                if !hidden {
                    let item = Item(role: .error, text: lastError ?? "", tag: tag)
                    items.append(item)
                    retry.failed(item: item.id, turn: tag, waiting: lastShown?.tag)
                    flagAzureSignIn(text)
                }
                flagSignIn(text)
            } else if !hidden && !turnHadText && !text.isEmpty {
                items.append(Item(role: .assistant, text: text, tag: tag))
            }
            azureGraceTurns = max(0, azureGraceTurns - 1)
        case .error(let message):
            lastError = message
            let item = Item(role: .error, text: message)
            items.append(item)
            retry.failed(item: item.id, turn: nil, waiting: lastShown?.tag)
            flagSignIn(message)
        case .exited:
            isRunning = false
            pending = 0
            pendingTags = []
            activity = nil
        }
        onEvent?(event)
    }

    @ObservationIgnored private var currentTag: String?

    private func flagSignIn(_ text: String) {
        guard ClaudeAuth.isSignInProblem(text) else { return }
        needsSignIn = true
        Self.onSignInProblem?(self, text)
    }

    /// Call after sending the message that says so, or with `queued` when it goes once the running turns end.
    func azureSignedIn(queued: Bool) {
        needsAzureSignIn = false
        azureGraceTurns = pending + (queued ? 1 : 0)
    }

    private func flagAzureSignIn(_ text: String) {
        guard AzureSignIn.isProblem(text, justSignedIn: azureGraceTurns > 0) else { return }
        needsAzureSignIn = true
        Self.onAzureSignInProblem?(self, text)
    }

    /// After signing in again: the process still holds the old login, so it stops and the next message starts
    /// a fresh one that continues the same conversation.
    func signedInAgain() {
        needsSignIn = false
        if !isBusy { stop() }
    }

    /// Diagnostics: `KB_CLAUDE_LOG=<file>` appends every session event to that file.
    static func log(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["KB_CLAUDE_LOG"], !path.isEmpty else { return }
        let stamp = MeetingController.clock(Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    private var isHiddenTurn: Bool {
        currentTag.map { hiddenTags.contains($0) } ?? false
    }
}

/// Builds launches with the user's environment and `KB_ROOT`.
extension AppModel {
    enum ClaudeAvailability: Equatable {
        case resolving
        case found(URL)
        case missing
    }

    var claudeAvailability: ClaudeAvailability {
        guard let shell else { return .resolving }
        return shell.claude.map(ClaudeAvailability.found) ?? .missing
    }

    /// The plugin KB runs: a folder chosen in Settings, else the copy inside Mindmill.app.
    var pluginLocation: (path: String, source: PluginLocation.Source) {
        PluginLocation.resolve(chosen: UserDefaults.standard.string(forKey: AppSettingsKeys.pluginRoot),
                               bundled: Bundle.main.resourceURL?.appendingPathComponent("plugin").path)
    }

    var pluginRootPath: String { pluginLocation.path }

    /// `KB_MODEL` (diagnostics) overrides both model settings for one launch.
    private var modelOverride: String? {
        ProcessInfo.processInfo.environment["KB_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The model a task runs on, from Settings → AI; empty for the assistant's default.
    func model(for task: AITask) -> String {
        modelOverride ?? aiSetup.model(for: task)
    }

    var liveModel: String { model(for: .meetings) }

    var defaultModel: String { model(for: .work) }

    var backgroundModel: String { model(for: .background) }

    var brainName: String { aiSetup.brainProvider.shortName }

    var cli: KBCLI {
        KBCLI(pluginRoot: URL(fileURLWithPath: KBConfig.expandTilde(pluginRootPath)), kbRoot: rootURL,
              python: shell?.python3 ?? URL(fileURLWithPath: "/usr/bin/python3"),
              environment: shell?.environment ?? ProcessInfo.processInfo.environment)
    }

    func resolveShell() {
        Task.detached(priority: .userInitiated) {
            let resolved = LoginShell.resolve()
            await MainActor.run { [weak self] in
                self?.shell = resolved
                self?.checkConnectors(force: true)
                self?.startBackgroundWork()
            }
        }
    }

    func claudeEnvironment() -> [String: String] {
        var env = shell?.environment ?? ProcessInfo.processInfo.environment
        env["KB_ROOT"] = rootURL.path
        return env
    }

    func launch(prompt: String, sessionID: String, resume: Bool, model: String, cwd: URL,
                tools: [String] = ClaudeLaunch.bridgeTools) -> ClaudeLaunch? {
        guard case .found(let exe) = claudeAvailability else { return nil }
        return ClaudeLaunch(executable: exe, pluginRoot: pluginRootPath, systemPrompt: prompt + "\n" + ClaudeModes.linkCapture, sessionID: sessionID,
                            resume: resume, model: model, workingDirectory: cwd, allowedTools: tools,
                            environment: claudeEnvironment())
    }

    var claudeMissingExplanation: String {
        switch claudeAvailability {
        case .resolving: return "Looking for the claude CLI…"
        case .missing: return "The claude CLI was not found on your login shell's PATH (zsh -lc 'command -v claude'). Install Claude Code, then relaunch Mindmill."
        case .found: return ""
        }
    }
}

enum AppSettingsKeys {
    static let appearance = "appearance"
    static let settingsPane = "settingsPane"
    static let launchMode = "launchMode"
    static let autoMorning = "autoMorning"
    static let calendarMinutes = "calendarSyncMinutes"
    static let calendarModel = "calendarModel"
    static let transcriptLanguage = "transcriptLanguage"
    static let transcriptMicrophone = "transcriptMicrophone"
    static let transcriptComputerAudio = "transcriptComputerAudio"
    static let transcriptConsentAcknowledged = "transcriptConsentAcknowledged"
    static let pluginRoot = "pluginRoot"
    static let liveModel = "liveModel"
    static let defaultModel = "defaultModel"
    static let defaultPluginRoot = PluginLocation.developmentPath
}
