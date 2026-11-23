import AVFoundation
import KBCore
import NaturalLanguage
import Speech

/// The microphone with on-device speech recognition, cut into utterances at a pause. With voice processing on,
/// the Mac's echo cancellation removes what `SentenceSpeaker` plays through the same engine, so the user can talk
/// over a reply (barge-in) without it hearing itself.
@MainActor
final class SpeechListener {
    let engine = AVAudioEngine()
    var onPartial: ((String) -> Void)?
    var onUtterance: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    /// Raw microphone audio as 16 kHz mono 16-bit PCM, for a real-time API instead of recognition.
    var onPCM16k: ((Data) -> Void)?
    var muted = false
    /// A pause this long ends what the user said.
    var endSilence: TimeInterval = 1.1
    private(set) var voiceProcessing = false

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var partial = ""
    private var lastChange = Date()
    private var ticker: Timer?
    private var converter: AVAudioConverter?
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    var recognizes = true

    static func authorize() async -> String? {
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else { return "Mindmill isn't allowed to recognise speech. Allow it in System Settings → Privacy & Security → Speech Recognition." }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard mic else { return "Mindmill isn't allowed to use the microphone. Allow it in System Settings → Privacy & Security → Microphone." }
        return nil
    }

    static func locale(for language: String) -> Locale {
        if language != "auto" { return Locale(identifier: language) }
        let preferred = Locale.preferredLanguages.first ?? "en-US"
        return preferred.hasPrefix("da") ? Locale(identifier: "da-DK") : Locale(identifier: "en-US")
    }

    func start(language: String, voiceProcessing wanted: Bool) throws {
        let input = engine.inputNode
        if wanted {
            do {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessing = true
            } catch {
                voiceProcessing = false
            }
        }
        if recognizes {
            let r = SFSpeechRecognizer(locale: Self.locale(for: language)) ?? SFSpeechRecognizer()
            guard let r, r.isAvailable else { throw ActionError("Speech recognition isn't available for this language.") }
            recognizer = r
            restartRecognition()
        }
        let format = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: pcmFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let level = Self.level(buffer)
            Task { @MainActor in self?.received(buffer, level: level) }
        }
        engine.prepare()
        try engine.start()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
    }

    /// Forgets what was heard so far, e.g. once speaking starts, so only new words count for barge-in.
    func reset() {
        partial = ""
        restartRecognition()
    }

    private func received(_ buffer: AVAudioPCMBuffer, level: Float) {
        onLevel?(muted ? 0 : level)
        guard !muted else { return }
        request?.append(buffer)
        if let onPCM16k, let pcm = convert(buffer) { onPCM16k(pcm) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter else { return nil }
        let ratio = pcmFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let p = out.int16ChannelData else { return nil }
        return Data(bytes: p[0], count: Int(out.frameLength) * 2)
    }

    private func restartRecognition() {
        task?.cancel()
        request?.endAudio()
        guard recognizes, let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        req.taskHint = .dictation
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error.map { ($0 as NSError).code }
            Task { @MainActor in
                guard let self, self.request === req else { return }
                if let text, text != self.partial {
                    self.partial = text
                    self.lastChange = Date()
                    self.onPartial?(text)
                }
                if final { self.finishUtterance() }
                // 1110: nothing was said; 301/216: cancelled. Start listening again.
                else if let failure, failure != 301, failure != 216 { self.restartRecognition() }
            }
        }
    }

    private func tick() {
        guard !partial.isEmpty, Date().timeIntervalSince(lastChange) >= endSilence else { return }
        finishUtterance()
    }

    private func finishUtterance() {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        restartRecognition()
        if !text.isEmpty { onUtterance?(text) }
    }

    var heard: String { partial }

    nonisolated static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = (sum / Float(n)).squareRoot()
        return min(1, rms * 8)
    }
}

/// Speaks sentences one after another as they arrive, through the listener's engine so echo cancellation knows
/// what is playing. `stop()` silences it at once.
@MainActor
final class SentenceSpeaker {
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let synth = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var writing = false
    private var scheduled = 0
    private var generation = 0
    private var connectedFormat: AVAudioFormat?
    var voiceID: String?
    var language = "auto"
    var rate: Double = 1
    var onIdle: (() -> Void)?
    var onStart: (() -> Void)?

    init(engine: AVAudioEngine) {
        self.engine = engine
        engine.attach(player)
    }

    var isSpeaking: Bool { writing || scheduled > 0 || !queue.isEmpty }

    func speak(_ sentence: String) {
        queue.append(sentence)
        pump()
    }

    func stop() {
        generation += 1
        queue = []
        writing = false
        scheduled = 0
        synth.stopSpeaking(at: .immediate)
        player.stop()
    }

    private func pump() {
        guard !writing, !queue.isEmpty else { return }
        let text = queue.removeFirst()
        writing = true
        if scheduled == 0 { onStart?() }
        let gen = generation
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(id: voiceID, for: text, language: language)
        utterance.rate = Float(min(Double(AVSpeechUtteranceMaximumSpeechRate),
                                   Double(AVSpeechUtteranceDefaultSpeechRate) * min(2, max(0.5, rate))))
        synth.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            let copy = Self.floatCopy(pcm)
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if pcm.frameLength == 0 {
                    self.writing = false
                    self.pump()
                    self.checkIdle()
                    return
                }
                if let copy { self.schedule(copy, gen: gen) }
            }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, gen: Int) {
        if connectedFormat != buffer.format {
            player.stop()
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            connectedFormat = buffer.format
        }
        scheduled += 1
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.scheduled -= 1
                self.checkIdle()
            }
        }
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
    }

    private func checkIdle() {
        if !isSpeaking { onIdle?() }
    }

    /// The synthesizer hands out 16-bit buffers; the mixer wants floats.
    nonisolated static func floatCopy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard b.frameLength > 0 else { return nil }
        if b.format.commonFormat == .pcmFormatFloat32, !b.format.isInterleaved { return b }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: b.format.sampleRate, channels: b.format.channelCount),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: b.frameLength),
              let conv = AVAudioConverter(from: b.format, to: fmt) else { return nil }
        try? conv.convert(to: out, from: b)
        return out
    }

    /// The chosen voice, else the best installed one for the sentence's language.
    static func voice(id: String?, for text: String, language: String) -> AVSpeechSynthesisVoice? {
        if let id, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        var code = language
        if code == "auto" {
            let r = NLLanguageRecognizer()
            r.languageConstraints = [.danish, .english]
            r.processString(text)
            code = r.dominantLanguage == .danish ? "da-DK" : "en-US"
        }
        return best(for: code)
    }

    static func best(for code: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(code.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        return voices.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: code)
    }

    static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        var r = v.quality.rawValue * 10
        if v.voiceTraits.contains(.isNoveltyVoice) { r -= 100 }
        if v.language.hasPrefix("en-US") || v.language.hasPrefix("da-DK") { r += 1 }
        return r
    }
}
