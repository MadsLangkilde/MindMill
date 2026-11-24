import Foundation

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String], stdin: String?, currentDirectory: URL?) async -> CommandResult
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], environment: [String: String], stdin: String?, currentDirectory: URL?) async -> CommandResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: Self.runSync(executable: executable, arguments: arguments, environment: environment,
                                                    stdin: stdin, currentDirectory: currentDirectory))
            }
        }
    }

    static func runSync(executable: URL, arguments: [String], environment: [String: String], stdin: String?, currentDirectory: URL?) -> CommandResult {
        #if !os(Windows)
        signal(SIGPIPE, SIG_IGN)
        #endif
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if !environment.isEmpty { p.environment = environment }
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        do { try p.run() } catch {
            return CommandResult(status: -1, stdout: "", stderr: "Could not run \(executable.path): \(error.localizedDescription)")
        }
        if let stdin {
            try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.wait()
        p.waitUntilExit()
        return CommandResult(status: p.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
    }
}

public struct KBCLIError: LocalizedError, Equatable {
    public let arguments: [String]
    public let status: Int32
    public let stderr: String

    public var errorDescription: String? {
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "kb \(arguments.prefix(2).joined(separator: " ")) failed (exit \(status))" + (msg.isEmpty ? "." : ": \(msg)")
    }
}

public enum Sprint: String, CaseIterable, Sendable, Identifiable {
    case current, next, none
    public var id: String { rawValue }
}

/// The plugin's `kb` CLI, run as `python3 <plugin root>/scripts/kb.py …` with `KB_ROOT` set to the app's root.
public struct KBCLI: Sendable {
    public var pluginRoot: URL
    public var kbRoot: URL
    public var python: URL
    /// Before the script: `-3` when `python` is Windows' `py` launcher.
    public var pythonArguments: [String]
    public var environment: [String: String]
    public var runner: CommandRunning

    public init(pluginRoot: URL, kbRoot: URL, python: URL = URL(fileURLWithPath: "/usr/bin/python3"), pythonArguments: [String] = [],
                environment: [String: String] = ProcessInfo.processInfo.environment, runner: CommandRunning = ProcessRunner()) {
        self.pluginRoot = pluginRoot
        self.kbRoot = kbRoot
        self.python = python
        self.pythonArguments = pythonArguments
        self.environment = environment
        self.runner = runner
    }

    public var script: URL { pluginRoot.appendingPathComponent("scripts").appendingPathComponent("kb.py") }

    public func result(_ args: [String], stdin: String? = nil) async -> CommandResult {
        var env = environment
        env["KB_ROOT"] = kbRoot.path
        return await runner.run(executable: python, arguments: pythonArguments + [script.path] + args, environment: env, stdin: stdin, currentDirectory: kbRoot)
    }

    /// Runs the CLI and returns stdout; a non-zero exit throws with stderr.
    @discardableResult
    public func run(_ args: [String], stdin: String? = nil) async throws -> String {
        let r = await result(args, stdin: stdin)
        guard r.status == 0 else { throw KBCLIError(arguments: args, status: r.status, stderr: r.stderr.isEmpty ? r.stdout : r.stderr) }
        return r.stdout
    }

    /// Returns the new entry's id (stdout line 1).
    public func approveInbox(_ id: EntryID) async throws -> String {
        let out = try await run(["inbox", "approve", id.rawValue])
        return out.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    public func rejectInbox(_ id: EntryID) async throws {
        try await run(["inbox", "reject", id.rawValue])
    }

    public struct CreatedWorkItem: Equatable, Sendable {
        public let id: String
        public let url: String
    }

    /// Posts the item to the tracker with its parent and related links. Parses `created <work item id> <url>`.
    /// `parent` overrides the entry's: a number, or `none`; nil leaves it to the entry and its text.
    public func createBacklog(_ id: EntryID, sprint: Sprint, parent: String? = nil) async throws -> CreatedWorkItem? {
        var args = ["backlog", "create", id.rawValue, "--yes", "--sprint", sprint.rawValue]
        if let parent { args += ["--parent", parent.isEmpty ? "none" : parent] }
        return Self.parseCreated(try await run(args))
    }

    /// Work items of the scope's tracker whose id is `query` or whose title has its words (`kb tracker find`).
    public func trackerFind(_ query: String, scope: String, limit: Int = 10) async throws -> [FoundWorkItem] {
        try FoundWorkItem.decode(try await run(["tracker", "find", query, "--scope", scope, "--limit", String(limit), "--json"]))
    }

    /// Checks the proposals waiting to be created against the tracker and each other.
    public func backlogDuplicates(scope: String?, entries: [EntryID] = [], offline: Bool = false) async throws -> DuplicateReport {
        var args = ["backlog", "duplicates", "--json"]
        if let scope { args += ["--scope", scope] }
        for e in entries { args += ["--entry", e.rawValue] }
        if offline { args.append("--offline") }
        return try DuplicateReport.decode(try await run(args))
    }

    /// Sets parent and related links in the tracker and the entries. Several targets are linked to each other.
    @discardableResult
    public func linkBacklog(_ targets: [String], parent: String?, related: [String], scope: String? = nil) async throws -> String {
        var args = ["backlog", "link"] + targets + ["--yes"]
        if let parent { args += ["--parent", parent.isEmpty ? "none" : parent] }
        for r in related { args += ["--related", r] }
        if let scope { args += ["--scope", scope] }
        return try await run(args)
    }

    /// Drops a proposal as a duplicate, optionally adding its notes as a comment on the existing item.
    public func dropBacklog(_ id: EntryID, duplicateOf: String, comment: Bool) async throws {
        try await run(["backlog", "drop", id.rawValue, "--duplicate-of", duplicateOf, "--yes"] + (comment ? ["--comment"] : []))
    }

    public func markNotDuplicate(_ id: EntryID, of others: [String]) async throws {
        try await run(["backlog", "not-duplicate", id.rawValue] + others)
    }

    public static func parseCreated(_ out: String) -> CreatedWorkItem? {
        for line in out.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ").map(String.init)
            if parts.count >= 3, parts[0] == "created" { return CreatedWorkItem(id: parts[1], url: parts[2]) }
        }
        return nil
    }

    /// What deleting would change elsewhere, one line per affected entry. Changes nothing.
    public func deletePlan(_ id: EntryID) async throws -> [String] {
        let out = try await run(["delete", id.rawValue, "--dry-run"])
        return out.components(separatedBy: .newlines).dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func deleteEntry(_ id: EntryID) async throws {
        try await run(["delete", id.rawValue])
    }

    public func rejectBacklog(_ id: EntryID) async throws {
        try await run(["backlog", "reject", id.rawValue])
    }

    public func closeFollowup(_ id: EntryID, status: FollowupStatus, resolvedBy: String?, answer: String?) async throws {
        var args = ["followup", "close", id.rawValue, "--status", status.rawValue]
        if let r = resolvedBy?.trimmingCharacters(in: .whitespaces), !r.isEmpty { args += ["--resolved-by", r] }
        if let a = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty { args += ["--answer", a] }
        try await run(args)
    }

    /// Proposes a fact through the inbox. Returns the inbox id the CLI prints.
    public func addInboxFact(project: String, title: String, proposedBy: String, reason: String, body: String) async throws -> String {
        let out = try await run(["inbox", "add", "--project", project, "--section", "facts", "--title", title,
                                 "--proposed-by", proposedBy, "--reason", reason, "--body-stdin"], stdin: body)
        return out.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    public func testSource(_ id: String, project: String?, query: String) async -> CommandResult {
        var args = ["sources", "test", id]
        if let project { args += ["--project", project] }
        args += ["--query", query]
        return await result(args)
    }
}

/// One `[n] <source id> — <ref> — <title>` line from an Ask answer.
public struct Citation: Equatable, Sendable, Identifiable {
    public let number: Int
    public let source: String
    public let ref: String
    public let title: String
    public var id: Int { number }

    public enum Target: Equatable, Sendable {
        case entry(EntryID)
        case file(String)
        case url(URL)
        case other(String)
    }

    /// Where the citation points. Claude sometimes swaps the columns, so the ref is tried first, then the source.
    public var target: Target {
        let candidates = [ref, source].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "`<> ")) }.filter { !$0.isEmpty }
        for r in candidates { if let id = EntryID(r) { return .entry(id) } }
        for r in candidates {
            if let u = URL(string: r), let s = u.scheme, ["http", "https"].contains(s) { return .url(u) }
        }
        for r in candidates where r.hasPrefix("/") || r.hasPrefix("~/") || r.hasPrefix("./") || (r.contains("/") && r.contains(".") && !r.contains(" ")) {
            return .file(r)
        }
        return .other(candidates.first ?? "")
    }
}

