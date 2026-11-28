import AppKit
import KBCore
import KBEngine
import SwiftUI

/// A Plan conversation that lives in its own place rather than in a session: a meeting's chat, a goal's coach, or
/// Ask. Plan → Sessions lists it with the sessions; opening it goes to that place.
struct LinkedConversation: Identifiable {
    enum Place: String { case meeting, goals, ask }
    let place: Place
    /// The meeting entry, the goal, or Ask's scope.
    let target: String
    let title: String
    let project: String?
    let kind: PlanSessionKind
    let updated: Date
    let count: Int
    let busy: Bool

    var id: String { Self.id(place, target) }
    static func id(_ place: Place, _ target: String) -> String { "link:\(place.rawValue):\(target)" }
    var origin: String? { place == .ask ? nil : target }
}

/// A row of Plan → Sessions.
@MainActor
enum PlanItem: Identifiable {
    case session(WorkSession)
    case linked(LinkedConversation)

    nonisolated var id: String {
        switch self {
        case .session(let s): return s.id
        case .linked(let c): return c.id
        }
    }

    var kind: PlanSessionKind {
        switch self {
        case .session(let s): return s.planKind
        case .linked(let c): return c.kind
        }
    }

    var updated: Date {
        switch self {
        case .session(let s): return s.updated
        case .linked(let c): return c.updated
        }
    }

    var project: String? {
        switch self {
        case .session(let s): return s.project
        case .linked(let c): return c.project
        }
    }

    var about: String? {
        switch self {
        case .session(let s): return s.about
        case .linked(let c): return c.origin
        }
    }

    var origin: String? { PlanSessions.origin(about: about) }

    var title: String {
        switch self {
        case .session(let s): return s.title
        case .linked(let c): return c.title
        }
    }

    var isRunning: Bool {
        switch self {
        case .session(let s): return s.chat.isRunning
        case .linked(let c): return c.busy
        }
    }
}

extension AppModel {
    var planSessions: [WorkSession] { engine.sessions.planSessions }

    var planSessionsNeedingUser: [WorkSession] { planSessions.filter { $0.archived != true && $0.crewState.needsUser } }

    /// The Plan session that created this work item, for "Planned in" on its Build session.
    func planSession(creating item: Int) -> WorkSession? { engine.sessions.planSession(creating: item) }

    func openPlanSession(_ s: WorkSession) {
        mode = .plan
        if sidebarSelection != .sessions { selectSidebar(.sessions) }
        selectedSessionID = s.id
    }

    /// A created work item, ready to implement, when it is known: from My Work, the backlog, or looked up.
    func implementable(_ id: Int, scope: String?) -> MyWork.Item? {
        if let item = myWork?.items.first(where: { $0.id == id }) { return item }
        if let item = workItem(id) { return item.asMyWork }
        if let d = workItemDetails[id], let scope { return d.asMyWork(scope: scope) }
        return nil
    }

    // MARK: Conversations that aren't sessions

    private var meetingChatsDirectory: URL {
        AppPaths.instanceData.appendingPathComponent("meeting-chats", isDirectory: true)
    }

    /// Reads which meetings have a chat, once; `MeetingController` keeps it current after that.
    func loadMeetingChatsIfNeeded() {
        guard !meetingChatsLoaded else { return }
        meetingChatsLoaded = true
        struct Saved: Decodable { var messages: [Message]; struct Message: Decodable {} }
        let files = (try? FileManager.default.contentsOfDirectory(at: meetingChatsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var found: [EntryID: (count: Int, updated: Date)] = [:]
        for url in files where url.pathExtension == "json" {
            guard let id = EntryID(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "__", with: "/")),
                  let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data),
                  !saved.messages.isEmpty else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            found[id] = (saved.messages.count, date)
        }
        meetingChats = found
    }

    func meetingChatSaved(_ id: EntryID, count: Int) {
        guard meetingChats[id]?.count != count else { return }
        meetingChats[id] = count == 0 ? nil : (count, Date())
    }

