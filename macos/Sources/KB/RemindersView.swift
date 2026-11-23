import KBCore
import SwiftUI

struct ReminderSheetRequest: Identifiable, Equatable {
    let id = UUID()
    /// Nil for a new reminder.
    var editing: Reminder?
    var project: String?
}

extension AppModel {
    var dueReminders: [Reminder] { reminders.filter { $0.isDue() } }
    var proposedReminders: [Reminder] { reminders.filter { $0.status == .proposed } }

    func newReminder() { reminderSheet = ReminderSheetRequest(editing: nil, project: nil) }

    func setReminder(_ r: Reminder, status: Reminder.Status) {
        do { try Reminders.setStatus(r, status) } catch { errorMessage = error.localizedDescription }
        reload()
    }

    func setReminder(_ r: Reminder, due: String) {
        do {
            try Reminders.setDue(r, due)
            if r.status == .done || r.status == .dismissed { try Reminders.setStatus(r, .open) }
        } catch { errorMessage = error.localizedDescription }
        notice = due.isEmpty ? "No due date." : "Due \(DateText.display(due))."
        reload()
    }

    func deleteReminder(_ r: Reminder) {
        do { try Reminders.delete(r) } catch { errorMessage = error.localizedDescription }
        if selectedReminderID == r.id { selectedReminderID = nil }
        reload()
    }

