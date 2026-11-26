import Foundation

/// Whether an entry stays on this Mac or is shared with the team, and how far a shared one has got. Every entry
/// lives in the scope's private folder; a shared one also has a copy in the scope's repository (`knowledgebase/`).
public enum EntrySharing: String, Equatable, Sendable {
    /// Only in the KB on this Mac.
    case `private`
    /// Its scope has no repository on this Mac, so it can't be shared.
    case noRepository
    /// Copied into the repository, not committed yet.
    case uncommitted
    /// Committed, not pushed (or the branch isn't on the remote yet).
    case unpushed
    /// Pushed: others can see it.
    case pushed
    /// Shared, but the repository's checked-out branch doesn't have it.
    case missing
    /// Copied into a folder that isn't a git repository.
    case local

    public var isShared: Bool { ![.private, .noRepository].contains(self) }

    public var symbol: String {
        switch self {
        case .private, .noRepository: return "lock.fill"
        case .uncommitted, .unpushed, .local: return "arrow.up.circle"
        case .pushed: return "person.2.fill"
        case .missing: return "person.2.slash"
        }
    }

    public var title: String {
        switch self {
        case .private: return "Private"
        case .noRepository: return "Private"
        case .uncommitted: return "Shared · not committed"
        case .unpushed: return "Shared · not pushed"
        case .pushed: return "Shared · pushed"
        case .missing: return "Shared · not on this branch"
        case .local: return "Shared · no git"
        }
    }

    /// The hover text: what it means and what happens next.
    public func help(repo: String?, branch: String?) -> String {
        let r = repo ?? "the repository"
        let on = branch.map { " on \($0)" } ?? ""
        switch self {
        case .private:
            return "Private: only in your knowledge base on this Mac. Share it to put a copy in \(r) for the team."
        case .noRepository:
            return "Private: this scope has no repository on this Mac, so its entries stay in your knowledge base."
        case .uncommitted:
            return "Shared: copied into \(r)/knowledgebase but not committed yet. Others see it once it's committed and pushed."
        case .unpushed:
            return "Shared: committed\(on) in \(r) but not pushed yet. Others see it after the next push."
        case .pushed:
            return "Shared and pushed\(on): others with access to \(r) can see it."
        case .missing:
            return "Shared, but the branch checked out in \(r)\(branch.map { " (\($0))" } ?? "") doesn't have it. It's safe in your knowledge base and shows up there again on a branch that has it."
        case .local:
            return "Shared: copied into \(r)/knowledgebase, which isn't a git repository, so nothing is pushed."
        }
    }
}

/// `kb share status --json`: each scope's repository and its shared entries' states. An entry not listed is private.
public struct SharingStatus: Equatable, Sendable {
    public struct Repo: Equatable, Sendable {
        public var path: String?
        public var branch: String?
        public var upstream: String?
        public var name: String? { path.map { URL(fileURLWithPath: $0).lastPathComponent } }
    }

    public var repos: [String: Repo]
    public var entries: [String: EntrySharing]

    public init(repos: [String: Repo] = [:], entries: [String: EntrySharing] = [:]) {
        self.repos = repos
        self.entries = entries
    }

    public static func parse(_ json: String) -> SharingStatus? {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let scopes = root["scopes"] as? [String: [String: Any]] else { return nil }
        var out = SharingStatus()
        for (sid, s) in scopes {
            out.repos[sid] = Repo(path: s["repo"] as? String, branch: s["branch"] as? String, upstream: s["upstream"] as? String)
            for (eid, state) in s["entries"] as? [String: String] ?? [:] {
                out.entries[eid] = EntrySharing(rawValue: state) ?? .uncommitted
            }
        }
        return out
    }

    /// The entry's state: listed ones as given, the rest private (or unshareable without a repository).
    public func state(of id: EntryID) -> EntrySharing {
        if let s = entries[id.rawValue] { return s }
        return repos[id.project]?.path == nil ? .noRepository : .private
    }

