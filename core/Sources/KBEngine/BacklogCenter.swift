import Foundation
import KBCore
import Observation

/// `engine.backlog`: backlog proposals (entries waiting to be created in the tracker) and whether each already exists:
/// at once from the cached tracker backlog and the knowledge base, then from `kb backlog duplicates` (a keyword search
/// and the parent's children in the tracker), and for the uncertain ones a short question to the brain, remembered per
/// proposal and candidate.
@MainActor
@Observable
public final class BacklogCenter {
    /// `kb backlog duplicates` per scope: tracker items found for the proposals waiting to be created.
    public var reports: [String: DuplicateReport] = [:]
    public var checked: [String: Date] = [:]
    public var checking: Set<String> = []
    public var errors: [String: String] = [:]
    /// The brain's word on a possible duplicate, by proposal and candidates: same, different or unsure.
    public var brainVerdicts: [String: String] = [:]
    public var brainRunning = false
    @ObservationIgnored public var verdictsURL: URL

    @ObservationIgnored unowned let engine: MindmillEngine

    init(engine: MindmillEngine, verdictsURL: URL) {
        self.engine = engine
        self.verdictsURL = verdictsURL
    }

    // MARK: Proposals

    /// A proposed backlog entry, sourced from `source` when given; it waits in Backlog to be created. Returns its id.
    @discardableResult
    public func propose(title: String, details: String, bug: Bool, scope: String, source: EntryID?) async throws -> String {
        if let source {
            let summary = details.split(separator: "\n").first.map(String.init) ?? ""
            var args = ["new", "backlog", "--project", scope, "--title", title, "--source", source.rawValue,
                        "--type", bug ? "bug" : "pbi", "--cross-project"]
            if !summary.isEmpty { args += ["--summary", String(summary.prefix(200))] }
            if !details.isEmpty { args.append("--body-stdin") }
            let out = try await engine.cli.run(args, stdin: details.isEmpty ? nil : details + "\n")
            engine.reload()
            return MindmillEngine.newEntryID(out)
        }
        return try await engine.createEntry(scope: scope, section: "backlog", title: title, summary: nil, tags: [],
                                            fields: ["kind": bug ? "bug" : "pbi"], body: details.isEmpty ? nil : details)
    }

    /// Creates the proposal in the tracker. `parent` nil leaves it to the entry and its text; empty means none.
    @discardableResult
    public func create(_ id: EntryID, sprint: Sprint, parent: String? = nil) async throws -> KBCLI.CreatedWorkItem? {
        defer { engine.reload() }
        let created = try await engine.cli.createBacklog(id, sprint: sprint, parent: parent)
        engine.onTrackerChanged?()
        return created
    }

    public func reject(_ id: EntryID) async throws {
        try await engine.cli.rejectBacklog(id)
        engine.reload()
    }

    /// The tool's tags can be written only to Azure DevOps for now; the others are reached through Claude's connectors.
    public func canAlignTags(_ item: TrackerBacklog.Item) -> Bool { engine.tracker.kind(item.scope) == "azure-devops" }

