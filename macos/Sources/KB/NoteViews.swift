import KBCore
import KBEngine
import SwiftUI

struct NewNoteRequest: Identifiable, Equatable {
    let id = UUID()
    let project: String
}

extension AppModel {
    func newNote(project: String) {
        newNoteRequest = NewNoteRequest(project: project)
    }

    func addNote(project: String, text: String, title: String) {
        Task {
            do {
                let id = try await engine.addNote(scope: project, text: text, title: title)
                notice = "Noted."
                selectEntry(id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Talks the note through, or sorts it, in its own Plan session, and shows that session. `live`: in voice.
    func noteSession(_ action: NoteAction, _ id: EntryID, live: Bool = false) {
        if document?.id == id, document?.isDirty == true { save() }
        let s = engine.noteSession(action, id, spoken: live, show: false)
        selectedSessionID = s.id
        openWindowAction?("claude", nil)
        if live { startLiveVoice(in: s) }
    }

    func setNote(_ id: EntryID, status: NoteStatus) {
        busyEntries.insert(id)
        Task {
            do {
                try await engine.setNote(id, status: status)
                notice = status == .filed ? "Marked as filed." : "Open again."
            } catch {
                errorMessage = error.localizedDescription
            }
            busyEntries.remove(id)
            if document?.id == id { openNow(id) }
        }
    }
}

// MARK: List

/// The user's notes in a scope: open ones, with filed ones folded away.
struct NotesView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    private var showFiled: Bool {
        get { model.foldStates["notes.filed"] ?? false }
        nonmutating set { model.foldStates["notes.filed"] = newValue }
    }

    var body: some View {
        let every = model.index.entries(project: project.id, section: .notes).filter { !$0.isDraft }
            .sorted { $0.noteUpdated > $1.noteUpdated }
        let query = model.listQuery(.notes)
        let all = query.isEmpty ? every : every.filter { $0.matches(query) }
        let open = all.filter { $0.noteStatus == .open }
        let filed = all.filter { $0.noteStatus == .filed }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(open.count) open").font(.headline)
                Spacer()
                Button { model.newNote(project: project.id) } label: { Label("New Note", systemImage: "plus") }
                    .help("Write it down now; sort it out later")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if !every.isEmpty { ListSearchField(key: .notes, prompt: "Search notes") }
            Divider()
            if all.isEmpty && !every.isEmpty {
                ListEmptyState(title: "No notes match “\(query)”", systemImage: "magnifyingglass")
            } else if all.isEmpty {
                ListEmptyState(title: "No Notes", systemImage: NoteStatus.icon, message: "Anything that doesn't fit anywhere yet: a thought, something you heard, a loose list. Talk it through with \(Brain.name), out loud or typed: it sums it up, checks it with you, and suggests what should become a fact, a decision, an idea or a follow-up. Notes are private.") {
                    Button("New Note…") { model.newNote(project: project.id) }
                }
            } else {
                List(selection: model.entrySelection) {
                    if !open.isEmpty { Section("Open · \(open.count)") { rows(open) } }
                    if !filed.isEmpty {
                        FoldableSection(isExpanded: Binding(get: { showFiled || !query.isEmpty }, set: { showFiled = $0 })) { rows(filed) } header: { Text("Filed · \(filed.count)") }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationSubtitle("Notes")
    }

    private func rows(_ entries: [KBEntry]) -> some View {
        ForEach(entries) { NoteRow(entry: $0).tag($0.id).entryContextMenu($0.id) }
    }
}

struct NoteRow: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry

    var body: some View {
        let parts = NoteBody(entry.body)
        let waiting = model.engine.suggestions(from: [entry.id.rawValue]).count
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.title).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Text(DateText.short(entry.noteUpdated)).font(.caption).foregroundStyle(.secondary)
            }
            let line = entry.summary.isEmpty ? parts.text : entry.summary
            if !line.isEmpty {
                Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if waiting > 0 || !parts.filed.isEmpty {
                ChipRow(spacing: 6) {
                    if waiting > 0 {
                        Chip(text: "\(waiting) suggestion\(waiting == 1 ? "" : "s")", color: .orange, systemImage: "lightbulb")
                    }
                    if !parts.filed.isEmpty {
                        Chip(text: "\(parts.filed.count) filed", color: .green, systemImage: "tray.and.arrow.down")
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: Detail

/// The bar over a note: its state, and talking it through or sorting it with the AI.
struct NoteBanner: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry

    var body: some View {
        let busy = model.busyEntries.contains(entry.id)
        let status = entry.noteStatus
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 160) {
            Image(systemName: NoteStatus.icon).foregroundStyle(.teal)
            Menu {
                ForEach(NoteStatus.allCases, id: \.self) { s in
                    Button { model.setNote(entry.id, status: s) } label: {
                        if s == status { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                    }
                }
            } label: {
                Text(status == .open ? "Note" : "Filed note").fontWeight(.semibold)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(busy)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Button("Sort It") { model.noteSession(.sort, entry.id) }
                    .help("\(Brain.name) suggests where each part belongs: facts, decisions, ideas, follow-ups, references. You add or dismiss each.")
                if model.liveVoiceAvailable {
                    Button { model.noteSession(.discuss, entry.id, live: true) } label: { Label("Talk It Through", systemImage: "waveform") }
                        .help("Talk out loud with \(model.voiceEngineName): it sums the note up, checks it with you and suggests where things belong")
                }
                Button {
                    model.noteSession(.discuss, entry.id)
                } label: {
                    Label(model.liveVoiceAvailable ? "Discuss" : "Talk It Through", systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.borderedProminent)
                .help("Go through it with \(Brain.name): it sums it up, checks it with you, asks what's unclear and suggests where things belong")
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.teal.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Under the header: what the note comes to, where its parts went, and the suggestions waiting on it.
struct NotePanel: View {
    @Environment(AppModel.self) private var model
    let id: EntryID

    var body: some View {
        if let entry = model.index.entry(id) {
            let parts = NoteBody(entry.body)
            VStack(alignment: .leading, spacing: 10) {
                if !parts.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What it comes to").font(.callout.weight(.semibold))
                        Text(parts.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !parts.filed.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Filed").font(.callout.weight(.semibold))
                        ForEach(parts.filed, id: \.self) { Label($0, systemImage: "tray.and.arrow.down").font(.callout) }
                    }
                }
                SuggestionCards(origins: [id.rawValue], title: "Suggested from this note")
            }
        }
    }
}

/// Writing a note down: just the text; the title comes from its first words unless given.
struct NewNoteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NewNoteRequest
    @State private var text = ""
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Note").font(.title2.weight(.semibold))
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            HStack(spacing: 8) {
                TextField("Title (optional: its first words)", text: $title).textFieldStyle(.roundedBorder)
                DictationButton(text: $text) {}
            }
            Text("Private: only in your knowledge base on this Mac. Talk it through or sort it afterwards, and \(Brain.name) suggests what belongs where.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Note") {
                    model.addNote(project: request.project, text: text, title: title)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: Suggestions

/// What sessions and notes suggest for the knowledge base, each added or dismissed with one click.
struct SuggestionCards: View {
    @Environment(AppModel.self) private var model
    let origins: Set<String>
    var title = "Suggested for your knowledge base"
    /// Space around the cards when they show, for places that have none of their own.
    var inset: CGFloat = 0

    var body: some View {
        let items = model.engine.suggestions(from: origins)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(title, systemImage: "lightbulb").font(.callout.weight(.semibold))
                    Spacer()
                    if items.count > 1 {
                        Button("Add All") { model.approveInbox(items.map(\.id)) }
                            .controlSize(.small)
                    }
                }
                ForEach(items) { e in card(e) }
            }
            .padding(10)
            .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.25)))
            .padding(.horizontal, inset)
            .padding(.top, inset > 0 ? 8 : 0)
        }
    }

    private func card(_ e: KBEntry) -> some View {
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 200) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let s = e.proposedSection { SectionChip(section: s) }
                    Text(e.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                }
                if !e.summary.isEmpty {
                    Text(e.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let r = e.reason, !r.isEmpty {
                    Text(r).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.selectEntry(e.id) }
            HStack(spacing: 6) {
                Button("Add") { model.approveInbox([e.id]) }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("Dismiss") { model.rejectInbox([e.id]) }.controlSize(.small)
            }
            .fixedSize()
        }
    }
}
