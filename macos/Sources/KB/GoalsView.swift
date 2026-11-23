import AppKit
import KBCore
import SwiftUI

struct GoalSheetRequest: Identifiable, Equatable {
    let id = UUID()
    var editing: Goal?
}

extension AppModel {
    var activeGoals: [Goal] { goals.filter { $0.status == .active } }

    func newGoal() { goalSheet = GoalSheetRequest(editing: nil) }

    func updateGoal(_ goal: Goal, _ change: (inout Goal) -> Void) {
        do { try Goals.update(goal, change) } catch { errorMessage = error.localizedDescription }
        reload()
    }

    func logGoalProgress(_ goal: Goal, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        updateGoal(goal) { $0.body = GoalBody.addingProgress(t, date: KBDate.today(), to: $0.body) }
        notice = "Progress logged."
    }

    func editGoalLog(_ goal: Goal, _ section: String, _ id: Int, date: String, text: String) {
        updateGoal(goal) { g in
            var log = ProgressLog(markdown: g.section(section))
            log.set(id, date: date, text: text)
            g.body = GoalBody.setting(section, to: log.markdown, in: g.body)
        }
    }

    func removeGoalLog(_ goal: Goal, _ section: String, _ id: Int) {
        updateGoal(goal) { g in
            var log = ProgressLog(markdown: g.section(section))
            log.remove(id)
            g.body = log.items.isEmpty && section != "Progress"
                ? GoalBody.removing(section, from: g.body)
                : GoalBody.setting(section, to: log.markdown, in: g.body)
        }
    }

    func acceptGoalProposal(_ goal: Goal, _ id: Int, date: String, text: String) {
        updateGoal(goal) { $0.body = GoalBody.accepting(id, date: date, text: text, in: $0.body) }
        notice = "Added to Progress."
    }

    /// Logs a suggested step as done today, without what it serves, and ticks it.
    func suggestionToProgress(_ goal: Goal, _ q: QuestionList.Question) {
        let text = (q.text.components(separatedBy: ":").first ?? q.text).trimmingCharacters(in: .whitespaces)
        var l = goal.suggestions
        l.set(q.id, done: true)
        updateGoal(goal) { g in
            g.body = GoalBody.setting("Suggestions", to: l.markdown, in: g.body)
            g.body = GoalBody.addingProgress(text, date: KBDate.today(), to: g.body)
        }
        notice = "Added to Progress."
    }

    func deleteGoal(_ goal: Goal) {
        do { try Goals.delete(goal) } catch { errorMessage = error.localizedDescription }
        goalChats.removeValue(forKey: goal.id)?.stop()
        goalCoachUpdated[goal.id] = nil
        if selectedGoalID == goal.id { selectedGoalID = nil }
        reload()
    }

    func goalChat(_ goal: Goal) -> ClaudeChat {
        if let c = goalChats[goal.id] { return c }
        let c = ClaudeChat()
        c.onEvent = { [weak self] event in
            if case .turnResult = event { self?.reload() }
        }
        goalChats[goal.id] = c
        return c
    }

    /// The goal coach: a session that edits the goal file's Suggestions and answers coaching questions.
    func sendToGoalCoach(_ goal: Goal, _ text: String, show: Bool = true) {
        let chat = goalChat(goal)
        if !chat.isRunning {
            guard let launch = launch(prompt: ClaudeModes.goal(goal.id), sessionID: UUID().uuidString.lowercased(), resume: false,
                                      model: defaultModel, cwd: rootURL) else {
                errorMessage = claudeMissingExplanation
                return
            }
            do { try chat.start(launch, mode: "goal") } catch {
                errorMessage = "Could not start claude: \(error.localizedDescription)"
                return
            }
            chat.send(ClaudeModes.warmup, tag: "connect", show: false)
        }
        chat.send(text, tag: "goal-\(UUID().uuidString.prefix(6))", show: show)
        goalCoachUpdated[goal.id] = Date()
    }
}