    var linkedConversations: [LinkedConversation] {
        var out: [LinkedConversation] = []
        for (id, chat) in meetingChats {
            out.append(LinkedConversation(place: .meeting, target: id.rawValue, title: "Meeting: " + (index.entry(id)?.title ?? id.stem),
                                          project: id.project, kind: .meetings, updated: chat.updated, count: chat.count,
                                          busy: meetingControllers[id]?.chat.isBusy ?? false))
        }
        for (id, updated) in goalCoachUpdated {
            guard let chat = goalChats[id], !chat.items.isEmpty else { continue }
            let title = goals.first { $0.id == id }?.title ?? String(id.dropFirst("goals/".count))
            out.append(LinkedConversation(place: .goals, target: id, title: "Goal coach: " + title, project: nil, kind: .goals,
                                          updated: updated, count: chat.items.count, busy: chat.isBusy))
        }
        for (scope, c) in askConversations where !c.turns.isEmpty {
            let q = c.turns.last?.question ?? ""
            out.append(LinkedConversation(place: .ask, target: scope, title: "Ask: " + (q.count > 80 ? String(q.prefix(77)) + "…" : q),
                                          project: scope, kind: .questions, updated: c.updated, count: c.turns.count,
                                          busy: c.chat.isBusy))
        }
        return out
    }

    func openLinked(_ c: LinkedConversation) {
        switch c.place {
        case .meeting:
            if let id = EntryID(c.target) { openMeeting(id) }
        case .goals:
            selectSidebar(.goals)
            selectedGoalID = c.target
        case .ask:
            if projectID != c.target, index.project(c.target) != nil { selectProject(c.target) }
            openAsk()
        }
    }

    // MARK: The list

    /// Every Plan conversation, in `scope` as its Sessions page shows it, or all of them.
    func planItems(scope: String?) -> [PlanItem] {
        let items = planSessions.map(PlanItem.session) + linkedConversations.map(PlanItem.linked)
        guard let scope else { return items }
        return items.filter { PlanSessions.shows(project: $0.project, about: $0.about, in: scope, index: index) }
    }

    func planItem(_ id: String?) -> PlanItem? {
        guard let id else { return nil }
        if let s = session(id), s.space == .plan { return .session(s) }
        return linkedConversations.first { $0.id == id }.map(PlanItem.linked)
    }

    func isArchived(_ item: PlanItem) -> Bool {
        switch item {
        case .session(let s): return s.archived == true
        case .linked(let c): return (planArchivedLinks[c.id] ?? 0) >= c.updated.timeIntervalSince1970
        }
    }

    func needsYou(_ item: PlanItem) -> Bool {
        guard case .session(let s) = item else { return false }
        return s.archived != true && s.crewState.needsUser
    }

    func planGroups(scope: String?) -> PlanSessions.Groups<PlanItem> {
        PlanSessions.group(planItems(scope: scope), kind: \.kind, updated: \.updated, archived: { self.isArchived($0) },
                           active: { $0.isRunning || self.needsYou($0) })
    }

    func setArchived(_ item: PlanItem, _ on: Bool) {
        switch item {
        case .session(let s):
            setArchived(s, on)
        case .linked(let c):
            planArchivedLinks[c.id] = on ? max(Date().timeIntervalSince1970, c.updated.timeIntervalSince1970) : nil
        }
    }
}