    /// Dismisses an email reminder and tells the email scan to skip that sender from now on.
    func dismissAndIgnoreSender(_ r: Reminder) {
        setReminder(r, status: .dismissed)
        guard let sender = r.fromDomain ?? r.from else { return }
        let cli = cli
        Task {
            do {
                try await cli.run(["email", "ignore", sender])
                notice = "Dismissed. Mail from \(sender) is skipped from now on."
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

/// Due-date choices: today, tomorrow, a week from now, or any date.
struct DueDatePicker: View {
    @Binding var due: String
    @State private var custom = false

    var body: some View {
        let q = Reminders.quickDates()
        VStack(alignment: .leading, spacing: 8) {
            let quick = ["", q.today, q.tomorrow, q.nextWeek]
            Picker("Due", selection: Binding(
                get: { custom ? "custom" : quick.contains(due) ? due : "custom" },
                set: { v in
                    if v == "custom" {
                        custom = true
                        if due.isEmpty { due = q.today }
                    } else {
                        custom = false
                        due = v
                    }
                }
            )) {
                Text("No date").tag("")
                Text("Today").tag(q.today)
                Text("Tomorrow").tag(q.tomorrow)
                Text("In a week").tag(q.nextWeek)
                Text("Pick a date").tag("custom")
            }
            .pickerStyle(.segmented)
            if custom || !quick.contains(due) {
                DatePicker("", selection: Binding(
                    get: { KBDate.parse(due) ?? Date() },
                    set: { due = KBDate.today($0) }
                ), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            Text(due.isEmpty ? "No due date" : DateText.display(due)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ReminderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ReminderSheetRequest
    @State private var title = ""
    @State private var note = ""
    @State private var due = KBDate.today()
    @State private var project = ""
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.editing == nil ? "New Reminder" : "Edit Reminder").font(.title2.weight(.semibold))
            TextField("What do you need to do?", text: $title).font(.title3)
            DueDatePicker(due: $due)
            Picker("Scope", selection: $project) {
                Text("None (personal)").tag("")
                ForEach(model.index.projects, id: \.id) { Text($0.title).tag($0.id) }
            }
            TextField("Link (optional)", text: $link)
            VStack(alignment: .leading, spacing: 4) {
                Text("Note").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .font(.body)
                    .frame(minHeight: 70, maxHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.editing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || !(due.isEmpty || KBDate.isISODate(due)))
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 460)
        .onAppear {
            if let r = request.editing {
                title = r.title
                note = r.note
                due = r.due
                project = r.project ?? ""
                link = r.link?.absoluteString ?? ""
            } else {
                project = request.project ?? ""
            }
        }
    }

    private func save() {
        do {
            if let r = request.editing {
                try Reminders.update(r) { e in
                    e.frontmatter.set("title", .string(title.trimmingCharacters(in: .whitespaces)))
                    e.frontmatter.set("due", due.isEmpty ? nil : .string(due))
                    e.frontmatter.set("project", project.isEmpty ? nil : .string(project))
                    e.frontmatter.set("link", link.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .string(link.trimmingCharacters(in: .whitespaces)))
                    e.note = note
                }
            } else {
                let r = try Reminders.create(title: title, due: due, note: note, project: project.isEmpty ? nil : project,
                                             link: link, root: model.rootURL)
                model.notice = r.hasDue ? "Reminder added, due \(DateText.display(r.due))." : "Reminder added."
            }
            dismiss()
            model.reload()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

/// One reminder: tick, title, due, project, and what can be done with it.
struct ReminderRow: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        let r = reminder
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if r.status == .proposed {
                Image(systemName: r.isFromEmail ? "envelope.badge" : "sparkles").foregroundStyle(.purple)
            } else {
                Button {
                    model.setReminder(r, status: r.status == .done ? .open : .done)
                } label: {
                    Image(systemName: r.status == .done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(r.status == .done ? Color.green : r.isOverdue() ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .help(r.status == .done ? "Mark not done" : "Mark done")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title)
                    .strikethrough(r.status == .done || r.status == .dismissed)
                    .foregroundStyle(r.status == .done || r.status == .dismissed ? .secondary : .primary)
                ChipRow(spacing: 6) {
                    Text(dueText(r)).foregroundStyle(r.isOverdue() ? .red : .secondary)
                    if let p = r.project { ProjectChip(project: p).fixedSize() }
                    if let from = r.from { Text("· \(from)").foregroundStyle(.secondary).lineLimit(1) }
                }
                .font(.caption)
                if r.status == .proposed {
                    if let reason = r.reason { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    HStack(spacing: 6) {
                        Button("Add") { model.setReminder(r, status: .open) }.buttonStyle(.borderedProminent)
                        Button("Dismiss") { model.setReminder(r, status: .dismissed) }
                        if r.fromDomain != nil || r.from != nil {
                            Button("Never from \(r.fromDomain ?? r.from ?? "")") { model.dismissAndIgnoreSender(r) }
                                .help("Dismiss, and have the email scan skip this sender from now on")
                        }
                    }
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            if let link = r.link {
                Link(destination: link) { Image(systemName: r.isFromEmail ? "envelope" : "link") }
                    .help(r.isFromEmail ? "Open the email" : link.absoluteString)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu { ReminderMenu(reminder: r) }
    }

    private func dueText(_ r: Reminder) -> String {
        guard !r.due.isEmpty else { return "No date" }
        let today = KBDate.today()
        if r.due == today { return "Today" }
        if r.due == Reminders.quickDates().tomorrow { return "Tomorrow" }
        return (r.due < today && r.status == .open ? "Overdue · " : "") + DateText.display(r.due)
    }
}

struct ReminderMenu: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        let q = Reminders.quickDates()
        Button("Ask \(Brain.name) About This…") { model.askAbout(.reminder(reminder)) }
        Button("Work on It with \(Brain.name)…") { model.workWithClaude(.reminder(reminder)) }
        Divider()
        Menu("Due") {
            Button("Today") { model.setReminder(reminder, due: q.today) }
            Button("Tomorrow") { model.setReminder(reminder, due: q.tomorrow) }
            Button("In a Week") { model.setReminder(reminder, due: q.nextWeek) }
            Button("No Date") { model.setReminder(reminder, due: "") }
                .disabled(!reminder.hasDue)
            Button("Pick a Date…") { model.reminderSheet = ReminderSheetRequest(editing: reminder) }
        }
        Button("Edit…") { model.reminderSheet = ReminderSheetRequest(editing: reminder) }
        if reminder.status == .open {
            Button("Mark Done") { model.setReminder(reminder, status: .done) }
        } else {
            Button("Reopen") { model.setReminder(reminder, status: .open) }
        }
        if reminder.status != .dismissed {
            Button("Not Relevant") { model.setReminder(reminder, status: .dismissed) }
        }
        Divider()
        Button("Delete", role: .destructive) { model.deleteReminder(reminder) }
    }
}

/// The content column for Reminders: proposed first, then overdue, today, upcoming, and recently done.
struct RemindersView: View {
    @Environment(AppModel.self) private var model
    @State private var showDone = false

    var body: some View {
        let today = KBDate.today()
        let query = model.listQuery(.reminders)
        let all = query.isEmpty ? model.reminders : model.reminders.filter { $0.matches(query) }
        let proposed = all.filter { $0.status == .proposed }
        let open = all.filter { $0.status == .open }
        let overdue = open.filter { $0.hasDue && $0.due < today }
        let dueToday = open.filter { $0.due == today }
        let upcoming = open.filter { $0.hasDue && $0.due > today }
        let undated = open.filter { !$0.hasDue }
        let done = all.filter { $0.status == .done }.sorted { ($0.frontmatter.string("done") ?? "") > ($1.frontmatter.string("done") ?? "") }
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reminders").font(.title3.weight(.semibold)).lineLimit(1)
                    Text("Personal · all scopes").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                EmailSyncButton().buttonStyle(.borderless)
                Button { model.newReminder() } label: { Label("New Reminder", systemImage: "plus").labelStyle(.iconOnly) }
                    .help("New reminder (⌥⌘R)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ListSearchField(key: .reminders, prompt: "Search reminders")
            Divider()
            List(selection: Binding(get: { model.selectedReminderID }, set: { model.selectedReminderID = $0 })) {
                if !query.isEmpty && all.isEmpty { ListSearchNoMatch(query: query) }
                if !proposed.isEmpty {
                    Section("Suggested by \(Brain.name)") { ForEach(proposed) { ReminderRow(reminder: $0).tag($0.id) } }
                }
                if !overdue.isEmpty {
                    Section("Overdue") { ForEach(overdue) { ReminderRow(reminder: $0).tag($0.id) } }
                }
                if query.isEmpty || !dueToday.isEmpty {
                    Section("Today") {
                        if dueToday.isEmpty { Text("Nothing due today.").foregroundStyle(.secondary).font(.callout) }
                        ForEach(dueToday) { ReminderRow(reminder: $0).tag($0.id) }
                    }
                }
                if !upcoming.isEmpty {
                    Section("Upcoming") { ForEach(upcoming) { ReminderRow(reminder: $0).tag($0.id) } }
                }
                if !undated.isEmpty {
                    Section("No date") { ForEach(undated) { ReminderRow(reminder: $0).tag($0.id) } }
                }
                if !done.isEmpty {
                    FoldableSection(isExpanded: Binding(get: { showDone || !query.isEmpty }, set: { showDone = $0 })) {
                        ForEach(done.prefix(query.isEmpty ? 30 : done.count)) { ReminderRow(reminder: $0).tag($0.id) }
                    } header: {
                        Text("Done (\(done.count))")
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationSubtitle("Reminders")
    }
}

/// The detail column for a selected reminder.
struct ReminderDetailView: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

    var body: some View {
        let r = reminder
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(r.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                ChipRow(spacing: 8) {
                    Chip(text: r.status.rawValue.capitalized, color: r.status == .proposed ? .purple : r.isOverdue() ? .red : .secondary)
                    Text(r.due.isEmpty ? "No date" : "Due \(DateText.display(r.due))")
                        .foregroundStyle(r.isOverdue() ? .red : .secondary)
                    if let p = r.project { ProjectChip(project: p).fixedSize() }
                }
                .font(.callout)
                if let from = r.from {
                    Label("From \(from)" + (r.fromDomain.map { " (\($0))" } ?? ""), systemImage: "envelope")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let reason = r.reason {
                    Label(reason, systemImage: "sparkles").font(.callout).foregroundStyle(.secondary)
                }
                if !r.note.isEmpty {
                    Text(InlineMarkdown.attributed(r.note)).textSelection(.enabled)
                }
                if let link = r.link { Link(r.isFromEmail ? "Open the email" : link.absoluteString, destination: link) }
                HStack {
                    if r.status == .proposed {
                        Button("Add") { model.setReminder(r, status: .open) }.buttonStyle(.borderedProminent)
                        Button("Dismiss") { model.setReminder(r, status: .dismissed) }
                    } else if r.status == .open {
                        Button("Mark Done") { model.setReminder(r, status: .done) }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Reopen") { model.setReminder(r, status: .open) }
                    }
                    Button("Edit…") { model.reminderSheet = ReminderSheetRequest(editing: r) }
                    Button { model.askAbout(.reminder(r)) } label: { Label("Ask \(Brain.name)", systemImage: "questionmark.bubble") }
                    Spacer()
                    Button("Delete", role: .destructive) { model.deleteReminder(r) }
                }
                Text(r.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RemindersRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.kbTheme) private var theme

    var body: some View {
        let selected = model.sidebarSelection == .reminders
        let due = model.dueReminders.count
        let proposed = model.proposedReminders.count
        Button {
            model.selectSidebar(.reminders)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bell")
                    .foregroundStyle(selected ? Color.white : theme.sidebarIconColor)
                    .frame(width: 18)
                Text("Reminders").font(.body.weight(.medium))
                Spacer()
                if model.email.isBusy {
                    ProgressView().controlSize(.mini)
                }
                if proposed > 0 {
                    Text("\(proposed) new")
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : .purple)
                }
                if due > 0 {
                    Text("\(due)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : model.reminders.contains { $0.isOverdue() } ? .red : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : .primary)
            .background(selected ? theme.selectionColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .help("Personal reminders, and what \(Brain.name) found in your email")
    }
}