    /// Whether a kind of entry is shared when it's made: the scope's choice (`chosen`, settings.json `sharing`), else
    /// the team's knowledge is and meetings, notes and the rest aren't.
    public static func sharedByDefault(_ section: KBSection, chosen: [String: String] = [:]) -> Bool {
        if let v = chosen[section.rawValue], v == "shared" || v == "private" { return v == "shared" }
        return KBLayout.teamSections.contains(section)
    }
}

/// The repositories a scope works with: its own and those it works on alongside it, then the ones it only takes
/// knowledge from. The same rules as `kb repos`.
public struct ScopeRepositories: Equatable, Sendable {
    public struct Repo: Equatable, Sendable, Identifiable {
        public var scope: String
        public var title: String
        public var checkout: URL?
        public var configured: String
        public var reference: Bool
        public var id: String { scope }
    }

    public var work: [Repo]
    public var reference: [Repo]

    public var all: [Repo] { work + reference }

    public static func of(_ scope: String, in index: KBIndex) -> ScopeRepositories {
        guard let s = index.project(scope) else { return ScopeRepositories(work: [], reference: []) }
        let ordered = [scope] + index.projects.map(\.id).filter { $0 != scope }
        let members = index.members(of: scope)
        let workIDs = ordered.filter { members.contains($0) }
        let refIDs = s.related.filter { !members.contains($0) && index.project($0) != nil }
        var seen: Set<String> = []
        func repos(_ ids: [String], reference: Bool) -> [Repo] {
            ids.compactMap { id in
                guard let p = index.project(id), let first = p.paths.first else { return nil }
                let checkout = KBLayout.checkout(paths: p.paths)
                let key = checkout?.path ?? "missing:\(id)"
                guard seen.insert(key).inserted else { return nil }
                return Repo(scope: id, title: p.title, checkout: checkout, configured: first, reference: reference)
            }
        }
        let work = repos(workIDs, reference: false)
        return ScopeRepositories(work: work, reference: repos(refIDs, reference: true))
    }

    /// Where a session in the scope starts: its own checkout, else the first one it works on.
    public var workingDirectory: URL? { work.compactMap(\.checkout).first }

    /// The other checkouts a session may read (and, for those it works on, change).
    public var extraDirectories: [URL] {
        let start = workingDirectory
        return all.compactMap(\.checkout).filter { $0 != start }
    }
}

/// `kb repos --json`: a repository's branch and how far it is from its remote.
public struct RepoState: Equatable, Sendable {
    public var git: Bool
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var changed: Int

    public init(git: Bool, branch: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, changed: Int = 0) {
        self.git = git
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changed = changed
    }

    public static func parse(_ json: String) -> [String: RepoState] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let repos = root["repos"] as? [[String: Any]] else { return [:] }
        var out: [String: RepoState] = [:]
        for r in repos {
            guard let scope = r["scope"] as? String, r["path"] is String else { continue }
            out[scope] = RepoState(git: r["git"] as? Bool ?? false, branch: r["branch"] as? String,
                                   upstream: r["upstream"] as? String, ahead: r["ahead"] as? Int ?? 0,
                                   behind: r["behind"] as? Int ?? 0, changed: r["changed"] as? Int ?? 0)
        }
        return out
    }

    /// One line: the branch and what stands out.
    public var summary: String {
        guard git else { return "Not a git repository" }
        var bits = [branch ?? "?"]
        if upstream == nil { bits.append("no remote branch") }
        if behind > 0 { bits.append("\(behind) behind") }
        if ahead > 0 { bits.append("\(ahead) not pushed") }
        if changed > 0 { bits.append("\(changed) changed file\(changed == 1 ? "" : "s")") }
        if upstream != nil, behind == 0, ahead == 0 { bits.append("up to date") }
        return bits.joined(separator: " · ")
    }

    public var canPull: Bool { git && upstream != nil }
}
