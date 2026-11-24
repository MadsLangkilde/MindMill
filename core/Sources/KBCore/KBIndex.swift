import Foundation

/// A scope: one folder of the KB (`projects/<id>/`), such as Android or Product-wide. (The type keeps its old name.)
public struct KBProject: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let paths: [String]
    public let remotes: [String]
    public let related: [String]
    /// The project this scope belongs to, such as `acme`.
    public let group: String
    /// The project-wide scope of its project. It shows every entry of the project.
    public let wide: Bool
    /// Other scopes whose entries this scope also shows, such as Mobile showing Android and iOS.
    public let includes: [String]

    public init(id: String, title: String, paths: [String] = [], remotes: [String] = [], related: [String] = [],
                group: String? = nil, wide: Bool = true, includes: [String] = []) {
        self.includes = includes
        self.id = id
        self.title = title
        self.paths = paths
        self.remotes = remotes
        self.related = related
        self.group = group ?? id
        self.wide = wide
    }
}

/// A project: a set of scopes, one of them project-wide.
public struct KBGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let scopes: [String]

    public init(id: String, title: String, scopes: [String]) {
        self.id = id
        self.title = title
        self.scopes = scopes
    }
}

public enum DecisionStatus: String, CaseIterable, Sendable {
    case active, proposed, superseded
}

public struct KBEntry: Identifiable, Hashable, Sendable {
    public let id: EntryID
    public let url: URL
    public let title: String
    public let date: String
    public let summary: String
    public let status: DecisionStatus?
    public let tags: [String]
    public let supersedes: [String]
    public let supersededBy: String?
    public let source: String?
    public let body: String
    public let frontmatter: Frontmatter
    let haystack: String

    public var project: String { id.project }
    public var section: KBSection { id.section }

    /// Titles are one line: a line break (real, or written as `\n`) becomes a space.
    public static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    /// The folder's scope first, then any other scopes the entry is tagged with.
    public var scopes: [String] {
        var out = [id.project]
        for s in frontmatter.list("scopes") where !out.contains(s) { out.append(s) }
        return out
    }
    public func isIn(scope: String) -> Bool { id.project == scope || frontmatter.list("scopes").contains(scope) }

    public init(id: EntryID, url: URL, text: String) {
        let parsed = FrontmatterCodec.parse(text)
        let fm = parsed.frontmatter
        self.id = id
        self.url = url
        let title = KBEntry.oneLine(fm.string("title") ?? "")
        self.title = title.isEmpty ? (id.section == .overview ? "Overview" : id.stem) : title
        let date = fm.string("date")?.trimmingCharacters(in: .whitespaces) ?? ""
        self.date = date.isEmpty ? (id.datePrefix ?? "") : date
        self.summary = fm.string("summary") ?? ""
        if id.section == .decisions {
            self.status = DecisionStatus(rawValue: (fm.string("status") ?? "").lowercased()) ?? .active
        } else {
            self.status = nil
        }
        self.tags = fm.list("tags")
        self.supersedes = fm.list("supersedes")
        let sb = fm.string("superseded_by")?.trimmingCharacters(in: .whitespaces) ?? ""
        self.supersededBy = sb.isEmpty ? nil : sb
        let src = fm.string("source")?.trimmingCharacters(in: .whitespaces) ?? ""
        self.source = src.isEmpty ? nil : src
        self.body = parsed.body
        self.frontmatter = fm
        // The fields count too (work_item, url, owner, attendees…).
        self.haystack = ([self.title, KBSearch.text(fm), parsed.body]).joined(separator: "\n").lowercased()
    }

    /// A trimmed frontmatter string, `nil` when absent or empty.
    public func field(_ key: String) -> String? {
        let v = frontmatter.string(key)?.trimmingCharacters(in: .whitespaces) ?? ""
        return v.isEmpty ? nil : v
    }

    public func listField(_ key: String) -> [String] { frontmatter.list(key) }

    /// The raw `status` value, lowercased; empty when absent.
    public var rawStatus: String { (field("status") ?? "").lowercased() }

    public var meetingStatus: MeetingStatus? {
        section == .meetings ? MeetingStatus(rawValue: rawStatus) ?? .filed : nil
    }

    /// The user finished preparing the meeting (Done in the app, or picked its questions).
    public var meetingReady: Bool { field("ready") == "true" }

