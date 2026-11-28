import Foundation

/// A Mindmill instance: a knowledge base of its own (a folder with its projects and scopes) with Mindmill's own data
/// for it (sessions, factories, tests). One is open at a time. kb's config lists them next to `root`, the open one's
/// folder, which `kb` and the skills read, and `instance`, the open one's id.
public struct MindmillInstance: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The folder as written in the config, `~` for the home folder.
    public var root: String

    /// The first instance keeps Mindmill's data where it always was.
    public static let mainID = "main"

    public init(id: String, name: String, root: String) {
        self.id = id
        self.name = name
        self.root = root
    }

    public var rootURL: URL { KBConfig.rootURL(for: root) }

    /// Mindmill's data for this instance in `base`, the data folder: the folder itself for the first instance, a
    /// folder in it for every other.
    public func dataFolder(in base: URL) -> URL {
        id == Self.mainID ? base : base.appendingPathComponent("instances", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }
}

public struct InstanceError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The instances in kb's config and which one is open.
public struct InstanceList: Equatable, Sendable {
    public var instances: [MindmillInstance]
    public var current: String

    public init(instances: [MindmillInstance], current: String) {
        self.instances = instances
        self.current = current
    }

    public var open: MindmillInstance { instances.first { $0.id == current } ?? instances[0] }

    public func instance(_ id: String) -> MindmillInstance? { instances.first { $0.id == id } }

    public func instance(root: URL) -> MindmillInstance? {
        let target = root.standardizedFileURL.path
        return instances.first { $0.rootURL.path == target }
    }

    public static func load(configURL: URL = KBConfig.defaultConfigURL) -> InstanceList {
        let stored = stored(configURL: configURL)
        return resolve(stored.listed, root: KBConfig.loadRootPath(configURL: configURL), named: stored.named)
    }

    /// Whether the config says what this list says, so it needn't be written.
    public func isRecorded(configURL: URL = KBConfig.defaultConfigURL) -> Bool {
        let stored = Self.stored(configURL: configURL)
        return stored.listed == instances && stored.named == current
    }

    static func stored(configURL: URL) -> (listed: [MindmillInstance], named: String?) {
        let json = (try? Data(contentsOf: configURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let listed = (json["instances"] as? [[String: Any]] ?? []).compactMap { o -> MindmillInstance? in
            guard let id = o["id"] as? String, !id.isEmpty, let root = o["root"] as? String, !root.isEmpty else { return nil }
            return MindmillInstance(id: id, name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id, root: root)
        }
        return (listed, json["instance"] as? String)
    }

    /// `root` always belongs to an instance: the one with that folder, else the one the config says is open (its
    /// folder moved, as `kb layout migrate` does), else a new one; with no list yet, the first.
    public static func resolve(_ listed: [MindmillInstance], root: String, named: String?) -> InstanceList {
        var list: [MindmillInstance] = []
        for i in listed where !list.contains(where: { $0.id == i.id }) { list.append(i) }
        let rootURL = KBConfig.rootURL(for: root)
        if let hit = list.first(where: { $0.rootURL.path == rootURL.path }) { return InstanceList(instances: list, current: hit.id) }
        if let named, let i = list.firstIndex(where: { $0.id == named }) {
            list[i].root = root
            return InstanceList(instances: list, current: named)
        }
        if list.isEmpty {
            return InstanceList(instances: [MindmillInstance(id: MindmillInstance.mainID, name: "Main", root: root)], current: MindmillInstance.mainID)
        }
        var made = InstanceList(instances: list, current: list[0].id)
        let name = rootURL.lastPathComponent.isEmpty ? "Mindmill" : rootURL.lastPathComponent.capitalized
        let new = MindmillInstance(id: made.uniqueID(for: name), name: made.uniqueName(name), root: root)
        made.instances.append(new)
        made.current = new.id
        return made
    }

    /// Writes the list, the open one's id and its folder as `root`, keeping the config's other keys.
    public func save(configURL: URL = KBConfig.defaultConfigURL) throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL), let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json = existing
        }
        json["root"] = open.root
        json["instance"] = open.id
        json["instances"] = instances.map { ["id": $0.id, "name": $0.name, "root": $0.root] }
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: configURL, options: .atomic)
    }

    public func uniqueID(for name: String) -> String {
        let base = Slug.make(name, maxLength: 40)
        var id = base
        var n = 2
        while id == MindmillInstance.mainID || instances.contains(where: { $0.id == id }) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    func uniqueName(_ name: String) -> String {
        var out = name
        var n = 2
        while instances.contains(where: { $0.name.caseInsensitiveCompare(out) == .orderedSame }) {
            out = "\(name) \(n)"
            n += 1
        }
        return out
    }

    /// Adds an instance for the folder `root`; `InstanceFolder.prepare` makes its knowledge base.
    @discardableResult
    public mutating func add(name: String, root: String) throws -> MindmillInstance {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try checkName(name, except: nil)
        let url = KBConfig.rootURL(for: root)
        if let other = instances.first(where: { Self.overlaps($0.rootURL, url) }) {
            throw InstanceError(other.rootURL.path == url.path ? "That folder is the instance \(other.name) already."
                                : "That folder overlaps the instance \(other.name)'s folder: choose one outside it.")
        }
        let made = MindmillInstance(id: uniqueID(for: name), name: name, root: KBConfig.abbreviateTilde(url.path))
        instances.append(made)
        return made
    }

    public mutating func rename(_ id: String, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = instances.firstIndex(where: { $0.id == id }) else { throw InstanceError("There's no such instance.") }
        try checkName(name, except: id)
        instances[i].name = name
    }

    /// Takes the instance off the list. Its folder and its data stay where they are.
    public mutating func forget(_ id: String) throws {
        guard id != current else { throw InstanceError("Switch to another instance before removing this one.") }
        guard instances.contains(where: { $0.id == id }) else { throw InstanceError("There's no such instance.") }
        instances.removeAll { $0.id == id }
    }

    private func checkName(_ name: String, except id: String?) throws {
        guard !name.isEmpty else { throw InstanceError("Give the instance a name.") }
        if let other = instances.first(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw InstanceError("There's an instance called \(other.name) already.")
        }
    }

    static func overlaps(_ a: URL, _ b: URL) -> Bool {
        let x = a.standardizedFileURL.path, y = b.standardizedFileURL.path
        return x == y || x.hasPrefix(y + "/") || y.hasPrefix(x + "/")
    }
}

/// A new instance's folder: new or empty, it gets an empty knowledge base; a knowledge base already is used as it is.
public enum InstanceFolder {
    @discardableResult
    public static func prepare(_ url: URL) throws -> KnowledgeBaseFolder {
        let state = KnowledgeBaseFolder.check(url)
        switch state {
        case .inUse(let what):
            throw InstanceError("That folder holds \(what). Choose a new or empty folder, or one with a Mindmill knowledge base.")
        case .knowledgeBase:
            return state
        case .new, .empty:
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Registry.createKnowledgeBase(root: url)
            return state
        }
    }
}
