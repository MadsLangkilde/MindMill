import KBCore
import SwiftUI

extension MeetingController {
    /// Backlog entries (PBIs and bugs) that name this meeting as their source, in any scope.
    var meetingBacklog: [KBEntry] {
        guard let model else { return [] }
        return model.index.entries.values
            .filter { $0.section == .backlog && $0.sources.contains(id.rawValue) }
            .sorted { $0.id.stem < $1.id.stem }
    }

    /// Writes a proposed backlog entry sourced from this meeting. It shows here, in Review and in Backlog.
    func addPBI(title: String, description: String, bug: Bool, scope: String) {
        guard let model else { return }
        let cli = model.cli
        let summary = description.split(separator: "\n").first.map(String.init) ?? ""
        var args = ["new", "backlog", "--project", scope, "--title", title, "--source", id.rawValue,
                    "--type", bug ? "bug" : "pbi", "--cross-project"]
        if !summary.isEmpty { args += ["--summary", String(summary.prefix(200))] }
        if !description.isEmpty { args.append("--body-stdin") }
        Task {
            do {
                _ = try await cli.run(args, stdin: description.isEmpty ? nil : description + "\n")
                model.reload()
                notice = "Added “\(title)” to \(model.index.project(scope)?.title ?? scope)'s backlog."
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// Claude proposes what the meeting calls for after checking what exists: in the prepare chat while
    /// preparing, else in a session of its own (the live session only answers in two lines).
    func suggestPBIs() {
        guard let model else { return }
        if stage == .prepare {
            chatInput = AppModel.suggestPBIsPrompt(id)
            sendChat()
        } else {
            model.suggestPBIs(for: id)
        }
    }

    /// Asks the prepare session to write the PBI from what was discussed.
    func draftPBIWithClaude(_ brief: String, bug: Bool, scope: String) {
        let kind = bug ? "bug" : "PBI"
        chatInput = """
        Draft a \(kind) for this, as a proposed backlog entry in scope `\(scope)` with `--source \(id.rawValue)` (`kb new backlog --type \(bug ? "bug" : "pbi")`): \(brief)
        First check it doesn't exist: `kb list --section backlog` and `kb tracker items --search "<2–3 keywords>"`; if it does, tell me its number instead of writing a new one.
        Write a clear title, a one-line summary and a body with the why, what and acceptance criteria. Name the meeting in words, never by KB id, since work items are shared. Don't create it in Azure DevOps.
        """
        sendChat()
    }
}

/// PBIs and bugs from this meeting, and a quick way to add one while preparing or during the meeting.
struct MeetingPBISheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var c: MeetingController
    @State private var title = ""
    @State private var details = ""
    @State private var bug = false
    @State private var scope = ""
    @State private var create: BacklogCreateRequest?
    @FocusState private var titleFocused: Bool

    var body: some View {
        let items = c.meetingBacklog
        let related = model.relatedPBIs(for: c.id).filter { $0.why != .fromThis }
        let scopes = [c.id.project] + model.index.siblings(of: c.id.project).map(\.id)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("PBIs and Bugs from This Meeting").font(.title3.weight(.semibold))
                Spacer()
                if c.stage != .live {
                    Button("Suggest with \(Brain.name)") {
                        c.suggestPBIs()
                        dismiss()
                    }
                    .help("\(Brain.name) checks the backlog and Azure DevOps, then proposes what this meeting calls for")
                }
            }
            if items.isEmpty {
                Text("None yet. Add one below; the summary at the end also proposes them.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                            if i > 0 { Divider() }
                            row(e)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            if !related.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Mentioned in the meeting or related").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(related) { RelatedPBIRow(pbi: $0) }
                        }
                    }
                    .frame(maxHeight: 140)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
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
                    .focused($titleFocused)
                    .onSubmit(add)
                TextField("Details, why, acceptance criteria (optional)", text: $details, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...)
                    .scrollingInput(details, maxLines: 8)
                if title.trimmingCharacters(in: .whitespaces).count > 3 { PBIMatchList(query: title) }
            }
            HStack {
                Text(c.stage == .prepare
                     ? "Added items wait in the backlog as proposals. Create them in Azure DevOps here, in Review, or from Backlog."
                     : "Jot it down now; \(Brain.name) fills in the details in the summary, and you create it in Azure DevOps when you review.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if c.stage == .prepare {
                    Button("Let \(Brain.name) Write It") {
                        c.draftPBIWithClaude([title, details].filter { !$0.isEmpty }.joined(separator: ". "), bug: bug, scope: scope)
                        title = ""
                        details = ""
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("\(Brain.name) writes it from the conversation and the knowledge base, as a proposal")
                }
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if scope.isEmpty { scope = c.id.project }
            titleFocused = true
            model.refreshTracker()
        }
        .sheet(item: $create) { BacklogBatchCreateSheet(request: BacklogBatchRequest(entries: [$0.entry], people: c.attendees)) }
    }

    private func add() {
        let t = KBEntry.oneLine(title)
        guard !t.isEmpty else { return }
        c.addPBI(title: t, description: details.trimmingCharacters(in: .whitespacesAndNewlines), bug: bug, scope: scope)
        title = ""
        details = ""
        titleFocused = true
    }

    private func row(_ e: KBEntry) -> some View {
        HStack(spacing: 8) {
            KindChip(kind: e.backlogKind)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).lineLimit(2)
                HStack(spacing: 6) {
                    ProjectChip(project: e.project)
                    if !e.summary.isEmpty { Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer()
            switch e.backlogStatus {
            case .proposed:
                Button("Create in Azure DevOps…") { create = BacklogCreateRequest(entry: e.id) }
                    .controlSize(.small)
            case .created:
                if let wi = e.field("work_item") {
                    if let u = e.field("url").flatMap(URL.init(string:)) { Link("#\(wi)", destination: u).font(.callout) } else { Text("#\(wi)") }
                } else {
                    Chip(text: "Created", color: .green)
                }
            default:
                Chip(text: "Rejected", color: .gray)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
