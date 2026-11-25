import Foundation

/// Finding text in a conversation the way ⌘F does in other apps: case and accents don't matter, and every place the
/// words appear is found, not just the first.
public enum TextFind {
    public static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The search as typed, without the spaces around it; empty means nothing is searched for.
    public static func query(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every place `query` appears in `text`, in order, without overlaps.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let q = Self.query(query)
        guard !q.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: q, options: options, range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    public static func contains(_ text: String, _ query: String) -> Bool {
        let q = Self.query(query)
        return !q.isEmpty && text.range(of: q, options: options) != nil
    }

    /// "3 of 12", "No matches", or nothing while the field is empty.
    public static func position(current: Int, count: Int, query: String) -> String {
        guard !Self.query(query).isEmpty else { return "" }
        guard count > 0 else { return "No matches" }
        return "\(min(max(current, 0), count - 1) + 1) of \(count)"
    }
}
