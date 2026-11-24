import Foundation

/// The tags on KB entries and on tracker items: areas and systems such as `auth`, `bff` or `common repo`, shared across
/// every kind of item so one area can be followed through the whole app. Tags the user removes are kept in `tags_off`,
/// and the background tagger never adds those back, so the user's own changes always stand.
public enum EntryTags {
    public static let offKey = "tags_off"

    /// Lower-case, single spaces, no leading `#`.
    public static func normalize(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        return t.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Normalized, without empties and repeats, in their first order.
    public static func normalized(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.map(normalize).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The user changed the tags from `old` to `new`: what they removed joins `off`, what they added leaves it.
    public static func off(old: [String], new: [String], off: [String]) -> [String] {
        let o = Set(normalized(old)), n = Set(normalized(new))
        let removed = o.subtracting(n)
        return normalized(off.filter { !n.contains(normalize($0)) } + removed.sorted())
    }

    /// Tags the tagger may add: not there yet and not removed by the user.
    public static func autoAdd(_ suggested: [String], to tags: [String], off: [String]) -> [String] {
        let blocked = Set(normalized(tags) + normalized(off))
        return normalized(tags) + normalized(suggested).filter { !blocked.contains($0) }
    }

    /// Normalizes the tags being saved and records the ones the user removed since `old` (the file as it was on disk).
    public static func recordUserEdit(_ fm: inout Frontmatter, old: Frontmatter?) {
        let new = normalized(fm.list("tags"))
        if fm["tags"] != nil || !new.isEmpty, new != fm.list("tags") { fm.set("tags", .list(new)) }
        guard let old else { return }
        let off = Self.off(old: old.list("tags"), new: new, off: fm.list(offKey))
        if off != fm.list(offKey) { fm.set(offKey, off.isEmpty ? nil : .list(off)) }
    }

    /// An item passes when it has every selected tag.
    public static func matches(_ tags: [String], selected: Set<String>) -> Bool {
        guard !selected.isEmpty else { return true }
        return selected.isSubset(of: Set(normalized(tags)))
    }

    /// Every tag in use with how many items have it, the most used first.
    public static func vocabulary(_ lists: [[String]]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for list in lists { for t in Set(normalized(list)) { counts[t, default: 0] += 1 } }
        return counts.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }
}
