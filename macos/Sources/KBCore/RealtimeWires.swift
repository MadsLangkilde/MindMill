import Foundation

/// OpenAI's Realtime API (GA): JSON events over a WebSocket, base64 PCM, function tools.
public struct OpenAIRealtimeWire: RealtimeWire {
    public var providerID: String { "openai" }
    public var inputRate: Double { 24000 }
    public var outputRate: Double { 24000 }
    var endpoint = "wss://api.openai.com/v1/realtime"

    public init() {}

    init(endpoint: String) {
        self.endpoint = endpoint
    }

    public func request(model: String, key: String) -> URLRequest {
        var c = URLComponents(string: endpoint)!
        c.queryItems = [URLQueryItem(name: "model", value: model)]
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return r
    }

    public func setup(model: String, instructions: String, voice: String, tools: [JSONValue], resume: String? = nil) -> [JSONValue] {
        [[
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": .string(model),
                "instructions": .string(instructions),
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "transcription": ["model": "gpt-transcribe"],
                        "noise_reduction": ["type": "near_field"],
                        "turn_detection": ["type": "semantic_vad", "create_response": true, "interrupt_response": true],
                    ],
                    "output": ["format": ["type": "audio/pcm", "rate": 24000], "voice": .string(voice)],
                ],
                "tools": .array(tools.map(Self.functionTool)),
                "tool_choice": "auto",
            ],
        ]]
    }

    static func functionTool(_ t: JSONValue) -> JSONValue {
        ["type": "function", "name": t["name"] ?? "", "description": t["description"] ?? "", "parameters": t["inputSchema"] ?? ["type": "object"]]
    }

    public func audio(_ pcm: Data) -> JSONValue {
        ["type": "input_audio_buffer.append", "audio": .string(pcm.base64EncodedString())]
    }

    public func toolResult(id: String, name: String, output: String) -> [JSONValue] {
        [["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": .string(id), "output": .string(output)]],
         ["type": "response.create"]]
    }

    public func cancel() -> [JSONValue] { [["type": "response.cancel"]] }

    public func text(_ text: String) -> [JSONValue] {
        [["type": "conversation.item.create", "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": .string(text)]]]],
         ["type": "response.create"]]
    }

    public func parse(_ m: JSONValue) -> [RealtimeEvent] {
        switch m["type"]?.string ?? "" {
        case "session.created", "session.updated": return [.ready]
        case "response.output_audio.delta", "response.audio.delta":
            return Data(base64Encoded: m["delta"]?.string ?? "").map { [.audio($0)] } ?? []
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            return [.assistantTranscript(m["delta"]?.string ?? "", final: false)]
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            return [.assistantTranscript(m["transcript"]?.string ?? "", final: true)]
        case "conversation.item.input_audio_transcription.completed":
            return [.userTranscript(m["transcript"]?.string ?? "", final: true)]
        case "input_audio_buffer.speech_started": return [.speechStarted]
        case "response.done": return [.responseDone]
        case "response.function_call_arguments.done":
            return [.toolCall(id: m["call_id"]?.string ?? "", name: m["name"]?.string ?? "",
                              arguments: .parse(m["arguments"]?.string ?? "{}"))]
        case "error":
            let e = m["error"] ?? [:]
            let code = e["code"]?.string ?? e["type"]?.string ?? ""
            let message = e["message"]?.string ?? code
            // Cancelling with nothing to cancel is harmless.
            let harmless = code == "response_cancel_not_active" || message.contains("no active response")
            return [.error(status: nil, message: message, fatal: !harmless && Self.isFatal(code: code, message: message))]
        default: return []
        }
    }

    static func isFatal(code: String, message: String) -> Bool {
        let c = (code + " " + message).lowercased()
        return c.contains("invalid_api_key") || c.contains("insufficient_quota") || c.contains("rate_limit") || c.contains("quota")
            || c.contains("authentication") || c.contains("model_not_found") || c.contains("session_expired") || c.contains("unauthorized")
    }
}

/// xAI's Grok Voice Agent API speaks the same event protocol as OpenAI's Realtime API at its own endpoint.
public struct XAIRealtimeWire: RealtimeWire {
    private var base = OpenAIRealtimeWire(endpoint: "wss://api.x.ai/v1/realtime")

    public init() {}

    public var providerID: String { "xai" }
    public var inputRate: Double { 24000 }
    public var outputRate: Double { 24000 }

    public func request(model: String, key: String) -> URLRequest { base.request(model: model, key: key) }

    public func setup(model: String, instructions: String, voice: String, tools: [JSONValue], resume: String? = nil) -> [JSONValue] {
        [[
            "type": "session.update",
            "session": [
                "instructions": .string(instructions),
                "voice": .string(voice),
                "turn_detection": ["type": "server_vad"],
                "audio": [
                    "input": ["format": ["type": "audio/pcm", "rate": 24000]],
                    "output": ["format": ["type": "audio/pcm", "rate": 24000]],
                ],
                "tools": .array(tools.map(OpenAIRealtimeWire.functionTool)),
            ],
        ]]
    }

