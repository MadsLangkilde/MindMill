import KBCore
import KBEngine
import SwiftUI

struct NewDiscussionRequest: Identifiable, Equatable {
    let id = UUID()
    let project: String
}

struct ConcludeDiscussionRequest: Identifiable, Equatable {
    var id: EntryID { entry }
    let entry: EntryID
}

extension AppModel {
    /// Claude runs one of the mindmill:discussion skill's actions on a discussion, in a Plan session.
    func discussionSession(_ action: String, _ id: EntryID, display: String) {
        engine.discussionSession(action, id, display: display)
    }

    func startDiscussion(project: String, lookFor: String) {
        engine.startDiscussion(project: project, lookFor: lookFor)
    }

    func setDiscussion(_ id: EntryID, status: DiscussionStatus, outcome: String? = nil) {
        var args = ["discussion", "status", id.rawValue, status.rawValue]
        if let o = outcome?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty { args += ["--outcome", o] }
        runDiscussionCLI(id, args, success: status == .concluded ? "Concluded." : status == .parked ? "Parked." : "Reopened.")
    }

    func setWaitingOn(_ id: EntryID, _ who: WaitingOn) {
        guard let e = index.entry(id) else { return }
        runDiscussionCLI(id, ["discussion", "status", id.rawValue, e.discussionStatus.rawValue, "--waiting-on", who.rawValue],
                         success: who.title + ".")
    }

    private func runDiscussionCLI(_ id: EntryID, _ args: [String], success: String) {
        if document?.id == id, document?.isDirty == true { save() }
        busyEntries.insert(id)
        let cli = cli
        Task {
            do {
                _ = try await cli.run(args)
                notice = success
            } catch {
                errorMessage = error.localizedDescription
            }
            busyEntries.remove(id)
            reload()
            if document?.id == id { openNow(id) }
        }
    }

    /// Entries that came out of a discussion: approved ones naming it as their source, and inbox proposals from it.
    func filed(from id: EntryID) -> [KBEntry] {
        index.entries.values
            .filter { $0.id != id && ($0.sources.contains(id.rawValue) || $0.proposedBy == id.rawValue) }
            .sorted { ($0.section == .inbox ? 0 : 1, $0.title) < ($1.section == .inbox ? 0 : 1, $1.title) }
    }
}

// MARK: List

