import Foundation

public enum KBSection: String, CaseIterable, Hashable, Sendable, Identifiable {
    case overview, decisions, meetings, facts, architecture, followups, backlog, discussions, ideas, research, references, notes, inbox

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .decisions: return "Decisions"
        case .meetings: return "Meetings"
        case .facts: return "Facts"
        case .architecture: return "Architecture"
        case .followups: return "Follow-ups"
        case .backlog: return "Backlog"
        case .discussions: return "Discussions"
        case .ideas: return "Ideas"
        case .research: return "Research"
        case .references: return "References"
        case .notes: return "Notes"
        case .inbox: return "Inbox"
        }
    }

    public var singularTitle: String {
        switch self {
        case .overview: return "Overview"
        case .decisions: return "Decision"
        case .meetings: return "Meeting"
        case .facts: return "Fact"
        case .architecture: return "Architecture Note"
        case .followups: return "Follow-up"
        case .backlog: return "Backlog Item"
        case .discussions: return "Discussion"
        case .ideas: return "Idea"
        case .research: return "Research"
        case .references: return "Reference"
        case .notes: return "Note"
        case .inbox: return "Inbox Entry"
        }
    }

    /// Named `YYYY-MM-DD-slug` and sorted newest first. Inbox files use `YYYYMMDD-HHMMSS-slug`.
    public var isDated: Bool { self == .decisions || self == .meetings || self == .followups || self == .backlog || self == .discussions || self == .ideas || self == .research || self == .references || self == .notes }

    public static let folders: [KBSection] = [.decisions, .meetings, .facts, .architecture, .followups, .backlog, .discussions, .ideas, .research, .references, .notes, .inbox]

    /// Sections an inbox entry can be approved into.
    public static let inboxTargets: [KBSection] = [.decisions, .facts, .architecture, .followups, .backlog, .ideas, .references, .notes]
}

/// `<project-id>/<section>/<file stem>`, or `<project-id>/overview` for a project's overview.md.
public struct EntryID: Hashable, Comparable, Sendable, CustomStringConvertible, Identifiable {
    public let project: String
    public let section: KBSection
    public let stem: String

    public init(project: String, section: KBSection, stem: String) {
        self.project = project
        self.section = section
        self.stem = section == .overview ? "overview" : stem
    }

    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".md") { s = String(s.dropLast(3)) }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") && $0 != "." && $0 != ".." }) else { return nil }
        if parts.count == 2, parts[1] == "overview" {
            self.init(project: parts[0], section: .overview, stem: "overview")
        } else if parts.count == 3, let section = KBSection(rawValue: parts[1]), section != .overview {
            self.init(project: parts[0], section: section, stem: parts[2])
        } else {
            return nil
        }
    }

    /// Derives the id from an entry's file: in `<root>/projects/<scope>/`, or in the split layout a scope's
    /// private folder or its repo's `knowledgebase/`.
    public init?(fileURL: URL, root: URL) {
        let layout = KBLayout.of(root: root)
        if layout.isSplit {
            guard let id = layout.entryID(fileURL: fileURL) else { return nil }
            self = id
            return
        }
        guard let rel = EntryID.relativeComponents(fileURL, root: root), rel.first == "projects", rel.count > 1,
              let id = EntryID.from(scope: rel[1], relative: Array(rel.dropFirst(2))) else { return nil }
        self = id
    }

    /// `relative` is the path inside a scope folder: `overview.md` or `<section>/<stem>.md`.
    static func from(scope: String, relative rel: [String]) -> EntryID? {
        guard let last = rel.last, last.hasSuffix(".md") else { return nil }
        let stem = String(last.dropLast(3))
        if rel.count == 1, stem == "overview" {
            return EntryID(project: scope, section: .overview, stem: "overview")
        } else if rel.count == 2, let section = KBSection(rawValue: rel[0]), section != .overview, !stem.isEmpty, !stem.hasPrefix(".") {
            return EntryID(project: scope, section: section, stem: stem)
        }
        return nil
    }

    public var rawValue: String {
        section == .overview ? "\(project)/overview" : "\(project)/\(section.rawValue)/\(stem)"
    }

    public var description: String { rawValue }
    public var id: String { rawValue }

    /// The entry's file, or where a new one goes (see `KBLayout`).
    public func fileURL(root: URL) -> URL {
        KBLayout.of(root: root).fileURL(self)
    }

    /// The `YYYY-MM-DD` prefix of a dated file name, if any.
    public var datePrefix: String? {
        guard stem.count >= 10 else { return nil }
        let p = String(stem.prefix(10))
        return KBDate.isISODate(p) ? p : nil
    }

    public static func < (a: EntryID, b: EntryID) -> Bool { a.rawValue < b.rawValue }

    static func relativeComponents(_ url: URL, root: URL) -> [String]? {
        func comps(_ u: URL, resolve: Bool) -> [String] {
            let s = u.standardizedFileURL
            return (resolve ? s.resolvingSymlinksInPath() : s).pathComponents.filter { $0 != "/" }
        }
        for resolve in [false, true] {
            let r = comps(root, resolve: resolve)
            var f = comps(url, resolve: resolve)
            if resolve, !FileManager.default.fileExists(atPath: url.path) {
                f = comps(url.deletingLastPathComponent(), resolve: true) + [url.lastPathComponent]
            }
            if f.count > r.count, Array(f.prefix(r.count)) == r { return Array(f.dropFirst(r.count)) }
        }
        return nil
    }
}

public enum Slug {
    public static func make(_ title: String, maxLength: Int = 60) -> String {
        var t = title.lowercased()
        for (a, b) in [("æ", "ae"), ("ø", "oe"), ("å", "aa"), ("ß", "ss"), ("&", " and ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        var pendingDash = false
        for scalar in t.unicodeScalars {
            let isAlnum = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
            if isAlnum {
                if pendingDash && !out.isEmpty { out.append("-") }
                out.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        if out.count > maxLength {
            var cut = String(out.prefix(maxLength))
            if let lastDash = cut.lastIndex(of: "-"), cut.distance(from: cut.startIndex, to: lastDash) > maxLength / 2 {
                cut = String(cut[..<lastDash])
            }
            out = cut.hasSuffix("-") ? String(cut.dropLast()) : cut
        }
        return out.isEmpty ? "untitled" : out
    }
}

public enum KBDate {
    public static func isISODate(_ s: String) -> Bool {
        let c = Array(s)
        guard c.count == 10, c[4] == "-", c[7] == "-" else { return false }
        return c.enumerated().allSatisfy { i, ch in i == 4 || i == 7 || ch.isASCII && ch.isNumber }
    }

    public static func today(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func parse(_ s: String) -> Date? {
        guard isISODate(s) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}
