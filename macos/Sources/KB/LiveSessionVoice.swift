import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    /// Whether live talk goes through a voice API (needed to talk live in a session).
    var liveVoiceAvailable: Bool {
        _ = voiceRevision
        return engine.voiceEngineChoice.engine() == .api
    }

    /// Which voice the next conversation uses, in words.
    var voiceEngineName: String {
        _ = voiceRevision
        if engine.voiceEngineChoice.engine() == .api, let p = RealtimeProvider.with(id: VoicePreferences.load().provider) { return p.name }
        return "built-in speech on this Mac"
    }

    func startLiveVoice(in s: WorkSession) {
        Task { await voiceMode.start(self, in: s) }
    }
}

/// In a session, above the message field: live talk's state, what it heard, which voice is used, and Stop.
struct SessionLiveBar: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession

    var body: some View {
        let voice = model.voiceMode
        if voice.sessionID == session.id || (voice.sessionID == nil && isFailedHere(voice)) {
            HStack(alignment: .top, spacing: 10) {
                Pulsing(active: voice.phase == .listening, duration: 0.9) { on in
                    Circle().fill(color(voice).opacity(on ? 0.9 : 0.5)).frame(width: 12, height: 12)
                }
                .padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(voice)).font(.callout.weight(.medium))
                    if !voice.heard.isEmpty {
                        Text(voice.heard).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(model.voiceEngineName).font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if voice.isOn {
                    Toggle(isOn: Binding(get: { voice.muted }, set: { voice.muted = $0 })) { Image(systemName: "mic.slash") }
                        .toggleStyle(.button)
                        .help("Mute")
                    Button("Stop") { voice.stop() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color(voice).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private func isFailedHere(_ v: MacVoiceMode) -> Bool {
        if case .failed = v.phase { return model.selectedSessionID == session.id || model.buildSelection == session.id }
        return false
    }

    private func color(_ v: MacVoiceMode) -> Color {
        switch v.phase {
        case .listening: return .green
        case .thinking: return .orange
        case .speaking: return .blue
        case .failed: return .red
        default: return .secondary
        }
    }

    private func title(_ v: MacVoiceMode) -> String {
        switch v.phase {
        case .off: return "Live talk ended"
        case .starting: return "Starting…"
        case .listening: return v.muted ? "Muted" : "Listening…"
        case .thinking: return "Working on it…"
        case .speaking: return "Speaking · just talk to interrupt"
        case .failed(let why): return why
        }
    }
}
