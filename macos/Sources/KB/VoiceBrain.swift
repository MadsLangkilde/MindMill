import Foundation
import KBCore
import Observation

/// What a voice conversation tells whoever listens (the Mac's voice window, a phone).
enum VoiceOutput: Equatable {
    case userSaid(String)
    case sentence(turn: String, index: Int, text: String)
    case done(turn: String, text: String)
    case action(name: String, status: String, speech: String, data: JSONValue)
    case error(String)
    case state(VoiceState)
    case transcript(role: String, text: String, final: Bool)
    /// The API engine: drop queued audio now.
    case clear
    case fallback(reason: VoiceFailure, speech: String)
}

enum VoiceState: String, Equatable {
    case idle, listening, thinking, speaking
}

/// One spoken conversation: a persistent Claude session, so a turn costs no start-up, with the action tools.
@MainActor
@Observable
final class VoiceConversation: Identifiable {
    struct Line: Identifiable, Equatable {
        enum Role: String { case user, assistant, action, error, status }
        let id = UUID()
        let role: Role
        var text: String
    }

    let id = UUID().uuidString.lowercased()
    let scope: String?
    let chat = ClaudeChat()
    private(set) var lines: [Line] = []
    private(set) var turn: String?
    var engine: VoiceEngineKind = .keyless
    /// The API engine failed once; it stays keyless from then on.
    var apiFailed = false
    private var chunker = SpeechChunker()
    private var replyText = ""
    @ObservationIgnored private var sinks: [UUID: (VoiceOutput) -> Void] = [:]
    @ObservationIgnored var started = false
    /// The phone connection that started it, if any.
    @ObservationIgnored var owner: ObjectIdentifier?

    init(scope: String?) {
        self.scope = scope
    }

    @discardableResult
    func listen(_ sink: @escaping (VoiceOutput) -> Void) -> UUID {
        let key = UUID()
        sinks[key] = sink
        return key
    }

    func stopListening(_ key: UUID) { sinks.removeValue(forKey: key) }

    var hasListeners: Bool { !sinks.isEmpty }

    func emit(_ out: VoiceOutput) {
        switch out {
        case .userSaid(let t): lines.append(Line(role: .user, text: t))
        case .done(_, let t) where !t.isEmpty: lines.append(Line(role: .assistant, text: t))
        case .action(_, let status, let speech, _) where status == "done": lines.append(Line(role: .action, text: speech))
        case .error(let m): lines.append(Line(role: .error, text: m))
        case .fallback(_, let speech): lines.append(Line(role: .status, text: speech))
        case .transcript(let role, let text, true):
            lines.append(Line(role: role == "user" ? .user : .assistant, text: text))
        default: break
        }
        for sink in sinks.values { sink(out) }
    }

    var isBusy: Bool { turn != nil }

    /// Sends what the user said; the reply comes back as sentences while it is written.
    func say(_ text: String) -> String {
        if let turn { chat.interrupt(tag: turn) }
        let t = "v-" + UUID().uuidString.prefix(8).lowercased()
        turn = t
        chunker = SpeechChunker()
        replyText = ""
        emit(.userSaid(text))
        emit(.state(.thinking))
        chat.send(text, tag: t)
        return t
    }

    @ObservationIgnored private var asks: [String: CheckedContinuation<String, Never>] = [:]

    /// One turn whose answer comes back as text instead of speech: the real-time model's `ask_brain`.
    func ask(_ text: String) async -> String {
        let tag = "b-" + UUID().uuidString.prefix(8).lowercased()
        return await withCheckedContinuation { c in
            asks[tag] = c
            chat.send(text, tag: tag, show: false)
        }
    }

    func interrupt() {
        guard let t = turn else { return }
        chat.interrupt(tag: t)
        turn = nil
        emit(.state(.listening))
    }