    public func audio(_ pcm: Data) -> JSONValue { base.audio(pcm) }
    public func toolResult(id: String, name: String, output: String) -> [JSONValue] { base.toolResult(id: id, name: name, output: output) }
    public func cancel() -> [JSONValue] { base.cancel() }
    public func text(_ text: String) -> [JSONValue] { base.text(text) }
    public func parse(_ m: JSONValue) -> [RealtimeEvent] { base.parse(m) }
}

/// Google's Gemini Live API (Gemini API key): `setup`, then `realtimeInput` audio and `toolResponse` messages.
public struct GeminiLiveWire: RealtimeWire {
    public var providerID: String { "gemini" }
    public var inputRate: Double { 16000 }
    public var outputRate: Double { 24000 }

    public init() {}

    public func request(model: String, key: String) -> URLRequest {
        var c = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        c.queryItems = [URLQueryItem(name: "key", value: key)]
        return URLRequest(url: c.url!)
    }

    public func setup(model: String, instructions: String, voice: String, tools: [JSONValue], resume: String? = nil) -> [JSONValue] {
        let declarations = tools.map { t -> JSONValue in
            ["name": t["name"] ?? "", "description": t["description"] ?? "", "parameters": Self.openAPISchema(t["inputSchema"] ?? ["type": "object"])]
        }
        var resumption: JSONValue = [:]
        if let resume { resumption = ["handle": .string(resume)] }
        return [[
            "setup": [
                "model": .string(model.hasPrefix("models/") ? model : "models/\(model)"),
                "contextWindowCompression": ["slidingWindow": [:]],
                "sessionResumption": resumption,
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": .string(voice)]]],
                ],
                "systemInstruction": ["parts": [["text": .string(instructions)]]],
                "tools": [["functionDeclarations": .array(declarations)]],
                "inputAudioTranscription": [:],
                "outputAudioTranscription": [:],
            ],
        ]]
    }

    /// Gemini's function parameters are an OpenAPI subset: no empty `required`, types as written.
    static func openAPISchema(_ s: JSONValue) -> JSONValue {
        guard case .object(var o) = s else { return s }
        if case .array(let r)? = o["required"], r.isEmpty { o["required"] = nil }
        if case .object(let props)? = o["properties"] {
            var cleaned: [String: JSONValue] = [:]
            for (k, v) in props { cleaned[k] = openAPISchema(v) }
            if cleaned.isEmpty { o["properties"] = nil } else { o["properties"] = .object(cleaned) }
        }
        return .object(o)
    }

    public func audio(_ pcm: Data) -> JSONValue {
        ["realtimeInput": ["audio": ["data": .string(pcm.base64EncodedString()), "mimeType": "audio/pcm;rate=16000"]]]
    }

    public func toolResult(id: String, name: String, output: String) -> [JSONValue] {
        [["toolResponse": ["functionResponses": [["id": .string(id), "name": .string(name), "response": ["result": .string(output)]]]]]]
    }

    /// Gemini stops by itself when it hears the user (`interrupted`).
    public func cancel() -> [JSONValue] { [] }

    public func text(_ text: String) -> [JSONValue] {
        [["clientContent": ["turns": [["role": "user", "parts": [["text": .string(text)]]]], "turnComplete": true]]]
    }

    public func parse(_ m: JSONValue) -> [RealtimeEvent] {
        var out: [RealtimeEvent] = []
        if m["setupComplete"] != nil { out.append(.ready) }
        if let sc = m["serverContent"] {
            if sc["interrupted"]?.bool == true { out.append(.speechStarted) }
            if let t = sc["inputTranscription"]?["text"]?.string, !t.isEmpty { out.append(.userTranscript(t, final: false)) }
            for part in sc["modelTurn"]?["parts"]?.array ?? [] {
                if let b64 = part["inlineData"]?["data"]?.string, let d = Data(base64Encoded: b64) { out.append(.audio(d)) }
            }
            if let t = sc["outputTranscription"]?["text"]?.string, !t.isEmpty { out.append(.assistantTranscript(t, final: false)) }
            if sc["turnComplete"]?.bool == true { out.append(.responseDone) }
        }
        for call in m["toolCall"]?["functionCalls"]?.array ?? [] {
            out.append(.toolCall(id: call["id"]?.string ?? "", name: call["name"]?.string ?? "", arguments: call["args"] ?? [:]))
        }
        if let e = m["error"] {
            let message = e["message"]?.string ?? "Gemini error"
            out.append(.error(status: e["code"]?.int, message: message, fatal: true))
        }
        if let h = m["sessionResumptionUpdate"]?["newHandle"]?.string, m["sessionResumptionUpdate"]?["resumable"]?.bool != false {
            out.append(.resumeHandle(h))
        }
        if m["goAway"] != nil { out.append(.goAway) }
        return out
    }
}
