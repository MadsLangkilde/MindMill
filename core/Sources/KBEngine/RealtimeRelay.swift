import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KBCore
import KBEngine

/// A connection to a real-time voice API for one conversation, held by the engine with the key from its `SecretStore`.
/// Audio comes in from the Mac's microphone or a phone and goes back the same way; tool calls run through the same
/// action layer as the buttons; anything deeper goes to the voice brain. Any failure falls back to keyless.
@MainActor
public final class RealtimeRelay {
    public struct Audio {
        public let seq: Int
        public let pcm: Data
    }

    /// Tools of its own instead of the action layer's (live voice in a session).
    public struct Tools {
        public let definitions: [JSONValue]
        public let run: (String, JSONValue) async -> String

        public init(definitions: [JSONValue], run: @escaping (String, JSONValue) async -> String) {
            self.definitions = definitions
            self.run = run
        }
    }

    /// The rate audio leaves the relay at, for the Mac's player and the phone (`pcm24k`).
    public static let outRate: Double = 24000
    public static let inRate: Double = 16000

    private let wire: RealtimeWire
    private weak var conversation: VoiceConversation?
    private let layer: ActionLayer
    private let askBrain: (String) async -> String
    private let audioOut: (Audio) -> Void
    private let onFail: (VoiceFailure) -> Void
    private var task: URLSessionWebSocketTask?
    private var seq = 0
    private var closed = false
    private var assistantText = ""
    private var userText = ""
    private var resumeHandle: String?
    private let custom: Tools?
    private var settings: (model: String, key: String, voice: String, instructions: String)?

    public init(wire: RealtimeWire, conversation: VoiceConversation, layer: ActionLayer, askBrain: @escaping (String) async -> String,
         audioOut: @escaping (Audio) -> Void, onFail: @escaping (VoiceFailure) -> Void, tools: Tools? = nil) {
        self.custom = tools
        self.wire = wire
        self.conversation = conversation
        self.layer = layer
        self.askBrain = askBrain
        self.audioOut = audioOut
        self.onFail = onFail
    }

    public func connect(model: String, key: String, voice: String, instructions: String) {
        settings = (model, key, voice, instructions)
        let t = URLSession.shared.webSocketTask(with: wire.request(model: model, key: key))
        t.maximumMessageSize = 16 << 20
        task = t
        t.resume()
        let tools = custom?.definitions ?? RealtimeTools.definitions(layer.toolDefinitions(only: ActionCatalog.voiceCore))
        for m in wire.setup(model: model, instructions: instructions, voice: voice, tools: tools, resume: resumeHandle) { send(m) }
        receive()
    }

    public func sendAudio(_ pcm16k: Data) { sendAudio(pcm16k, rate: Self.inRate) }

    /// Microphone audio at `rate` (16 kHz from phones, 24 kHz from the Windows shell), resampled for the wire.
    public func sendAudio(_ pcm: Data, rate: Double) {
        guard !closed, task != nil else { return }
        send(wire.audio(PCMResampler.resample(pcm, from: rate, to: wire.inputRate)))
    }

    /// A text turn for the model to answer out loud (the session's progress).
    public func say(_ text: String) {
        guard !closed, task != nil else { return }
        for m in wire.text(text) { send(m) }
    }

    public func interrupt() {
        for m in wire.cancel() { send(m) }
        conversation?.emit(.clear)
    }

    public func close() {
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func send(_ message: JSONValue) {
        task?.send(.string(message.jsonString)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.failed(status: nil, message: error.localizedDescription) }
        }
    }

    private func receive() {
        let current = task
        current?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed, self.task === current else { return }
                switch result {
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: data = Data()
                    }
                    if let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
                        for e in self.wire.parse(json) { await self.handle(e) }
                    }
                    self.receive()
                case .failure(let error):
                    let status = (self.task?.response as? HTTPURLResponse)?.statusCode
                    let reason = self.task?.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    self.failed(status: status, message: reason.isEmpty ? error.localizedDescription : reason)
                }
            }
        }
    }

    private func handle(_ e: RealtimeEvent) async {
        guard let c = conversation else { return }
        switch e {
        case .ready:
            c.emit(.state(.listening))
        case .audio(let pcm):
            finishUserTurn()
            seq += 1
            c.emit(.state(.speaking))
            audioOut(Audio(seq: seq, pcm: PCMResampler.resample(pcm, from: wire.outputRate, to: Self.outRate)))
        case .assistantTranscript(let t, let final):
            if final {
                let text = t.isEmpty ? assistantText : t
                assistantText = ""
                if !text.isEmpty { c.emit(.transcript(role: "assistant", text: text, final: true)) }
            } else {
                finishUserTurn()
                assistantText += t
                c.emit(.transcript(role: "assistant", text: assistantText, final: false))
            }
        case .userTranscript(let t, let final):
            if final {
                userText = ""
                c.emit(.transcript(role: "user", text: t, final: true))
            } else {
                userText += t
                c.emit(.transcript(role: "user", text: userText, final: false))
            }
        case .speechStarted:
            c.emit(.clear)
            c.emit(.state(.listening))
        case .responseDone:
            finishUserTurn()
            if !assistantText.isEmpty {
                c.emit(.transcript(role: "assistant", text: assistantText, final: true))
                assistantText = ""
            }
            c.emit(.state(.listening))
        case .toolCall(let id, let name, let args):
            finishUserTurn()
            c.emit(.state(.thinking))
            let output = await runTool(name, args)
            for m in wire.toolResult(id: id, name: name, output: output) { send(m) }
        case .error(let status, let message, let fatal):
            if fatal { failed(status: status, message: message) }
        case .resumeHandle(let h):
            resumeHandle = h
        case .goAway:
            reconnect()
        }
    }

    /// Moves to a new connection, carrying the session on with the last resumption handle.
    private func reconnect() {
        guard let s = settings, resumeHandle != nil else { return }
        let old = task
        task = nil
        old?.cancel(with: .normalClosure, reason: nil)
        connect(model: s.model, key: s.key, voice: s.voice, instructions: s.instructions)
    }

    /// A provider that sends the user's words in pieces (Gemini) never says they're final: they are once it answers.
    private func finishUserTurn() {
        guard !userText.isEmpty else { return }
        let text = userText.trimmingCharacters(in: .whitespaces)
        userText = ""
        if !text.isEmpty { conversation?.emit(.transcript(role: "user", text: text, final: true)) }
    }

    private func runTool(_ name: String, _ args: JSONValue) async -> String {
        if let custom { return await custom.run(name, args) }
        switch name {
        case RealtimeTools.askBrain:
            return await askBrain(args["request"]?.string ?? "")
        default:
            return await layer.callTool(name, args, channel: .voice).text
        }
    }

    private func failed(status: Int?, message: String) {
        guard !closed else { return }
        close()
        onFail(VoiceFailure.classify(status: status, message: message))
    }
}
