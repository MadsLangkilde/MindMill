import AppKit
import KBCore
import KBEngine
import SwiftUI

struct FollowupCloseRequest: Identifiable, Equatable {
    var id: EntryID { entry }
    let entry: EntryID
}

struct BacklogCreateRequest: Identifiable, Equatable {
    var id: EntryID { entry }
    let entry: EntryID
}

struct ProjectSettingsRequest: Identifiable, Equatable {
    var id: String { project }
    let project: String
    var tab: ProjectSettingsTab = .tracker
}

enum ProjectSettingsTab: String, Hashable {
    case tracker, conventions, sources
}

struct NewMeetingRequest: Identifiable, Equatable {
    let id = UUID()
    let project: String
    /// Opens on "Now": a meeting that starts as soon as it is created.
    var quick = false
}

extension AppModel {
    // MARK: Sections

    /// The sidebar order: Inbox first while it has entries.
    func hasOverview(project: String) -> Bool { index.count(project: project, section: .overview) > 0 }

    func settings(for project: String) -> ProjectSettings {
        ProjectSettings.load(project: project, root: rootURL)
    }

    // MARK: Windows

    func openMeeting(_ id: EntryID) {
        if id.project != projectID {
            navigate { [self] in setProject(id.project) }
        }
        openWindowAction?("meeting", id.rawValue)
    }

    /// One controller per open meeting window, created on first use so a restored window never waits for `onAppear`.
    func meetingController(for id: EntryID) -> MeetingController {
        if let c = meetingControllers[id] { return c }
        let c = MeetingController(id: id, model: self)
        meetingControllers[id] = c
        return c
    }

    func closeMeetingController(_ id: EntryID) {
        meetingControllers.removeValue(forKey: id)?.close()
    }

    func openAsk() {
        openWindowAction?("ask", nil)
    }

    // MARK: URLs and diagnostics

    /// `kb://today[?date=]`, `kb://meeting?id=[&action=prepare|notes]`, `kb://ask`, `kb://claude[?about=<id>[&run=create-pbi]|?q=]`, `kb://settings?project=&tab=`, `kb://new-meeting`, `kb://reminders[?new]`, `kb://goals[?id=&action=suggest]`, `kb://sync[?what=email|calendar]`.
    func handleWorkflowURL(host: String, items: [URLQueryItem]) -> Bool {
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch host {
        case "today":
            navigate { [self] in
                if let d = value("date"), KBDate.isISODate(d) { setDailyDate(d) }
                sidebarSelection = .today
                closeDocument()
            }
            return true
        case "meeting":
            guard let raw = value("id"), let id = EntryID(raw), id.section == .meetings, index.entry(id) != nil else {
                errorMessage = "No meeting with id \(value("id") ?? "")."
                return true
            }
            switch value("action") {
            case "prepare": prepareMeeting(id)
            case "notes": takeNotes(id)
            default: openMeeting(id)
            }
            return true
        case "claude":
            if let raw = value("about"), let id = EntryID(raw), index.entry(id) != nil {
                Task { [self] in
                    for _ in 0..<60 where shell == nil { try? await Task.sleep(for: .milliseconds(250)) }
                    if value("run") == "create-pbi" { createWorkItem(from: id) } else {
                        workWithClaude(.entry(id, title: index.entry(id)?.title ?? id.stem))
                    }
                }
            } else if let q = value("q") {
                Task { [self] in
                    for _ in 0..<60 where shell == nil { try? await Task.sleep(for: .milliseconds(250)) }
                    newSession(message: q)
                }
            } else {
                openSessions()
            }
            return true
        case "ask":
            if let p = value("project"), index.project(p) != nil, p != projectID { navigate { [self] in setProject(p) } }
            openAsk()
            if let q = value("q"), let p = value("project") ?? projectID {
                Task { [self] in
                    for _ in 0..<60 where shell == nil { try? await Task.sleep(for: .milliseconds(250)) }
                    conversation(for: p).ask(q, model: self)
                }
            }
            return true
        case "settings":
            let p = value("project") ?? projectID
            if let p, index.project(p) != nil {
                projectSettingsRequest = ProjectSettingsRequest(project: p, tab: ProjectSettingsTab(rawValue: value("tab") ?? "") ?? .tracker)
            }
            return true
        case "reminders":
            navigate { [self] in
                sidebarSelection = .reminders
                closeDocument()
            }
            if value("new") != nil { newReminder() }
            return true
        case "goals":
            navigate { [self] in
                sidebarSelection = .goals
                closeDocument()
                if let id = value("id") { selectedGoalID = id.hasPrefix("goals/") ? id : "goals/\(id)" }
            }
            if value("action") == "suggest", let id = value("id") {
                Task { [self] in
                    for _ in 0..<60 where shell == nil { try? await Task.sleep(for: .milliseconds(250)) }
                    if let g = goals.first(where: { $0.id == id || $0.stem == id }) { sendToGoalCoach(g, "Suggest next steps") }
                }
            }
            return true
        case "sync":
            let what = value("what")
            Task { [self] in
                for _ in 0..<60 where shell == nil { try? await Task.sleep(for: .milliseconds(250)) }
                if what != "calendar" { syncEmail() }
                if what != "email" { syncCalendar() }
            }
            return true
        case "new-meeting":
            if let p = projectID { newMeetingRequest = NewMeetingRequest(project: p) }
            return true
        default:
            return false
        }
    }

