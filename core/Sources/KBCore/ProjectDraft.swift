import Foundation

/// One project as the project editor changes it: its name, its named locations and its scopes. Rows have keys that
/// never change while editing, so typing a title or an id never makes the editor lose its place.
public struct ProjectDraft: Equatable, Sendable {
    public struct Location: Equatable, Sendable, Identifiable {
        public let id: UUID
        public var name: String
        /// Stored with `~` for the home folder.
        public var path: String

        public init(id: UUID = UUID(), name: String, path: String) {
            self.id = id
            self.name = name
            self.path = path
        }
    }

    public struct Scope: Equatable, Sendable, Identifiable {
        public let id: UUID
        /// The scope's folder id once it exists; nil for a new one, which takes `newID` or one from its title.
        public var existing: String?
        public var newID: String
        public var title: String
        public var wide: Bool
        /// Paths of the project's locations it works in.
        public var paths: [String]
        /// As typed: comma separated, parsed on save.
        public var remotes: String
        /// Other scopes of this project it also shows, by key.
        public var includes: [UUID]
        /// Scopes of other projects it reads knowledge from, by id.
        public var related: [String]
        /// Related scopes of this project, kept as they were (the editor doesn't offer them).
        var keptRelated: [String] = []

        public init(id: UUID = UUID(), existing: String? = nil, newID: String = "", title: String, wide: Bool = false,
                    paths: [String] = [], remotes: String = "", includes: [UUID] = [], related: [String] = []) {
            self.id = id
            self.existing = existing
            self.newID = newID
            self.title = title
            self.wide = wide
            self.paths = paths
            self.remotes = remotes
            self.includes = includes
            self.related = related
        }
    }

    /// The project's id once it exists; nil for a new project.
    public let existing: String?
    /// The id a new project gets. Follows the title until the user types one.
    public var newID: String
    public var idEdited = false
    public var title: String
    public var locations: [Location]
    public var scopes: [Scope]
    /// Existing scopes to delete on save, each with the scope its entries move to (a key in `scopes`).
    public var removed: [String: UUID] = [:]
    /// Each removed scope as it was, to restore it.
    var removedScopes: [String: Scope] = [:]

    public var id: String { existing ?? newID }

    /// Sets the title; a new project's id follows it, free in `registry`, until the user types an id.
    public mutating func setTitle(_ t: String, in registry: Registry) {
        title = t
        if isNew, !idEdited { newID = t.trimmingCharacters(in: .whitespaces).isEmpty ? "" : registry.freeID(t) }
    }

    public mutating func setID(_ id: String) {
        newID = id
        idEdited = !id.isEmpty
    }
    public var isNew: Bool { existing == nil }

    /// A new project with only its project-wide scope.
    public init(title: String = "") {
        existing = nil
        newID = Registry.slug(title)
        self.title = title
        locations = []
        scopes = [Scope(title: "Overview", wide: true)]
    }

    /// An existing project as `registry` has it.
    public init?(project: String, registry: Registry) {
        guard let p = registry.projects.first(where: { $0.id == project }) else { return nil }
        existing = p.id
        newID = p.id
        title = p.title
        locations = registry.locations(of: p.id).map { Location(name: $0.name, path: $0.path) }
        let inProject = registry.scopes(in: p.id)
        let keys = Dictionary(uniqueKeysWithValues: inProject.map { ($0.id, UUID()) })
        scopes = inProject.map { s in
            var d = Scope(id: keys[s.id]!, existing: s.id, newID: s.id, title: s.title, wide: s.wide, paths: s.paths,
                          remotes: s.remotes.joined(separator: ", "), includes: s.includes.compactMap { keys[$0] },
                          related: s.related.filter { r in !inProject.contains { $0.id == r } })
            d.keptRelated = s.related.filter { r in inProject.contains { $0.id == r } }
            return d
        }
    }

    // MARK: Locations

    /// Adds a folder as a location; `withScope` also adds a scope of the same name working in it. A folder already
    /// here returns its location.
    @discardableResult
    public mutating func addLocation(path: String, name: String, withScope: Bool, home: String = NSHomeDirectory()) -> UUID {
        let stored = Registry.tildePath(path, home: home)
        if let known = locations.first(where: { $0.path == stored }) { return known.id }
        let loc = Location(name: name, path: stored)
        locations.append(loc)
        if withScope { scopes.append(Scope(title: name, paths: [stored])) }
        return loc.id
    }

