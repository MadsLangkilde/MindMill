import Foundation
import KBCore
import Observation

/// Project scans: a Claude Code session reads a scope's repository and records findings with `kb scan`; the user
/// adds the ones worth keeping to the knowledge base. The runs live in the scan folder (`ScanDir`).
@MainActor
@Observable
public final class ScanRunner {
    public static let tools = ["Read", "Grep", "Glob", "Bash(kb:*)", "Bash(git log:*)", "Bash(git -C:*)", "Bash(git show:*)",
                               "Bash(git blame:*)", "Bash(ls:*)"]

    public var list: [ScanRun] = []
    /// Findings being added to the knowledge base right now.
    public var applying: Set<String> = []
    /// What each running scan's session is doing, one line.
    public var activity: [String: String] = [:]

    /// The scans started (the first id), for the host to show it.
    @ObservationIgnored public var onStarted: ((String) -> Void)?
    /// A scan was thrown away.
    @ObservationIgnored public var onDeleted: ((String) -> Void)?

    @ObservationIgnored unowned let engine: MindmillEngine
    @ObservationIgnored var chats: [String: ClaudeChat] = [:]
    @ObservationIgnored var lastRead = Date.distantPast
    @ObservationIgnored var loaded = false
    @ObservationIgnored public var directory: URL = ScanDir.url()

    init(engine: MindmillEngine) {
        self.engine = engine
    }

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    public func reload() {
        lastRead = Date()
        let fresh = ScanRun.loadAll(dir: directory)
        if fresh != list { list = fresh }
    }

    /// While a scan runs, its findings show up as it records them.
    public func tick() {
        guard !chats.isEmpty, Date().timeIntervalSince(lastRead) > 2 else { return }
        reload()
    }

    public func scan(_ id: String) -> ScanRun? { list.first { $0.id == id } }

    public func isScanning(_ id: String) -> Bool { chats[id] != nil && !(scan(id)?.isFinished ?? true) }

    /// Scans of the project `group`'s scopes, newest first.
    public func scans(group: String) -> [ScanRun] {
        let ids = Set(engine.index.groups.first { $0.id == group }?.scopes ?? [])
        return list.filter { ids.contains($0.scope) }
    }

    public func pendingFindings(group: String) -> Int {
        scans(group: group).reduce(0) { $0 + $1.pending.count }
    }

    // MARK: Scanning

    public func start(scopes: [String], kinds: [ScanKind], sources: [ScanSource], focus: String) {
        guard engine.claudeExecutable != nil else {
            engine.report(engine.claudeMissingExplanation, error: true)
            return
        }
        Task {
            var first: String?
            for scope in scopes {
                if let id = await start(scope: scope, kinds: kinds, sources: sources, focus: focus), first == nil { first = id }
            }
            reload()
            if let first { onStarted?(first) }
        }
    }

    private func start(scope: String, kinds: [ScanKind], sources: [ScanSource], focus: String) async -> String? {
        let index = engine.index
        guard let p = index.project(scope), let checkout = ScopeRepo.of(paths: p.paths).checkout else {
            engine.report("\(index.project(scope)?.title ?? scope) has no repository on this \(engine.platform.machineWord). Locate it first.", error: true)
            return nil
        }
        var args = ["scan", "new", "--scope", scope, "--kinds", kinds.map(\.rawValue).joined(separator: ","),
                    "--sources", sources.map(\.rawValue).joined(separator: ",")]
        if !focus.trimmingCharacters(in: .whitespaces).isEmpty { args += ["--focus", focus] }
        let cli = engine.cli
        let id: String
        do {
            id = try await cli.run(args).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            engine.report(Self.message(error), error: true)
            return nil
        }
        reload()
        guard let run = scan(id) else { return nil }
        let group = index.group(of: scope)
        let siblings = (group?.scopes ?? []).compactMap { index.project($0) }
        let wide = siblings.first { $0.wide && $0.id != scope }?.id
        let others = siblings.filter { !$0.wide && $0.id != scope }.map(\.id)
        let hasOverview = index.entry(EntryID(project: scope, section: .overview, stem: "overview")) != nil
        let prompt = ScanPrompt.system(run: run, scopeTitle: p.title, project: group?.title ?? p.title, wideScope: wide,
                                       otherScopes: others, checkout: checkout.path, hasOverview: hasOverview)
        guard var launch = engine.launch(prompt: prompt, sessionID: UUID().uuidString.lowercased(), resume: false,
                                         model: engine.model(for: .work), cwd: checkout, tools: Self.tools) else { return nil }
        launch.disallowedTools = ["Write", "Edit", "NotebookEdit"]
        let chat = ClaudeChat()
        chat.onEvent = { [weak self] event in
            Task { @MainActor in self?.event(id, event) }
        }
        do {
            try chat.start(launch, mode: "scan")
        } catch {
            _ = try? await cli.run(["scan", "done", "--run", id, "--failed", "--note", error.localizedDescription])
            reload()
            return nil
        }
        chats[id] = chat
        chat.send(ScanPrompt.start, tag: "scan", show: false)
        return id
    }

