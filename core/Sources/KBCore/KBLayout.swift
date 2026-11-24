import Foundation

/// Where the KB keeps things; the same rules as `kb layout` in the CLI.
///
/// The split layout, used when `shared/kb.json` exists:
/// - `<root>/shared/`: kb.json, people, knowledge sources, email state, daily plans, reminders, goals
/// - `<root>/<scope>/`: the scope's private entries and settings.json
/// - `<repo>/knowledgebase/`: the team's decisions, facts, architecture, follow-ups and backlog of a scope with a
///   repo, committed with the code. The Overview has no repo and stays private.
///
/// The legacy layout keeps everything in `<root>`, entries in `<root>/projects/<scope>/`.
public struct KBLayout: Sendable, Equatable {
    public static let teamSections: Set<KBSection> = [.decisions, .facts, .architecture, .followups, .backlog, .overview]
    public static let teamFolder = "knowledgebase"

    public let root: URL
    public let isSplit: Bool
    /// Each scope's main checkout, for scopes with a repo on this Mac.
    public let checkouts: [String: URL]

    public init(root: URL, isSplit: Bool, checkouts: [String: URL]) {
        self.root = root
        self.isSplit = isSplit
        self.checkouts = checkouts
    }

    public static func isSplit(root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("shared/kb.json").path)
    }

    /// Where the files that span every project are.
    public static func home(root: URL) -> URL {
        isSplit(root: root) ? root.appendingPathComponent("shared", isDirectory: true) : root
    }

    /// The layout for `root`, with the scopes' checkouts read from kb.json. Cached until kb.json changes.
    public static func of(root: URL) -> KBLayout {
        let split = isSplit(root: root)
        let registry = home(root: root).appendingPathComponent("kb.json")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: registry.path)[.modificationDate] as? Date) ?? .distantPast
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let hit = cache.layouts[root.path], hit.stamp == stamp { return hit.layout }
        var checkouts: [String: URL] = [:]
        if split, let (scopes, _) = try? KBIndex.parseRegistry(at: registry) {
            for s in scopes {
                if let dir = checkout(paths: s.paths) { checkouts[s.id] = dir }
            }
        }
        let layout = KBLayout(root: root, isSplit: split, checkouts: checkouts)
        cache.layouts[root.path] = (stamp, layout)
        return layout
    }

    /// The first of a scope's paths that is a folder on this Mac.
    static func checkout(paths: [String]) -> URL? {
        for p in paths {
            let url = URL(fileURLWithPath: KBConfig.expandTilde(p), isDirectory: true).standardizedFileURL
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return nil
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var layouts: [String: (stamp: Date, layout: KBLayout)] = [:]
    }

    private static let cache = Cache()

    public var home: URL { isSplit ? root.appendingPathComponent("shared", isDirectory: true) : root }

    public func privateDir(_ scope: String) -> URL {
        isSplit ? root.appendingPathComponent(scope, isDirectory: true)
            : root.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
    }

    public func teamDir(_ scope: String) -> URL? {
        guard isSplit else { return nil }
        return checkouts[scope]?.appendingPathComponent(Self.teamFolder, isDirectory: true)
    }

    /// The private folder first (it holds every entry), then the team one, whose entries not copied in yet (a
    /// teammate's, just pulled) are read from there.
    public func dirs(_ scope: String) -> [URL] {
        [privateDir(scope)] + (teamDir(scope).map { [$0] } ?? [])
    }

    /// Where a new entry goes: always the private folder. A shared one gets a copy in the team folder from `kb share`.
    public func newEntryDir(_ scope: String, _ section: KBSection) -> URL {
        privateDir(scope)
    }

    /// The path of `id` inside a scope folder.
    static func relativePath(_ id: EntryID) -> String {
        id.section == .overview ? "overview.md" : "\(id.section.rawValue)/\(id.stem).md"
    }

    /// The entry's file: where it is, or where a new one goes.
    public func fileURL(_ id: EntryID) -> URL {
        let rel = Self.relativePath(id)
        for dir in dirs(id.project) {
            let url = dir.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return newEntryDir(id.project, id.section).appendingPathComponent(rel)
    }

    /// Whether `url` is in a repo's team folder.
    public func isTeam(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return checkouts.keys.contains { scope in
            teamDir(scope).map { path.hasPrefix($0.standardizedFileURL.path + "/") } ?? false
        }
    }

    /// The id of the entry at `url`, in any scope's team or private folder.
    public func entryID(fileURL url: URL) -> EntryID? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let scopes = isSplit ? Array(Set(checkouts.keys).union(registeredScopes)) : []
        for scope in scopes {
            for dir in dirs(scope) {
                let base = dir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                guard path.hasPrefix(base) else { continue }
                let rel = path.dropFirst(base.count).split(separator: "/").map(String.init)
                return EntryID.from(scope: scope, relative: rel)
            }
        }
        return nil
    }

    /// Scope ids from kb.json, for private folders that aren't in `checkouts`.
    private var registeredScopes: [String] {
        guard let (scopes, _) = try? KBIndex.parseRegistry(at: home.appendingPathComponent("kb.json")) else { return [] }
        return scopes.map(\.id)
    }
}
