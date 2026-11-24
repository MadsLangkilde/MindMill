import Foundation

public enum DuplicateVerdict: String, Codable, Sendable, Comparable {
    case none, possible, likely

    var rank: Int { self == .likely ? 2 : self == .possible ? 1 : 0 }

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// Something a proposal may duplicate: a tracker item, a created backlog entry, or another proposal.
public struct DuplicateCandidate: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case workItem = "work_item", entry, proposal }

    public var kind: Kind
    /// The work item number as text, or the entry id.
    public var id: String
    public var number: Int?
    public var title: String
    public var state: String
    public var type: String
    public var url: String
    public var scopes: [String]
    public var parent: Int?
    public var text: String

    public init(kind: Kind, id: String, number: Int? = nil, title: String, state: String = "", type: String = "pbi",
                url: String = "", scopes: [String], parent: Int? = nil, text: String = "") {
        self.kind = kind
        self.id = id
        self.number = number
        self.title = title
        self.state = state
        self.type = type
        self.url = url
        self.scopes = scopes
        self.parent = parent
        self.text = text
    }

    enum CodingKeys: String, CodingKey { case kind, id, number, title, state, type, url, scopes, parent, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .workItem
        number = try? c.decodeIfPresent(Int.self, forKey: .number)
        id = (try? c.decode(String.self, forKey: .id)) ?? number.map(String.init) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "pbi"
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        parent = try? c.decodeIfPresent(Int.self, forKey: .parent)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    public init(item: TrackerBacklog.Item) {
        self.init(kind: .workItem, id: String(item.id), number: item.id, title: item.title, state: item.state,
                  type: item.type, url: item.url, scopes: item.scopes)
    }
}

public struct DuplicateMatch: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var kind: DuplicateCandidate.Kind
    public var id: String
    public var number: Int?
    public var title: String
    public var state: String
    public var type: String
    public var url: String
    public var score: Double
    public var verdict: DuplicateVerdict
    public var reasons: [String]

    public init(candidate c: DuplicateCandidate, score: Double, verdict: DuplicateVerdict, reasons: [String]) {
        kind = c.kind
        id = c.id
        number = c.number
        title = c.title
        state = c.state
        type = c.type
        url = c.url
        self.score = score
        self.verdict = verdict
        self.reasons = reasons
    }

    enum CodingKeys: String, CodingKey { case kind, id, number, title, state, type, url, score, verdict, reasons }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(DuplicateCandidate.Kind.self, forKey: .kind)) ?? .workItem
        number = try? c.decodeIfPresent(Int.self, forKey: .number)
        id = (try? c.decode(String.self, forKey: .id)) ?? number.map(String.init) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? ""
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "pbi"
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        verdict = (try? c.decode(DuplicateVerdict.self, forKey: .verdict)) ?? .none
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
    }

    /// `#431548`, or the other proposal's title.
    public var label: String { number.map { "#\($0)" } ?? title }
    /// What the user dismisses with Not a Duplicate: the number, else the entry id.
    public var key: String { number.map(String.init) ?? id }
}

public struct DuplicateFinding: Codable, Equatable, Sendable {
    public var id: String
    public var scope: String
    public var title: String
    public var verdict: DuplicateVerdict
    public var matches: [DuplicateMatch]

    public init(id: String, scope: String, title: String, verdict: DuplicateVerdict, matches: [DuplicateMatch]) {
        self.id = id
        self.scope = scope
        self.title = title
        self.verdict = verdict
        self.matches = matches
    }

    public var best: DuplicateMatch? { matches.first }

    /// Something very like it was already created (a work item in the tracker, or a backlog entry created from
    /// Mindmill): the suggestion leaves the list until the user looks at it. Another suggestion doesn't count.
    public var alreadyCreated: DuplicateMatch? {
        matches.first { $0.verdict == .likely && $0.kind != .proposal }
    }
}

/// `kb backlog duplicates --json`.
public struct DuplicateReport: Codable, Equatable, Sendable {
    public var checked: String
    public var proposals: [DuplicateFinding]
    public var candidates: [DuplicateCandidate]
    public var notes: [String]

