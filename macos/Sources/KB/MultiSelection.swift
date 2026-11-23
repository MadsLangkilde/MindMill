import KBCore
import SwiftUI

extension AppModel {
    /// Lists select one entry as before, or several with ⌘-click and ⇧-click.
    var entrySelection: Binding<Set<EntryID>> {
        Binding(
            get: { self.multiSelection.count > 1 ? self.multiSelection : Set([self.selectedEntryID].compactMap { $0 }) },
            set: { new in
                if new.count <= 1 {
                    self.multiSelection = []
                    self.selectEntry(new.first)
                } else {
                    self.navigate { [self] in
                        if self.document?.isNew == true || self.document != nil { self.closeDocument() }
                        self.multiSelection = new
                    }
                }
            })
    }

    func selectedEntries(_ ids: Set<EntryID>) -> [KBEntry] {
        ids.compactMap { index.entry($0) }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// A Claude session about several entries at once, with the user's question.
    func askAboutEntries(_ ids: Set<EntryID>, question: String) {
        let entries = selectedEntries(ids)
        guard !entries.isEmpty else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = entries.map { "- `\($0.id.rawValue)` “\($0.title)”" }.joined(separator: "\n")
        let kinds = Set(entries.map(\.section))
        let noun = kinds.count == 1 ? kinds.first!.title.lowercased() : "entries"
        let message = """
        This is about these \(entries.count) KB \(noun):
        \(list)

        Read each one first (`kb show <id>`) and what they link to. Use other sources where it helps: related KB entries (`kb search`), the project's code, `kb sources` and the connected tools. Cite entry ids and sources.
        If a fact turns out wrong or outdated, don't edit it: flag it with `kb fact challenge <fact id> --by session:<this session> --question '…'` (the corrected text on stdin with `--body-stdin`), so I decide on the fact in the app. Change other entries only when I say so.

        \(q.isEmpty ? "What do you notice about them together?" : q)
        """
        let projects = Set(entries.map(\.project))
        newSession(title: q.isEmpty ? "\(entries.count) \(noun)" : String(q.prefix(60)),
                   project: projects.count == 1 ? projects.first : nil,
                   message: message,
                   display: (q.isEmpty ? "What do you notice about them together?" : q) + "\n\n" + entries.map { "· \($0.title)" }.joined(separator: "\n"))
    }

    func deleteEntries(_ ids: Set<EntryID>) {
        let cli = cli
        if let d = document, ids.contains(d.id) { closeDocument() }
        multiSelection = []
        busyEntries.formUnion(ids)
        Task {
            var failures: [String] = []
            for id in ids {
                if id.section == .meetings { closeMeetingController(id) }
                do { try await cli.deleteEntry(id) } catch { failures.append(error.localizedDescription) }
                busyEntries.remove(id)
            }
            reload()
            if failures.isEmpty { notice = "Deleted \(ids.count) entries." } else { errorMessage = failures.joined(separator: "\n\n") }
        }
    }

    func moveEntries(_ ids: Set<EntryID>, to project: String) {
        multiSelection = []
        for id in ids { moveEntry(id, to: project) }
    }

    func closeFollowups(_ ids: Set<EntryID>, status: FollowupStatus) {
        multiSelection = []
        for id in ids where index.entry(id)?.followupStatus == .open {
            closeFollowup(id, status: status, resolvedBy: nil, answer: nil)
        }
    }

    func startLeadOn(_ ids: Set<EntryID>) {
        let entries = selectedEntries(ids)
        let projects = Set(entries.map(\.project))
        newLeadRequest = NewLeadRequest(
            title: entries.count == 1 ? entries[0].title : "",
            project: projects.count == 1 ? projects.first : projectID,
            about: entries.count == 1 ? entries[0].id.rawValue : nil,
            brief: "Work on these KB entries (read each with `kb show <id>` first):\n"
                + entries.map { "- `\($0.id.rawValue)` “\($0.title)”" }.joined(separator: "\n"))
        mode = .build
    }
}

/// The detail when several entries are selected: what they are, a question to Claude, and bulk actions.
struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model
    let ids: Set<EntryID>
    @State private var question = ""
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    var body: some View {
        let entries = model.selectedEntries(ids)
        let sections = Set(entries.map(\.section))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(entries.count) selected").font(.title2.weight(.semibold))
                    Text(sections.count == 1 ? sections.first!.title.lowercased() : "entries").foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Selection") { model.multiSelection = [] }
                        .buttonStyle(.borderless)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Divider() }
                        HStack(spacing: 8) {
                            Image(systemName: SidebarView.icon(e.section)).foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).lineLimit(1)
                                if !e.summary.isEmpty { Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                            if e.section == .facts, !model.factChanges(for: e.id).isEmpty { MayHaveChangedChip() }
                            Button {
                                model.multiSelection.remove(e.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove from the selection")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

                askBox(sections: sections)
                actions(entries: entries, sections: sections)
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Delete \(entries.count) entries?", isPresented: $confirmDelete) {
            Button("Delete \(entries.count)", role: .destructive) { model.deleteEntries(ids) }
        } message: {
            Text("The files are removed, and links to them in other entries are taken out.")
        }
    }

    private func askBox(sections: Set<KBSection>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ask \(Brain.name) about these", systemImage: "sparkles").font(.headline)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("For example: these seem to contradict each other. Are any actually false? Check other sources.",
                          text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...)
                    .scrollingInput(question, maxLines: 8)
                    .focused($focused)
                    .onSubmit(ask)
                Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
            FlowButtons(prompts: suggestions(sections)) { question = $0; ask() }
            Text("Opens a \(Brain.name) session with the entries attached. A fact it finds wrong is flagged on the fact for you to decide.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func suggestions(_ sections: Set<KBSection>) -> [String] {
        var out: [String] = []
        if sections == [.facts] {
            out += ["Do these contradict each other? Check other sources to see which are false.",
                    "Are these still true? Check the code and other sources."]
        }
        if sections == [.followups] {
            out += ["Which of these are already done or answered? Check the KB, the code and recent work items.",
                    "Group these and suggest what to do first."]
        }
        if sections == [.decisions] {
            out += ["Do any of these conflict? Is one superseded in practice?"]
        }
        out += ["Are any of these duplicates?", "Summarise these in a few lines."]
        return out
    }

    private func ask() {
        let q = question
        question = ""
        model.askAboutEntries(ids, question: q)
    }

    private func actions(entries: [KBEntry], sections: Set<KBSection>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions").font(.headline)
            HStack(spacing: 8) {
                if sections == [.followups], entries.contains(where: { $0.followupStatus == .open }) {
                    Button("Mark Done") { model.closeFollowups(ids, status: .done) }
                    Button("Drop") { model.closeFollowups(ids, status: .dropped) }
                }
                Button {
                    model.startLeadOn(ids)
                } label: {
                    Label("Work on These in Build…", systemImage: "hammer")
                }
                .help("A Build session works on all of them")
                let scopeIDs = Set(entries.flatMap { model.index.group(of: $0.project)?.scopes ?? [] })
                if scopeIDs.count > 1 {
                    Menu("Scopes") {
                        ForEach(model.index.projects.filter { scopeIDs.contains($0.id) }) { s in
                            let inAll = entries.allSatisfy { $0.isIn(scope: s.id) }
                            Button(inAll ? "Remove from \(s.title)" : "Add to \(s.title)") {
                                model.changeScope(s.id, on: ids, add: !inAll)
                            }
                        }
                    }
                    .fixedSize()
                    .help("Add the selected entries to a scope, or remove them from it")
                }
                Menu("Move to Scope") {
                    ForEach(model.index.projects) { p in
                        Button(p.title) { model.moveEntries(ids, to: p.id) }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Delete \(entries.count)…", role: .destructive) { confirmDelete = true }
            }
        }
    }
}

/// Suggested prompts as small buttons that wrap.
struct FlowButtons: View {
    let prompts: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(prompts, id: \.self) { p in
                Button {
                    action(p)
                } label: {
                    Label(p, systemImage: "text.bubble").font(.callout)
                }
                .buttonStyle(.link)
            }
        }
    }
}
