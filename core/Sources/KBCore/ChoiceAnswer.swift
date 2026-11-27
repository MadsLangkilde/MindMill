import Foundation

/// A click on one of a reply's choices: the conversation shows the option marked as picked in the reply, not the
/// answer again as a message of the user's. Worked out from the text alone, so a conversation read back from disk
/// shows the same.
public enum ChoiceAnswer {
    /// An option as its button shows it and as a click sends it: without "(Recommended)".
    public static func label(_ option: String) -> String {
        option.replacingOccurrences(of: "(Recommended)", with: "").replacingOccurrences(of: "(recommended)", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The options `answer` picks from the last choices block of `reply`; nil when it isn't an answer to them.
    public static func picked(_ answer: String, reply: String) -> Set<String>? {
        guard let c = choices(reply) else { return nil }
        let labels = c.options.map(label)
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if labels.contains(a) { return [a] }
        if c.multi {
            let parts = a.components(separatedBy: ", ")
            if parts.count > 1, parts.allSatisfy(labels.contains) { return Set(parts) }
        }
        return nil
    }

    private static func choices(_ reply: String) -> (multi: Bool, options: [String])? {
        for block in MarkdownBlocks.parse(reply).reversed() {
            if case .choices(let multi, let options) = block { return (multi, options) }
        }
        return nil
    }

    public enum Role: Sendable { case user, reply, other }

    public struct Answered: Equatable, Sendable {
        /// The picked options, by the reply that offered them.
        public var picks: [UUID: Set<String>] = [:]
        /// The user's messages that only answered a reply's choices.
        public var answers: Set<UUID> = []
    }

    /// Which of the user's messages answered the choices of the reply before them.
    public static func answered(_ items: [(id: UUID, role: Role, text: String)]) -> Answered {
        var out = Answered()
        var reply: (id: UUID, text: String)?
        for item in items {
            switch item.role {
            case .reply:
                reply = (item.id, item.text)
            case .user:
                if let r = reply, let p = picked(item.text, reply: r.text) {
                    out.picks[r.id] = p
                    out.answers.insert(item.id)
                }
                reply = nil
            case .other:
                continue
            }
        }
        return out
    }

    /// The reply without its choices blocks, for views that draw the choices themselves.
    public static func withoutChoices(_ markdown: String) -> String {
        var out: [String] = []
        var skipping = false
        for line in markdown.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if skipping {
                if t.hasPrefix("```") { skipping = false }
                continue
            }
            if t.hasPrefix("```"), t.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("choices") {
                skipping = true
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
