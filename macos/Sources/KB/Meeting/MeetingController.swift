import ImageIO
import AppKit
import KBCore
import Observation
import SwiftUI

/// One meeting window: the file's stage, the Claude session behind it, live notes and the flags they got.
@MainActor
@Observable
final class MeetingController {
    enum Stage: Equatable {
        case prepare, live, summarizing, review, filed
    }

    let id: EntryID
    @ObservationIgnored weak var model: AppModel?

    private(set) var title = ""
    private(set) var date = ""
    private(set) var start = ""
    private(set) var attendees: [String] = []
    private(set) var end = ""
    private(set) var projectGuessed = false
    private(set) var onlineURL: URL?
    private(set) var status: MeetingStatus = .prepared
    /// Files and web pages added for the meeting, and those Claude is reading now.
    private(set) var materials: [MeetingMaterial] = []
    private(set) var readingMaterials: Set<String> = []
    @ObservationIgnored private var materialTags: [String: String] = [:]
    /// When Done was pressed, while Claude writes the summary (`summarizing` in the file).
    private(set) var summarizingSince: String?
    private(set) var storedSessionID: String?
    var stage: Stage = .prepare
    var missing = false

    var questions = QuestionList()
    /// `## Suggested questions`: Claude's, until the user picks them into `## Questions`.
    var suggested = QuestionList()
    /// The user finished preparing; unpicked suggestions then stay out of the meeting.
    private(set) var ready = false
    private(set) var prep = ""
    private(set) var notes = ""
    var summary = ""
    /// `## Transcript summary` in parts; at filing the kept ones are added to the summary.
    private(set) var transcriptParts: [TranscriptSummary.Part] = []
    var leftOutParts: Set<Int> = []
    private(set) var useTranscript = true
    var keepTranscript = true
    var summaryEditing = false
    var summaryDirty = false

    let chat = ClaudeChat()
    var chatInput = ""
    private(set) var tracker = LiveNoteTracker()
    private(set) var flags: [Int: [LiveReply.Flag]] = [:]
    private(set) var pendingNotes: Set<Int> = []
    var positions: [Int: CGFloat] = [:]
    var questionsExpanded = true
    private(set) var liveStartedAt: Date?

    struct TranscriptLine: Identifiable, Equatable {
        let id: Int
        let time: String
        let speaker: String
        let text: String
        var language = ""
        /// The batch it was sent to Claude in; flags for that batch show after its last line.
        var batch: Int?
        var markdown: String { MeetingTranscript.Line(time: time, speaker: speaker, text: text, language: language).markdown }
    }

    let transcriber = LiveTranscriber()
    let screen = ScreenWatcher()
    /// Pictures shown to Claude, by the batch they were sent in; deleted once Claude has read them.
    @ObservationIgnored private var pictureFiles: [Int: URL] = [:]
    private(set) var sendingPicture = false
    private(set) var transcript: [TranscriptLine] = []
    private(set) var transcriptFlags: [Int: [LiveReply.Flag]] = [:]
    private(set) var pendingBatches: Set<Int> = []
    var showTranscriptConsent = false
    @ObservationIgnored private var unsentTranscript: [Int] = []
    @ObservationIgnored private var transcriptTimer: Timer?
    @ObservationIgnored private var transcriptSaveTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptDirty = false
    @ObservationIgnored private var nextBatch = 0

    var reviewError: String?
    private(set) var proposedCount: Int?
    var unticked: Set<EntryID> = []
    /// The backlog items ticked at review, offered for creating once the meeting is filed.
    var createAfterFiling: BacklogBatchRequest?
    private(set) var filing = false
    var fileErrors: [String] = []
    var notice: String?
    var pbiSheet = false

    @ObservationIgnored private var notesSaveTask: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var questionsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var questionsDirty = false
    @ObservationIgnored private var notesDirty = false
    @ObservationIgnored private var loadedOnce = false

    init(id: EntryID, model: AppModel) {
        self.id = id
        self.model = model
        load()
        restoreChat()
        chat.onEvent = { [weak self] event in
            self?.handle(event)
            DispatchQueue.main.async { self?.saveChat() }
        }
    }

    // MARK: Kept between windows

    private struct SavedChat: Codable {
        struct Message: Codable { var role: String; var text: String }
        var messages: [Message]
        var draft: String
        var questionsExpanded: Bool
    }

    /// The conversation, the unsent message and the layout, kept per meeting so closing the window or quitting
    /// the app loses nothing. The Claude session itself resumes from `session_id` in the meeting file.
    private var chatURL: URL {
        let name = id.rawValue.replacingOccurrences(of: "/", with: "__")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KB/meeting-chats/\(name).json")
    }

