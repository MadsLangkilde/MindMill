import KBCore
import SwiftUI

extension AppModel {
    /// Claude runs one of the kb:idea skill's actions on an idea, in a Plan session.
    func ideaSession(_ action: String, _ id: EntryID, display: String) {
        let title = index.entry(id)?.title ?? id.stem
        newSession(title: "Idea: \(title)", project: id.project, message: "/kb:idea \(action) \(id.rawValue)",
                   display: "\(display): \(title)", about: "idea:\(id.rawValue)")
    }

    func turnIdea(_ id: EntryID, into outcome: IdeaOutcome) {
        ideaSession("turn \(outcome.rawValue)", id, display: "Turn it into \(outcome.title.lowercased())")
    }

    func newIdea(project: String) {
        newEntryRequest = NewEntryRequest(project: project, section: .ideas)
    }

    func setIdea(_ id: EntryID, status: IdeaStatus) {
        if document?.id == id, document?.isDirty == true { save() }
        busyEntries.insert(id)
        let cli = cli
        Task {
            do {
                _ = try await cli.run(["idea", "status", id.rawValue, status.rawValue])
                notice = status == .shelved ? "Shelved." : status == .done ? "Marked as turned into something." : "Moved to \(status.title)."
            } catch {
                errorMessage = error.localizedDescription
            }
            busyEntries.remove(id)
            reload()
            if document?.id == id { openNow(id) }
        }
    }
}

// MARK: List

