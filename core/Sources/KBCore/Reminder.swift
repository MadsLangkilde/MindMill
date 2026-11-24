import Foundation

/// A personal reminder in `reminders/<stem>.md` at the KB root. It belongs to the user, not to a project;
/// `project` only links it to one.
public struct Reminder: Identifiable, Equatable, Sendable {
    public enum Status: String, CaseIterable, Sendable {
        /// `proposed` is Claude's suggestion (from email or the morning routine), waiting for the user.
        case open, proposed, done, dismissed
    }

    /// `reminders/<stem>`, the id the CLI prints.
    public let id: String
    public let url: URL
    public var frontmatter: Frontmatter
    public var note: String

    public var stem: String { url.deletingPathExtension().lastPathComponent }
    public var title: String { frontmatter.string("title") ?? stem }
    public var due: String { frontmatter.string("due") ?? "" }
    public var status: Status { Status(rawValue: (frontmatter.string("status") ?? "").lowercased()) ?? .open }
    public var project: String? { nonEmpty("project") }
    public var source: String? { nonEmpty("source") }
    public var from: String? { nonEmpty("from") }
    public var fromDomain: String? { nonEmpty("from_domain") }
    public var link: URL? { nonEmpty("link").flatMap(URL.init(string:)) }
    public var reason: String? { nonEmpty("reason") }
    public var isFromEmail: Bool { source?.hasPrefix("email:") ?? false }
    public var hasDue: Bool { !due.isEmpty }
    /// Reminders without a date sort after every dated one.
    var sortKey: String { due.isEmpty ? "~" : due }

    public func isOverdue(today: String = KBDate.today()) -> Bool { status == .open && !due.isEmpty && due < today }
    public func isDue(today: String = KBDate.today()) -> Bool { status == .open && !due.isEmpty && due <= today }

    private func nonEmpty(_ key: String) -> String? {
        let v = frontmatter.string(key)?.trimmingCharacters(in: .whitespaces) ?? ""
        return v.isEmpty ? nil : v
    }

    public var serialized: String {
        let body = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return FrontmatterCodec.serialize(frontmatter, body: body.isEmpty ? "" : "\n" + body + "\n", forceFrontmatter: true)
    }
}

public enum Reminders {
    public static func directory(root: URL) -> URL { KBLayout.home(root: root).appendingPathComponent("reminders", isDirectory: true) }

    public static func load(root: URL) -> [Reminder] {
        let dir = directory(root: root)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap(read)
            .sorted { ($0.sortKey, $0.title) < ($1.sortKey, $1.title) }
    }

    static func read(_ url: URL) -> Reminder? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parsed = FrontmatterCodec.parse(text)
        return Reminder(id: "reminders/" + url.deletingPathExtension().lastPathComponent, url: url,
                        frontmatter: parsed.frontmatter, note: parsed.body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    public static func create(title: String, due: String, note: String = "", project: String? = nil, link: String = "",
                              root: URL, today: String = KBDate.today()) throws -> Reminder {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = directory(root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = Slug.make(clean, maxLength: 50)
        var url = dir.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        var fm = Frontmatter()
        fm.set("title", .string(clean))
        if !due.isEmpty { fm.set("due", .string(due)) }
        fm.set("status", .string(Reminder.Status.open.rawValue))
        fm.set("created", .string(today))
        if let project, !project.isEmpty { fm.set("project", .string(project)) }
        if !link.trimmingCharacters(in: .whitespaces).isEmpty { fm.set("link", .string(link.trimmingCharacters(in: .whitespaces))) }
        let r = Reminder(id: "reminders/" + url.deletingPathExtension().lastPathComponent, url: url, frontmatter: fm, note: note)
        try write(r)
        return r
    }

    /// Re-reads the file, applies `change` and writes it back.
    @discardableResult
    public static func update(_ reminder: Reminder, _ change: (inout Reminder) -> Void) throws -> Reminder {
        var r = read(reminder.url) ?? reminder
        change(&r)
        try write(r)
        return r
    }

    public static func setStatus(_ reminder: Reminder, _ status: Reminder.Status, today: String = KBDate.today()) throws {
        try update(reminder) { r in
            r.frontmatter.set("status", .string(status.rawValue))
            r.frontmatter.set("done", status == .done ? .string(today) : nil)
        }
    }

    public static func setDue(_ reminder: Reminder, _ due: String) throws {
        try update(reminder) { $0.frontmatter.set("due", due.isEmpty ? nil : .string(due)) }
    }

    public static func delete(_ reminder: Reminder) throws {
        try FileManager.default.removeItem(at: reminder.url)
    }

    static func write(_ r: Reminder) throws {
        let tmp = r.url.deletingLastPathComponent().appendingPathComponent(".\(r.url.lastPathComponent).tmp")
        try r.serialized.write(to: tmp, atomically: false, encoding: .utf8)
        if FileManager.default.fileExists(atPath: r.url.path) {
            _ = try FileManager.default.replaceItemAt(r.url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: r.url)
        }
    }

    /// Today, tomorrow and a week from today, for quick due-date choices.
    public static func quickDates(from date: Date = Date()) -> (today: String, tomorrow: String, nextWeek: String) {
        let cal = Calendar(identifier: .gregorian)
        func plus(_ days: Int) -> String { KBDate.today(cal.date(byAdding: .day, value: days, to: date) ?? date) }
        return (plus(0), plus(1), plus(7))
    }
}
