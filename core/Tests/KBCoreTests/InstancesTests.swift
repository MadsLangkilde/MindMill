import Foundation
import Testing
@testable import KBCore

@Suite struct InstancesTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kb-instances-\(UUID().uuidString)")
    var config: URL { dir.appendingPathComponent("config.json") }

    func writeConfig(_ json: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: config, atomically: true, encoding: .utf8)
    }

    @Test func aConfigWithOnlyARootIsTheMainInstance() throws {
        try writeConfig(#"{"root": "~/Mindmill/knowledgebase"}"#)
        let list = InstanceList.load(configURL: config)
        #expect(list.instances == [MindmillInstance(id: "main", name: "Main", root: "~/Mindmill/knowledgebase")])
        #expect(list.current == "main")
        let base = URL(fileURLWithPath: "/data")
        #expect(list.open.dataFolder(in: base) == base)
        #expect(MindmillInstance(id: "work", name: "Work", root: "/w").dataFolder(in: base).path == "/data/instances/work")
    }

    @Test func theRootPicksTheOpenInstanceAndAMovedFolderKeepsItsInstance() {
        let listed = [MindmillInstance(id: "main", name: "Main", root: "/kb/main"), MindmillInstance(id: "work", name: "Work", root: "/kb/work")]
        #expect(InstanceList.resolve(listed, root: "/kb/work", named: "main").current == "work")
        let moved = InstanceList.resolve(listed, root: "/elsewhere/work", named: "work")
        #expect(moved.current == "work" && moved.instance("work")?.root == "/elsewhere/work" && moved.instances.count == 2)
        let unknown = InstanceList.resolve(listed, root: "/kb/clients", named: nil)
        #expect(unknown.instances.count == 3 && unknown.open.name == "Clients" && unknown.open.id == "clients")
    }

    @Test func addingRenamingAndForgetting() throws {
        var list = InstanceList(instances: [MindmillInstance(id: "main", name: "Main", root: "/kb/main")], current: "main")
        let work = try list.add(name: " Work ", root: "/kb/work")
        #expect(work.id == "work" && work.name == "Work")
        #expect(throws: InstanceError.self) { try list.add(name: "work", root: "/kb/other") }
        #expect(throws: InstanceError.self) { try list.add(name: "Inside", root: "/kb/main/inside") }
        #expect(throws: InstanceError.self) { try list.add(name: "Same", root: "/kb/work") }
        #expect(throws: InstanceError.self) { try list.add(name: "  ", root: "/kb/blank") }
        #expect(list.uniqueID(for: "Main") == "main-2" && list.uniqueID(for: "Work") == "work-2")
        try list.rename("work", to: "Clients")
        #expect(list.instance("work")?.name == "Clients")
        #expect(throws: InstanceError.self) { try list.forget("main") }
        try list.forget("work")
        #expect(list.instance("work") == nil)
    }

    @Test func savingKeepsTheConfigsOtherKeys() throws {
        try writeConfig(#"{"root": "/kb/main", "other": 1}"#)
        var list = InstanceList.load(configURL: config)
        try list.add(name: "Work", root: "/kb/work")
        list.current = "work"
        try list.save(configURL: config)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        #expect(json["root"] as? String == "/kb/work" && json["instance"] as? String == "work" && json["other"] as? Int == 1)
        #expect(KBConfig.loadRootPath(configURL: config) == "/kb/work")
        let again = InstanceList.load(configURL: config)
        #expect(again.current == "work" && again.instances.map(\.id) == ["main", "work"])
    }

    @Test func anInstanceFolderMustBeNewEmptyOrAKnowledgeBase() throws {
        let new = dir.appendingPathComponent("new")
        #expect(try InstanceFolder.prepare(new) == .new)
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("shared/kb.json").path))
        #expect(try InstanceFolder.prepare(new) == .knowledgeBase)
        let code = dir.appendingPathComponent("code")
        try FileManager.default.createDirectory(at: code.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(throws: InstanceError.self) { try InstanceFolder.prepare(code) }
    }

    @Test func foldersAreMadeOnlyUnderHomeWithPlainNames() throws {
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let made = try FolderListing.create(in: "~/projects", name: " New app ", home: home.path)
        #expect(made["path"]?.string == "~/projects/New app" && made["name"]?.string == "New app")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("projects/New app").path))
        for name in ["", ".hidden", "a/b", "New app"] {
            #expect(throws: (any Error).self) { try FolderListing.create(in: "~/projects", name: name, home: home.path) }
        }
        #expect(throws: (any Error).self) { try FolderListing.create(in: "/tmp", name: "x", home: home.path) }
    }
}

