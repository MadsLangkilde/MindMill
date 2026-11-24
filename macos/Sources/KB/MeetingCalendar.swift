import KBCore
import KBEngine
import SwiftUI

/// Meetings as a month calendar: pick a day to see its meetings; a search lists matches from every day.
struct MeetingsView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    @State private var selected = KBDate.today()
    @State private var month = MonthGrid.month(of: KBDate.today())

    var body: some View {
        let every = model.index.entries(project: project.id, section: .meetings)
        let query = model.listQuery(.section(.meetings))
        let picked = model.tagSelection(.meetings)
        let dated = every.filter { !$0.isDraft && (query.isEmpty || $0.matches(query)) && EntryTags.matches($0.tags, selected: picked) }
        let byDay = Dictionary(grouping: dated, by: \.date)
        let unsaved = model.document.flatMap { $0.isNew && $0.id.project == project.id && $0.id.section == .meetings ? $0 : nil }
        VStack(spacing: 0) {
            CalendarSyncProblem()
            MonthCalendar(month: $month, selected: $selected, meetings: byDay)
            ListSearchField(key: .section(.meetings), prompt: "Search meetings")
            TagFilterBar(key: .meetings, available: every.map(\.tags))
            Divider()
            List(selection: model.entrySelection) {
                if let unsaved { UnsavedRow(document: unsaved).tag(unsaved.id) }
                DraftsSection(drafts: every.filter(\.isDraft))
                if query.isEmpty && picked.isEmpty {
                    Section {
                        let day = (byDay[selected] ?? []).sorted { ($0.field("start") ?? "") < ($1.field("start") ?? "") }
                        if day.isEmpty {
                            Text("No meetings.").foregroundStyle(.secondary).font(.callout)
                        }
                        rows(day)
                        OutlookWeekRow(day: selected)
                    } header: {
                        Text(Self.heading(selected))
                    }
                } else if dated.isEmpty {
                    if query.isEmpty { TagFilterNoMatch(key: .meetings) } else { ListSearchNoMatch(query: query) }
                } else {
                    // Coming up soonest first, then what's over, newest first.
                    let today = KBDate.today()
                    let days = byDay.keys.sorted { a, b in
                        let (fa, fb) = (a >= today, b >= today)
                        return fa != fb ? fa : (fa ? a < b : a > b)
                    }
                    ForEach(days, id: \.self) { d in
                        Section(d.isEmpty ? "No date" : Self.heading(d)) {
                            rows((byDay[d] ?? []).sorted { ($0.field("start") ?? "") < ($1.field("start") ?? "") })
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .navigationSubtitle("Meetings")
        .onChange(of: model.selectedEntryID) { _, id in
            // Opening a meeting from elsewhere (Today, search) shows its day.
            guard let id, id.section == .meetings, let e = model.index.entry(id), KBDate.isISODate(e.date), e.date != selected else { return }
            selected = e.date
            month = MonthGrid.month(of: e.date)
        }
    }

    private func rows(_ entries: [KBEntry]) -> some View {
        ForEach(entries) { EntryRow(entry: $0).tag($0.id).entryContextMenu($0.id) }
    }

    /// "Today, Thursday 12 Nov · week 46" or "Monday 16 Nov · week 47".
    static func heading(_ iso: String) -> String {
        guard let d = KBDate.parse(iso) else { return iso }
        let today = KBDate.today()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMM"
        let name = f.string(from: d)
        let near = DaySections.label(iso, today: today, direction: iso < today ? .past : .future)
        let day = ["Today", "Yesterday", "Tomorrow"].contains(near) ? "\(near), \(name)" : name
        return "\(day) · week \(MonthGrid.weekNumber(iso))"
    }
}

/// The last calendar sync failed for a reason other than signing in: what went wrong, and Try Again.
private struct CalendarSyncProblem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.calendarSync.error, !model.microsoft365NeedsSignIn, !ConnectorSignIn.isNeeded(error),
           !model.calendar.isRunning {
            AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 200) {
                Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.orange)
                Text("The calendar didn't sync: \(error)").font(.callout).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) { Button("Try Again") { model.syncCalendar() } }.fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.orange.opacity(0.10))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// For a day past what the regular sync mirrors: fetch that week from Outlook.
private struct OutlookWeekRow: View {
    @Environment(AppModel.self) private var model
    let day: String

    var body: some View {
        let today = KBDate.today()
        let synced = KBDate.today(Calendar(identifier: .gregorian).date(byAdding: .day, value: AppModel.calendarDaysAhead, to: Date()) ?? Date())
        let week = MonthGrid.week(of: day)
        let sync = model.calendarSync
        let fetching = sync.range.map { $0.from <= day && day <= $0.to } ?? false
        let queued = sync.queued.map { $0.from <= day && day <= $0.to } ?? false
        if day > synced {
            HStack(spacing: 8) {
                if fetching || queued {
                    ProgressView().controlSize(.small)
                    Text(fetching ? "Getting week \(MonthGrid.weekNumber(day)) from Outlook…" : "Week \(MonthGrid.weekNumber(day)) is next in line")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Get Week \(MonthGrid.weekNumber(day)) from Outlook") {
                        model.syncCalendar(from: max(week.from, today), to: week.to)
                    }
                    .help("The calendar keeps two weeks ahead up to date by itself. This adds the meetings of this week.")
                }
            }
            .padding(.vertical, 2)
        } else if fetching, day >= today, sync.range?.from == today {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Updating from Outlook…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// A month of days, Monday first, with a dot per meeting; the selected day is filled, today ringed.
struct MonthCalendar: View {
    @Binding var month: String
    @Binding var selected: String
    let meetings: [String: [KBEntry]]

    private let columns = Array(repeating: GridItem(.flexible(minimum: 26), spacing: 2), count: 7)

    var body: some View {
        let today = KBDate.today()
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button { month = MonthGrid.shift(month: month, by: -1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous month")
                Text(MonthGrid.title(month: month))
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                Button { month = MonthGrid.shift(month: month, by: 1) } label: { Image(systemName: "chevron.right") }
                    .help("Next month")
                Button("Today") {
                    selected = today
                    month = MonthGrid.month(of: today)
                }
                .disabled(selected == today && month == MonthGrid.month(of: today))
            }
            .buttonStyle(.borderless)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(MonthGrid.weekdays, id: \.self) { d in
                    Text(d).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(MonthGrid.days(month: month), id: \.self) { d in
                    DayCell(day: d, inMonth: MonthGrid.month(of: d) == month, isToday: d == today, isSelected: d == selected,
                            meetings: meetings[d] ?? []) {
                        selected = d
                        if MonthGrid.month(of: d) != month { month = MonthGrid.month(of: d) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private struct DayCell: View {
    let day: String
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let meetings: [KBEntry]
    let action: () -> Void

    var body: some View {
        let held = meetings.filter { $0.meetingStatus != .cancelled }
        Button(action: action) {
            VStack(spacing: 2) {
                Text(MonthGrid.dayNumber(day))
                    .font(.callout.weight(isToday || isSelected ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white : isToday ? Color.accentColor : inMonth ? Color.primary : Color.secondary.opacity(0.6))
                    .frame(width: 26, height: 26)
                    .background {
                        if isSelected { Circle().fill(Color.accentColor) }
                        else if isToday { Circle().stroke(Color.accentColor, lineWidth: 1.5) }
                    }
                HStack(spacing: 2) {
                    ForEach(0..<min(held.count, 3), id: \.self) { _ in
                        Circle().fill(inMonth ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.5)).frame(width: 4, height: 4)
                    }
                    if held.count > 3 {
                        Text("+").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(held))
    }

    private func help(_ held: [KBEntry]) -> String {
        guard !held.isEmpty else { return MeetingsView.heading(day) }
        let titles = held.sorted { ($0.field("start") ?? "") < ($1.field("start") ?? "") }
            .prefix(6).map { e in [e.field("start"), e.title].compactMap { $0 }.joined(separator: " ") }
        return ([MeetingsView.heading(day)] + titles).joined(separator: "\n")
    }
}
