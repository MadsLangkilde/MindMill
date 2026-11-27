import AppKit
import KBCore
import KBEngine
import Observation
import SwiftUI

/// One Ask conversation for one project, kept alive for follow-ups until "New Conversation".
@MainActor
@Observable
final class AskConversation {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        let sources: [String]?
        var answer: AskAnswer?
        var raw = ""
        var error: String?
        var savedAs: String?
        var saving = false
        /// Asked by clicking one of the previous answer's choices: shown there as picked, not as a question.
        var viaChoice = false
        /// The options picked from this answer's choices.
        var picked: Set<String>?
    }

    let project: String
    let chat = ClaudeChat()
    var turns: [Turn] = []
    var updated = Date()
    var input = ""
    /// Attached by "Ask Claude about this"; its context goes with the next question.
    var subject: AskSubject?
    /// Source ids switched off for the next question.
    var excluded: Set<String> = []

    init(project: String) {
        self.project = project
        chat.onEvent = { [weak self] in self?.handle($0) }
    }

    /// Answers the choices at the end of an answer: the option shows picked there, and goes to Claude as the next question.
    func choose(_ option: String, after turnID: UUID, model: AppModel) {
        guard let i = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[i].picked = Set(option.components(separatedBy: ", "))
        ask(option, model: model, viaChoice: true)
    }

    func ask(_ question: String, model: AppModel, viaChoice: Bool = false) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let configured = model.configuredSources(project: project).map(\.source).filter(\.enabled)
        let all = BuiltinSources.all.map(\.id) + configured.map(\.id)
        let chosen = excluded.isEmpty ? nil : all.filter { !excluded.contains($0) }
        if !chat.isRunning {
            let cwd = ClaudeLaunch.workingDirectory(project: model.index.project(project), root: model.rootURL)
            guard let launch = model.launch(prompt: ClaudeModes.ask(project), sessionID: UUID().uuidString.lowercased(),
                                            resume: false, model: model.model(for: .ask), cwd: cwd,
                                            tools: AskTools.allowedTools(sources: configured)) else {
                model.errorMessage = model.claudeMissingExplanation
                return
            }
            do { try chat.start(launch, mode: "ask") } catch {
                model.errorMessage = "Could not start claude: \(error.localizedDescription)"
                return
            }
            chat.send(ClaudeModes.warmup, tag: "connect", show: false)
        }
        let about = subject
        var turn = Turn(question: about.map { "About “\($0.title)”: \(q)" } ?? q, sources: chosen)
        turn.viaChoice = viaChoice
        turns.append(turn)
        updated = Date()
        input = ""
        subject = nil
        let message = ClaudeModes.askMessage(q, sources: chosen)
        chat.send(about.map { "\($0.context)\n\nQuestion: \(message)" } ?? message, tag: turn.id.uuidString, show: false)
    }

    func newConversation() {
        chat.reset()
        turns = []
    }

    private func handle(_ event: ClaudeEvent) {
        guard case .turnResult(let text, let isError, let tag) = event,
              let i = turns.firstIndex(where: { $0.id.uuidString == tag }) else { return }
        if isError {
            turns[i].error = text
        } else {
            turns[i].raw = text
            turns[i].answer = AskAnswer.parse(text)
        }
    }

    func saveAsFact(_ turnID: UUID, model: AppModel) {
        guard let i = turns.firstIndex(where: { $0.id == turnID }), let answer = turns[i].answer else { return }
        let firstLine = answer.body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? turns[i].question
        var title = firstLine.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        title = title.replacingOccurrences(of: #"\s*\[\d+\]"#, with: "", options: .regularExpression)
        if title.count > 90 { title = String(title.prefix(87)).trimmingCharacters(in: .whitespaces) + "…" }
        let sources = answer.citations.map { "[\($0.number)] \($0.source) — \($0.ref) — \($0.title)" }.joined(separator: "\n")
        let body = "Q: \(turns[i].question)\n\n\(answer.body)\n" + (sources.isEmpty ? "" : "\nSources:\n\(sources)\n")
        let proposer = "ask:\(chat.sessionID ?? "unknown")"
        turns[i].saving = true
        let cli = model.cli
        let project = project
        Task {
            do {
                let id = try await cli.addInboxFact(project: project, title: title, proposedBy: proposer, reason: "from Ask", body: body)
                if let j = turns.firstIndex(where: { $0.id == turnID }) { turns[j].savedAs = id.isEmpty ? "inbox" : id }
                model.notice = "Proposed as a fact. Approve it in the Inbox."
                model.reload()
            } catch {
                model.errorMessage = error.localizedDescription
            }
            if let j = turns.firstIndex(where: { $0.id == turnID }) { turns[j].saving = false }
        }
    }
}

