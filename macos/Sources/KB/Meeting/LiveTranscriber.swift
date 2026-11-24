import KBCore
import KBEngine
import AVFoundation
import CoreMedia
import NaturalLanguage
@preconcurrency import ScreenCaptureKit
import Speech
import SwiftUI

/// On-device live transcription of a meeting: the microphone as "You" (or "Room" alone) and the computer's
/// audio (the call) as "Others". Audio never leaves the Mac and is never stored; only the text is kept.
@MainActor
@Observable
final class LiveTranscriber {
    struct Segment: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let speaker: String
        let text: String
        /// `da`, `en`: the language the line was recognised in.
        let language: String
    }

    enum State: Equatable {
        case off, starting, running
        case failed(String, settings: Bool)
    }

    /// The last failure was the screen-recording permission, so the panel offers to reset it.
    private(set) var screenPermissionMissing = false
    /// A source that could not start while the other runs, e.g. the call's audio without the microphone.
    private(set) var warning: String?
    /// How loud each source is right now, 0…1, so the user sees that sound arrives.
    private(set) var level: [String: Float] = [:]
    /// The recogniser's last complaint per source, cleared when it recognises words again.
    private(set) var problem: [String: String] = [:]
    /// The sources that are running, in display order.
    private(set) var sources: [String] = []

    private(set) var state: State = .off
    /// The words recognised so far in each channel's current utterance.
    private(set) var partial: [String: String] = [:]
    /// The language of the last line heard, in auto mode.
    private(set) var heard: String?
    /// The languages being listened for, after the ones without on-device recognition are dropped.
    private(set) var listening: [String] = []
    @ObservationIgnored var onSegment: ((Segment) -> Void)?
    /// Recognised pieces not yet shown as a line: the recogniser ends a piece at every breath, so pieces are joined
    /// until the sentence ends or the speaker stops.
    private(set) var pending: [String: SentenceAssembler] = [:]

    @ObservationIgnored private var channels: [SpeechChannel] = []
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: SystemAudioOutput?
    @ObservationIgnored private var ticker: Timer?

    var isOn: Bool { state == .running || state == .starting }

    static let auto = "auto"
    static let languages: [(id: String, name: String)] = [(auto, "Auto"), ("da-DK", "Dansk"), ("en-US", "English")]

    static func name(_ code: String) -> String {
        switch code.prefix(2) {
        case "da": return "Dansk"
        case "en": return "English"
        default: return code
        }
    }

    /// `auto` listens for Danish and English at once and keeps, per utterance, the one that fits.
    func start(locale: String, microphone: Bool, computerAudio: Bool) async {
        guard !isOn else { return }
        state = .starting
        heard = nil
        screenPermissionMissing = false
        warning = nil
        problem = [:]
        level = [:]
        guard microphone || computerAudio else { return fail("Choose the microphone, the computer's audio, or both.") }
        guard await Self.speechAuthorized() else {
            return fail("Mindmill may not use speech recognition. Allow it in System Settings → Privacy & Security → Speech Recognition.", settings: true)
        }
        let wanted = locale == Self.auto ? Self.languages.map(\.id).filter { $0 != Self.auto } : [locale]
        let locales = wanted.filter { SFSpeechRecognizer(locale: Locale(identifier: $0))?.supportsOnDeviceRecognition == true }
        guard !locales.isEmpty else {
            return fail("On-device recognition for \(wanted.map(Self.name).joined(separator: " and ")) isn't installed. Add the language under System Settings → General → Keyboard → Dictation, then try again.", settings: false)
        }
        listening = locales
        var started: [SpeechChannel] = []
        if microphone {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                return fail("Mindmill may not use the microphone. Allow it in System Settings → Privacy & Security → Microphone.", settings: true)
            }
            let mic = makeChannel(computerAudio ? "You" : "Room", locales: locales)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in mic.append(buffer) }
            do {
                engine.prepare()
                try engine.start()
            } catch {
                return fail("Could not start the microphone: \(error.localizedDescription)")
            }
            self.engine = engine
            started.append(mic)
        }
        if computerAudio {
            let others = makeChannel("Others", locales: locales)
            do {
                try await startSystemAudio(into: others)
                started.append(others)
            } catch {
                let denied = !CGPreflightScreenCaptureAccess()
                if denied { CGRequestScreenCaptureAccess() }
                screenPermissionMissing = denied
                let message = denied
                    ? "Mindmill may not record the computer's audio, so the call isn't transcribed. Allow Mindmill under System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Mindmill."
                    : "Could not capture the computer's audio: \(error.localizedDescription)"
                // The microphone still works: keep it running rather than lose the whole meeting.
                guard !started.isEmpty else {
                    stopAudio()
                    return fail(message, settings: denied)
                }
                warning = message
            }
        }
        sources = started.map(\.speaker)
        channels = started
        channels.forEach { $0.begin() }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.channels.forEach { $0.tick() }
                self.flushPending(now: Date())
            }
        }
        state = .running
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        channels.forEach { $0.finish() }
        channels = []
        flushPending(now: nil)
        stopAudio()
        partial = [:]
        level = [:]
        if isOn { state = .off }
    }

    func dismissError() {
        if case .failed = state { state = .off }
        warning = nil
    }

    private func fail(_ message: String, settings: Bool = false) {
        stop()
        state = .failed(message, settings: settings)
    }

    private func stopAudio() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        output = nil
    }

    private func emit(_ line: SentenceAssembler.Line, _ speaker: String) {
        onSegment?(Segment(time: line.started, speaker: speaker, text: line.text, language: line.language))
    }

    /// Ends the waiting lines whose speaker has stopped; `nil` ends them all.
    private func flushPending(now: Date?) {
        for speaker in pending.keys {
            guard var a = pending[speaker] else { continue }
            // A sentence in progress keeps its line open.
            let speaking = partial[speaker] != nil
            if let line = now.map({ speaking ? nil : a.due(at: $0) }) ?? a.flush() { emit(line, speaker) }
            pending[speaker] = a
        }
    }

    /// What was said but not yet shown as a line, then what is being said now.
    func live(_ speaker: String) -> String? {
        let text = [pending[speaker]?.text ?? "", partial[speaker] ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private func makeChannel(_ speaker: String, locales: [String]) -> SpeechChannel {
        SpeechChannel(speaker: speaker, locales: locales.map { Locale(identifier: $0) },
                      onPartial: { [weak self] text in
                          MainActor.assumeIsolated {
                              self?.partial[speaker] = text.isEmpty ? nil : text
                              if !text.isEmpty { self?.problem[speaker] = nil }
                          }
                      },
                      onLevel: { [weak self] value in
                          MainActor.assumeIsolated {
                              guard let self, self.isOn else { return }
                              self.level[speaker] = value
                          }
                      },
                      onError: { [weak self] message in
                          MainActor.assumeIsolated { self?.problem[speaker] = message }
                      },
                      onFinal: { [weak self] text, language in
                          MainActor.assumeIsolated {
                              guard let self else { return }
                              self.partial[speaker] = nil
                              self.problem[speaker] = nil
                              if locales.count > 1 { self.heard = language }
                              var a = self.pending[speaker] ?? SentenceAssembler()
                              if let line = a.add(text, language: language, at: Date()) { self.emit(line, speaker) }
                              // A last piece that arrives after Stop has no ticker left to end its line.
                              if !self.isOn, let line = a.flush() { self.emit(line, speaker) }
                              self.pending[speaker] = a
                          }
                      })
    }

    private func startSystemAudio(into channel: SpeechChannel) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw TranscriberError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        let output = SystemAudioOutput(channel: channel)
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
    }

    private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        }
    }

    enum TranscriberError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display to capture audio from." }
    }
}

