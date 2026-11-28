import Foundation
import KBCore
import Testing
@testable import KBEngine

/// Instances on the engine: what the phone lists, makes and opens, and a new project in an instance that isn't open.
@MainActor
@Suite struct InstanceEngineTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("kb-inst-\(UUID().uuidString)")
    var root: URL { base.appendingPathComponent("main") }
    let defaults = UserDefaults(suiteName: "kb-inst-\(UUID().uuidString)")!

    func makeEngine() throws -> MindmillEngine {
        try Registry.createKnowledgeBase(root: root)
        let config = base.appendingPathComponent("config.json")
        try #"{"root": "\#(root.path)"}"#.write(to: config, atomically: true, encoding: .utf8)
        let platform = EnginePlatform(name: "Windows", machineWord: "PC", secrets: MemorySecretStore(), transport: FakeTransport(),
                                      defaults: defaults, pluginRoot: { "/nonexistent" })
        let engine = MindmillEngine(rootPath: root.path, platform: platform, remoteFolder: base.appendingPathComponent("remote"))
        engine.isolate(in: base.appendingPathComponent("data"))
        engine.configURL = config
        engine.instance = InstanceList.load(configURL: config).open
        engine.reload()
        return engine
    }

    func client() -> RemoteClient { RemoteClient(FakeConnection()) }

    @Test func listCreateAndSwitch() async throws {
        let engine = try makeEngine()
        let first = try await engine.call("instances.list", [:], from: client())
        #expect(first["current"]?.string == "main")
        #expect(first["instances"]?.array?.count == 1 && first["instances"]?.array?.first?["exists"]?.bool == true)

        let made = try engine.createInstance(name: "Work", folder: base.appendingPathComponent("work"))
        #expect(made.id == "work")
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("work/shared/kb.json").path))
        let listed = try await engine.call("instances.list", [:], from: client())
        #expect(listed["instances"]?.array?.map { $0["id"]?.string } == ["main", "work"])
        #expect(listed["current"]?.string == "main")

        await #expect(throws: RemoteError.self) { _ = try await engine.call("instance.switch", ["id": "work"], from: client()) }
        var opened: [String] = []
        engine.onSwitchInstance = { opened.append($0.id) }
        let same = try await engine.call("instance.switch", ["id": "main"], from: client())
        #expect(same["switching"]?.bool == false)
        let switching = try await engine.call("instance.switch", ["id": "work"], from: client())
        #expect(switching["switching"]?.bool == true)
        for _ in 0..<100 where opened.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(opened == ["work"])
        await #expect(throws: RemoteError.self) { _ = try await engine.call("instance.switch", ["id": "nope"], from: client()) }
        await #expect(throws: RemoteError.self) {
            _ = try await engine.call("instance.create", ["name": "Outside", "path": "/tmp/outside-home"], from: client())
        }
    }

    @Test func aNewProjectGoesIntoTheInstanceAskedFor() async throws {
        let engine = try makeEngine()
        try engine.createInstance(name: "Work", folder: base.appendingPathComponent("work"))
        let code = base.appendingPathComponent("code/app")
        try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
        let saved = try await engine.call("projects.config.save", [
            "instance": "work",
            "project": ["title": "Acme", "locations": [["name": "App", "path": .string(code.path)]], "scopes": []],
        ], from: client())
        #expect(saved["instance"]?.string == "work" && saved["id"]?.string == "acme")
        let work = try Registry.load(base.appendingPathComponent("work/shared/kb.json"))
        #expect(work.projects.map(\.id) == ["acme"])
        #expect(engine.index.projects.isEmpty)
        await #expect(throws: RemoteError.self) {
            _ = try await engine.call("projects.config.save", ["instance": "work", "id": "acme", "project": ["title": "Acme"]], from: client())
        }
    }

    @Test func helloNamesTheInstanceAndTheLauncher() throws {
        let engine = try makeEngine()
        #expect(engine.helloResult()["instance"]?["name"]?.string == "Main")
        #expect(engine.helloResult()["launcher"] == .null)
        engine.launcherPort = 7879
        #expect(engine.helloResult()["launcher"]?["port"]?.int == 7879)
    }

    @Test func theLauncherKeysFollowThePairedPhones() throws {
        let engine = try makeEngine()
        let remote = base.appendingPathComponent("remote")
        let keys = BackgroundAgents.keysURL(remoteFolder: remote)
        let (_, token) = engine.remote.devices.pair(name: "Pixel")
        engine.remote.saveDevices()
        #expect(try String(contentsOf: keys, encoding: .utf8) == Digest.sha256Hex(token) + "\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: keys.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
