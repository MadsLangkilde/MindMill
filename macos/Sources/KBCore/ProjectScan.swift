import Foundation

/// What a project scan can look for. Each kind lands in the KB section of the same name, except Project Docs,
/// which adds repository documents to Architecture → Project Docs.
public enum ScanKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case overview, decisions, facts, architecture, followups, backlog, docs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .decisions: return "Decisions"
        case .facts: return "Facts"
        case .architecture: return "Architecture"
        case .followups: return "Open Questions"
        case .backlog: return "Backlog Ideas"
        case .docs: return "Project Docs"
        }
    }

    public var icon: String {
        switch self {
        case .overview: return "doc.text"
        case .decisions: return "checkmark.seal"
        case .facts: return "lightbulb"
        case .architecture: return "building.columns"
        case .followups: return "checklist"
        case .backlog: return "list.bullet.rectangle"
        case .docs: return "doc.richtext"
        }
    }

    public var help: String {
        switch self {
        case .overview: return "What the project is, in a few lines"
        case .decisions: return "Choices made and why: from docs, ADRs, commit messages, code comments"
        case .facts: return "Things that are true: versions, limits, conventions, environments, who owns what"
        case .architecture: return "The parts, what talks to what, and the flows between them"
        case .followups: return "TODOs, FIXMEs and unanswered questions worth tracking"
        case .backlog: return "Bugs and improvements the code or docs point at"
        case .docs: return "Documentation files in the repository worth keeping at hand"
        }
    }

    public var section: KBSection? {
        switch self {
        case .overview: return .overview
        case .decisions: return .decisions
        case .facts: return .facts
        case .architecture: return .architecture
        case .followups: return .followups
        case .backlog: return .backlog
        case .docs: return nil
        }
    }

    /// What it writes, for the scan prompt.
    var instruction: String {
        switch self {
        case .overview:
            return "overview: one finding at most: what the project is and does, for whom, the main parts, in 3–8 lines. "
                + "Pass --updates <scope>/overview when the scope has an overview."
        case .decisions:
            return "decisions: a choice someone made, with the reason. Body: \"## Decision\\n<what>\\n\\n## Why\\n<why, and what "
                + "was rejected if known>\". --date is the day it was made when a commit or doc shows it."
        case .facts:
            return "facts: one thing that is true and useful to know (a version, a limit, a convention, an environment, a "
                + "build or release step, an integration). Body: the fact and how you know it."
        case .architecture:
            return "architecture: one note per part or flow: what it is, what it talks to, where it lives in the repo. "
                + "A ```mermaid diagram is welcome when it makes it clearer."
        case .followups:
            return "followups: an open question or an action worth tracking (TODO, FIXME, HACK, a doc's open point). "
                + "--followup-kind question or action. Body: the context and where it is."
        case .backlog:
            return "backlog: a bug or an improvement the code, comments or docs point at, worth a PBI. Body: "
                + "\"## Description\\n<what and why>\\n\\n## Acceptance criteria\\n- <criterion>\"."
        case .docs:
            return "docs: a documentation file worth keeping in Project Docs (architecture notes, setup guides, ADRs; not "
                + "licences, changelogs or generated files). Run `kb docs scan --scope <scope>` to list them; pass "
                + "--path <repo-relative path> and a --title."
        }
    }
}

/// Where a scan looks.
public enum ScanSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case docs, code, history, work, knowledge

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .docs: return "Documentation"
        case .code: return "Code and comments"
        case .history: return "Git history"
        case .work: return "Work items and pull requests"
        case .knowledge: return "Existing knowledge"
        }
    }

    public var help: String {
        switch self {
        case .docs: return "READMEs, docs folders, ADRs, wikis kept in the repo"
        case .code: return "Build files, configuration, modules and their comments"
        case .history: return "Commit messages and how the code changed over time"
        case .work: return "The tracker's PBIs and bugs, and pull requests"
        case .knowledge: return "The repo's knowledgebase/ folder and the knowledge base, to correct what's out of date"
        }
    }

    var instruction: String {
        switch self {
        case .docs: return "documentation: README files, docs/ folders, ADRs, wikis and other Markdown kept in the repo"
        case .code: return "code: build files, configuration, module structure, public interfaces, and comments (TODO, FIXME, "
            + "explanations of why)"
        case .history: return "git history: `git log` (messages, merges, who changed what), `git log -S` or `git blame` for why "
            + "something is as it is"
        case .work: return "work items and pull requests: `kb tracker backlog --scope <scope> --json`, `kb pr list`"
        case .knowledge: return "existing knowledge: what the KB says (`kb list --project <scope>`, `kb show <id>`); propose "
            + "--updates <id> where it is out of date"
        }
    }
}

