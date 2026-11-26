import Foundation

/// The user's notes: thoughts that don't belong anywhere yet. Private unless the user shares one; talked through and
/// sorted with the AI, which suggests where each part belongs.
public enum NoteStatus: String, CaseIterable, Sendable {
    case open, filed

    public var title: String {
        switch self {
        case .open: return "Open"
        case .filed: return "Filed"
        }
    }

    public static let icon = "note.text"
}

extension KBEntry {
    public var noteStatus: NoteStatus { NoteStatus(rawValue: rawStatus) ?? .open }
    public var noteUpdated: String { field("updated") ?? date }
}

/// A note's parts: what the user wrote, what it comes to (confirmed with them), and where its parts went.
public struct NoteBody: Equatable, Sendable {
    public var text: String
    public var summary: String
    public var filed: [String]

    public init(_ body: String) {
        text = (GoalBody.section("Notes", in: body) ?? body).trimmingCharacters(in: .whitespacesAndNewlines)
        summary = (GoalBody.section("Summary", in: body) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        filed = (GoalBody.section("Filed", in: body) ?? "").components(separatedBy: "\n").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") ? String(t.dropFirst(2)) : nil
        }
    }

    public static func template(text: String) -> String {
        "## Notes\n\(text)\n\n## Summary\n\n## Filed\n"
    }

    /// A title from the first words of the text, for a note written down without one.
    public static func title(from text: String) -> String {
        let first = text.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " #-*")) }
            .first { !$0.isEmpty } ?? "Note"
        let words = first.split(separator: " ")
        return words.prefix(8).joined(separator: " ") + (words.count > 8 ? "…" : "")
    }
}

/// What the AI does with a note, in its session (the mindmill:notes skill).
public enum NoteAction: String, CaseIterable, Sendable {
    /// Talk it through: summarise, check with the user, suggest where things belong.
    case discuss
    /// Suggest where each part belongs.
    case sort

    public var display: String {
        switch self {
        case .discuss: return "Talk it through"
        case .sort: return "Sort it"
        }
    }
}