    private func event(_ id: String, _ event: ClaudeEvent) {
        switch event {
        case .toolDetail(_, let summary):
            activity[id] = summary
        case .turnResult(let text, let isError, _):
            finish(id, note: text, failed: isError)
        case .exited:
            finish(id, note: "\(Brain.name) stopped before the scan was done.", failed: true)
        default:
            break
        }
    }

    /// Ends a scan's session; marks the run done when the session didn't.
    private func finish(_ id: String, note: String, failed: Bool) {
        guard let chat = chats.removeValue(forKey: id) else { return }
        chat.onEvent = nil
        chat.stop()
        activity[id] = nil
        reload()
        let title = scan(id).flatMap { engine.index.project($0.scope)?.title } ?? "the repository"
        if scan(id)?.isFinished == false {
            let line = note.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let cli = engine.cli
            Task {
                _ = try? await cli.run(["scan", "done", "--run", id, "--note", String(line.prefix(300))] + (failed ? ["--failed"] : []))
                reload()
                announce(id, title: title)
            }
        } else {
            announce(id, title: title)
        }
    }

    private func announce(_ id: String, title: String) {
        guard let run = scan(id) else { return }
        engine.report(run.failed ? "The scan of \(title) stopped: \(run.note)"
                      : "The scan of \(title) found \(run.pending.count) thing\(run.pending.count == 1 ? "" : "s") to review.")
    }

    public func stop(_ id: String) {
        guard let chat = chats.removeValue(forKey: id) else { return }
        chat.onEvent = nil
        chat.stop()
        activity[id] = nil
        let cli = engine.cli
        Task {
            _ = try? await cli.run(["scan", "done", "--run", id, "--note", "Stopped by you."])
            reload()
        }
    }

    public func apply(run: String, ids: [String]) {
        guard !ids.isEmpty else { return }
        applying.formUnion(ids)
        let cli = engine.cli
        Task {
            defer { applying.subtract(ids) }
            do {
                let out = try await cli.run(["scan", "apply", "--run", run] + ids)
                let n = out.split(whereSeparator: \.isNewline).count
                engine.reload()
                reload()
                engine.report("Added \(n) to the knowledge base.")
            } catch {
                reload()
                engine.report(Self.message(error), error: true)
            }
        }
    }

    public func dismiss(run: String, ids: [String]) {
        guard !ids.isEmpty else { return }
        let cli = engine.cli
        Task {
            _ = try? await cli.run(["scan", "dismiss", "--run", run] + ids)
            reload()
        }
    }

    /// Throws a finished scan away, with what it found and didn't add.
    public func delete(_ id: String) {
        guard !isScanning(id) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).jsonl"))
        onDeleted?(id)
        reload()
    }

    static func message(_ error: Error) -> String {
        (error as? KBCLIError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription
    }

    // MARK: Actions

    func register(on a: ActionLayer) {
        a.register("scans.list") { [unowned self] _ in
            loadIfNeeded()
            guard !list.isEmpty else { return ActionResult("No scans yet.") }
            let running = list.filter { $0.finished == nil && !$0.failed }.count
            return ActionResult("\(ActionText.count(list.count, "scan"))" + (running > 0 ? ", \(running) running." : "."),
                                data: ["scans": .array(list.map { s in
                                    ["id": .string(s.id), "scope": .string(s.scope), "kinds": .array(s.kinds.map { .string($0.rawValue) }),
                                     "running": .bool(s.finished == nil && !s.failed), "failed": .bool(s.failed), "note": .string(s.note),
                                     "findings": .array(s.findings.map { f in
                                         ["id": .string(f.id), "kind": .string(f.kind.rawValue), "title": .string(f.title),
                                          "summary": .string(f.summary), "status": .string(f.status.rawValue)]
                                     })]
                                })])
        }
        a.register("scan.start") { [unowned self] p in
            let scopes = p["scopes"]?.strings.isEmpty == false ? p["scopes"]!.strings : [try engine.scopeParam(p)]
            let kinds = (p["kinds"]?.strings ?? []).compactMap(ScanKind.init(rawValue:))
            let sources = (p["sources"]?.strings ?? []).compactMap(ScanSource.init(rawValue:))
            start(scopes: scopes, kinds: kinds.isEmpty ? ScanKind.allCases : kinds,
                  sources: sources.isEmpty ? ScanSource.allCases : sources, focus: p["focus"]?.string ?? "")
            return ActionResult("Started scanning " + ActionText.list(scopes) + ".")
        }
        a.register("scan.stop") { [unowned self] p in
            stop(p["id"]?.string ?? "")
            return ActionResult("Stopped the scan.")
        }
        a.register("scan.apply") { [unowned self] p in
            loadIfNeeded()
            guard let id = p["id"]?.string, let run = list.first(where: { $0.id == id }) else { throw ActionError("No such scan.") }
            let picked = p["findings"]?.strings ?? []
            let ids = picked.isEmpty ? run.findings.filter { $0.status == .pending }.map(\.id) : picked
            apply(run: id, ids: ids)
            return ActionResult("Adding \(ActionText.count(ids.count, "finding")) to the knowledge base.")
        }
    }
}
