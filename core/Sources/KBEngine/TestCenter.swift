import Foundation
import KBCore
import KBEngine
import Observation

/// The Test menu's state: each scope's plan, what this machine has, deliveries and review cards.
@MainActor
@Observable
public final class TestCenter {
    public var store: TestStore
    public var facts = TestEnvironmentFacts()
    public var gathering = false
    public var ask = TestAsk()
    /// Scopes whose compatibility check is running.
    public var checking: Set<String> = []
    /// Targets whose delivery is running, with what it is doing.
    public var working: [String: String] = [:]
    public var deliveries: [TestDelivery] = []
    public var cards: [TestReviewCard] = []
    /// The scope the Test view shows, and a type to put first when a prompt opened it.
    public var selectedScope: String?
    public var preselectType: ProjectType?
    /// Last output per target, for the "Last run" log under More options.
    public var logs: [String: String] = [:]
    @ObservationIgnored public var listings: [String: RepoListing] = [:]
    @ObservationIgnored public var servers: [String: Process] = [:]
    @ObservationIgnored public var serverOutput: [String: String] = [:]
    @ObservationIgnored public var lastAutoDelivery: [String: Date] = [:]

    nonisolated public static var folder: URL {
        AppPaths.file("deliveries")
    }

    nonisolated public static var historyURL: URL { folder.appendingPathComponent("history.json") }

    /// Where deliveries, review cards and their history are kept, and the testing plans.
    public let root: URL
    public let storeURL: URL
    var historyURL: URL { root.appendingPathComponent("history.json") }

    public init(root: URL = TestCenter.folder, storeURL: URL = TestStore.defaultURL) {
        self.root = root
        self.storeURL = storeURL
        store = TestStore.load(storeURL)
        loadHistory()
    }

    public func save() { store.save(storeURL) }

    public func edit(_ scope: String, _ change: (inout ScopeTestPlan) -> Void) {
        change(&store[scope])
        save()
    }

    public func editTarget(_ scope: String, _ id: String, _ change: (inout TestTarget) -> Void) {
        edit(scope) { plan in
            if let i = plan.targets.firstIndex(where: { $0.id == id }) { change(&plan.targets[i]) }
        }
    }

    public func folder(_ id: String) -> URL {
        let url = root.appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func update(_ d: TestDelivery) {
        if let i = deliveries.firstIndex(where: { $0.id == d.id }) { deliveries[i] = d } else { deliveries.insert(d, at: 0) }
        if deliveries.count > 40 {
            for old in deliveries.dropFirst(40) { try? FileManager.default.removeItem(at: root.appendingPathComponent(old.id)) }
            deliveries = Array(deliveries.prefix(40))
        }
        saveHistory()
    }

    public func add(_ card: TestReviewCard) {
        cards.insert(card, at: 0)
        if cards.count > 40 {
            for old in cards.dropFirst(40) { try? FileManager.default.removeItem(at: root.appendingPathComponent(old.id)) }
            cards = Array(cards.prefix(40))
        }
        saveHistory()
    }

    public func respond(_ id: String, _ response: String) {
        if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].response = response }
        saveHistory()
    }

    private struct History: Codable {
        var deliveries: [TestDelivery]
        var cards: [TestReviewCard]
    }

    private func saveHistory() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? e.encode(History(deliveries: deliveries, cards: cards)) { try? data.write(to: historyURL, options: .atomic) }
    }

    private func loadHistory() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: historyURL), let h = try? d.decode(History.self, from: data) else { return }
        deliveries = h.deliveries
        cards = h.cards
    }

    public func stopServers() {
        for p in servers.values where p.isRunning { p.terminate() }
        servers = [:]
    }
}

/// Runs shell commands for testing with the user's login environment: zsh on macOS, Git Bash on Windows (Claude Code
/// needs Git for Windows anyway), so the same POSIX commands and `quote` work on both.
public enum TestShell {
    /// What `command` printed, trimmed, when it succeeded and printed something.
    public nonisolated static func output(_ command: String, environment: [String: String], timeout: TimeInterval = 20) async -> String? {
        let r = await run(command, environment: environment, timeout: timeout)
        let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.code == 0 && !out.isEmpty ? out : nil
    }

    /// Runs every probe at once (name, command) and gives each one's first line of output, for those that worked.
    public nonisolated static func probe(_ probes: [(String, String)], environment: [String: String], timeout: TimeInterval = 10) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for (name, command) in probes {
                group.addTask { (name, await output(command + " 2>&1", environment: environment, timeout: timeout)) }
            }
            var found: [String: String] = [:]
            for await (name, out) in group {
                if let line = out?.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) { found[name] = line }
            }
            return found
        }
    }

    public struct Result {
        public var code: Int32
        public var output: String

        public init(code: Int32, output: String) {
            self.code = code
            self.output = output
        }
    }

    public nonisolated static func run(_ command: String, cwd: URL? = nil, environment: [String: String], timeout: TimeInterval = 900) async -> Result {
        await Task.detached {
            let p = Process()
            let shell = ShellInvocation.current(command)
            p.executableURL = shell.executable
            p.arguments = shell.arguments
            p.environment = environment
            if let cwd { p.currentDirectoryURL = cwd }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            let buffer = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { h in buffer.append(h.availableData) }
            do { try p.run() } catch { return Result(code: -1, output: error.localizedDescription) }
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            var timedOut = false
            if p.isRunning { p.terminate(); timedOut = true }
            p.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
            var out = buffer.text
            if timedOut { out += "\n[Stopped after \(Int(timeout)) seconds]" }
            return Result(code: timedOut ? -2 : p.terminationStatus, output: out)
        }.value
    }

    final class OutputBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.withLock { data.append(d) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    /// Single-quoted for zsh and bash.
    public nonisolated static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
