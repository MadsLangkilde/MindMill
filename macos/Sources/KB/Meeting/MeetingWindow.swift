import KBCore
import KBEngine
import SwiftUI

struct MeetingWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meetingID: String

    var body: some View {
        let controller = EntryID(meetingID).flatMap { $0.section == .meetings ? model.meetingController(for: $0) : nil }
        Group {
            if let controller {
                if controller.missing {
                    ListEmptyState(title: "Meeting not found", systemImage: "person.2.slash", message: "\(meetingID) no longer exists.")
                } else {
                    MeetingContent(c: controller)
                }
            } else {
                ListEmptyState(title: "Not a meeting", systemImage: "person.2.slash", message: meetingID)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle("\(controller?.title ?? "Meeting") — Meeting")
        .onAppear {
            // A restored window for a meeting that is gone (or another root) closes itself.
            guard let controller, !controller.missing else {
                DispatchQueue.main.async { dismiss() }
                return
            }
            controller.windowAppeared()
        }
        .onDisappear {
            if let id = EntryID(meetingID) { model.closeMeetingController(id) }
        }
        .onChange(of: model.indexVersion) { _, _ in controller?.load() }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "kb" else { return .systemAction }
            model.handle(url: url)
            NSApp.windows.first { $0.title.hasPrefix("Mindmill") }?.makeKeyAndOrderFront(nil)
            return .handled
        })
    }
}

struct MeetingContent: View {
    @Environment(AppModel.self) private var model
    @Bindable var c: MeetingController

    var body: some View {
        VStack(spacing: 0) {
            MeetingHeader(c: c)
            Divider()
            switch c.stage {
            case .prepare: PrepareStage(c: c)
            case .live: LiveStage(c: c)
            case .summarizing: SummarizingStage(c: c)
            case .review: ReviewStage(c: c)
            case .filed: FiledStage(c: c)
            }
            if let notice = c.notice {
                NoticeBar(text: notice, seconds: 6) { c.notice = nil }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.2), value: c.notice)
        .sheet(isPresented: $c.pbiSheet) { MeetingPBISheet(c: c) }
        .sheet(item: $c.createAfterFiling) { request in BacklogBatchCreateSheet(request: request) }
    }
}

// MARK: Header