/// Ideas in a scope: new and exploring ones, with shelved and finished ones folded away.
struct IdeasView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    @State private var showShelved = false
    @State private var showDone = false

    var body: some View {
        let every = model.index.entries(project: project.id, section: .ideas).filter { !$0.isDraft }
            .sorted { $0.ideaUpdated > $1.ideaUpdated }
        let query = model.listQuery(.ideas)
        let all = query.isEmpty ? every : every.filter { $0.matches(query) }
        let exploring = all.filter { $0.ideaStatus == .exploring }
        let new = all.filter { $0.ideaStatus == .new }
        let shelved = all.filter { $0.ideaStatus == .shelved }
        let done = all.filter { $0.ideaStatus == .done }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(new.count + exploring.count) open").font(.headline)
                Spacer()
                Button { model.newIdea(project: project.id) } label: { Label("New Idea", systemImage: "plus") }
                    .help("Write it down now; brainstorm it later")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if !every.isEmpty { ListSearchField(key: .ideas, prompt: "Search ideas") }
            Divider()
            if all.isEmpty && !every.isEmpty {
                ListEmptyState(title: "No ideas match “\(query)”", systemImage: "magnifyingglass")
            } else if all.isEmpty {
                ListEmptyState(title: "No Ideas", systemImage: IdeaRow.icon, message: "Write down an idea while it's fresh, then brainstorm it with \(Brain.name). When it has grown, turn it into backlog items, facts, a decision, follow-ups, an architecture note, or a new project in Mindmill.") {
                    Button("New Idea…") { model.newIdea(project: project.id) }
                }
            } else {
                List(selection: model.entrySelection) {
                    DraftsSection(drafts: model.index.entries(project: project.id, section: .ideas).filter(\.isDraft))
                    if !exploring.isEmpty { Section("Exploring · \(exploring.count)") { rows(exploring) } }
                    if !new.isEmpty { Section("New · \(new.count)") { rows(new) } }
                    if !shelved.isEmpty {
                        FoldableSection(isExpanded: Binding(get: { showShelved || !query.isEmpty }, set: { showShelved = $0 })) { rows(shelved) } header: { Text("Shelved · \(shelved.count)") }
                    }
                    if !done.isEmpty {
                        FoldableSection(isExpanded: Binding(get: { showDone || !query.isEmpty }, set: { showDone = $0 })) { rows(done) } header: { Text("Turned into something · \(done.count)") }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationSubtitle("Ideas")
    }

    private func rows(_ entries: [KBEntry]) -> some View {
        ForEach(entries) { IdeaRow(entry: $0).tag($0.id).entryContextMenu($0.id) }
    }
}

struct IdeaRow: View {
    static let icon = "lightbulb.max"
    let entry: KBEntry

    var body: some View {
        let parts = IdeaBody(entry.body)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.title).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Text(DateText.short(entry.ideaUpdated)).font(.caption).foregroundStyle(.secondary)
            }
            if !entry.summary.isEmpty {
                Text(entry.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            ChipRow(spacing: 6) {
                if !parts.openQuestions.isEmpty {
                    Chip(text: "\(parts.openQuestions.count) open question\(parts.openQuestions.count == 1 ? "" : "s")", color: .blue, systemImage: "questionmark.circle")
                }
                if !parts.nextSteps.isEmpty {
                    Chip(text: "\(parts.nextSteps.count) next step\(parts.nextSteps.count == 1 ? "" : "s")", color: .orange, systemImage: "arrow.forward.circle")
                }
                if !parts.turnedInto.isEmpty {
                    Chip(text: "Turned into \(parts.turnedInto.count)", color: .green, systemImage: "arrow.triangle.branch")
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: Detail

/// The bar over an idea: its state and what Claude can grow it into.
struct IdeaBanner: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry

    var body: some View {
        let busy = model.busyEntries.contains(entry.id)
        let status = entry.ideaStatus
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 160) {
            Image(systemName: IdeaRow.icon).foregroundStyle(.yellow)
            Menu {
                ForEach(IdeaStatus.allCases, id: \.self) { s in
                    Button { model.setIdea(entry.id, status: s) } label: {
                        if s == status { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                    }
                }
            } label: {
                Text(status == .new ? "New idea" : status.title).fontWeight(.semibold)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(busy)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Menu {
                    ForEach(IdeaOutcome.allCases) { o in
                        Button(o.title + "…") { model.turnIdea(entry.id, into: o) }
                    }
                } label: {
                    Text("Turn Into")
                }
                .fixedSize()
                .disabled(busy)
                .help("\(Brain.name) drafts them from the idea. Entries wait in the Inbox and backlog items under Waiting to be created until you approve them.")
                Button("Research…") {
                    model.newResearchRequest = NewResearchRequest(project: entry.project, target: .entry(entry.id), title: entry.title)
                }
                .help("Look into something for this idea with \(Brain.name); when you finish, the takeaways you pick are added to it")
                Button {
                    model.ideaSession("brainstorm", entry.id, display: "Brainstorm the idea")
                } label: {
                    Label("Brainstorm", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .help("Think it through with \(Brain.name): it asks, challenges, looks in the knowledge base and code, and writes down thoughts, questions and next steps")
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Under the header: next steps, open questions, and what came out of the idea.
struct IdeaPanel: View {
    @Environment(AppModel.self) private var model
    let id: EntryID

    var body: some View {
        if let entry = model.index.entry(id) {
            let parts = IdeaBody(entry.body)
            let filed = model.filed(from: id)
            VStack(alignment: .leading, spacing: 10) {
                if !parts.nextSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next steps").font(.callout.weight(.semibold))
                        ForEach(parts.nextSteps, id: \.self) { Label($0, systemImage: "arrow.forward.circle").font(.callout) }
                    }
                }
                if !parts.openQuestions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open questions").font(.callout.weight(.semibold))
                        ForEach(parts.openQuestions, id: \.self) { Label($0, systemImage: "questionmark.circle").font(.callout) }
                    }
                }
                if !filed.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Came out of this idea").font(.callout.weight(.semibold))
                        ForEach(filed) { e in
                            Button {
                                model.selectEntry(e.id)
                            } label: {
                                HStack(spacing: 6) {
                                    if e.section == .inbox {
                                        Chip(text: "Waiting for approval", color: .orange)
                                        if let s = e.proposedSection { SectionChip(section: s) }
                                    } else {
                                        SectionChip(section: e.section)
                                    }
                                    Text(e.title).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
