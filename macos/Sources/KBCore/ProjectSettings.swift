import Foundation

/// `projects/<id>/settings.json`. Keys the app does not know are kept when it saves.
public struct ProjectSettings: Equatable, Sendable {
    public struct Tracker: Equatable, Sendable {
        public var kind = "none"
        public var organization = ""
        public var project = ""
        public var areaPath = ""
        public var iterationRoot = ""
        public var titlePrefix = ""
        public var tags: [String] = []
        /// Empty means `null`.
        public var defaultParent = ""
        public var assignee = ""
        public var foundIn = ""

        public init() {}
    }

    public struct Convention: Equatable, Sendable, Identifiable {
        public var id = UUID()
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }

        public static func == (a: Convention, b: Convention) -> Bool { a.key == b.key && a.value == b.value }
    }

    public var tracker = Tracker()
    public var conventions: [Convention] = []
    public var sources: [KnowledgeSource] = []
    /// Whether the file had a `tracker` object; a project without one is not set up yet.
    public var hasTracker = false
    var raw: [String: AnyHashableSendable] = [:]

    public init() {}

    public static func url(project: String, root: URL) -> URL {
        KBLayout.of(root: root).privateDir(project).appendingPathComponent("settings.json")
    }

    public static func load(project: String, root: URL) -> ProjectSettings {
        guard let data = try? Data(contentsOf: url(project: project, root: root)) else { return ProjectSettings() }
        return parse(data)
    }

    public static func parse(_ data: Data) -> ProjectSettings {
        var s = ProjectSettings()
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return s }
        s.raw = json.mapValues(AnyHashableSendable.init)
        if let t = json["tracker"] as? [String: Any] {
            s.hasTracker = true
            s.tracker.kind = t["kind"] as? String ?? "none"
            s.tracker.organization = t["organization"] as? String ?? ""
            s.tracker.project = t["project"] as? String ?? ""
            s.tracker.areaPath = t["area_path"] as? String ?? ""
            s.tracker.iterationRoot = t["iteration_root"] as? String ?? ""
            s.tracker.titlePrefix = t["title_prefix"] as? String ?? ""
            s.tracker.tags = t["tags"] as? [String] ?? []
            if let n = t["default_parent"] as? NSNumber {
                s.tracker.defaultParent = n.stringValue
            } else {
                s.tracker.defaultParent = t["default_parent"] as? String ?? ""
            }
            s.tracker.assignee = t["assignee"] as? String ?? ""
            s.tracker.foundIn = t["found_in"] as? String ?? ""
        }
        s.sources = SourceList.parse(json["sources"])
        if let c = json["conventions"] as? [String: Any] {
            s.conventions = c.keys.sorted().map { Convention(key: $0, value: (c[$0] as? String) ?? "\(c[$0] ?? "")") }
        }
        return s
    }

    public func serialized() throws -> Data {
        var json = raw.mapValues(\.value)
        guard hasTracker || tracker != Tracker() || json["tracker"] != nil else { return try serializedWithoutTracker(json) }
        var t = (json["tracker"] as? [String: Any]) ?? [:]
        t["kind"] = tracker.kind
        t["organization"] = tracker.organization
        t["project"] = tracker.project
        t["area_path"] = tracker.areaPath
        t["iteration_root"] = tracker.iterationRoot
        t["title_prefix"] = tracker.titlePrefix
        t["tags"] = tracker.tags
        let parent = tracker.defaultParent.trimmingCharacters(in: .whitespaces)
        if parent.isEmpty {
            t["default_parent"] = NSNull()
        } else if let n = Int(parent) {
            t["default_parent"] = n
        } else {
            t["default_parent"] = parent
        }
        t["assignee"] = tracker.assignee
        t["found_in"] = tracker.foundIn
        json["tracker"] = t
        var c: [String: Any] = [:]
        for conv in conventions {
            let k = conv.key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { c[k] = conv.value }
        }
        json["conventions"] = c
        if !sources.isEmpty || json["sources"] != nil { json["sources"] = sources.map(\.json) }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data + Data("\n".utf8)
    }

    /// A project with only sources (or conventions) and no tracker keeps having no `tracker` object.
    private func serializedWithoutTracker(_ base: [String: Any]) throws -> Data {
        var json = base
        if !conventions.isEmpty || json["conventions"] != nil {
            var c: [String: Any] = [:]
            for conv in conventions where !conv.key.trimmingCharacters(in: .whitespaces).isEmpty {
                c[conv.key.trimmingCharacters(in: .whitespaces)] = conv.value
            }
            json["conventions"] = c
        }
        if !sources.isEmpty || json["sources"] != nil { json["sources"] = sources.map(\.json) }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data + Data("\n".utf8)
    }

    public func save(project: String, root: URL) throws {
        let u = ProjectSettings.url(project: project, root: root)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialized().write(to: u, options: .atomic)
    }

    public static func == (a: ProjectSettings, b: ProjectSettings) -> Bool {
        a.tracker == b.tracker && a.conventions == b.conventions && a.hasTracker == b.hasTracker && a.sources == b.sources
    }
}

/// Wraps a JSON value so `ProjectSettings` can keep unknown keys and still be `Sendable`.
struct AnyHashableSendable: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}
