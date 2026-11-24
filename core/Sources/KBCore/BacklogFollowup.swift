import Foundation

/// A follow-up whose only point is to create a PBI or bug ("Create an Android PBI for X"). Such work belongs under
/// Backlog → Suggested backlog items, not in follow-ups; `kb followup to-backlog` moves it. The same rule as
/// `backlog_task_title` in kb.py.
public enum BacklogFollowup {
    private static let pattern = try! NSRegularExpression(pattern:
        #"^\s*(?:create|opret|lav|add|write|raise|propose)\s+(?:(?:an?|the|new|some|two|both|en|et|nye?)\s+)*"#
        + #"(?:(?:[\w./&-]+\s+){0,3}?)"#
        + #"(?:pbi\(s\)|(?:pbis?|bugs?|backlog[- ]items?|work[- ]items?|user stor(?:y|ies)|tickets?)\b)"#
        + #"(?:\s*(?:for|to|about|on|covering|til|om|:|-|–)\s+(.*)|[\s.]*)$"#, options: [.caseInsensitive])

    /// The work the follow-up names ("X"), or the whole title when it names nothing more; nil for other follow-ups.
    public static func workTitle(_ title: String) -> String? {
        let range = NSRange(title.startIndex..., in: title)
        guard let m = pattern.firstMatch(in: title, range: range) else { return nil }
        let rest = Range(m.range(at: 1), in: title).map { String(title[$0]) }?
            .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? ""
        return rest.isEmpty ? title.trimmingCharacters(in: .whitespaces) : rest.prefix(1).uppercased() + rest.dropFirst()
    }
}
