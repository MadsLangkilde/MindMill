import Foundation

public enum SourceKind: String, CaseIterable, Sendable, Identifiable {
    case folder, url
    case adoWiki = "ado-wiki"
    case adoWorkItems = "ado-work-items"
    case adoRepos = "ado-repos"
    case teams, outlook, mcp, command

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .folder: return "Folder"
        case .url: return "Web page"
        case .adoWiki: return "Azure DevOps wiki"
        case .adoWorkItems: return "Azure DevOps work items"
        case .adoRepos: return "Azure DevOps repos"
        case .teams: return "Teams"
        case .outlook: return "Outlook"
        case .mcp: return "MCP server"
        case .command: return "Command"
        }
    }

    public struct Field: Sendable, Equatable {
        public let key: String
        public let label: String
        public let required: Bool
        public let isList: Bool
        public let placeholder: String
    }

    /// The `config` fields for this kind, from the format's Knowledge sources table.
    public var fields: [Field] {
        func f(_ k: String, _ l: String, req: Bool = false, list: Bool = false, _ p: String = "") -> Field {
            Field(key: k, label: l, required: req, isList: list, placeholder: p)
        }
        switch self {
        case .folder: return [f("path", "Path", req: true, "~/docs"), f("glob", "Glob", "**/*.md")]
        case .url: return [f("url", "URL", req: true, "https://…"), f("scope", "Scope", "page or site")]
        case .adoWiki: return [f("organization", "Organization", req: true), f("project", "Project", req: true), f("wiki", "Wiki", req: true, "Project.wiki")]
        case .adoWorkItems: return [f("organization", "Organization", req: true), f("project", "Project", req: true), f("area_path", "Area path")]
        case .adoRepos: return [f("organization", "Organization", req: true), f("project", "Project", req: true), f("repos", "Repos", list: true, "repo-a, repo-b")]
        case .teams: return [f("chats", "Chats", list: true), f("channels", "Channels", list: true), f("since_days", "Since (days)", "30")]
        case .outlook: return [f("folders", "Folders", list: true), f("since_days", "Since (days)", "30")]
        case .mcp: return [f("server", "Server", req: true, "server name in Claude Code"), f("tools", "Tools", list: true)]
        case .command: return [f("run", "Command", req: true, "mytool search {query}"), f("cwd", "Working dir")]
        }
    }

    /// Kinds the CLI can test itself; the others are tested through Claude.
    public var testedByCLI: Bool {
        switch self {
        case .teams, .outlook, .mcp: return false
        default: return true
        }
    }
}

public enum SourceConfigValue: Hashable, Sendable {
    case string(String)
    case list([String])
    case other(String)

    public var display: String {
        switch self {
        case .string(let s), .other(let s): return s
        case .list(let l): return l.joined(separator: ", ")
        }
    }
}

public enum SourceScope: String, Sendable {
    case project, global, builtin
}