/// Feeds the call's audio from ScreenCaptureKit to a channel. Screen frames are requested at 1 fps, 2×2 px, and dropped.
final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "kb.transcriber.audio")
    let channel: SpeechChannel

    init(channel: SpeechChannel) { self.channel = channel }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        channel.append(sampleBuffer)
    }
}

/// One speaker channel: a chain of on-device recognition requests, cut into utterances at pauses. With more than
/// one language, every utterance is recognised in each and the best fitting result is kept.
/// Audio arrives on audio threads; results arrive on Speech's queue; `tick` runs on the main thread.
final class SpeechChannel: @unchecked Sendable {
    let speaker: String
    private let recognizers: [(code: String, recognizer: SFSpeechRecognizer)]
    private let onPartial: (String) -> Void
    private let onFinal: (String, String) -> Void
    private let onLevel: (Float) -> Void
    private let onError: (String) -> Void
    private let lock = NSLock()
    private var levelPeak: Float = 0
    private var levelReported = Date.distantPast
    /// The language heard last: its partial text is shown, and it wins close calls.
    private var preferred = 0

    private final class Hypothesis {
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        /// Words from before the recogniser started over.
        var carried = ""
        var chunk = ""
        var chunkStart: TimeInterval?
        var confidence: Float = 0
        var ended = false
        var text: String { [carried, chunk].filter { !$0.isEmpty }.joined(separator: " ") }

