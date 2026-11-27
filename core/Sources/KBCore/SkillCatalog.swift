import Foundation

/// Where the user's own skills are kept: for them in every project, or in one project's repository.
public enum SkillLocation: String, CaseIterable, Sendable {
    case user, project
}

/// A skill or command the session's AI can run with `/<name>`.
public struct SkillInfo: Equatable, Sendable, Identifiable {
    public enum Source: String, Sendable {
        /// From an installed plugin (or the AI's account), read only.
        case plugin
        /// The user's own, for every project.
        case user
        /// The user's own, in a project's repository.
        case project
        /// A command with no file Mindmill knows of (built in, or listed by the session only).
        case command
    }

    public var name: String
    public var description: String
    public var source: Source
    public var plugin: String?
    public var scope: String?
    /// The SKILL.md (or command file), when there is one.
    public var path: String?

    public var id: String { command }
    public var command: String { "/" + (plugin.map { "\($0):" } ?? "") + name }
    public var editable: Bool { source == .user || source == .project }
    public var location: SkillLocation? {
        switch source {
        case .user: return .user
        case .project: return .project
        default: return nil
        }
    }

    public init(name: String, description: String, source: Source, plugin: String? = nil, scope: String? = nil, path: String? = nil) {
        self.name = name
        self.description = description
        self.source = source
        self.plugin = plugin
        self.scope = scope
        self.path = path
    }
}

/// The skills and commands of the AI that runs sessions: found in its folders, the user's and each repository's,
/// and in its installed plugins. Pure over the file system it is given, so it is tested without a real home.
public enum SkillCatalog {
    /// The AI's folder names: `~/.claude` and a repository's `.claude` for Claude Code, `.agents` for Codex and
    /// Gemini CLI.
    public struct Home: Equatable, Sendable {
        public var user: URL
        public var projectFolder: String

        public init(user: URL, projectFolder: String) {
            self.user = user
            self.projectFolder = projectFolder
        }

        public static func of(brain: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Home {
            brain == AIProvider.codex.id || brain == AIProvider.gemini.id
                ? Home(user: home.appendingPathComponent(".agents"), projectFolder: ".agents")
                : Home(user: home.appendingPathComponent(".claude"), projectFolder: ".claude")
        }

        public var skills: URL { user.appendingPathComponent("skills", isDirectory: true) }
        public func skills(repo: URL) -> URL { repo.appendingPathComponent(projectFolder).appendingPathComponent("skills", isDirectory: true) }
    }

    /// An installed plugin: its name (the part of `name@marketplace` before the `@`) and folder.
    public struct Plugin: Equatable, Sendable {
        public var name: String
        public var folder: URL

        public init(name: String, folder: URL) {
            self.name = name
            self.folder = folder
        }
    }

    /// `name` and `description` from a SKILL.md's or command's frontmatter.
    public static func frontmatter(_ text: String) -> (name: String?, description: String?) {
        guard text.hasPrefix("---") else { return (nil, nil) }
        let lines = text.components(separatedBy: "\n").dropFirst()
        var name: String?
        var description: String?
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            func value(_ key: String) -> String? {
                guard line.hasPrefix(key + ":") else { return nil }
                var v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                if v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f { v = String(v.dropFirst().dropLast()) }
                return v.isEmpty ? nil : v
            }
            name = name ?? value("name")
            description = description ?? value("description")
        }
        return (name, description)
    }

    /// The skills in `folder/<name>/SKILL.md`.
    public static func skills(in folder: URL, source: SkillInfo.Source, plugin: String? = nil, scope: String? = nil,
                              fm: FileManager = .default) -> [SkillInfo] {
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().compactMap { dir in
            guard !dir.hasPrefix(".") else { return nil }
            let file = folder.appendingPathComponent(dir).appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let meta = frontmatter(text)
            return SkillInfo(name: meta.name ?? dir, description: meta.description ?? "", source: source, plugin: plugin,
                             scope: scope, path: file.path)
        }
    }