public struct ScanFinding: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case pending, applied, dismissed }

    public var id: String
    public var kind: ScanKind
    public var scope: String
    public var title: String
    public var summary: String
    public var body: String
    public var source: String
    public var scopes: [String]
    public var date: String
    /// The entry this one replaces or corrects.
    public var updates: String
    /// Project Docs: the repository-relative path.
    public var path: String
    public var confidence: String
    public var status: Status = .pending
    /// The entry it became once applied.
    public var entry: String = ""

    public init(id: String, kind: ScanKind, scope: String, title: String, summary: String = "", body: String = "",
                source: String = "", scopes: [String] = [], date: String = "", updates: String = "", path: String = "",
                confidence: String = "medium") {
        self.id = id
        self.kind = kind
        self.scope = scope
        self.title = title
        self.summary = summary
        self.body = body
        self.source = source
        self.scopes = scopes
        self.date = date
        self.updates = updates
        self.path = path
        self.confidence = confidence
    }
}

/// One scan: what it looks for, what it found and what the user did with each finding, folded from its
/// JSON-lines file (written by `kb scan`).
public struct ScanRun: Identifiable, Equatable, Sendable {
    public var id: String
    public var scope: String
    public var kinds: [ScanKind]
    public var sources: [ScanSource]
    public var focus: String
    public var started: Date?
    public var progress: [String] = []
    public var finished: Date?
    public var note: String = ""
    public var failed = false
    public var findings: [ScanFinding] = []

    public init(id: String, scope: String, kinds: [ScanKind] = ScanKind.allCases, sources: [ScanSource] = ScanSource.allCases,
                focus: String = "", started: Date? = nil) {
        self.id = id
        self.scope = scope
        self.kinds = kinds
        self.sources = sources
        self.focus = focus
        self.started = started
    }

    public var isFinished: Bool { finished != nil }
    public var pending: [ScanFinding] { findings.filter { $0.status == .pending } }
    public var appliedCount: Int { findings.filter { $0.status == .applied }.count }

    /// Findings of each kind in the order kinds are listed, kinds with none left out.
    public func grouped(_ list: [ScanFinding]) -> [(kind: ScanKind, findings: [ScanFinding])] {
        ScanKind.allCases.compactMap { k in
            let f = list.filter { $0.kind == k }
            return f.isEmpty ? nil : (k, f)
        }
    }

    public static func parse(id: String, text: String) -> ScanRun? {
        var run: ScanRun?
        var findings: [ScanFinding] = []
        var index: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            let at = (obj["at"] as? String).flatMap(Self.date)
            switch type {
            case "start":
                run = ScanRun(id: id, scope: obj["scope"] as? String ?? "",
                              kinds: (obj["kinds"] as? [String] ?? []).compactMap(ScanKind.init(rawValue:)),
                              sources: (obj["sources"] as? [String] ?? []).compactMap(ScanSource.init(rawValue:)),
                              focus: obj["focus"] as? String ?? "", started: at)
            case "finding":
                guard let fid = obj["id"] as? String, let kind = (obj["kind"] as? String).flatMap(ScanKind.init(rawValue:)) else { continue }
                let f = ScanFinding(id: fid, kind: kind, scope: obj["scope"] as? String ?? "", title: obj["title"] as? String ?? fid,
                                    summary: obj["summary"] as? String ?? "", body: obj["body"] as? String ?? "",
                                    source: obj["source"] as? String ?? "", scopes: obj["scopes"] as? [String] ?? [],
                                    date: obj["date"] as? String ?? "", updates: obj["updates"] as? String ?? "",
                                    path: obj["path"] as? String ?? "", confidence: obj["confidence"] as? String ?? "medium")
                index[fid] = findings.count
                findings.append(f)
            case "progress":
                if let t = obj["text"] as? String { run?.progress.append(t) }
            case "done":
                run?.finished = at ?? Date()
                run?.note = obj["note"] as? String ?? ""
                run?.failed = obj["failed"] as? Bool ?? false
            case "applied", "dismissed":
                guard let fid = obj["finding"] as? String, let i = index[fid] else { continue }
                findings[i].status = type == "applied" ? .applied : .dismissed
                findings[i].entry = obj["entry"] as? String ?? ""
            default:
                break
            }
        }
        run?.findings = findings
        return run
    }

    /// Every scan in `dir`, newest first.
    public static func loadAll(dir: URL) -> [ScanRun] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).flatMap { parse(id: url.deletingPathExtension().lastPathComponent, text: $0) }
            }
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: String(s.prefix(19)))
    }
}

public enum ScanDir {
    public static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let v = environment["KB_SCANS_DIR"], !v.isEmpty { return URL(fileURLWithPath: KBConfig.expandTilde(v)) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KB/scans")
    }
}