    private func restoreChat() {
        guard let data = try? Data(contentsOf: chatURL), let saved = try? JSONDecoder().decode(SavedChat.self, from: data) else { return }
        chat.items = saved.messages.map { ClaudeChat.Item(role: ClaudeChat.Role(rawValue: $0.role) ?? .assistant, text: $0.text) }
        chatInput = saved.draft
        questionsExpanded = saved.questionsExpanded
    }

    func saveChat() {
        let kept = chat.items.filter { $0.role == .user || $0.role == .assistant || $0.role == .error }
        guard !kept.isEmpty || !chatInput.isEmpty || FileManager.default.fileExists(atPath: chatURL.path) else { return }
        let saved = SavedChat(messages: kept.map { .init(role: $0.role.rawValue, text: $0.text) }, draft: chatInput,
                              questionsExpanded: questionsExpanded)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: chatURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: chatURL, options: .atomic)
        model?.meetingChatSaved(id, count: kept.count)
    }

    @ObservationIgnored private var appeared = false

    /// Starts what the window needs once it is on screen: a live meeting resumes its session, and a meeting
    /// created with "Prepare with Claude" starts preparing.
    func windowAppeared() {
        guard !appeared else { return }
        appeared = true
        if let script = ProcessInfo.processInfo.environment["KB_MEETING_SCRIPT"], !script.isEmpty {
            runScript(script)
        } else if status == .live {
            DispatchQueue.main.async { [weak self] in self?.resumeLive() }
        } else if stage == .prepare || stage == .filed, model?.pendingStart.remove(id) != nil {
            DispatchQueue.main.async { [weak self] in self?.startMeeting() }
        } else if stage == .prepare, model?.pendingPrepare.remove(id) != nil {
            DispatchQueue.main.async { [weak self] in self?.prepareWithClaude() }
        }
    }

    var root: URL? { model?.rootURL }
    var projectTitle: String { model?.index.project(id.project)?.title ?? id.project }
    var sessionID: String? { chat.sessionID ?? storedSessionID }
    var isReading: Bool { !pendingNotes.isEmpty }

    // MARK: Loading

    func load() {
        guard let root else { return }
        guard let doc = try? KBStore.load(id, root: root) else {
            missing = true
            return
        }
        missing = false
        title = doc.title
        date = doc.frontmatter.string("date") ?? ""
        start = doc.frontmatter.string("start") ?? ""
        attendees = doc.frontmatter.list("attendees")
        end = doc.frontmatter.string("end") ?? ""
        projectGuessed = ["true", "yes"].contains((doc.frontmatter.string("project_guessed") ?? "").lowercased())
        onlineURL = doc.frontmatter.string("online_url").flatMap(URL.init(string:))
        status = MeetingFile.status(of: doc)
        summarizingSince = status == .live ? doc.frontmatter.string("summarizing").flatMap { $0.isEmpty ? nil : $0 } : nil
        let sid = doc.frontmatter.string("session_id")?.trimmingCharacters(in: .whitespaces) ?? ""
        storedSessionID = sid.isEmpty ? nil : sid
        prep = doc.meetingSection(.prep) ?? ""
        materials = MeetingMaterial.parse(doc.meetingSection(.materials) ?? "")
        ready = doc.frontmatter.string("ready") == "true"
        if !questionsDirty {
            questions = QuestionList(markdown: doc.meetingSection(.questions) ?? "")
            suggested = QuestionList(markdown: doc.meetingSection(.suggested) ?? "")
        }
        if !loadedOnce || (stage != .live && !notesDirty) {
            notes = doc.meetingSection(.rawNotes) ?? ""
        }
        if !summaryDirty && !summaryEditing { summary = doc.meetingSection(.summary) ?? "" }
        let parts = TranscriptSummary.parts(doc.meetingSection(.transcriptSummary) ?? "")
        if parts != transcriptParts {
            transcriptParts = parts
            leftOutParts = leftOutParts.filter { $0 < parts.count }
        }
        if transcript.isEmpty && !transcriber.isOn {
            transcript = Self.parseTranscript(doc.meetingSection(.transcript) ?? "")
        }
        if !loadedOnce {
            loadedOnce = true
            tracker.markSent(notes)
            switch status {
            case .scheduled, .prepared, .cancelled: stage = .prepare
            case .live where summarizingSince != nil:
                // Done was pressed and the summary never came back (KB quit meanwhile): offer to try again.
                stage = .summarizing
                if !chat.isBusy { reviewError = "\(Brain.name) stopped before finishing the summary." }
            case .live: stage = .live
            case .review: stage = .review
            case .filed: stage = .filed
            }
            if stage == .prepare { moveLegacySuggestions(doc) }
        } else if status == .filed, stage != .filed {
            stage = .filed
        } else if status == .review, stage == .prepare || stage == .live || (stage == .summarizing && !chat.isBusy) {
            // Filed from elsewhere (a terminal session): follow the file.
            stage = .review
        }
    }

    // MARK: Session

    @discardableResult
    private func ensureSession(_ mode: String) -> Bool {
        if chat.isRunning && chat.mode == mode { return true }
        guard let model else { return false }
        let existing = chat.sessionID ?? storedSessionID
        let sid = existing ?? UUID().uuidString.lowercased()
        let prompt = mode == "prepare" ? ClaudeModes.prepare(id.rawValue) : ClaudeModes.live(id.rawValue)
        let modelName = mode == "prepare" ? model.defaultModel : model.liveModel
        let cwd = ClaudeLaunch.workingDirectory(project: model.index.project(id.project), root: model.rootURL)
        guard let launch = model.launch(prompt: prompt, sessionID: sid, resume: existing != nil, model: modelName, cwd: cwd,
                                        tools: ClaudeLaunch.bridgeTools + ["WebFetch"]) else {
            notice = model.claudeMissingExplanation
            return false
        }
        do {
            try chat.start(launch, mode: mode)
            // claude.ai connectors (calendar, Teams, email) are only there from the second turn.
            if mode == "prepare" { chat.send(ClaudeModes.warmup, tag: "connect", show: false) }
            return true
        } catch {
            notice = "Could not start claude: \(error.localizedDescription)"
            return false
        }
    }

    private func handle(_ event: ClaudeEvent) {
        switch event {
        case .sessionStarted(let sid):
            if storedSessionID != sid, let root {
                storedSessionID = sid
                _ = try? MeetingFile.update(id, root: root) { $0.frontmatter.set("session_id", .string(sid)) }
            }
        case .turnResult(let text, let isError, let tag):
            guard let tag else { return }
            if tag.hasPrefix("note:"), let n = Int(tag.dropFirst(5)) {
                pendingNotes.remove(n)
                guard !isError else {
                    flags[n] = [.init(kind: .note, text: "\(Brain.name) could not read this note: \(text)")]
                    return
                }
                let reply = LiveReply.parse(text)
                if !reply.flags.isEmpty { flags[n] = reply.flags }
                tick(reply)
            } else if tag.hasPrefix("transcript:"), let b = Int(tag.dropFirst(11)) {
                pendingBatches.remove(b)
                if let url = pictureFiles.removeValue(forKey: b) { try? FileManager.default.removeItem(at: url) }
                guard !isError else { return }
                let reply = LiveReply.parse(text)
                if !reply.flags.isEmpty { transcriptFlags[b] = reply.flags }
                tick(reply)
            } else if tag.hasPrefix("material:"), let link = materialTags.removeValue(forKey: tag) {
                readingMaterials.remove(link)
                let line = text.components(separatedBy: .newlines).first { $0.hasPrefix("SUMMARY:") || $0.hasPrefix("UNREADABLE:") } ?? text
                let note: String
                if isError {
                    note = "\(Brain.name) couldn't read it."
                } else if line.hasPrefix("UNREADABLE:") {
                    note = "Couldn't open it: " + line.dropFirst("UNREADABLE:".count).trimmingCharacters(in: .whitespaces)
                } else {
                    note = line.replacingOccurrences(of: "SUMMARY:", with: "").trimmingCharacters(in: .whitespaces)
                }
                setMaterialNote(link, String(note.prefix(400)))
            } else if tag == "warmup" {
                tick(LiveReply.parse(text))
            } else if tag == "review" {
                if isError {
                    reviewError = text
                } else {
                    proposedCount = LiveReply.proposedCount(text)
                    clearSummarizing()
                    model?.reload()
                    load()
                    stage = .review
                }
            } else if tag.hasPrefix("prep") {
                model?.reload()
                load()
            }
        case .exited:
            pendingNotes.removeAll()
            pictureFiles.values.forEach { try? FileManager.default.removeItem(at: $0) }
            pictureFiles = [:]
            if stage == .summarizing { reviewError = reviewError ?? "\(Brain.name) stopped before finishing the summary." }
        default:
            break
        }
    }

    // MARK: Materials

    private var materialsFolder: URL? {
        guard let root else { return nil }
        let file = id.fileURL(root: root)
        return file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".files")
    }

    /// Where a material is: a file's full path, or the page's URL.
    func location(of m: MeetingMaterial) -> String {
        guard !m.isWeb, let root else { return m.link }
        return id.fileURL(root: root).deletingLastPathComponent().appendingPathComponent(m.link).standardizedFileURL.path
    }

    /// Copies the files next to the meeting file, lists them under `## Materials`, and has Claude read them.
    func addMaterialFiles(_ urls: [URL]) {
        guard let folder = materialsFolder else { return }
        var added: [MeetingMaterial] = []
        for url in urls where url.isFileURL {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var dest = folder.appendingPathComponent(url.lastPathComponent)
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
                    dest = folder.appendingPathComponent("\(base)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
                    n += 1
                }
                try FileManager.default.copyItem(at: url, to: dest)
                added.append(MeetingMaterial(title: url.lastPathComponent, link: folder.lastPathComponent + "/" + dest.lastPathComponent))
            } catch {
                notice = "Could not add \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        addMaterials(added)
    }

    /// Lists a web page under `## Materials` and has Claude read it.
    func addMaterialLink(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t.contains("://") ? t : "https://" + t), let host = url.host, !host.isEmpty else {
            notice = "That doesn't look like a web address."
            return
        }
        guard !materials.contains(where: { $0.link == url.absoluteString }) else { return }
        let path = url.path == "/" ? "" : url.path
        addMaterials([MeetingMaterial(title: host + (path.count > 40 ? String(path.prefix(39)) + "…" : path), link: url.absoluteString)])
    }

    private func addMaterials(_ added: [MeetingMaterial]) {
        guard !added.isEmpty, let root else { return }
        materials += added
        writeMaterials(root)
        for m in added { readMaterial(m) }
    }

    func readMaterial(_ m: MeetingMaterial) {
        guard ensureSession(stage == .live ? "live" : "prepare") else { return }
        let tag = "material:\(UUID().uuidString.prefix(8))"
        materialTags[tag] = m.link
        readingMaterials.insert(m.link)
        chat.send(ClaudeModes.material(location(of: m), title: m.title, isWeb: m.isWeb), tag: tag, show: false)
    }

    func removeMaterial(_ m: MeetingMaterial) {
        guard let root else { return }
        materials.removeAll { $0.link == m.link }
        writeMaterials(root)
        if !m.isWeb { try? FileManager.default.removeItem(atPath: location(of: m)) }
    }

    private func setMaterialNote(_ link: String, _ note: String) {
        guard let root, let i = materials.firstIndex(where: { $0.link == link }) else { return }
        materials[i].note = note
        writeMaterials(root)
    }

    private func writeMaterials(_ root: URL) {
        let text = MeetingMaterial.render(materials)
        do {
            try MeetingFile.update(id, root: root) { d in
                if text.isEmpty { d.body = MeetingBody.removing(.materials, in: d.body) } else { d.setMeetingSection(.materials, text) }
            }
        } catch {
            notice = "Could not save the materials: \(error.localizedDescription)"
        }
    }

    // MARK: Prepare

    func prepareWithClaude() {
        guard ensureSession("prepare") else { return }
        chat.send("prepare \(id.rawValue)", tag: "prep-start", show: true)
    }

    func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        flushQuestions()
        guard ensureSession(stage == .prepare ? "prepare" : "live") else { return }
        chatInput = ""
        chat.send(text, tag: "prep-\(UUID().uuidString.prefix(6))")
        saveChat()
    }

    func questionsEdited() {
        questionsDirty = true
        questionsSaveTask?.cancel()
        questionsSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.flushQuestions()
        }
    }

    func flushQuestions() {
        questionsSaveTask?.cancel()
        guard questionsDirty, let root else { return }
        let md = questions.markdown
        let sug = suggested.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let ready = ready
        do {
            try MeetingFile.update(id, root: root) { d in
                d.setMeetingSection(.questions, md)
                if !sug.isEmpty {
                    d.setMeetingSection(.suggested, sug)
                } else if d.meetingSection(.suggested) != nil {
                    d.body = MeetingBody.removing(.suggested, in: d.body)
                }
                if ready, d.frontmatter.string("ready") != "true" { d.frontmatter.set("ready", .string("true")) }
            }
            questionsDirty = false
        } catch {
            notice = "Could not save the questions: \(error.localizedDescription)"
        }
    }

    /// A meeting Claude prepared before suggestions had their own section, that the user hasn't touched:
    /// its questions are suggestions.
    private func moveLegacySuggestions(_ doc: EntryDocument) {
        guard !ready, doc.meetingSection(.suggested) == nil, date >= KBDate.today(),
              !questions.questions.isEmpty, !questions.questions.contains(where: { $0.done || !$0.answer.isEmpty })
        else { return }
        suggested = questions
        questions = QuestionList()
        questionsDirty = true
        flushQuestions()
    }

    /// Adds a suggestion to the meeting's questions, in the same group.
    func pick(_ index: Int) {
        suggested.move(index, to: &questions)
        ready = true
        questionsEdited()
    }

    /// Takes a question out of the meeting; it stays among the suggestions.
    func unpick(_ index: Int) {
        questions.move(index, to: &suggested)
        ready = true
        questionsEdited()
    }

    func pickAll() {
        while let q = suggested.questions.first { suggested.move(q.id, to: &questions) }
        ready = true
        questionsEdited()
    }

    func dismissSuggestion(_ index: Int) {
        suggested.remove(index)
        suggested.dropEmptyGroups()
        questionsEdited()
    }

    func addQuestion(_ text: String) {
        questions.insert([.task(done: false, text: text)], group: nil)
        questionsEdited()
    }

    /// Done preparing: the picked questions are the meeting's, and the meeting no longer counts as waiting.
    func finishPreparing() {
        ready = true
        questionsDirty = true
        flushQuestions()
        model?.reload()
    }

    /// Ticks a question; the answer field under it opens for what was said.
    func setAnswered(_ id: Int, _ done: Bool) {
        questions.set(id, done: done)
        questionsEdited()
    }

    func setAnswer(_ id: Int, _ answer: String) {
        questions.set(id, answer: answer)
        questionsEdited()
    }

    private func tick(_ reply: LiveReply) {
        guard !reply.answered.isEmpty else { return }
        var changed = false
        for a in reply.answered where questions.markAnswered(a, answer: reply.answers[a]) { changed = true }
        if changed {
            questionsDirty = true
            flushQuestions()
        }
    }

    // MARK: Live

    var isCancelled: Bool { status == .cancelled }

    /// Starts taking notes; from a filed meeting it reopens it, and Done summarizes all notes again.
    func startMeeting() {
        if !ready, !suggested.questions.isEmpty {
            // Not prepared: every suggestion comes along, apart from the prepared questions.
            questions.addSuggestions(suggested)
            suggested = QuestionList()
            questionsDirty = true
        }
        flushQuestions()
        guard let root else { return }
        let now = Self.clock(Date())
        do {
            try MeetingFile.update(id, root: root) { d in
                d.frontmatter.set("status", .string(MeetingStatus.live.rawValue))
                if (d.frontmatter.string("start") ?? "").isEmpty { d.frontmatter.set("start", .string(now)) }
            }
        } catch {
            notice = "Could not start: \(error.localizedDescription)"
            return
        }
        load()
        stage = .live
        liveStartedAt = Date()
        if ensureSession("live") {
            chat.send("The meeting `\(id.rawValue)` has started. Read its `## Questions` now. Reply OK.", tag: "warmup", show: false)
        }
    }

    /// Started by an action (voice, the phone): as the Start button, then transcribing without the consent prompt;
    /// the action's answer reminds the user to tell the room instead. The window opened after it finds it running.
    func startFromAction(transcribe: Bool) {
        appeared = true
        if stage != .live { startMeeting() }
        if transcribe { beginTranscription() }
    }

    private func resumeLive() {
        liveStartedAt = startDate ?? Date()
        if ensureSession("live") {
            chat.send("I am back in the meeting `\(id.rawValue)` (the app was reopened). The notes so far are in `## Raw notes`. Reply OK.", tag: "warmup", show: false)
        }
    }

    /// The meeting's `date` + `start`, when that is today.
    var startDate: Date? {
        guard date == KBDate.today(), start.count >= 4, let day = KBDate.parse(date) else { return nil }
        let parts = start.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let d = Calendar(identifier: .gregorian).date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
        return d.flatMap { $0 <= Date() ? $0 : nil }
    }

    func notesChanged(_ text: String) {
        guard text != notes else { return }
        notes = text
        notesDirty = true
        scheduleNotesSave()
        send(tracker.update(text: text, paused: false))
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.send(self.tracker.update(text: self.notes, paused: true))
        }
    }

    private func send(_ new: [LiveNote]) {
        guard !new.isEmpty, stage == .live else { return }
        if !chat.isRunning, !ensureSession("live") { return }
        for n in new {
            pendingNotes.insert(n.id)
            chat.send(n.text, tag: "note:\(n.id)", show: false)
        }
    }

    /// Saves at most 1.5 s after the first unsaved keystroke, so typing never waits and a crash loses little.
    private func scheduleNotesSave() {
        guard notesSaveTask == nil else { return }
        notesSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self?.notesSaveTask = nil
            self?.saveNotesNow()
        }
    }

    func saveNotesNow() {
        notesSaveTask?.cancel()
        notesSaveTask = nil
        guard notesDirty, let root else { return }
        let text = notes
        do {
            try MeetingFile.update(id, root: root) { $0.setMeetingSection(.rawNotes, text) }
            notesDirty = false
        } catch {
            notice = "Could not save notes: \(error.localizedDescription)"
        }
    }

    var notesSaved: Bool { !notesDirty }

    func finishMeeting() {
        stopWatchingScreen()
        stopTranscription()
        pauseTask?.cancel()
        saveNotesNow()
        flushQuestions()
        if let root {
            _ = try? MeetingFile.update(id, root: root) { d in
                if (d.frontmatter.string("end") ?? "").isEmpty { d.frontmatter.set("end", .string(Self.clock(Date()))) }
                d.frontmatter.set("summarizing", .string(Self.clock(Date())))
            }
            model?.reload()
        }
        reviewError = nil
        stage = .summarizing
        guard ensureSession("live") else {
            reviewError = notice ?? "\(Brain.name) is not available."
            return
        }
        chat.send(ClaudeModes.review(id.rawValue), tag: "review", show: false)
    }

    func retryReview() {
        reviewError = nil
        chat.stop()
        finishMeeting()
    }

    /// Without Claude: go to review with whatever is in the file.
    func reviewWithoutClaude() {
        chat.stop()
        clearSummarizing()
        if let root, status != .review {
            _ = try? MeetingFile.update(id, root: root) { $0.frontmatter.set("status", .string(MeetingStatus.review.rawValue)) }
        }
        load()
        stage = .review
    }

    func backToLive() {
        reviewError = nil
        clearSummarizing()
        model?.reload()
        stage = .live
    }

    private func clearSummarizing() {
        guard let root else { return }
        _ = try? MeetingFile.update(id, root: root) { $0.frontmatter.set("summarizing", nil) }
        summarizingSince = nil
    }

    // MARK: Transcript

    var transcriptLanguage: String {
        UserDefaults.standard.string(forKey: AppSettingsKeys.transcriptLanguage) ?? LiveTranscriber.auto
    }

    func setTranscriptLanguage(_ id: String) {
        UserDefaults.standard.set(id, forKey: AppSettingsKeys.transcriptLanguage)
        if transcriber.isOn {
            stopTranscription()
            beginTranscription()
        }
    }

    /// Asks the user to tell the attendees first, unless they turned that reminder off.
    func startTranscription() {
        if UserDefaults.standard.bool(forKey: AppSettingsKeys.transcriptConsentAcknowledged) {
            beginTranscription()
        } else {
            showTranscriptConsent = true
        }
    }

    func beginTranscription() {
        guard !transcriber.isOn else { return }
        let d = UserDefaults.standard
        let mic = d.object(forKey: AppSettingsKeys.transcriptMicrophone) as? Bool ?? true
        let computer = d.object(forKey: AppSettingsKeys.transcriptComputerAudio) as? Bool ?? true
        transcriber.onSegment = { [weak self] seg in self?.addSegment(seg) }
        let language = transcriptLanguage
        Task { await transcriber.start(locale: language, microphone: mic, computerAudio: computer) }
        startTranscriptTimer()
    }

    private func startTranscriptTimer() {
        guard transcriptTimer == nil else { return }
        transcriptTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushTranscriptToClaude() }
        }
    }

    func stopTranscription() {
        transcriber.stop()
        if !screen.isOn {
            transcriptTimer?.invalidate()
            transcriptTimer = nil
        }
        flushTranscriptToClaude()
        saveTranscriptNow()
    }

    // MARK: Screen

    func watchScreen(_ window: ScreenWatcher.Window) {
        screen.onText = { [weak self] text, _ in self?.addLine(time: Date(), speaker: Self.screenSpeaker, text: text) }
        screen.onPicture = { [weak self] image, w in self?.sendPicture(image, name: w.name, automatic: true) }
        screen.watch(window)
        startTranscriptTimer()
    }

    func stopWatchingScreen() {
        screen.stop()
        if !transcriber.isOn {
            transcriptTimer?.invalidate()
            transcriptTimer = nil
        }
        flushTranscriptToClaude()
        saveTranscriptNow()
    }

    static let screenSpeaker = "Screen"

    /// Takes a picture of the watched window and has Claude look at it. The picture is deleted once Claude has
    /// read it; the transcript keeps only a line saying it was shown.
    func showScreenToClaude() {
        guard stage == .live, screen.isOn, !sendingPicture else { return }
        sendingPicture = true
        Task {
            defer { sendingPicture = false }
            do {
                sendPicture(try await screen.picture(), name: screen.watching?.name ?? "the shared window", automatic: false)
            } catch {
                notice = "Could not show the screen to \(Brain.name): \(error.localizedDescription)"
            }
        }
    }

    /// Has Claude look at a picture of the watched window or screen; `automatic` when the content changed a lot by
    /// itself (a new slide) and the user asked for pictures of such changes.
    private func sendPicture(_ image: CGImage, name: String, automatic: Bool) {
        guard stage == .live else { return }
        let url: URL
        do { url = try ScreenWatcher.save(image) } catch {
            notice = "Could not show the screen to \(Brain.name): \(error.localizedDescription)"
            return
        }
        flushTranscriptToClaude()
        guard chat.isRunning || ensureSession("live") else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let what = screen.area == nil ? name : "an area of \(name)"
        let id = addLine(time: Date(), speaker: Self.screenSpeaker,
                         text: automatic ? "It changed: picture of \(what) shown to \(Brain.name)" : "Picture of \(what) shown to \(Brain.name)", send: false)
        let batch = nextBatch
        nextBatch += 1
        transcript[id].batch = batch
        pictureFiles[batch] = url
        pendingBatches.insert(batch)
        chat.send(ClaudeModes.screenshot(path: url.path, window: what), tag: "transcript:\(batch)", show: false)
    }

    // MARK: From the phone

    /// A line the phone's speech recognition heard.
    func addRemoteLine(speaker: String, text: String, language: String) {
        guard stage == .live, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        addLine(time: Date(), speaker: speaker, text: text, language: language)
        startTranscriptTimer()
    }

    /// A note typed on the phone, added under the notes so far.
    func appendRemoteNote(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        notesChanged(notes.isEmpty ? t : notes.trimmingCharacters(in: .newlines) + "\n" + t)
    }

    /// A picture of the phone's screen, for \(Brain.name) to read like a shared window.
    func showRemotePicture(_ jpeg: Data) {
        guard stage == .live, let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        sendPicture(image, name: "the phone's screen", automatic: false)
    }

    var remoteState: String {
        switch stage {
        case .prepare: return "prepared"
        case .live: return "live"
        case .summarizing: return "summarising"
        case .review, .filed: return "done"
        }
    }

    private func addSegment(_ seg: LiveTranscriber.Segment) {
        addLine(time: seg.time, speaker: seg.speaker, text: seg.text, language: seg.language)
    }

    @discardableResult
    private func addLine(time: Date, speaker: String, text: String, language: String = "", send: Bool = true) -> Int {
        let line = TranscriptLine(id: transcript.count, time: Self.clock(time), speaker: speaker, text: text,
                                  language: language)
        transcript.append(line)
        if send { unsentTranscript.append(line.id) }
        transcriptDirty = true
        if transcriptSaveTask == nil {
            transcriptSaveTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.transcriptSaveTask = nil
                self?.saveTranscriptNow()
            }
        }
        return line.id
    }

    private func flushTranscriptToClaude() {
        guard stage == .live, !unsentTranscript.isEmpty else { return }
        guard chat.isRunning || ensureSession("live") else { return }
        let batch = nextBatch
        nextBatch += 1
        let ids = unsentTranscript
        unsentTranscript = []
        for i in ids where i < transcript.count { transcript[i].batch = batch }
        let lines = ids.filter { $0 < transcript.count }.map { i -> String in
            let l = transcript[i]
            return "\(l.time) \(l.speaker)\(l.language.isEmpty ? "" : " [\(l.language)]"): \(l.text)"
        }
        pendingBatches.insert(batch)
        chat.send(ClaudeModes.transcript(lines), tag: "transcript:\(batch)", show: false)
    }

    func saveTranscriptNow() {
        transcriptSaveTask?.cancel()
        transcriptSaveTask = nil
        guard transcriptDirty, let root else { return }
        let md = transcript.map(\.markdown).joined(separator: "\n")
        do {
            try MeetingFile.update(id, root: root) { $0.setMeetingSection(.transcript, md) }
            transcriptDirty = false
        } catch {
            notice = "Could not save the transcript: \(error.localizedDescription)"
        }
    }

    static func parseTranscript(_ md: String) -> [TranscriptLine] {
        MeetingTranscript.parse(md).enumerated().map { i, l in TranscriptLine(id: i, time: l.time, speaker: l.speaker, text: l.text, language: l.language) }
    }

    // MARK: Review

    var inboxCards: [KBEntry] { model?.index.inbox(project: id.project, proposedBy: id.rawValue) ?? [] }
    /// Backlog items from this meeting that are still waiting to be created.
    var waitingBacklog: [KBEntry] {
        (model?.index.backlog(project: id.project, sourcedFrom: id.rawValue) ?? []).filter { $0.backlogStatus == .proposed }
    }

    var backlogCards: [KBEntry] {
        (model?.index.backlog(project: id.project, sourcedFrom: id.rawValue) ?? []).filter { $0.backlogStatus == .proposed }
    }

    func isTicked(_ e: EntryID) -> Bool { !unticked.contains(e) }

    func setTicked(_ e: EntryID, _ on: Bool) {
        if on { unticked.remove(e) } else { unticked.insert(e) }
    }

    func saveSummary() {
        guard let root else { return }
        let text = summary
        do {
            try MeetingFile.update(id, root: root) { $0.setMeetingSection(.summary, text) }
            summaryDirty = false
            summaryEditing = false
        } catch {
            notice = "Could not save the summary: \(error.localizedDescription)"
        }
    }

    /// Leaves the whole transcript out, or takes it back: its summary parts, and the proposals only it supports.
    func setUseTranscript(_ on: Bool) {
        useTranscript = on
        for e in inboxCards + backlogCards where Self.fromTranscript(e) { setTicked(e.id, on) }
    }

    static func fromTranscript(_ e: KBEntry) -> Bool {
        (e.reason ?? "").lowercased().hasPrefix("from the transcript")
    }

    var keptParts: [TranscriptSummary.Part] {
        useTranscript ? transcriptParts.filter { !leftOutParts.contains($0.id) } : []
    }

    /// Writes the summary with the transcript parts the user kept, and drops the parts section (and the
    /// transcript itself when the user chose not to keep it).
    private func mergeTranscriptSummary(root: URL) throws {
        let hasParts = !transcriptParts.isEmpty
        guard hasParts || !keepTranscript else { return }
        let merged = TranscriptSummary.merged(summary: summary, keeping: keptParts)
        let dropTranscript = !keepTranscript
        try MeetingFile.update(id, root: root) { d in
            if hasParts {
                d.setMeetingSection(.summary, merged)
                d.body = MeetingBody.removing(.transcriptSummary, in: d.body)
            }
            if dropTranscript { d.body = MeetingBody.removing(.transcript, in: d.body) }
        }
        if dropTranscript { transcript = [] }
        summary = merged
        transcriptParts = []
        leftOutParts = []
    }

    func fileSelected() {
        guard let model, let root else { return }
        if summaryDirty { saveSummary() }
        do {
            try mergeTranscriptSummary(root: root)
            try MeetingFile.update(id, root: root) { $0.body = MeetingBody.removing(.suggested, in: $0.body) }
        } catch {
            fileErrors = ["Could not write the summary: \(error.localizedDescription)"]
            return
        }
        filing = true
        fileErrors = []
        let cli = model.cli
        let inbox = inboxCards.map { ($0.id, isTicked($0.id)) }
        let rejectBacklog = backlogCards.filter { !isTicked($0.id) }.map(\.id)
        let keepBacklog = backlogCards.filter { isTicked($0.id) }.map(\.id)
        Task {
            var errors: [String] = []
            for (entry, keep) in inbox {
                do {
                    if keep { _ = try await cli.approveInbox(entry) } else { try await cli.rejectInbox(entry) }
                } catch { errors.append(error.localizedDescription) }
            }
            for entry in rejectBacklog {
                do { try await cli.rejectBacklog(entry) } catch { errors.append(error.localizedDescription) }
            }
            if errors.isEmpty {
                do {
                    try MeetingFile.update(id, root: root) { $0.frontmatter.set("status", .string(MeetingStatus.filed.rawValue)) }
                    stage = .filed
                    chat.stop()
                    if !keepBacklog.isEmpty {
                        createAfterFiling = BacklogBatchRequest(entries: keepBacklog, context: "“\(title)”", people: attendees)
                    }
                } catch { errors.append(error.localizedDescription) }
            }
            fileErrors = errors
            filing = false
            model.reload()
            load()
        }
    }

    // MARK: Diagnostics

    /// `KB_MEETING_SCRIPT`: lines of `start`, `type <text>` (appends a paragraph and a blank line),
    /// `wait <seconds>`, `done`, `untick <title words>`, `file`. Drives the same code paths as typing, for checking without a keyboard.
    private func runScript(_ script: String) {
        Task { [weak self] in
            for raw in script.components(separatedBy: CharacterSet(charactersIn: "\n;")) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard let self, !line.isEmpty else { continue }
                let (cmd, arg) = line.firstIndex(of: " ").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) } ?? (line, "")
                switch cmd {
                case "start": self.startMeeting()
                case "type": self.notesChanged(self.notes + (self.notes.isEmpty ? "" : "") + arg + "\n\n")
                case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
                case "done": self.finishMeeting()
                case "untick":
                    for e in self.inboxCards + self.backlogCards where e.title.localizedCaseInsensitiveContains(arg) {
                        self.setTicked(e.id, false)
                    }
                case "file": self.fileSelected()
                default: break
                }
            }
        }
    }

    // MARK: Window

    func close() {
        transcriber.stop()
        transcriptTimer?.invalidate()
        saveTranscriptNow()
        pauseTask?.cancel()
        if stage == .live { saveNotesNow() }
        flushQuestions()
        saveChat()
        chat.stop()
    }

    func setAttendees(_ names: [String]) {
        guard names != attendees, let root else { return }
        attendees = names
        do {
            try MeetingFile.update(id, root: root) { $0.frontmatter.set("attendees", .list(names)) }
            model?.reload()
        } catch {
            notice = "Could not save the attendees: \(error.localizedDescription)"
        }
    }

    /// A new title in the file; the file name stays, so links keep working.
    func rename(_ newTitle: String) {
        let t = KBEntry.oneLine(newTitle)
        guard !t.isEmpty, t != title, let root else { return }
        do {
            try MeetingFile.update(id, root: root) { $0.frontmatter.set("title", .string(t)) }
            load()
            model?.reload()
        } catch {
            notice = "Could not rename: \(error.localizedDescription)"
        }
    }

    func continueInTerminal() {
        guard let sid = sessionID, let model else {
            notice = "No \(Brain.name) session yet. Send \(Brain.name) a message first."
            return
        }
        let command = "claude --resume \(sid)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let dir = ClaudeLaunch.workingDirectory(project: model.index.project(id.project), root: model.rootURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", dir.path]
        try? p.run()
        notice = "Copied “\(command)”. Paste it in the new Terminal window. Close this window first so only one process uses the session."
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
