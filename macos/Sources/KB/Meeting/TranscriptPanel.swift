import AppKit
import KBCore
import KBEngine
import SwiftUI

/// The live transcript beside the notes: the speech-to-text lines, what is being heard now, and Claude's flags.
struct TranscriptPanel: View {
    @Bindable var c: MeetingController
    var onHide: () -> Void
    @AppStorage(AppSettingsKeys.transcriptMicrophone) private var microphone = true
    @AppStorage(AppSettingsKeys.transcriptComputerAudio) private var computerAudio = true

    var body: some View {
        let t = c.transcriber
        VStack(alignment: .leading, spacing: 0) {
            header(t)
            if case .failed(let message, let settings) = t.state {
                failure(message, settings: settings, t)
            } else if let warning = t.warning, t.isOn {
                failure(warning, settings: t.screenPermissionMissing, t)
            }
            Divider()
            if t.isOn || c.screen.isOn || !c.transcript.isEmpty {
                lines
                if t.isOn {
                    Divider()
                    LiveCaption(t: t)
                }
            } else {
                Text("Turn the meeting audio into text on this Mac, and read along with a window such as the shared slides. \(Brain.name) reads both next to your notes, and at the end you choose which parts go into the summary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.secondary.opacity(0.04))
    }

    private func header(_ t: LiveTranscriber) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Transcript", systemImage: "waveform").font(.callout.weight(.semibold))
                status(t.state)
                Spacer()
                if t.isOn {
                    Button { c.stopTranscription() } label: { Label("Stop", systemImage: "stop.circle") }
                } else {
                    Button { c.startTranscription() } label: { Label("Transcribe", systemImage: "waveform.circle") }
                        .help("Turn the meeting audio into text on this Mac. \(Brain.name) reads it alongside your notes.")
                }
                Button(action: onHide) { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless)
                    .help("Hide the transcript (it keeps running)")
            }
            HStack(spacing: 8) {
                Menu(LiveTranscriber.languages.first { $0.id == c.transcriptLanguage }?.name ?? c.transcriptLanguage) {
                    ForEach(LiveTranscriber.languages, id: \.id) { lang in
                        Button(lang.id == LiveTranscriber.auto ? "Auto: Dansk or English" : lang.name) { c.setTranscriptLanguage(lang.id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Auto listens for Danish and English and keeps, for each sentence, the language that fits")
                if let heard = t.heard, t.isOn {
                    Text("hearing \(LiveTranscriber.name(heard))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Group {
                    Toggle(isOn: $microphone) { Image(systemName: "mic") }
                        .help("Your microphone: you, or the whole room in person")
                    Toggle(isOn: $computerAudio) { Image(systemName: "speaker.wave.2") }
                        .help("What the call plays: the other people in a Teams call")
                }
                .disabled(t.isOn)
            }
            .toggleStyle(.button)
            ScreenRow(c: c)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func failure(_ message: String, settings: Bool, _ t: LiveTranscriber) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { t.dismissError() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            if t.screenPermissionMissing {
                Text("Already on in System Settings? That switch can belong to an older build of Mindmill. Reset it, allow Mindmill when macOS asks, then reopen Mindmill.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Reset Permission") { LiveTranscriber.resetScreenPermission() }
                        .help("Clears Mindmill's Screen & System Audio Recording entry and asks again")
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    Button("Reopen Mindmill") { LiveTranscriber.relaunch() }
                        .help("macOS applies the screen-recording permission only after Mindmill restarts")
                }
                .controlSize(.small)
            } else if settings {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func status(_ state: LiveTranscriber.State) -> some View {
        switch state {
        case .running:
            Circle().fill(Color.red).frame(width: 7, height: 7).help("Transcribing on this Mac")
        case .starting:
            ProgressView().controlSize(.mini)
        default:
            EmptyView()
        }
    }

    private var lines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(c.transcript) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            if startsTurn(line) {
                                HStack(spacing: 6) {
                                    Text(line.speaker).font(.caption.weight(.semibold))
                                        .foregroundStyle(Self.color(line.speaker))
                                    Text(line.time).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                    if !line.language.isEmpty {
                                        Text(line.language.uppercased()).font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 4)
                                            .background(Color.secondary.opacity(0.12), in: Capsule())
                                    }
                                }
                                .padding(.top, 4)
                            }
                            if line.speaker == MeetingController.screenSpeaker {
                                ScreenLine(text: line.text)
                            } else {
                                Text(line.text).font(.callout).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .id(line.id)
                        if let b = line.batch, isLastOfBatch(line), let flags = c.transcriptFlags[b] {
                            ForEach(Array(flags.enumerated()), id: \.offset) { _, f in
                                Text(f.text)
                                    .font(.callout)
                                    .foregroundStyle(f.kind == .warning ? Color.orange : Color.blue)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 10)
                            }
                        }
                    }
                    if c.transcript.isEmpty, c.transcriber.isOn {
                        Text("Lines appear here as each sentence ends. What is being said right now shows below.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: c.transcript.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    /// A speaker label above the first line of each turn, and again after a minute or a change of language.
    private func startsTurn(_ line: TranscriptLineRef) -> Bool {
        guard line.id > 0, line.id - 1 < c.transcript.count else { return true }
        let prev = c.transcript[line.id - 1]
        return prev.speaker != line.speaker || prev.time != line.time || prev.language != line.language
    }

    static func color(_ speaker: String) -> Color {
        switch speaker {
        case "Others": return .indigo
        case MeetingController.screenSpeaker: return .secondary
        default: return .teal
        }
    }

    private func isLastOfBatch(_ line: TranscriptLineRef) -> Bool {
        guard let b = line.batch else { return false }
        return c.transcript.last(where: { $0.batch == b })?.id == line.id
    }
}

typealias TranscriptLineRef = MeetingController.TranscriptLine

/// What is being heard right now, pinned under the transcript: a sound meter per source, so a silent microphone
/// shows at once, and the words of the sentence in progress.
struct LiveCaption: View {
    let t: LiveTranscriber

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ForEach(t.sources, id: \.self) { source in
                    HStack(spacing: 5) {
                        Image(systemName: source == "Others" ? "speaker.wave.2" : "mic")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(source).font(.caption2).foregroundStyle(.secondary)
                        LevelMeter(value: t.level[source] ?? 0)
                    }
                    .help(source == "Others" ? "How loud the call is" : "How loud your microphone is")
                }
                Spacer(minLength: 0)
                if t.state == .starting {
                    Text("Starting…").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ForEach(t.sources.filter { t.problem[$0] != nil }, id: \.self) { source in
                Label("\(source): \(t.problem[source] ?? "")", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let now = t.sources.compactMap { s in t.live(s).map { (s, $0) } }
            if now.isEmpty {
                Text(t.state == .running ? "Listening…" : " ")
                    .font(.callout).italic().foregroundStyle(.tertiary)
            } else {
                ForEach(now, id: \.0) { speaker, text in
                    (Text(t.sources.count > 1 ? "\(speaker)  " : "").font(.caption.weight(.semibold))
                        .foregroundStyle(speaker == "Others" ? Color.indigo : Color.teal)
                     + Text(Self.tail(text)).font(.callout).foregroundStyle(.secondary))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.easeOut(duration: 0.15), value: text)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
    }

    /// The end of a long sentence: the newest words are the ones to check.
    static func tail(_ text: String, words: Int = 40) -> String {
        let all = text.split(separator: " ")
        return all.count <= words ? text : "… " + all.suffix(words).joined(separator: " ")
    }
}

struct LevelMeter: View {
    let value: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Float(i) < value * 5 + 0.15 && value > 0.05 ? Color.green.opacity(0.8) : Color.secondary.opacity(0.18))
                    .frame(width: 4, height: 4 + CGFloat(i) * 2)
            }
        }
        .frame(height: 12, alignment: .bottom)
        .animation(.linear(duration: 0.1), value: value)
    }
}

/// Text read from the watched window: quieter than speech, three lines until clicked.
struct ScreenLine: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(expanded ? nil : 3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .onTapGesture { expanded.toggle() }
            .help(expanded ? "Click to fold" : "Click to show all the text read from the window")
    }
}