    /// For an inbox entry: the section it would be approved into.
    public var proposedSection: KBSection? { field("proposed_section").flatMap(KBSection.init(rawValue:)) }
    public var proposedBy: String? { field("proposed_by") }
    /// A pending change to an existing fact (`updates: <fact id>`); it waits on the fact.
    public var isFactChange: Bool { section == .inbox && field("updates") != nil }
    /// A new fact waiting for the user's yes; it waits under Facts, not in the Inbox.
    public var isFactProposal: Bool { section == .inbox && proposedSection == .facts && field("updates") == nil }
    /// What the Inbox lists: every proposal except those about facts.
    public var waitsInInbox: Bool { section == .inbox && !isFactChange && !isFactProposal }
    public var isDraft: Bool { field("draft") == "true" }
    public var reason: String? { field("reason") }

    /// `source` as a list: backlog items carry several, decisions and facts one.
    public var sources: [String] { listField("source") }

    public func matches(_ query: String) -> Bool {
        KBSearch.matches(query, in: haystack)
    }
}

public enum KBLoadError: Error, Equatable, Sendable {
    case rootMissing(String)
    case registryMissing(String)
    case registryInvalid(String)

    /// No knowledge base there yet, as on a new Mac: one can be created.
    public var isMissing: Bool {
        switch self {
        case .rootMissing, .registryMissing: return true
        case .registryInvalid: return false
        }
    }

    public var title: String {
        switch self {
        case .rootMissing: return "Knowledge base not found"
        case .registryMissing: return "No kb.json"
        case .registryInvalid: return "kb.json could not be read"
        }
    }

    public var message: String {
        switch self {
        case .rootMissing(let p): return "The folder \(p) does not exist. Choose another root in Settings (⌘,)."
        case .registryMissing(let p): return "\(p) has no kb.json project registry. Choose another root in Settings (⌘,)."
        case .registryInvalid(let why): return why
        }
    }
}

public struct DecisionChain: Identifiable, Hashable, Sendable {
    /// Oldest first; each element is superseded by the next one.
    public let entries: [KBEntry]
    public var id: String { entries.first?.id.rawValue ?? "" }
    public var newestDate: String { entries.map(\.date).max() ?? "" }
}

public struct KBIndex: Sendable {
    public let root: URL
    /// Every scope, in registry order.
    public let projects: [KBProject]
    /// The projects that group the scopes.
    public let groups: [KBGroup]
    public let entries: [EntryID: KBEntry]

    public static let empty = KBIndex(root: URL(fileURLWithPath: "/"), projects: [], entries: [:])

    public init(root: URL, projects: [KBProject], entries: [EntryID: KBEntry], groups: [KBGroup]? = nil) {
        self.root = root
        self.projects = projects
        self.entries = entries
        self.groups = groups ?? KBIndex.groups(of: projects, titles: [:])
    }

    static func groups(of scopes: [KBProject], titles: [String: String]) -> [KBGroup] {
        var order: [String] = []
        var members: [String: [String]] = [:]
        for s in scopes {
            if members[s.group] == nil { order.append(s.group) }
            members[s.group, default: []].append(s.id)
        }
        return order.map { g in
            KBGroup(id: g, title: titles[g] ?? scopes.first { $0.id == g }?.title ?? g, scopes: members[g] ?? [])
        }
    }

    public func group(of scope: String) -> KBGroup? {
        guard let g = project(scope)?.group else { return nil }
        return groups.first { $0.id == g }
    }

    /// The other scopes of a scope's project, which an entry there can also be tagged with.
    public func siblings(of scope: String) -> [KBProject] {
        guard let g = group(of: scope) else { return [] }
        return g.scopes.compactMap(project).filter { $0.id != scope }
    }

    public static func load(root: URL, fileManager: FileManager = .default) throws -> KBIndex {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw KBLoadError.rootMissing(root.path)
        }
        let layout = KBLayout.of(root: root)
        let registry = layout.home.appendingPathComponent("kb.json")
        guard fileManager.fileExists(atPath: registry.path) else { throw KBLoadError.registryMissing(root.path) }
        let (projects, groupTitles) = try parseRegistry(at: registry)