    public static func decode(_ json: String) throws -> DuplicateReport {
        try JSONDecoder().decode(DuplicateReport.self, from: Data(json.utf8))
    }
}

/// A proposal as the duplicate check sees it.
public struct DuplicateProposal: Equatable, Sendable {
    public var id: String
    public var scope: String
    public var title: String
    public var text: String
    public var parent: Int?
    public var refs: [Int]
    public var related: [String]
    public var dismissed: [String]

    public init(id: String, scope: String, title: String, text: String = "", parent: Int? = nil, refs: [Int] = [],
                related: [String] = [], dismissed: [String] = []) {
        self.id = id
        self.scope = scope
        self.title = title
        self.text = text
        self.parent = parent
        self.refs = refs
        self.related = related
        self.dismissed = dismissed
    }

    public init(entry e: KBEntry) {
        let parent = WorkItemLinks.parentNumber(e.field("parent"))
            ?? WorkItemLinks.inferredParent(body: e.body, ownWorkItem: e.field("work_item"))?.number
        let related = WorkItemLinks.relatedValues(e.listField("related"))
        let refs = WorkItemLinks.refs(in: e.body + "\n" + e.summary).filter { $0 != parent && !related.contains(String($0)) }
        self.init(id: e.id.rawValue, scope: e.project, title: e.title, text: String((e.summary + " " + e.body).prefix(2000)),
                  parent: parent, refs: refs, related: related, dismissed: WorkItemLinks.relatedValues(e.listField("not_duplicate_of")))
    }
}

/// Whether a proposal waiting to be created may already exist, by cheap word overlap. The same rules as
/// `kb backlog duplicates`: title words count most, the description counts when both have one, the same parent and
/// the proposal naming the item add to it, and one shared title word is never enough on its own.
public enum BacklogDuplicates {
    public static let likely = 0.75
    public static let possible = 0.45

    static let stopWords: Set<String> = PBIMatch.stopWords.union([
        "show", "fix", "update", "remove", "support", "handle", "allow", "change", "display", "implement", "create",
        "enable", "user",
    ])