public struct KnowledgeSource: Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var useFor: String
    public var enabled: Bool
    public var config: [String: SourceConfigValue]
    /// Keys of the source object the app does not know, kept as JSON.
    var extra: [String: String] = [:]

    public init(id: String, kind: String, title: String, useFor: String, enabled: Bool = true, config: [String: SourceConfigValue] = [:]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.useFor = useFor
        self.enabled = enabled
        self.config = config
    }

    public var sourceKind: SourceKind? { SourceKind(rawValue: kind) }

    public func string(_ key: String) -> String? {
        guard let v = config[key] else { return nil }
        let s = v.display.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    public func list(_ key: String) -> [String] {
        switch config[key] {
        case .list(let l): return l
        case .string(let s): return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: return []
        }
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.kind = json["kind"] as? String ?? "command"
        self.title = json["title"] as? String ?? id
        self.useFor = json["use_for"] as? String ?? ""
        self.enabled = json["enabled"] as? Bool ?? true
        var cfg: [String: SourceConfigValue] = [:]
        for (k, v) in (json["config"] as? [String: Any]) ?? [:] {
            if let s = v as? String { cfg[k] = .string(s) }
            else if let l = v as? [Any] { cfg[k] = .list(l.map { "\($0)" }) }
            else if let n = v as? NSNumber { cfg[k] = .other(n.stringValue) }
        }
        self.config = cfg
        for (k, v) in json where !["id", "kind", "title", "use_for", "enabled", "config"].contains(k) {
            if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]), let s = String(data: d, encoding: .utf8) {
                extra[k] = s
            }
        }
    }

    var json: [String: Any] {
        var o: [String: Any] = ["id": id, "kind": kind, "title": title, "use_for": useFor, "enabled": enabled]
        var cfg: [String: Any] = [:]
        for (k, v) in config {
            switch v {
            case .string(let s): if !s.isEmpty { cfg[k] = s }
            case .list(let l): if !l.isEmpty { cfg[k] = l }
            case .other(let s): cfg[k] = Int(s).map { $0 as Any } ?? Double(s).map { $0 as Any } ?? s
            }
        }
        o["config"] = cfg
        for (k, s) in extra {
            if let d = s.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) { o[k] = v }
        }
        return o
    }

    /// A free id derived from `title`, not in `taken`.
    public static func makeID(title: String, taken: Set<String>) -> String {
        let base = Slug.make(title, maxLength: 40)
        var id = base
        var n = 2
        while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }
}

/// Sources that are always there: listed for the chips, never written to a file.
public enum BuiltinSources {
    public static let kb = "kb"
    public static let code = "code"
    public static let related = "related"

    public static let all: [(id: String, title: String)] = [
        (kb, "Knowledge base"), (code, "Code & docs"), (related, "Related projects"),
    ]
}

/// `<root>/sources.json`: `{"sources": [...]}`, used for every project.
public enum GlobalSources {
    public static func url(root: URL) -> URL { KBLayout.home(root: root).appendingPathComponent("sources.json") }

    public static func load(root: URL) -> [KnowledgeSource] {
        guard let data = try? Data(contentsOf: url(root: root)) else { return [] }
        return parse(data)
    }

    public static func parse(_ data: Data) -> [KnowledgeSource] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return SourceList.parse(json["sources"])
    }

    /// Writes the list, keeping any other top-level keys already in the file.
    public static func save(_ sources: [KnowledgeSource], root: URL) throws {
        let u = url(root: root)
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: u), let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json = existing
        }
        json["sources"] = sources.map(\.json)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: u, options: .atomic)
    }
}

enum SourceList {
    static func parse(_ value: Any?) -> [KnowledgeSource] {
        ((value as? [Any]) ?? []).compactMap { ($0 as? [String: Any]).flatMap(KnowledgeSource.init(json:)) }
    }
}

/// The tools an Ask session may use: the bridge list, web and git, plus what each enabled source needs.
public enum AskTools {
    public static func allowedTools(sources: [KnowledgeSource]) -> [String] {
        var tools = ClaudeLaunch.bridgeTools + ["WebFetch", "WebSearch", "Bash(curl:*)", "Bash(git:*)"]
        for s in sources where s.enabled {
            switch s.sourceKind {
            case .mcp:
                guard let server = s.string("server") else { continue }
                let listed = s.list("tools")
                if listed.isEmpty {
                    tools.append("mcp__\(server)__*")
                } else {
                    tools += listed.map { $0.hasPrefix("mcp__") ? $0 : "mcp__\(server)__\($0)" }
                }
            case .command:
                guard let run = s.string("run"), let first = run.split(whereSeparator: { $0.isWhitespace }).first else { continue }
                tools.append("Bash(\(first):*)")
            default:
                continue
            }
        }
        var seen: Set<String> = []
        return tools.filter { seen.insert($0).inserted }
    }
}