/// Plan → Sessions: every Plan conversation of this scope (or every scope), by where it was started.
struct PlanSessionsList: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    @AppStorage("planSessionsAllScopes") private var allScopes = false

    var body: some View {
        @Bindable var model = model
        let groups = model.planGroups(scope: allScopes ? nil : project.id)
        VStack(spacing: 0) {
            FlowLayout(spacing: 8, centered: true) {
                Picker("Show", selection: $allScopes) {
                    Text(project.title).tag(false)
                    Text("All scopes").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button {
                    let s = model.newSession(project: project.id, show: false)
                    model.selectedSessionID = s.id
                } label: { Label("New Session", systemImage: "square.and.pencil") }
                .help("A new \(Brain.name) session in \(project.title)")
                Button {
                    Task { _ = await model.assistantSession(scope: project.id, new: true, show: true) }
                } label: { Label("Assistant", systemImage: "wand.and.stars") }
                .help("A session that can do anything in Mindmill for you: start a meeting, make a factory, change a setting… (⌥⌘A)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List(selection: $model.selectedSessionID) {
                if groups.sections.isEmpty && groups.older.isEmpty {
                    ListEmptyState(title: groups.archived.isEmpty ? "No sessions yet" : "No open sessions",
                                   systemImage: "bubble.left.and.text.bubble.right",
                                   message: "Every \(Brain.name) conversation in Plan shows here, wherever you started it: creating PBIs and bugs, a research, an idea, a discussion, a follow-up, a meeting, a goal, or a question.")
                }
                PlanSessionSections(groups: groups, scope: allScopes ? nil : project.id)
            }
            .listStyle(.inset)
        }
        .onAppear {
            model.loadSessionsIfNeeded()
            model.loadMeetingChatsIfNeeded()
        }
    }
}

/// The sections of Plan → Sessions and the Sessions window: by kind, then Older and Archived, folded.
struct PlanSessionSections: View {
    @Environment(AppModel.self) private var model
    let groups: PlanSessions.Groups<PlanItem>
    /// The scope listed; rows from other scopes (or every row, when nil) say which scope they are in.
    var scope: String?
    var inSessionsWindow = false
    private var showOlder: Bool {
        get { model.foldStates["plansessions.older"] ?? false }
        nonmutating set { model.foldStates["plansessions.older"] = newValue }
    }
    private var showArchived: Bool {
        get { model.foldStates["plansessions.archived"] ?? false }
        nonmutating set { model.foldStates["plansessions.archived"] = newValue }
    }

    var body: some View {
        ForEach(groups.sections, id: \.kind) { section in
            Section {
                ForEach(section.items) { row($0) }
            } header: {
                Label("\(section.kind.title) · \(section.items.count)", systemImage: section.kind.icon)
            }
        }
        if !groups.older.isEmpty {
            FoldableSection(isExpanded: model.fold("plansessions.older")) {
                ForEach(groups.older) { row($0) }
            } header: {
                Text("Older · \(groups.older.count)")
            }
        }
        if !groups.archived.isEmpty {
            FoldableSection(isExpanded: model.fold("plansessions.archived")) {
                ForEach(groups.archived) { row($0) }
            } header: {
                Text("Archived · \(groups.archived.count)")
            }
        }
    }

    @ViewBuilder
    private func row(_ item: PlanItem) -> some View {
        switch item {
        case .session(let s):
            PlanSessionRow(session: s, showScope: scope == nil || s.project != scope)
                .tag(s.id)
                .contextMenu {
                    if !inSessionsWindow {
                        Button("Open in Its Own Window") {
                            model.selectedSessionID = s.id
                            model.openSessions()
                        }
                    }
                    Button("Continue in Terminal") { model.openSessionInTerminal(s) }
                    if !s.isResearchSession, !s.isAssistant { Button("Move to Build") { model.moveToBuild(s) } }
                    Divider()
                    archiveButton(item)
                    Button("Delete", role: .destructive) { model.deleteSession(s) }
                }
        case .linked(let c):
            Button { model.openLinked(c) } label: {
                LinkedConversationRow(conversation: c, showScope: scope == nil || c.project != scope)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(c.place == .meeting ? "Open Meeting" : c.place == .goals ? "Open Goal" : "Open Ask") { model.openLinked(c) }
                Divider()
                archiveButton(item)
            }
        }
    }

    @ViewBuilder
    private func archiveButton(_ item: PlanItem) -> some View {
        if model.isArchived(item) {
            Button("Move Out of the Archive") { model.setArchived(item, false) }
        } else {
            Button("Archive") { model.setArchived(item, true) }
        }
    }
}

/// In a Plan session's header, beside Strategy: archive it, or take it out of the archive.
struct PlanArchiveButton: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession

    var body: some View {
        let archived = session.archived == true
        Button {
            model.setArchived(PlanItem.session(session), !archived)
        } label: {
            Label(archived ? "Unarchive" : "Archive", systemImage: archived ? "tray.and.arrow.up" : "archivebox")
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help(archived ? "Take it out of the archive in Plan → Sessions" : "Move it to Archived in Plan → Sessions. A new message brings it back.")
    }
}

/// A meeting's chat, a goal's coach or Ask in Plan → Sessions: where it lives, and opening it goes there.
struct LinkedConversationRow: View {
    @Environment(AppModel.self) private var model
    let conversation: LinkedConversation
    var showScope = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: conversation.kind.icon).font(.caption).foregroundStyle(.secondary)
                .frame(width: 10).padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                ChipRow(spacing: 5) {
                    if conversation.busy { StatusPill(status: .running, compact: true) }
                    Chip(text: place, color: .secondary)
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var place: String {
        switch conversation.place {
        case .meeting: return "In the meeting window"
        case .goals: return "In Goals"
        case .ask: return "In Ask"
        }
    }

    private var caption: String {
        var parts: [String] = []
        if showScope { parts.append(conversation.project.flatMap { model.index.project($0)?.title } ?? "Every scope") }
        parts.append(RelativeTime.short(conversation.updated))
        return parts.joined(separator: " · ")
    }
}

struct PlanSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession
    var showScope = false

    var body: some View {
        let state = session.crewState
        HStack(alignment: .top, spacing: 8) {
            StateDot(state: state).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                ChipRow(spacing: 5) {
                    if state.needsUser {
                        StatusPill(status: state == .blocked ? .needsPermission : .needsInput, compact: true)
                    } else if state == .working {
                        StatusPill(status: .running, compact: true)
                    }
                    if session.planKind == .workItems {
                        let created = session.createdItems
                        if created.isEmpty {
                            Chip(text: "Drafting", color: .secondary)
                        } else {
                            ForEach(created, id: \.self) { id in Chip(text: "Created #\(id)", color: .green) }
                        }
                    }
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var caption: String {
        var parts: [String] = []
        if showScope { parts.append(session.project.flatMap { model.index.project($0)?.title } ?? "Knowledge base") }
        parts.append(RelativeTime.short(session.updated))
        return parts.joined(separator: " · ")
    }
}

/// In a Plan session that created work items: each one, with Implement to start it in Build.
struct CreatedItemsBar: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession
    @State private var showAll = false

    var body: some View {
        let ids = session.createdItems
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(showAll ? ids : Array(ids.prefix(2)), id: \.self) { id in itemRow(id) }
                if ids.count > 2 {
                    Button(showAll ? "Show fewer" : "Show all \(ids.count) created work items") { showAll.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Color.green.opacity(0.07))
            Divider()
        }
    }

    private func itemRow(_ id: Int) -> some View {
        let scope = session.project ?? model.projectID
        let item = model.implementable(id, scope: scope)
        let building = model.sessions(forKey: "wi:\(id)").first
        return AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 200) {
            Image(systemName: "checkmark.rectangle.stack.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Created #\(String(id))" + (item.map { ": \($0.title)" } ?? "")).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let item { Text(item.state).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if let url = item.flatMap({ URL(string: $0.url) }) { Link("Azure DevOps", destination: url) }
                if let building {
                    Button("Open in Build") { model.openSession(building) }
                } else if let item {
                    Button("Implement…") { model.startImplement(item, show: true) }
                        .buttonStyle(.borderedProminent)
                        .help("Start it in Build; the Build session links back to this conversation")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .fixedSize()
        }
        .onAppear { if item == nil, let scope { model.loadWorkItemDetail(id, scope: scope) } }
    }
}

/// On a Build session whose work item was created in Plan: a way back to that conversation.
struct PlannedInLink: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession

    var body: some View {
        if session.space == .build, let about = session.about, about.hasPrefix("wi:"), let id = Int(about.dropFirst(3)),
           let plan = model.planSession(creating: id) {
            Button { model.openPlanSession(plan) } label: {
                Label("Planned in “\(plan.title)”", systemImage: "arrow.uturn.backward.circle")
                    .lineLimit(1)
            }
            .buttonStyle(.link)
            .font(.caption)
            .help("Open the Plan session that created #\(id)")
        }
    }
}
