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

    /// At the Mac, the user is there to answer macOS's password prompt for the key, so it waits longer.
    func startRealtime(_ c: VoiceConversation, audioOut: @escaping (RealtimeRelay.Audio) -> Void) async {
        await engine.startRealtime(c, keyWait: 60, audioOut: audioOut)
    }

    var voiceEngineChoice: VoiceEngineChoice { engine.voiceEngineChoice }
}