struct AskWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let p = model.project {
                AskView(conversation: model.conversation(for: p.id), project: p)
                    .id(p.id)
            } else {
                ListEmptyState(title: "No scope", systemImage: "questionmark.bubble")
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .navigationTitle("Ask — \(model.project?.title ?? "")")
    }
}

struct AskView: View {
    @Environment(AppModel.self) private var model
    @Bindable var conversation: AskConversation
    let project: KBProject
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ask").font(.headline)
                    Text(project.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    conversation.newConversation()
                    inputFocused = true
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
                .disabled(conversation.turns.isEmpty && !conversation.chat.isRunning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if conversation.turns.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ask anything about \(project.title).").font(.title3.weight(.semibold))
                                Text("\(Brain.name) answers from the knowledge base, the code and docs, related scopes and the sources below, and cites each claim. Follow-up questions keep the context.")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 30)
                        }
                        ForEach(conversation.turns) { turn in
                            AskTurnView(conversation: conversation, turn: turn).id(turn.id)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: conversation.turns.count) { _, _ in
                    if let last = conversation.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                }
            }
            Divider()
            AskSubjectChip(conversation: conversation)
            SourceChips(conversation: conversation, project: project)
            HStack(alignment: .bottom, spacing: 8) {
                TextField(conversation.subject.map { "Ask about “\($0.title)”…" } ?? "Ask about \(project.title)…", text: $conversation.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...)
                    .scrollingInput(conversation.input, maxLines: 6)
                    .focused($inputFocused)
                    .onSubmit(ask)
                    .promptKeys($conversation.input)
                Button(action: ask) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(conversation.input.trimmingCharacters(in: .whitespaces).isEmpty || !claudeAvailable)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .padding(.top, 4)
            if !claudeAvailable {
                Text(model.claudeMissingExplanation).font(.caption).foregroundStyle(.orange).padding(.bottom, 8)
            }
        }
        .onAppear { inputFocused = true }
        .onChange(of: conversation.subject) { _, _ in inputFocused = true }
    }

    private func ask() {
        model.recordPrompt(conversation.input)
        conversation.ask(conversation.input, model: model)
    }

    private var claudeAvailable: Bool { if case .found = model.claudeAvailability { return true } else { return false } }
}

struct SourceChips: View {
    @Environment(AppModel.self) private var model
    @Bindable var conversation: AskConversation
    let project: KBProject

