import Foundation
import KBCore
import Observation

/// A `ClaudeSession` as SwiftUI state: the visible transcript, whether a turn is running, and the last tool used.
@MainActor
@Observable
public final class ClaudeChat {
    public enum Role: String { case user, assistant, error, status, tool }

    public struct Item: Identifiable, Equatable {
        public let id = UUID()
        public let role: Role
        public var text: String
        public var tag: String?
        /// Files and images sent with a user message, shown with it.
        public var attachments: [Attachment] = []
        /// When it was sent or arrived; nil for a message restored from before times were kept.
        public var at: Date?

        public init(role: Role, text: String, tag: String? = nil, attachments: [Attachment] = [], at: Date? = Date()) {
            self.role = role
            self.text = text
            self.tag = tag
            self.attachments = attachments
            self.at = at
        }
    }

    public var items: [Item] = []
    /// Messages sent and not yet answered, including the one running.
    public private(set) var pending = 0
    public private(set) var activity: String?
    public private(set) var sessionID: String?
    public private(set) var isRunning = false
    public private(set) var mode: String?
    public var lastError: String?
    /// Slash commands the session knows, from its init line.
    public private(set) var commands: [String] = []
    /// Tool calls refused in the last turn, as `Tool(detail)`.
    public private(set) var denials: [String] = []
    /// Session windows show each tool call as a `.tool` item; other chats only show the activity.
    @ObservationIgnored public var showsTools = false

    /// Every session's MCP connector statuses, so the app can say when Microsoft 365 needs signing in.
    @ObservationIgnored public static var onConnectors: (([String: String]) -> Void)?
    /// A chat whose Claude failed to sign in, with the error. The app asks the user to sign in again.
    @ObservationIgnored public static var onSignInProblem: ((ClaudeChat, String) -> Void)?
    /// A chat that says the Azure CLI sign-in the Azure DevOps tools use has expired, with what it said.
    @ObservationIgnored public static var onAzureSignInProblem: ((ClaudeChat, String) -> Void)?
    /// Claude said the Azure CLI sign-in has expired; the session offers to sign in from KB until it's done or dismissed.
    public var needsAzureSignIn = false
    /// Turns left to end before a reply mentioning az login counts again, once the Azure sign-in works.
    @ObservationIgnored private var azureGraceTurns = 0
    /// The last turn failed because Claude isn't signed in; cleared once the user signs in again.
    public private(set) var needsSignIn = false
    /// The last message the transcript showed, as sent and as shown, until its turn succeeds: what to send
    /// again after signing in.
    public private(set) var lastShown: (text: String, display: String, tag: String?, attachments: [Attachment])?
    private var retry = RetryOffer()
    /// The error line that offers to send the failed message again.
    public var retryItemID: UUID? { lastShown == nil ? nil : retry.errorItem }
    /// Tags of shown messages whose turn hasn't ended: they can still be cancelled.
    public private(set) var pendingTags: Set<String> = []
    @ObservationIgnored private var cancelledTags: Set<String> = []

    /// Called for every event, after the transcript is updated.
    @ObservationIgnored public var onEvent: ((ClaudeEvent) -> Void)?
    @ObservationIgnored private var session: ClaudeSession?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var turnHadText = false
    @ObservationIgnored private var hiddenTags: Set<String> = []

    public var isBusy: Bool { pending > 0 }

    public init() {}

    public func start(_ launch: ClaudeLaunch, mode: String) throws {
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
    public func send(_ text: String, tag: String? = nil, show: Bool = true, hideReply: Bool? = nil, display: String? = nil,
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
    public func interrupt(tag: String) {
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
    public func cancel(_ item: Item) -> (text: String, reachedClaude: Bool)? {
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
    public func takeRetry() -> (text: String, display: String, attachments: [Attachment])? {
        guard retry.errorItem != nil, let shown = lastShown else { return nil }
        retry.clear()
        return (shown.text, shown.display, shown.attachments)
    }

    /// A line from the app in the transcript, not sent to Claude and not kept.
    public func note(_ text: String) {
        items.append(Item(role: .status, text: text))
    }

    public func stop() {
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

    public func reset() {
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
    public func azureSignedIn(queued: Bool) {
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
    public func signedInAgain() {
        needsSignIn = false
        if !isBusy { stop() }
    }

    /// Diagnostics: `KB_CLAUDE_LOG=<file>` appends every session event to that file.
    public static func log(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["KB_CLAUDE_LOG"], !path.isEmpty else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let stamp = f.string(from: Date())
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