        var entries: [EntryID: KBEntry] = [:]
        for project in projects {
            // Team first, so an entry in both folders is read from the private one, which holds every entry.
            for dir in layout.dirs(project.id).reversed() {
                let overview = dir.appendingPathComponent("overview.md")
                if let text = try? String(contentsOf: overview, encoding: .utf8) {
                    let id = EntryID(project: project.id, section: .overview, stem: "overview")
                    entries[id] = KBEntry(id: id, url: overview, text: text)
                }
                for section in KBSection.folders {
                    let sdir = dir.appendingPathComponent(section.rawValue)
                    guard let names = try? fileManager.contentsOfDirectory(atPath: sdir.path) else { continue }
                    for name in names where name.hasSuffix(".md") && !name.hasPrefix(".") {
                        let url = sdir.appendingPathComponent(name)
                        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                        let id = EntryID(project: project.id, section: section, stem: String(name.dropLast(3)))
                        entries[id] = KBEntry(id: id, url: url, text: text)
                    }
                }
            }
        }
        var index = KBIndex(root: root, projects: projects, entries: entries, groups: groups(of: projects, titles: groupTitles))
        index.overviewSpansAll = layout.isSplit
        return index
    }

    /// v2 nests scopes in projects; a v1 project (no `scopes`) is a scope that is its own project.
    static func parseRegistry(at url: URL) throws -> ([KBProject], [String: String]) {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw KBLoadError.registryInvalid(error.localizedDescription) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw KBLoadError.registryInvalid("kb.json is not a JSON object.")
        }
        guard let list = json["projects"] as? [[String: Any]] else {
            throw KBLoadError.registryInvalid("kb.json has no \"projects\" array.")
        }
        func scope(_ p: [String: Any], group: String?, wide: Bool) -> KBProject? {
            guard let id = p["id"] as? String, !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return nil }
            let title = (p["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return KBProject(id: id, title: title, paths: p["paths"] as? [String] ?? [], remotes: p["remotes"] as? [String] ?? [],
                             related: p["related"] as? [String] ?? [], group: group, wide: wide,
                             includes: p["includes"] as? [String] ?? [])
        }
        var scopes: [KBProject] = []
        var titles: [String: String] = [:]
        for p in list {
            if let nested = p["scopes"] as? [[String: Any]], let gid = p["id"] as? String, !gid.isEmpty {
                titles[gid] = (p["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? gid
                scopes += nested.compactMap { scope($0, group: gid, wide: ($0["wide"] as? Bool) ?? false) }
            } else if let s = scope(p, group: nil, wide: true) {
                scopes.append(s)
            }
        }
        return (scopes, titles)
    }

    public func project(_ id: String) -> KBProject? {
        projects.first { $0.id == id }
    }

    public func entry(_ id: EntryID) -> KBEntry? {
        entries[id]
    }

    /// In the split layout the wide scope is the Overview, which shows every scope in the app.
    public var overviewSpansAll = false

    /// The scopes whose entries `scope` shows: itself and what it includes. The Overview shows every scope; in the
    /// legacy layout a project-wide scope shows its own project.
    public func members(of scope: String) -> Set<String> {
        guard let s = project(scope) else { return [scope] }
        if s.wide, overviewSpansAll { return Set(projects.map(\.id)) }
        if s.wide, let g = group(of: scope) { return Set(g.scopes) }
        var out: Set<String> = [scope]
        var queue = s.includes
        while let next = queue.popLast() {
            guard out.insert(next).inserted, let n = project(next) else { continue }
            queue += n.includes
        }
        return out
    }

    /// Whether `scope` lists the entry: it lives in or is tagged with one of the scope's members.
    public func shows(_ entry: KBEntry, in scope: String) -> Bool {
        shows(entry, members: members(of: scope))
    }

    func shows(_ entry: KBEntry, members: Set<String>) -> Bool {
        members.contains(entry.project) || entry.scopes.contains { members.contains($0) }
    }

    /// A scope's entries: those in its folder, those tagged with it, and those of the scopes it includes.
    /// A scope's overview stays its own.
    public func entries(project: String, section: KBSection) -> [KBEntry] {
        let m = section == .overview ? [project] : members(of: project)
        return KBIndex.sorted(entries.values.filter { $0.section == section && shows($0, members: m) })
    }

    public func count(project: String, section: KBSection) -> Int {
        let m = section == .overview ? [project] : members(of: project)
        return entries.values.reduce(0) { $0 + ($1.section == section && shows($1, members: m) ? 1 : 0) }
    }

    /// Dated entries newest first; facts and architecture by title.
    public static func sorted(_ list: [KBEntry]) -> [KBEntry] {
        list.sorted { a, b in
            if a.section != b.section { return a.section.rawValue < b.section.rawValue }
            if a.section == .inbox { return a.id.stem > b.id.stem }
            if a.section.isDated || a.section == .overview {
                if a.date != b.date { return a.date > b.date }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
            let c = a.title.localizedStandardCompare(b.title)
            return c == .orderedSame ? a.id < b.id : c == .orderedAscending
        }
    }

    /// Entries matching every whitespace-separated term, case-insensitively, in title, summary, tags and body.
    /// `project` limits the search to one project; `nil` searches all, grouped in registry order.
    public func search(_ query: String, project: String? = nil) -> [(project: KBProject, entries: [KBEntry])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let scope = project.map { id in projects.filter { $0.id == id } } ?? projects
        return scope.compactMap { p in
            let m = members(of: p.id)
            let hits = entries.values.filter {
                (project == nil ? $0.project == p.id : shows($0, members: m)) && $0.matches(q)
            }
            guard !hits.isEmpty else { return nil }
            let order = KBSection.allCases
            let sorted = hits.sorted { a, b in
                if a.section != b.section {
                    return order.firstIndex(of: a.section)! < order.firstIndex(of: b.section)!
                }
                return KBIndex.sorted([a, b]).first == a
            }
            return (p, sorted)
        }
    }

    /// For a half-remembered search: entries that don't have every word but have most of them, or words that start
    /// the same way (“sign” finds “signs off”), best first. Strict matches are left out; `search` has those.
    public func looseSearch(_ query: String, project: String? = nil, limit: Int = 20) -> [KBEntry] {
        let terms = KBSearch.terms(query).filter { $0.count >= 3 }
        guard !terms.isEmpty else { return [] }
        let stems = terms.map { $0.count > 5 ? String($0.prefix(max(4, $0.count - 3))) : $0 }
        let need = max(1, Int((Double(terms.count) * 0.5).rounded(.up)))
        let m = project.map { members(of: $0) }
        var scored: [(KBEntry, Int)] = []
        for e in entries.values where m.map({ shows(e, members: $0) }) ?? true {
            guard !e.matches(query) else { continue }
            let title = e.title.lowercased()
            var hits = 0, score = 0
            for (t, stem) in zip(terms, stems) {
                if e.haystack.contains(t) { hits += 1; score += title.contains(t) ? 4 : 2 } else if e.haystack.contains(stem) { hits += 1; score += title.contains(stem) ? 3 : 1 }
            }
            if hits >= need { scored.append((e, score * 10 + hits)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }.prefix(limit).map(\.0)
    }

    /// Inbox entries proposed by `proposer` (a meeting id, `session:<id>` or `daily:<date>`).
    public func inbox(project: String, proposedBy proposer: String) -> [KBEntry] {
        entries(project: project, section: .inbox).filter { $0.proposedBy == proposer }
    }

    /// Backlog entries whose `source` list contains `id`.
    public func backlog(project: String, sourcedFrom id: String) -> [KBEntry] {
        entries(project: project, section: .backlog).filter { $0.sources.contains(id) }
    }

    /// Supersede chains among a project's decisions (components with two or more decisions, newest chain
    /// first) and the decisions that are not linked to any other.
    public func decisionTimeline(project: String) -> (chains: [DecisionChain], standalone: [KBEntry]) {
        let m = members(of: project)
        let decisions = entries.values.filter { $0.section == .decisions && shows($0, members: m) }
        var byID: [String: KBEntry] = [:]
        for d in decisions { byID[d.id.rawValue] = d }

        var adjacency: [String: Set<String>] = [:]
        func link(_ a: String, _ b: String) {
            guard byID[a] != nil, byID[b] != nil, a != b else { return }
            adjacency[a, default: []].insert(b)
            adjacency[b, default: []].insert(a)
        }
        for d in decisions {
            for old in d.supersedes { link(d.id.rawValue, old) }
            if let new = d.supersededBy { link(d.id.rawValue, new) }
        }

        var seen: Set<String> = []
        var chains: [DecisionChain] = []
        var standalone: [KBEntry] = []
        for d in decisions.sorted(by: { $0.id < $1.id }) where !seen.contains(d.id.rawValue) {
            var component: [KBEntry] = []
            var stack = [d.id.rawValue]
            seen.insert(d.id.rawValue)
            while let cur = stack.popLast() {
                if let e = byID[cur] { component.append(e) }
                for n in adjacency[cur] ?? [] where !seen.contains(n) {
                    seen.insert(n)
                    stack.append(n)
                }
            }
            if component.count == 1 {
                standalone.append(component[0])
            } else {
                chains.append(DecisionChain(entries: KBIndex.orderChain(component)))
            }
        }
        chains.sort { $0.newestDate > $1.newestDate }
        return (chains, KBIndex.sorted(standalone))
    }

    /// Orders a chain so each decision comes before the one that replaced it, falling back to date.
    static func orderChain(_ component: [KBEntry]) -> [KBEntry] {
        let ids = Set(component.map { $0.id.rawValue })
        var successors: [String: Set<String>] = [:]
        var indegree: [String: Int] = Dictionary(uniqueKeysWithValues: component.map { ($0.id.rawValue, 0) })
        func edge(old: String, new: String) {
            guard ids.contains(old), ids.contains(new), old != new, !(successors[old]?.contains(new) ?? false) else { return }
            successors[old, default: []].insert(new)
            indegree[new, default: 0] += 1
        }
        for e in component {
            for old in e.supersedes { edge(old: old, new: e.id.rawValue) }
            if let new = e.supersededBy { edge(old: e.id.rawValue, new: new) }
        }
        let byID = Dictionary(uniqueKeysWithValues: component.map { ($0.id.rawValue, $0) })
        let dateOrder: (KBEntry, KBEntry) -> Bool = { a, b in a.date == b.date ? a.id < b.id : a.date < b.date }
        var ready = component.filter { indegree[$0.id.rawValue] == 0 }.sorted(by: dateOrder)
        var result: [KBEntry] = []
        while !ready.isEmpty {
            let next = ready.removeFirst()
            result.append(next)
            for s in successors[next.id.rawValue] ?? [] {
                indegree[s]! -= 1
                if indegree[s] == 0, let e = byID[s] {
                    ready.append(e)
                    ready.sort(by: dateOrder)
                }
            }
        }
        if result.count < component.count {
            let placed = Set(result.map { $0.id })
            result += component.filter { !placed.contains($0.id) }.sorted(by: dateOrder)
        }
        return result
    }
}

public enum MeetingStatus: String, CaseIterable, Sendable {
    case scheduled, prepared, live, review, filed, cancelled

    /// Statuses that open in meeting mode rather than as a plain entry.
    public var isActive: Bool { self != .filed && self != .cancelled }

    /// Before the meeting: notes can start, and Claude can prepare it.
    public var isUpcoming: Bool { self == .scheduled || self == .prepared }
}

public enum FollowupStatus: String, CaseIterable, Sendable {
    case open, done, dropped

    /// How a closed one reads in the Handled list.
    public var handledTitle: String {
        switch self {
        case .open: return "Open"
        case .done: return "Resolved"
        case .dropped: return "No longer needed"
        }
    }
}

/// What the background follow-up check did, from its reply.
public struct FollowupCheckReport: Equatable, Sendable {
    public var handled: [(id: String, why: String)] = []
    public var updated: [(id: String, why: String)] = []

    public static func == (a: Self, b: Self) -> Bool {
        a.handled.map { $0.id + $0.why } == b.handled.map { $0.id + $0.why } && a.updated.map { $0.id + $0.why } == b.updated.map { $0.id + $0.why }
    }

    public init(_ reply: String) {
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            for (prefix, handled) in [("HANDLED ", true), ("UPDATED ", false)] where line.hasPrefix(prefix) {
                let rest = line.dropFirst(prefix.count)
                let parts = rest.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard let id = parts.first, !id.isEmpty else { continue }
                let item = (id: id.trimmingCharacters(in: CharacterSet(charactersIn: "`")), why: parts.count > 1 ? parts[1] : "")
                if handled { self.handled.append(item) } else { updated.append(item) }
            }
        }
    }
}

public enum BacklogStatus: String, CaseIterable, Sendable {
    case proposed, created, rejected
}

extension KBEntry {
    public var followupKind: String { (field("kind") ?? "action").lowercased() }
    public var followupStatus: FollowupStatus { FollowupStatus(rawValue: rawStatus) ?? .open }
    /// Done was pressed on the meeting and Claude is writing its summary.
    public var meetingSummarizing: Bool { meetingStatus == .live && !(field("summarizing") ?? "").isEmpty }
    /// The app closed this follow-up by itself, finding it handled by something the user saved.
    public var closedByKB: Bool { field("closed_by") == "kb" }
    /// The newest line under `## Updates`, without its date.
    public var latestUpdate: String? {
        guard let range = body.range(of: "## Updates") else { return nil }
        let line = body[range.upperBound...].components(separatedBy: .newlines)
            .last { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
        guard var text = line?.trimmingCharacters(in: .whitespaces).dropFirst(2).description else { return nil }
        if text.count > 12, KBDate.isISODate(String(text.prefix(10))), text.dropFirst(10).hasPrefix(": ") { text = String(text.dropFirst(12)) }
        return text.isEmpty ? nil : text
    }
    public var backlogStatus: BacklogStatus { BacklogStatus(rawValue: rawStatus) ?? .proposed }
    public var backlogKind: String { (field("kind") ?? "pbi").lowercased() }

    /// True when `due` is a date before `today` and the follow-up is still open.
    public func isOverdue(today: String = KBDate.today()) -> Bool {
        guard section == .followups, followupStatus == .open, let due = field("due"), KBDate.isISODate(due) else { return false }
        return due < today
    }
}
