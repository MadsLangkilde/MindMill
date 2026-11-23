import KBCore
import SwiftUI

/// What is selected in the Today list: a meeting or other entry, a reminder, or a line of the plan.
enum TodaySelection: Hashable {
    case entry(EntryID)
    case reminder(String)
    case item(Int)
}

extension AppModel {
    func setTodayAllScopes(_ on: Bool) {
        todayAllScopes = on
        UserDefaults.standard.set(on, forKey: "todayAllScopes")
    }

    /// The scopes Today shows: the selected scope with what it includes, and its project-wide scope. `nil` is all.
    var todayScopes: Set<String>? {
        guard !todayAllScopes, let p = projectID, index.project(p) != nil else { return nil }
        var out = index.members(of: p)
        if let g = index.group(of: p), let wide = g.scopes.first(where: { index.project($0)?.wide == true }) { out.insert(wide) }
        return out
    }

    /// A `[scope]` tag that names a known scope is shown only in that scope; `[reminder]`, `[goal]` and none show everywhere.
    func todayShows(tag: String?, scopes: Set<String>? = nil) -> Bool {
        guard let visible = scopes ?? todayScopes else { return true }
        guard let tag, index.project(tag) != nil else { return true }
        return visible.contains(tag)
    }

    func todayShows(_ item: DailyPlan.Item) -> Bool {
        guard let visible = todayScopes else { return true }
        if let tag = item.project, index.project(tag) != nil { return visible.contains(tag) }
        if let id = linkedEntry(item), let e = index.entry(id) { return visible.contains(e.project) || e.scopes.contains { visible.contains($0) } }
        return true
    }

    func todayShows(meeting e: KBEntry) -> Bool {
        guard let visible = todayScopes else { return true }
        return visible.contains(e.project) || e.scopes.contains { visible.contains($0) }
    }

    func todayShows(_ r: Reminder) -> Bool { todayShows(tag: r.project) }

    private var hiddenMeetingsKey: String { "todayHiddenMeetings.\(dailyDate)" }

    func loadTodayHidden() {
        todayHiddenMeetings = Set(UserDefaults.standard.stringArray(forKey: hiddenMeetingsKey) ?? [])
    }

    /// Sets a meeting aside for the day, or brings it back.
    func setMeetingNotRelevant(_ id: EntryID, _ on: Bool) {
        if on { todayHiddenMeetings.insert(id.rawValue) } else { todayHiddenMeetings.remove(id.rawValue) }
        UserDefaults.standard.set(todayHiddenMeetings.sorted(), forKey: hiddenMeetingsKey)
        if on, todaySelection == .entry(id) { selectToday(nil) }
    }

    /// Marks a plan line not relevant, restores it, or removes it from the day's file.
    func markPlanItem(_ item: DailyPlan.Item, _ mark: DailyPlan.Mark) {
        do {
            try DailyPlan.setMark(date: dailyDate, lineText: item.lineText, mark, root: rootURL)
            if mark == .removed || mark == .notRelevant, todaySelection == .item(item.id) { selectToday(nil) }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var todaySelectionBinding: Binding<TodaySelection?> {
        Binding(get: { self.todaySelection }, set: { self.selectToday($0) })
    }

    var dailyPlanItems: [DailyPlan.Item] {
        guard let p = dailyPlan else { return [] }
        return p.today + p.toDecide + p.sideGoal
    }

    func linkedReminder(_ item: DailyPlan.Item) -> Reminder? {
        guard let ref = item.ref else { return nil }
        return reminders.first { $0.id == ref }
    }

    func linkedEntry(_ item: DailyPlan.Item) -> EntryID? {
        guard let ref = item.ref, let id = EntryID(ref), index.entry(id) != nil else { return nil }
        return id
    }

    /// A plan line is done when it is ticked, or when the reminder or follow-up it points to is closed.
    func isDone(_ item: DailyPlan.Item) -> Bool {
        if item.done == true { return true }
        if let r = linkedReminder(item) { return r.status == .done || r.status == .dismissed }
        if let id = linkedEntry(item), id.section == .followups, let s = index.entry(id)?.followupStatus { return s != .open }
        return false
    }

    /// Shows the selection's details in the content area, staying on Today.
    func selectToday(_ selection: TodaySelection?) {
        guard selection != todaySelection else { return }
        navigate { [self] in
            todaySelection = selection
            var entry: EntryID?
            switch selection {
            case .entry(let id): entry = id
            case .item(let line): entry = dailyPlanItems.first { $0.line == line }.flatMap(linkedEntry)
            default: break
            }
            if let entry { openNow(entry) } else { closeDocument() }
        }
    }
}

/// The content area while Today is selected: the selected item, or the morning routine.
struct TodayDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.todaySelection {
        case .reminder(let id):
            if let r = model.reminders.first(where: { $0.id == id }) { ReminderDetailView(reminder: r) } else { MorningPanel() }
        case .item(let line):
            if let item = model.dailyPlanItems.first(where: { $0.line == line }) {
                if let r = model.linkedReminder(item) { ReminderDetailView(reminder: r) } else { TodayItemDetail(item: item) }
            } else {
                MorningPanel()
            }
        default:
            MorningPanel()
        }
    }
}

/// A plan line that points at nothing in the KB, such as a work item or a plain task.
struct TodayItemDetail: View {
    @Environment(AppModel.self) private var model
    let item: DailyPlan.Item

    var body: some View {
        let done = model.isDone(item)
        let title = String(item.text.prefix(60))
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(InlineMarkdown.attributed(item.text))
                    .font(.title2.weight(.semibold))
                    .strikethrough(done)
                    .textSelection(.enabled)
                ChipRow(spacing: 8) {
                    Chip(text: done ? "Done" : "Planned", color: done ? .green : .secondary)
                    ProjectChip(project: item.project)
                    if let ref = item.ref { RefLink(ref: ref).font(.callout) }
                }
                HStack(spacing: 8) {
                    Button(done ? "Mark Not Done" : "Mark Done") { model.setChecked(item, done: !done) }
                    if let ref = item.ref, let url = RefLink.url(ref, model: model) {
                        Link(destination: url) { Label(ref.hasPrefix("ado:") ? "Open in Azure DevOps" : "Open Link", systemImage: "arrow.up.right.square") }
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Button {
                        model.askAbout(.text(item.text, title: title, project: item.project))
                    } label: { Label("Ask \(Brain.name) About This…", systemImage: "sparkles") }
                    Button {
                        model.workWithClaude(.text(item.text, title: title, project: item.project))
                    } label: { Label("Work on It with \(Brain.name)…", systemImage: "hammer") }
                }
                Text("From today's plan, daily/\(model.dailyDate).md.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