    /// Renames a location, and a scope of the same name that works only there, so the two stay in step.
    public mutating func renameLocation(_ id: UUID, to name: String) {
        guard let i = locations.firstIndex(where: { $0.id == id }) else { return }
        let old = locations[i]
        locations[i].name = name
        for j in scopes.indices where !scopes[j].wide && scopes[j].paths == [old.path] && scopes[j].title == old.name {
            scopes[j].title = name
        }
    }

    /// Points a location at another folder; scopes working there follow it.
    public mutating func moveLocation(_ id: UUID, to path: String, home: String = NSHomeDirectory()) {
        guard let i = locations.firstIndex(where: { $0.id == id }) else { return }
        let old = locations[i].path
        let stored = Registry.tildePath(path, home: home)
        guard stored != old, !locations.contains(where: { $0.path == stored }) else { return }
        locations[i].path = stored
        for j in scopes.indices { scopes[j].paths = scopes[j].paths.map { $0 == old ? stored : $0 } }
    }

    /// Removes a location; scopes stop working there.
    public mutating func removeLocation(_ id: UUID) {
        guard let loc = locations.first(where: { $0.id == id }) else { return }
        locations.removeAll { $0.id == id }
        for j in scopes.indices { scopes[j].paths.removeAll { $0 == loc.path } }
    }

    // MARK: Scopes

    @discardableResult
    public mutating func addScope(title: String = "New scope") -> UUID {
        let s = Scope(title: title)
        scopes.append(s)
        return s.id
    }

    public mutating func makeWide(_ key: UUID) {
        for j in scopes.indices { scopes[j].wide = scopes[j].id == key }
        for j in scopes.indices { scopes[j].includes.removeAll { $0 == key } }
        if let i = scopes.firstIndex(where: { $0.id == key }) { scopes[i].includes = [] }
    }

    /// The scopes a removed scope's entries can move to.
    public func moveTargets(excluding key: UUID) -> [Scope] {
        scopes.filter { $0.id != key }
    }

    /// Removes a scope. An existing one is deleted on save and its entries move to the project-wide scope (or
    /// `moveTo`); a new one just goes. The project-wide scope can't be removed.
    public mutating func removeScope(_ key: UUID, moveTo: UUID? = nil) {
        guard let s = scopes.first(where: { $0.id == key }), !s.wide else { return }
        scopes.removeAll { $0.id == key }
        for j in scopes.indices { scopes[j].includes.removeAll { $0 == key } }
        if let id = s.existing {
            removed[id] = moveTo ?? scopes.first(where: \.wide)?.id
            removedScopes[id] = s
        }
    }

    public mutating func restoreScope(_ id: String) {
        guard let s = removedScopes[id] else { return }
        removed[id] = nil
        removedScopes[id] = nil
        scopes.append(s)
    }

    public var removedTitles: [(id: String, title: String, moveTo: String)] {
        removed.keys.sorted().map { id in
            (id, removedScopes[id]?.title ?? id, scopes.first { $0.id == removed[id] }?.title ?? "the project-wide scope")
        }
    }

    // MARK: Checking and saving

    /// What stops it from saving, or nil.
    public func problem(in registry: Registry) -> String? {
        let name = title.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Give the project a name." }
        if isNew {
            if !Registry.isValidID(newID) { return "“\(newID)” can't be a project id: use lowercase letters, digits and dashes." }
            if registry.projects.contains(where: { $0.id == newID }) || registry.scopes.contains(where: { $0.id == newID }) {
                return "The id “\(newID)” is taken. Choose another."
            }
            if locations.isEmpty { return "Add at least one location: a folder the project's code is in." }
        }
        if let bad = locations.first(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "Name the location \((bad.path as NSString).lastPathComponent)."
        }
        if scopes.contains(where: { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }) { return "Every scope needs a title." }
        if scopes.filter(\.wide).count != 1 { return "Pick one project-wide scope." }
        let typed = scopes.filter { $0.existing == nil && !$0.newID.isEmpty }.map(\.newID)
        if let bad = typed.first(where: { !Registry.isValidID($0) }) { return "“\(bad)” can't be a scope id: use lowercase letters, digits and dashes." }
        let others = Set(registry.scopes.filter { $0.project != existing }.map(\.id) + registry.projects.map(\.id))
        if let dup = typed.first(where: { id in others.contains(id) || typed.filter { $0 == id }.count > 1 || scopes.contains { $0.existing == id } }) {
            return "The scope id “\(dup)” is taken. Choose another."
        }
        return nil
    }