        /// After a pause the on-device recogniser drops what it heard and reports only the words after it; a
        /// revision of the same words starts at the same time. Returns whether the text changed.
        func update(_ transcription: SFTranscription) -> Bool {
            let new = transcription.formattedString
            let start = transcription.segments.first?.timestamp
            if !chunk.isEmpty, let start, let old = chunkStart, start > old + 0.8 {
                carried = [carried, chunk].filter { !$0.isEmpty }.joined(separator: " ")
                chunk = ""
            }
            guard new != chunk else { return false }
            chunk = new
            chunkStart = start ?? chunkStart
            return true
        }
    }

    private final class Utterance {
        var hyps: [Hypothesis] = []
        var lastChange = Date()
        let started = Date()
        var cutAt: Date?
        var committed = false
        var spoke: Bool { hyps.contains { !$0.text.isEmpty } }
        var allEnded: Bool { hyps.allSatisfy(\.ended) }
    }

    private var current: Utterance?
    private var ending: [Utterance] = []
    private var finished = false

    /// A pause this long ends an utterance; utterances are also cut at this length so none grows unbounded.
    static let pause: TimeInterval = 2
    static let maxLength: TimeInterval = 40

    init(speaker: String, locales: [Locale], onPartial: @escaping (String) -> Void,
         onLevel: @escaping (Float) -> Void = { _ in }, onError: @escaping (String) -> Void = { _ in },
         onFinal: @escaping (String, String) -> Void) {
        self.speaker = speaker
        recognizers = locales.compactMap { l in
            SFSpeechRecognizer(locale: l).map { (String(l.identifier.prefix(2)), $0) }
        }
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onLevel = onLevel
        self.onError = onError
    }

