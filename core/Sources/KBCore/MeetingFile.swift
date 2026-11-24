import Foundation

/// The four meeting body sections the app reads and writes, in file order.
public enum MeetingSection: String, CaseIterable, Sendable {
    case prep = "Prep"
    /// Files and links the user added for the meeting, each with what Claude found in it.
    case materials = "Materials"
    /// Claude's questions the user hasn't picked for the meeting yet.
    case suggested = "Suggested questions"
    case questions = "Questions"
    case rawNotes = "Raw notes"
    case transcript = "Transcript"
    /// What the transcript adds to the notes, as `### topic` parts the user keeps or leaves out at review.
    case transcriptSummary = "Transcript summary"
    case summary = "Summary"

    var heading: String { "## \(rawValue)" }

    static func matching(_ line: String) -> MeetingSection? {
        guard line.hasPrefix("## ") else { return nil }
        let name = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { $0.rawValue.lowercased() == name }
    }
}

/// Reads and replaces meeting body sections. A section runs until the next of the four known headings,
/// so a summary may contain its own `##` headings. Everything outside the replaced section is kept.
public enum MeetingBody {
    struct Span {
        let section: MeetingSection
        let headingLine: Int
        /// First line after the section (the next known heading, or the line count).
        let end: Int
    }

    static func spans(_ lines: [String]) -> [Span] {
        var starts: [(MeetingSection, Int)] = []
        var inFence = false
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("```") { inFence.toggle() }
            if !inFence, let s = MeetingSection.matching(line), !starts.contains(where: { $0.0 == s }) {
                starts.append((s, i))
            }
        }
        return starts.enumerated().map { n, s in
            Span(section: s.0, headingLine: s.1, end: n + 1 < starts.count ? starts[n + 1].1 : lines.count)
        }
    }

    /// The section's content without its heading, trimmed of surrounding blank lines; `nil` when absent.
    public static func section(_ section: MeetingSection, in body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let span = spans(lines).first(where: { $0.section == section }) else { return nil }
        return lines[(span.headingLine + 1)..<span.end].joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// Replaces (or inserts, in file order) a section. `content` is written between a blank line after
    /// the heading and a blank line before the next section.
    public static func setting(_ section: MeetingSection, to content: String, in body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        let trimmed = content.trimmingCharacters(in: .newlines)
        var block = [section.heading, ""]
        if !trimmed.isEmpty { block += trimmed.components(separatedBy: "\n") + [""] }
        let all = spans(lines)
        if let span = all.first(where: { $0.section == section }) {
            let isLast = span.end == lines.count
            if isLast, block.last == "" { block.removeLast() }
            lines.replaceSubrange(span.headingLine..<span.end, with: isLast ? block + [""] : block)
            return lines.joined(separator: "\n")
        }
        let order = MeetingSection.allCases
        let mine = order.firstIndex(of: section)!
        if let next = all.first(where: { order.firstIndex(of: $0.section)! > mine }) {
            var insert = block
            if next.headingLine > 0, !lines[next.headingLine - 1].isEmpty { insert.insert("", at: 0) }
            lines.insert(contentsOf: insert, at: next.headingLine)
            return lines.joined(separator: "\n")
        }
        var text = body
        while text.hasSuffix("\n\n") { text.removeLast() }
        if text.isEmpty || text == "\n" {
            return "\n" + block.joined(separator: "\n") + (block.last == "" ? "" : "\n")
        }
        if !text.hasSuffix("\n") { text += "\n" }
        return text + "\n" + block.joined(separator: "\n") + (block.last == "" ? "" : "\n")
    }
}

