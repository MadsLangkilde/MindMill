import KBCore
import KBEngine
import SwiftUI

enum ModelChoice {
    static let all: [(tag: String, title: String)] = [("", "Default"), ("haiku", "Haiku"), ("sonnet", "Sonnet"), ("opus", "Opus")]
}

/// How a strategy works in words, its diagrams, and the instructions the lead gets.
struct StrategyDetails: View {
    let strategy: Strategy
    @State private var showInstructions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How it works").font(.headline)
                ForEach(Array(strategy.howItWorks.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
            StrategyPicture(strategy: strategy)
            DisclosureGroup(isExpanded: $showInstructions) {
                Text(strategy.message)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 6)
            } label: {
                Text("What the lead is told").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A strategy's details. Your own can be edited or deleted here; a built-in one can be copied to make your own.
struct StrategyDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let slug: String
    @State private var editing: StrategyEditorRequest?
    @State private var confirmDelete = false

    var body: some View {
        let st = model.strategies.first { $0.slug == slug }
        VStack(spacing: 0) {
            if let st {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(st.title).font(.title2.weight(.semibold))
                        Chip(text: st.isBuiltIn ? "Built in" : "Yours", color: st.isBuiltIn ? .secondary : .accentColor)
                    }
                    if !st.summary.isEmpty { Text(st.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                ScrollView {
                    StrategyDetails(strategy: st).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    if st.isBuiltIn {
                        Button("Copy to Make My Own…") { editing = .copy(of: st) }
                            .help("Built-in strategies can't be changed; a copy can")
                    } else {
                        Button("Delete…", role: .destructive) { confirmDelete = true }
                        Button("Edit…") { editing = .edit(st) }
                    }
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(14)
            } else {
                Text("This strategy is gone.").foregroundStyle(.secondary).padding(40)
                Button("Close") { dismiss() }.padding(.bottom, 20)
            }
        }
        .frame(width: 640)
        .frame(minHeight: 420, idealHeight: 640, maxHeight: 820)
        .sheet(item: $editing) { StrategyEditorSheet(request: $0) }
        .confirmationDialog("Delete “\(st?.title ?? slug)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let st { model.deleteStrategy(st) }
                dismiss()
            }
        } message: {
            Text("Sessions already using it keep their instructions.")
        }
    }
}

struct StrategyEditorRequest: Identifiable {
    let id = UUID()
    var draft: Strategy
    var isNew: Bool

    static var new: StrategyEditorRequest {
        StrategyEditorRequest(draft: Strategy(slug: "", title: "", roles: [
            StrategyRole(name: "Builder", kind: .builder, model: "sonnet", count: 2, duty: "Builds the part it is given, with tests."),
            StrategyRole(name: "Reviewer", kind: .reviewer, model: "opus", checkpoint: .eachStep,
                         duty: "Reads the diff and reports findings, most severe first, or LGTM."),
        ]), isNew: true)
    }

    static func edit(_ s: Strategy) -> StrategyEditorRequest { StrategyEditorRequest(draft: s, isNew: false) }

    static func copy(of s: Strategy) -> StrategyEditorRequest {
        var d = s
        d.slug = ""
        d.title = "\(s.title) (mine)"
        d.origin = .custom
        return StrategyEditorRequest(draft: d, isNew: true)
    }
}

/// Makes or changes one of your strategies: the lead, the sessions it starts and how they work together,
/// with the diagram drawn live beside it.
struct StrategyEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: StrategyEditorRequest
    @State private var draft = Strategy(slug: "", title: "")
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            Text(request.isNew ? "New Strategy" : "Edit “\(request.draft.title)”")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            HStack(spacing: 0) {
                ScrollView { form.padding(18) }
                    .frame(minWidth: 420, maxWidth: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        StrategyDetails(strategy: draft)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 400)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.isNew ? "Create Strategy" : "Save Changes") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(14)
        }
        .frame(width: 900, height: 680)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = request.draft
        }
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
            && (!draft.roles.isEmpty || !draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && draft.roles.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $draft.title, prompt: Text("Name, e.g. Two builders + reviewer"))
                    .textFieldStyle(.roundedBorder)
                TextField("Summary", text: $draft.summary, prompt: Text("One line: what it is for"))
                    .textFieldStyle(.roundedBorder)
                Picker("Lead's model", selection: $draft.leadModel) {
                    ForEach(ModelChoice.all, id: \.tag) { Text($0.title).tag($0.tag) }
                }
                .fixedSize()
                .help("The model of the session you start, which leads the others")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sessions the lead starts").font(.headline)
                    Spacer()
                    Menu {
                        Button("Builder") {
                            draft.roles.append(StrategyRole(name: "Builder", kind: .builder, model: "sonnet",
                                                            duty: "Builds the part it is given, with tests."))
                        }
                        Button("Reviewer") {
                            draft.roles.append(StrategyRole(name: "Reviewer", kind: .reviewer, model: "opus", checkpoint: .eachStep,
                                                            duty: "Reads the diff and reports findings, most severe first, or LGTM."))
                        }
                        Button("Helper") { draft.roles.append(StrategyRole(name: "Tester", kind: .helper, model: "haiku",
                                                                            duty: "Runs the tests and reports failures.")) }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .fixedSize()
                }
                if draft.roles.isEmpty {
                    Text("None: the lead works alone. Add builders to split the work, or reviewers to check it along the way.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach($draft.roles) { $role in
                    RoleEditor(role: $role) { draft.roles.removeAll { $0.id == role.id } }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("How they work together").font(.headline)
                Text("Optional with sessions above. Numbered steps (1. …) become the steps in the diagram.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.instructions)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            }
        }
    }

    private func save() {
        var s = draft
        s.title = s.title.trimmingCharacters(in: .whitespaces)
        s.origin = .custom
        s.spawns = !s.roles.isEmpty
        if request.isNew {
            var slug = Strategy.slugify(s.title)
            while model.strategies.contains(where: { $0.slug == slug }) { slug += "-2" }
            s.slug = slug
        }
        model.saveStrategy(s)
        dismiss()
    }
}

private struct RoleEditor: View {
    @Binding var role: StrategyRole
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: StrategyTeamDiagram.icon(role.kind)).foregroundStyle(StrategyTeamDiagram.color(role.kind))
                TextField("Name", text: $role.name).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                Picker("", selection: $role.kind) {
                    ForEach(StrategyRole.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove this role")
            }
            FlowLayout(spacing: 12) {
                Picker("Model", selection: $role.model) {
                    ForEach(ModelChoice.all, id: \.tag) { Text($0.title).tag($0.tag) }
                }
                .fixedSize()
                Stepper("\(role.count) session\(role.count == 1 ? "" : "s")", value: $role.count, in: 1...6).fixedSize()
                if role.kind == .reviewer {
                    Picker("Checks", selection: $role.checkpoint) {
                        ForEach(StrategyRole.Checkpoint.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
            }
            TextField("What it does and how it behaves", text: $role.duty, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StrategyTeamDiagram.color(role.kind).opacity(0.3)))
    }
}
