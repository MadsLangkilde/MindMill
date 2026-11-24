import Foundation

/// Whether a session's reply waits on the user. Only a reply that ends with options to click does: a reply that ends
/// with a bare question may be asking someone else, so the app asks the session once to put it as options.
public enum OpenQuestion {
    public static let tagPrefix = "open-question"

    public static func waitsOnUser(_ reply: String) -> Bool {
        MarkdownBlocks.trailingChoices(reply) != nil
    }

    /// The question a reply ends with when it gives no options; nil when it ends with options or isn't a question.
    public static func of(_ reply: String) -> String? {
        guard !waitsOnUser(reply) else { return nil }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix("?") else { return nil }
        let last = text.components(separatedBy: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? text
        let line = last.trimmingCharacters(in: .whitespaces)
        var start = line.startIndex
        var i = line.startIndex
        while i < line.index(before: line.endIndex) {
            let next = line.index(after: i)
            if ".!?".contains(line[i]), line[next] == " " { start = line.index(after: next) }
            i = next
        }
        return String(line[start...]).trimmingCharacters(in: .whitespaces)
    }

    /// Whether to ask the session about the question its last reply ended with: once per reply, and never about the
    /// answer to that request or to a message the user didn't see.
    public static func shouldAsk(reply: String, turnTag: String?, alreadyAsked: Bool) -> Bool {
        guard !alreadyAsked, of(reply) != nil else { return false }
        if let turnTag, turnTag.hasPrefix(tagPrefix) || turnTag == "connect" { return false }
        return true
    }

    public static func request(_ question: String) -> String {
        "[From the Mindmill app] Your reply ended with a question and no options: “\(question)”. If it is for the user, ask it again in one short message: a bold question, at most one line of context, then a `choices` block with the options, your recommendation first marked \"(Recommended)\". If it isn't for the user (it's for someone else, or rhetorical), reply in one line saying so, without a question."
    }

    public static let status = "That ended with a question but no options. Mindmill asked Claude to give you options to pick from."
}
