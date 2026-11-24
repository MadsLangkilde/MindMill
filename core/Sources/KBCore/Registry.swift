import Foundation

/// kb.json as the app edits it: projects, each with scopes, one of them project-wide. Writes version 2; reads 1 and 2.
public struct Registry: Equatable, Sendable {
    public struct Project: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// The folders the project's code lives in, each with a name. Its scopes' `paths` point at these.
        public var locations: [Location]
        public init(id: String, title: String, locations: [Location] = []) {
            self.id = id
            self.title = title
            self.locations = locations
        }
    }

    /// A named folder of a project, stored with `~` for the home folder.
    public struct Location: Equatable, Sendable, Hashable {
        public var name: String
        public var path: String
        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    public struct Scope: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var project: String
        public var wide: Bool
        public var paths: [String]
        public var remotes: [String]
        public var related: [String]
        /// Scopes whose entries this one also shows. Ignored on the project-wide scope, which shows all.
        public var includes: [String]

        public init(id: String, title: String, project: String, wide: Bool = false, paths: [String] = [],
                    remotes: [String] = [], related: [String] = [], includes: [String] = []) {
            self.includes = includes
            self.id = id
            self.title = title
            self.project = project
            self.wide = wide
            self.paths = paths
            self.remotes = remotes
            self.related = related
        }
    }

    public var projects: [Project]
    public var scopes: [Scope]

    public init(projects: [Project] = [], scopes: [Scope] = []) {
        self.projects = projects
        self.scopes = scopes
    }

    public static func load(_ url: URL) throws -> Registry {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        var r = Registry()
        for p in json["projects"] as? [[String: Any]] ?? [] {
            guard let id = p["id"] as? String else { continue }
            let title = p["title"] as? String ?? id
            let locations = (p["locations"] as? [[String: Any]] ?? []).compactMap { l -> Location? in
                guard let path = l["path"] as? String, !path.isEmpty else { return nil }
                return Location(name: l["name"] as? String ?? (path as NSString).lastPathComponent, path: path)
            }
            if let nested = p["scopes"] as? [[String: Any]] {
                r.projects.append(Project(id: id, title: title, locations: locations))
                r.scopes += nested.compactMap { scope($0, project: id, wide: $0["wide"] as? Bool ?? false) }
            } else if let s = scope(p, project: id, wide: true) {
                r.projects.append(Project(id: id, title: title))
                r.scopes.append(s)
            }
        }
        return r
    }

    private static func scope(_ d: [String: Any], project: String, wide: Bool) -> Scope? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        return Scope(id: id, title: d["title"] as? String ?? id, project: project, wide: wide,
                     paths: d["paths"] as? [String] ?? [], remotes: d["remotes"] as? [String] ?? [],
                     related: d["related"] as? [String] ?? [], includes: d["includes"] as? [String] ?? [])
    }

    public func scopes(in project: String) -> [Scope] { scopes.filter { $0.project == project } }

    /// The project's named locations, then every folder its scopes point at that has no name yet: named after the
    /// scope when only that scope uses it, else after the folder.
    public func locations(of project: String) -> [Location] {
        var out = projects.first { $0.id == project }?.locations ?? []
        let inProject = scopes(in: project)
        for s in inProject {
            for path in s.paths where !out.contains(where: { $0.path == path }) {
                let shared = inProject.filter { $0.paths.contains(path) }.count > 1
                out.append(Location(name: s.paths.count == 1 && !shared ? s.title : (path as NSString).lastPathComponent, path: path))
            }
        }
        return out
    }

    /// What is wrong, or nil: ids must be unique folder-safe slugs, and each project needs one project-wide scope.
    public var problem: String? {
        let ids = scopes.map(\.id)
        if let dup = ids.first(where: { id in ids.filter { $0 == id }.count > 1 }) { return "Two scopes have the id “\(dup)”." }
        if let bad = ids.first(where: { !Self.isValidID($0) }) { return "“\(bad)” can't be a scope id: use lowercase letters, digits and dashes." }
        let pids = projects.map(\.id)
        if let dup = pids.first(where: { id in pids.filter { $0 == id }.count > 1 }) { return "Two projects have the id “\(dup)”." }
        for p in projects where scopes(in: p.id).filter(\.wide).count != 1 {
            return "\(p.title) needs exactly one project-wide scope."
        }
        return nil
    }

    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" } && !id.hasPrefix("-")
    }

    public static func slug(_ title: String) -> String {
        let s = title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return s.split(separator: "-").joined(separator: "-")
    }

    public var json: Data {
        let out: [String: Any] = [
            "version": 2,
            "projects": projects.map { p -> [String: Any] in
                var d: [String: Any] = [
                    "id": p.id, "title": p.title,
                    "scopes": scopes(in: p.id).map { s -> [String: Any] in
                        let inc = s.includes.filter { i in i != s.id && scopes(in: p.id).contains { $0.id == i } }
                        let related = s.related.filter { r in r != s.id && !inc.contains(r) && scopes.contains { $0.id == r } }
                        var d: [String: Any] = ["id": s.id, "title": s.title, "paths": s.paths, "remotes": s.remotes, "related": related]
                        if s.wide { d["wide"] = true }
                        if !s.wide, !inc.isEmpty { d["includes"] = inc }
                        return d
                    },
                ]
                if !p.locations.isEmpty {
                    d["locations"] = p.locations.map { ["name": $0.name, "path": $0.path] }
                }
                return d
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Writes kb.json and makes a private folder for every scope.
    public func save(root: URL) throws {
        if let problem { throw NSError(domain: "KB", code: 1, userInfo: [NSLocalizedDescriptionKey: problem]) }
        try json.write(to: KBLayout.home(root: root).appendingPathComponent("kb.json"), options: .atomic)
        let split = KBLayout.isSplit(root: root)
        for s in scopes {
            let dir = split ? root.appendingPathComponent(s.id) : root.appendingPathComponent("projects/\(s.id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// A new knowledge base at `root` in the split layout, with no projects yet. Leaves an existing one alone.
    public static func createKnowledgeBase(root: URL) throws {
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let file = shared.appendingPathComponent("kb.json")
        guard !FileManager.default.fileExists(atPath: file.path),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("kb.json").path) else { return }
        try Registry().json.write(to: file, options: .atomic)
    }

    /// An id from `title` that no scope or project has yet.
    public func freeID(_ title: String) -> String {
        let base = Self.slug(title).isEmpty ? "scope" : Self.slug(title)
        let taken = Set(scopes.map(\.id) + projects.map(\.id))
        if !taken.contains(base) { return base }
        return (2...999).lazy.map { "\(base)-\($0)" }.first { !taken.contains($0) } ?? base + "-x"
    }

    /// Adds a repository as a scope of `project` and returns its id; a repository already in a scope returns that
    /// scope. `path` is stored with `~` for the home folder.
    @discardableResult
    public mutating func addRepository(path: String, title: String, project: String, home: String = NSHomeDirectory()) -> String {
        let stored = Self.tildePath(path, home: home)
        if let known = scopes.first(where: { $0.paths.contains(stored) || $0.paths.contains(path) }) { return known.id }
        let id = freeID(title)
        scopes.append(Scope(id: id, title: title, project: project, paths: [stored]))
        return id
    }

    /// A new project with its project-wide scope; returns the project id.
    @discardableResult
    public mutating func addProject(title: String) -> String {
        let id = freeID(title)
        projects.append(Project(id: id, title: title))
        let wide = freeID(title + " wide")
        scopes.append(Scope(id: wide, title: "Project-wide", project: id, wide: true))
        return id
    }

    /// Points a scope at a checkout on this Mac, keeping its other paths after it.
    public mutating func locate(scope: String, path: String, home: String = NSHomeDirectory()) {
        guard let i = scopes.firstIndex(where: { $0.id == scope }) else { return }
        let stored = Self.tildePath(path, home: home)
        let old = scopes[i].paths.first
        scopes[i].paths = [stored] + scopes[i].paths.filter { $0 != stored }
        guard let old, old != stored, let p = projects.firstIndex(where: { $0.id == scopes[i].project }) else { return }
        for j in projects[p].locations.indices where projects[p].locations[j].path == old {
            projects[p].locations[j].path = stored
        }
    }

    public static func tildePath(_ path: String, home: String) -> String {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        return path == h ? "~" : path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
    }
}