    public static func words(_ s: String) -> Set<String> {
        var out = Set<String>()
        for part in s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) where part.count >= 3 {
            var w = String(part)
            if stopWords.contains(w) || w.allSatisfy(\.isNumber) { continue }
            if w.count > 4, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }
            if !stopWords.contains(w) { out.insert(w) }
        }
        return out
    }

    /// The title without the tracker's prefix and a short platform lead ("iOS: ", "Android: ").
    public static func bareTitle(_ title: String, prefix: String = "") -> String {
        var t = title.trimmingCharacters(in: .whitespaces)
        if !prefix.isEmpty, t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        if let r = t.range(of: #"^[^:]{1,20}:\s+"#, options: .regularExpression) { t = String(t[r.upperBound...]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func dice(_ a: Set<String>, _ b: Set<String>) -> Double {
        a.isEmpty || b.isEmpty ? 0 : 2 * Double(a.intersection(b).count) / Double(a.count + b.count)
    }

    public static func score(_ p: DuplicateProposal, _ c: DuplicateCandidate) -> (score: Double, verdict: DuplicateVerdict, reasons: [String]) {
        let tp = bareTitle(p.title), tc = bareTitle(c.title)
        let wp = words(tp), wc = words(tc)
        let t = !tp.isEmpty && tp.lowercased() == tc.lowercased() ? 1 : dice(wp, wc)
        let shared = wp.intersection(wc).sorted()
        var reasons: [String] = []
        if !shared.isEmpty { reasons.append("title words: " + shared.joined(separator: ", ")) }
        var score = t
        if !p.text.isEmpty, !c.text.isEmpty {
            score = 0.7 * t + 0.3 * dice(wp.union(words(p.text)), wc.union(words(c.text)))
        }
        let sameParent = p.parent != nil && p.parent == c.parent
        if sameParent {
            score += 0.1
            reasons.append("same parent #\(p.parent!)")
        }
        let mentioned = c.number.map { p.refs.contains($0) } ?? false
        if mentioned {
            score += 0.15
            reasons.append("the proposal mentions #\(c.number!)")
        }
        score = (min(score, 1) * 100).rounded() / 100
        if shared.count < 2, t < 1, !(sameParent && !shared.isEmpty) { score = min(score, possible - 0.01) }
        let verdict: DuplicateVerdict = score >= likely ? .likely : (score >= possible || mentioned) ? .possible : .none
        return (score, verdict, reasons)
    }

    public struct ScopeInfo: Equatable, Sendable {
        public var project: String
        public var wide: Bool
        public init(project: String, wide: Bool) {
            self.project = project
            self.wide = wide
        }
    }

    /// Whether items of `others` can duplicate work in `scope`: the same scope, or the project-wide scope of the same
    /// project on either side. Another platform's scope (its twin) can't.
    public static func sameFamily(_ scope: String, _ others: [String], info: [String: ScopeInfo]) -> Bool {
        if others.contains(scope) { return true }
        let mine = info[scope] ?? ScopeInfo(project: scope, wide: false)
        let theirs = others.map { info[$0] ?? ScopeInfo(project: $0, wide: false) }
        guard !theirs.isEmpty, theirs.allSatisfy({ $0.project == mine.project }) else { return false }
        return mine.wide || theirs.allSatisfy(\.wide)
    }

    /// The proposal's best matches among the candidates of its scope. Its parent, related items and the ones the user
    /// said aren't duplicates are left out.
    public static func check(_ p: DuplicateProposal, candidates: [DuplicateCandidate], info: [String: ScopeInfo],
                             limit: Int = 3) -> DuplicateFinding {
        var skip = Set(p.related + p.dismissed + [p.id])
        if let parent = p.parent { skip.insert(String(parent)) }
        var seen = Set<String>()
        var matches: [DuplicateMatch] = []
        for c in candidates {
            let key = c.number.map(String.init) ?? c.id
            guard !skip.contains(key), !skip.contains(c.id), seen.insert("\(c.kind.rawValue):\(key)").inserted,
                  sameFamily(p.scope, c.scopes, info: info) else { continue }
            let s = score(p, c)
            if s.verdict != .none { matches.append(DuplicateMatch(candidate: c, score: s.score, verdict: s.verdict, reasons: s.reasons)) }
        }
        matches.sort { ($0.score, $1.id) > ($1.score, $0.id) }
        matches = Array(matches.prefix(limit))
        return DuplicateFinding(id: p.id, scope: p.scope, title: p.title, verdict: matches.first?.verdict ?? .none, matches: matches)
    }

    /// One pool from the tracker cache, the CLI's search and the KB: a work item found twice is kept once, the richer
    /// copy (with text and parent) first; a created entry only when its work item isn't in the pool.
    public static func pool(tracker: [DuplicateCandidate], searched: [DuplicateCandidate], entries: [DuplicateCandidate]) -> [DuplicateCandidate] {
        var out: [DuplicateCandidate] = []
        var numbers = Set<Int>()
        for c in searched + tracker where c.kind == .workItem {
            guard let n = c.number, numbers.insert(n).inserted else { continue }
            out.append(c)
        }
        for c in entries where c.kind != .workItem {
            if c.kind == .entry, let n = c.number, numbers.contains(n) { continue }
            out.append(c)
        }
        return out
    }

    /// Created and proposed backlog entries as candidates.
    public static func candidate(entry e: KBEntry) -> DuplicateCandidate? {
        let status = e.backlogStatus
        guard status == .proposed || status == .created, !e.isDraft else { return nil }
        let wi = e.field("work_item")
        return DuplicateCandidate(kind: status == .created ? .entry : .proposal, id: e.id.rawValue,
                                  number: status == .created ? wi.flatMap { Int($0) } : nil, title: e.title,
                                  state: status == .created ? "created" : "proposed", type: e.backlogKind,
                                  url: e.field("url") ?? "", scopes: [e.project],
                                  parent: WorkItemLinks.parentNumber(e.field("parent")),
                                  text: String((e.summary + " " + e.body).prefix(1500)))
    }
}
