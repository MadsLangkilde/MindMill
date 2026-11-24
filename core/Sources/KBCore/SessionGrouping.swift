import Foundation

/// One lead per piece of work: when several top-level Build sessions are about the same work item or pull request,
/// one leads it and the others go under it.
public enum SessionGrouping {
    public struct Candidate: Equatable, Sendable {
        public var id: String
        /// The work it is about, with a pull request mapped to its work item.
        public var work: String?
        public var role: SessionRole
        public var created: Date
        /// Started on the work item itself, rather than on its pull request's comments or a review.
        public var implements: Bool

        public init(id: String, work: String?, role: SessionRole, created: Date, implements: Bool = false) {
            self.id = id
            self.work = work
            self.role = role
            self.created = created
            self.implements = implements
        }
    }

    /// The session that leads the work: a lead already, then the one implementing the work item, then the oldest.
    public static func main(of sessions: [Candidate]) -> Candidate? {
        sessions.filter { $0.role == .lead || $0.role == .solo }.min { a, b in
            if (a.role == .lead) != (b.role == .lead) { return a.role == .lead }
            if a.implements != b.implements { return a.implements }
            return a.created < b.created
        }
    }

    /// For each piece of work with more than one top-level session: the one leading it and those to move under it.
    public static func plan(_ sessions: [Candidate]) -> [(lead: String, members: [String])] {
        let top = sessions.filter { $0.role == .lead || $0.role == .solo }
        return Dictionary(grouping: top.filter { $0.work != nil }) { $0.work ?? "" }
            .values
            .filter { $0.count > 1 }
            .compactMap { group -> (lead: String, members: [String])? in
                guard let lead = main(of: group) else { return nil }
                return (lead.id, group.filter { $0.id != lead.id }.sorted { $0.created < $1.created }.map(\.id))
            }
            .sorted { $0.lead < $1.lead }
    }
}

/// Build's session list split by scope: one section per scope that has sessions, in registry order, then scopes
/// the registry no longer knows, then sessions without a scope. Each section keeps the sessions' order.
public enum ScopeSections {
    public static func split<T>(_ items: [T], order: [String], scope: (T) -> String?) -> [(scope: String?, items: [T])] {
        var buckets: [String: [T]] = [:]
        var unknownOrder: [String] = []
        var none: [T] = []
        for item in items {
            guard let s = scope(item), !s.isEmpty else { none.append(item); continue }
            if buckets[s] == nil, !order.contains(s) { unknownOrder.append(s) }
            buckets[s, default: []].append(item)
        }
        var out: [(scope: String?, items: [T])] = []
        for s in order + unknownOrder { if let b = buckets[s] { out.append((s, b)) } }
        if !none.isEmpty { out.append((nil, none)) }
        return out
    }
}