struct GoalsRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.kbTheme) private var theme

    var body: some View {
        let selected = model.sidebarSelection == .goals
        Button {
            model.selectSidebar(.goals)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mountain.2")
                    .foregroundStyle(selected ? Color.white : theme.sidebarIconColor)
                    .frame(width: 18)
                Text("Goals").font(.body.weight(.medium))
                Spacer()
                if !model.activeGoals.isEmpty {
                    Text("\(model.activeGoals.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
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
        .help("Personal long-term goals: a side agenda for briefs, meeting prep and the morning routine")
    }
}

struct GoalsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Goals").font(.title3.weight(.semibold))
                    Text("Personal · a side agenda").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.newGoal() } label: { Label("New Goal", systemImage: "plus") }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            if !model.goals.isEmpty { ListSearchField(key: .goals, prompt: "Search goals") }
            Divider()
            let query = model.listQuery(.goals)
            let goals = query.isEmpty ? model.goals : model.goals.filter { $0.matches(query) }
            if !model.goals.isEmpty && goals.isEmpty {
                ListEmptyState(title: "No goals match “\(query)”", systemImage: "magnifyingglass")
            } else if model.goals.isEmpty {
                ListEmptyState(title: "No goals yet", systemImage: "mountain.2", message: "A long-term goal, like your next career step, quietly shapes briefs, meeting prep and the morning routine without taking over.") {
                    Button("New Goal…") { model.newGoal() }
                }
            } else {
                List(selection: Binding(get: { model.selectedGoalID }, set: { model.selectedGoalID = $0 })) {
                    ForEach(Goal.Status.allCases, id: \.self) { status in
                        let list = goals.filter { $0.status == status }
                        if !list.isEmpty {
                            Section(status.rawValue.capitalized) {
                                ForEach(list) { GoalRow(goal: $0).tag($0.id) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationSubtitle("Goals")
    }
}

struct GoalRow: View {
    @Environment(AppModel.self) private var model
    let goal: Goal

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(goal.title).font(.headline)
            ChipRow(spacing: 6) {
                if !goal.horizon.isEmpty { Text(goal.horizon) }
                if goal.openSuggestions > 0 { Text("· \(goal.openSuggestions) suggestions") }
                if !goal.proposedProgress.items.isEmpty { Text("· \(goal.proposedProgress.items.count) to review").foregroundStyle(.green) }
                if let last = goal.lastProgress { Text("· progress \(DateText.display(last))") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Ask \(Brain.name) About This…") { model.askAbout(.goal(goal)) }
            Button("Work on It with \(Brain.name)…") { model.workWithClaude(.goal(goal)) }
            Button("Edit…") { model.goalSheet = GoalSheetRequest(editing: goal) }
            Menu("Status") {
                ForEach(Goal.Status.allCases, id: \.self) { s in
                    Button(s.rawValue.capitalized) { model.updateGoal(goal) { $0.frontmatter.set("status", .string(s.rawValue)) } }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { model.deleteGoal(goal) }
        }
    }
}

struct GoalDetailView: View {
    @Environment(AppModel.self) private var model
    let goal: Goal
    @State private var progress = ""
    @State private var newSuggestion = ""

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    section("Why", goal.section("Why"), empty: "Why this matters to you. Edit to add it.")
                    section("What it takes", goal.section("What it takes"),
                            empty: "The concrete things that would show you're there. Ask the coach to draft them.")
                    suggestions
                    proposedSection
                    progressSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 380)
            GoalCoach(goal: goal)
                .frame(minWidth: 300, idealWidth: 360)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(goal.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 8) {
                Menu(goal.status.rawValue.capitalized) {
                    ForEach(Goal.Status.allCases, id: \.self) { s in
                        Button(s.rawValue.capitalized) { model.updateGoal(goal) { $0.frontmatter.set("status", .string(s.rawValue)) } }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if !goal.horizon.isEmpty { Label(goal.horizon, systemImage: "calendar").foregroundStyle(.secondary) }
                Spacer()
                Button("Edit…") { model.goalSheet = GoalSheetRequest(editing: goal) }
                Button { model.askAbout(.goal(goal)) } label: { Label("Ask \(Brain.name)", systemImage: "questionmark.bubble") }
            }
            .font(.callout)
            Text(goal.status == .active
                 ? "Active goals show up as one quiet line in briefs, meeting prep and the morning plan, only when something fits."
                 : "Only active goals are taken into account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, _ markdown: String, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if markdown.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(InlineMarkdown.attributed(markdown)).textSelection(.enabled)
            }
        }
    }

    private var suggestions: some View {
        let list = goal.suggestions
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Suggestions").font(.headline)
                Spacer()
                Button {
                    model.sendToGoalCoach(goal, "Suggest next steps")
                } label: {
                    Label("Suggest Next Steps", systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(model.goalChat(goal).isBusy)
            }
            if list.questions.isEmpty {
                Text("Small steps that ride on work you already have. \(Brain.name) suggests them from your meetings, work items and plans.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(list.questions) { q in
                GoalSuggestionRow(goal: goal, question: q)
            }
            HStack {
                TextField("Add a step of your own", text: $newSuggestion)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addSuggestion)
                Button("Add", action: addSuggestion)
                    .disabled(newSuggestion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addSuggestion() {
        let t = newSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var l = goal.suggestions
        l.append(t)
        model.updateGoal(goal) { $0.body = GoalBody.setting("Suggestions", to: l.markdown, in: $0.body) }
        newSuggestion = ""
    }

    @ViewBuilder
    private var proposedSection: some View {
        let proposed = goal.proposedProgress.items
        if !proposed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Proposed for Progress").font(.headline)
                Text("Things you did that look like progress on this goal. Add them as they are, edit them first, or dismiss them.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(proposed) { item in
                    ProgressLine(item: item, accent: true,
                                 accept: { date, text in model.acceptGoalProposal(goal, item.id, date: date, text: text) },
                                 save: { date, text in model.editGoalLog(goal, "Proposed progress", item.id, date: date, text: text) },
                                 remove: { model.removeGoalLog(goal, "Proposed progress", item.id) })
                }
            }
            .padding(12)
            .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Progress").font(.headline)
                Spacer()
                Button {
                    model.sendToGoalCoach(goal, "Find progress")
                } label: {
                    Label("Find Progress", systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(model.goalChat(goal).isBusy)
                .help("\(Brain.name) looks at what you finished lately (PRs, work items, meetings, decisions) and proposes what counts")
            }
            HStack {
                TextField("What did you do toward this goal?", text: $progress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(log)
                Button("Log", action: log).disabled(progress.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let items = goal.progress.items
            if items.isEmpty {
                Text("Nothing logged yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                ProgressLine(item: item,
                             save: { date, text in model.editGoalLog(goal, "Progress", item.id, date: date, text: text) },
                             remove: { model.removeGoalLog(goal, "Progress", item.id) })
            }
        }
    }

    private func log() {
        model.logGoalProgress(goal, progress)
        progress = ""
    }
}

/// A suggested step: tick it when it's done, edit it, or add it to Progress.
struct GoalSuggestionRow: View {
    @Environment(AppModel.self) private var model
    let goal: Goal
    let question: QuestionList.Question
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                var l = goal.suggestions
                l.set(question.id, done: !question.done)
                model.updateGoal(goal) { $0.body = GoalBody.setting("Suggestions", to: l.markdown, in: $0.body) }
            } label: {
                Image(systemName: question.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(question.done ? Color.green : .secondary)
            }
            .buttonStyle(.borderless)
            .help(question.done ? "Mark not done" : "Mark done")
            if editing {
                InlineTextEditor(text: $draft, onSave: save, onCancel: { editing = false })
            } else {
                Text(InlineMarkdown.attributed(question.text))
                    .strikethrough(question.done)
                    .foregroundStyle(question.done ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) { startEditing() }
                Button {
                    model.suggestionToProgress(goal, question)
                } label: { Image(systemName: "text.badge.plus") }
                .buttonStyle(.borderless)
                .help("Add to Progress, dated today, and mark it done")
                Button { startEditing() } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit")
                Button {
                    var l = goal.suggestions
                    l.remove(question.id)
                    model.updateGoal(goal) { $0.body = GoalBody.setting("Suggestions", to: l.markdown, in: $0.body) }
                } label: { Image(systemName: "xmark.circle").foregroundStyle(.tertiary) }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
    }

    private func startEditing() {
        draft = question.text
        editing = true
    }

    private func save() {
        let t = draft.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        editing = false
        guard !t.isEmpty, t != question.text else { return }
        var l = goal.suggestions
        l.set(question.id, text: t)
        model.updateGoal(goal) { $0.body = GoalBody.setting("Suggestions", to: l.markdown, in: $0.body) }
    }
}

/// One dated line of Progress or Proposed progress, editable in place.
struct ProgressLine: View {
    let item: ProgressLog.Item
    var accent = false
    var accept: ((String, String) -> Void)?
    let save: (String, String) -> Void
    let remove: () -> Void
    @State private var editing = false
    @State private var date = ""
    @State private var text = ""

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("YYYY-MM-DD", text: $date)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospacedDigit())
                        .frame(width: 110)
                    if !validDate { Text("Use YYYY-MM-DD").font(.caption).foregroundStyle(.red) }
                }
                InlineTextEditor(text: $text, saveTitle: accept == nil ? "Save" : "Add to Progress", saveDisabled: !validDate,
                                 onSave: commit, onCancel: { editing = false })
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.date.isEmpty ? "—" : DateText.display(item.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(InlineMarkdown.attributed(item.text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) { startEditing() }
                if let accept {
                    Button("Add") { accept(item.date.isEmpty ? KBDate.today() : item.date, item.text) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .help("Add to Progress")
                }
                Button { startEditing() } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help(accept == nil ? "Edit" : "Edit before adding")
                Button(action: remove) {
                    Image(systemName: accept == nil ? "trash" : "xmark.circle").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help(accept == nil ? "Delete" : "Dismiss")
            }
            .padding(.vertical, accent ? 2 : 0)
        }
    }

    private var validDate: Bool { KBDate.isISODate(date.trimmingCharacters(in: .whitespaces)) }

    private func startEditing() {
        date = item.date.isEmpty ? KBDate.today() : item.date
        text = item.text
        editing = true
    }

    private func commit() {
        let t = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard validDate, !t.isEmpty else { return }
        editing = false
        let d = date.trimmingCharacters(in: .whitespaces)
        if let accept { accept(d, t) } else { save(d, t) }
    }
}

/// A text field that edits a line in place, with Save and Cancel.
struct InlineTextEditor: View {
    @Binding var text: String
    var saveTitle = "Save"
    var saveDisabled = false
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { if !saveDisabled { onSave() } }
                .onExitCommand(perform: onCancel)
            HStack(spacing: 8) {
                Button("Cancel", action: onCancel).controlSize(.small)
                Button(saveTitle, action: onSave)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(saveDisabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { focused = true }
    }
}

struct GoalCoach: View {
    @Environment(AppModel.self) private var model
    let goal: Goal
    @State private var input = ""

    var body: some View {
        let chat = model.goalChat(goal)
        VStack(spacing: 0) {
            HStack {
                Label("Coach", systemImage: "sparkles").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ChatTranscript(chat: chat, emptyHint: "Talk the goal through: “what does a tech lead do differently?”, “draft What it takes”, “which of this week's meetings could help?”. \(Brain.name) edits the goal file and keeps it a side agenda.",
                           onChoice: { model.sendToGoalCoach(goal, $0) })
            Divider()
            HStack(spacing: 8) {
                TextField("Ask the coach…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...)
                    .scrollingInput(input, maxLines: 4)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    private func send() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input = ""
        model.sendToGoalCoach(goal, t)
    }
}

struct GoalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: GoalSheetRequest
    @State private var title = ""
    @State private var horizon = ""
    @State private var why = ""
    @State private var whatItTakes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.editing == nil ? "New Goal" : "Edit Goal").font(.title2.weight(.semibold))
            TextField("The goal, e.g. Become a tech lead", text: $title).font(.title3)
            TextField("When, in your words, e.g. by end of 2027", text: $horizon)
            field("Why it matters", $why, height: 70)
            if request.editing != nil {
                field("What it takes (one per line, “- …”)", $whatItTakes, height: 110)
            } else {
                Text("After saving, ask the coach to draft what it takes and suggest first steps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.editing == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 500)
        .onAppear {
            guard let g = request.editing else { return }
            title = g.title
            horizon = g.horizon
            why = g.section("Why")
            whatItTakes = g.section("What it takes")
        }
    }

    private func field(_ label: String, _ text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .frame(minHeight: height, maxHeight: height * 2)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
        }
    }

    private func save() {
        do {
            if let g = request.editing {
                try Goals.update(g) { e in
                    e.frontmatter.set("title", .string(title.trimmingCharacters(in: .whitespaces)))
                    let h = horizon.trimmingCharacters(in: .whitespaces)
                    e.frontmatter.set("horizon", h.isEmpty ? nil : .string(h))
                    e.body = GoalBody.setting("Why", to: why, in: e.body)
                    e.body = GoalBody.setting("What it takes", to: whatItTakes, in: e.body)
                }
            } else {
                let g = try Goals.create(title: title, horizon: horizon, why: why, root: model.rootURL)
                model.selectedGoalID = g.id
                model.selectSidebar(.goals)
            }
            dismiss()
            model.reload()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
