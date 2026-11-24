import Foundation
import KBCore
import Testing
@testable import KBEngine

/// A transport without sockets: the test opens connections and reads what the hub sent.
final class FakeTransport: CompanionTransport {
    var listener: FakeListener?
    var networkChanged: (@MainActor (String, Bool) -> Void)?
    var failNext: String?
    let machineName = "Test PC"

    @MainActor func listen(port: Int, folder: URL) throws -> CompanionListening {
        if let failNext {
            self.failNext = nil
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: failNext])
        }
        let l = FakeListener()
        listener = l
        return l
    }

    @MainActor func watchNetwork(_ changed: @escaping @MainActor (String, Bool) -> Void) { networkChanged = changed }
    @MainActor func stopWatchingNetwork() { networkChanged = nil }
    func addresses() async -> (addresses: [String], tailscaleName: String?) { (["192.168.1.5"], nil) }
}

@MainActor
final class FakeListener: CompanionListening {
    let fingerprint = String(repeating: "ab", count: 32)
    var onState: ((CompanionListenerState) -> Void)?
    var onConnection: ((CompanionConnection) -> Void)?
    var cancelled = false

    func start() { onState?(.ready) }
    func cancel() { cancelled = true }
}

final class FakeConnection: CompanionConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    var onText: (@Sendable (String) -> Void)?
    var onClose: (@Sendable () -> Void)?
    var closed = false

    var sent: [JSONValue] {
        lock.withLock { _sent }.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    func start(onText: @escaping @Sendable (String) -> Void, onBinary: @escaping @Sendable (Data) -> Void,
               onClose: @escaping @Sendable () -> Void) {
        self.onText = onText
        self.onClose = onClose
    }

    func sendText(_ text: String) { lock.withLock { _sent.append(text) } }
    func sendBinary(_ data: Data) {}
    func close() { closed = true }
}