    func handle(_ event: ClaudeEvent) {
        switch event {
        case .textDelta(let piece):
            guard let t = turn else { return }
            replyText += piece
            for s in chunker.add(piece) { emit(.sentence(turn: t, index: chunker.count - 1, text: s)) }
        case .turnResult(let text, let isError, let tag):
            if let tag, let waiting = asks.removeValue(forKey: tag) {
                waiting.resume(returning: isError ? "The brain couldn't answer: \(text)" : text)
                return
            }
            guard let t = turn, tag == t else { return }
            if isError {
                emit(.error(text.isEmpty ? "Something went wrong." : SpeechChunker.plain(String(text.prefix(200)))))
            } else {
                for s in chunker.finish() { emit(.sentence(turn: t, index: chunker.count - 1, text: s)) }
                if chunker.count == 0, !text.isEmpty {
                    var c = SpeechChunker()
                    for s in c.add(text) + c.finish() { emit(.sentence(turn: t, index: 0, text: s)) }
                }
                emit(.done(turn: t, text: SpeechChunker.plain(text.isEmpty ? replyText : text)))
            }
            turn = nil
        case .exited:
            for (_, waiting) in asks { waiting.resume(returning: "The brain stopped.") }
            asks = [:]
            if turn != nil { emit(.error("The voice brain stopped. Say something to start it again.")) }
            turn = nil
        default:
            break
        }
    }
}

extension AppModel {
    /// Starts a voice conversation's brain: a persistent Claude session with the action tools, streaming its reply.
    func startVoiceConversation(scope: String?, engine: VoiceEngineKind? = nil) async -> VoiceConversation {
        let c = VoiceConversation(scope: scope ?? projectID)
        c.engine = engine ?? voiceEngineChoice.engine()
        voiceConversations[c.id] = c
        c.chat.onEvent = { [weak c] e in c?.handle(e) }
        await bootVoiceBrain(c)
        return c
    }

    func bootVoiceBrain(_ c: VoiceConversation) async {
        let mcp = await actionServer.ready()
        let title = index.projects.first { $0.id == c.scope }?.title
        let cwd = ClaudeLaunch.workingDirectory(project: index.project(c.scope ?? ""), root: rootURL)
        var model = model(for: .voice)
        if model.isEmpty { model = "sonnet" }
        guard var launch = launch(prompt: VoicePrompt.system(project: c.scope, projectTitle: title),
                                  sessionID: UUID().uuidString.lowercased(), resume: false, model: model, cwd: cwd,
                                  tools: ClaudeLaunch.bridgeTools + MCPActions.allowedTools) else {
            c.emit(.error(claudeMissingExplanation))
            return
        }
        launch.mcpConfig = mcp
        launch.partialMessages = true
        launch.persist = false
        do {
            try c.chat.start(launch, mode: "voice")
            c.started = true
        } catch {
            c.emit(.error("Couldn't start the voice brain: \(error.localizedDescription)"))
        }
    }

    /// Says something in a conversation, starting its brain again if it stopped.
    func voiceSay(_ text: String, in c: VoiceConversation) async -> String {
        if !c.chat.isRunning { await bootVoiceBrain(c) }
        return c.say(text)
    }

    func endVoiceConversation(_ id: String) {
        guard let c = voiceConversations.removeValue(forKey: id) else { return }
        c.interrupt()
        c.chat.stop()
        realtimeRelays[id]?.close()
        realtimeRelays[id] = nil
    }

    /// Actions the voice brain ran show as cards in the conversation that was talking.
    func forwardVoiceAction(_ name: String, _ channel: ActionChannel, _ result: ActionResult) {
        guard channel == .model || channel == .voice else { return }
        for c in voiceConversations.values where c.isBusy || c.engine == .api {
            c.emit(.action(name: name, status: "done", speech: result.speech, data: result.data))
        }
    }

    var voiceEngineChoice: VoiceEngineChoice {
        let prefs = VoicePreferences.load()
        return VoiceEngineChoice(preferred: prefs.engine, provider: prefs.provider,
                                 hasKey: prefs.provider.map { VoiceKeychain.has(provider: $0) } ?? false)
    }
}
