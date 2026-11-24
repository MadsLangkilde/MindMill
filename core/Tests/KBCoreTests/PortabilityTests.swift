import Foundation
import Testing
@testable import KBCore
#if canImport(CryptoKit)
import CryptoKit
#endif

@Suite struct PortabilityTests {
    @Test func portableSHA256MatchesKnownVectors() {
        func hex(_ s: String) -> String { PortableSHA256.hash(Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        #expect(hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    #if canImport(CryptoKit)
    @Test func portableSHA256MatchesCryptoKit() {
        for n in [0, 1, 55, 56, 63, 64, 65, 119, 120, 1000, 70_000] {
            let data = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            let kit = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(PortableSHA256.hash(data).map { String(format: "%02x", $0) }.joined() == kit)
            #expect(Digest.sha256Hex(data) == kit)
        }
    }
    #endif

    @Test func gitPathsAreIgnoredWithEitherSeparator() {
        #expect(FileWatchers.isInsideGit("/r/.git/index"))
        #expect(FileWatchers.isInsideGit(#"C:\r\.git\index"#))
        #expect(FileWatchers.isInsideGit("/r/.git"))
        #expect(!FileWatchers.isInsideGit("/r/.github/workflows/a.yml"))
    }

    @Test func pollingSnapshotsFindAddedChangedAndRemovedFiles() {
        typealias S = PollingFileWatcher.Stamp
        let t = Date()
        let old: [String: S] = ["/a": S(modified: t, size: 1), "/b": S(modified: t, size: 1), "/c": S(modified: t, size: 1)]
        let new: [String: S] = ["/a": S(modified: t, size: 1), "/b": S(modified: t, size: 2), "/d": S(modified: t, size: 1)]
        #expect(PollingFileWatcher.changes(from: old, to: new) == ["/b", "/c", "/d"])
    }

    @Test func pollingWatcherReportsANewFileAndSkipsGit() async throws {
        let dir = try TempDir()
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let queue = DispatchQueue(label: "poll-test")
        let received = await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            let once = OnceBox(cont)
            let watcher = PollingFileWatcher(path: dir.url.path, debounce: 0.05, interval: 0.1, callbackQueue: queue) { once.resume($0) }
            #expect(watcher.start())
            once.keepAlive = watcher
            queue.asyncAfter(deadline: .now() + 0.3) {
                try? Data("x".utf8).write(to: dir.url.appendingPathComponent(".git/HEAD"))
                try? Data("x".utf8).write(to: dir.url.appendingPathComponent("a.md"))
            }
            queue.asyncAfter(deadline: .now() + 10) { once.resume([]) }
        }
        #expect(received.contains { $0.hasSuffix("a.md") })
        #expect(!received.contains { FileWatchers.isInsideGit($0) })
        #expect(PollingFileWatcher(path: dir.url.appendingPathComponent("missing").path) { _ in }.start() == false)
    }

    @Test func fingerprintIsTheCertificatesSHA256() {
        #expect(CertificateFingerprint.of(der: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct AppPathsTests {
    @Test func dataFolderPerPlatform() {
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support")
        #expect(AppPaths.dataFolder(windows: false, environment: [:], applicationSupport: support).path
            == "/Users/me/Library/Application Support/KB")
        #expect(AppPaths.dataFolder(windows: true, environment: ["APPDATA": "/appdata/Roaming"], applicationSupport: support).path
            == "/appdata/Roaming/Mindmill")
        #expect(AppPaths.dataFolder(windows: true, environment: [:], applicationSupport: support).lastPathComponent == "Mindmill")
        #if os(macOS)
        #expect(AppPaths.file("crew").path.hasSuffix("/Library/Application Support/KB/crew"))
        #expect(CrewDir.url(environment: [:]) == AppPaths.file("crew"))
        #endif
    }

    @Test func tildeWorksWithWindowsSeparators() {
        let home = #"C:\Users\me"#
        #expect(KBConfig.abbreviateTilde(#"C:\Users\me\knowledgebase\shared"#, home: home) == "~/knowledgebase/shared")
        #expect(KBConfig.abbreviateTilde(#"c:\users\me\repo"#, home: home) == "~/repo")
        #expect(KBConfig.abbreviateTilde(#"D:\other"#, home: home) == #"D:\other"#)
        #expect(KBConfig.expandTilde("~/knowledgebase", home: home) == #"C:\Users\me/knowledgebase"#)
        #expect(KBConfig.expandTilde(#"~\knowledgebase"#, home: home) == #"C:\Users\me/knowledgebase"#)
        #expect(KBConfig.expandTilde("~/a", home: "/Users/me") == "/Users/me/a")
        #expect(KBConfig.abbreviateTilde("/Users/me/a", home: "/Users/me") == "~/a")
    }
}

@Suite struct WindowsToolsTests {
    let env = ["Path": #"C:\Windows\system32;C:\Users\me\AppData\Local\Microsoft\WindowsApps;"C:\Tools\bin""#,
               "USERPROFILE": #"C:\Users\me"#, "LOCALAPPDATA": #"C:\Users\me\AppData\Local"#, "SystemRoot": #"C:\Windows"#]

    @Test func pathIsReadWhateverItsCase() {
        #expect(WindowsTools.pathFolders(env) == [#"C:\Windows\system32"#, #"C:\Users\me\AppData\Local\Microsoft\WindowsApps"#, #"C:\Tools\bin"#])
    }

    @Test func claudeComesFromPathThenTheNativeInstall() {
        let onPath: Set<String> = [#"C:\Tools\bin\claude.exe"#, #"C:\Users\me\.local\bin\claude.exe"#]
        #expect(WindowsTools.claude(environment: env, exists: onPath.contains) == #"C:\Tools\bin\claude.exe"#)
        let native: Set<String> = [#"C:\Users\me\.local\bin\claude.exe"#, #"C:\Tools\bin\claude.cmd"#]
        #expect(WindowsTools.claude(environment: env, exists: native.contains) == #"C:\Users\me\.local\bin\claude.exe"#)
        #expect(WindowsTools.claude(environment: env, exists: { _ in false }) == nil)
    }

    @Test func pythonSkipsTheStoreStubAndFallsBackToTheLauncher() {
        let stub: Set<String> = [#"C:\Users\me\AppData\Local\Microsoft\WindowsApps\python.exe"#, #"C:\Windows\py.exe"#]
        #expect(WindowsTools.python(environment: env, exists: stub.contains, listDirectory: { _ in [] })
            == WindowsTools.Python(path: #"C:\Windows\py.exe"#, arguments: ["-3"]))
        let real: Set<String> = [#"C:\Tools\bin\python.exe"#, #"C:\Windows\py.exe"#]
        #expect(WindowsTools.python(environment: env, exists: real.contains, listDirectory: { _ in [] })?.path == #"C:\Tools\bin\python.exe"#)
    }

    @Test func pythonFindsTheNewestPerUserInstall() {
        let installs: Set<String> = [#"C:\Users\me\AppData\Local\Programs\Python\Python39\python.exe"#,
                                     #"C:\Users\me\AppData\Local\Programs\Python\Python312\python.exe"#]
        let py = WindowsTools.python(environment: env, exists: installs.contains, listDirectory: { _ in ["Python39", "Python312", "Launcher"] })
        #expect(py == WindowsTools.Python(path: #"C:\Users\me\AppData\Local\Programs\Python\Python312\python.exe"#, arguments: []))
    }

    @Test func pythonArgumentsGoBeforeTheScript() async {
        final class Spy: CommandRunning, @unchecked Sendable {
            var args: [String] = []
            func run(executable: URL, arguments: [String], environment: [String: String], stdin: String?, currentDirectory: URL?) async -> CommandResult {
                args = arguments
                return CommandResult(status: 0, stdout: "", stderr: "")
            }
        }
        let spy = Spy()
        let cli = KBCLI(pluginRoot: URL(fileURLWithPath: "/p"), kbRoot: URL(fileURLWithPath: "/k"), python: URL(fileURLWithPath: "/py"),
                        pythonArguments: ["-3"], environment: [:], runner: spy)
        _ = await cli.result(["list"])
        #expect(spy.args == ["-3", "/p/scripts/kb.py", "list"])
    }
}
