import Foundation

/// `kb docs list --json`: the documentation files a scope added from its repository, and drafts of them made in
/// the app that aren't in the repository yet.
public struct ProjectDocList: Codable, Equatable, Sendable {
    public struct Doc: Codable, Equatable, Sendable, Identifiable {
        public var path: String
        public var title: String
        /// Where to read it now: the draft when there is one, else the repository's file.
        public var file: String
        public var repoFile: String
        public var exists: Bool
        /// `edited` or `new` while a draft waits to go into the repository.
        public var draft: String?
        /// The repository's file changed after the draft was started.
        public var stale: Bool
        public var modified: String

        public var id: String { path }
        public var hasDraft: Bool { draft != nil }
        public var folder: String {
            let parts = path.split(separator: "/")
            return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
        }

        enum CodingKeys: String, CodingKey {
            case path, title, file, exists, draft, stale, modified
            case repoFile = "repo_file"
        }

        public init(path: String, title: String, file: String = "", repoFile: String = "", exists: Bool = true,
                    draft: String? = nil, stale: Bool = false, modified: String = "") {
            self.path = path
            self.title = title
            self.file = file
            self.repoFile = repoFile
            self.exists = exists
            self.draft = draft
            self.stale = stale
            self.modified = modified
        }

        public func matches(_ query: String) -> Bool {
            let q = query.lowercased()
            return q.isEmpty || title.lowercased().contains(q) || path.lowercased().contains(q)
        }
    }

    public var checkout: String
    public var docs: [Doc]

    public var drafts: [Doc] { docs.filter(\.hasDraft) }

    public static func decode(_ json: String) throws -> ProjectDocList {
        try JSONDecoder().decode(ProjectDocList.self, from: Data(json.utf8))
    }

    /// Docs by folder, the repository's top level first.
    public var byFolder: [(folder: String, docs: [Doc])] {
        Dictionary(grouping: docs, by: \.folder)
            .map { ($0.key, $0.value.sorted { $0.title.lowercased() < $1.title.lowercased() }) }
            .sorted { ($0.folder.isEmpty ? "" : "~" + $0.folder) < ($1.folder.isEmpty ? "" : "~" + $1.folder) }
    }
}

/// `kb docs scan --json`: documentation files found in the repository.
public struct DocScan: Codable, Equatable, Sendable {
    public struct Found: Codable, Equatable, Sendable, Identifiable {
        public var path: String
        public var title: String
        public var size: Int
        public var added: Bool
        public var id: String { path }
    }

    public var checkout: String
    public var docs: [Found]

    public static func decode(_ json: String) throws -> DocScan {
        try JSONDecoder().decode(DocScan.self, from: Data(json.utf8))
    }
}

public enum ProjectDocPath {
    /// A repository path for a new document titled `title` in `folder`.
    public static func suggested(title: String, folder: String = "docs") -> String {
        let slug = Slug.make(title, maxLength: 50)
        let dir = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return (dir.isEmpty ? "" : dir + "/") + (slug.isEmpty ? "untitled" : slug) + ".md"
    }

    /// Mirrors `kb docs`: inside the repository, a documentation file, not in a build or tooling folder.
    public static func isValid(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespaces)
        let parts = p.split(separator: "/").map(String.init)
        guard !p.isEmpty, !p.hasPrefix("/"), !parts.contains(".."), let first = parts.first else { return false }
        let exts = [".md", ".markdown", ".mdx", ".adoc", ".rst", ".mmd", ".puml"]
        let skip: Set<String> = [".git", "node_modules", "build", ".build", "Pods", "Carthage", ".gradle", ".idea",
                                 "DerivedData", "vendor", "dist", "out", "target", ".venv", "venv", "__pycache__", ".claude",
                                 KBLayout.teamFolder]
        return exts.contains { p.lowercased().hasSuffix($0) } && !skip.contains(first)
    }

    /// The brief for the Build session that puts the drafts into the repository.
    public static func prBrief(scope: String, docs: [ProjectDocList.Doc], note: String) -> String {
        let list = docs.map { "- `\($0.path)` (\($0.draft == "new" ? "new" : "edited")\($0.stale ? "; the repository changed it since the draft began" : "")): the new text is in `\($0.file)`" }
            .joined(separator: "\n")
        let why = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Put these documentation changes from the Mindmill app into the repository with a pull request. The user said yes to the branch, the commit, the push and the pull request.
        \(list)
        \(why.isEmpty ? "" : "\nWhat changed and why, in the user's words: \(why)\n")
        `kb docs diff --scope \(scope)` shows the changes.
        1. Make a new branch from the repository's default branch, in a new worktree, named the way this repository names documentation branches (else `docs/<short-name>`). Copy each draft over its file there. Where the repository changed a file since the draft began, merge the two by hand, and ask with choices when they disagree.
        2. Commit with this repository's commit conventions, push, and open a pull request the way this repository does (its own PR skill or instructions when it has them). When the branch policy needs a linked work item, ask the user which one with choices. When the repository has no remote or no way to open a pull request, stop after the commit and say so.
        3. Then `kb docs saved --scope \(scope) \(docs.map(\.path).joined(separator: " "))` so the app stops showing them as drafts, and reply with the pull request's link.
        Keep the draft paths, KB ids and local paths out of the commit message and the pull request.
        """
    }
}
