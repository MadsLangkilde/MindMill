import Foundation

/// One reply from the Live session to a note.
public struct LiveReply: Equatable, Sendable {
    public struct Flag: Equatable, Sendable, Hashable {
        public enum Kind: String, Sendable {
            /// `⚠`: conflicts with a decision or the code.
            case warning
            /// `ℹ`: already decided, or open since an earlier meeting.
            case info
            /// Anything else Claude said that is not `OK`.
            case note
        }

        public let kind: Kind
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public var flags: [Flag] = []
    /// Question texts from `ANSWERED:` lines.
    public var answered: [String] = []
    /// The answer after ` => ` on an `ANSWERED:` line, by question text.
    public var answers: [String: String] = [:]

    public var isOK: Bool { flags.isEmpty }

    public init(flags: [Flag] = [], answered: [String] = []) {
        self.flags = flags
        self.answered = answered
    }

    public static func parse(_ text: String) -> LiveReply {
        var reply = LiveReply()
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Claude sometimes bullets or bolds its lines.
            for p in ["- ", "* ", "• "] where line.hasPrefix(p) { line = String(line.dropFirst(p.count)) }
            line = line.replacingOccurrences(of: "**", with: "")
            guard !line.isEmpty else { continue }
            if let r = line.range(of: "ANSWERED:", options: [.anchored, .caseInsensitive]) {
                var q = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                var answer = ""
                if let arrow = q.range(of: " => ") {
                    answer = String(q[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
                    q = String(q[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
                if q.count >= 2, (q.hasPrefix("\"") && q.hasSuffix("\"")) || (q.hasPrefix("“") && q.hasSuffix("”")) {
                    q = String(q.dropFirst().dropLast())
                }
                if !q.isEmpty {
                    reply.answered.append(q)
                    if !answer.isEmpty { reply.answers[q] = answer }
                }
                continue
            }
            let stripped = stripOK(line)
            if stripped.isEmpty { continue }
            if let rest = dropMarker(stripped, ["⚠️", "⚠"]) {
                reply.flags.append(Flag(kind: .warning, text: rest))
            } else if let rest = dropMarker(stripped, ["ℹ️", "ℹ"]) {
                reply.flags.append(Flag(kind: .info, text: rest))
            } else {
                reply.flags.append(Flag(kind: .note, text: stripped))
            }
        }
        return reply
    }

    /// `OK`, `OK.` and `Noted.` say nothing; a leading `OK` before a flag is dropped.
    static func stripOK(_ line: String) -> String {
        let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: ".!").union(.whitespaces)).lowercased()
        if ["ok", "noted", "okay"].contains(bare) { return "" }
        return line
    }

    static func dropMarker(_ line: String, _ markers: [String]) -> String? {
        for m in markers where line.hasPrefix(m) {
            return String(line.dropFirst(m.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The `n` from a Review reply's `PROPOSED <n>` line.
    public static func proposedCount(_ text: String) -> Int? {
        for raw in text.components(separatedBy: .newlines).reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            guard let r = line.range(of: "PROPOSED", options: .caseInsensitive) else { continue }
            let rest = line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
            if let n = Int(rest.prefix(while: { $0.isNumber })) { return n }
        }
        return nil
    }
}

/// A paragraph of live notes sent to Claude.
public struct LiveNote: Equatable, Sendable, Identifiable {
    public let id: Int
    /// What was sent.
    public let text: String
    /// The whole paragraph as it currently reads in the editor, used to place flags next to it.
    public var anchor: String
}

/// Decides which paragraphs of the notes to send. A paragraph is complete when a blank line follows it,
/// or, for the last one, after a typing pause. Each paragraph is sent once; text appended to a paragraph
/// already sent is sent as its own note, and small edits to a sent paragraph are not resent.
public struct LiveNoteTracker: Equatable, Sendable {
    public private(set) var notes: [LiveNote] = []
    private var nextID: Int

    public init(startID: Int = 1) { nextID = startID }

    public static func paragraphs(_ text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(current.joined(separator: "\n"))
                current = []
            } else {
                current.append(line)
            }
        }
        out.append(current.joined(separator: "\n"))
        return out
    }

    /// Returns the notes to send now, in order.
    public mutating func update(text: String, paused: Bool) -> [LiveNote] {
        let parts = Self.paragraphs(text)
        let present = Set(parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var complete = Array(parts.dropLast())
        if paused, let last = parts.last { complete.append(last) }
        var toSend: [LiveNote] = []
        for raw in complete {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            if notes.contains(where: { $0.anchor == p }) { continue }
            // A sent paragraph that still reads the same elsewhere was not the one edited.
            if let i = notes.lastIndex(where: { p.hasPrefix($0.anchor) && !present.contains($0.anchor) }) {
                let delta = String(p.dropFirst(notes[i].anchor.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let old = notes[i].anchor
                for j in notes.indices where notes[j].anchor == old { notes[j].anchor = p }
                // Only a word or more of new text is worth a message.
                if delta.count >= 2 {
                    let note = LiveNote(id: nextID, text: delta, anchor: p)
                    nextID += 1
                    notes.append(note)
                    toSend.append(note)
                }
                continue
            }
            if let i = notes.lastIndex(where: { !present.contains($0.anchor) && Self.isEdit(of: $0.anchor, p) }) {
                let old = notes[i].anchor
                for j in notes.indices where notes[j].anchor == old { notes[j].anchor = p }
                continue
            }
            let note = LiveNote(id: nextID, text: p, anchor: p)
            nextID += 1
            notes.append(note)
            toSend.append(note)
        }
        return toSend
    }

    /// Restores notes already sent in an earlier window, so reopening does not resend them.
    public mutating func markSent(_ text: String) {
        for raw in Self.paragraphs(text) {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty, !notes.contains(where: { $0.anchor == p }) else { continue }
            notes.append(LiveNote(id: nextID, text: p, anchor: p))
            nextID += 1
        }
    }

    /// A shortened paragraph, or one sharing most of its beginning with `old`, is an edit, not a new note.
    static func isEdit(of old: String, _ new: String) -> Bool {
        if old.hasPrefix(new) { return true }
        let common = zip(old, new).prefix { $0 == $1 }.count
        let shorter = min(old.count, new.count)
        return shorter >= 10 && Double(common) >= 0.6 * Double(shorter)
    }
}
