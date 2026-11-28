import KBCore
import KBEngine
import SwiftUI

struct NewPBIRequest: Identifiable, Equatable {
    var id: EntryID { source }
    let source: EntryID
}

/// A PBI or bug that bears on an entry: proposed or created from it, written into it by number, or one whose
/// title shares most of its words.
struct RelatedPBI: Identifiable, Equatable {
    enum Why: Int, Comparable {
        case fromThis, mentioned, similar
        static func < (a: Why, b: Why) -> Bool { a.rawValue < b.rawValue }
    }

    var id: String
    var number: Int?
    var title: String
    var kind: String
    var state: String
    var url: URL?
    var entry: EntryID?
    var why: Why
}

extension AppModel {
    /// Where a PBI or bug can come from.
    static let pbiSources: Set<KBSection> = [.followups, .meetings, .discussions, .ideas, .decisions, .facts, .architecture]

    private var trackerItems: [TrackerBacklog.Item] { tracker?.items ?? [] }

    private func related(_ item: TrackerBacklog.Item, _ why: RelatedPBI.Why) -> RelatedPBI {
        RelatedPBI(id: "wi:\(item.id)", number: item.id, title: item.title, kind: item.isBug ? "bug" : "pbi",
                   state: item.state, url: URL(string: item.url), why: why)
    }

    private func related(_ e: KBEntry, _ why: RelatedPBI.Why) -> RelatedPBI {
        let number = e.field("work_item").flatMap(Int.init)
        let state: String
        switch e.backlogStatus {
        case .proposed: state = "Proposed"
        case .created: state = number.flatMap { n in trackerItems.first { $0.id == n }?.state } ?? "Created"
        case .rejected: state = "Rejected"
        }
        return RelatedPBI(id: number.map { "wi:\($0)" } ?? e.id.rawValue, number: number, title: e.title,
                          kind: e.backlogKind, state: state, url: e.field("url").flatMap(URL.init(string:)),
                          entry: e.id, why: why)
    }

    private var backlogEntries: [KBEntry] {
        index.entries.values.filter { $0.section == .backlog && !$0.isDraft && $0.backlogStatus != .rejected }
    }

    /// PBIs and bugs that bear on an entry, from this entry first.
    func relatedPBIs(for id: EntryID) -> [RelatedPBI] {
        guard let entry = index.entry(id) else { return [] }
        var out: [RelatedPBI] = []
        var seen = Set<String>()
        func add(_ r: RelatedPBI) {
            guard seen.insert(r.id).inserted else { return }
            out.append(r)
        }
        for e in backlogEntries where e.sources.contains(id.rawValue) { add(related(e, .fromThis)) }
        let text = [entry.title, entry.summary, entry.body, entry.field("resolved_by") ?? ""].joined(separator: "\n")
        for m in PBIMatch.mentionedWorkItems(text) {
            if let item = trackerItems.first(where: { $0.id == m.number }) {
                add(related(item, .mentioned))
            } else if let e = backlogEntries.first(where: { $0.field("work_item") == String(m.number) }) {
                add(related(e, .mentioned))
            } else if m.explicit, let url = workItemURL(m.number, project: id.project) {
                add(RelatedPBI(id: "wi:\(m.number)", number: m.number, title: "Work item #\(m.number)", kind: "pbi",
                               state: "", url: url, why: .mentioned))
            }
        }
        for r in similarPBIs(to: entry.title, limit: 4) { add(r) }
        return out
    }

