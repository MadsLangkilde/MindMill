import Foundation
import KBCore
import Observation

/// The Test menu's state: each scope's plan, what this Mac has, deliveries and review cards.
@MainActor
@Observable
final class TestCenter {
    var store = TestStore.load()
    var facts = TestEnvironmentFacts()
    var gathering = false
    var ask = TestAsk()
    /// Scopes whose compatibility check is running.
    var checking: Set<String> = []
    /// Targets whose delivery is running, with what it is doing.
    var working: [String: String] = [:]
    var deliveries: [TestDelivery] = []
    var cards: [TestReviewCard] = []
    /// The scope the Test view shows, and a type to put first when a prompt opened it.
    var selectedScope: String?
    var preselectType: ProjectType?
    /// Last output per target, for the "Last run" log under More options.
    var logs: [String: String] = [:]
    @ObservationIgnored var listings: [String: RepoListing] = [:]
    @ObservationIgnored var servers: [String: Process] = [:]
    @ObservationIgnored var serverOutput: [String: String] = [:]
    @ObservationIgnored var lastAutoDelivery: [String: Date] = [:]

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KB/deliveries")
    }

    static var historyURL: URL { folder.appendingPathComponent("history.json") }

    init() {
        loadHistory()
    }

    func save() { store.save() }

    func edit(_ scope: String, _ change: (inout ScopeTestPlan) -> Void) {
        change(&store[scope])
        save()
    }

    func editTarget(_ scope: String, _ id: String, _ change: (inout TestTarget) -> Void) {
        edit(scope) { plan in
            if let i = plan.targets.firstIndex(where: { $0.id == id }) { change(&plan.targets[i]) }
        }
    }

    func folder(_ id: String) -> URL {
        let url = Self.folder.appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func update(_ d: TestDelivery) {
        if let i = deliveries.firstIndex(where: { $0.id == d.id }) { deliveries[i] = d } else { deliveries.insert(d, at: 0) }
        if deliveries.count > 40 {
            for old in deliveries.dropFirst(40) { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(old.id)) }
            deliveries = Array(deliveries.prefix(40))
        }
        saveHistory()
    }

    func add(_ card: TestReviewCard) {
        cards.insert(card, at: 0)
        if cards.count > 40 {
            for old in cards.dropFirst(40) { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(old.id)) }
            cards = Array(cards.prefix(40))
        }
        saveHistory()
    }

    func respond(_ id: String, _ response: String) {
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
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? e.encode(History(deliveries: deliveries, cards: cards)) { try? data.write(to: Self.historyURL, options: .atomic) }
    }

    private func loadHistory() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.historyURL), let h = try? d.decode(History.self, from: data) else { return }
        deliveries = h.deliveries
        cards = h.cards
    }

    func stopServers() {
        for p in servers.values where p.isRunning { p.terminate() }
        servers = [:]
    }
}

/// Runs shell commands for testing with the user's login environment.
enum TestShell {
    struct Result {
        var code: Int32
        var output: String
    }

    nonisolated static func run(_ command: String, cwd: URL? = nil, environment: [String: String], timeout: TimeInterval = 900) async -> Result {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", command]
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

    /// Single-quoted for zsh.
    nonisolated static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
