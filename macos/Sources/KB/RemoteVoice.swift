import Foundation
import KBCore

extension VoiceOutput {
    /// The event a phone gets for this, per docs/remote-api.md; nil for what stays on the Mac.
    func remoteEvent(conversation: String) -> (String, JSONValue)? {
        let c = JSONValue.string(conversation)
        switch self {
        case .sentence(let turn, let index, let text):
            return ("voice.sentence", ["conversation": c, "turn": .string(turn), "index": .number(Double(index)), "text": .string(text)])
        case .done(let turn, let text):
            return ("voice.done", ["conversation": c, "turn": .string(turn), "text": .string(text)])
        case .action(let name, let status, let speech, let data):
            return ("voice.action", ["conversation": c, "name": .string(name), "status": .string(status), "speech": .string(speech), "data": data])
        case .error(let message):
            return ("voice.error", ["conversation": c, "message": .string(message)])
        case .state(let s):
            return ("voice.state", ["conversation": c, "state": .string(s.rawValue)])
        case .transcript(let role, let text, let final):
            return ("voice.transcript", ["conversation": c, "role": .string(role), "text": .string(text), "final": .bool(final)])
        case .clear:
            return ("voice.clear", ["conversation": c])
        case .fallback(let reason, let speech):
            return ("voice.fallback", ["conversation": c, "reason": .string(reason.rawValue), "speech": .string(speech)])
        case .userSaid:
            return nil
        }
    }
}

extension AppModel {
    func remoteVoice(_ method: String, _ p: JSONValue, from client: RemoteClient) async throws -> JSONValue? {
        switch method {
        case "voice.config":
            return VoicePreferences.load().remoteConfig(engine: voiceEngineChoice.engine())

        case "voice.start":
            let force = p["engine"]?.string == VoiceEngineKind.keyless.rawValue
            let engine = voiceEngineChoice.engine(forceKeyless: force)
            let c = await startVoiceConversation(scope: p["scope"]?.string, engine: engine)
            c.owner = ObjectIdentifier(client)
            c.listen { [weak client] out in
                guard let client, let (name, data) = out.remoteEvent(conversation: c.id) else { return }
                client.send(.event(name: name, data: data))
            }
            if engine == .api {
                startRealtime(c) { [weak client] audio in
                    client?.sendBinary(RemoteFrame(header: ["kind": "voice", "conversation": .string(c.id), "format": "pcm24k",
                                                            "seq": .number(Double(audio.seq))], payload: audio.pcm).encoded())
                }
            }
            return ["conversation": .string(c.id), "engine": .string(c.engine.rawValue)]

        case "voice.say":
            guard let c = voiceConversation(p), let text = p["text"]?.string, !text.isEmpty else { throw RemoteError.badParams("conversation and text") }
            let turn = await voiceSay(text, in: c)
            return ["turn": .string(turn)]

        case "voice.interrupt":
            guard let c = voiceConversation(p) else { throw RemoteError.badParams("conversation") }
            c.interrupt()
            realtimeRelays[c.id]?.interrupt()
            return ["stopped": true]

        case "voice.end":
            guard let c = voiceConversation(p) else { return ["ended": true] }
            endVoiceConversation(c.id)
            return ["ended": true]

        default:
            return nil
        }
    }

    private func voiceConversation(_ p: JSONValue) -> VoiceConversation? {
        p["conversation"]?.string.flatMap { voiceConversations[$0] }
    }

    /// Microphone audio from a phone, for its API-engine conversation.
    func remoteVoiceAudio(_ frame: RemoteFrame, from client: RemoteClient) {
        guard let id = frame.header["conversation"]?.string, let c = voiceConversations[id], c.owner == ObjectIdentifier(client) else { return }
        realtimeRelays[id]?.sendAudio(frame.payload)
    }

    /// A phone went away: end the conversations it was having.
    func remoteClientClosed(_ client: RemoteClient) {
        for c in voiceConversations.values where c.owner == ObjectIdentifier(client) { endVoiceConversation(c.id) }
    }
}

extension AppModel {
    func remoteBinary(_ frame: RemoteFrame, from client: RemoteClient) {
        switch frame.kind {
        case "voice": remoteVoiceAudio(frame, from: client)
        case "screen": remoteMeetingScreen(frame, from: client)
        default: break
        }
    }

    func remoteMeetingScreen(_ frame: RemoteFrame, from client: RemoteClient) {
        guard let raw = frame.header["meeting"]?.string, let id = EntryID(raw), let c = meetingControllers[id] else { return }
        c.showRemotePicture(frame.payload)
    }

    func remoteCallTest(_ method: String, _ p: JSONValue, from client: RemoteClient) async throws -> JSONValue? {
        try await remoteTest(method, p, from: client)
    }
}