    /// Puts the project into `registry`. Removed scopes stay in it (no longer project-wide) so the CLI can move
    /// their entries; delete them with the returned `removals` (scope id → the id its entries move to).
    public func apply(to registry: Registry) throws -> (registry: Registry, project: String, scopes: [String], removals: [String: String]) {
        if let problem = problem(in: registry) { throw NSError(domain: "KB", code: 1, userInfo: [NSLocalizedDescriptionKey: problem]) }
        var r = registry
        let pid = id
        let named = locations.map { Registry.Location(name: $0.name.trimmingCharacters(in: .whitespaces), path: $0.path) }
        let name = title.trimmingCharacters(in: .whitespaces)
        if let i = r.projects.firstIndex(where: { $0.id == pid }) {
            r.projects[i].title = name
            r.projects[i].locations = named
        } else {
            r.projects.append(.init(id: pid, title: name, locations: named))
        }
        // Ids first, so includes can name scopes made in the same save.
        var ids: [UUID: String] = [:]
        for s in scopes {
            if let id = s.existing {
                ids[s.id] = id
            } else {
                var id = s.newID.isEmpty ? r.freeID(s.wide ? name + " wide" : s.title) : s.newID
                if s.newID.isEmpty, ids.values.contains(id) {
                    id = (2...999).lazy.map { "\(id)-\($0)" }.first { c in !ids.values.contains(c) && r.freeID(c) == c } ?? id
                }
                ids[s.id] = id
                r.scopes.append(.init(id: id, title: s.title, project: pid))
            }
        }
        let paths = Set(locations.map(\.path))
        for s in scopes {
            guard let id = ids[s.id], let i = r.scopes.firstIndex(where: { $0.id == id }) else { continue }
            r.scopes[i].title = s.title.trimmingCharacters(in: .whitespaces)
            r.scopes[i].project = pid
            r.scopes[i].wide = s.wide
            // The project-wide scope covers everything; a path it shared with another scope would take sessions from it.
            let taken = Set(scopes.filter { !$0.wide }.flatMap(\.paths))
            r.scopes[i].paths = s.paths.filter { paths.contains($0) && !(s.wide && taken.contains($0)) }
            r.scopes[i].remotes = s.remotes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            r.scopes[i].includes = s.wide ? [] : s.includes.compactMap { ids[$0] }.filter { $0 != id }
            r.scopes[i].related = s.keptRelated.filter { k in !removed.keys.contains(k) } + s.related
        }
        var removals: [String: String] = [:]
        for (id, to) in removed {
            if let i = r.scopes.firstIndex(where: { $0.id == id }) { r.scopes[i].wide = false }
            removals[id] = ids[to] ?? scopes.first(where: \.wide).flatMap { ids[$0.id] }
        }
        // Scopes in the registry that the draft doesn't know (another editor added them) stay as they are.
        if let problem = r.problem { throw NSError(domain: "KB", code: 1, userInfo: [NSLocalizedDescriptionKey: problem]) }
        return (r, pid, scopes.compactMap { ids[$0.id] }, removals)
    }
}

// MARK: The phone's project editor

