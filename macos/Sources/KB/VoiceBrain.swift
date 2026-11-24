import Foundation
import KBCore
import KBEngine

/// The voice brain lives in the engine (EngineVoice.swift); the Mac's voice mode reaches it through these.
extension AppModel {
    func startVoiceConversation(scope: String?, engine kind: VoiceEngineKind? = nil) async -> VoiceConversation {
        await engine.startVoiceConversation(scope: scope, engine: kind)
    }

    func voiceSay(_ text: String, in c: VoiceConversation) async -> String { await engine.voiceSay(text, in: c) }

    func endVoiceConversation(_ id: String) { engine.endVoiceConversation(id) }

    func startRealtime(_ c: VoiceConversation, audioOut: @escaping (RealtimeRelay.Audio) -> Void) {
        engine.startRealtime(c, audioOut: audioOut)
    }

    var voiceEngineChoice: VoiceEngineChoice { engine.voiceEngineChoice }
}