@MainActor
@Suite struct RemoteServerTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kb-hub-\(UUID().uuidString)")
    let defaults = UserDefaults(suiteName: "kb-hub-\(UUID().uuidString)")!

    func waitFor(_ c: FakeConnection, count: Int) async {
        for _ in 0..<200 where c.sent.count < count { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func request(_ c: FakeConnection, _ id: String, _ method: String, _ params: JSONValue = [:]) async {
        let msg: JSONValue = ["id": .string(id), "method": .string(method), "params": params]
        let before = c.sent.count
        c.onText?(msg.jsonString)
        await waitFor(c, count: before + 1)
    }

    @Test func pairsThenSaysHelloAndRoutesRequests() async throws {
        let transport = FakeTransport()
        let server = RemoteServer(transport: transport, folder: folder, defaults: defaults)
        server.handle = { client, method, params in ["method": .string(method), "device": .string(client.deviceName)] }
        server.start()
        #expect(server.isRunning)
        #expect(server.fingerprint.count == 64)

        let phone = FakeConnection()
        transport.listener?.onConnection?(phone)
        await request(phone, "1", "entries.list")
        #expect(phone.sent.last?["error"]?["code"]?.string == "unauthorized")

        await request(phone, "2", "pair", ["code": "000000", "name": "Pixel"])
        #expect(phone.sent.last?["error"]?["code"]?.string == "bad_code")

        server.pairing = PairingCode.new()
        let code = try #require(server.pairing?.code)
        #expect(server.invite()?.name == "Test PC")
        await request(phone, "3", "pair", ["code": .string(code), "name": "Pixel"])
        let token = try #require(phone.sent.last?["result"]?["token"]?.string)
        #expect(server.pairingOutcome == .paired(name: "Pixel"))
        #expect(server.connected.values.contains("Pixel"))

        let again = FakeConnection()
        transport.listener?.onConnection?(again)
        await request(again, "4", "hello", ["token": .string(token)])
        #expect(again.sent.last?["result"]?["device"]?.string == "Pixel")
        #expect(again.sent.last?["result"]?["method"]?.string == "hello")

        server.broadcast("index.changed")
        await waitFor(again, count: 2)
        #expect(again.sent.last?["event"]?.string == "index.changed")

        let deviceID = try #require(server.devices.devices.first?.id)
        server.revoke(deviceID)
        #expect(again.closed && phone.closed)
        let reloaded = RemoteServer(transport: FakeTransport(), folder: folder, defaults: defaults)
        #expect(reloaded.devices.devices.isEmpty)
    }

    @Test func platformsGetOnlyWhatTheyCanUseAndPushRegisters() async throws {
        let transport = FakeTransport()
        let server = RemoteServer(transport: transport, folder: folder, defaults: defaults)
        server.handle = { _, method, _ in ["method": .string(method)] }
        server.start()
        server.pairing = PairingCode.new()
        let iphone = FakeConnection()
        transport.listener?.onConnection?(iphone)
        await request(iphone, "1", "pair", ["code": .string(server.pairing!.code), "name": "iPhone", "platform": "ios"])
        let token = try #require(iphone.sent.last?["result"]?["token"]?.string)
        #expect(server.devices.devices.first?.platform == "ios")

        let android = FakeConnection()
        transport.listener?.onConnection?(android)
        server.pairing = PairingCode.new()
        await request(android, "1", "pair", ["code": .string(server.pairing!.code), "name": "Pixel", "platform": "android"])
        let old = FakeConnection()
        transport.listener?.onConnection?(old)
        server.pairing = PairingCode.new()
        await request(old, "1", "pair", ["code": .string(server.pairing!.code), "name": "Old phone"])

        let counts = (iphone.sent.count, android.sent.count, old.sent.count)
        server.broadcast("test.delivery", ["id": "d1", "kind": "apk"], platform: "android")
        server.broadcast("index.changed")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(iphone.sent.count == counts.0 + 1, "the iPhone gets index.changed, not the APK")
        #expect(android.sent.count == counts.1 + 2)
        #expect(old.sent.count == counts.2 + 2, "a phone that doesn't say gets everything")

        await request(iphone, "2", "push.register", ["token": .string(String(repeating: "ab", count: 32)), "environment": "sandbox", "topic": "dk.langkilde.mindmill"])
        #expect(iphone.sent.last?["result"]?["registered"] == .bool(false), "no push set up yet")
        var pushed: [(PushNote, [String])] = []
        server.push = { note, devices in pushed.append((note, devices.map(\.name))) }
        await request(iphone, "3", "push.register", ["token": .string(String(repeating: "ab", count: 32)), "environment": "sandbox", "topic": "dk.langkilde.mindmill"])
        #expect(iphone.sent.last?["result"]?["registered"] == .bool(true))

        server.sessionStateChanged(id: "s1", title: "Plan", state: "waiting")
        #expect(pushed.isEmpty, "the iPhone is connected, so it hears it there")
        iphone.onClose?()
        try? await Task.sleep(for: .milliseconds(50))
        server.sessionStateChanged(id: "s1", title: "Plan", state: "waiting")
        #expect(pushed.isEmpty, "only when it starts to need the user")
        server.sessionStateChanged(id: "s1", title: "Plan", state: "working")
        server.sessionStateChanged(id: "s1", title: "Plan", state: "waiting")
        #expect(pushed.map(\.1) == [["iPhone"]])
        server.factoryQuestionsChanged(id: "f", count: 1)
        server.factoryQuestionsChanged(id: "f", count: 1)
        #expect(pushed.count == 2)

        let again = FakeConnection()
        transport.listener?.onConnection?(again)
        await request(again, "4", "hello", ["token": .string(token)])
        #expect(server.devices.devices.first { $0.name == "iPhone" }?.push != nil)
    }

    @Test func wrongCodesStopTheCode() async {
        let transport = FakeTransport()
        let server = RemoteServer(transport: transport, folder: folder, defaults: defaults)
        server.start()
        server.pairing = PairingCode.new()
        let phone = FakeConnection()
        transport.listener?.onConnection?(phone)
        for i in 0..<RemoteServer.maxPairingAttempts {
            await request(phone, "\(i)", "pair", ["code": "x"])
        }
        #expect(server.pairing == nil)
        if case .failed = server.pairingOutcome {} else { Issue.record("expected the code to fail") }
    }

    @Test func aFailedListenTriesAgainAndTheNetworkRestartsIt() async {
        let transport = FakeTransport()
        transport.failNext = "Port 7878 is already in use by another app."
        let server = RemoteServer(transport: transport, folder: folder, defaults: defaults)
        server.start()
        #expect(server.error == "Port 7878 is already in use by another app.")
        if case .failed(_, let at) = server.status { #expect(at != nil) } else { Issue.record("expected failed") }
        transport.networkChanged?("a", true)
        transport.networkChanged?("b", true)
        #expect(server.isRunning)
        server.stop()
        #expect(server.status == .off && transport.networkChanged == nil)
    }
}

@Suite struct AdapterTests {
    @Test func voiceKeysAreNamedSecrets() {
        let store = MemorySecretStore()
        let keys = SecretVoiceKeys(store)
        keys.set("k1", provider: "openai")
        #expect(store.secret("voice-api/openai") == "k1")
        #expect(keys.has(provider: "openai"))
        keys.set("", provider: "openai")
        #expect(!store.hasSecret("voice-api/openai"))
    }

    @Test func keyTestRequestsUseEachProvidersHeader() {
        #expect(RealtimeKeyTest.request(provider: "openai", key: "k")?.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(RealtimeKeyTest.request(provider: "gemini", key: "k")?.value(forHTTPHeaderField: "x-goog-api-key") == "k")
        #expect(RealtimeKeyTest.request(provider: "nobody", key: "k") == nil)
    }
}

@MainActor
@Suite struct VoiceConversationTests {
    @Test func linesFollowWhatIsEmitted() {
        let c = VoiceConversation(scope: "android")
        var seen: [VoiceOutput] = []
        let key = c.listen { seen.append($0) }
        c.emit(.userSaid("hi"))
        c.emit(.done(turn: "t", text: "hello"))
        c.emit(.state(.listening))
        #expect(c.lines.map(\.text) == ["hi", "hello"])
        #expect(seen.count == 3)
        c.stopListening(key)
        #expect(!c.hasListeners)
    }
}

@Suite struct ShellInvocationTests {
    @Test func windowsPrefersGitBashOverWSLAndCmd() {
        let env = ["ProgramFiles": #"C:\Program Files"#, "Path": #"C:\Windows\System32"#, "SystemRoot": #"C:\Windows"#]
        let git: Set<String> = [#"C:\Program Files\Git\bin\bash.exe"#, #"C:\Windows\System32\bash.exe"#]
        #expect(ShellInvocation.windows("ls", environment: env, exists: git.contains)
            == ShellInvocation(executable: URL(fileURLWithPath: #"C:\Program Files\Git\bin\bash.exe"#), arguments: ["-c", "ls"]))
        let wslOnly: Set<String> = [#"C:\Windows\System32\bash.exe"#]
        #expect(ShellInvocation.windows("ls", environment: env, exists: wslOnly.contains).arguments == ["/d", "/c", "ls"])
        let custom = env.merging(["CLAUDE_CODE_GIT_BASH_PATH": #"D:\Git\bin\bash.exe"#]) { $1 }
        #expect(ShellInvocation.gitBash(environment: custom, exists: { $0.hasPrefix("D:") }) == #"D:\Git\bin\bash.exe"#)
    }

    #if os(macOS)
    @Test func macUsesZsh() {
        #expect(ShellInvocation.current("echo hi").executable.path == "/bin/zsh")
    }
    #endif
}

@Suite struct PayloadTests {
    @Test func actionTextPhrases() {
        #expect(ActionText.intParam(.string("#42")) == 42)
        #expect(ActionText.intParam(.number(7)) == 7)
        #expect(ActionText.count(1, "item") == "1 item" && ActionText.count(2, "item") == "2 items")
        #expect(ActionText.list(["a", "b", "c"], or: true) == "a, b or c")
        #expect(ActionText.day("2026-01-02") == "2026-01-02")
    }

    @Test func voiceEventsForPhones() {
        #expect(VoiceOutput.state(.listening).remoteEvent(conversation: "c")?.0 == "voice.state")
        #expect(VoiceOutput.userSaid("x").remoteEvent(conversation: "c") == nil)
    }
}

@Suite struct FactoryDecisionTests {
    typealias View = FactoryDecisions.SessionView

    @Test func aTaskHoldsItsPlaceUntilItsPullRequestMoves() {
        var t = FactoryTask(workItem: 1, title: "X", scope: "a", sessionID: "s")
        #expect(FactoryDecisions.occupiesSlot(t, session: View(exists: true), hasOpenQuestion: false))
        #expect(FactoryDecisions.occupiesSlot(t, session: View(exists: true, work: .running), hasOpenQuestion: false))
        #expect(!FactoryDecisions.occupiesSlot(t, session: View(exists: true, work: .inReview), hasOpenQuestion: false))
        #expect(FactoryDecisions.occupiesSlot(t, session: View(exists: true, busy: true, work: .inReview), hasOpenQuestion: false))
        #expect(FactoryDecisions.occupiesSlot(t, session: View(exists: true, work: .inReview), hasOpenQuestion: true))
        #expect(!FactoryDecisions.occupiesSlot(t, session: View(exists: false), hasOpenQuestion: false))
        t.outcome = "Pushed"
        #expect(!FactoryDecisions.occupiesSlot(t, session: View(exists: true), hasOpenQuestion: false))
    }

    @Test func outcomes() {
        #expect(FactoryDecisions.outcome(session: View(exists: false), stage: nil) == "Session deleted")
        #expect(FactoryDecisions.outcome(session: View(exists: true, archived: true), stage: nil) == "Session archived")
        #expect(FactoryDecisions.outcome(session: View(exists: true), stage: .done) == "Resolved")
        #expect(FactoryDecisions.outcome(session: View(exists: true, work: .resolved), stage: nil) == "Resolved")
        #expect(FactoryDecisions.outcome(session: View(exists: true, work: .inReview), stage: .inPR) == nil)
    }

    @Test func timeAndExclusions() {
        let start = Date()
        let run = FactoryRun(started: start, endsAt: start.addingTimeInterval(60))
        #expect(!FactoryDecisions.timeIsUp(run, now: start))
        #expect(FactoryDecisions.timeIsUp(run, now: start.addingTimeInterval(61)))
        #expect(!FactoryDecisions.windDownComplete(run, anyBusy: false))
        var mine = run
        mine.tasks = [FactoryTask(workItem: 1, title: "", scope: "a", sessionID: "s")]
        mine.skipped = [2]
        var other = Factory(name: "Other")
        other.run = FactoryRun(endsAt: nil)
        other.run?.tasks = [FactoryTask(workItem: 5, title: "", scope: "a", sessionID: "t")]
        #expect(FactoryDecisions.excluded(run: mine, assigning: [3], withLiveSession: [4], otherFactories: [other]) == [1, 2, 3, 4, 5])
    }
}

@Suite struct CrewFilesTests {
    @Test func ordersAreTakenOldestFirstAndStateIsWritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kb-crew-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let crew = CrewFiles(directory: dir)
        crew.prepare()
        try Data("b".utf8).write(to: crew.ordersFolder.appendingPathComponent("2.json"))
        try Data("a".utf8).write(to: crew.ordersFolder.appendingPathComponent("1.json"))
        try Data("x".utf8).write(to: crew.ordersFolder.appendingPathComponent("1.tmp"))
        #expect(crew.takeOrders().map { String(decoding: $0, as: UTF8.self) } == ["a", "b"])
        #expect(crew.takeOrders().isEmpty)
        let state = CrewState(updated: "now", sessions: [])
        try crew.write(state)
        #expect(FileManager.default.fileExists(atPath: crew.stateURL.path))
        #expect(!CrewFiles.needsWrite(state, last: state, dirty: false, written: Date()))
        #expect(CrewFiles.needsWrite(state, last: state, dirty: true, written: Date()))
        #expect(CrewFiles.needsWrite(state, last: state, dirty: false, written: Date().addingTimeInterval(-31)))
    }
}