    func performEntryAction(_ action: String, id: EntryID) {
        switch action {
        case "edit": isEditing = true
        case "done": followupCloseRequest = FollowupCloseRequest(entry: id)
        case "create": backlogCreateRequest = BacklogCreateRequest(entry: id)
        case "meeting": openMeeting(id)
        default: break
        }
    }

    // MARK: Today

    func setDailyDate(_ date: String) {
        if date != dailyDate { selectToday(nil) }
        dailyDate = date
        loadTodayHidden()
        reload()
    }

    func stepDailyDate(by days: Int) {
        guard let d = KBDate.parse(dailyDate), let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: d) else { return }
        setDailyDate(KBDate.today(next))
    }

    func setChecked(_ item: DailyPlan.Item, done: Bool) {
        do { try engine.setPlanItem(item, date: dailyDate, done: done) } catch { errorMessage = error.localizedDescription }
    }

    func runMorningRoutine() { engine.routines.runMorning(date: dailyDate) }

    // MARK: CLI actions

    func runCLI(_ ids: [EntryID], success: String?, _ work: @escaping (KBCLI, EntryID) async throws -> Void) {
        let cli = cli
        for id in ids {
            busyEntries.insert(id)
            if document?.id == id, document?.isDirty == true { save() }
        }
        Task {
            var failures: [String] = []
            for id in ids {
                do { try await work(cli, id) } catch { failures.append(error.localizedDescription) }
                busyEntries.remove(id)
            }
            reload()
            if !failures.isEmpty {
                errorMessage = failures.joined(separator: "\n\n")
            } else if let success {
                notice = success
            }
        }
    }

    func approveInbox(_ ids: [EntryID]) {
        inboxSelection.subtract(ids)
        runCLI(ids, success: ids.count == 1 ? "Approved." : "Approved \(ids.count) entries.") { cli, id in
            _ = try await cli.approveInbox(id)
        }
    }

    func rejectInbox(_ ids: [EntryID]) {
        inboxSelection.subtract(ids)
        runCLI(ids, success: ids.count == 1 ? "Rejected." : "Rejected \(ids.count) entries.") { cli, id in
            try await cli.rejectInbox(id)
        }
    }

    func closeFollowup(_ id: EntryID, status: FollowupStatus, resolvedBy: String?, answer: String?) {
        runCLI([id], success: status == .done ? "Marked done." : status == .open ? "Reopened." : "Dropped.") { cli, id in
            try await cli.closeFollowup(id, status: status, resolvedBy: resolvedBy, answer: answer)
        }
    }

    /// `parent` nil leaves it to the entry and its text; empty means none.
    func createBacklog(_ id: EntryID, sprint: Sprint, parent: String? = nil) {
        busyEntries.insert(id)
        if document?.id == id, document?.isDirty == true { save() }
        Task {
            do {
                let created = try await engine.backlog.create(id, sprint: sprint, parent: parent)
                notice = created.map { "Created work item \($0.id)." } ?? "Created."
            } catch {
                errorMessage = error.localizedDescription
            }
            busyEntries.remove(id)
            reload()
        }
    }

    /// Asks the CLI what else the delete would change, then shows the confirmation.
    func requestDelete(_ id: EntryID) {
        let title = index.entry(id)?.title ?? id.rawValue
        let cli = cli
        Task {
            do {
                deleteRequest = DeleteRequest(entry: id, title: title, effects: try await cli.deletePlan(id))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func confirmDelete() {
        guard let request = deleteRequest else { return }
        deleteRequest = nil
        let id = request.entry
        if document?.id == id { closeDocument() }
        if id.section == .meetings { closeMeetingController(id) }
        inboxSelection.remove(id)
        busyEntries.insert(id)
        let cli = cli
        Task {
            do {
                try await cli.deleteEntry(id)
                notice = "Deleted “\(request.title)”."
            } catch {
                errorMessage = error.localizedDescription
            }
            busyEntries.remove(id)
            reload()
        }
    }

    func rejectBacklog(_ id: EntryID) {
        runCLI([id], success: "Rejected.") { [engine] _, id in try await engine.backlog.reject(id) }
    }

    // MARK: Ask

    func conversation(for project: String) -> AskConversation {
        if let c = askConversations[project] { return c }
        let c = AskConversation(project: project)
        askConversations[project] = c
        return c
    }

    /// Enabled sources for a project: its own, then the global ones.
    func configuredSources(project: String) -> [(source: KnowledgeSource, scope: SourceScope)] {
        settings(for: project).sources.map { ($0, SourceScope.project) } + GlobalSources.load(root: rootURL).map { ($0, SourceScope.global) }
    }
}