    /// The commands in `folder/<name>.md`.
    public static func commands(in folder: URL, source: SkillInfo.Source, plugin: String? = nil, scope: String? = nil,
                                fm: FileManager = .default) -> [SkillInfo] {
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().compactMap { file in
            guard file.hasSuffix(".md"), !file.hasPrefix(".") else { return nil }
            let url = folder.appendingPathComponent(file)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return SkillInfo(name: String(file.dropLast(3)), description: frontmatter(text).description ?? "", source: source,
                             plugin: plugin, scope: scope, path: url.path)
        }
    }

    /// Everything the AI can run: the user's skills and commands, each repository's, the skills synced from the AI's
    /// account, and the plugins'; then `listed` (what a running session reports) that none of those explain.
    public static func scan(home: Home, repos: [(scope: String, folder: URL)], plugins: [Plugin], listed: [String] = [],
                            fm: FileManager = .default) -> [SkillInfo] {
        var out = skills(in: home.skills, source: .user, fm: fm)
            + commands(in: home.user.appendingPathComponent("commands"), source: .user, fm: fm)
        let synced = home.skills.appendingPathComponent("synced")
        for group in ((try? fm.contentsOfDirectory(atPath: synced.path)) ?? []).sorted() where !group.hasPrefix(".") {
            out += skills(in: synced.appendingPathComponent(group), source: .plugin, plugin: "anthropic-skills", fm: fm)
        }
        for r in repos {
            out += skills(in: home.skills(repo: r.folder), source: .project, scope: r.scope, fm: fm)
            out += commands(in: r.folder.appendingPathComponent(home.projectFolder).appendingPathComponent("commands"),
                            source: .project, scope: r.scope, fm: fm)
        }
        for p in plugins {
            out += skills(in: p.folder.appendingPathComponent("skills"), source: .plugin, plugin: p.name, fm: fm)
            out += commands(in: p.folder.appendingPathComponent("commands"), source: .plugin, plugin: p.name, fm: fm)
        }
        var seen = Set<String>()
        out = out.filter { seen.insert($0.command).inserted }
        for raw in listed {
            let name = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
            guard !seen.contains("/" + name) else { continue }
            seen.insert("/" + name)
            let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
            out.append(parts.count == 2 ? SkillInfo(name: parts[1], description: "", source: .command, plugin: parts[0])
                       : SkillInfo(name: name, description: "", source: .command))
        }
        return out
    }