@Suite struct BackgroundAgentsTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kb-launcher-\(UUID().uuidString)")

    @Test func theProofMatchesTheDocumentedExample() {
        let hash = Digest.sha256Hex("test-token-123")
        #expect(hash == "19b6b086eebb807f54e6327309dec0ff347a6c3c30bf3bb396f167513eba3475")
        #expect(BackgroundAgents.proof(tokenHash: hash, nonce: "00112233445566778899aabbccddeeff")
                == "9b89935c64db57ff6439992d10224d8b92300607ba4067092741cc82d3a84e28")
    }

    @Test func plistsAndPorts() throws {
        let launcher = try #require(try PropertyListSerialization.propertyList(
            from: BackgroundAgents.launcherPlist(script: URL(fileURLWithPath: "/d/launcher.sh"), port: 7879), format: nil) as? [String: Any])
        #expect(launcher["Label"] as? String == BackgroundAgents.launcherLabel)
        #expect(((launcher["Sockets"] as? [String: Any])?["Listeners"] as? [String: Any])?["SockServiceName"] as? String == "7879")
        #expect(launcher["ProgramArguments"] as? [String] == ["/bin/bash", "/d/launcher.sh"])
        let login = try #require(try PropertyListSerialization.propertyList(
            from: BackgroundAgents.loginPlist(app: "/A/Mindmill.app", background: true), format: nil) as? [String: Any])
        #expect(login["RunAtLoad"] as? Bool == true)
        #expect(login["ProgramArguments"] as? [String] == ["/usr/bin/open", "-g", "-j", "-a", "/A/Mindmill.app", "--args", "--background"])
        #expect(BackgroundAgents.openCommand(app: "/A/Mindmill.app", background: false) == ["/usr/bin/open", "-a", "/A/Mindmill.app"])
        #expect(BackgroundAgents.launcherPort(remotePort: 7878) == 7879 && BackgroundAgents.launcherPort(remotePort: 65535) == 65534)
        #expect(BackgroundAgents.installedVersion(scriptText: BackgroundAgents.launcherScript(keys: URL(fileURLWithPath: "/k"), app: "/A"))
                == BackgroundAgents.launcherVersion)
    }

    /// Runs the script as launchd would, with a pipe for the socket, and answers its nonce.
    func ask(running: Bool, answer: (String) -> String) throws -> (reply: String, started: Bool) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys = dir.appendingPathComponent("launcher-keys")
        try BackgroundAgents.keysText(tokenHashes: ["aaaa", Digest.sha256Hex("test-token-123")]).write(to: keys, atomically: true, encoding: .utf8)
        let started = dir.appendingPathComponent("started-\(UUID().uuidString)")
        let script = dir.appendingPathComponent("launcher.sh")
        try BackgroundAgents.launcherScript(keys: keys.path, start: "/usr/bin/touch \(LidAwake.shellQuoted(started.path))",
                                            running: running ? "true" : "false").write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        var first = Data()
        while !first.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            first.append(chunk)
        }
        let greeting = String(decoding: first, as: UTF8.self).trimmingCharacters(in: .newlines)
        #expect(greeting.hasPrefix("MINDMILL 1 "))
        let nonce = String(greeting.dropFirst("MINDMILL 1 ".count))
        #expect(nonce.count == 32)
        input.fileHandleForWriting.write(Data((answer(nonce) + "\n").utf8))
        let rest = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: rest, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                FileManager.default.fileExists(atPath: started.path))
    }

    @Test func theLauncherStartsMindmillOnlyForAPairedPhone() throws {
        let hash = Digest.sha256Hex("test-token-123")
        let good = try ask(running: false) { "START " + BackgroundAgents.proof(tokenHash: hash, nonce: $0) }
        #expect(good.reply == "OK started" && good.started)
        let running = try ask(running: true) { "START " + BackgroundAgents.proof(tokenHash: hash, nonce: $0) }
        #expect(running.reply == "OK running" && !running.started)
        let stranger = try ask(running: false) { "START " + BackgroundAgents.proof(tokenHash: Digest.sha256Hex("other"), nonce: $0) }
        #expect(stranger.reply == "NO" && !stranger.started)
        let replayed = try ask(running: false) { _ in "START " + BackgroundAgents.proof(tokenHash: hash, nonce: "00112233445566778899aabbccddeeff") }
        #expect(replayed.reply == "NO" && !replayed.started)
        let garbage = try ask(running: false) { _ in "HELLO" }
        #expect(garbage.reply == "NO" && !garbage.started)
    }
}
