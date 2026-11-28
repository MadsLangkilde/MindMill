import Foundation
import Testing
@testable import KBCore

struct RealtimeWireTests {
    let tools: [JSONValue] = [["name": "factory_stop", "description": "Stop", "inputSchema": ["type": "object", "properties": ["factory": ["type": "string"]], "required": ["factory"]]]]

    @Test func openAIConnectsWithTheKeyOnlyInTheHeader() {
        let r = OpenAIRealtimeWire().request(model: "gpt-realtime-2.1", key: "sk-1")
        #expect(r.url?.absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")
        #expect(XAIRealtimeWire().request(model: "grok-voice-latest", key: "x").url?.absoluteString == "wss://api.x.ai/v1/realtime?model=grok-voice-latest")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
    }

    @Test func openAISetupCarriesToolsVoiceAndTranscription() {
        let s = OpenAIRealtimeWire().setup(model: "gpt-realtime", instructions: "Hi", voice: "marin", tools: tools)[0]
        #expect(s["type"]?.string == "session.update")
        #expect(s["session"]?["audio"]?["output"]?["voice"]?.string == "marin")
        #expect(s["session"]?["tools"]?.array?.first?["type"]?.string == "function")
        #expect(s["session"]?["tools"]?.array?.first?["parameters"]?["required"]?.strings == ["factory"])
        #expect(s["session"]?["audio"]?["input"]?["transcription"] != nil)
    }

    @Test func openAIEventsBecomeCommonEvents() {
        let w = OpenAIRealtimeWire()
        let pcm = Data([1, 0, 2, 0])
        #expect(w.parse(["type": "response.output_audio.delta", "delta": .string(pcm.base64EncodedString())]) == [.audio(pcm)])
        #expect(w.parse(["type": "input_audio_buffer.speech_started"]) == [.speechStarted])
        #expect(w.parse(["type": "response.function_call_arguments.done", "call_id": "c1", "name": "factory_stop", "arguments": "{\"factory\":\"N\"}"])
                == [.toolCall(id: "c1", name: "factory_stop", arguments: ["factory": "N"])])
        #expect(w.parse(["type": "error", "error": ["code": "invalid_api_key", "message": "Incorrect API key"]])
                == [.error(status: nil, message: "Incorrect API key", fatal: true)])
        #expect(w.parse(["type": "error", "error": ["code": "response_cancel_not_active", "message": "x"]])
                == [.error(status: nil, message: "x", fatal: false)])
    }

    @Test func openAIToolResultsContinueTheResponse() {
        let out = OpenAIRealtimeWire().toolResult(id: "c1", name: "x", output: "Done.")
        #expect(out[0]["item"]?["type"]?.string == "function_call_output")
        #expect(out[0]["item"]?["call_id"]?.string == "c1")
        #expect(out[1]["type"]?.string == "response.create")
    }

    @Test func geminiSetupAndEvents() {
        let w = GeminiLiveWire()
        let r = w.request(model: "m", key: "g-1")
        #expect(r.url?.query == "key=g-1")
        #expect(w.parse(["sessionResumptionUpdate": ["newHandle": "h1", "resumable": true]]) == [.resumeHandle("h1")])
        #expect(w.parse(["goAway": ["timeLeft": "10s"]]) == [.goAway])
        #expect(w.setup(model: "m", instructions: "", voice: "Kore", tools: [], resume: "h1")[0]["setup"]?["sessionResumption"]?["handle"]?.string == "h1")
        let s = w.setup(model: "gemini-x", instructions: "Hi", voice: "Puck", tools: tools)[0]
        #expect(s["setup"]?["model"]?.string == "models/gemini-x")
        #expect(s["setup"]?["tools"]?.array?.first?["functionDeclarations"]?.array?.first?["name"]?.string == "factory_stop")
        let pcm = Data([9, 9])
        let events = w.parse(["serverContent": ["modelTurn": ["parts": [["inlineData": ["mimeType": "audio/pcm;rate=24000", "data": .string(pcm.base64EncodedString())]]]],
                                                "turnComplete": true]])
        #expect(events == [.audio(pcm), .responseDone])
        #expect(w.parse(["serverContent": ["interrupted": true]]) == [.speechStarted])
        #expect(w.parse(["toolCall": ["functionCalls": [["id": "f1", "name": "overview", "args": [:]]]]]) == [.toolCall(id: "f1", name: "overview", arguments: [:])])
        #expect(w.toolResult(id: "f1", name: "overview", output: "ok")[0]["toolResponse"]?["functionResponses"]?.array?.first?["id"]?.string == "f1")
    }

    @Test func geminiDropsEmptyRequiredLists() {
        let schema = GeminiLiveWire.openAPISchema(["type": "object", "properties": [:], "required": []])
        #expect(schema == ["type": "object"])
    }

    @Test func aGeminiToolThatTakesNothingHasNoParameters() {
        let s = GeminiLiveWire().setup(model: "m", instructions: "", voice: "Kore", tools: SessionVoice.tools)[0]
        let declarations = s["setup"]?["tools"]?.array?.first?["functionDeclarations"]?.array ?? []
        let stop = declarations.first { $0["name"]?.string == SessionVoice.stop }
        let send = declarations.first { $0["name"]?.string == SessionVoice.send }
        #expect(stop != nil && stop?["parameters"] == nil)
        #expect(send?["parameters"]?["properties"]?["message"] != nil)
    }

    @Test func aFallbackQuotesWhatTheProviderSaid() {
        let m = VoiceEngineChoice.fallbackMessage(.other, provider: "Google Gemini Live", detail: "Invalid argument")
        #expect(m == "Google Gemini Live stopped working. It said: “Invalid argument”")
        #expect(!VoiceEngineChoice.fallbackMessage(.keyLocked, provider: "G", detail: "x").contains("It said"))
    }

    @Test func everyAvailableProviderHasAWire() {
        for p in RealtimeProvider.all where p.available {
            #expect(RealtimeWires.wire(for: p.id) != nil, "\(p.id)")
        }
    }

    @Test func resamplesBetweenRates() {
        let samples: [Int16] = Array(repeating: 1000, count: 160)
        let pcm = samples.withUnsafeBytes { Data($0) }
        #expect(PCMResampler.resample(pcm, from: 16000, to: 24000).count == 240 * 2)
        #expect(PCMResampler.resample(pcm, from: 24000, to: 16000).count == 107 * 2)
        #expect(PCMResampler.resample(pcm, from: 24000, to: 24000) == pcm)
        let up = PCMResampler.resample(pcm, from: 16000, to: 24000)
        let values: [Int16] = up.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(values.allSatisfy { $0 == 1000 })
    }

    @Test func realtimeToolsIncludeActionsConfirmationAndTheBrain() {
        let defs = RealtimeTools.definitions(tools).compactMap { $0["name"]?.string }
        #expect(defs == ["factory_stop", "confirm_action", "cancel_action", "find_actions", "run_action", "ask_brain"])
    }
}