public struct AskAnswer: Equatable, Sendable {
    /// The answer without its `Sources:` block.
    public let body: String
    public let citations: [Citation]

    public static func parse(_ text: String) -> AskAnswer {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
            return t.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("sources:")
        }) else { return AskAnswer(body: text.trimmingCharacters(in: .whitespacesAndNewlines), citations: []) }
        var citations: [Citation] = []
        for line in lines[(start + 1)...] {
            if let c = parseLine(line) { citations.append(c) }
        }
        // Sources written on the heading line itself.
        if let c = parseLine(String(lines[start].drop(while: { $0 != ":" }).dropFirst())) { citations.insert(c, at: 0) }
        let body = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return AskAnswer(body: body, citations: citations)
    }

    static func parseLine(_ raw: String) -> Citation? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        for p in ["- ", "* "] where line.hasPrefix(p) { line = String(line.dropFirst(p.count)) }
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              let n = Int(line[line.index(after: line.startIndex)..<close]) else { return nil }
        let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        for sep in [" — ", " – ", " -- ", " - "] where rest.contains(sep) {
            parts = rest.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
            break
        }
        if parts.isEmpty { parts = [rest] }
        let source = parts[0]
        let ref = parts.count > 1 ? parts[1] : ""
        let title = parts.count > 2 ? parts[2...].joined(separator: " — ") : ""
        return Citation(number: n, source: source, ref: ref.replacingOccurrences(of: "`", with: ""), title: title)
    }
}
