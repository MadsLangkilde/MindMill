import KBCore
import KBEngine
import SwiftUI

/// The daily plan across projects. Every item names its project.
struct TodayView: View {
    @Environment(AppModel.self) private var model

    @State private var showNotRelevant = false

    var body: some View {
        let allMeetings = model.meetings(on: model.dailyDate).filter { model.todayShows(meeting: $0) && (query.isEmpty || $0.matches(query)) }
        let meetings = allMeetings.filter { !model.todayHiddenMeetings.contains($0.id.rawValue) }
        let hiddenMeetings = allMeetings.filter { model.todayHiddenMeetings.contains($0.id.rawValue) }
        VStack(spacing: 0) {
            header
            ListSearchField(key: .today, prompt: "Search today")
            if model.dailyDate == KBDate.today(), !model.sprintMoments.isEmpty {
                SprintMomentCards().padding(.horizontal, 14).padding(.bottom, 10)
            }
            Divider()
            if let plan = model.dailyPlan {
                let shown = { (items: [DailyPlan.Item]) in items.filter { model.todayShows($0) && (query.isEmpty || $0.matches(query)) } }
                let today = shown(plan.today), toDecide = shown(plan.toDecide), sideGoal = shown(plan.sideGoal)
                let setAside = (today + toDecide + sideGoal).filter(\.notRelevant)
                List(selection: model.todaySelectionBinding) {
                    meetingsSection(meetings)
                    remindersSection()
                    let rows = today.filter { !$0.notRelevant }
                    if query.isEmpty || !rows.isEmpty {
                        Section("Today") {
                            if rows.isEmpty { Text("Nothing planned.").foregroundStyle(.secondary) }
                            ForEach(rows) { planRow($0, checkable: true) }
                        }
                    }
                    let decide = toDecide.filter { !$0.notRelevant }
                    if !decide.isEmpty {
                        Section("To decide") {
                            ForEach(decide) { planRow($0, checkable: false) }
                        }
                    }
                    let goal = sideGoal.filter { !$0.notRelevant }
                    if !goal.isEmpty {
                        Section {
                            ForEach(goal) { planRow($0, checkable: true).foregroundStyle(.secondary) }
                        } header: {
                            Label("Side goal", systemImage: "mountain.2").foregroundStyle(.green)
                        }
                    }
                    if query.isEmpty {
                        FoldableSection(isExpanded: model.fold("today.proposed")) {
                            ForEach(plan.proposed, id: \.self) { line in
                                Text(InlineMarkdown.attributed(line)).font(.callout).foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Proposed")
                        }
                        Section { WaitingSummary() }
                        if !plan.other.isEmpty {
                            Section("Notes") {
                                Text(InlineMarkdown.attributed(plan.other)).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                    notRelevantSection(items: setAside, meetings: hiddenMeetings)
                }
                .listStyle(.inset)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sun.max").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No plan for \(DateText.display(model.dailyDate))").font(.headline)
                        Text(model.dailyDate == KBDate.today()
                             ? "Run the morning routine to have \(Brain.name) write daily/\(model.dailyDate).md from your calendar, follow-ups and inbox."
                             : "There is no daily/\(model.dailyDate).md.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.dailyDate == KBDate.today() { MorningButton() }
                }
                .padding(14)
                Divider()
                List(selection: model.todaySelectionBinding) {
                    meetingsSection(meetings)
                    remindersSection()
                    if query.isEmpty { Section("Waiting") { WaitingSummary() } }
                    notRelevantSection(items: [], meetings: hiddenMeetings)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationSubtitle("Today")
        .task { model.checkSprints() }
    }

    private var query: String { model.listQuery(.today) }

    private func planRow(_ item: DailyPlan.Item, checkable: Bool) -> some View {
        TodayItemRow(item: item, checkable: checkable)
            .tag(TodaySelection.item(item.id))
            .swipeActions(edge: .trailing) {
                Button("Remove", role: .destructive) { model.markPlanItem(item, .removed) }
                Button("Not Relevant") { model.markPlanItem(item, .notRelevant) }.tint(.gray)
            }
    }

    /// Plan lines, meetings and reminders set aside today, collapsed at the bottom.
    @ViewBuilder
    private func notRelevantSection(items: [DailyPlan.Item], meetings: [KBEntry]) -> some View {
        let today = model.dailyDate
        let reminders = model.reminders.filter { $0.status == .dismissed && $0.due == today && model.todayShows($0) }
        let count = items.count + meetings.count + reminders.count
        if count > 0 {
            FoldableSection(isExpanded: $showNotRelevant) {
                ForEach(meetings) { e in
                    HStack {
                        Image(systemName: "calendar").foregroundStyle(.secondary)
                        Text(e.title).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore") { model.setMeetingNotRelevant(e.id, false) }.buttonStyle(.link).font(.caption)
                    }
                }
                ForEach(reminders) { r in
                    HStack {
                        Image(systemName: "bell").foregroundStyle(.secondary)
                        Text(r.title).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore") { model.setReminder(r, status: .open) }.buttonStyle(.link).font(.caption)
                    }
                }
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        Text(InlineMarkdown.attributed(item.text)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore") { model.markPlanItem(item, .open) }.buttonStyle(.link).font(.caption)
                    }
                    .contextMenu {
                        Button("Restore") { model.markPlanItem(item, .open) }
                        Button("Remove", role: .destructive) { model.markPlanItem(item, .removed) }
                    }
                }
            } header: {
                Text("Not relevant · \(count)")
            }
        }
    }

    @ViewBuilder
    private func remindersSection() -> some View {
        let today = model.dailyDate
        let due = model.reminders.filter { $0.status == .open && !$0.due.isEmpty && $0.due <= today && model.todayShows($0) && (query.isEmpty || $0.matches(query)) }
        let proposed = model.proposedReminders.filter { model.todayShows($0) && (query.isEmpty || $0.matches(query)) }
        Section {
            if due.isEmpty && proposed.isEmpty {
                Text(query.isEmpty ? "Nothing due." : "No reminders match “\(query)”.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(due) { r in
                ReminderRow(reminder: r).tag(TodaySelection.reminder(r.id))
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { model.deleteReminder(r) }
                        Button("Not Relevant") { model.setReminder(r, status: .dismissed) }.tint(.gray)
                    }
            }
            ForEach(proposed.prefix(5)) { r in
                ReminderRow(reminder: r).tag(TodaySelection.reminder(r.id))
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { model.deleteReminder(r) }
                        Button("Dismiss") { model.setReminder(r, status: .dismissed) }.tint(.gray)
                    }
            }
            if proposed.count > 5 {
                Button("\(proposed.count - 5) more suggestions…") { model.selectSidebar(.reminders) }.buttonStyle(.link)
            }
        } header: {
            HStack {
                Text("Reminders")
                Spacer()
                Button { model.newReminder() } label: { Label("New Reminder", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("New reminder (⌥⌘R)")
            }
        }
    }

    @ViewBuilder
    private func meetingsSection(_ meetings: [KBEntry]) -> some View {
        Section {
            if meetings.isEmpty && !query.isEmpty {
                Text("No meetings match “\(query)”.").font(.callout).foregroundStyle(.secondary)
            } else if meetings.isEmpty {
                Text(model.calendar.isRunning ? "Syncing the calendar…" : "No meetings. New meetings in your calendar appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(meetings) { e in
                MeetingDayRow(entry: e).tag(TodaySelection.entry(e.id))
                    .swipeActions(edge: .trailing) {
                        Button("Not Relevant") { model.setMeetingNotRelevant(e.id, true) }.tint(.gray)
                    }
            }
        } header: {
            HStack {
                Text("Meetings")
                Spacer()
                if let p = model.meetingScope {
                    Button {
                        model.startQuickMeeting()
                    } label: {
                        Label("Quick Meeting", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Start a meeting now, at the coffee machine or the desks, in \(model.index.project(p)?.title ?? p) (⇧⌘M)")
                    Menu {
                        Button("Quick Meeting…") { model.newMeetingRequest = NewMeetingRequest(project: p, quick: true) }
                        Button("Plan a Meeting…") { model.newMeetingRequest = NewMeetingRequest(project: p) }
                    } label: {
                        Label("New Meeting", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .controlSize(.small)
                    .help("A meeting that isn't in your calendar: now, with a title and attendees, or planned for later")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.dailyPlan?.title ?? dayTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("\(model.dailyDate == KBDate.today() ? "Today" : model.dailyDate) · \(scopeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if model.projectID != nil {
                Toggle(isOn: Binding(get: { model.todayAllScopes }, set: { model.setTodayAllScopes($0) })) {
                    Image(systemName: "square.stack.3d.up")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(model.todayAllScopes ? "Showing every scope. Click to show only the selected scope." : "Show items from every scope, not just the selected one")
            }
            CalendarSyncButton()
                .buttonStyle(.borderless)
            EmailSyncButton()
                .buttonStyle(.borderless)
                .padding(.trailing, 4)
            ControlGroup {
                Button { model.stepDailyDate(by: -1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous day")
                Button("Today") { model.setDailyDate(KBDate.today()) }
                    .disabled(model.dailyDate == KBDate.today())
                Button { model.stepDailyDate(by: 1) } label: { Image(systemName: "chevron.right") }
                    .help("Next day")
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var scopeText: String {
        guard let scopes = model.todayScopes, let p = model.project else { return "all scopes" }
        let wide = scopes.compactMap { model.index.project($0) }.first { $0.wide && $0.id != p.id }
        return wide.map { "\(p.title) and \($0.title)" } ?? p.title
    }

    private var dayTitle: String {
        KBDate.parse(model.dailyDate)?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? model.dailyDate
    }
}

/// `[project]` as a chip with the project's title.
struct ProjectChip: View {
    @Environment(AppModel.self) private var model
    let project: String?

    var body: some View {
        if let project {
            let known = model.index.project(project)
            Text(known?.title ?? project)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(project == model.projectID ? Color.accentColor : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .lineLimit(1)
                .fixedSize()
                .help(project)
        }
    }
}

struct TodayItemRow: View {
    @Environment(AppModel.self) private var model
    let item: DailyPlan.Item
    let checkable: Bool

    var body: some View {
        let done = model.isDone(item)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if checkable {
                Button {
                    model.setChecked(item, done: !done)
                } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? Color.green : .secondary)
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help(done ? "Mark not done" : "Mark done")
            } else {
                Image(systemName: "questionmark.diamond").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(InlineMarkdown.attributed(item.text))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                ChipRow(spacing: 6) {
                    ProjectChip(project: item.project)
                    if let ref = item.ref { RefLink(ref: ref).lineLimit(1) }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Ask \(Brain.name) About This…") {
                model.askAbout(.text(item.text, title: String(item.text.prefix(60)), project: item.project))
            }
            Button("Work on It with \(Brain.name)…") {
                model.workWithClaude(.text(item.text, title: String(item.text.prefix(60)), project: item.project))
            }
            if let ref = item.ref, let id = EntryID(ref) {
                Button("Open \(id.section.singularTitle)") { model.openLink(ref) }
                if AppModel.pbiSources.contains(id.section) {
                    Button("New PBI or Bug…") { model.newPBIRequest = NewPBIRequest(source: id) }
                }
            }
            Divider()
            Button("Not Relevant Today") { model.markPlanItem(item, .notRelevant) }
            Button("Remove from Today", role: .destructive) { model.markPlanItem(item, .removed) }
        }
    }
}

/// A trailing `(…)`: an entry id opens it, `ado:<n>` opens the work item, a URL opens the browser.
struct RefLink: View {
    @Environment(AppModel.self) private var model
    let ref: String

    var body: some View {
        if EntryID(ref) != nil {
            EntryLink(raw: ref)
        } else if let url = RefLink.url(ref, model: model) {
            Link(ref, destination: url)
        } else {
            Text(ref).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    static func url(_ ref: String, model: AppModel) -> URL? {
        if let u = URL(string: ref), ["http", "https"].contains(u.scheme ?? "") { return u }
        if ref.hasPrefix("ado:"), let n = Int(ref.dropFirst(4)) {
            // The open scope's tracker, else the first scope that has Azure DevOps set up.
            let trackers = ([model.project].compactMap { $0 } + model.index.projects).map { model.settings(for: $0.id).tracker }
            guard let t = trackers.first(where: { $0.kind == "azure-devops" && !$0.organization.isEmpty && !$0.project.isEmpty }) else { return nil }
            let org = t.organization, proj = t.project
            return URL(string: "https://dev.azure.com/\(org)/\(proj.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proj)/_workitems/edit/\(n)")
        }
        return nil
    }
}

struct TodayMeetingRow: View {
    @Environment(AppModel.self) private var model
    let meeting: DailyPlan.Meeting

    var body: some View {
        let id = meeting.meetingID.flatMap(EntryID.init)
        let entry = id.flatMap { model.index.entry($0) }
        let status = entry?.meetingStatus ?? meeting.status.flatMap(MeetingStatus.init(rawValue:))
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(meeting.time)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    if let id { model.openLink(id.rawValue) }
                } label: {
                    Text(entry?.title ?? meeting.title).font(.body.weight(.medium))
                }
                .buttonStyle(.plain)
                .disabled(entry == nil)
                .help(entry == nil ? (meeting.meetingID ?? "No meeting file") : "Open \(id?.rawValue ?? "")")
                ChipRow(spacing: 6) {
                    ProjectChip(project: meeting.project ?? id?.project)
                    if let entry, entry.meetingStatus != nil {
                        let chip = MeetingDayRow.chip(entry)
                        Chip(text: chip.text, color: chip.color)
                    } else if let status {
                        Chip(text: status.rawValue.capitalized, color: status == .live ? .red : status == .filed ? .gray : .indigo)
                    }
                }
                .font(.caption)
            }
            Spacer()
            if let id, entry != nil, let status, status.isActive {
                Button(status == .prepared ? "Prepare" : status == .live ? "Resume" : "Review") { model.openMeeting(id) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Inbox, proposed fact and proposed backlog counts per project, as links into each project's Inbox, Facts and Backlog.
struct WaitingSummary: View {
    @Environment(AppModel.self) private var model

    private struct Waiting { let project: KBProject; let inbox: Int; let facts: Int; let backlog: Int }

    var body: some View {
        let rows = model.index.projects.filter { model.todayShows(tag: $0.id) }.compactMap { p -> Waiting? in
            // By folder, so an entry shown in several scopes is counted once.
            let own = model.index.entries.values.filter { $0.project == p.id }
            let w = Waiting(project: p, inbox: own.filter(\.waitsInInbox).count,
                            facts: own.filter { $0.isFactProposal || $0.isFactChange }.count,
                            backlog: own.filter { $0.section == .backlog && $0.backlogStatus == .proposed }.count)
            return w.inbox + w.facts + w.backlog > 0 ? w : nil
        }
        if rows.isEmpty {
            Text("Nothing waiting for approval.").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(rows, id: \.project.id) { w in
            ChipRow(spacing: 10) {
                ProjectChip(project: w.project.id)
                if w.inbox > 0 { link("\(w.inbox) in Inbox", w.project, "inbox") }
                if w.facts > 0 { link("\(w.facts) fact\(w.facts == 1 ? "" : "s")", w.project, "facts") }
                if w.backlog > 0 { link("\(w.backlog) backlog", w.project, "backlog") }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func link(_ title: String, _ p: KBProject, _ section: String) -> some View {
        Button(title) { model.handle(url: URL(string: "kb://open?project=\(p.id)&section=\(section)")!) }
            .buttonStyle(.link)
    }
}

struct MorningButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let available: Bool = { if case .found = model.claudeAvailability { return true } else { return false } }()
        VStack(spacing: 4) {
            Button {
                model.runMorningRoutine()
            } label: {
                Label(model.morning.isBusy ? "Running…" : "Run Morning Routine", systemImage: "sun.horizon")
            }
            .disabled(!available || model.morning.isBusy || model.dailyDate != KBDate.today())
            .help(available ? "\(Brain.name) reads your calendar, follow-ups and inbox and writes today's plan." : model.claudeMissingExplanation)
            if !available {
                Text(model.claudeMissingExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
    }
}

/// The detail column while Today is selected: the morning routine's session.
struct MorningPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let chat = model.morning
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Morning Routine").font(.title2.weight(.semibold))
                    Text("\(Brain.name) writes daily/\(model.dailyDate).md, prepares meetings and fills the inbox. The plan updates as the file changes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                MorningButton()
            }
            .padding(20)
            Divider()
            if chat.items.isEmpty && !chat.isBusy {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not run in this session").font(.headline)
                    Text("Replies from the morning routine appear here. Select an item in the list to see its details.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                Spacer()
            } else {
                ChatTranscript(chat: chat, emptyHint: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Short replies and a working indicator. Used by the morning routine and meeting prep.
struct ChatTranscript: View {
    let chat: ClaudeChat
    let emptyHint: String?
    /// Answers a ```choices block in the last reply; without it, choices show as plain options.
    var onChoice: ((String) -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.items.isEmpty, let emptyHint {
                        Text(emptyHint).font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    let marks = TranscriptTimes.marks(chat.items.map(\.timeEntry))
                    ForEach(Array(chat.items.enumerated()), id: \.element.id) { i, item in
                        VStack(alignment: .leading, spacing: 4) {
                            if let day = marks[i].day { DayHeading(title: day).padding(.vertical, 2) }
                            ChatBubble(item: item, choose: chooser(for: item)).id(item.id)
                            if let time = marks[i].time, let at = item.at {
                                MessageTime(text: time, at: at)
                                    .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
                            }
                        }
                    }
                    if chat.isBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(chat.activity.map { "Working… (\($0))" } ?? "\(Brain.name) is thinking…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .id("busy")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.items.count) { _, _ in
                withAnimation { proxy.scrollTo(chat.isBusy ? AnyHashable("busy") : AnyHashable(chat.items.last?.id), anchor: .bottom) }
            }
        }
    }
}

extension ChatTranscript {
    /// Only the last reply's choices are live, and only while Claude waits.
    func chooser(for item: ClaudeChat.Item) -> ((String) -> Void)? {
        guard let onChoice, !chat.isBusy, item.role == .assistant,
              chat.items.last(where: { $0.role == .assistant || $0.role == .user })?.id == item.id else { return nil }
        return onChoice
    }
}

extension ClaudeChat.Item {
    var timeEntry: TranscriptTimes.Entry {
        let side: TranscriptTimes.Side = switch role {
        case .user: .user
        case .assistant, .error: .reply
        case .status, .tool: .other
        }
        return .init(at: at, side: side)
    }
}

struct ChatBubble: View {
    let item: ClaudeChat.Item
    var choose: ((String) -> Void)?

    var body: some View {
        switch item.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                if !item.attachments.isEmpty { MessageAttachments(attachments: item.attachments) }
                if !item.text.isEmpty { UserMessageView(text: item.text, minLeading: 40) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            if MarkdownBlocks.parse(item.text).contains(where: { if case .choices = $0 { return true } else { return false } }) {
                MarkdownDocument(text: item.text, choices: choose.map { pick in
                    ChoiceHandler(multi: false, picked: [], toggle: { _ in }, choose: pick)
                })
            } else if item.text.contains("```") || item.text.contains("\n|") {
                MarkdownDocument(text: item.text)
            } else {
                Text(InlineMarkdown.attributed(item.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .textSelection(.enabled)
        case .status:
            Text(item.text).font(.caption).foregroundStyle(.secondary)
        case .tool:
            Text(ToolDescription.step(item.text).title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Markdown for SwiftUI `Text`: inline styles and links, with block structure kept as plain lines.
enum InlineMarkdown {
    static func attributed(_ markdown: String, citationLinks: Bool = false) -> AttributedString {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            var line = raw
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let text = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                line = text.isEmpty ? "" : "**\(text)**"
            } else if t.hasPrefix("- [ ] ") {
                line = "☐ " + t.dropFirst(6)
            } else if t.hasPrefix("- [x] ") || t.hasPrefix("- [X] ") {
                line = "☑ " + t.dropFirst(6)
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
                let indent = String(repeating: "  ", count: (raw.prefix { $0 == " " }.count) / 2)
                line = indent + "• " + t.dropFirst(2)
            }
            if citationLinks { line = linkCitations(line) }
            lines.append(line)
        }
        let joined = lines.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: joined, options: options)) ?? AttributedString(markdown)
    }

    /// `[3]` becomes a `kbcite:3` link; `[text](url)` links are left alone.
    static func linkCitations(_ line: String) -> String {
        var out = ""
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "[", let close = line[i...].firstIndex(of: "]") {
                let inner = line[line.index(after: i)..<close]
                let after = line.index(after: close)
                let isLink = after < line.endIndex && line[after] == "("
                if !isLink, !inner.isEmpty, inner.allSatisfy({ $0.isNumber || $0 == "," || $0 == " " }) {
                    let nums = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    out += nums.map { "[[\($0)]](kbcite:\($0))" }.joined()
                    i = after
                    continue
                }
            }
            out.append(line[i])
            i = line.index(after: i)
        }
        return out
    }
}