    var body: some View {
        let configured = model.configuredSources(project: project.id).filter { $0.source.enabled }
        let chips: [(id: String, title: String, icon: String)] =
            BuiltinSources.all.map { ($0.id, $0.title, $0.id == BuiltinSources.kb ? "books.vertical" : $0.id == BuiltinSources.code ? "chevron.left.forwardslash.chevron.right" : "link") }
            + configured.map { ($0.source.id, $0.source.title, SourceRow.icon($0.source.kind)) }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Sources").font(.caption).foregroundStyle(.secondary)
                ForEach(chips, id: \.id) { chip in
                    let on = !conversation.excluded.contains(chip.id)
                    Button {
                        if on { conversation.excluded.insert(chip.id) } else { conversation.excluded.remove(chip.id) }
                    } label: {
                        Label(chip.title, systemImage: chip.icon)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                            .background(on ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08), in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Color.accentColor.opacity(0.35) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .help(on ? "Used for the next question. Click to leave it out." : "Left out. Click to use it.")
                }
                Button {
                    model.projectSettingsRequest = ProjectSettingsRequest(project: project.id, tab: .sources)
                    NSApp.windows.first { $0.title.hasPrefix("Mindmill") }?.makeKeyAndOrderFront(nil)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Add a knowledge source")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

struct AskTurnView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chooseLink) private var chooseLink
    let conversation: AskConversation
    let turn: AskConversation.Turn
    @State private var multiPicked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !turn.viaChoice {
            HStack(alignment: .top) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(turn.question)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        .textSelection(.enabled)
                    if let s = turn.sources {
                        Text("only: \(s.joined(separator: ", "))").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            }
            if let error = turn.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
            } else if let answer = turn.answer {
                Text(InlineMarkdown.attributed(ChoiceAnswer.withoutChoices(answer.body), citationLinks: true))
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "kbcite", let n = Int(url.absoluteString.dropFirst("kbcite:".count)),
                           let c = answer.citations.first(where: { $0.number == n }) {
                            CitationOpener.open(c, model: model)
                            return .handled
                        }
                        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                            chooseLink(url)
                            return .handled
                        }
                        return .systemAction
                    })
                if let c = MarkdownBlocks.trailingChoices(answer.body) {
                    ChoicesView(multi: c.multi, options: c.options, handler: handler(multi: c.multi), answered: turn.picked)
                }
                if !answer.citations.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(answer.citations) { c in CitationChip(citation: c) }
                    }
                }
                HStack(spacing: 10) {
                    if let saved = turn.savedAs {
                        Label("Proposed as a fact (\(saved))", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                    } else {
                        Button {
                            conversation.saveAsFact(turn.id, model: model)
                        } label: {
                            Label("Save as Fact", systemImage: "lightbulb")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(turn.saving)
                        if turn.saving { ProgressView().controlSize(.mini) }
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(turn.raw, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(conversation.chat.activity.map { "Looking… (\(ToolName.friendly($0)))" } ?? "Thinking…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

enum ToolName {
    static func friendly(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.split(separator: "_", omittingEmptySubsequences: true)
            return parts.dropFirst().joined(separator: " ")
        }
        return name
    }
}

extension AskTurnView {
    /// Live only on the last answer, while nothing is picked and no question runs.
    func handler(multi: Bool) -> ChoiceHandler? {
        guard turn.picked == nil, conversation.turns.last?.id == turn.id, !conversation.chat.isBusy else { return nil }
        let id = turn.id
        return ChoiceHandler(
            multi: multi,
            picked: multiPicked,
            toggle: { o in if multiPicked.contains(o) { multiPicked.remove(o) } else { multiPicked.insert(o) } },
            choose: { answer in conversation.choose(answer, after: id, model: model) })
    }
}

struct CitationChip: View {
    @Environment(AppModel.self) private var model
    let citation: Citation

    var body: some View {
        Button {
            CitationOpener.open(citation, model: model)
        } label: {
            HStack(spacing: 4) {
                Text("\(citation.number)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Color.accentColor, in: Circle())
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption).lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("\(citation.source) — \(citation.ref)")
    }

    private var label: String {
        if !citation.title.isEmpty { return citation.title }
        if case .entry(let id) = citation.target { return model.index.entry(id)?.title ?? id.rawValue }
        return citation.ref.isEmpty ? citation.source : citation.ref
    }

    private var icon: String {
        switch citation.target {
        case .entry: return "books.vertical"
        case .file: return "doc"
        case .url: return "globe"
        case .other: return "number"
        }
    }
}

enum CitationOpener {
    @MainActor
    static func open(_ c: Citation, model: AppModel) {
        switch c.target {
        case .entry(let id):
            if id.project != model.projectID { model.notice = "Switched to \(model.index.project(id.project)?.title ?? id.project)." }
            model.openLink(id.rawValue)
            NSApp.windows.first { $0.title.hasPrefix("Mindmill") }?.makeKeyAndOrderFront(nil)
        case .url(let u):
            NSWorkspace.shared.open(u)
        case .file(let path):
            let cleaned = path.replacingOccurrences(of: #":\d+(-\d+)?$"#, with: "", options: .regularExpression)
            let expanded = KBConfig.expandTilde(cleaned)
            var url = URL(fileURLWithPath: expanded)
            if !expanded.hasPrefix("/") {
                url = ClaudeLaunch.workingDirectory(project: model.project, root: model.rootURL).appendingPathComponent(cleaned)
            }
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
            } else {
                model.errorMessage = "\(url.path) does not exist."
            }
        case .other(let ref):
            if let u = RefLink.url(ref, model: model) { NSWorkspace.shared.open(u) } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ref, forType: .string)
                model.notice = "Copied \(ref)."
            }
        }
    }
}

/// Wraps chips onto as many lines as needed.