    /// The matches for what follows the slash: names that start with it first (also after `plugin:`), then names and
    /// descriptions that contain it; the user's own before plugins' at equal rank.
    public static func matches(_ skills: [SkillInfo], query: String) -> [SkillInfo] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        func rank(_ s: SkillInfo) -> Int? {
            let full = String(s.command.dropFirst()).lowercased()
            let name = s.name.lowercased()
            if q.isEmpty { return 0 }
            if name == q || full == q { return 0 }
            if name.hasPrefix(q) || full.hasPrefix(q) { return 1 }
            if full.contains(q) { return 2 }
            if s.description.lowercased().contains(q) { return 3 }
            return nil
        }
        func order(_ s: SkillInfo) -> Int {
            switch s.source {
            case .project: return 0
            case .user: return 1
            case .plugin: return 2
            case .command: return 3
            }
        }
        return skills.compactMap { s in rank(s).map { (s, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if order(a.0) != order(b.0) { return order(a.0) < order(b.0) }
                return a.0.command < b.0.command
            }
            .map(\.0)
    }

    /// A folder name for a new skill: lowercase words joined by dashes.
    public static func safeName(_ raw: String) -> String {
        let lowered = raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(lowered).split(separator: "-").joined(separator: "-").prefix(64).description
    }

    /// The SKILL.md of `name` at `location`; `repo` is the scope's repository for a project skill.
    public static func file(name: String, location: SkillLocation, home: Home, repo: URL?) -> URL? {
        let n = safeName(name)
        guard !n.isEmpty else { return nil }
        switch location {
        case .user: return home.skills.appendingPathComponent(n).appendingPathComponent("SKILL.md")
        case .project: return repo.map { home.skills(repo: $0).appendingPathComponent(n).appendingPathComponent("SKILL.md") }
        }
    }

    /// The prompt that has the AI write (or change) a skill from the user's words.
    public static func draftPrompt(description: String, name: String?, current: String?) -> String {
        if let current, !current.isEmpty {
            return """
            Here is a skill for an AI coding assistant (a SKILL.md: YAML frontmatter with `name` and `description`, then \
            Markdown instructions). Change it as the user asks and reply with the complete new SKILL.md only, no fences \
            and nothing around it. Keep what they didn't ask to change.

            The user's change: \(description)

            The skill:
            \(current)
            """
        }
        return """
        Write a skill for an AI coding assistant from the user's description. Reply with the complete SKILL.md only, no \
        fences and nothing around it: YAML frontmatter between `---` lines with `name: \(name.map(safeName).flatMap { $0.isEmpty ? nil : $0 } ?? "<short-kebab-case-name>")` and a \
        one-line `description:` that says what it does and when to use it (the assistant picks skills by it), then \
        clear Markdown instructions: what to do step by step, what to check, what to avoid. Keep it short and concrete; \
        no placeholders.

        The user's description: \(description)
        """
    }

    /// The skill text from a draft reply, without fences the AI may have added anyway.
    public static func cleanDraft(_ reply: String) -> String {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        if let start = t.range(of: "---"), start.lowerBound != t.startIndex, t[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).count < 200 {
            t = String(t[start.lowerBound...])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

/// Plugins and tools (MCP servers) of the session's AI, as its CLI reports them.
public enum AIExtensions {
    public struct InstalledPlugin: Equatable, Sendable, Identifiable {
        public var id: String
        public var version: String
        public var scope: String
        public var enabled: Bool
        public var folder: String?
        public var name: String { String(id.split(separator: "@").first ?? Substring(id)) }
        public var marketplace: String { id.split(separator: "@").dropFirst().first.map(String.init) ?? "" }
    }

    public struct AvailablePlugin: Equatable, Sendable, Identifiable {
        public var id: String
        public var description: String
        public var installs: Int?
        public var name: String { String(id.split(separator: "@").first ?? Substring(id)) }
        public var marketplace: String { id.split(separator: "@").dropFirst().first.map(String.init) ?? "" }
    }

    /// `claude plugin list --json`, an array of installed plugins; with `--available`, an object with `installed` and
    /// `available` (the shape differs between versions, so both are read).
    public static func parsePlugins(_ json: String) -> (installed: [InstalledPlugin], available: [AvailablePlugin]) {
        guard let data = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return ([], []) }
        let installedRaw: [[String: Any]]
        var availableRaw: [[String: Any]] = []
        if let list = root as? [[String: Any]] {
            installedRaw = list
        } else if let obj = root as? [String: Any] {
            installedRaw = obj["installed"] as? [[String: Any]] ?? obj["plugins"] as? [[String: Any]] ?? []
            availableRaw = obj["available"] as? [[String: Any]] ?? []
        } else {
            return ([], [])
        }
        let installed = installedRaw.compactMap { d -> InstalledPlugin? in
            guard let id = d["id"] as? String else { return nil }
            let enabled = (d["enabled"] as? Bool ?? true) && (d["projectEnabled"] as? Bool ?? true)
            return InstalledPlugin(id: id, version: d["version"] as? String ?? "", scope: d["scope"] as? String ?? "user",
                                   enabled: enabled, folder: d["installPath"] as? String)
        }
        let known = Set(installed.map(\.id))
        let available = availableRaw.compactMap { d -> AvailablePlugin? in
            let name = d["name"] as? String
            let market = d["marketplace"] as? String ?? d["marketplaceName"] as? String
            guard let id = d["id"] as? String ?? d["pluginId"] as? String ?? name.map({ n in market.map { "\(n)@\($0)" } ?? n }),
                  !known.contains(id) else { return nil }
            let installs = d["installCount"] as? Int ?? d["installs"] as? Int ?? d["unique_installs"] as? Int
            return AvailablePlugin(id: id, description: d["description"] as? String ?? "", installs: installs)
        }
        return (installed, available)
    }

    /// Plugins on offer that match `query` in their name or description, the most installed first.
    public static func search(_ available: [AvailablePlugin], query: String, limit: Int = 50) -> [AvailablePlugin] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let hits = q.isEmpty ? available : available.filter { $0.id.lowercased().contains(q) || $0.description.lowercased().contains(q) }
        return Array(hits.sorted { ($0.installs ?? 0, $1.id) > ($1.installs ?? 0, $0.id) }.prefix(limit))
    }
}
