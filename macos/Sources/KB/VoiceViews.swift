import AVFoundation
import KBCore
import KBEngine
import SwiftUI

/// Talk to Mindmill: the same abilities as the phone's voice screen.
struct VoiceWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let voice = model.voiceMode
        VStack(spacing: 0) {
            VoiceHeader(voice: voice)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let lines = voice.conversation?.lines, !lines.isEmpty {
                            ForEach(lines) { VoiceLineView(line: $0).id($0.id) }
                        } else {
                            ListEmptyState(title: voice.isOn ? "Listening" : "Talk to \(Brain.name)", systemImage: "waveform",
                                           message: voice.isOn ? "Ask what needs you, about a work item, or to pause a factory." :
                                            "Anything in Mindmill by voice: facts, meetings, follow-ups, the backlog and factories.") { EmptyView() }
                        }
                        if !voice.heard.isEmpty {
                            Text(voice.heard).foregroundStyle(.secondary).italic().frame(maxWidth: .infinity, alignment: .trailing)
                                .id("heard")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
                }
                .onChange(of: voice.conversation?.lines.count) { _, _ in
                    if let last = voice.conversation?.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if let notice = voice.notice {
                NoticeBar(text: notice, seconds: 12) {}
            }
            Divider()
            VoiceControls(voice: voice)
        }
        .frame(minWidth: 340, minHeight: 420)
        .onDisappear { voice.stop() }
    }
}

private struct VoiceHeader: View {
    let voice: MacVoiceMode

