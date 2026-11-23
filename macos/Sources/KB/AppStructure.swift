import Foundation
import KBCore

/// The sidebar of each mode as data: what the Mac shows, in the user's order, for `app.structure` on the phone.
extension AppModel {
    /// A KB section's sidebar badge: what still waits on the user. `needsYou` when it shows prominently (facts that
    /// changed or are proposed, a full inbox).
    func sidebarBadge(_ section: KBSection, project: String) -> (count: Int, needsYou: Bool) {
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
        case .decisions: return (entries().filter { $0.status == .proposed }.count, false)
        case .meetings:
            let today = KBDate.today()
            return (entries().filter { $0.meetingNeedsAttention(today: today) }.count, false)
        default: return (0, false)
        }
    }

    static let planningOrderKey = "sidebarPlanningOrder"
    static let workOrderKey = "sidebarWorkOrder"

    func appStructure(scope: String?) -> JSONValue {
        loadSessionsIfNeeded()
        loadMeetingChatsIfNeeded()
        let scope = scope.flatMap { index.project($0) != nil ? $0 : nil } ?? projectID
        return ["scope": scope.map(JSONValue.string) ?? .null,
                "modes": [
                    ["id": "plan", "title": "Plan", "sections": .array(planStructure(scope: scope))],
                    ["id": "build", "title": "Build", "sections": .array(buildStructure())],
                ]]
    }

    private static func row(_ id: String, _ title: String, _ icon: String, group: String? = nil, count: Int? = nil,
                            needsYou: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "title": .string(title), "icon": .string(icon)]
        if let group { o["group"] = .string(group) }
        if let count, count > 0 { o["count"] = .number(Double(count)) }
        if let needsYou, needsYou > 0 { o["needsYou"] = .number(Double(needsYou)) }
        return .object(o)
    }

    private func planStructure(scope: String?) -> [JSONValue] {
        let open = dailyPlan?.today.filter { $0.done == false && !$0.notRelevant && todayShows($0) }.count ?? 0
        var out: [JSONValue] = [
            Self.row("today", "Today", "sun.max", count: open),
            Self.row("reminders", "Reminders", "bell", count: dueReminders.count + proposedReminders.count, needsYou: dueReminders.count),
            Self.row("goals", "Goals", "mountain.2", count: activeGoals.count),
        ]
        guard let scope else { return out }
        let pending = index.group(of: scope).map { pendingFindings(group: $0.id) } ?? 0
        out.append(Self.row("project", "Project", "shippingbox", count: pending, needsYou: pending))
        let items = planItems(scope: scope).filter { !isArchived($0) }
        out.append(Self.row("sessions", "Sessions", "bubble.left.and.text.bubble.right", count: items.count,
                            needsYou: items.filter(needsYou).count))
        if hasOverview(project: scope) { out.append(Self.row("overview", "Overview", "doc.text")) }
        let defaults = UserDefaults.standard
        for (group, key, keys) in [("Planning", Self.planningOrderKey, SidebarOrder.planning), ("Work", Self.workOrderKey, SidebarOrder.work)] {
            for k in SidebarOrder.resolve(SidebarOrder.decode(defaults.string(forKey: key) ?? ""), defaults: keys) {
                if k == "pullRequests" {
                    let waiting = pullRequests?.needingAnswers ?? 0
                    out.append(Self.row(k, "Pull Requests", "arrow.triangle.pull", group: group, count: waiting))
                } else if let section = KBSection(rawValue: k) {
                    let badge = sidebarBadge(section, project: scope)
                    out.append(Self.row(k, section.title, SidebarView.icon(section), group: group, count: badge.count,
                                        needsYou: badge.needsYou ? badge.count : nil))
                }
            }
        }
        return out
    }

    private func buildStructure() -> [JSONValue] {
        var out: [JSONValue] = [Self.row("overview", "Overview", "binoculars.fill", needsYou: overseerNeedsUser ? 1 : 0)]
        out.append(Self.row("factories", "Software Factories", "gearshape.2.fill", count: factories.filter(\.isRunning).count,
                            needsYou: factoryQuestionCount))
        out.append(Self.row("testing", "Testing", "checkmark.seal"))
        let top = topLevelBuildSessions
        for section in ScopeSections.split(top, order: index.projects.map(\.id), scope: { $0.project }) {
            let all = section.items + section.items.flatMap { members(of: $0) }
            let title = section.scope.flatMap { index.project($0)?.title } ?? "No scope"
            out.append(Self.row("scope:" + (section.scope ?? ""), title, "folder", group: "Sessions", count: section.items.count,
                                needsYou: all.filter { $0.crewState.needsUser }.count))
        }
        let archived = archivedBuildSessions.count
        if archived > 0 { out.append(Self.row("archived", "Archived", "archivebox", count: archived)) }
        return out
    }
}
