import Foundation

/// A real-time voice API the user can add a key for. The key itself lives only in the Mac's Keychain.
public struct RealtimeProvider: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var models: [String]
    public var defaultModel: String
    public var voices: [String]
    public var defaultVoice: String
    /// Where to get a key.
    public var keyPage: String
    /// Implemented end to end; the others are listed with the interface ready.
    public var available: Bool
    public var note: String

    public init(id: String, name: String, models: [String], defaultModel: String, voices: [String], defaultVoice: String,
                keyPage: String, available: Bool, note: String = "") {
        self.id = id
        self.name = name
        self.models = models
        self.defaultModel = defaultModel
        self.voices = voices
        self.defaultVoice = defaultVoice
        self.keyPage = keyPage
        self.available = available
        self.note = note
    }

    public static func with(id: String?) -> RealtimeProvider? { all.first { $0.id == id } }

    public static var all: [RealtimeProvider] { RealtimeProviders.all }
}

/// The user's voice settings. Never holds a key.
public struct VoicePreferences: Codable, Equatable, Sendable {
    public var engine: VoiceEngineKind = .keyless
    /// The active provider for the API engine; keys for several can be stored, one is active.
    public var provider: String?
    /// Model chosen per provider id.
    public var models: [String: String] = [:]
    /// Voice chosen per provider id, for the API engine.
    public var apiVoices: [String: String] = [:]
    /// A macOS voice identifier for the keyless engine; nil picks the best installed voice for the language.
    public var macVoice: String?
    /// 0.5 to 2; 1 is the system's normal speed.
    public var rate: Double = 1
    /// `auto`, `da-DK` or `en-US`.
    public var language = "auto"
    /// Ask out loud before destructive actions and writes to outside tools.
    public var confirmsRisky = true
    /// Stop speaking as soon as the user talks.
    public var bargeIn = true

    public init() {}

    public static let key = "voicePreferences"

    public static func load(_ defaults: UserDefaults = .standard) -> VoicePreferences {
        guard let data = defaults.data(forKey: key), let p = try? JSONDecoder().decode(VoicePreferences.self, from: data) else {
            return VoicePreferences()
        }
        return p
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    public func model(for provider: String) -> String {
        models[provider] ?? RealtimeProvider.with(id: provider)?.defaultModel ?? ""
    }

    public func apiVoice(for provider: String) -> String {
        apiVoices[provider] ?? RealtimeProvider.with(id: provider)?.defaultVoice ?? ""
    }

    public var clampedRate: Double { min(2, max(0.5, rate)) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = (try? c.decode(VoiceEngineKind.self, forKey: .engine)) ?? .keyless
        provider = try? c.decode(String.self, forKey: .provider)
        models = (try? c.decode([String: String].self, forKey: .models)) ?? [:]
        apiVoices = (try? c.decode([String: String].self, forKey: .apiVoices)) ?? [:]
        macVoice = try? c.decode(String.self, forKey: .macVoice)
        rate = (try? c.decode(Double.self, forKey: .rate)) ?? 1
        language = (try? c.decode(String.self, forKey: .language)) ?? "auto"
        confirmsRisky = (try? c.decode(Bool.self, forKey: .confirmsRisky)) ?? true
        bargeIn = (try? c.decode(Bool.self, forKey: .bargeIn)) ?? true
    }

    /// What the phone gets from `voice.config`: the engine to use and how to speak. Never a key, and nothing
    /// derived from one.
    public func remoteConfig(engine: VoiceEngineKind) -> JSONValue {
        var out: [String: JSONValue] = [
            "engine": .string(engine.rawValue), "rate": .number(clampedRate), "confirmsRisky": .bool(confirmsRisky),
            "language": .string(language), "bargeIn": .bool(bargeIn),
        ]
        if engine == .api, let provider, let p = RealtimeProvider.with(id: provider) {
            out["provider"] = .string(p.id)
            out["providerName"] = .string(p.name)
            out["model"] = .string(model(for: provider))
        }
        return .object(out)
    }
}

/// Where API keys are kept. The app's is the Keychain; tests use memory.
public protocol VoiceKeyStore {
    func key(provider: String) -> String?
    func set(_ key: String?, provider: String)
}

public extension VoiceKeyStore {
    func has(provider: String) -> Bool { !(key(provider: provider) ?? "").isEmpty }
}

public final class MemoryKeyStore: VoiceKeyStore {
    public var keys: [String: String] = [:]
    public init() {}
    public func key(provider: String) -> String? { keys[provider] }
    public func set(_ key: String?, provider: String) { keys[provider] = key }
}
