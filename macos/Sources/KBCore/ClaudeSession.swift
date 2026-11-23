import Foundation

/// A running process the session talks to. The real one is `ClaudeSubprocess`; tests use a fake.
public protocol ClaudeProcess: AnyObject, Sendable {
    func start(onLine: @escaping @Sendable (String) -> Void,
               onStderr: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws
    func write(_ line: String) throws
    func terminate()
}

/// One headless Claude session: writes user messages as JSON lines, one turn at a time, and turns stdout
/// into `events`. Messages sent while a turn runs wait in a queue and go out in order.
public final class ClaudeSession: @unchecked Sendable {
    public let events: AsyncStream<ClaudeEvent>
    private let continuation: AsyncStream<ClaudeEvent>.Continuation
    private let process: ClaudeProcess
    private let lock = NSLock()
    private var queue: [Outgoing] = []
    private var inFlight: Outgoing?
    private var running = false
    private var finished = false
    private var stderrTail: [String] = []
    private var _sessionID: String?

    public init(process: ClaudeProcess) {
        self.process = process
        var c: AsyncStream<ClaudeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    public var sessionID: String? { lock.withLock { _sessionID } }
    public var isBusy: Bool { lock.withLock { inFlight != nil } }
    public var queuedCount: Int { lock.withLock { queue.count } }
    public var isRunning: Bool { lock.withLock { running && !finished } }

    public func start() throws {
        try process.start(
            onLine: { [weak self] in self?.handle(line: $0) },
            onStderr: { [weak self] in self?.handle(stderr: $0) },
            onExit: { [weak self] in self?.handle(exit: $0) }
        )
        lock.withLock { running = true }
        pump()
    }

    private struct Outgoing {
        var text: String
        var tag: String?
        var images: [ImageBlock]
    }

    /// Queues a message. `tag` comes back on the turn's `turnStarted` and `turnResult`.
    public func send(_ text: String, tag: String? = nil, images: [ImageBlock] = []) {
        let dropped = lock.withLock { () -> Bool in
            if finished { return true }
            queue.append(Outgoing(text: text, tag: tag, images: images))
            return false
        }
        if dropped {
            continuation.yield(.error("Claude is not running; the message was not sent."))
            return
        }
        pump()
    }

    public func terminate() {
        process.terminate()
    }

    public enum CancelOutcome: Equatable, Sendable {
        /// It was still waiting in the queue and never reached Claude.
        case removed
        /// Claude was working on it and has been asked to stop; its turn ends with a result as usual.
        case interrupted
        case notFound
    }

    /// Takes back the message sent with `tag`: drops it from the queue, or interrupts the turn working on it.
    public func cancel(tag: String) -> CancelOutcome {
        let outcome = lock.withLock { () -> CancelOutcome in
            if let i = queue.firstIndex(where: { $0.tag == tag }) {
                queue.remove(at: i)
                return .removed
            }
            return inFlight?.tag == tag ? .interrupted : .notFound
        }
        if outcome == .interrupted {
            try? process.write(ClaudeStreamLine.interrupt(id: UUID().uuidString))
        }
        return outcome
    }

    private func pump() {
        let next: Outgoing? = lock.withLock {
            guard running, !finished, inFlight == nil, !queue.isEmpty else { return nil }
            let n = queue.removeFirst()
            inFlight = n
            return n
        }
        guard let next else { return }
        continuation.yield(.turnStarted(tag: next.tag))
        do {
            try process.write(ClaudeStreamLine.userMessage(next.text, images: next.images))
        } catch {
            lock.withLock { inFlight = nil }
            continuation.yield(.error("Could not send to Claude: \(error.localizedDescription)"))
        }
    }

    func handle(line: String) {
        for item in ClaudeStreamLine.parse(line) {
            switch item {
            case .initialized(let id):
                let isNew = lock.withLock { () -> Bool in
                    defer { _sessionID = id }
                    return _sessionID != id
                }
                if isNew { continuation.yield(.sessionStarted(id)) }
            case .connectors(let status):
                continuation.yield(.connectors(status))
            case .text(let t):
                continuation.yield(.assistantText(t))
            case .textDelta(let t):
                continuation.yield(.textDelta(t))
            case .toolUse(let name):
                continuation.yield(.toolUse(name))
            case .toolDetail(let name, let summary):
                continuation.yield(.toolDetail(name: name, summary: summary))
            case .commands(let list):
                continuation.yield(.commands(list))
            case .denied(let list):
                continuation.yield(.denied(list))
            case .result(let text, let isError):
                let tag = lock.withLock { () -> String? in
                    defer { inFlight = nil }
                    return inFlight?.tag
                }
                continuation.yield(.turnResult(text: text, isError: isError, tag: tag))
                pump()
            }
        }
    }

    func handle(stderr: String) {
        lock.withLock {
            stderrTail.append(stderr)
            if stderrTail.count > 20 { stderrTail.removeFirst(stderrTail.count - 20) }
        }
    }

    func handle(exit code: Int32) {
        let tail = lock.withLock { () -> String in
            finished = true
            inFlight = nil
            queue.removeAll()
            return stderrTail.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if code != 0 && code != 15 && code != 143 {
            continuation.yield(.error(tail.isEmpty ? "Claude exited with code \(code)." : tail))
        }
        continuation.yield(.exited(code))
        continuation.finish()
    }
}

/// The real `claude` process.
public final class ClaudeSubprocess: ClaudeProcess, @unchecked Sendable {
    private let launch: ClaudeLaunch
    private let process = Process()
    private let stdin = Pipe()
    private let lock = NSLock()

    public init(_ launch: ClaudeLaunch) {
        self.launch = launch
    }

    public var commandLine: String {
        ([launch.executable.path] + launch.arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }

    public func start(onLine: @escaping @Sendable (String) -> Void,
                      onStderr: @escaping @Sendable (String) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) throws {
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.workingDirectory
        if !launch.environment.isEmpty { process.environment = launch.environment }
        let out = Pipe()
        let err = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = err
        let outBuffer = LockedBuffer()
        let errBuffer = LockedBuffer()
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                if let rest = outBuffer.flush() { onLine(rest) }
                return
            }
            for line in outBuffer.append(data) { onLine(line) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            for line in errBuffer.append(data) { onStderr(line) }
        }
        process.terminationHandler = { p in
            // Let the readers drain what is left before reporting the exit.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                onExit(p.terminationStatus)
            }
        }
        try process.run()
    }

    public func write(_ line: String) throws {
        try lock.withLock {
            try stdin.fileHandleForWriting.write(contentsOf: Data(line.utf8))
        }
    }

    public func terminate() {
        if process.isRunning {
            try? stdin.fileHandleForWriting.close()
            process.terminate()
        }
    }
}

final class LockedBuffer: @unchecked Sendable {
    private var buffer = LineBuffer()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] { lock.withLock { buffer.append(data) } }
    func flush() -> String? { lock.withLock { buffer.flush() } }
}

/// Runs a one-shot `claude -p <prompt>` and returns its text output.
public enum ClaudeOneShot {
    public static func arguments(prompt: String, pluginRoot: String, model: String, allowedTools: [String]) -> [String] {
        var args = ["-p", prompt, "--plugin-dir", KBConfig.expandTilde(pluginRoot)]
        if !model.trimmingCharacters(in: .whitespaces).isEmpty { args += ["--model", model] }
        args += ["--allowedTools", allowedTools.joined(separator: " ")]
        return args
    }
}