    var body: some View {
        HStack(spacing: 12) {
            Pulsing(active: voice.phase == .listening || voice.phase == .thinking, duration: 0.9) { on in
                Circle()
                    .fill(color.opacity(on ? 0.9 : 0.55))
                    .frame(width: 18 + CGFloat(voice.level) * 14, height: 18 + CGFloat(voice.level) * 14)
                    .frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var color: Color {
        switch voice.phase {
        case .listening: return .green
        case .thinking: return .orange
        case .speaking: return .blue
        case .failed: return .red
        default: return .secondary
        }
    }

    private var title: String {
        switch voice.phase {
        case .off: return "Voice is off"
        case .starting: return "Starting…"
        case .listening: return voice.muted ? "Muted" : "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .failed: return "Voice stopped"
        }
    }

    private var detail: String {
        if case .failed(let why) = voice.phase { return why }
        guard let c = voice.conversation else { return "Built-in speech on this Mac, \(Brain.name) as the brain." }
        let engine = c.engine == .api ? (RealtimeProvider.with(id: VoicePreferences.load().provider)?.name ?? "Voice API") : "Built-in voice"
        return voice.phase == .speaking ? "\(engine). Just talk to interrupt." : engine
    }
}

private struct VoiceLineView: View {
    let line: VoiceConversation.Line

    var body: some View {
        switch line.role {
        case .user:
            Text(line.text).padding(8).background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15)))
                .frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled)
        case .assistant:
            Text(line.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        case .action:
            Label(line.text, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Label(line.text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .status:
            Text(line.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct VoiceControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Bindable var voice: MacVoiceMode

    var body: some View {
        ChipRow(spacing: 8) {
            if voice.isOn {
                Button { voice.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .keyboardShortcut(.escape, modifiers: [])
                Toggle(isOn: $voice.muted) { Label("Mute", systemImage: "mic.slash") }.toggleStyle(.button)
                if voice.phase == .speaking || voice.phase == .thinking {
                    Button { voice.interrupt() } label: { Label("Interrupt", systemImage: "hand.raised") }
                }
            } else {
                Button { Task { await voice.start(model) } } label: { Label("Start Talking", systemImage: "waveform") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
            Button { SettingsPane.voice.select(); openSettings() } label: { Label("Voice Settings…", systemImage: "slider.horizontal.3") }
                .buttonStyle(.borderless)
        }
        .padding(10)
    }
}

/// A microphone button for a prompt: talk, and the words go into the field; click again to send.
struct DictationButton: View {
    @Binding var text: String
    var onSend: () -> Void
    @State private var listener: SpeechListener?
    @State private var level: Float = 0
    @State private var base = ""
    @State private var problem: String?

    var body: some View {
        Button(action: toggle) {
            Image(systemName: listener == nil ? "mic" : "mic.fill")
                .foregroundStyle(listener == nil ? Color.secondary : Color.red)
                .scaleEffect(1 + CGFloat(level) * 0.3)
        }
        .buttonStyle(.borderless)
        .help(problem ?? (listener == nil ? "Dictate: talk, and click again to send" : "Click to send what you said"))
        .onDisappear { listener?.stop(); listener = nil }
    }

    private func toggle() {
        if let l = listener {
            let rest = l.heard
            l.stop()
            listener = nil
            level = 0
            if !rest.isEmpty { text = join(text, rest) }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSend() }
            return
        }
        Task {
            if let p = await SpeechListener.authorize() { problem = p; return }
            let l = SpeechListener()
            l.endSilence = 2.5
            base = text
            l.onPartial = { partial in text = join(base, partial) }
            l.onUtterance = { said in
                base = join(base, said)
                text = base
            }
            l.onLevel = { level = $0 }
            do {
                try l.start(language: VoicePreferences.load().language, voiceProcessing: false)
                listener = l
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : a.hasSuffix(" ") || a.hasSuffix("\n") ? a + b : a + " " + b
    }
}

/// Settings → Voice: engine, voice and speed, confirmation, and the keys for the API engine.
struct VoiceSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var prefs = VoicePreferences.load()
    @State private var showAllProviders = false
    private let sample = AVSpeechSynthesizer()

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $prefs.engine) {
                    Text("Built-in (no setup)").tag(VoiceEngineKind.keyless)
                    Text("Voice API (smoother)").tag(VoiceEngineKind.api)
                }
                .pickerStyle(.radioGroup)
                Text(prefs.engine == .api && !hasActiveKey
                     ? "Add a key below and choose it with Use. Until then, the built-in voice is used."
                     : "Built-in recognises speech on this Mac or phone and speaks with the system voices; \(Brain.name) does the thinking. A voice API answers faster and sounds more natural, and falls back to built-in if it fails.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("How it talks") {
                Picker("Voice", selection: $prefs.macVoice) {
                    Text("Best installed voice").tag(String?.none)
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name) (\(Locale.current.localizedString(forIdentifier: v.language) ?? v.language))\(quality(v))").tag(String?.some(v.identifier))
                    }
                }
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $prefs.rate, in: 0.5...2, step: 0.1)
                        Text(prefs.rate.formatted(.number.precision(.fractionLength(1))) + "×").monospacedDigit().frame(width: 40)
                    }
                }
                Picker("Language", selection: $prefs.language) {
                    Text("Automatic").tag("auto")
                    Text("Dansk").tag("da-DK")
                    Text("English").tag("en-US")
                }
                HStack {
                    Button("Try It") { trySample() }
                    if !hasEnhancedVoice {
                        Button("Get Better Voices…") { openSpokenContent() }
                            .help("System Settings → Accessibility → Spoken Content → System Voice → Manage Voices: download an Enhanced or Premium voice")
                    }
                }
                if !hasEnhancedVoice {
                    Text("Enhanced and Premium voices sound much more natural. Download them in System Settings → Accessibility → Spoken Content → System voice → Manage Voices.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Safety") {
                Toggle("Ask out loud before stopping factories or writing to the tracker", isOn: $prefs.confirmsRisky)
                Toggle("Stop speaking when I start talking", isOn: $prefs.bargeIn)
            }
            Section("Voice API keys") {
                Text("Keys are stored in this Mac's Keychain and never leave it. The phone's voice goes through this Mac, and a paired phone can send a key here too.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(RealtimeProvider.all.filter { $0.available || showAllProviders }) { p in
                    ProviderKeyRow(provider: p, prefs: $prefs)
                }
                Button(showAllProviders ? "Fewer Providers" : "More Providers…") { showAllProviders.toggle() }
                    .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs) { _, new in
            new.save()
            model.actions.confirmsRisky = new.confirmsRisky
        }
    }

    private var hasActiveKey: Bool { prefs.provider.map { VoiceKeychain.has(provider: $0) } ?? false }

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { ($0.language.hasPrefix("da") || $0.language.hasPrefix("en")) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    private var hasEnhancedVoice: Bool { voices.contains { $0.quality != .default } }

    private func quality(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return " · Premium"
        case .enhanced: return " · Enhanced"
        default: return ""
        }
    }

    private func trySample() {
        let text = prefs.language == "da-DK" ? "Hej. Sådan lyder jeg, når jeg læser dine svar op." : "Hi. This is how I sound when I read your replies."
        let u = AVSpeechUtterance(string: text)
        u.voice = SentenceSpeaker.voice(id: prefs.macVoice, for: text, language: prefs.language)
        u.rate = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * prefs.clampedRate)
        sample.stopSpeaking(at: .immediate)
        sample.speak(u)
    }

    private func openSpokenContent() {
        for raw in ["x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
                    "x-apple.systempreferences:com.apple.preference.universalaccess?SpeechSettings"] {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }
}

private struct ProviderKeyRow: View {
    let provider: RealtimeProvider
    @Binding var prefs: VoicePreferences
    @State private var entry = ""
    @State private var saved = false
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.name).font(.headline)
                if !provider.available { Text(provider.note).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if saved {
                    if prefs.provider == provider.id {
                        Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    } else if provider.available {
                        Button("Use") { prefs.provider = provider.id; prefs.engine = .api }
                    }
                }
            }
            if saved {
                ChipRow(spacing: 8) {
                    Text("Key saved").font(.callout).foregroundStyle(.secondary)
                    Button(testing ? "Testing…" : "Test Key") { test() }.disabled(testing)
                    Button("Remove", role: .destructive) {
                        VoiceKeychain().set(nil, provider: provider.id)
                        saved = false
                        result = nil
                        if prefs.provider == provider.id { prefs.provider = nil; prefs.engine = .keyless }
                    }
                }
                if provider.available {
                    Picker("Model", selection: Binding(get: { prefs.model(for: provider.id) }, set: { prefs.models[provider.id] = $0 })) {
                        ForEach(provider.models, id: \.self) { Text($0).tag($0) }
                    }
                    if !provider.voices.isEmpty {
                        Picker("Voice", selection: Binding(get: { prefs.apiVoice(for: provider.id) }, set: { prefs.apiVoices[provider.id] = $0 })) {
                            ForEach(provider.voices, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
            } else {
                HStack {
                    SecureField("API key", text: $entry).textFieldStyle(.roundedBorder)
                    Button("Save") {
                        VoiceKeychain().set(entry.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider.id)
                        entry = ""
                        saved = true
                        if provider.available, prefs.provider == nil || prefs.engine == .keyless {
                            prefs.provider = provider.id
                            prefs.engine = .api
                        }
                        test()
                    }
                    .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Link("Get a key", destination: URL(string: provider.keyPage)!).font(.caption)
            }
            if let result {
                Label(result, systemImage: RealtimeKeyTest.passed(result) ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(RealtimeKeyTest.passed(result) ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .onAppear { saved = VoiceKeychain.has(provider: provider.id) }
    }

    private func test() {
        guard let key = VoiceKeychain().key(provider: provider.id) else { return }
        testing = true
        Task {
            result = await RealtimeKeyTest.test(provider: provider.id, key: key)
            testing = false
        }
    }
}
