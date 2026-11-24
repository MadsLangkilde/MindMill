import Foundation

/// Whose move a follow-up is. With no owner it is the user's own; `waiting_on` someone else, or an owner who isn't the
/// user, means the user is waiting on others.
public enum FollowupResponsibility: String, CaseIterable, Sendable {
    case me, others

    /// `me` holds the names the user goes by (display name, e-mail); "me" itself always counts.
    public static func of(owner: String?, waitingOn: String?, me: [String]) -> FollowupResponsibility {
        if let w = waitingOn?.trimmingCharacters(in: .whitespaces), !w.isEmpty, !isMe(w, me: me) { return .others }
        guard let o = owner?.trimmingCharacters(in: .whitespaces), !o.isEmpty else { return .me }
        return isMe(o, me: me) ? .me : .others
    }

    public static func isMe(_ name: String, me: [String]) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n == "me" { return true }
        return me.contains { m in
            let x = m.trimmingCharacters(in: .whitespaces).lowercased()
            guard !x.isEmpty else { return false }
            // "Amy Brown" matches "amy brown <ab@…>" and the mail's local part matches its address.
            return n == x || n.hasPrefix(x + " <") || (x.contains("@") && n == x.split(separator: "@").first.map(String.init))
        }
    }
}

extension KBEntry {
    public func responsibility(me: [String]) -> FollowupResponsibility {
        FollowupResponsibility.of(owner: field("owner"), waitingOn: field("waiting_on"), me: me)
    }

    /// Where the follow-up came from: one meeting or fact, or several after merging.
    public var raisedIn: [String] { listField("raised_in").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

/// A suggestion that two open follow-ups say the same thing, from `followup-merges.json` in the knowledge base's home folder.
public struct FollowupMergeProposal: Codable, Equatable, Sendable, Identifiable {
    public var keep: String
    public var other: String
    public var why: String?
    public var date: String?

    public var id: String { "\(keep)|\(other)" }

    public static func url(root: URL) -> URL { KBLayout.home(root: root).appendingPathComponent("followup-merges.json") }

    /// The proposals whose follow-ups are both still open.
    public static func load(root: URL, index: KBIndex) -> [FollowupMergeProposal] {
        struct File: Decodable { var proposals: [FollowupMergeProposal]? }
        guard let data = try? Data(contentsOf: url(root: root)),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return (file.proposals ?? []).filter { p in
            [p.keep, p.other].allSatisfy { raw in
                EntryID(raw).flatMap { index.entry($0) }.map { $0.followupStatus == .open } ?? false
            }
        }
    }
}

/// Facts linked to each other with `related:`. A link is written on one fact and holds both ways.
extension KBIndex {
    public func linkedFacts(of id: EntryID) -> [KBEntry] {
        var out: [EntryID] = entry(id)?.listField("related").compactMap(EntryID.init) ?? []
        for e in entries.values where e.section == .facts && e.id != id && e.listField("related").contains(id.rawValue) {
            out.append(e.id)
        }
        var seen: Set<EntryID> = []
        return out.filter { $0 != id && seen.insert($0).inserted }.compactMap { entry($0) }
    }

    /// Every link between facts once, as pairs ordered by id.
    public func factLinks(among ids: Set<EntryID>? = nil) -> [(EntryID, EntryID)] {
        var seen: Set<String> = []
        var out: [(EntryID, EntryID)] = []
        for e in entries.values where e.section == .facts && (ids?.contains(e.id) ?? true) {
            for raw in e.listField("related") {
                guard let other = EntryID(raw), other != e.id, entry(other) != nil, ids?.contains(other) ?? true else { continue }
                let (a, b) = e.id.rawValue < other.rawValue ? (e.id, other) : (other, e.id)
                if seen.insert("\(a.rawValue)|\(b.rawValue)").inserted { out.append((a, b)) }
            }
        }
        return out.sorted { ($0.0.rawValue, $0.1.rawValue) < ($1.0.rawValue, $1.1.rawValue) }
    }
}

/// A fact Claude thinks is related, and why, before the user accepts or rejects it.
public struct FactLinkSuggestion: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var why: String

    public init(id: String, why: String) {
        self.id = id
        self.why = why
    }

    /// `[{"id": "...", "why": "..."}]` anywhere in Claude's reply; ids that aren't candidates are dropped.
    public static func parse(_ reply: String, candidates: Set<String>) -> [FactLinkSuggestion] {
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"), start < end,
              let list = try? JSONDecoder().decode([FactLinkSuggestion].self, from: Data(reply[start...end].utf8)) else { return [] }
        var seen: Set<String> = []
        return list.filter { candidates.contains($0.id) && seen.insert($0.id).inserted }
    }
}
