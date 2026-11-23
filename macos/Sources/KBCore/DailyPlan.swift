import Foundation

/// `daily/<YYYY-MM-DD>.md`: the morning routine's plan, across projects.
public struct DailyPlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        /// Line number in the file, unique per plan.
        public var id: Int { line }
        public let line: Int
        public var done: Bool?
        /// Marked `[-]`: set aside as not relevant today.
        public var notRelevant: Bool = false
        public let project: String?
        public let text: String
        /// The trailing `(…)`: an entry id or a tracker reference.
        public let ref: String?
        /// The text after the checkbox, exactly as in the file. Used to find the line again.
        public let lineText: String
    }

    public struct Meeting: Equatable, Sendable, Identifiable {
        public var id: Int { line }
        public let line: Int
        public let time: String
        public let project: String?
        public let title: String
        public let meetingID: String?
        public let status: String?
    }

    public var title: String
    public var date: String
    public var today: [Item] = []
    public var meetings: [Meeting] = []
    public var toDecide: [Item] = []
    /// At most one small step toward a personal goal, from `## Side goal`.
    public var sideGoal: [Item] = []
    public var proposed: [String] = []
    /// Sections the parser did not recognise, as raw Markdown.
    public var other: String = ""

    public static func url(date: String, root: URL) -> URL {
        KBLayout.home(root: root).appendingPathComponent("daily").appendingPathComponent("\(date).md")
    }

    public static func load(date: String, root: URL) -> DailyPlan? {
        guard let text = try? String(contentsOf: url(date: date, root: root), encoding: .utf8) else { return nil }
        return parse(text, date: date)
    }

    public static func parse(_ raw: String, date fallbackDate: String = "") -> DailyPlan {
        let parsed = FrontmatterCodec.parse(raw)
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var plan = DailyPlan(title: parsed.frontmatter.string("title") ?? fallbackDate,
                             date: parsed.frontmatter.string("date") ?? fallbackDate)
        var section = ""
        var otherLines: [String] = []
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            if line.hasPrefix("## ") {
                section = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                if !["today", "meetings", "to decide", "proposed", "side goal"].contains(section) { otherLines.append(line) }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else {
                if !["today", "meetings", "to decide", "proposed", "side goal", ""].contains(section) { otherLines.append(line) }
                continue
            }
            let content = String(trimmed.dropFirst(2))
            switch section {
            case "today": plan.today.append(item(content, line: n))
            case "to decide": plan.toDecide.append(item(content, line: n))
            case "side goal": plan.sideGoal.append(item(content, line: n))
            case "meetings": plan.meetings.append(meeting(content, line: n))
            case "proposed": plan.proposed.append(content)
            case "": break
            default: otherLines.append(line)
            }
        }
        plan.other = otherLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return plan
    }

    static func item(_ content: String, line: Int) -> Item {
        var rest = content
        var done: Bool?
        var notRelevant = false
        if rest.hasPrefix("[-] ") {
            notRelevant = true
            rest = String(rest.dropFirst(4))
        } else if let (d, after) = checkbox(rest) {
            done = d
            rest = after
        }
        let lineText = rest
        let (project, afterProject) = projectTag(rest)
        var body = afterProject
        var ref: String?
        if body.hasSuffix(")"), let open = matchingOpenParen(body) {
            let inner = String(body[body.index(after: open)..<body.index(before: body.endIndex)]).trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, !inner.contains(" ") {
                ref = inner
                body = String(body[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return Item(line: line, done: done, notRelevant: notRelevant, project: project, text: body, ref: ref, lineText: lineText)
    }

    static func meeting(_ content: String, line: Int) -> Meeting {
        var rest = content
        var time = ""
        if let space = rest.firstIndex(of: " "), rest[..<space].contains(":") {
            time = String(rest[..<space])
            rest = String(rest[rest.index(after: space)...])
        }
        let (project, afterProject) = projectTag(rest)
        rest = afterProject
        var status: String?
        if rest.hasSuffix(")"), let open = matchingOpenParen(rest) {
            status = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]).trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
        }
        var title = rest
        var id: String?
        for arrow in ["→", "->"] {
            if let r = rest.range(of: arrow, options: .backwards) {
                title = String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let t = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                id = t.isEmpty ? nil : t
                break
            }
        }
        return Meeting(line: line, time: time, project: project, title: title, meetingID: id, status: status)
    }

    static func checkbox(_ s: String) -> (Bool, String)? {
        for (mark, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where s.hasPrefix(mark) {
            return (done, String(s.dropFirst(mark.count)))
        }
        return nil
    }

    static func projectTag(_ s: String) -> (String?, String) {
        guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return (nil, s) }
        let tag = String(s[s.index(after: s.startIndex)..<close])
        guard !tag.isEmpty, !tag.contains(" ") else { return (nil, s) }
        return (tag, String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces))
    }

    static func matchingOpenParen(_ s: String) -> String.Index? {
        var depth = 0
        var i = s.index(before: s.endIndex)
        while true {
            let c = s[i]
            if c == ")" { depth += 1 }
            if c == "(" {
                depth -= 1
                if depth == 0 { return i }
            }
            if i == s.startIndex { return nil }
            i = s.index(before: i)
        }
    }

    public enum Mark: Equatable, Sendable {
        case open, done, notRelevant, removed
    }

    /// Rewrites the plan line (in Today, To decide or Side goal) whose text after any checkbox is `lineText`:
    /// a checkbox for open or done, `[-]` for not relevant, or no line at all. Lines in To decide have no
    /// checkbox, and get none back when restored. Everything else is kept byte for byte; `nil` when no such line.
    public static func mark(_ raw: String, lineText: String, _ mark: Mark) -> String? {
        let hadCRLF = raw.contains("\r\n")
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var section = ""
        for (n, line) in lines.enumerated() {
            if line.hasPrefix("## ") {
                section = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard ["today", "to decide", "side goal"].contains(section) else { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let trimmed = line.dropFirst(indent.count)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { continue }
            let bullet = trimmed.prefix(2)
            let content = String(trimmed.dropFirst(2))
            let after: String
            if content.hasPrefix("[-] ") { after = String(content.dropFirst(4)) } else if let (_, a) = checkbox(content) { after = a } else { after = content }
            guard after == lineText else { continue }
            let box: String
            switch mark {
            case .removed:
                lines.remove(at: n)
                let out = lines.joined(separator: "\n")
                return hadCRLF ? out.replacingOccurrences(of: "\n", with: "\r\n") : out
            case .notRelevant: box = "[-] "
            case .done: box = "[x] "
            case .open: box = section == "to decide" ? "" : "[ ] "
            }
            lines[n] = indent + bullet + box + after
            let out = lines.joined(separator: "\n")
            return hadCRLF ? out.replacingOccurrences(of: "\n", with: "\r\n") : out
        }
        return nil
    }

    /// Sets the checkbox of the plan line whose text after the checkbox is `lineText`.
    public static func toggle(_ raw: String, lineText: String, done: Bool) -> String? {
        mark(raw, lineText: lineText, done ? .done : .open)
    }

    /// Changes a line in `daily/<date>.md` on disk.
    public static func setMark(date: String, lineText: String, _ m: Mark, root: URL) throws {
        let u = url(date: date, root: root)
        let raw = try String(contentsOf: u, encoding: .utf8)
        guard let updated = mark(raw, lineText: lineText, m) else {
            throw DailyPlanError.lineNotFound(lineText)
        }
        if updated != raw { try KBStore.write(updated, to: u) }
    }

    public static func setDone(date: String, lineText: String, done: Bool, root: URL) throws {
        try setMark(date: date, lineText: lineText, done ? .done : .open, root: root)
    }
}

public enum DailyPlanError: LocalizedError, Equatable {
    case lineNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .lineNotFound(let t): return "The plan no longer has the line “\(t)”."
        }
    }
}
