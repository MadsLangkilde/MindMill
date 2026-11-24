import Foundation

/// A personal long-term goal in `goals/<stem>.md` at the KB root: a side agenda across all projects.
public struct Goal: Identifiable, Equatable, Sendable {
    public enum Status: String, CaseIterable, Sendable {
        case active, paused, achieved, dropped
    }

    /// `goals/<stem>`, the id the CLI prints.
    public let id: String
    public let url: URL
    public var frontmatter: Frontmatter
    public var body: String

    public var stem: String { url.deletingPathExtension().lastPathComponent }
    public var title: String { frontmatter.string("title") ?? stem }
    public var horizon: String { frontmatter.string("horizon") ?? "" }
    public var status: Status { Status(rawValue: (frontmatter.string("status") ?? "").lowercased()) ?? .active }

    public func section(_ name: String) -> String { GoalBody.section(name, in: body) ?? "" }
    public var suggestions: QuestionList { QuestionList(markdown: section("Suggestions")) }
    public var openSuggestions: Int { suggestions.questions.filter { !$0.done }.count }
    /// Set by `kb goal propose` and `kb goal scanned`: the day the coach last looked for progress.
    public var progressScanned: String? { frontmatter.string("progress_scanned") }
    /// Dates of `- YYYY-MM-DD: …` lines in Progress, newest first as written.
    public var lastProgress: String? {
        section("Progress").components(separatedBy: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { line -> String? in
                guard line.hasPrefix("- ") else { return nil }
                let d = String(line.dropFirst(2).prefix(10))
                return KBDate.isISODate(d) ? d : nil
            }
            .first
    }

    public var serialized: String {
        FrontmatterCodec.serialize(frontmatter, body: body.hasPrefix("\n") ? body : "\n" + body, forceFrontmatter: true)
    }
}

/// `## Name` sections of a goal body. A section runs to the next `## ` heading.
public enum GoalBody {
    public static func section(_ name: String, in body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { isHeading($0, name) }) else { return nil }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
        return lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    public static func setting(_ name: String, to content: String, in body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        let trimmed = content.trimmingCharacters(in: .newlines)
        var block = ["## \(name)"]
        if !trimmed.isEmpty { block += trimmed.components(separatedBy: "\n") }
        block.append("")
        if let start = lines.firstIndex(where: { isHeading($0, name) }) {
            let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
            lines.replaceSubrange(start..<end, with: block)
            return lines.joined(separator: "\n")
        }
        var text = body
        while text.hasSuffix("\n\n") { text.removeLast() }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        return text + (text.isEmpty ? "" : "\n") + block.joined(separator: "\n")
    }

    /// Adds `- <date>: <text>` at the top of Progress.
    public static func addingProgress(_ text: String, date: String, to body: String) -> String {
        var log = ProgressLog(markdown: section("Progress", in: body) ?? "")
        log.add(date: date, text: text)
        return setting("Progress", to: log.markdown, in: body)
    }

    static func isHeading(_ line: String, _ name: String) -> Bool {
        line.hasPrefix("## ") && line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased()
    }
}

public enum Goals {
    public static let template = "\n## Why\n{why}\n\n## What it takes\n\n## Suggestions\n\n## Progress\n"

    public static func directory(root: URL) -> URL { KBLayout.home(root: root).appendingPathComponent("goals", isDirectory: true) }

