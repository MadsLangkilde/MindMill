import Foundation
import KBCore

// The engine reaches the operating system only through these protocols. Each platform provides them:
// the macOS app (Sources/KB/MacPlatform.swift) and the Windows engine host (docs/engine-host.md). Some have a
// portable default here that works anywhere Foundation does.

/// Secrets the engine keeps for the user (voice API keys, the TLS identity's password). macOS: the login Keychain.
/// Windows: Credential Manager (`CredWriteW`, target `Mindmill/<name>`), never sent to the shell.
public protocol SecretStore: AnyObject {
    func secret(_ name: String) -> String?
    /// nil or empty removes it.
    func setSecret(_ value: String?, name: String)
    /// Whether it is saved, without reading it (macOS can ask for the password when the value is read).
    func hasSecret(_ name: String) -> Bool
}

/// Secrets in memory, for tests and for hosts without a store yet.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func secret(_ name: String) -> String? { lock.withLock { values[name] } }

    public func setSecret(_ value: String?, name: String) {
        lock.withLock { values[name] = value?.isEmpty == false ? value : nil }
    }

    public func hasSecret(_ name: String) -> Bool { secret(name) != nil }
}

/// Voice API keys are secrets named `voice-api/<provider>`.
public struct SecretVoiceKeys: VoiceKeyStore {
    public let store: SecretStore

    public init(_ store: SecretStore) { self.store = store }

    public static func name(_ provider: String) -> String { "voice-api/\(provider)" }

    public func key(provider: String) -> String? { store.secret(Self.name(provider)) }

    public func set(_ key: String?, provider: String) { store.setSecret(key, name: Self.name(provider)) }
}

/// Finds `claude`, Python and the user's environment. macOS: the login shell (`LoginShell`); Windows: PATH and the
/// usual install folders (`WindowsTools`). `SystemTools` picks the right one for the platform it was built for.
public protocol ToolLocating: Sendable {
    func resolve() -> LoginShell.Resolved
}

public struct SystemTools: ToolLocating {
    public init() {}

    public func resolve() -> LoginShell.Resolved {
        Self.overriding(LoginShell.resolve(), environment: ProcessInfo.processInfo.environment)
    }

    /// `MINDMILL_CLAUDE` points the engine at another `claude` (tests use a stub; the engine host's `--claude`).
    public static func overriding(_ r: LoginShell.Resolved, environment: [String: String]) -> LoginShell.Resolved {
        guard let path = environment["MINDMILL_CLAUDE"], !path.isEmpty else { return r }
        return LoginShell.Resolved(environment: r.environment, claude: URL(fileURLWithPath: KBConfig.expandTilde(path)),
                                   python3: r.python3, python3Arguments: r.python3Arguments)
    }
}

/// Something the user should know about while they may not be looking: a session waits for them, a factory stopped.
/// macOS: the notice bar and the phones; Windows: the shell's `platform.notify` toast, else the phones.
public protocol Notifier: AnyObject {
    func notify(title: String, body: String, action: String?)
}

/// Speech on the machine the engine runs on. macOS: `Speech` and `AVSpeechSynthesizer` (`VoiceAudio` in the app);
/// Windows: the shell's `platform.speech.*` and `platform.speak` services.
public protocol SpeechServices: AnyObject {
    /// Starts recognition; partial and final text, and the input level for barge-in, come back through `events`.
    func startListening(language: String, conversation: Bool, echoCancellation: Bool,
                        events: @escaping (SpeechEvent) -> Void) throws
    func stopListening()
    /// Speaks `text`; `done(interrupted:)` is called once it finished or was stopped.
    func speak(_ text: String, voice: String?, rate: Double?, done: @escaping (_ interrupted: Bool) -> Void)
    func stopSpeaking()
    func voices() -> [SpeechVoice]
}

public enum SpeechEvent: Equatable, Sendable {
    case partial(String)
    case final(String)
    case level(Double)
    case error(String)
}

public struct SpeechVoice: Equatable, Sendable, Codable {
    public var id: String
    public var name: String
    public var language: String
    public var natural: Bool

    public init(id: String, name: String, language: String, natural: Bool) {
        self.id = id
        self.name = name
        self.language = language
        self.natural = natural
    }
}

/// The companion server's transport: a TLS WebSocket listener that phones pin by certificate fingerprint
/// (docs/remote-api.md). macOS: Network.framework with the identity from `RemoteIdentity`; Windows: the engine
/// host's own listener. `RemoteHub` does everything above the transport: pairing, hello, requests, events.
public protocol CompanionTransport: AnyObject {
    /// Starts listening on `port` with the identity kept in `folder`. Throws a message for the user when it can't.
    @MainActor func listen(port: Int, folder: URL) throws -> CompanionListening
    /// Calls `changed` when the network changes (a key that differs per network state, and whether it is up).
    @MainActor func watchNetwork(_ changed: @escaping @MainActor (_ key: String, _ satisfied: Bool) -> Void)
    @MainActor func stopWatchingNetwork()
    /// Every address a phone may reach this machine on, best first, and the machine's name for the invite.
    func addresses() async -> (addresses: [String], tailscaleName: String?)
    var machineName: String { get }
}

/// One running listener. The hub drops a listener's callbacks once it has replaced or closed it.
@MainActor
public protocol CompanionListening: AnyObject {
    /// SHA-256 of the certificate's DER bytes, hex, lower case: what the phones pin.
    var fingerprint: String { get }
    var onState: ((CompanionListenerState) -> Void)? { get set }
    var onConnection: ((CompanionConnection) -> Void)? { get set }
    func start()
    func cancel()
}

public enum CompanionListenerState: Equatable, Sendable {
    case ready
    case waiting(String)
    case failed(String)
}

/// One phone's (or desktop shell's) WebSocket. Callbacks may come on any queue.
public protocol CompanionConnection: AnyObject, Sendable {
    func start(onText: @escaping @Sendable (String) -> Void, onBinary: @escaping @Sendable (Data) -> Void,
               onClose: @escaping @Sendable () -> Void)
    func sendText(_ text: String)
    func sendBinary(_ data: Data)
    func close()
}