extension MeetingBody {
    /// Drops a section and its heading; the body is unchanged when it has none.
    public static func removing(_ section: MeetingSection, in body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        guard let span = spans(lines).first(where: { $0.section == section }) else { return body }
        lines.removeSubrange(span.headingLine..<span.end)
        while lines.count > 1, lines.last == "", lines[lines.count - 2] == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// One line of `## Materials`: `- [title](<link>) — what Claude found in it`. A file's link is relative to the
/// meeting file (a copy kept next to it); a web page's is its URL.
public struct MeetingMaterial: Equatable, Sendable, Identifiable {
    public var title: String
    public var link: String
    public var note: String

    public var id: String { link }
    public var isWeb: Bool { link.hasPrefix("http://") || link.hasPrefix("https://") }

    public init(title: String, link: String, note: String = "") {
        self.title = title
        self.link = link
        self.note = note
    }

    public static func parse(_ section: String) -> [MeetingMaterial] {
        section.components(separatedBy: "\n").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ["), let close = t.range(of: "]("), let end = t.range(of: ")", range: close.upperBound..<t.endIndex) else {
                return nil
            }
            let title = String(t[t.index(t.startIndex, offsetBy: 3)..<close.lowerBound])
            var link = String(t[close.upperBound..<end.lowerBound])
            if link.hasPrefix("<"), link.hasSuffix(">") { link = String(link.dropFirst().dropLast()) }
            var note = String(t[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            for dash in ["— ", "- ", "– "] where note.hasPrefix(dash) { note = String(note.dropFirst(dash.count)) }
            return MeetingMaterial(title: title, link: link, note: note)
        }
    }

    public static func render(_ list: [MeetingMaterial]) -> String {
        list.map { m in
            let title = m.title.replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "\n", with: " ")
            let note = m.note.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return "- [\(title)](<\(m.link)>)" + (note.isEmpty ? "" : " — \(note)")
        }.joined(separator: "\n")
    }
}

/// The `## Questions` task list. Lines that are not tasks (group headings, notes) are kept in place.
public struct QuestionList: Equatable, Sendable {
    public enum Line: Equatable, Sendable {
        case task(done: Bool, text: String)
        case other(String)
    }

    public var lines: [Line]

    public init(lines: [Line] = []) { self.lines = lines }

    public init(markdown: String) {
        lines = markdown.components(separatedBy: "\n").map { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            for (mark, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true), ("* [ ] ", false), ("* [x] ", true)] where t.hasPrefix(mark) {
                return .task(done: done, text: String(t.dropFirst(mark.count)))
            }
            if t == "- [ ]" || t == "- [x]" { return .task(done: t == "- [x]", text: "") }
            return .other(raw)
        }
        while case .other(let s)? = lines.last, s.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while case .other(let s)? = lines.first, s.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
    }

    public var markdown: String {
        lines.map {
            switch $0 {
            case .task(let done, let text): return "- [\(done ? "x" : " ")] \(text)"
            case .other(let s): return s
            }
        }.joined(separator: "\n")
    }

    public struct Question: Equatable, Sendable, Identifiable {
        /// Index into `lines`.
        public let id: Int
        public let text: String
        public let done: Bool
        /// The nearest `###`/`####` heading or bold line above it, for grouping.
        public let group: String?
        /// From the indented `  - Answer: …` line right under the question; empty when there is none.
        public var answer = ""
    }

    static let answerPrefix = "- Answer:"