    func begin() {
        guard !recognizers.isEmpty else { return }
        let u = Utterance()
        for (index, r) in recognizers.enumerated() {
            let h = Hypothesis()
            h.request.requiresOnDeviceRecognition = true
            h.request.shouldReportPartialResults = true
            h.request.addsPunctuation = true
            h.request.taskHint = .dictation
            u.hyps.append(h)
            h.task = r.recognizer.recognitionTask(with: h.request) { [weak self, weak u, weak h] result, error in
                guard let self, let u, let h else { return }
                if let result {
                    let (show, text): (Bool, String) = self.lock.withLock {
                        if h.update(result.bestTranscription) { u.lastChange = Date() }
                        if result.isFinal {
                            h.ended = true
                            let segments = result.bestTranscription.segments
                            h.confidence = segments.isEmpty ? 0 : segments.map(\.confidence).reduce(0, +) / Float(segments.count)
                        }
                        guard self.current === u else { return (false, h.text) }
                        // The language heard last speaks for the line, unless it hears nothing at all.
                        return (index == self.preferred || self.recognizers.count == 1 || u.hyps[self.preferred].text.isEmpty, h.text)
                    }
                    if show { DispatchQueue.main.async { self.onPartial(text) } }
                }
                if let error {
                    self.lock.withLock { h.ended = true }
                    if let message = Self.complaint(error) { DispatchQueue.main.async { self.onError(message) } }
                }
                guard result?.isFinal == true || error != nil else { return }
                let (done, restart, quick): (Bool, Bool, Bool) = self.lock.withLock {
                    (u.allEnded, u.allEnded && self.current === u && !self.finished,
                     error != nil && !u.spoke && Date().timeIntervalSince(u.started) < 2)
                }
                if done { self.commit(u) }
                // Silence or a recognizer hiccup ends the current request; keep listening. A request that fails at
                // once (dictation off, model missing) would fail again at once, so wait a little before retrying.
                if restart { DispatchQueue.main.asyncAfter(deadline: .now() + (quick ? 2 : 0)) { self.begin() } }
            }
        }
        lock.withLock { current = u }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if let data = buffer.floatChannelData, buffer.frameLength > 0 {
            measure(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        lock.withLock { current?.hyps.forEach { $0.request.append(buffer) } }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        measure(sampleBuffer)
        lock.withLock { current?.hyps.forEach { $0.request.appendAudioSampleBuffer(sampleBuffer) } }
    }

    private func measure(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return }
        var list = AudioBufferList()
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr, let data = list.mBuffers.mData else { return }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        withExtendedLifetime(block) {
            measure(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
    }

    /// Reports the loudest stretch of the last tenth of a second, on a 0…1 scale from -55 dB to -5 dB.
    private func measure(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let value = min(1, max(0, (db + 55) / 50))
        let report: Float? = lock.withLock {
            levelPeak = max(levelPeak, value)
            guard Date().timeIntervalSince(levelReported) > 0.1 else { return nil }
            levelReported = Date()
            defer { levelPeak = 0 }
            return levelPeak
        }
        if let report { DispatchQueue.main.async { self.onLevel(report) } }
    }

    /// What to tell the user about a recognition error; nil for the ones that only mean silence or a cancelled request.
    static func complaint(_ error: Error) -> String? {
        let e = error as NSError
        if e.domain == "kAFAssistantErrorDomain", [203, 216, 301, 1110].contains(e.code) { return nil }
        if e.domain == NSCocoaErrorDomain, e.code == NSUserCancelledError { return nil }
        if e.localizedDescription.localizedCaseInsensitiveContains("no speech") { return nil }
        if e.localizedDescription.localizedCaseInsensitiveContains("canceled") || e.localizedDescription.localizedCaseInsensitiveContains("cancelled") { return nil }
        return e.localizedDescription
    }

    /// Ends the utterance at a pause or at its maximum length, and starts the next one at once.
    func tick() {
        let now = Date()
        var cut: Utterance?
        var stale: [Utterance] = []
        lock.withLock {
            if let u = current {
                if (u.spoke && now.timeIntervalSince(u.lastChange) > Self.pause) || now.timeIntervalSince(u.started) > Self.maxLength {
                    u.cutAt = now
                    ending.append(u)
                    current = nil
                    cut = u
                }
            }
            stale = ending.filter { ($0.cutAt.map { now.timeIntervalSince($0) > 3 } ?? false) && !$0.committed }
            ending.removeAll { u in u.committed || stale.contains { $0 === u } }
        }
        if let cut {
            cut.hyps.forEach { $0.request.endAudio() }
            begin()
        }
        for u in stale {
            commit(u)
            u.hyps.forEach { $0.task?.cancel() }
        }
    }

    func finish() {
        let all: [Utterance] = lock.withLock {
            finished = true
            let list = (current.map { [$0] } ?? []) + ending
            current = nil
            ending = []
            return list
        }
        for u in all {
            u.hyps.forEach { $0.request.endAudio() }
            commit(u)
            u.hyps.forEach { $0.task?.cancel() }
        }
    }

    private func commit(_ u: Utterance) {
        let picked: (String, String)? = lock.withLock {
            guard !u.committed else { return nil }
            u.committed = true
            let texts = u.hyps.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            let candidates = texts.indices.filter { !texts[$0].isEmpty }
            guard !candidates.isEmpty else { return nil }
            let best = candidates.count == 1 ? candidates[0] : candidates.max { a, b in
                score(a, text: texts[a], u) < score(b, text: texts[b], u)
            }!
            preferred = best
            return (texts[best], recognizers[best].code)
        }
        guard let (text, language) = picked else { return }
        DispatchQueue.main.async { self.onFinal(text, language) }
    }

    /// How well a recogniser's text fits its language: the recogniser's confidence (low when the speech was in
    /// another language), whether the words read as that language, and a nudge toward the language heard last.
    private func score(_ index: Int, text: String, _ u: Utterance) -> Double {
        let h = u.hyps[index]
        let code = recognizers[index].code
        let nl = NLLanguageRecognizer()
        nl.languageConstraints = recognizers.map { NLLanguage(rawValue: $0.code) }
        nl.processString(text)
        let fit = nl.languageHypotheses(withMaximum: recognizers.count)[NLLanguage(rawValue: code)] ?? 0
        let confidence = h.confidence > 0 ? Double(h.confidence) : 0.4
        let words = text.split(separator: " ").count
        // A few words say little about the language: lean on what was heard last.
        let stick = index == preferred ? (words <= 3 ? 0.25 : 0.08) : 0
        return 0.55 * confidence + 0.45 * fit + stick
    }
}

extension LiveTranscriber {
    /// Clears Mindmill's screen-recording entry, which can go stale after KB is rebuilt: System Settings still shows
    /// KB as allowed, but the grant belongs to the old build. macOS then asks again; KB must be reopened after.
    static func resetScreenPermission() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "dk.langkilde.kb"]
        try? p.run()
        p.waitUntilExit()
        CGRequestScreenCaptureAccess()
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
