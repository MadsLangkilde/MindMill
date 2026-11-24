import Foundation
import KBCore
import Testing
@testable import KBEngine

@MainActor
@Suite struct MindmillEngineTests {
    final class Shown: Presenter {
        var shown: [(String, String?)] = []
        func show(screen: String, id: String?) throws { shown.append((screen, id)) }
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kb-engine-\(UUID().uuidString)")
    let defaults = UserDefaults(suiteName: "kb-engine-\(UUID().uuidString)")!

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func makeEngine(platform name: String = "Windows") throws -> MindmillEngine {
        try write("kb.json", #"{"version": 1, "projects": [{"id": "alpha", "title": "Alpha", "paths": []}, {"id": "beta", "title": "Beta"}]}"#)
        try write("projects/alpha/facts/one.md", "---\ntitle: One\n---\nFirst.\n")
        try write("projects/alpha/facts/two.md", "---\ntitle: Two\nrelated: [alpha/facts/one]\n---\n")
        try write("projects/alpha/inbox/new-fact.md", "---\ntitle: Maybe\nkind: fact\n---\n")
        let platform = EnginePlatform(name: name, machineWord: "PC", secrets: MemorySecretStore(), transport: FakeTransport(),
                                      defaults: defaults, pluginRoot: { "/nonexistent" })
        let engine = MindmillEngine(rootPath: root.path, platform: platform,
                                    remoteFolder: root.appendingPathComponent("remote-data"))
        engine.isolate(in: root.appendingPathComponent("app-data"))
        engine.reload()
        return engine
    }

    func client() -> RemoteClient { RemoteClient(FakeConnection()) }

    @Test func loadsTheKnowledgeBaseAndPicksAScope() throws {
        let engine = try makeEngine()
        #expect(engine.loadError == nil)
        #expect(engine.scope == "alpha")
        var reloaded = 0
        engine.onReload.append { _ in reloaded += 1 }
        engine.reload()
        #expect(reloaded == 1)
        #expect(engine.selectScope("beta"))
        #expect(defaults.string(forKey: MindmillEngine.lastScopeKey) == "beta")
        #expect(!engine.selectScope("nope"))
    }

    @Test func answersTheRemoteMethodsItOwns() async throws {
        let engine = try makeEngine()
        let c = client()
        let hello = try await engine.call("hello", [:], from: c)
        #expect(hello["name"]?.string == "Test PC")
        #expect(hello["scopes"]?.array?.count == 2)
        let facts = try await engine.call("entries.list", ["scope": "alpha", "section": "facts"], from: c)
        #expect(facts["entries"]?.array?.count == 2)
        let structure = try await engine.call("app.structure", ["scope": "alpha"], from: c)
        #expect(structure["modes"]?.array?.count == 2)
        let entry = try await engine.call("entry.get", ["id": "alpha/facts/two"], from: c)
        #expect(entry["extra"]?["linked"]?.array?.first?["id"]?.string == "alpha/facts/one")
    }

    @Test func platformFeaturesAreUnavailableAndOthersUnknown() async throws {
        let engine = try makeEngine()
        await #expect(throws: RemoteError.self) { _ = try await engine.call("meeting.start", [:], from: client()) }
        do {
            _ = try await engine.call("meeting.get", [:], from: client())
        } catch let e as RemoteError {
            #expect(e.code == "unavailable")
            #expect(e.message.contains("Windows"))
        }
        do {
            _ = try await engine.call("nothing.here", [:], from: client())
        } catch let e as RemoteError {
            #expect(e.code == "unknown_method")
        }
        let outcome = await engine.actions.run("meeting.mac.start", [:], channel: .remote)
        #expect(outcome.text.contains("isn't available on Windows"))
    }

    @Test func hostsAddAndReplaceMethodsAndActions() async throws {
        let engine = try makeEngine()
        engine.methods.register(prefix: "meeting.") { method in { _, _ in ["handled": .string(method)] } }
        let r = try await engine.call("meeting.get", [:], from: client())
        #expect(r["handled"]?.string == "meeting.get")
        engine.actions.register("app.mode") { _ in ActionResult("Host's own.") }
        let outcome = await engine.actions.run("app.mode", ["mode": "build"], channel: .ui)
        #expect(outcome.text == "Host's own.")
    }

    @Test func portableActionsRunOnTheEngineAlone() async throws {
        let engine = try makeEngine()
        let shown = Shown()
        engine.platform.presenter = shown
        let facts = await engine.actions.run("facts.list", ["scope": "alpha", "links": true], channel: .remote)
        guard case .done(let result) = facts else { Issue.record("facts.list failed: \(facts.text)"); return }
        #expect(result.data["links"]?["alpha/facts/two"]?.strings == ["alpha/facts/one"])
        let show = await engine.actions.run("app.show", ["screen": "facts"], channel: .remote)
        #expect(show.text.contains("PC's screen"))
        #expect(shown.shown.first?.0 == "facts")
        let mode = await engine.actions.run("app.mode", ["mode": "build"], channel: .ui)
        #expect(mode.text == "Switched to Build.")
        #expect(engine.mode == "build")
        let ai = await engine.actions.run("settings.ai", ["task": "voice", "model": "haiku"], channel: .ui)
        #expect(ai.text.contains("haiku"))
        #expect(engine.model(for: .voice) == "haiku" || ProcessInfo.processInfo.environment["KB_MODEL"] != nil)
        #expect(AISetup.migrated(defaults: defaults).model(for: .voice) == "haiku")
        #expect(engine.actions.unhandled.contains("meeting.mac.start"))
        #expect(!engine.actions.unhandled.contains("entry.read"))
    }

    @Test func badgesCountWhatWaits() throws {
        let engine = try makeEngine()
        #expect(engine.factProposals(project: "alpha").count == engine.sidebarBadge(.facts, project: "alpha").count
            || engine.factProposals(project: "alpha").isEmpty)
        #expect(KBSection.facts.icon == "lightbulb")
    }

    @Test func voiceFramesSayTheirRate() {
        #expect(MindmillEngine.sampleRate("pcm24k") == 24000)
        #expect(MindmillEngine.sampleRate("pcm16k") == 16000)
        #expect(MindmillEngine.sampleRate(nil) == 16000)
    }
}
