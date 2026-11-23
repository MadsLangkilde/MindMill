import Foundation
import KBCore

/// A connection to a real-time voice API for one conversation, held on the Mac with the key from the Keychain.
/// Audio comes in from the Mac's microphone or a phone and goes back the same way; tool calls run through the same
/// action layer as the buttons; anything deeper goes to the voice brain. Any failure falls back to keyless.
@MainActor
final class RealtimeRelay {
    struct Audio {
        let seq: Int
        let pcm: Data
    }

    /// The rate audio leaves the relay at, for the Mac's player and the phone (`pcm24k`).
    static let outRate: Double = 24000
    static let inRate: Double = 16000

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
    private var resumeHandle: String?
    private var settings: (model: String, key: String, voice: String, instructions: String)?

    init(wire: RealtimeWire, conversation: VoiceConversation, layer: ActionLayer, askBrain: @escaping (String) async -> String,
         audioOut: @escaping (Audio) -> Void, onFail: @escaping (VoiceFailure) -> Void) {
        self.wire = wire
        self.conversation = conversation
        self.layer = layer
        self.askBrain = askBrain
        self.audioOut = audioOut
        self.onFail = onFail
    }

    func connect(model: String, key: String, voice: String, instructions: String) {
        settings = (model, key, voice, instructions)
        let t = URLSession.shared.webSocketTask(with: wire.request(model: model, key: key))
        t.maximumMessageSize = 16 << 20
        task = t
        t.resume()
        let tools = RealtimeTools.definitions(layer.toolDefinitions(only: ActionCatalog.voiceCore))
        for m in wire.setup(model: model, instructions: instructions, voice: voice, tools: tools, resume: resumeHandle) { send(m) }
        receive()
    }

    func sendAudio(_ pcm16k: Data) {
        guard !closed, task != nil else { return }
        send(wire.audio(PCMResampler.resample(pcm16k, from: Self.inRate, to: wire.inputRate)))
    }

    func interrupt() {
        for m in wire.cancel() { send(m) }
        conversation?.emit(.clear)
    }

    func close() {
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
            seq += 1
            c.emit(.state(.speaking))
            audioOut(Audio(seq: seq, pcm: PCMResampler.resample(pcm, from: wire.outputRate, to: Self.outRate)))
        case .assistantTranscript(let t, let final):
            if final {
                let text = t.isEmpty ? assistantText : t
                assistantText = ""
                if !text.isEmpty { c.emit(.transcript(role: "assistant", text: text, final: true)) }
            } else {
                assistantText += t
                c.emit(.transcript(role: "assistant", text: t, final: false))
            }
        case .userTranscript(let t, let final):
            c.emit(.transcript(role: "user", text: t, final: final))
        case .speechStarted:
            c.emit(.clear)
            c.emit(.state(.listening))
        case .responseDone:
            if !assistantText.isEmpty {
                c.emit(.transcript(role: "assistant", text: assistantText, final: true))
                assistantText = ""
            }
            c.emit(.state(.listening))
        case .toolCall(let id, let name, let args):
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

    private func runTool(_ name: String, _ args: JSONValue) async -> String {
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

extension AppModel {
    /// Connects a conversation to its real-time API; without a provider, key or wire it falls back to keyless and
    /// says so.
    func startRealtime(_ c: VoiceConversation, audioOut: @escaping (RealtimeRelay.Audio) -> Void) {
        let prefs = VoicePreferences.load()
        guard let provider = prefs.provider, let key = VoiceKeychain().key(provider: provider), !key.isEmpty,
              let wire = RealtimeWires.wire(for: provider) else {
            fallBack(c, .badKey)
            return
        }
        let relay = RealtimeRelay(wire: wire, conversation: c, layer: actions,
                                  askBrain: { [weak self, weak c] request in
                                      guard let self, let c else { return "The brain isn't available." }
                                      return await self.askVoiceBrain(request, in: c)
                                  },
                                  audioOut: audioOut,
                                  onFail: { [weak self, weak c] reason in
                                      guard let self, let c else { return }
                                      self.fallBack(c, reason)
                                  })
        realtimeRelays[c.id] = relay
        let title = index.projects.first { $0.id == c.scope }?.title
        let instructions = RealtimeTools.instructions + (title.map { " The current project is \($0)." } ?? "")
        relay.connect(model: prefs.model(for: provider), key: key, voice: prefs.apiVoice(for: provider), instructions: instructions)
    }

    private func fallBack(_ c: VoiceConversation, _ reason: VoiceFailure) {
        realtimeRelays[c.id]?.close()
        realtimeRelays[c.id] = nil
        c.apiFailed = true
        c.engine = .keyless
        c.emit(.fallback(reason: reason, speech: VoiceEngineChoice.fallbackSpeech(reason)))
    }

    /// The real-time model's `ask_brain`: one turn of the conversation's Claude session, answered in text.
    func askVoiceBrain(_ request: String, in c: VoiceConversation) async -> String {
        if !c.chat.isRunning { await bootVoiceBrain(c) }
        return await c.ask(request)
    }
}