    /// Writes the item's aligned tags to the tool; returns what the CLI said.
    public func alignTags(_ item: TrackerBacklog.Item) async throws -> String {
        let out = try await engine.cli.run(["tracker", "tag", String(item.id), "--yes"])
        engine.tracker.refreshBacklog()
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Duplicates

    public var scopeInfo: [String: BacklogDuplicates.ScopeInfo] {
        Dictionary(engine.index.projects.map { ($0.id, BacklogDuplicates.ScopeInfo(project: $0.group, wide: $0.wide)) },
                   uniquingKeysWith: { a, _ in a })
    }

    private func pool() -> [DuplicateCandidate] {
        BacklogDuplicates.pool(tracker: (engine.tracker.backlog?.items ?? []).map(DuplicateCandidate.init(item:)),
                               searched: reports.values.flatMap(\.candidates),
                               entries: engine.index.entries.values.filter { $0.section == .backlog }.compactMap(BacklogDuplicates.candidate(entry:)))
    }

    public func findings(for entries: [KBEntry]) -> [EntryID: DuplicateFinding] {
        let proposals = entries.filter { $0.section == .backlog && $0.backlogStatus == .proposed }
        guard !proposals.isEmpty else { return [:] }
        loadVerdicts()
        let pool = pool()
        let info = scopeInfo
        var out: [EntryID: DuplicateFinding] = [:]
        for e in proposals {
            out[e.id] = withBrainVerdict(BacklogDuplicates.check(DuplicateProposal(entry: e), candidates: pool, info: info))
        }
        return out
    }

    /// The match that keeps a proposal from being created until the user drops it or says it isn't a duplicate.
    public func unresolved(_ id: EntryID) -> DuplicateMatch? {
        guard let e = engine.index.entry(id), let f = findings(for: [e])[id], f.verdict != .none else { return nil }
        return f.best
    }

    private static func brainKey(_ f: DuplicateFinding) -> String? {
        f.best.map { "\(f.id)|\($0.kind.rawValue):\($0.key)" }
    }

    private func withBrainVerdict(_ f: DuplicateFinding) -> DuplicateFinding {
        guard f.verdict == .possible, let key = Self.brainKey(f), let said = brainVerdicts[key] else { return f }
        var out = f
        switch said {
        case "same":
            out.verdict = .likely
            out.matches[0].verdict = .likely
            out.matches[0].reasons.append("\(Brain.name) reads it as the same work")
        case "different":
            out.verdict = .none
        default:
            out.matches[0].reasons.append("\(Brain.name) isn't sure either")
        }
        return out
    }

    /// The scope's proposals waiting to be created (only `id` when given).
    public func proposals(scope: String, only: EntryID? = nil) -> [KBEntry] {
        engine.index.entries(project: scope, section: .backlog)
            .filter { !$0.isDraft && $0.backlogStatus == .proposed && (only == nil || $0.id == only) }
    }

    /// Searches the tracker for what the scope's proposals may duplicate: again after ten minutes, when a new
    /// proposal arrives, or when forced.
    public func check(scope: String, force: Bool = false) {
        loadVerdicts()
        guard !checking.contains(scope) else { return }
        let proposals = proposals(scope: scope)
        guard !proposals.isEmpty else { return }
        let seen = Set(reports[scope]?.proposals.map(\.id) ?? [])
        let fresh = checked[scope].map { Date().timeIntervalSince($0) < 600 } ?? false
        if !force, fresh, proposals.allSatisfy({ seen.contains($0.id.rawValue) }) { return }
        checking.insert(scope)
        Task {
            do {
                reports[scope] = try await engine.cli.backlogDuplicates(scope: nil, entries: proposals.map(\.id))
                errors[scope] = nil
            } catch {
                errors[scope] = error.localizedDescription
            }
            checked[scope] = Date()
            checking.remove(scope)
            askBrain(proposals.map(\.id))
        }
    }

    /// Searches now and waits (the `backlog.duplicates` action).
    public func checkNow(scope: String, proposals: [KBEntry]) async throws -> DuplicateReport {
        let report = try await engine.cli.backlogDuplicates(scope: nil, entries: proposals.map(\.id))
        reports[scope] = report
        checked[scope] = Date()
        errors[scope] = nil
        return report
    }

    // MARK: Asking the brain

    private func loadVerdicts() {
        guard brainVerdicts.isEmpty, let data = try? Data(contentsOf: verdictsURL),
              let saved = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        brainVerdicts = saved
    }

    private func saveVerdicts() {
        guard let data = try? JSONEncoder().encode(brainVerdicts) else { return }
        try? FileManager.default.createDirectory(at: verdictsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: verdictsURL, options: .atomic)
    }

    /// One short call for up to six possible duplicates nobody has judged yet: same work, different, or unsure.
    private func askBrain(_ ids: [EntryID]) {
        guard !brainRunning, let exe = engine.claudeExecutable else { return }
        let entries = ids.compactMap { engine.index.entry($0) }
        let pool = pool()
        let info = scopeInfo
        var asked: [(key: String, entry: KBEntry, match: DuplicateMatch, text: String)] = []
        for e in entries {
            let f = BacklogDuplicates.check(DuplicateProposal(entry: e), candidates: pool, info: info)
            guard f.verdict == .possible, let best = f.best, let key = Self.brainKey(f), brainVerdicts[key] == nil else { continue }
            let text = pool.first { $0.kind == best.kind && ($0.number.map(String.init) ?? $0.id) == best.key }?.text ?? ""
            asked.append((key, e, best, text))
            if asked.count == 6 { break }
        }
        guard !asked.isEmpty else { return }
        let prompt = Self.brainPrompt(asked.map { ($0.entry, $0.match, $0.text) })
        brainRunning = true
        let args = ClaudeOneShot.arguments(prompt: prompt, pluginRoot: engine.pluginRootPath, model: engine.model(for: .background),
                                           allowedTools: ["Read"])
        let env = engine.claudeEnvironment()
        let cwd = engine.rootURL
        Task {
            let r = await ProcessRunner().run(executable: exe, arguments: args, environment: env, stdin: nil, currentDirectory: cwd)
            if r.status == 0 {
                for (n, word) in Self.parseBrainVerdicts(r.stdout) where n >= 1 && n <= asked.count {
                    brainVerdicts[asked[n - 1].key] = word
                }
                saveVerdicts()
            }
            brainRunning = false
        }
    }

    static func brainPrompt(_ pairs: [(entry: KBEntry, match: DuplicateMatch, text: String)]) -> String {
        let lines = pairs.enumerated().map { i, a in
            let proposed = excerpt(a.entry.summary + " " + a.entry.body, 500)
            let existing = excerpt(a.text, 400)
            return "\(i + 1). Proposed: \(a.entry.title)\(proposed.isEmpty ? "" : " — \(proposed)")\n"
                + "   Existing: \(a.match.label == a.match.title ? "" : a.match.label + " ")\(a.match.title) (\(a.match.state))"
                + (existing.isEmpty ? "" : " — \(existing)")
        }
        return """
        For each numbered pair, decide whether the proposed backlog item and the existing item describe the same piece \
        of work, so that creating the proposal would duplicate it. Overlapping or related work that still needs its own \
        item is different. Reply with one line per pair, exactly `<number>: same`, `<number>: different` or \
        `<number>: unsure`, and nothing else.

        \(lines.joined(separator: "\n"))
        """
    }

    public static func parseBrainVerdicts(_ text: String) -> [(Int, String)] {
        text.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2, let n = Int(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "#. "))),
                  ["same", "different", "unsure"].contains(parts[1]) else { return nil }
            return (n, parts[1])
        }
    }

    private static func excerpt(_ s: String, _ limit: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

extension MindmillEngine {
    func registerBacklogActions() {
        let a = actions

        a.register("backlog.propose") { [unowned self] p in
            let scope = try scopeParam(p)
            let source = p["source"]?.string.flatMap(EntryID.init)
            let id = try await backlog.propose(title: p["title"]?.string ?? "", details: p["details"]?.string ?? "",
                                               bug: p["bug"]?.bool ?? false, scope: scope, source: source)
            return ActionResult("Proposed it in the backlog. Create it in the tracker when you're ready.", data: ["id": .string(id)])
        }

        a.register("backlog.create") { [unowned self] p in
            let id = try entryParam(p)
            guard index.entry(id)?.backlogStatus == .proposed else { throw ActionError("That isn't a proposal waiting to be created.") }
            if let related = p["related"] {
                let values = WorkItemLinks.relatedValues(related.strings.isEmpty ? (related.string.map { [$0] } ?? []) : related.strings)
                var doc = try KBStore.load(id, root: rootURL)
                doc.frontmatter.set("related", values.isEmpty ? nil : .list(values))
                if doc.isDirty { _ = try KBStore.save(&doc, root: rootURL) }
            }
            if let dup = backlog.unresolved(id) {
                guard p["not_duplicate"]?.bool == true else {
                    throw ActionError("It may duplicate \(dup.label) “\(dup.title)” (\(dup.state)). Check it: drop the proposal, or create it with not_duplicate.")
                }
                try await cli.markNotDuplicate(id, of: backlog.findings(for: index.entry(id).map { [$0] } ?? [])[id]?.matches.map(\.key) ?? [dup.key])
            }
            let parent = p["parent"]?.string ?? ActionText.intParam(p["parent"]).map(String.init)
            let created = try await backlog.create(id, sprint: p["sprint"]?.string.flatMap(Sprint.init(rawValue:)) ?? .none,
                                                   parent: parent.map { $0.lowercased() == "none" ? "" : $0.filter(\.isNumber) })
            return ActionResult(created.map { "Created work item \($0.id)." } ?? "Created it.",
                                data: created.map { ["id": .string($0.id), "url": .string($0.url)] } ?? [:])
        }

        a.register("backlog.duplicates") { [unowned self] p in
            let scope = try scopeParam(p)
            let only = try p["id"]?.string.map { _ in try entryParam(p) }
            let proposals = backlog.proposals(scope: scope, only: only)
            guard !proposals.isEmpty else { return ActionResult("No proposals are waiting to be created.", data: ["proposals": []]) }
            let report = try await backlog.checkNow(scope: scope, proposals: proposals)
            let findings = backlog.findings(for: proposals)
            let ordered = proposals.compactMap { findings[$0.id] }
            let flagged = ordered.filter { $0.verdict != .none }
            let speech = flagged.isEmpty ? "None of the \(ActionText.count(ordered.count, "proposal")) seems to exist already."
                : ActionText.list(flagged.prefix(3).map { "\($0.title) is a \($0.verdict == .likely ? "likely" : "possible") duplicate of \($0.best!.label)" })
                    + (flagged.count > 3 ? ", and \(flagged.count - 3) more" : "") + "."
            return ActionResult(speech, data: ["proposals": .from(ordered), "notes": .from(report.notes)])
        }

        a.register("backlog.link") { [unowned self] p in
            let ids = p["ids"]?.strings.isEmpty == false ? p["ids"]!.strings : (p["ids"]?.string.map { [$0] } ?? [])
            guard !ids.isEmpty else { throw ActionError("Which items?") }
            let related = p["related"]?.strings.isEmpty == false ? p["related"]!.strings : (p["related"]?.string.map { [$0] } ?? [])
            let scope = p["scope"]?.string == nil ? nil : try scopeParam(p)
            let out = try await cli.linkBacklog(ids, parent: p["parent"]?.string.map { $0.lowercased() == "none" ? "" : $0 },
                                                related: related, scope: scope)
            reload()
            return ActionResult(out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: ". ") + ".")
        }

        a.register("backlog.reject") { [unowned self] p in
            try await backlog.reject(try entryParam(p))
            return ActionResult("Rejected it.")
        }

        a.register("workitem.tags.align") { [unowned self] p in
            let scope = try scopeParam(p)
            guard let id = ActionText.intParam(p["id"]),
                  let item = tracker.items(scope: scope).first(where: { $0.id == id }) ?? tracker.backlog?.item(id)
            else { throw ActionError("I can't find that work item.") }
            guard backlog.canAlignTags(item) else { throw ActionError("This tracker doesn't take Mindmill's tags.") }
            let said = try await backlog.alignTags(item)
            return ActionResult(said.isEmpty ? "Wrote its tags to the tracker." : said)
        }
    }
}