    /// The answer on line `index`, when that line is an indented `- Answer:` line.
    static func answer(in line: Line) -> String? {
        guard case .other(let s) = line, s.first == " " || s.first == "\t" else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.lowercased().hasPrefix(answerPrefix.lowercased()) else { return nil }
        return String(t.dropFirst(answerPrefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private func answerLine(after index: Int) -> Int? {
        let next = index + 1
        guard lines.indices.contains(next), Self.answer(in: lines[next]) != nil else { return nil }
        return next
    }

    public var questions: [Question] {
        var group: String?
        var out: [Question] = []
        for (i, line) in lines.enumerated() {
            switch line {
            case .task(let done, let text):
                var q = Question(id: i, text: text, done: done, group: group)
                if let a = answerLine(after: i).flatMap({ Self.answer(in: lines[$0]) }) { q.answer = a }
                out.append(q)
            case .other:
                if let g = Self.groupName(line) { group = g }
            }
        }
        return out
    }

    public mutating func set(_ index: Int, done: Bool) {
        guard lines.indices.contains(index), case .task(_, let text) = lines[index] else { return }
        lines[index] = .task(done: done, text: text)
    }

    public mutating func set(_ index: Int, text: String) {
        guard lines.indices.contains(index), case .task(let done, _) = lines[index] else { return }
        lines[index] = .task(done: done, text: text)
    }

    /// Sets the answer written under the question; an empty answer removes the line.
    public mutating func set(_ index: Int, answer: String) {
        guard lines.indices.contains(index), case .task = lines[index] else { return }
        let a = answer.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let line = Line.other("  \(Self.answerPrefix) \(a)")
        if let existing = answerLine(after: index) {
            if a.isEmpty { lines.remove(at: existing) } else { lines[existing] = line }
        } else if !a.isEmpty {
            lines.insert(line, at: index + 1)
        }
    }

    /// Removes the question and its answer.
    public mutating func remove(_ index: Int) {
        guard lines.indices.contains(index) else { return }
        if let a = answerLine(after: index) { lines.remove(at: a) }
        lines.remove(at: index)
    }

    public mutating func append(_ text: String) {
        lines.append(.task(done: false, text: text))
    }

    /// The group a `###`/`####` heading or a bold line opens; `nil` for any other line.
    static func groupName(_ line: Line) -> String? {
        guard case .other(let s) = line, answer(in: line) == nil else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { return t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
        if t.hasPrefix("**"), t.hasSuffix("**"), t.count > 4 { return String(t.dropFirst(2).dropLast(2)) }
        return nil
    }

    private static func isBlank(_ line: Line) -> Bool {
        if case .other(let s) = line { return s.trimmingCharacters(in: .whitespaces).isEmpty }
        return false
    }

    /// Removes the question with its answer and returns those lines.
    public mutating func take(_ index: Int) -> [Line] {
        guard lines.indices.contains(index), case .task = lines[index] else { return [] }
        var out = [lines[index]]
        if let a = answerLine(after: index) {
            out.append(lines[a])
            lines.remove(at: a)
        }
        lines.remove(at: index)
        return out
    }

    /// Adds lines at the end of `group`, under a new `### group` at the end when there is none; without a
    /// group, before the first heading.
    public mutating func insert(_ new: [Line], group: String?) {
        guard !new.isEmpty else { return }
        guard let group else {
            var end = lines.firstIndex { Self.groupName($0) != nil } ?? lines.count
            let beforeHeading = end < lines.count
            while end > 0, Self.isBlank(lines[end - 1]) { end -= 1 }
            let gap = beforeHeading && !Self.isBlank(lines[end])
            lines.insert(contentsOf: gap ? new + [.other("")] : new, at: end)
            return
        }
        if let h = lines.firstIndex(where: { Self.groupName($0) == group }) {
            var end = lines[(h + 1)...].firstIndex { Self.groupName($0) != nil } ?? lines.count
            while end > h + 1, Self.isBlank(lines[end - 1]) { end -= 1 }
            lines.insert(contentsOf: new, at: end)
        } else {
            if !lines.isEmpty, !Self.isBlank(lines[lines.count - 1]) { lines.append(.other("")) }
            lines.append(.other("### \(group)"))
            lines.append(contentsOf: new)
        }
    }

    /// Moves a question, with its answer, to the same group in `other`.
    public mutating func move(_ index: Int, to other: inout QuestionList) {
        let group = questions.first { $0.id == index }?.group
        let taken = take(index)
        other.insert(taken, group: group)
        dropEmptyGroups()
    }

    /// Removes headings left with nothing under them, and doubled blank lines.
    public mutating func dropEmptyGroups() {
        var i = 0
        while i < lines.count {
            if Self.groupName(lines[i]) != nil {
                let next = lines[(i + 1)...].firstIndex { !Self.isBlank($0) }
                if next == nil || Self.groupName(lines[next!]) != nil {
                    lines.removeSubrange(i..<(next ?? lines.count))
                    continue
                }
            }
            i += 1
        }
        var out: [Line] = []
        for l in lines where !(Self.isBlank(l) && (out.isEmpty || out.last.map(Self.isBlank) == true)) { out.append(l) }
        while let last = out.last, Self.isBlank(last) { out.removeLast() }
        lines = out
    }

    public static let suggestedGroup = "Suggested"

    /// A group added from the suggestions when the meeting started unprepared: `Suggested` or `Suggested · <group>`.
    public static func isSuggested(group: String?) -> Bool {
        guard let group else { return false }
        return group == suggestedGroup || group.hasPrefix(suggestedGroup + " · ")
    }

    /// The group without the `Suggested · ` prefix; `nil` for plain `Suggested`.
    public static func displayGroup(_ group: String?) -> String? {
        guard let group, isSuggested(group: group) else { return group }
        return group == suggestedGroup ? nil : String(group.dropFirst((suggestedGroup + " · ").count))
    }

    /// Adds all of `suggested` at the end, each group renamed `Suggested · <group>` and ungrouped ones under
    /// `Suggested`, so the meeting shows them apart from the prepared questions.
    public mutating func addSuggestions(_ suggested: QuestionList) {
        var added: [Line] = []
        var grouped = false
        for line in suggested.lines {
            if let g = Self.groupName(line) {
                if !added.isEmpty, !Self.isBlank(added[added.count - 1]) { added.append(.other("")) }
                added.append(.other("### \(Self.suggestedGroup) · \(g)"))
                grouped = true
            } else {
                if !grouped, !Self.isBlank(line) {
                    added.append(.other("### \(Self.suggestedGroup)"))
                    grouped = true
                }
                added.append(line)
            }
        }
        guard added.contains(where: { if case .task = $0 { return true } else { return false } }) else { return }
        if !lines.isEmpty, !Self.isBlank(lines[lines.count - 1]) { lines.append(.other("")) }
        lines += added
        dropEmptyGroups()
    }

    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        // Drop a trailing citation such as "(re: product/decisions/…)".
        if let r = t.range(of: "(re:", options: .backwards) { t = String(t[..<r.lowerBound]) }
        let kept = t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(kept)).split(separator: " ").joined(separator: " ")
    }

    /// Ticks the question matching `answered` (exact after normalising, else one containing the other).
    /// Returns whether a question was found.
    /// An `answer` is written under it unless it has one already.
    @discardableResult
    public mutating func markAnswered(_ answered: String, answer: String? = nil) -> Bool {
        let target = Self.normalize(answered)
        guard !target.isEmpty else { return false }
        let qs = questions
        let match = qs.first { Self.normalize($0.text) == target }
            ?? qs.first {
                let q = Self.normalize($0.text)
                return min(q.count, target.count) >= 12 && (q.contains(target) || target.contains(q))
            }
        guard let q = match else { return false }
        set(q.id, done: true)
        if let answer, !answer.isEmpty, q.answer.isEmpty { set(q.id, answer: answer) }
        return true
    }
}

public enum MeetingFile {
    /// Creates `meetings/<date>-<slug>.md` with `status: prepared` and an empty `## Questions`.
    @discardableResult
    public static func create(project: String, title: String, date: String, start: String, attendees: [String],
                              root: URL) throws -> EntryDocument {
        var doc = try KBStore.newDocument(project: project, section: .meetings, title: title, root: root, date: date)
        var fm = Frontmatter()
        fm.set("title", .string(title.trimmingCharacters(in: .whitespacesAndNewlines)))
        fm.set("date", .string(date))
        fm.set("status", .string(MeetingStatus.prepared.rawValue))
        if !start.isEmpty { fm.set("start", .string(start)) }
        fm.set("attendees", .list(attendees))
        fm.set("summary", .string(""))
        fm.set("tags", .list([]))
        doc.frontmatter = fm
        doc.body = "\n## Questions\n"
        try KBStore.save(&doc, root: root)
        return doc
    }

    /// Loads the meeting, applies `change` and writes it back if anything changed.
    @discardableResult
    public static func update(_ id: EntryID, root: URL, _ change: (inout EntryDocument) -> Void) throws -> EntryDocument {
        var doc = try KBStore.load(id, root: root)
        change(&doc)
        if doc.isDirty { try KBStore.save(&doc, root: root) }
        return doc
    }

    public static func status(of doc: EntryDocument) -> MeetingStatus {
        MeetingStatus(rawValue: (doc.frontmatter.string("status") ?? "").lowercased()) ?? .filed
    }
}

extension EntryDocument {
    public func meetingSection(_ section: MeetingSection) -> String? {
        MeetingBody.section(section, in: body)
    }

    public mutating func setMeetingSection(_ section: MeetingSection, _ content: String) {
        let updated = MeetingBody.setting(section, to: content, in: body)
        if updated != body { body = updated }
    }
}

/// `## Transcript` lines: `- HH:MM [lang] **Speaker:** text`, the language (`da`, `en`) when it was recognised.
public enum MeetingTranscript {
    public struct Line: Equatable, Sendable {
        public let time: String
        public let speaker: String
        public let text: String
        public let language: String
        public init(time: String, speaker: String, text: String, language: String = "") {
            self.time = time
            self.speaker = speaker
            self.text = text
            self.language = language
        }
        public var markdown: String { "- \(time) \(language.isEmpty ? "" : "[\(language)] ")**\(speaker):** \(text)" }
    }

    public static func parse(_ md: String) -> [Line] {
        md.components(separatedBy: "\n").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") else { return nil }
            let rest = String(t.dropFirst(2))
            guard let space = rest.firstIndex(of: " ") else { return Line(time: "", speaker: "", text: rest) }
            let time = String(rest[..<space])
            var text = String(rest[rest.index(after: space)...])
            var language = ""
            if text.hasPrefix("["), let close = text.firstIndex(of: "]"), text.distance(from: text.startIndex, to: close) <= 6 {
                language = String(text[text.index(after: text.startIndex)..<close])
                text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            var speaker = ""
            if text.hasPrefix("**"), let end = text.range(of: ":**") {
                speaker = String(text[text.index(text.startIndex, offsetBy: 2)..<end.lowerBound])
                text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            return Line(time: time, speaker: speaker, text: text, language: language)
        }
    }
}

/// `## Transcript summary`: one part per `### heading`; text before the first heading is a part without a title.
public enum TranscriptSummary {
    public struct Part: Equatable, Sendable, Identifiable {
        public let id: Int
        public let title: String
        public let body: String
        public var markdown: String { title.isEmpty ? body : "### \(title)\n\n\(body)" }
    }

    public static func parts(_ md: String) -> [Part] {
        var out: [(String, [String])] = []
        var inFence = false
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inFence.toggle() }
            if !inFence, line.hasPrefix("### ") {
                out.append((String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces), []))
            } else if out.isEmpty {
                out.append(("", [line]))
            } else {
                out[out.count - 1].1.append(line)
            }
        }
        return out.enumerated().compactMap { i, p in
            let body = p.1.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !(p.0.isEmpty && body.isEmpty) else { return nil }
            return Part(id: i, title: p.0, body: body)
        }
    }

    /// The summary written from the notes, followed by the transcript parts the user kept.
    public static func merged(summary: String, keeping parts: [Part]) -> String {
        let base = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parts.isEmpty else { return base }
        let added = "## From the conversation\n\n" + parts.map(\.markdown).joined(separator: "\n\n")
        return base.isEmpty ? added : base + "\n\n" + added
    }
}
