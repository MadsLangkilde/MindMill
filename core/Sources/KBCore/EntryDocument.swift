import Foundation

/// An entry open for editing. `diskText` is what the file held when it was loaded or last saved;
/// `nil` means the entry has not been written yet.
public struct EntryDocument: Equatable, Sendable {
    public let id: EntryID
    public let url: URL
    public var frontmatter: Frontmatter
    public var body: String
    public var hasFrontmatter: Bool
    public var diskText: String?

    public init(id: EntryID, url: URL, text: String) {
        let parsed = FrontmatterCodec.parse(text)
        self.id = id
        self.url = url
        self.frontmatter = parsed.frontmatter
        self.body = parsed.body
        self.hasFrontmatter = parsed.hasFrontmatter
        self.diskText = text
    }

    public init(id: EntryID, url: URL, frontmatter: Frontmatter, body: String) {
        self.id = id
        self.url = url
        self.frontmatter = frontmatter
        self.body = body
        self.hasFrontmatter = true
        self.diskText = nil
    }

    public var serialized: String {
        FrontmatterCodec.serialize(frontmatter, body: body, forceFrontmatter: hasFrontmatter)
    }

    public var isNew: Bool { diskText == nil }
    public var isDirty: Bool { diskText.map { $0.replacingOccurrences(of: "\r\n", with: "\n") != serialized } ?? true }

    public var title: String { frontmatter.string("title").map(KBEntry.oneLine) ?? id.stem }
    /// Added by hand and not saved yet: kept on disk under the section's Drafts, out of what Claude loads.
    public var isDraft: Bool { frontmatter.string("draft") == "true" }
    public var status: DecisionStatus? {
        id.section == .decisions ? DecisionStatus(rawValue: (frontmatter.string("status") ?? "").lowercased()) ?? .active : nil
    }
}

public enum KBStoreError: LocalizedError, Equatable {
    case outsideProject(String)
    case alreadyExists(String)
    case emptyTitle

    public var errorDescription: String? {
        switch self {
        case .outsideProject(let p): return "Refusing to write outside the selected project's folder: \(p)"
        case .alreadyExists(let p): return "A file already exists at \(p)"
        case .emptyTitle: return "The title cannot be empty."
        }
    }
}

public enum KBStore {
    public struct SaveResult: Equatable, Sendable {
        /// Older decisions that were marked `status: superseded` by this save.
        public var superseded: [EntryID] = []
        /// `supersedes` ids that do not exist on disk and were left alone.
        public var missing: [String] = []
    }

    /// Atomic UTF-8 write. Creates the parent folder when needed.
    public static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public static func load(_ id: EntryID, root: URL) throws -> EntryDocument {
        let url = id.fileURL(root: root)
        return EntryDocument(id: id, url: url, text: try String(contentsOf: url, encoding: .utf8))
    }

    /// A new entry in memory, with a file name that is free in `project`. Nothing is written.
    public static func newDocument(
        project: String, section: KBSection, title rawTitle: String, root: URL,
        date: String = KBDate.today(), supersedes: [EntryID] = [], tags: [String] = []
    ) throws -> EntryDocument {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || section == .overview else { throw KBStoreError.emptyTitle }
        let base = section.isDated ? "\(date)-\(Slug.make(title))" : Slug.make(title)
        var stem = base
        var n = 2
        while EntryID(project: project, section: section, stem: stem).fileURL(root: root).fileExists {
            if section == .overview { throw KBStoreError.alreadyExists(EntryID(project: project, section: section, stem: stem).fileURL(root: root).path) }
            stem = "\(base)-\(n)"
            n += 1
        }
        let id = EntryID(project: project, section: section, stem: stem)

        var fm = Frontmatter()
        fm.set("title", .string(title.isEmpty ? "Overview" : title))
        fm.set("date", .string(date))
        if section == .decisions { fm.set("status", .string("active")) }
        if section == .followups {
            fm.set("kind", .string("action"))
            fm.set("status", .string("open"))
        }
        if section == .backlog {
            fm.set("kind", .string("pbi"))
            fm.set("status", .string("proposed"))
        }
        if section == .ideas { fm.set("status", .string(IdeaStatus.new.rawValue)) }
        if section == .research { fm.set("status", .string(ResearchStatus.open.rawValue)) }
        if section == .notes { fm.set("status", .string(NoteStatus.open.rawValue)) }
        if section == .discussions {
            fm.set("status", .string("open"))
            fm.set("waiting_on", .string("nobody"))
            fm.set("people", .list([]))
        }
        fm.set("summary", .string(""))
        if !supersedes.isEmpty { fm.set("supersedes", .list(supersedes.map(\.rawValue))) }
        if section == .meetings { fm.set("attendees", .list([])) }
        fm.set("tags", .list(tags))
        return EntryDocument(id: id, url: id.fileURL(root: root), frontmatter: fm, body: template(for: section))
    }

