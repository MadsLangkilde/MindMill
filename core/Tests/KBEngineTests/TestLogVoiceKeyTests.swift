import Foundation
import KBCore
import Testing
@testable import KBEngine

/// What the phone gets for a failed build (its log, whose version to build) and the voice API keys it can send.
@MainActor
@Suite struct TestLogVoiceKeyTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kb-testlog-\(UUID().uuidString)")
    let defaults = UserDefaults(suiteName: "kb-testlog-\(UUID().uuidString)")!

    func makeEngine(secrets: SecretStore = MemorySecretStore()) throws -> MindmillEngine {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"version": 1, "projects": [{"id": "alpha", "title": "Alpha", "paths": []}]}"#
            .write(to: root.appendingPathComponent("kb.json"), atomically: true, encoding: .utf8)
        let platform = EnginePlatform(name: "Windows", machineWord: "PC", secrets: secrets, transport: FakeTransport(),
                                      defaults: defaults, pluginRoot: { "/nonexistent" })
        let engine = MindmillEngine(rootPath: root.path, platform: platform, remoteFolder: root.appendingPathComponent("remote"))
        engine.isolate(in: root.appendingPathComponent("data"))
        engine.reload()
        return engine
    }

    func client() -> RemoteClient { RemoteClient(FakeConnection()) }

    @Test func aFailedBuildsLogReachesThePhone() async throws {
        let engine = try makeEngine()
        var d = TestDelivery(scope: "alpha", target: "t1", kind: .apk, title: "App")
        d.state = .failed
        d.session = "s1"
        engine.tests.center.update(d)
        let quiet = try await engine.call("test.status", ["scope": "alpha"], from: client())
        #expect(quiet["deliveries"]?.array?.first?["hasLog"]?.bool == false)
        await #expect(throws: RemoteError.self) { _ = try await engine.call("test.log", ["delivery": .string(d.id)], from: client()) }

        try "$ gradle assembleDebug\nzsh:1: command not found: gradle\n"
            .write(to: engine.tests.center.folder(d.id).appendingPathComponent(TestCenter.logFile), atomically: true, encoding: .utf8)
        let status = try await engine.call("test.status", ["scope": "alpha"], from: client())
        let listed = try #require(status["deliveries"]?.array?.first)
        #expect(listed["hasLog"]?.bool == true && listed["session"]?.string == "s1")
        let log = try await engine.call("test.log", ["delivery": .string(d.id)], from: client())
        #expect(log["log"]?.string?.contains("command not found") == true)
        #expect(log["firstError"]?.string == "command not found: gradle")
        await #expect(throws: RemoteError.self) { _ = try await engine.call("test.log", ["delivery": "nope"], from: client()) }
    }

    @Test func buildSourcesWithoutCopiesOfferTheComputersOwnVersion() async throws {
        let engine = try makeEngine()
        let sources = try await engine.call("test.sources", ["scope": "alpha"], from: client())
        #expect(sources["local"]?["branch"] == .null)
        #expect(sources["sessions"]?.array?.isEmpty == true)
    }

    @Test func thePhoneCanSendAKeyButNeverReadsOne() async throws {
        let store = MemorySecretStore()
        let engine = try makeEngine(secrets: store)
        let before = try await engine.call("voice.providers", [:], from: client())
        let nova = try #require(before["providers"]?.array?.first { $0["id"]?.string == "nova-sonic" })
        #expect(nova["hasKey"]?.bool == false && nova["key"] == nil)

        let saved = try await engine.call("voice.key.set", ["provider": "nova-sonic", "key": " sk-test \n", "use": false], from: client())
        #expect(saved["saved"]?.bool == true)
        #expect(store.secret(SecretVoiceKeys.name("nova-sonic")) == "sk-test")
        let after = try await engine.call("voice.providers", [:], from: client())
        #expect(after["providers"]?.array?.first { $0["id"]?.string == "nova-sonic" }?["hasKey"]?.bool == true)
        #expect(!String(describing: after).contains("sk-test"))

        for bad: JSONValue in [["provider": "nope", "key": "k"], ["provider": "nova-sonic", "key": "  "], ["provider": "nova-sonic", "key": "a\nb"]] {
            await #expect(throws: RemoteError.self) { _ = try await engine.call("voice.key.set", bad, from: client()) }
        }
        await #expect(throws: RemoteError.self) { _ = try await engine.call("voice.use", ["provider": "nope"], from: client()) }

        _ = try await engine.call("voice.key.remove", ["provider": "nova-sonic"], from: client())
        #expect(store.secret(SecretVoiceKeys.name("nova-sonic")) == nil)
    }

    @Test func aKeyThatTakesTooLongToReadIsLockedAndReadyNextTime() async throws {
        let store = SlowSecretStore()
        store.values[SecretVoiceKeys.name("gemini")] = "k"
        let engine = try makeEngine(secrets: store)
        #expect(await engine.readVoiceKey("openai", wait: 1) == .missing)
        #expect(await engine.readVoiceKey("gemini", wait: 0.05) == .locked)
        for _ in 0..<100 where engine.voiceKeyReads["gemini"] != nil { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(await engine.readVoiceKey("gemini", wait: 1) == .key("k"))
    }

    @Test func aFallbackSaysWhyOnTheScreen() {
        let out = VoiceOutput.fallback(reason: .keyLocked, speech: "s",
                                       message: VoiceEngineChoice.fallbackMessage(.keyLocked, provider: "Google Gemini Live"))
        let event = out.remoteEvent(conversation: "c")
        #expect(event?.0 == "voice.fallback" && event?.1["reason"]?.string == "keyLocked")
        #expect(event?.1["message"]?.string?.contains("login password") == true)
    }
}

/// Answers the first read only after a while, as the Keychain does while macOS waits for the password.
final class SlowSecretStore: SecretStore, @unchecked Sendable {
    var values: [String: String] = [:]
    private var slow = true
    private let lock = NSLock()

    func secret(_ name: String) -> String? {
        let wait = lock.withLock { () -> Bool in defer { slow = false }; return slow }
        if wait { Thread.sleep(forTimeInterval: 0.4) }
        return lock.withLock { values[name] }
    }

    func setSecret(_ value: String?, name: String) { lock.withLock { values[name] = value } }

    func hasSecret(_ name: String) -> Bool { lock.withLock { values[name] != nil } }
}
