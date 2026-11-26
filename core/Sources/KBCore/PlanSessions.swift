import Foundation

/// What a Plan session is for, so Plan's Sessions page can group them. The order is the page's.
public enum PlanSessionKind: String, CaseIterable, Sendable {
    case assistant, workItems, notes, research, ideas, discussions, followups, meetings, goals, entries, questions

    public var title: String {
        switch self {
        case .assistant: return "Assistant"
        case .workItems: return "Work items"
        case .notes: return "Notes"
        case .research: return "Research"
        case .ideas: return "Ideas"
        case .discussions: return "Discussions"
        case .followups: return "Follow-ups"
        case .meetings: return "Meetings"
        case .goals: return "Goals"
        case .entries: return "On entries"
        case .questions: return "Questions"
        }
    }

    public var icon: String {
        switch self {
        case .assistant: return "wand.and.stars"
        case .workItems: return "plus.rectangle.on.rectangle"
        case .notes: return NoteStatus.icon
        case .research: return ResearchStatus.icon
        case .ideas: return "lightbulb.max"
        case .discussions: return "bubble.left.and.bubble.right"
        case .followups: return "checklist"
        case .meetings: return "person.2"
        case .goals: return "mountain.2"
        case .entries: return "doc.text"
        case .questions: return "questionmark.bubble"
        }
    }
}

public enum PlanSessions {
    /// `about` prefixes of sessions started from a research, an idea or a discussion; the entry id follows.
    static let prefixes: [(String, PlanSessionKind)] = [("research:", .research), ("idea:", .ideas), ("discussion:", .discussions), ("note:", .notes)]
    /// The plugin was called `kb` before `mindmill`; older sessions start with `/kb:`.
    static let pluginPrefixes = ["/mindmill:", "/kb:"]
    static let skills: [(String, PlanSessionKind)] = pluginPrefixes.flatMap { p in
        [(p + "research", PlanSessionKind.research), (p + "idea", .ideas), (p + "discussion", .discussions), (p + "notes", .notes)]
    }

    /// Where it was started, before what it does: the assistant, a research, idea or discussion; then creating PBIs
    /// or bugs (by title or by what was asked); then the kind of entry it works on, a goal, or a skill it ran;
    /// else a question.
    public static func kind(title: String, about: String?, firstMessage: String) -> PlanSessionKind {
        if about == SessionRecord.assistantAbout { return .assistant }
        if let about, let k = prefixes.first(where: { about.hasPrefix($0.0) }) { return k.1 }
        let t = title.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("PBI:") || t.hasPrefix("PBIs:") { return .workItems }
        let text = (t + "\n" + firstMessage).lowercased()
        if pluginPrefixes.contains(where: { firstMessage.contains($0 + "create-pbi") || firstMessage.contains($0 + "work-item") }) { return .workItems }
        let creates = ["create", "make", "write", "split", "opret", "lav"].contains { text.contains($0) }
        let items = ["pbi", "bug", "work item", "workitem", "user stor"].contains { text.contains($0) }
        if creates && items { return .workItems }
        if let about, about.hasPrefix(goalPrefix) { return .goals }
        if let id = about.flatMap(EntryID.init) {
            switch id.section {
            case .research: return .research
            case .ideas: return .ideas
            case .notes: return .notes
            case .discussions: return .discussions
            case .followups: return .followups
            case .meetings: return .meetings
            default: return .entries
            }
        }
        if let k = skills.first(where: { firstMessage.hasPrefix($0.0) }) { return k.1 }
        return .questions
    }

    static let goalPrefix = "goals/"

    /// What a session was started from: the entry (or goal) in its `about`, without the research/idea/discussion
    /// prefix. Work items, pull requests and the assistant have none.
    public static func origin(about: String?) -> String? {
        guard var a = about else { return nil }
        if let p = prefixes.first(where: { a.hasPrefix($0.0) }) { a = String(a.dropFirst(p.0.count)) }
        if a.hasPrefix(goalPrefix) || EntryID(a) != nil { return a }
        return nil
    }

    /// Whether a Plan session belongs on `scope`'s Sessions page: it has no scope, it is in the scope or one the
    /// scope includes, or it works on an entry the scope shows (an entry tagged with the scope counts).
    public static func shows(project: String?, about: String?, in scope: String, index: KBIndex) -> Bool {
        guard let project else { return true }
        if index.members(of: scope).contains(project) { return true }
        guard let id = origin(about: about).flatMap(EntryID.init), let entry = index.entry(id) else { return false }
        return index.shows(entry, in: scope)
    }

    /// Plan's Sessions page: recent ones by kind, newest first; the rest under Older; archived ones last. Running
    /// ones and those that need the user count as recent however old they are.
    public struct Groups<Item> {
        public var sections: [(kind: PlanSessionKind, items: [Item])] = []
        public var older: [Item] = []
        public var archived: [Item] = []
    }

    public static let recentDays = 14

    public static func group<Item>(_ items: [Item], now: Date = Date(), kind: (Item) -> PlanSessionKind,
                                   updated: (Item) -> Date, archived: (Item) -> Bool, active: (Item) -> Bool) -> Groups<Item> {
        let cutoff = now.addingTimeInterval(-Double(recentDays) * 86_400)
        let sorted = items.sorted { updated($0) > updated($1) }
        var g = Groups<Item>()
        g.archived = sorted.filter(archived)
        let open = sorted.filter { !archived($0) }
        let recent = open.filter { updated($0) > cutoff || active($0) }
        g.older = open.filter { !(updated($0) > cutoff || active($0)) }
        for k in PlanSessionKind.allCases {
            let list = recent.filter { kind($0) == k }
            if !list.isEmpty { g.sections.append((k, list)) }
        }
        return g
    }

    /// The work items a session created, in order: from Azure DevOps links and `kb backlog create`'s
    /// "created <id> <url>" line.
    public static func createdItems(_ texts: [String]) -> [Int] {
        var out: [Int] = []
        let patterns = [#"_workitems/edit/(\d{3,9})"#, #"(?m)^created (\d{3,9}) https?://"#]
        for text in texts {
            for p in patterns {
                guard let re = try? NSRegularExpression(pattern: p) else { continue }
                for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let r = Range(m.range(at: 1), in: text), let id = Int(text[r]), !out.contains(id) { out.append(id) }
                }
            }
        }
        return out
    }
}

extension WorkItemDetail {
    /// Enough of a work item to implement it from a Plan session that just created it.
    public func asMyWork(scope: String) -> MyWork.Item {
        let s = state.lowercased()
        let stage: MyWork.Stage = ["new", "approved", "to do", "proposed"].contains(s) ? .notStarted
            : ["resolved", "done", "closed"].contains(s) ? .resolved : .inProgress
        return MyWork.Item(id: id, type: type.lowercased() == "bug" ? "bug" : "pbi", title: title, state: state,
                           sprint: iteration, project: scope, url: url, stage: stage, prs: [])
    }
}
