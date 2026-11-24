import Foundation

/// Mindmill's own tags on work items from the connected tracker (Azure DevOps, Jira, the local tracker…), kept in the KB
/// only. The tool's own tags are never changed by them: a local tag reaches the tool only when the user aligns it, for
/// the item or for every item, and then it is added beside the tool's tags, never in place of them.
public struct ItemTags: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var tags: [String]
        /// Local tags the user chose to write to the tool for this item.
        public var aligned: [String]

        public init(tags: [String] = [], aligned: [String] = []) {
            self.tags = tags
            self.aligned = aligned
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            aligned = try c.decodeIfPresent([String].self, forKey: .aligned) ?? []
        }
    }

    public var version = 1
    /// By `<tracker kind>:<item id>`, e.g. `azure-devops:4711`.
    public var items: [String: Item] = [:]
    /// Tags aligned for every item that has them.
    public var alignedTags: [String] = []

    enum CodingKeys: String, CodingKey {
        case version, items
        case alignedTags = "aligned_tags"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        items = try c.decodeIfPresent([String: Item].self, forKey: .items) ?? [:]
        alignedTags = try c.decodeIfPresent([String].self, forKey: .alignedTags) ?? []
    }

    public static func key(kind: String, id: String) -> String { "\(kind):\(id)" }

    /// In the knowledge base's home folder, beside people.json: the user's own, never in a team folder or the tool.
    public static func url(root: URL) -> URL { KBLayout.home(root: root).appendingPathComponent("item-tags.json") }

    public static func load(root: URL) -> ItemTags {
        guard let data = try? Data(contentsOf: url(root: root)) else { return ItemTags() }
        return (try? JSONDecoder().decode(ItemTags.self, from: data)) ?? ItemTags()
    }

    public func save(root: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let target = Self.url(root: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: target, options: .atomic)
    }

    public func tags(_ key: String) -> [String] { items[key]?.tags ?? [] }

    public mutating func setTags(_ tags: [String], for key: String) {
        var item = items[key] ?? Item()
        item.tags = EntryTags.normalized(tags)
        item.aligned = item.aligned.filter { item.tags.contains($0) }
        items[key] = item.tags.isEmpty ? nil : item
    }

    public mutating func setAligned(_ tag: String, _ on: Bool, for key: String) {
        guard var item = items[key] else { return }
        let t = EntryTags.normalize(tag)
        item.aligned = on ? EntryTags.normalized(item.aligned + [t]) : item.aligned.filter { $0 != t }
        items[key] = item
    }

    public mutating func setAlignedEverywhere(_ tag: String, _ on: Bool) {
        let t = EntryTags.normalize(tag)
        alignedTags = on ? EntryTags.normalized(alignedTags + [t]) : alignedTags.filter { $0 != t }
    }

    public func isAligned(_ tag: String, for key: String) -> Bool {
        let t = EntryTags.normalize(tag)
        return alignedTags.contains(t) || (items[key]?.aligned.contains(t) ?? false)
    }

    /// The local tags the user aligned for this item, that the tool doesn't have yet: the only tags that may be written.
    public func pending(for key: String, toolTags: [String]) -> [String] {
        TrackerTagSync.additions(local: tags(key), aligned: (items[key]?.aligned ?? []) + alignedTags, toolTags: toolTags)
    }

    public var allTagLists: [[String]] { items.values.map(\.tags) }
}

/// The one rule for what KB may write to a tracker's tags.
public enum TrackerTagSync {
    /// Aligned local tags the tool doesn't have, compared without case. Nothing else ever leaves the KB.
    public static func additions(local: [String], aligned: [String], toolTags: [String]) -> [String] {
        let allowed = Set(EntryTags.normalized(aligned))
        let present = Set(EntryTags.normalized(toolTags))
        return EntryTags.normalized(local).filter { allowed.contains($0) && !present.contains($0) }
    }

    /// The tool's tags after aligning: all of its own, unchanged and in order, then the additions.
    public static func merged(toolTags: [String], additions: [String]) -> [String] {
        let present = Set(EntryTags.normalized(toolTags))
        return toolTags + additions.filter { !present.contains(EntryTags.normalize($0)) }
    }
}