/// Discussions in a scope: the ones waiting on you first, then open, parked and concluded.
struct DiscussionsView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    private var showParked: Bool {
        get { model.foldStates["discussions.parked"] ?? false }
        nonmutating set { model.foldStates["discussions.parked"] = newValue }
    }
    private var showConcluded: Bool {
        get { model.foldStates["discussions.concluded"] ?? false }
        nonmutating set { model.foldStates["discussions.concluded"] = newValue }
    }

    var body: some View {
        let every = model.index.entries(project: project.id, section: .discussions).filter { !$0.isDraft }
            .sorted { $0.discussionUpdated > $1.discussionUpdated }
        let query = model.listQuery(.discussions)
        let all = query.isEmpty ? every : every.filter { $0.matches(query) }
        let open = all.filter { $0.discussionStatus == .open }
        let mine = open.filter { $0.waitingOn == WaitingOn.me.rawValue }
        let others = open.filter { $0.waitingOn != WaitingOn.me.rawValue }
        let parked = all.filter { $0.discussionStatus == .parked }
        let concluded = all.filter { $0.discussionStatus == .concluded }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(open.count) open").font(.headline)
                Spacer()
                Button {
                    model.newDiscussionRequest = NewDiscussionRequest(project: project.id)
                } label: {
                    Label("New Discussion", systemImage: "plus")
                }
                .help("Start one from an email thread or a Teams chat, or write it yourself")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if !every.isEmpty { ListSearchField(key: .discussions, prompt: "Search discussions") }
            Divider()
            if all.isEmpty && !every.isEmpty {
                ListEmptyState(title: "No discussions match “\(query)”", systemImage: "magnifyingglass")
            } else if all.isEmpty {
                ListEmptyState(title: "No Discussions", systemImage: "bubble.left.and.bubble.right", message: "Track an email thread or a chat that isn't settled yet: who said what, what's still open, and what was learned. File the findings as facts, decisions and follow-ups when they're ready.") {
                    Button("New Discussion…") { model.newDiscussionRequest = NewDiscussionRequest(project: project.id) }
                }
            } else {
                List(selection: model.entrySelection) {
                    DraftsSection(drafts: model.index.entries(project: project.id, section: .discussions).filter(\.isDraft))
                    if !mine.isEmpty {
                        Section("Waiting on you · \(mine.count)") { rows(mine) }
                    }
                    if query.isEmpty || !others.isEmpty {
                        Section("Open · \(others.count)") {
                            if others.isEmpty { Text("None.").foregroundStyle(.secondary).font(.callout) }
                            rows(others)
                        }
                    }
                    if !parked.isEmpty {
                        FoldableSection(isExpanded: Binding(get: { showParked || !query.isEmpty }, set: { showParked = $0 })) { rows(parked) } header: { Text("Parked · \(parked.count)") }
                    }
                    if !concluded.isEmpty {
                        FoldableSection(isExpanded: Binding(get: { showConcluded || !query.isEmpty }, set: { showConcluded = $0 })) { rows(concluded) } header: { Text("Concluded · \(concluded.count)") }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationSubtitle("Discussions")
    }

    private func rows(_ entries: [KBEntry]) -> some View {
        ForEach(entries) { DiscussionRow(entry: $0).tag($0.id).entryContextMenu($0.id) }
    }
}

struct DiscussionRow: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry

    var body: some View {
        let parts = DiscussionBody(entry.body)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: Self.channelIcon(entry.channel)).foregroundStyle(.secondary).font(.caption)
                Text(entry.title).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Text(DateText.short(entry.discussionUpdated)).font(.caption).foregroundStyle(.secondary)
            }
            if !entry.summary.isEmpty {
                Text(entry.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            ChipRow(spacing: 6) {
                if entry.waitingOn == WaitingOn.me.rawValue, entry.discussionStatus == .open {
                    Chip(text: "Your turn", color: .orange, systemImage: "arrowshape.turn.up.left.fill")
                }
                let open = parts.openQuestions.count
                if open > 0 { Chip(text: "\(open) open question\(open == 1 ? "" : "s")", color: .blue, systemImage: "questionmark.circle") }
                if !parts.findings.isEmpty {
                    let unfiled = parts.findings.filter { !$0.contains("→") }.count
                    Chip(text: unfiled > 0 ? "\(unfiled) to file" : "\(parts.findings.count) filed",
                         color: unfiled > 0 ? .purple : .green, systemImage: "lightbulb")
                }
                ForEach(entry.listField("people").prefix(4), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 3)
    }

    static func channelIcon(_ channel: String?) -> String {
        switch channel {
        case "email": return "envelope"
        case "teams": return "bubble.left.and.text.bubble.right"
        case "meeting": return "person.2"
        default: return "bubble.left.and.bubble.right"
        }
    }
}

// MARK: Detail

/// The bar over a discussion: its state, who it waits on, and what Claude can do with it.
struct DiscussionBanner: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry

    var body: some View {
        let busy = model.busyEntries.contains(entry.id)
        let status = entry.discussionStatus
        let waiting = WaitingOn(rawValue: entry.waitingOn) ?? .nobody
        HStack(spacing: 10) {
            ChipRow(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.mint)
                Text(status == .open ? "Open discussion" : status.title).fontWeight(.semibold)
                Menu {
                    ForEach(WaitingOn.allCases, id: \.self) { w in
                        Button { model.setWaitingOn(entry.id, w) } label: {
                            if w == waiting { Label(w.title, systemImage: "checkmark") } else { Text(w.title) }
                        }
                    }
                } label: {
                    Chip(text: waiting.title, color: waiting == .me ? .orange : .secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(busy || status != .open)
                if let link = entry.field("link"), let u = URL(string: link) {
                    Link(destination: u) { Label(entry.channel == "teams" ? "Open chat" : "Open mail", systemImage: "arrow.up.right.square") }
                        .font(.callout)
                }
            }
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            Menu {
                Button("Check for New Replies") { model.discussionSession("refresh", entry.id, display: "Check for new replies") }
                Button("File the Findings in the Knowledge Base") { model.discussionSession("file", entry.id, display: "File the findings") }
                Button("Suggest PBIs…") { model.suggestPBIs(for: entry.id) }
                Button("Research…") {
                    model.newResearchRequest = NewResearchRequest(project: entry.project, target: .entry(entry.id), title: entry.title)
                }
                Divider()
                switch status {
                case .open:
                    Button("Park") { model.setDiscussion(entry.id, status: .parked) }
                    Button("Conclude…") { model.concludeDiscussionRequest = ConcludeDiscussionRequest(entry: entry.id) }
                case .parked, .concluded:
                    Button("Reopen") { model.setDiscussion(entry.id, status: .open) }
                }
            } label: {
                Text("More")
            }
            .fixedSize()
            .disabled(busy)
            Button {
                model.discussionSession("work", entry.id, display: "Work on the discussion")
            } label: {
                Label("Work on It with \(Brain.name)", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .help("\(Brain.name) reads it with the knowledge base and code, says where it stands, and proposes next steps or a reply")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.mint.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Under the header: open questions, findings not filed yet, and what was filed from it.
struct DiscussionPanel: View {
    @Environment(AppModel.self) private var model
    let id: EntryID

    var body: some View {
        if let entry = model.index.entry(id) {
            let parts = DiscussionBody(entry.body)
            let filed = model.filed(from: id)
            let unfiled = parts.findings.filter { !$0.contains("→") }
            VStack(alignment: .leading, spacing: 10) {
                if !parts.openQuestions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open questions").font(.callout.weight(.semibold))
                        ForEach(parts.openQuestions, id: \.self) { q in
                            Label(q.text, systemImage: "questionmark.circle").font(.callout)
                        }
                    }
                }
                if !unfiled.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Label("\(unfiled.count) finding\(unfiled.count == 1 ? "" : "s") not filed yet", systemImage: "lightbulb")
                            .font(.callout).foregroundStyle(.purple)
                        Spacer()
                        Button("File in the Knowledge Base…") { model.discussionSession("file", id, display: "File the findings") }
                            .controlSize(.small)
                            .help("\(Brain.name) proposes facts, decisions, follow-ups and backlog items. You approve each in the Inbox.")
                    }
                }
                if !filed.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Filed from this discussion").font(.callout.weight(.semibold))
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

// MARK: Sheets

struct NewDiscussionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NewDiscussionRequest
    @State private var lookFor = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Discussion").font(.title2.weight(.semibold))
            Text("\(Brain.name) finds the thread in your mail or Teams, writes down who said what and what's still open, and keeps it until it settles.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Subject, a sender's name, or words from the thread", text: $lookFor, axis: .vertical)
                .lineLimit(1...)
                .scrollingInput(lookFor, maxLines: 3)
                .textFieldStyle(.roundedBorder)
                .onSubmit(start)
            HStack {
                Button("Write It Myself") {
                    dismiss()
                    model.newEntryRequest = NewEntryRequest(project: request.project, section: .discussions)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Find It", action: start)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(lookFor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func start() {
        guard !lookFor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.startDiscussion(project: request.project, lookFor: lookFor)
        dismiss()
    }
}

struct ConcludeDiscussionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: EntryID
    @State private var outcome = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Conclude “\(model.index.entry(id)?.title ?? id.stem)”").font(.title2.weight(.semibold))
            Text("What was settled? It goes in the Outcome section. Leave it empty and \(Brain.name) proposes one from the discussion.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $outcome)
                .font(.body)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Let \(Brain.name) Propose It" : "Conclude") {
                    if outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        model.discussionSession("conclude", id, display: "Conclude the discussion")
                    } else {
                        model.setDiscussion(id, status: .concluded, outcome: outcome)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
