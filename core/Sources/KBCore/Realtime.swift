import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a real-time voice API says, in one shape for every provider.
public enum RealtimeEvent: Equatable, Sendable {
    case ready
    /// Output audio, 16-bit little-endian mono PCM at the protocol's `outputRate`.
    case audio(Data)
    case assistantTranscript(String, final: Bool)
    case userTranscript(String, final: Bool)
    /// The user started talking: stop playing at once.
    case speechStarted
    case responseDone
    case toolCall(id: String, name: String, arguments: JSONValue)
    case error(status: Int?, message: String, fatal: Bool)
    /// A handle to resume the same session on a new connection.
    case resumeHandle(String)
    /// The server will close the connection soon: reconnect with the last handle.
    case goAway
}

/// One provider's wire format: how to connect, set up the session, send audio and tool results, and read events.
/// The relay on the Mac does the I/O; this stays pure so each provider can be tested.
public protocol RealtimeWire: Sendable {
    var providerID: String { get }
    /// Sample rate of the PCM the API takes and gives.
    var inputRate: Double { get }
    var outputRate: Double { get }
    func request(model: String, key: String) -> URLRequest
    func setup(model: String, instructions: String, voice: String, tools: [JSONValue], resume: String?) -> [JSONValue]
    func audio(_ pcm: Data) -> JSONValue
    func toolResult(id: String, name: String, output: String) -> [JSONValue]
    /// What to send when the user barges in, beyond stopping playback (nil when the server handles it).
    func cancel() -> [JSONValue]
    /// Sends a text turn (used to say why it fell back, or to greet).
    func text(_ text: String) -> [JSONValue]
    func parse(_ message: JSONValue) -> [RealtimeEvent]
}

public enum RealtimeWires {
    public static func wire(for provider: String) -> RealtimeWire? {
        switch provider {
        case "openai": return OpenAIRealtimeWire()
        case "xai": return XAIRealtimeWire()
        case "gemini": return GeminiLiveWire()
        default: return nil
        }
    }
}

/// Linear resampling of 16-bit mono PCM; enough for speech between 16, 24 and 48 kHz.
public enum PCMResampler {
    public static func resample(_ pcm: Data, from: Double, to: Double) -> Data {
        guard from != to, pcm.count >= 4 else { return pcm }
        let input: [Int16] = pcm.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) } }
        let outCount = Int((Double(input.count) * to / from).rounded())
        guard outCount > 0 else { return Data() }
        var out = [Int16](repeating: 0, count: outCount)
        let step = from / to
        for i in 0..<outCount {
            let pos = Double(i) * step
            let j = Int(pos)
            let frac = pos - Double(j)
            let a = Double(input[min(j, input.count - 1)])
            let b = Double(input[min(j + 1, input.count - 1)])
            out[i] = Int16(max(-32768, min(32767, (a + (b - a) * frac).rounded())))
        }
        return out.withUnsafeBytes { Data($0) }
    }
}

/// The tools a real-time model gets: every action, the confirmation pair, and a way to hand deeper work to the brain.
public enum RealtimeTools {
    public static let askBrain = "ask_brain"

    /// `layer` holds the core actions; `find_actions` and `run_action` reach every other one.
    public static func definitions(_ layer: [JSONValue]) -> [JSONValue] {
        layer + [ActionTools.confirm, ActionTools.cancel, ActionTools.find, ActionTools.run, [
            "name": .string(askBrain),
            "description": "Hand a question or a deeper task to Mindmill's brain (it can read code, the knowledge base and run any kb command). Use it when no other tool fits. Returns its answer.",
            "inputSchema": ["type": "object", "properties": ["request": ["type": "string", "description": "What to find out or do"]], "required": ["request"]],
        ]]
    }

    public static let instructions = """
    You are Mindmill's voice. The user talks to you out loud. Answer in one to three short spoken sentences, no lists \
    or markup, in the language the user speaks. Use the tools to look things up and to act; they are the same actions \
    as the app's buttons, and everything the app can do is reachable: when no tool fits, find it with find_actions \
    and run it with run_action. When a tool answers that it needs confirmation, ask the user exactly its question, and call \
    confirm_action only after a clear yes, otherwise cancel_action. For deeper work, or a question no action answers, \
    use ask_brain. Keep going until the user says goodbye.
    """
}

extension JSONValue {
    /// A JSON object from a string holding JSON, as tool arguments often come.
    public static func parse(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .object([:])
    }

    public var jsonString: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
