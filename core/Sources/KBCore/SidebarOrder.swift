import Foundation

/// The user's order of the sidebar rows in a section, stored as keys. Rows added in a later version appear at
/// their default place; rows that are hidden for now (an overview not written yet) keep their place.
public enum SidebarOrder {
    public static let planning = ["notes", "inbox", "decisions", "meetings", "discussions", "ideas", "research", "facts", "followups", "references"]
    public static let work = ["backlog", "pullRequests", "architecture"]

    public static func decode(_ stored: String) -> [String] {
        stored.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func encode(_ keys: [String]) -> String { keys.joined(separator: ",") }

    /// The saved order of the known keys, with any default key it lacks inserted after its default predecessor.
    public static func resolve(_ saved: [String], defaults: [String]) -> [String] {
        var out = saved.filter { defaults.contains($0) }
        out = out.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for (i, key) in defaults.enumerated() where !out.contains(key) {
            let before = defaults[..<i].reversed().first { out.contains($0) }
            let at = before.flatMap { out.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            out.insert(key, at: at)
        }
        return out
    }

    /// Applies a move made in the visible rows to the full order; hidden rows stay where they were.
    public static func move(_ full: [String], visible: [String], from: IndexSet, to: Int) -> [String] {
        var shown = visible
        let moving = from.sorted().map { shown[$0] }
        var target = to
        for i in from.sorted().reversed() {
            shown.remove(at: i)
            if i < target { target -= 1 }
        }
        shown.insert(contentsOf: moving, at: min(max(0, target), shown.count))
        var out = full
        var next = shown.makeIterator()
        for (i, key) in full.enumerated() where visible.contains(key) {
            if let k = next.next() { out[i] = k }
        }
        return out
    }
}