struct MeetingHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let c: MeetingController
    @State private var renaming = false
    @State private var editingAttendees = false
    @State private var newTitle = ""

    private func move(to project: String) {
        let old = c.id
        model.moveEntry(old, to: project) { new in
            dismiss()
            model.openMeeting(new)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title).font(.title2.weight(.semibold)).lineLimit(1)
                    .onTapGesture(count: 2) {
                        newTitle = c.title
                        renaming = true
                    }
                    .help("Double-click to rename")
                ChipRow(spacing: 8) {
                    Label(c.projectTitle, systemImage: "folder.fill").foregroundStyle(Color.accentColor)
                    if c.projectGuessed {
                        Menu("Project guessed") {
                            Section("Move this meeting to") {
                                ForEach(model.index.projects.filter { $0.id != c.id.project }, id: \.id) { p in
                                    Button(p.title) { move(to: p.id) }
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .foregroundStyle(.orange)
                        .help("Calendar sync picked this project. Move the meeting if it belongs elsewhere; later meetings in the series follow.")
                    }
                    if c.isCancelled { Chip(text: "Cancelled", color: .red) }
                    if !c.date.isEmpty { Text(DateText.display(c.date)).fixedSize() }
                    if !c.start.isEmpty { Text(c.end.isEmpty ? c.start : "\(c.start)–\(c.end)").monospacedDigit().fixedSize() }
                    Button {
                        editingAttendees = true
                    } label: {
                        Label(c.attendees.isEmpty ? "Add attendees" : c.attendees.joined(separator: ", "), systemImage: "person.2")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Add or remove attendees")
                    .popover(isPresented: $editingAttendees, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Attendees").font(.headline)
                            PeoplePicker(names: Binding(get: { c.attendees }, set: { c.setAttendees($0) }),
                                         placeholder: "Search Azure DevOps, or type a name")
                        }
                        .padding(14)
                        .frame(width: 380)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            StageTrack(stage: c.stage).fixedSize()
            Spacer(minLength: 8)
            if c.stage == .live {
                ClaudeIndicator(c: c)
                ElapsedTimer(since: c.liveStartedAt ?? Date())
            }
            if c.stage == .prepare || c.stage == .live {
                let n = c.meetingBacklog.count
                Button {
                    c.pbiSheet = true
                } label: {
                    Label(n == 0 ? "PBI" : "PBIs · \(n)", systemImage: "plus.rectangle.on.rectangle")
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .help("Add a PBI or bug from this meeting (⌥⌘B)")
            }
            if let url = c.onlineURL, c.stage == .prepare || c.stage == .live {
                Link(destination: url) { Label("Join", systemImage: "video").lineLimit(1) }
                    .fixedSize()
                    .help("Open the online meeting")
            }
            Menu {
                Button("Ask \(Brain.name) About This…") { model.askAbout(.entry(c.id, title: c.title)) }
                Button("Rename…") {
                    newTitle = c.title
                    renaming = true
                }
                Menu("Move to Project") {
                    ForEach(model.index.projects.filter { $0.id != c.id.project }, id: \.id) { p in
                        Button(p.title) { move(to: p.id) }
                    }
                }
                Button("Continue in Terminal") { c.continueInTerminal() }
                    .disabled(c.sessionID == nil)
                Button("Open in Mindmill") { model.openLink(c.id.rawValue) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.id.fileURL(root: model.rootURL)]) }
                if let sid = c.sessionID {
                    Divider()
                    Text("Session \(sid)")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .alert("Rename Meeting", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") { c.rename(newTitle) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct StageTrack: View {
    let stage: MeetingController.Stage

    var body: some View {
        let steps: [(String, [MeetingController.Stage])] = [
            ("Prepare", [.prepare]), ("Live", [.live]), ("Review", [.summarizing, .review]), ("Filed", [.filed]),
        ]
        let current = steps.firstIndex { $0.1.contains(stage) } ?? 0
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                if i > 0 {
                    Rectangle().fill(i <= current ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)).frame(width: 18, height: 1.5)
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(i < current ? Color.accentColor : i == current ? (stage == .live ? Color.red : Color.accentColor) : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                    Text(step.0)
                        .font(.caption.weight(i == current ? .semibold : .regular))
                        .foregroundStyle(i == current ? .primary : .secondary)
                }
            }
        }
    }
}

struct ClaudeIndicator: View {
    let c: MeetingController

    var body: some View {
        HStack(spacing: 5) {
            if c.isReading {
                ProgressView().controlSize(.mini)
                Text("\(Brain.name) is reading…")
            } else if c.chat.isRunning {
                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                Text("\(Brain.name) follows your notes")
            } else {
                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text("\(Brain.name) is off")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: 150, alignment: .trailing)
    }
}

struct ElapsedTimer: View {
    let since: Date

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(since)))
            Text(s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

// MARK: Prepare

struct PrepareStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var c: MeetingController
    @State private var newQuestion = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Questions").font(.headline)
                        if c.ready { Chip(text: "Prepared", color: .green) }
                        Spacer()
                    }
                    Text("Pick the suggestions you want to bring up; they move to Prepared questions. Only those go into the meeting once you are done. If you start without preparing, all suggestions come along under Suggested.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 6)
                List {
                    Section {
                        if c.questions.questions.isEmpty {
                            Text(c.suggested.questions.isEmpty ? "None yet." : "None picked yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(c.questions.questions) { q in
                            QuestionEditRow(c: c, question: q)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            TextField("Add your own question", text: $newQuestion)
                                .textFieldStyle(.plain)
                                .onSubmit {
                                    let t = newQuestion.trimmingCharacters(in: .whitespaces)
                                    guard !t.isEmpty else { return }
                                    c.addQuestion(t)
                                    newQuestion = ""
                                }
                        }
                    } header: {
                        let qs = c.questions.questions
                        HStack {
                            Text("Prepared questions")
                            if !qs.isEmpty {
                                Text("\(qs.count)\(qs.contains(where: \.done) ? " · \(qs.filter(\.done).count) answered" : "")")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !c.suggested.questions.isEmpty {
                        Section {
                            ForEach(c.suggested.questions) { q in
                                SuggestionRow(c: c, question: q)
                            }
                        } header: {
                            HStack {
                                Text("Suggested")
                                Text("\(c.suggested.questions.count)").foregroundStyle(.secondary)
                                Spacer()
                                Button("Pick All") { c.pickAll() }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 200)
                Divider()
                MeetingMaterialsView(c: c)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Prep").font(.headline)
                        ChipRow(spacing: 6) {
                            ForEach(PrepLinks.find(c.prep), id: \.self) { url in
                                Button {
                                    model.openCapture(url, for: .meeting(c.id))
                                } label: {
                                    Label(PrepLinks.label(url), systemImage: "globe")
                                        .font(.caption)
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                .controlSize(.small)
                                .help("Open \(url.absoluteString) in Mindmill's browser, sign in if asked, and share its text with \(Brain.name)")
                            }
                        }
                    }
                    if c.prep.isEmpty {
                        Text("\(Brain.name) writes context it gathers here (earlier decisions, open follow-ups, code).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        MarkdownWebView(
                            html: MarkdownRenderer.page(body: MarkdownRenderer(linkRewriter: MarkdownRenderer.entryLinkRewriter).render(c.prep),
                                                        accentHex: NSColor.controlAccentColor.hexString),
                            baseURL: c.id.fileURL(root: model.rootURL).deletingLastPathComponent(),
                            onLink: { model.openLink($0) }
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minHeight: 160)
                Divider()
                HStack {
                    Text(c.ready || c.suggested.questions.isEmpty
                         ? "Starting sets the meeting live with the prepared questions. Notes are saved as you type."
                         : "Done saves your picks for later. Starting now brings all suggestions along.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Done") {
                        c.finishPreparing()
                        dismiss()
                    }
                    .controlSize(.large)
                    .help("Done preparing: keep the picked questions for the meeting and close the window")
                    Button {
                        c.startMeeting()
                    } label: {
                        Label("Start Meeting", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .frame(minWidth: 420)
            PrepChat(c: c)
                .frame(minWidth: 320, idealWidth: 380)
        }
    }
}

struct QuestionEditRow: View {
    @Bindable var c: MeetingController
    let question: QuestionList.Question
    @State private var text = ""
    @FocusState private var answerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let g = question.group, c.questions.questions.first(where: { $0.group == g })?.id == question.id {
                Text(g).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AnsweredButton(done: question.done) {
                    c.setAnswered(question.id, !question.done)
                    if !question.done { answerFocused = true }
                }
                TextField("Question", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(question.done ? .secondary : .primary)
                    .lineLimit(1...)
                    .scrollingInput(text, maxLines: 4)
                    .onSubmit { commit() }
                    .onChange(of: text) { _, _ in commit() }
                Button {
                    c.unpick(question.id)
                } label: {
                    Image(systemName: "minus.circle").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Leave it out of the meeting. It goes back to the suggestions.")
            }
            if question.done || !question.answer.isEmpty {
                AnswerField(c: c, question: question, focused: $answerFocused)
                    .padding(.leading, 24)
            }
        }
        .onAppear { text = question.text }
        .onChange(of: question.text) { _, new in if new != text { text = new } }
    }

    private func commit() {
        guard text != question.text else { return }
        c.questions.set(question.id, text: text)
        c.questionsEdited()
    }
}

/// A suggestion: + picks it for the meeting, × drops it.
struct SuggestionRow: View {
    @Bindable var c: MeetingController
    let question: QuestionList.Question

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let g = question.group, c.suggested.questions.first(where: { $0.group == g })?.id == question.id {
                Text(g).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    c.pick(question.id)
                } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .help("Bring this up in the meeting")
                Text(question.text)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Button {
                    c.dismissSuggestion(question.id)
                } label: {
                    Image(systemName: "xmark.circle").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Drop this suggestion")
            }
        }
    }
}

struct AnsweredButton: View {
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : .secondary)
        }
        .buttonStyle(.borderless)
        .help(done ? "Answered. Click to mark it open again." : "Mark answered and write the answer")
    }
}

/// The answer under a ticked question, saved as an indented `- Answer:` line in `## Questions`.
struct AnswerField: View {
    @Bindable var c: MeetingController
    let question: QuestionList.Question
    var focused: FocusState<Bool>.Binding
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
            TextField("Answer", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...)
                .scrollingInput(text, maxLines: 5)
                .focused(focused)
                .onChange(of: text) { _, new in
                    if new != question.answer { c.setAnswer(question.id, new) }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .onAppear { text = question.answer }
        .onChange(of: question.answer) { _, new in
            if new != text.trimmingCharacters(in: .whitespaces) { text = new }
        }
    }
}

struct PrepChat: View {
    @Environment(AppModel.self) private var model
    @Bindable var c: MeetingController

    var body: some View {
        VStack(spacing: 0) {
            ConnectorBanner()
            HStack {
                Label("\(Brain.name)", systemImage: "sparkles").font(.headline)
                Spacer()
                if c.chat.items.isEmpty && !c.chat.isBusy {
                    Button("Prepare with \(Brain.name)") { c.prepareWithClaude() }
                        .disabled(!claudeAvailable)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ChatTranscript(chat: c.chat, emptyHint: claudeAvailable
                           ? "Ask \(Brain.name) to gather context and add questions: “add questions about the upload format”. It edits Prep and Questions in the file."
                           : model.claudeMissingExplanation,
                           onChoice: { answer in
                               c.chatInput = answer
                               c.sendChat()
                           })
                .environment(\.captureTarget, .meeting(c.id))
            Divider()
            HStack(spacing: 8) {
                ShareWebPageButton(target: .meeting(c.id))
                TextField("Talk to \(Brain.name) about this meeting…", text: $c.chatInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...)
                    .scrollingInput(c.chatInput, maxLines: 4)
                    .onSubmit { c.sendChat() }
                Button {
                    c.sendChat()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(c.chatInput.trimmingCharacters(in: .whitespaces).isEmpty || !claudeAvailable)
            }
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    private var claudeAvailable: Bool { if case .found = model.claudeAvailability { return true } else { return false } }
}

// MARK: Live

struct LiveStage: View {
    @Bindable var c: MeetingController
    @AppStorage("meetingTranscriptShown") private var transcriptShown = true

    var body: some View {
        VStack(spacing: 0) {
            QuestionsStrip(c: c)
            Divider()
            MeetingMaterialsView(c: c)
            Divider()
            liveSplit
            Divider()
            bottomBar
        }
        .alert("Tell everyone you're transcribing", isPresented: $c.showTranscriptConsent) {
            Button("Start Transcribing") { c.beginTranscription() }
            Button("Start, and Don't Remind Me Again") {
                UserDefaults.standard.set(true, forKey: AppSettingsKeys.transcriptConsentAcknowledged)
                c.beginTranscription()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mindmill turns the meeting's audio into text on this Mac, and reads the text of a window you pick to read along with. The audio is never stored or sent anywhere; the text is saved in the meeting file and read by \(Brain.name). Let the attendees know before you start.")
        }
    }

    private var liveSplit: some View {
            HSplitView {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            NotesTextView(
                                text: c.notes,
                                onChange: { c.notesChanged($0) },
                                anchors: Dictionary(uniqueKeysWithValues: c.tracker.notes.map { ($0.id, $0.anchor) }),
                                onPositions: { if c.positions != $0 { c.positions = $0 } }
                            )
                            if c.notes.isEmpty {
                                Text("Type notes. A blank line, or a short pause, sends the paragraph to \(Brain.name).\nIt only speaks up when something conflicts with what is decided.")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 23)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: geo.size.width * 0.68)
                        Divider()
                        FlagGutter(notes: c.tracker.notes, flags: c.flags, pending: c.pendingNotes, positions: c.positions)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.secondary.opacity(0.03))
                    }
                }
                .frame(minWidth: 420)
                if transcriptShown {
                    TranscriptPanel(c: c, onHide: { transcriptShown = false })
                        .frame(minWidth: 260, idealWidth: 340, maxWidth: 560)
                }
            }
    }

    private var bottomBar: some View {
            HStack(spacing: 12) {
                Label(c.notesSaved ? "Saved" : "Saving…", systemImage: c.notesSaved ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let warnings = c.flags.values.flatMap { $0 }.filter { $0.kind == .warning }.count
                if warnings > 0 {
                    Label("\(warnings) to check", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if !transcriptShown, c.transcriber.isOn {
                    HiddenTranscriptCaption(c: c)
                }
                if !transcriptShown {
                    Button {
                        transcriptShown = true
                    } label: {
                        Label(c.transcriber.isOn ? "Transcript (on)" : "Transcript", systemImage: "waveform")
                    }
                    .help("Show the transcript next to the notes")
                }
                Button {
                    c.finishMeeting()
                } label: {
                    Label("Done", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("End the meeting: \(Brain.name) writes the summary and proposes entries (⌘↩)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct QuestionsStrip: View {
    @Bindable var c: MeetingController

    var body: some View {
        let qs = c.questions.questions
        let answered = qs.filter(\.done).count
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { c.questionsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(c.questionsExpanded ? 90 : 0))
                        .font(.caption)
                    Text("Questions").font(.subheadline.weight(.semibold))
                    Text("\(answered) of \(qs.count) answered").font(.caption).foregroundStyle(.secondary)
                    if qs.count > 0 {
                        ProgressView(value: Double(answered), total: Double(max(qs.count, 1)))
                            .frame(width: 80)
                            .controlSize(.mini)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if c.questionsExpanded && !qs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        let prepared = qs.filter { !QuestionList.isSuggested(group: $0.group) }
                        let suggested = qs.filter { QuestionList.isSuggested(group: $0.group) }
                        if !prepared.isEmpty {
                            LiveQuestionHeading(title: "Prepared questions")
                            ForEach(prepared) { q in LiveQuestionRow(c: c, question: q) }
                        }
                        if !suggested.isEmpty {
                            LiveQuestionHeading(title: "Suggested").padding(.top, prepared.isEmpty ? 0 : 6)
                            ForEach(suggested) { q in
                                if let g = QuestionList.displayGroup(q.group), suggested.first(where: { $0.group == q.group })?.id == q.id {
                                    Text(g).font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
                                }
                                LiveQuestionRow(c: c, question: q)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

struct LiveQuestionHeading: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}

struct LiveQuestionRow: View {
    @Bindable var c: MeetingController
    let question: QuestionList.Question
    @FocusState private var answerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AnsweredButton(done: question.done) {
                    c.setAnswered(question.id, !question.done)
                    if !question.done { answerFocused = true }
                }
                Text(question.text)
                    .foregroundStyle(question.done ? .secondary : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
            if question.done || !question.answer.isEmpty {
                AnswerField(c: c, question: question, focused: $answerFocused)
                    .padding(.leading, 22)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: question.done)
    }
}

// MARK: Summarizing

struct SummarizingStage: View {
    @Bindable var c: MeetingController

    var body: some View {
        VStack(spacing: 16) {
            if let error = c.reviewError {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("The summary did not finish").font(.title3.weight(.semibold))
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520).textSelection(.enabled)
                HStack {
                    Button("Back to Notes") { c.backToLive() }
                    Button("Review Without \(Brain.name)") { c.reviewWithoutClaude() }
                    Button("Try Again") { c.retryReview() }.buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView().controlSize(.large)
                Text("\(Brain.name) is writing the summary").font(.title3.weight(.semibold))
                if !c.transcript.isEmpty {
                    Text("and, apart from it, what the transcript adds").font(.callout).foregroundStyle(.secondary)
                }
                let proposed = c.inboxCards.count + c.backlogCards.count
                if proposed > 0 {
                    Text("\(proposed) proposal\(proposed == 1 ? "" : "s") so far").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: Review

struct ReviewStage: View {
    @Environment(AppModel.self) private var model
    @Bindable var c: MeetingController
    @State private var editing: EntryID?

    var body: some View {
        let inbox = c.inboxCards
        let backlog = c.backlogCards
        VStack(spacing: 0) {
        HSplitView {
            VSplitView {
                summaryPane
                    .frame(minHeight: 200)
                if !c.transcriptParts.isEmpty || !c.transcript.isEmpty {
                    TranscriptPartsPane(c: c)
                        .frame(minHeight: c.transcriptParts.isEmpty ? 60 : 180, idealHeight: c.transcriptParts.isEmpty ? 60 : 300)
                }
            }
            .frame(minWidth: 380, idealWidth: 480)
            proposedPane(inbox: inbox, backlog: backlog)
                .frame(minWidth: 380, idealWidth: 460)
        }
        Divider()
            HStack(spacing: 12) {
                if !c.fileErrors.isEmpty {
                    Label(c.fileErrors.joined(separator: " · "), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else {
                    let keep = (inbox + backlog).filter { c.isTicked($0.id) }.count
                    Text("Ticked inbox entries are approved, unticked ones rejected. Ticked backlog items are offered for creating next, with sprint and assignee; unticked ones are rejected. \(keep) ticked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if c.filing { ProgressView().controlSize(.small) }
                Button {
                    c.fileSelected()
                } label: {
                    Label("File Selected", systemImage: "tray.and.arrow.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(c.filing)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(item: Binding(get: { editing.map(EditTarget.init) }, set: { editing = $0?.id })) { t in
            InlineEntryEditor(id: t.id)
        }
    }

    private var summaryPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Summary").font(.headline)
                if !c.transcriptParts.isEmpty { Text("from your notes").foregroundStyle(.secondary) }
                Spacer()
                if c.summaryDirty {
                    Button("Save") { c.saveSummary() }.keyboardShortcut("s")
                }
                Picker("", selection: $c.summaryEditing) {
                    Label("Preview", systemImage: "eye").tag(false)
                    Label("Edit", systemImage: "pencil").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            Divider()
            if c.summaryEditing {
                TextEditor(text: Binding(get: { c.summary }, set: { c.summary = $0; c.summaryDirty = true }))
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
            } else if c.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ListEmptyState(title: "No summary yet", systemImage: "doc.text", message: "Switch to Edit to write one.")
            } else {
                MarkdownWebView(
                    html: MarkdownRenderer.page(body: MarkdownRenderer(linkRewriter: MarkdownRenderer.entryLinkRewriter).render(c.summary),
                                                accentHex: NSColor.controlAccentColor.hexString),
                    baseURL: c.id.fileURL(root: model.rootURL).deletingLastPathComponent(),
                    onLink: { model.openLink($0) }
                )
            }
        }
    }

    private func proposedPane(inbox: [KBEntry], backlog: [KBEntry]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Proposed").font(.headline)
                Text("\(inbox.count + backlog.count)").foregroundStyle(.secondary)
                Spacer()
                if let n = c.proposedCount, n != inbox.count + backlog.count {
                    Text("\(Brain.name) reported \(n)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if inbox.isEmpty && backlog.isEmpty {
                ListEmptyState(title: "Nothing proposed", systemImage: "tray",
                               message: "Filing only sets the meeting to filed.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(inbox) { e in
                            ReviewCard(c: c, entry: e, isBacklog: false, onEdit: { editing = e.id })
                        }
                        if !backlog.isEmpty {
                            Text("Backlog (you pick sprint and assignee after filing)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                            ForEach(BacklogTwins.group(backlog), id: \.first!.id) { twins in
                                if twins.count == 1, let e = twins.first {
                                    ReviewCard(c: c, entry: e, isBacklog: true, onEdit: { editing = e.id })
                                } else {
                                    TwinReviewCard(c: c, entries: twins, onEdit: { editing = $0 })
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    struct EditTarget: Identifiable {
        let id: EntryID
    }
}

/// The transcript's summary in parts: tick the ones the final summary keeps, or leave the transcript out entirely.
struct TranscriptPartsPane: View {
    @Bindable var c: MeetingController

    var body: some View {
        let parts = c.transcriptParts
        let kept = c.keptParts.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("From the transcript", systemImage: "waveform").font(.headline)
                if !parts.isEmpty {
                    Text(c.useTranscript ? "\(kept) of \(parts.count) kept" : "left out").foregroundStyle(.secondary)
                }
                Spacer()
                if !parts.isEmpty {
                    Toggle("Use", isOn: Binding(get: { c.useTranscript }, set: { c.setUseTranscript($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Leave the whole transcript out: none of its parts, and its proposals unticked")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            Divider()
            if !parts.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What was said that your notes don't have. Kept parts are added to the summary under “From the conversation” when you file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(parts) { part in
                            TranscriptPartCard(c: c, part: part)
                        }
                    }
                    .padding(14)
                }
                .disabled(!c.useTranscript)
                .opacity(c.useTranscript ? 1 : 0.5)
            }
            Toggle("Keep the full transcript in the meeting file", isOn: $c.keepTranscript)
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .help("Off: the transcript lines are deleted from the file when you file the meeting")
        }
    }
}

struct TranscriptPartCard: View {
    @Bindable var c: MeetingController
    let part: TranscriptSummary.Part

    var body: some View {
        let kept = !c.leftOutParts.contains(part.id)
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { kept }, set: { on in
                if on { c.leftOutParts.remove(part.id) } else { c.leftOutParts.insert(part.id) }
            }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                if !part.title.isEmpty {
                    Text(part.title).font(.callout.weight(.semibold)).strikethrough(!kept)
                }
                Text(InlineMarkdown.attributed(part.body))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.secondary.opacity(kept ? 0.07 : 0.03), in: RoundedRectangle(cornerRadius: 8))
        .opacity(kept ? 1 : 0.6)
    }
}

struct ReviewCard: View {
    @Environment(AppModel.self) private var model
    let c: MeetingController
    let entry: KBEntry
    let isBacklog: Bool
    let onEdit: () -> Void

    var body: some View {
        let ticked = c.isTicked(entry.id)
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { ticked }, set: { c.setTicked(entry.id, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if isBacklog {
                        KindChip(kind: entry.backlogKind)
                        ProjectChip(project: entry.project)
                    } else if let s = entry.proposedSection { SectionChip(section: s) }
                    Spacer()
                    Button("Edit", action: onEdit).buttonStyle(.borderless).controlSize(.small)
                }
                Text(entry.title).font(.headline).foregroundStyle(ticked ? .primary : .secondary).strikethrough(!ticked)
                if !entry.summary.isEmpty {
                    Text(entry.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                ForEach(entry.supersedes, id: \.self) { old in
                    let oldTitle = EntryID(old).flatMap { model.index.entry($0)?.title } ?? old
                    Label("replaces \(oldTitle)", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let reason = entry.reason {
                    if MeetingController.fromTranscript(entry) {
                        Label(reason, systemImage: "waveform").font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                    } else {
                        Text(reason).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(ticked ? 0.07 : 0.03), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.15)))
        .opacity(ticked ? 1 : 0.7)
    }
}

/// Title, summary and body of one proposed entry, saved straight to its file.
struct InlineEntryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: EntryID
    @State private var doc: EntryDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let d = doc {
                Text("Edit Proposal").font(.title2.weight(.semibold))
                TextField("Title", text: Binding(get: { doc?.frontmatter.string("title") ?? "" }, set: { doc?.frontmatter.setString("title", $0) }))
                    .font(.title3)
                TextField("Summary", text: Binding(get: { doc?.frontmatter.string("summary") ?? "" }, set: { doc?.frontmatter.setString("summary", $0) }))
                TextEditor(text: Binding(get: { doc?.body ?? "" }, set: { doc?.body = $0 }))
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 220)
                    .border(Color.secondary.opacity(0.2))
                HStack {
                    Text(d.id.rawValue).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        guard var d = doc else { return }
                        do {
                            try KBStore.save(&d, root: model.rootURL)
                            model.reload()
                            dismiss()
                        } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(doc?.isDirty ?? false))
                }
            } else {
                ProgressView()
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 620, height: 460)
        .onAppear { doc = try? KBStore.load(id, root: model.rootURL) }
    }
}

// MARK: Filed

struct FiledStage: View {
    @Environment(AppModel.self) private var model
    let c: MeetingController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Filed").font(.headline)
                    Text("The meeting and its approved entries are in \(c.projectTitle).").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open in Mindmill") { model.openLink(c.id.rawValue) }
                Button {
                    c.startMeeting()
                } label: {
                    Label("Add Notes", systemImage: "square.and.pencil")
                }
                .help("Reopen the meeting to take more notes with \(Brain.name). Done summarizes all notes again for review.")
            }
            .padding(16)
            .background(Color.green.opacity(0.08))
            Divider()
            let waiting = c.waitingBacklog
            if !waiting.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "tray.full").foregroundStyle(.orange)
                    Text(waiting.count == 1 ? "1 work item from this meeting waits to be created." : "\(waiting.count) work items from this meeting wait to be created.")
                        .font(.callout)
                    Spacer()
                    Button("Create…") {
                        c.createAfterFiling = BacklogBatchRequest(entries: waiting.map(\.id), context: "“\(c.title)”", people: c.attendees)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.08))
                Divider()
            }
            if c.summary.isEmpty {
                ListEmptyState(title: "No summary", systemImage: "doc.text", message: "Add Notes reopens the meeting; Done summarizes all notes again.")
            } else {
                MarkdownWebView(
                    html: MarkdownRenderer.page(body: MarkdownRenderer(linkRewriter: MarkdownRenderer.entryLinkRewriter).render(c.summary),
                                                accentHex: NSColor.controlAccentColor.hexString),
                    baseURL: c.id.fileURL(root: model.rootURL).deletingLastPathComponent(),
                    onLink: { model.openLink($0) }
                )
            }
        }
    }
}

// MARK: New meeting

struct NewMeetingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NewMeetingRequest
    @State private var title = ""
    @State private var now = false
    @State private var day = Date()
    @State private var start = Date()
    @State private var attendees: [String] = []
    @State private var prepare = true

    var body: some View {
        let projectTitle = model.index.project(request.project)?.title ?? request.project
        let date = KBDate.today(now ? Date() : day)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(now ? "Quick Meeting" : "New Meeting").font(.title2.weight(.semibold))
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    Text("in ") + Text(projectTitle).bold()
                }
                .font(.callout)
            }
            Picker("", selection: $now) {
                Text("Now").tag(true)
                Text("Later").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField(now ? "What it's about (optional)" : "Title", text: $title).font(.title3)
            if !now {
                HStack {
                    DatePicker("Date", selection: $day, displayedComponents: .date)
                    DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                }
            }
            PeoplePicker(names: $attendees, placeholder: "Attendees: search Azure DevOps, or type a name")
            if now {
                Text("Starts now at \(MeetingController.clock(Date())) and opens straight into notes. Done at the end gives you the summary and proposals as for any meeting.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Prepare with \(Brain.name)", isOn: $prepare)
                    .disabled(!claudeAvailable)
                    .help(claudeAvailable ? "\(Brain.name) gathers context and drafts questions" : model.claudeMissingExplanation)
                Text("projects/\(request.project)/meetings/\(date)-\(Slug.make(title)).md · status: prepared")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(now ? "Start Now" : "Create and Open") { now ? startNow() : create(date: date) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!now && title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 500)
        .onAppear { now = request.quick }
    }

    private var claudeAvailable: Bool { if case .found = model.claudeAvailability { return true } else { return false } }

    private var names: [String] { attendees }

    private func startNow() {
        dismiss()
        model.startQuickMeeting(title: title, project: request.project, attendees: names)
    }

    private func create(date: String) {
        do {
            let doc = try MeetingFile.create(project: request.project, title: title, date: date,
                                             start: MeetingController.clock(start), attendees: names, root: model.rootURL)
            dismiss()
            model.reload()
            model.openLink(doc.id.rawValue)
            model.openMeeting(doc.id)
            if prepare && claudeAvailable {
                model.pendingPrepare.insert(doc.id)
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

/// With the transcript hidden, one quiet line in the bottom bar still shows that it is hearing words.
struct HiddenTranscriptCaption: View {
    let c: MeetingController

    var body: some View {
        let t = c.transcriber
        let live = t.sources.compactMap { t.live($0) }.first
        let text = live ?? c.transcript.last?.text ?? "Listening…"
        HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
            Text(LiveCaption.tail(text, words: 14))
                .font(.caption)
                .italic(live != nil)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: 420, alignment: .trailing)
        .help("What the transcript heard last")
    }
}

/// The same PBI proposed once per platform (Android and iOS): one card, a checkbox per platform.
enum BacklogTwins {
    static func key(_ e: KBEntry) -> String {
        (e.backlogKind ?? "pbi") + "|" + e.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// Entries with the same kind and title together, in the order they first appear.
    static func group(_ entries: [KBEntry]) -> [[KBEntry]] {
        var out: [[KBEntry]] = []
        var index: [String: Int] = [:]
        for e in entries {
            let k = key(e)
            if let i = index[k] { out[i].append(e) } else {
                index[k] = out.count
                out.append([e])
            }
        }
        return out
    }
}

struct TwinReviewCard: View {
    @Environment(AppModel.self) private var model
    let c: MeetingController
    let entries: [KBEntry]
    let onEdit: (EntryID) -> Void

    var body: some View {
        let first = entries[0]
        let anyTicked = entries.contains { c.isTicked($0.id) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                KindChip(kind: first.backlogKind)
                Text("one per platform").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("Edit") {
                    ForEach(entries) { e in
                        Button(model.index.project(e.project)?.title ?? e.project) { onEdit(e.id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            }
            Text(first.title).font(.headline).foregroundStyle(anyTicked ? .primary : .secondary).strikethrough(!anyTicked)
            if !first.summary.isEmpty {
                Text(first.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 14) {
                ForEach(entries) { e in
                    Toggle(isOn: Binding(get: { c.isTicked(e.id) }, set: { c.setTicked(e.id, $0) })) {
                        Text(model.index.project(e.project)?.title ?? e.project)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .font(.callout)
            if let reason = first.reason {
                Text(reason).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(anyTicked ? 0.07 : 0.03), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.15)))
        .opacity(anyTicked ? 1 : 0.7)
    }
}