extension ProjectDraft {
    /// The project as `projects.config.get` sends it.
    public static func json(project: String, registry: Registry, entries: (String) -> Int, home: String = NSHomeDirectory()) -> JSONValue {
        guard let p = registry.projects.first(where: { $0.id == project }) else { return .null }
        let locations = registry.locations(of: project).map { l -> JSONValue in
            let full = expand(l.path, home: home)
            var dir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: full, isDirectory: &dir) && dir.boolValue
            return ["name": .string(l.name), "path": .string(l.path), "exists": .bool(exists),
                    "repository": .bool(exists && FileManager.default.fileExists(atPath: full + "/.git"))]
        }
        let scopes = registry.scopes(in: project).map { s -> JSONValue in
            ["id": .string(s.id), "title": .string(s.title), "wide": .bool(s.wide), "paths": .array(s.paths.map(JSONValue.string)),
             "remotes": .array(s.remotes.map(JSONValue.string)), "includes": .array(s.includes.map(JSONValue.string)),
             "related": .array(s.related.map(JSONValue.string)), "entries": .number(Double(entries(s.id)))]
        }
        return ["id": .string(p.id), "title": .string(p.title), "locations": .array(locations), "scopes": .array(scopes)]
    }

    /// A draft from `projects.config.save`: `id` names an existing project (nil or empty: a new one).
    public static func from(json p: JSONValue, id: String?, registry: Registry, home: String = NSHomeDirectory()) throws -> ProjectDraft {
        func bad(_ m: String) -> Error { NSError(domain: "KB", code: 2, userInfo: [NSLocalizedDescriptionKey: m]) }
        var d: ProjectDraft
        if let id, !id.isEmpty {
            guard let existing = ProjectDraft(project: id, registry: registry) else { throw bad("There's no project \(id).") }
            d = existing
            if let t = p["title"]?.string { d.title = t }
        } else {
            d = ProjectDraft()
            d.setTitle(p["title"]?.string ?? "", in: registry)
            if let typed = p["newId"]?.string, !typed.isEmpty { d.setID(typed) }
        }
        if let locs = p["locations"]?.array {
            d.locations = try locs.map { l in
                guard let path = l["path"]?.string, !path.isEmpty else { throw bad("A location needs a path.") }
                let stored = Registry.tildePath(expand(path, home: home), home: home)
                return Location(name: l["name"]?.string ?? (stored as NSString).lastPathComponent, path: stored)
            }
        }
        guard let list = p["scopes"]?.array else {
            let known = Set(d.locations.map(\.path))
            for i in d.scopes.indices { d.scopes[i].paths.removeAll { !known.contains($0) } }
            return d
        }
        let old = d.scopes
        var scopes: [Scope] = []
        for js in list {
            let wanted = js["id"]?.string ?? ""
            var s = old.first { $0.existing == wanted && !wanted.isEmpty } ?? Scope(title: "")
            if s.existing == nil, !wanted.isEmpty { s.newID = wanted }
            if let t = js["title"]?.string { s.title = t }
            s.wide = js["wide"]?.bool ?? (s.existing != nil ? s.wide : false)
            if let paths = js["paths"]?.array {
                s.paths = paths.compactMap(\.string).map { Registry.tildePath(expand($0, home: home), home: home) }
            }
            if let remotes = js["remotes"]?.array { s.remotes = remotes.compactMap(\.string).joined(separator: ", ") }
            if let related = js["related"]?.array { s.related = related.compactMap(\.string) }
            scopes.append(s)
        }
        for (i, js) in list.enumerated() {
            guard let refs = js["includes"]?.array?.compactMap(\.string) else { continue }
            scopes[i].includes = refs.compactMap { ref in
                scopes.first { $0.existing == ref || ($0.existing == nil && ($0.newID == ref || $0.title == ref)) }?.id
            }
        }
        if !scopes.contains(where: \.wide) {
            scopes.insert(Scope(title: "Overview", wide: true), at: 0)
        } else if scopes.filter(\.wide).count > 1 {
            throw bad("Only one scope can be project-wide.")
        }
        let gone = old.filter { o in !scopes.contains { $0.id == o.id } }
        d.scopes = scopes + gone.map { var g = $0; g.wide = false; return g }
        for g in gone { d.removeScope(g.id) }
        let known = Set(d.locations.map(\.path))
        if let stray = d.scopes.flatMap(\.paths).first(where: { !known.contains($0) }) {
            throw bad("\(stray) isn't one of the project's locations.")
        }
        return d
    }

    static func expand(_ path: String, home: String) -> String {
        path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }
}

/// The folders in a folder under the user's home, for picking a location from the phone.
public enum FolderListing {
    public static func list(_ path: String?, home: String = NSHomeDirectory()) throws -> JSONValue {
        let raw = (path?.isEmpty == false ? path! : "~")
        let full = URL(fileURLWithPath: ProjectDraft.expand(raw, home: home)).standardizedFileURL.resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        guard full == root || full.hasPrefix(root + "/") else {
            throw NSError(domain: "KB", code: 2, userInfo: [NSLocalizedDescriptionKey: "Only folders in your home folder."])
        }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: full)) ?? []
        let folders = names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name -> JSONValue? in
            var dir: ObjCBool = false
            let p = full + "/" + name
            guard fm.fileExists(atPath: p, isDirectory: &dir), dir.boolValue, !name.hasSuffix(".app") else { return nil }
            return ["name": .string(name), "path": .string(Registry.tildePath(p, home: root)),
                    "repository": .bool(fm.fileExists(atPath: p + "/.git"))]
        }
        let parent: JSONValue = full == root ? .null : .string(Registry.tildePath((full as NSString).deletingLastPathComponent, home: root))
        return ["path": .string(Registry.tildePath(full, home: root)), "parent": parent, "folders": .array(folders)]
    }
}