    /// Open PBIs and bugs, and proposals, whose title shares most words with `text`; best first.
    func similarPBIs(to text: String, limit: Int = 5, threshold: Double = 0.5) -> [RelatedPBI] {
        var scored: [(Double, RelatedPBI)] = []
        for item in trackerItems {
            let s = PBIMatch.score(text, item.title)
            if s >= threshold { scored.append((s, related(item, .similar))) }
        }
        let tracked = Set(trackerItems.map(\.id))
        for e in backlogEntries {
            if let n = e.field("work_item").flatMap(Int.init), tracked.contains(n) { continue }
            let s = PBIMatch.score(text, e.title)
            if s >= threshold { scored.append((s, related(e, .similar))) }
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    func workItemURL(_ number: Int, project: String) -> URL? {
        workItemURL(String(number), project: project)
    }

    func workItemURL(_ item: String, project: String) -> URL? {
        let t = tracker(for: project)
        return TrackerLink.url(kind: t.kind, organization: t.organization, project: t.project, item: item)
    }

    /// The name of the scope's tracker: Azure DevOps, Jira, Mindmill…
    func trackerName(_ project: String) -> String { TrackerLink.name(tracker(for: project).kind) }

    /// The work item a session is about, if any.
    func sessionWorkItem(_ s: WorkSession) -> String? {
        TrackerLink.workItem(about: s.about) { [index] id in index.entry(id)?.field("work_item") }
    }

    /// Makes a suggested backlog item from a reminder (its title and note) and opens the create dialog for it.
    func backlogItem(from r: Reminder) {
        guard let scope = r.project ?? projectID else {
            errorMessage = "Pick a project first: the reminder has none."
            return
        }
        let bug = r.title.range(of: #"\b(bug|fejl|crash|broken)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        Task {
            do {
                let raw = try await engine.backlog.propose(title: r.title, details: r.note, bug: bug, scope: scope, source: nil)
                guard let id = EntryID(raw) else { throw ActionError("Mindmill didn't say which entry it made.") }
                reload()
                backlogBatchRequest = BacklogBatchRequest(entries: [id], context: "the reminder")
            } catch {
                errorMessage = "Couldn't make the backlog item: \(error.localizedDescription)"
            }
        }
    }

    /// Turns a "create a PBI" follow-up into a suggested backlog item and opens it.
    func followupToBacklog(_ id: EntryID) {
        let cli = cli
        Task {
            do {
                let out = try await cli.run(["followup", "to-backlog", id.rawValue]).trimmingCharacters(in: .whitespacesAndNewlines)
                reload()
                if let new = EntryID(out) {
                    checkDuplicates(scope: new.project, force: true)
                    open(new)
                }
                notice = "Moved to Suggested backlog items."
            } catch {
                errorMessage = "Couldn't move it: \(error.localizedDescription)"
            }
        }
    }

    /// Shows a work item of Mindmill's own tracker under Plan → Backlog.
    func showLocalItem(_ number: Int, project: String) {
        navigate { [self] in
            mode = .plan
            if projectID != project { setProject(project) }
            sidebarSelection = .section(.backlog)
            closeDocument()
            showProposedBacklog = false
            selectedLocalItem = number
        }
    }

    /// A proposed backlog entry sourced from `source`; it waits in Backlog with a Create button.
    func addProposedPBI(source: EntryID, title: String, details: String, bug: Bool, scope: String) {
        Task {
            do {
                try await engine.backlog.propose(title: title, details: details, bug: bug, scope: scope, source: source)
                notice = "Added “\(title)” to \(index.project(scope)?.title ?? scope)'s backlog as a proposal."
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// The create-PBI skill on an entry, with what the user typed as a starting point.
    func createWorkItem(from id: EntryID, brief: String) {
        let b = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return createWorkItem(from: id) }
        let title = index.entry(id)?.title ?? id.stem
        newSession(title: "PBI: \(title)", project: id.project, message: "/mindmill:create-pbi \(id.rawValue) \(b)",
                   display: "Create a PBI from “\(title)”: \(b)")
    }

    /// Claude reads the meeting and proposes the PBIs and bugs it calls for, after checking which exist.
    func suggestPBIs(for id: EntryID) {
        let title = index.entry(id)?.title ?? id.stem
        newSession(title: "PBIs: \(title)", project: id.project, message: Self.suggestPBIsPrompt(id),
                   display: "Suggest PBIs and bugs for “\(title)”")
    }

    static func suggestPBIsPrompt(_ id: EntryID) -> String {
        """
        Suggest the PBIs and bugs that the \(id.section.singularTitle.lowercased()) `\(id.rawValue)` calls for (everything it says: prep, questions, points, notes, findings, summary), following the mindmill:work-item skill's "Proposing from the knowledge base" rules. First check what exists: `kb list --section backlog` and `kb tracker items --search "<2–3 keywords>"` for each candidate. For one that exists, don't propose it again: list it as `#<id> <title> (<state>)`. Write each new one as a proposed backlog entry with `--source \(id.rawValue)` (title and body name it in words, never by KB id, since work items are shared). \(WorkItemLinks.proposalRule) Don't create anything in the tracker. Reply with two short lists: Already exists, and Proposed.
        """
    }
}

// MARK: Views

/// One related or matching work item: kind, number (a link), title and state.
struct RelatedPBIRow: View {
    @Environment(AppModel.self) private var model
    let pbi: RelatedPBI

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            KindChip(kind: pbi.kind)
            if let n = pbi.number {
                if let u = pbi.url { Link("#\(n)", destination: u).font(.callout.monospacedDigit()) } else { Text("#\(n)").monospacedDigit() }
            }
            Button {
                if let e = pbi.entry { model.openLink(e.rawValue) } else if let u = pbi.url { NSWorkspace.shared.open(u) }
            } label: {
                Text(pbi.title).lineLimit(2).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .help(pbi.entry != nil ? "Open the backlog entry" : "Open in \(TrackerLink.name(forURL: pbi.url?.absoluteString ?? ""))")
            Spacer(minLength: 6)
            if !pbi.state.isEmpty {
                Chip(text: pbi.state, color: pbi.state == "Proposed" ? .orange : pbi.state == "Done" ? .green : .secondary)
            }
            if pbi.state == "Proposed", let e = pbi.entry {
                Button("Create…") { model.backlogCreateRequest = BacklogCreateRequest(entry: e) }
                    .controlSize(.small)
                    .help("Create it in \(model.trackerName(e.project))")
            }
        }
        .font(.callout)
    }
}

/// Work items related to an entry, under its header: from it, written in it, and with a similar title.
struct RelatedPBIsPanel: View {
    @Environment(AppModel.self) private var model
    let id: EntryID
    @AppStorage("relatedPBIsExpanded") private var expanded = true

    var body: some View {
        let items = model.relatedPBIs(for: id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.caption).rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("PBIs and bugs").font(.headline)
                        if !items.isEmpty { Text("\(items.count)").foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if model.trackerLoading { ProgressView().controlSize(.mini) }
                Spacer()
                if id.section == .meetings {
                    Button("Suggest with \(Brain.name)") { model.suggestPBIs(for: id) }
                        .help("\(Brain.name) checks the backlog and Azure DevOps, then proposes what this meeting calls for")
                }
                Button("New PBI…") { model.newPBIRequest = NewPBIRequest(source: id) }
            }
            .controlSize(.small)
            if expanded {
                if items.isEmpty {
                    Text(model.tracker == nil ? "Loading the tracker…" : "None found.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(groups(items), id: \.0) { title, list in
                        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                        ForEach(list) { RelatedPBIRow(pbi: $0) }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { model.refreshTracker() }
    }

    private func groups(_ items: [RelatedPBI]) -> [(String, [RelatedPBI])] {
        let from = id.section == .meetings ? "From this meeting" : "From this \(id.section.singularTitle.lowercased())"
        return [(from, RelatedPBI.Why.fromThis), ("Mentioned", .mentioned), ("May be related", .similar)].compactMap { title, why in
            let list = items.filter { $0.why == why }
            return list.isEmpty ? nil : (title, list)
        }
    }
}

/// Existing PBIs and bugs that look like `query`, so a new one isn't a duplicate.
struct PBIMatchList: View {
    @Environment(AppModel.self) private var model
    let query: String

    var body: some View {
        let matches = model.similarPBIs(to: query, limit: 5, threshold: 0.4)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label("Already in the backlog?", systemImage: "exclamationmark.magnifyingglass")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(matches) { RelatedPBIRow(pbi: $0) }
            }
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// A PBI or bug from any entry: shows what may already exist, then adds a proposal or lets Claude write it.
struct NewPBISheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: EntryID
    @State private var title = ""
    @State private var details = ""
    @State private var bug = false
    @State private var scope = ""

    var body: some View {
        let entry = model.index.entry(source)
        let scopes = [source.project] + model.index.siblings(of: source.project).map(\.id)
        VStack(alignment: .leading, spacing: 14) {
            Text("New PBI or Bug").font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                SectionChip(section: source.section)
                Text(entry?.title ?? source.stem).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Picker("", selection: $bug) {
                    Text("PBI").tag(false)
                    Text("Bug").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Scope", selection: $scope) {
                    ForEach(scopes, id: \.self) { Text(model.index.project($0)?.title ?? $0).tag($0) }
                }
                .fixedSize()
            }
            TextField(bug ? "What is broken" : "What should be built", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            TextField("Details, why, acceptance criteria (optional)", text: $details, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...)
                .scrollingInput(details, maxLines: 8)
            PBIMatchList(query: title.isEmpty ? (entry?.title ?? "") : title)
            HStack {
                Text("A proposal waits in Backlog until you create it in Azure DevOps. \(Brain.name) goes through it step by step.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Let \(Brain.name) Write It") {
                    model.createWorkItem(from: source, brief: [title, details].filter { !$0.isEmpty }.joined(separator: ". "))
                    dismiss()
                }
                .help("\(Brain.name) drafts it from the entry and the knowledge base, checks for duplicates, and asks before creating")
                Button("Add as Proposal", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear {
            scope = source.project
            if source.section == .followups || source.section == .decisions, let t = entry?.title { title = t }
            model.refreshTracker()
        }
    }

    private func add() {
        let t = KBEntry.oneLine(title)
        guard !t.isEmpty else { return }
        model.addProposedPBI(source: source, title: t, details: details.trimmingCharacters(in: .whitespacesAndNewlines),
                             bug: bug, scope: scope.isEmpty ? source.project : scope)
        dismiss()
    }
}
