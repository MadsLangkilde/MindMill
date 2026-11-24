import Foundation
import KBCore

/// What an "Ask Claude about this" question is about. Its context goes with the first question.
public enum AskSubject: Equatable, Sendable {
    case entry(EntryID, title: String)
    case reminder(Reminder)
    case text(String, title: String, project: String?)
    case goal(Goal)

    public var title: String {
        switch self {
        case .goal(let g): return g.title
        case .entry(_, let title): return title
        case .reminder(let r): return r.title
        case .text(_, let title, _): return title
        }
    }

    public var project: String? {
        switch self {
        case .entry(let id, _): return id.project
        case .reminder(let r): return r.project
        case .text(_, _, let p): return p
        case .goal: return nil
        }
    }

    public var context: String {
        switch self {
        case .entry(let id, let title):
            return "This question is about the KB entry `\(id.rawValue)` (“\(title)”). Read it first with `kb show \(id.rawValue)`, then whatever it links to."
        case .reminder(let r):
            var s = "This question is about the user's reminder `\(r.id)` (“\(r.title)”), due \(r.due), status \(r.status.rawValue)."
            if let from = r.from { s += " It came from an email from \(from)." }
            if let reason = r.reason { s += " Why it was suggested: \(reason)" }
            if !r.note.isEmpty { s += "\nNote:\n\(r.note)" }
            if r.isFromEmail { s += "\nFind the email with outlook_email_search if you need more than this." }
            return s
        case .text(let text, _, _):
            return "This question is about this item from the user's day plan: \(text)"
        case .goal(let g):
            return "This question is about the user's personal goal `\(g.id)` (“\(g.title)”). Read `\(g.id).md` in the KB root first. It is a side agenda; follow the kb:goals skill."
        }
    }
}
