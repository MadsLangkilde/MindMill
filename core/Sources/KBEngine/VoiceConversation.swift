import Foundation
import KBCore
import Observation

/// What a voice conversation tells whoever listens (the Mac's voice window, a phone).
public enum VoiceOutput: Equatable {
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

public enum VoiceState: String, Equatable {
    case idle, listening, thinking, speaking
}

/// One spoken conversation: a persistent Claude session, so a turn costs no start-up, with the action tools.
@MainActor
@Observable
public final class VoiceConversation: Identifiable {
    public struct Line: Identifiable, Equatable {
        public enum Role: String { case user, assistant, action, error, status }
        public let id = UUID()
        public let role: Role
        public var text: String

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    public let id = UUID().uuidString.lowercased()
    public let scope: String?
    public let chat = ClaudeChat()
    public private(set) var lines: [Line] = []
    public private(set) var turn: String?
    public var engine: VoiceEngineKind = .keyless
    /// The API engine failed once; it stays keyless from then on.
    public var apiFailed = false
    private var chunker = SpeechChunker()
    private var replyText = ""
    @ObservationIgnored private var sinks: [UUID: (VoiceOutput) -> Void] = [:]
    @ObservationIgnored public var started = false
    /// The phone connection that started it, if any.
    @ObservationIgnored public var owner: ObjectIdentifier?
    /// Live voice in this work session: the realtime model talks, the session does the work.
    @ObservationIgnored public var sessionID: String?
    @ObservationIgnored public var sessionFollower = SessionVoiceFollower()

    public init(scope: String?) {
        self.scope = scope
    }

    @discardableResult
    public func listen(_ sink: @escaping (VoiceOutput) -> Void) -> UUID {
        let key = UUID()
        sinks[key] = sink
        return key
    }

    public func stopListening(_ key: UUID) { sinks.removeValue(forKey: key) }

    public var hasListeners: Bool { !sinks.isEmpty }

    public func emit(_ out: VoiceOutput) {
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

    public var isBusy: Bool { turn != nil }

    /// Sends what the user said; the reply comes back as sentences while it is written.
    public func say(_ text: String) -> String {
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
    public func ask(_ text: String) async -> String {
        let tag = "b-" + UUID().uuidString.prefix(8).lowercased()
        return await withCheckedContinuation { c in
            asks[tag] = c
            chat.send(text, tag: tag, show: false)
        }
    }

    public func interrupt() {
        guard let t = turn else { return }
        chat.interrupt(tag: t)
        turn = nil
        emit(.state(.listening))
    }

    public func handle(_ event: ClaudeEvent) {
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
