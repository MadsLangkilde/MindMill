import AVFoundation
import KBCore
import KBEngine
import Observation

/// Voice mode on the Mac: listen, send what was said to the voice brain, speak the reply sentence by sentence as
/// it arrives, and stop speaking as soon as the user talks.
@MainActor
@Observable
final class MacVoiceMode {
    enum Phase: Equatable {
        case off, starting, listening, thinking, speaking
        case failed(String)
    }

    private(set) var phase: Phase = .off
    private(set) var heard = ""
    private(set) var level: Float = 0
    private(set) var conversation: VoiceConversation?
    private(set) var notice: String?
    var muted = false { didSet { listener?.muted = muted } }

    @ObservationIgnored private var listener: SpeechListener?
    @ObservationIgnored private var speaker: SentenceSpeaker?
    @ObservationIgnored private var sink: UUID?
    @ObservationIgnored private var replyDone = true
    @ObservationIgnored private var prefs = VoicePreferences()
    @ObservationIgnored private weak var model: AppModel?

    var isOn: Bool {
        switch phase {
        case .off, .failed: return false
        default: return true
        }
    }

    func start(_ model: AppModel) async {
        guard !isOn else { return }
        self.model = model
        phase = .starting
        notice = nil
        if let problem = await SpeechListener.authorize() {
            phase = .failed(problem)
            return
        }
        prefs = VoicePreferences.load()
        let c = await model.startVoiceConversation(scope: model.projectID)
        conversation = c
        sink = c.listen { [weak self] out in self?.handle(out) }

        let l = SpeechListener()
        let api = c.engine == .api
        l.recognizes = !api
        l.onLevel = { [weak self] v in self?.level = v }
        l.onPartial = { [weak self] text in self?.heardSome(text) }
        l.onUtterance = { [weak self] text in self?.utterance(text) }
        let s = SentenceSpeaker(engine: l.engine)
        s.voiceID = prefs.macVoice
        s.language = prefs.language
        s.rate = prefs.rate
        s.onStart = { [weak self] in
            guard let self else { return }
            self.phase = .speaking
            self.listener?.reset()
        }
        s.onIdle = { [weak self] in self?.spokeAll() }
        listener = l
        speaker = s
        if api {
            l.onPCM16k = { [weak self, weak c] pcm in
                guard let c, let relay = self?.model?.realtimeRelays[c.id] else { return }
                relay.sendAudio(pcm)
            }
            model.startRealtime(c) { [weak self] audio in self?.playAPI(audio.pcm) }
        }
        do {
            try l.start(language: prefs.language, voiceProcessing: true)
            phase = .listening
            if !l.voiceProcessing { notice = "Echo cancellation isn't available, so use headphones to talk over replies." }
        } catch {
            phase = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        listener?.stop()
        speaker?.stop()
        listener = nil
        speaker = nil
        apiPlayer = nil
        if let c = conversation {
            if let sink { c.stopListening(sink) }
            model?.endVoiceConversation(c.id)
        }
        conversation = nil
        heard = ""
        level = 0
        if case .failed = phase {} else { phase = .off }
    }

    /// Stops speaking now and listens.
    func interrupt() {
        speaker?.stop()
        apiPlayer?.stop()
        conversation?.interrupt()
        model?.realtimeRelays[conversation?.id ?? ""]?.interrupt()
        replyDone = true
        phase = .listening
    }

    private func heardSome(_ text: String) {
        heard = text
        guard phase == .speaking || phase == .thinking, prefs.bargeIn else { return }
        let words = text.split(whereSeparator: \.isWhitespace).count
        let needed = listener?.voiceProcessing == true ? 2 : 3
        if words >= needed { interrupt() }
    }

    private func utterance(_ text: String) {
        heard = ""
        guard let c = conversation, let model else { return }
        speaker?.stop()
        replyDone = false
        phase = .thinking
        Task { _ = await model.voiceSay(text, in: c) }
    }

    private func handle(_ out: VoiceOutput) {
        switch out {
        case .sentence(_, _, let text):
            speaker?.speak(text)
        case .done:
            replyDone = true
            if speaker?.isSpeaking != true { phase = .listening }
        case .error(let message):
            replyDone = true
            speaker?.speak(message)
        case .state(let s):
            if conversation?.engine == .api {
                phase = s == .speaking ? .speaking : s == .thinking ? .thinking : .listening
            }
        case .clear:
            apiPlayer?.stop()
        case .fallback(_, let speech):
            notice = speech
            switchToKeyless()
            speaker?.speak(speech)
        default:
            break
        }
    }

    private func spokeAll() {
        if replyDone, phase == .speaking { phase = .listening }
    }

    private func switchToKeyless() {
        guard let l = listener else { return }
        l.onPCM16k = nil
        l.stop()
        let fresh = SpeechListener()
        fresh.onLevel = l.onLevel
        fresh.onPartial = l.onPartial
        fresh.onUtterance = l.onUtterance
        let s = SentenceSpeaker(engine: fresh.engine)
        s.voiceID = prefs.macVoice
        s.language = prefs.language
        s.rate = prefs.rate
        s.onStart = speaker?.onStart
        s.onIdle = speaker?.onIdle
        listener = fresh
        speaker = s
        apiPlayer = nil
        try? fresh.start(language: prefs.language, voiceProcessing: true)
        phase = .listening
    }

    // MARK: API engine audio

    @ObservationIgnored private var apiPlayer: AVAudioPlayerNode?
    @ObservationIgnored private let apiFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    private func playAPI(_ pcm: Data) {
        guard let l = listener else { return }
        if apiPlayer == nil {
            let p = AVAudioPlayerNode()
            l.engine.attach(p)
            l.engine.connect(p, to: l.engine.mainMixerNode, format: apiFormat)
            apiPlayer = p
        }
        let frames = pcm.count / 2
        guard frames > 0, let p = apiPlayer, let buffer = AVAudioPCMBuffer(pcmFormat: apiFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        p.scheduleBuffer(buffer)
        if !p.isPlaying { p.play() }
    }
}