    public static func load(root: URL) -> [Goal] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(root: root), includingPropertiesForKeys: nil)) ?? []
        let order: [Goal.Status] = [.active, .paused, .achieved, .dropped]
        return files.filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap(read)
            .sorted { (order.firstIndex(of: $0.status) ?? 9, $0.title) < (order.firstIndex(of: $1.status) ?? 9, $1.title) }
    }

    static func read(_ url: URL) -> Goal? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parsed = FrontmatterCodec.parse(text)
        return Goal(id: "goals/" + url.deletingPathExtension().lastPathComponent, url: url,
                    frontmatter: parsed.frontmatter, body: parsed.body)
    }

    @discardableResult
    public static func create(title: String, horizon: String, why: String, root: URL, today: String = KBDate.today()) throws -> Goal {
        let dir = directory(root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = Slug.make(title, maxLength: 50)
        var url = dir.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        var fm = Frontmatter()
        fm.set("title", .string(title.trimmingCharacters(in: .whitespacesAndNewlines)))
        fm.set("status", .string(Goal.Status.active.rawValue))
        fm.set("created", .string(today))
        if !horizon.trimmingCharacters(in: .whitespaces).isEmpty { fm.set("horizon", .string(horizon.trimmingCharacters(in: .whitespaces))) }
        let body = template.replacingOccurrences(of: "{why}", with: why.trimmingCharacters(in: .whitespacesAndNewlines))
        let g = Goal(id: "goals/" + url.deletingPathExtension().lastPathComponent, url: url, frontmatter: fm, body: body)
        try write(g)
        return g
    }

    @discardableResult
    public static func update(_ goal: Goal, _ change: (inout Goal) -> Void) throws -> Goal {
        var g = read(goal.url) ?? goal
        change(&g)
        try write(g)
        return g
    }

    public static func delete(_ goal: Goal) throws { try FileManager.default.removeItem(at: goal.url) }

    static func write(_ g: Goal) throws {
        let tmp = g.url.deletingLastPathComponent().appendingPathComponent(".\(g.url.lastPathComponent).tmp")
        try g.serialized.write(to: tmp, atomically: false, encoding: .utf8)
        if FileManager.default.fileExists(atPath: g.url.path) {
            _ = try FileManager.default.replaceItemAt(g.url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: g.url)
        }
    }
}

/// The `- YYYY-MM-DD: text` lines of a goal's Progress or Proposed progress, newest first. Other lines are kept
/// as they are.
public struct ProgressLog: Equatable, Sendable {
    public struct Item: Identifiable, Equatable, Sendable {
        /// Index into the section's lines.
        public let id: Int
        public var date: String
        public var text: String
    }

    public var lines: [String]

    public init(markdown: String) {
        lines = markdown.isEmpty ? [] : markdown.components(separatedBy: "\n")
    }

    public var markdown: String { lines.joined(separator: "\n").trimmingCharacters(in: .newlines) }

    public var items: [Item] {
        lines.enumerated().compactMap { i, raw in Self.parse(raw).map { Item(id: i, date: $0.date, text: $0.text) } }
    }

    static func parse(_ raw: String) -> (date: String, text: String)? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("- ") || t.hasPrefix("* ") else { return nil }
        let rest = String(t.dropFirst(2))
        let d = String(rest.prefix(10))
        if KBDate.isISODate(d) {
            var text = rest.dropFirst(10).drop { $0 == " " }
            if text.first == ":" { text = text.dropFirst() }
            return (d, text.trimmingCharacters(in: .whitespaces))
        }
        return ("", rest)
    }

    static func line(date: String, text: String) -> String {
        let t = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return date.isEmpty ? "- \(t)" : "- \(date): \(t)"
    }

    /// Adds a line in date order, newest first, after any lines of the same date.
    public mutating func add(date: String, text: String) {
        let at = items.first { !$0.date.isEmpty && $0.date < date }?.id ?? (items.last.map { $0.id + 1 } ?? lines.count)
        lines.insert(Self.line(date: date, text: text), at: min(at, lines.count))
    }

    public mutating func set(_ id: Int, date: String, text: String) {
        guard lines.indices.contains(id) else { return }
        lines.remove(at: id)
        add(date: date, text: text)
    }

    public mutating func remove(_ id: Int) {
        guard lines.indices.contains(id) else { return }
        lines.remove(at: id)
    }

    public func contains(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        return items.contains { $0.text.lowercased() == t }
    }
}

extension Goal {
    public var progress: ProgressLog { ProgressLog(markdown: section("Progress")) }
    /// What the app or the coach saw the user do that may count as progress, for the user to add or dismiss.
    public var proposedProgress: ProgressLog { ProgressLog(markdown: section("Proposed progress")) }
}

extension GoalBody {
    /// Moves a proposed line into Progress, with the text the user settled on.
    public static func accepting(_ id: Int, date: String, text: String, in body: String) -> String {
        var proposed = ProgressLog(markdown: section("Proposed progress", in: body) ?? "")
        proposed.remove(id)
        var log = ProgressLog(markdown: section("Progress", in: body) ?? "")
        log.add(date: date, text: text)
        var b = setting("Progress", to: log.markdown, in: body)
        b = proposed.items.isEmpty ? removing("Proposed progress", from: b) : setting("Proposed progress", to: proposed.markdown, in: b)
        return b
    }

    public static func removing(_ name: String, from body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { isHeading($0, name) }) else { return body }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
        lines.removeSubrange(start..<end)
        return lines.joined(separator: "\n")
    }
}