    /// Creates the entry on disk and returns it loaded.
    @discardableResult
    public static func create(project: String, section: KBSection, title: String, root: URL, date: String = KBDate.today()) throws -> EntryDocument {
        var doc = try newDocument(project: project, section: section, title: title, root: root, date: date)
        _ = try save(&doc, root: root)
        return doc
    }

    public static func template(for section: KBSection) -> String {
        switch section {
        case .decisions:
            return "\n## Decision\n\n\n## Why\n\n\n## Consequences\n\n"
        case .meetings:
            return "\n## Context\n\n\n## Decisions\n\n\n## Q&A\n\n\n## Open questions\n\n\n## Action items\n\n"
        case .backlog:
            return "\n## Description\n\n\n## Acceptance criteria\n\n- \n"
        case .references:
            return "\n## Why it matters\n\n\n## Content\n\n"
        case .discussions:
            return "\n## Summary\n\n\n## Points raised\n\n\n## Open questions\n\n\n## Findings\n\n\n## Outcome\n\n"
        case .ideas:
            return "\n## The idea\n\n\n## Brainstorm\n\n\n## Open questions\n\n\n## Next steps\n\n\n## Turned into\n\n"
        case .research:
            return "\n" + ResearchBody.template(question: "")
        case .notes:
            return "\n" + NoteBody.template(text: "")
        case .facts, .architecture, .overview, .followups, .inbox:
            return "\n"
        }
    }

    /// Writes the document. On the first save of a new decision, every existing decision in its
    /// `supersedes` list is marked `status: superseded` with `superseded_by` pointing back.
    @discardableResult
    public static func save(_ doc: inout EntryDocument, root: URL) throws -> SaveResult {
        guard isInsideProject(doc.url, project: doc.id.project, root: root) else {
            throw KBStoreError.outsideProject(doc.url.path)
        }
        let wasNew = doc.isNew
        if wasNew && doc.url.fileExists { throw KBStoreError.alreadyExists(doc.url.path) }
        EntryTags.recordUserEdit(&doc.frontmatter, old: doc.diskText.map { FrontmatterCodec.parse($0).frontmatter })
        let text = doc.serialized
        try write(text, to: doc.url)
        doc.diskText = text
        doc.hasFrontmatter = !doc.frontmatter.lines.isEmpty || doc.hasFrontmatter

        var result = SaveResult()
        if wasNew && doc.id.section == .decisions {
            for raw in doc.frontmatter.list("supersedes") {
                guard let old = EntryID(raw), old.section == .decisions, old != doc.id, old.fileURL(root: root).fileExists else {
                    result.missing.append(raw)
                    continue
                }
                try markSuperseded(old, by: doc.id, root: root)
                result.superseded.append(old)
            }
        }
        return result
    }

    /// Sets `status: superseded` and `superseded_by: <new>` on an existing decision. The body is not touched.
    public static func markSuperseded(_ old: EntryID, by new: EntryID, root: URL) throws {
        var doc = try load(old, root: root)
        doc.frontmatter.set("status", .string(DecisionStatus.superseded.rawValue))
        doc.frontmatter.set("superseded_by", .string(new.rawValue))
        let text = doc.serialized
        try write(text, to: doc.url)
    }

    static func isInsideProject(_ url: URL, project: String, root: URL) -> Bool {
        guard let id = EntryID(fileURL: url, root: root) else { return false }
        return id.project == project
    }
}

extension URL {
    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// What to do with an open document after the files on disk changed.
public enum DiskSync: Equatable, Sendable {
    case unchanged
    /// Not edited here: take the disk version silently.
    case reload(EntryDocument)
    /// Edited here and changed on disk: ask.
    case conflictModified
    /// Edited here and deleted on disk: ask.
    case conflictDeleted
    /// Not edited here and deleted on disk: close it.
    case close

    /// `diskText` is the file's current content, or `nil` when it no longer exists.
    public static func decide(_ doc: EntryDocument, diskText: String?) -> DiskSync {
        guard !doc.isNew else { return .unchanged }
        guard let diskText else { return doc.isDirty ? .conflictDeleted : .close }
        if diskText == doc.diskText { return .unchanged }
        return doc.isDirty ? .conflictModified : .reload(EntryDocument(id: doc.id, url: doc.url, text: diskText))
    }
}