/// A scope's repository on this Mac and the team knowledge already in it.
public struct ScopeRepo: Equatable, Sendable {
    public var checkout: URL?
    /// `<repo>/knowledgebase/` exists.
    public var hasTeamFolder: Bool
    /// Markdown entries in it.
    public var teamEntries: Int

    public init(checkout: URL?, hasTeamFolder: Bool, teamEntries: Int) {
        self.checkout = checkout
        self.hasTeamFolder = hasTeamFolder
        self.teamEntries = teamEntries
    }

    public static func of(paths: [String]) -> ScopeRepo {
        guard let dir = KBLayout.checkout(paths: paths) else { return ScopeRepo(checkout: nil, hasTeamFolder: false, teamEntries: 0) }
        let team = dir.appendingPathComponent(KBLayout.teamFolder, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: team.path, isDirectory: &isDir), isDir.boolValue else {
            return ScopeRepo(checkout: dir, hasTeamFolder: false, teamEntries: 0)
        }
        let files = FileManager.default.enumerator(at: team, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }.count ?? 0
        return ScopeRepo(checkout: dir, hasTeamFolder: true, teamEntries: files)
    }

    /// Whether `url` is a git checkout (has `.git`, a folder or a worktree's file).
    public static func isRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }
}

/// The instructions for a scan session.
public enum ScanPrompt {
    public static func system(run: ScanRun, scopeTitle: String, project: String, wideScope: String?, otherScopes: [String],
                              checkout: String, hasOverview: Bool) -> String {
        let kinds = run.kinds.isEmpty ? ScanKind.allCases : run.kinds
        let sources = run.sources.isEmpty ? ScanSource.allCases : run.sources
        var lines = [
            "You scan a repository for the Mindmill app, read-only, to find knowledge worth keeping. The user reviews every "
                + "finding and ticks the ones that go into the knowledge base; nothing you record goes in on its own.",
            "",
            "Repository: \(checkout) (the working directory). Scope: \(scopeTitle) (`\(run.scope)`) in the project \(project).",
            "Scan run: \(run.id)",
        ]
        if let wideScope { lines.append("Knowledge that spans the whole product, not only this repository, goes to the project-wide scope: --scope \(wideScope).") }
        if !otherScopes.isEmpty { lines.append("Other scopes of the project, to tag with --scopes when a finding concerns them too: \(otherScopes.joined(separator: ", ")).") }
        if hasOverview { lines.append("The scope has an overview: propose an overview only to correct it, with --updates \(run.scope)/overview.") }
        if !run.focus.isEmpty { lines += ["", "The user wants you to focus on: \(run.focus)"] }
        lines += ["", "Look for:"] + kinds.map { "- " + $0.instruction }
        lines += ["", "Look in:"] + sources.map { "- " + $0.instruction }
        if !sources.contains(.knowledge) {
            lines.append("- also run `kb list --project \(run.scope)` first, only to avoid proposing what the KB already has")
        }
        lines += [
            "",
            "How:",
            "1. Start with `kb list --project \(run.scope)` to see what the KB knows. A `knowledgebase/` folder in the repository "
                + "is the team's knowledge and already in the KB: never propose it again; propose --updates <id> when the code "
                + "shows it is out of date.",
            "2. Get the lay of the land (README, top-level folders, build files), then go area by area. Each time you move to "
                + "a new area, say so: `kb scan progress --run \(run.id) \"<area>\"`.",
            "3. Record each finding as you go, one thing per finding:",
            "   kb scan found --run \(run.id) --kind <kind> --title \"<one line>\" --summary \"<one line that stands alone>\" "
                + "--source \"<repo-relative path:line, commit <sha>, or work item #id>\" [--scope <scope>] [--scopes a,b] "
                + "[--date YYYY-MM-DD] [--updates <entry id>] [--confidence high|medium|low] --body-stdin <<'EOF'",
            "   <body in Markdown>",
            "   EOF",
            "   It refuses duplicates and what the KB already has, and says so; move on when it does.",
            "4. When you have covered what was asked: `kb scan done --run \(run.id) --note \"<one line: what you covered>\"`, "
                + "then reply with that line. If something stops you: `kb scan done --run \(run.id) --failed --note \"<why>\"`.",
            "",
            "Rules:",
            "- Only what is true and would help a teammate, with where you found it. Mark guesses --confidence low.",
            "- Prefer fewer, solid findings over many thin ones; don't record what any developer would assume.",
            "- Never record secrets, keys, tokens, passwords, personal data or absolute local paths.",
            "- Read only: don't change, build or run anything in the repository. Don't ask the user anything; decide and note it.",
            "- Write plainly, in English, in full sentences.",
        ]
        return lines.joined(separator: "\n")
    }

    /// The first message: the session starts working on it.
    public static let start = "Scan the repository now, as described."
}
