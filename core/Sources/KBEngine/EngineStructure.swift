import Foundation
import KBCore

/// What `app.structure` needs that the knowledge base alone doesn't say: sessions, factories, pull requests, scans.
/// The host fills it in (`MindmillEngine.structureExtras`); left at its defaults, those rows show no badge.
public struct StructureExtras {
    /// Open items of today's plan the user sees; nil counts every open item.
    public var todayOpen: Int?
    /// Scan findings waiting in the scope's project.
    public var projectPending = 0
    /// Plan → Sessions in the scope: items and how many wait for the user.
    public var planSessions = 0
    public var planSessionsNeedYou = 0
    public var pullRequestsWaiting = 0
    public var overseerNeedsYou = false
    public var factoriesRunning = 0
    public var factoryQuestions = 0
    /// Build's session rows: one per scope with sessions (nil: no scope), in the user's order.
    public var buildScopes: [(scope: String?, count: Int, needsYou: Int)] = []
    public var archivedBuild = 0

    public init() {}
}

/// The sidebar of each mode as data: what the app shows, in the user's order (`app.structure` in remote-api.md).
extension MindmillEngine {
    public static let planningOrderKey = "sidebarPlanningOrder"
    public static let workOrderKey = "sidebarWorkOrder"

    public func factChangeCount(project: String) -> Int {
        index.entries(project: project, section: .inbox).filter(\.isFactChange).count
    }

    /// A KB section's sidebar badge: what still waits on the user. `needsYou` when it shows prominently (facts that
    /// changed or are proposed, a full inbox).
    public func sidebarBadge(_ section: KBSection, project: String) -> (count: Int, needsYou: Bool) {
        let changes = factChangeCount(project: project)
        let proposed = factProposals(project: project).count
        let total = index.count(project: project, section: section) - (section == .inbox ? changes + proposed : 0)
        if section == .facts, changes + proposed > 0 { return (changes + proposed, true) }
        if section == .inbox { return (total, total > 0) }
        let entries = { self.index.entries(project: project, section: section).filter { !$0.isDraft } }
        switch section {
        case .followups: return (entries().filter { $0.followupStatus == .open }.count, false)
        case .backlog: return (entries().filter { $0.backlogStatus == .proposed }.count, false)
        case .discussions: return (entries().filter { $0.discussionStatus == .open && $0.waitingOn == "me" }.count, false)
        case .research: return (entries().filter { $0.researchStatus == .review }.count, false)
        case .notes: return (entries().filter { $0.noteStatus == .open }.count, false)
        case .decisions: return (entries().filter { $0.status == .proposed }.count, false)
        case .meetings:
            let today = KBDate.today()
            return (entries().filter { $0.meetingNeedsAttention(today: today) }.count, false)
        default: return (0, false)
        }
    }

    public func appStructure(scope: String?) -> JSONValue {
        let scope = scope.flatMap { index.project($0) != nil ? $0 : nil } ?? self.scope
        let extras = structureExtras(scope)
        return ["scope": scope.map(JSONValue.string) ?? .null,
                "modes": [
                    ["id": "plan", "title": "Plan", "sections": .array(planStructure(scope: scope, extras))],
                    ["id": "build", "title": "Build", "sections": .array(buildStructure(extras))],
                ]]
    }

    public static func structureRow(_ id: String, _ title: String, _ icon: String, group: String? = nil, count: Int? = nil,
                                    needsYou: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(title), "icon": .string(icon)]
        if let group { o["group"] = .string(group) }
        if let count, count > 0 { o["count"] = .number(Double(count)) }
        if let needsYou, needsYou > 0 { o["needsYou"] = .number(Double(needsYou)) }
        return .object(o)
    }

    private func planStructure(scope: String?, _ x: StructureExtras) -> [JSONValue] {
        let open = x.todayOpen ?? DailyPlan.load(date: KBDate.today(), root: rootURL)?.today
            .filter { $0.done == false && !$0.notRelevant }.count ?? 0
        let reminders = Reminders.load(root: rootURL)
        let due = reminders.filter { $0.isDue() }.count
        let proposed = reminders.filter { $0.status == .proposed }.count
        let goals = Goals.load(root: rootURL).filter { $0.status == .active }.count
        var out: [JSONValue] = [
            Self.structureRow("today", "Today", "sun.max", count: open),
            Self.structureRow("reminders", "Reminders", "bell", count: due + proposed, needsYou: due),
            Self.structureRow("goals", "Goals", "mountain.2", count: goals),
        ]
        guard let scope else { return out }
        out.append(Self.structureRow("project", "Project", "shippingbox", count: x.projectPending, needsYou: x.projectPending))
        out.append(Self.structureRow("sessions", "Sessions", "bubble.left.and.text.bubble.right", count: x.planSessions,
                                     needsYou: x.planSessionsNeedYou))
        if index.count(project: scope, section: .overview) > 0 { out.append(Self.structureRow("overview", "Overview", "doc.text")) }
        let defaults = platform.defaults
        for (group, key, keys) in [("Planning", Self.planningOrderKey, SidebarOrder.planning), ("Work", Self.workOrderKey, SidebarOrder.work)] {
            for k in SidebarOrder.resolve(SidebarOrder.decode(defaults.string(forKey: key) ?? ""), defaults: keys) {
                if k == "pullRequests" {
                    out.append(Self.structureRow(k, "Pull Requests", "arrow.triangle.pull", group: group, count: x.pullRequestsWaiting))
                } else if let section = KBSection(rawValue: k) {
                    let badge = sidebarBadge(section, project: scope)
                    out.append(Self.structureRow(k, section.title, section.icon, group: group, count: badge.count,
                                                 needsYou: badge.needsYou ? badge.count : nil))
                }
            }
        }
        return out
    }

    private func buildStructure(_ x: StructureExtras) -> [JSONValue] {
        var out: [JSONValue] = [Self.structureRow("overview", "Overview", "binoculars.fill", needsYou: x.overseerNeedsYou ? 1 : 0)]
        out.append(Self.structureRow("factories", "Software Factories", "gearshape.2.fill", count: x.factoriesRunning,
                                     needsYou: x.factoryQuestions))
        out.append(Self.structureRow("testing", "Testing", "checkmark.seal"))
        for row in x.buildScopes {
            let title = row.scope.flatMap { index.project($0)?.title } ?? "No scope"
            out.append(Self.structureRow("scope:" + (row.scope ?? ""), title, "folder", group: "Sessions", count: row.count,
                                         needsYou: row.needsYou))
        }
        if x.archivedBuild > 0 { out.append(Self.structureRow("archived", "Archived", "archivebox", count: x.archivedBuild)) }
        return out
    }
}

extension KBSection {
    /// The SF Symbol the Mac shows for the section; phones and Windows map it to their own icons.
    public var icon: String {
        switch self {
        case .overview: return "doc.text"
        case .decisions: return "checkmark.seal"
        case .meetings: return "person.2"
        case .facts: return "lightbulb"
        case .architecture: return "building.columns"
        case .followups: return "checklist"
        case .backlog: return "list.bullet.rectangle"
        case .discussions: return "bubble.left.and.bubble.right"
        case .ideas: return "lightbulb.max"
        case .research: return ResearchStatus.icon
        case .references: return "bookmark"
        case .notes: return "note.text"
        case .inbox: return "tray.and.arrow.down"
        }
    }
}
