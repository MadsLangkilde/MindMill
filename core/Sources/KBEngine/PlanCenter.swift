import Foundation
import KBCore
import Observation

/// `engine.plan`: Plan mode's work that keeps state between calls: suggested fact links, the quiz, duplicate
/// follow-ups, the follow-up check, the goal coaches and the people directory. The Mac's views and the actions share it.
@MainActor
@Observable
public final class PlanCenter {
    /// Claude's suggested links per fact id, until accepted or rejected; rejected ones aren't suggested again.
    public var factLinkSuggestions: [String: [FactLinkSuggestion]] = [:]
    public var factLinkRejected: [String: [String]] = [:]
    public var suggestingLinks: Set<EntryID> = []
    public var findingDuplicates = false
    /// Goal coaches by goal id, and when each last had a message, so Plan → Sessions lists it.
    @ObservationIgnored public var goalChats: [String: ClaudeChat] = [:]
    public var goalCoachUpdated: [String: Date] = [:]
    public var people = People()
    @ObservationIgnored public var peopleLoaded = false
    public var peopleSyncing = false
    public var followupWatch = FollowupWatchState()
    public var followupChecker = ClaudeChat()
    /// The background checks may run (the host turns them on once Claude Code is found and set up).
    @ObservationIgnored public var backgroundStarted = false

    @ObservationIgnored private var quizStatsCache: QuizStats?
    @ObservationIgnored private var rejectedLoaded = false
    @ObservationIgnored unowned let engine: MindmillEngine

    init(engine: MindmillEngine) {
        self.engine = engine
    }

    private var index: KBIndex { engine.index }

    // MARK: Fact links

    public func linkFacts(_ a: EntryID, _ b: EntryID, remove: Bool = false) async throws {
        defer { engine.reload() }
        try await engine.cli.run(["fact", "link", a.rawValue, b.rawValue] + (remove ? ["--remove"] : []))
    }

    /// Facts a fact could be linked to: in its project and siblings, not linked yet, not rejected before.
    public func linkCandidates(_ id: EntryID) -> [KBEntry] {
        loadRejected()
        let linked = Set(index.linkedFacts(of: id).map(\.id))
        let rejected = Set(factLinkRejected[id.rawValue] ?? [])
        let scopes = Set([id.project] + index.siblings(of: id.project).map(\.id))
        return index.entries.values.filter {
            $0.section == .facts && $0.id != id && !$0.isDraft && scopes.contains($0.id.project)
                && !linked.contains($0.id) && !rejected.contains($0.id.rawValue)
        }
    }

    /// Claude compares the fact with the others in its project and suggests related ones, kept in
    /// `factLinkSuggestions` for the user to accept or reject. nil when it's already looking or the fact is gone.
    public func suggestFactLinks(_ id: EntryID) async -> [FactLinkSuggestion]? {
        guard let fact = index.entry(id), !suggestingLinks.contains(id) else { return nil }
        let others = linkCandidates(id)
        guard !others.isEmpty else { return [] }
        suggestingLinks.insert(id)
        let prompt = Self.linkPrompt(fact, others: others)
        let candidates = Set(others.map(\.id.rawValue))
        let reply = await engine.claudeOnce(prompt, system: "You suggest links between facts in a knowledge base. Reply with JSON only.",
                                            model: engine.model(for: .background))
        suggestingLinks.remove(id)
        let found = FactLinkSuggestion.parse(reply ?? "", candidates: candidates)
        factLinkSuggestions[id.rawValue] = found
        return found
    }

    static func linkPrompt(_ fact: KBEntry, others: [KBEntry]) -> String {
        let list = others.sorted { $0.id.rawValue < $1.id.rawValue }.prefix(300)
            .map { "- \($0.id.rawValue): \($0.title)\($0.summary.isEmpty ? "" : " — \($0.summary.prefix(160))")" }
            .joined(separator: "\n")
        return """
        The fact:
        \(fact.title)
        \(fact.summary)
        \(fact.body.prefix(1500))

        Other facts:
        \(list)

        Which other facts are directly related to this one: one depends on, explains, contradicts or completes the other \
        (for example "the BFF issues tokens" and "the device validates them")? Sharing a word or an area isn't enough. \
        Reply with only a JSON array, at most 6, best first: [{"id": "<id>", "why": "<a few words>"}], or [] for none.
        """
    }

    public func acceptLinkSuggestion(_ s: FactLinkSuggestion, for id: EntryID) async throws {
        factLinkSuggestions[id.rawValue]?.removeAll { $0 == s }
        if let other = EntryID(s.id) { try await linkFacts(id, other) }
    }

    public func rejectLinkSuggestion(_ s: FactLinkSuggestion, for id: EntryID) {
        loadRejected()
        factLinkSuggestions[id.rawValue]?.removeAll { $0 == s }
        factLinkRejected[id.rawValue, default: []].append(s.id)
        saveRejected()
    }

    private var rejectedURL: URL { engine.dataFile("factlinks-rejected.json") }

    public func loadRejected() {
        guard !rejectedLoaded else { return }
        rejectedLoaded = true
        guard let data = try? Data(contentsOf: rejectedURL),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        factLinkRejected = map
    }

    private func saveRejected() {
        guard let data = try? JSONEncoder().encode(factLinkRejected) else { return }
        try? FileManager.default.createDirectory(at: rejectedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: rejectedURL, options: .atomic)
    }

    // MARK: Quiz

    public var quiz: QuizStats {
        if let s = quizStatsCache { return s }
        let s = QuizStats.load(root: engine.rootURL)
        quizStatsCache = s
        return s
    }

    public func recordQuizAnswer(_ fact: String, correct: Bool) throws {
        var s = quiz
        s.record(fact, correct: correct, today: KBDate.today())
        quizStatsCache = s
        try s.save(root: engine.rootURL)
    }

    private var quizQuestionsURL: URL { engine.dataFile("quiz-questions.json") }

    private struct StoredQuestions: Codable { var sig: String; var questions: [QuizQuestion] }

    /// Questions written before, by fact id, with the fact's signature then: a changed fact gets new questions.
    private func cachedQuestions() -> [String: StoredQuestions] {
        guard let data = try? Data(contentsOf: quizQuestionsURL),
              let map = try? JSONDecoder().decode([String: StoredQuestions].self, from: data) else { return [:] }
        return map
    }

    private func storeQuestions(_ map: [String: StoredQuestions]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? FileManager.default.createDirectory(at: quizQuestionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: quizQuestionsURL, options: .atomic)
    }

    /// A fact's text as a short signature: questions are written again when it changes.
    public static func signature(_ e: KBEntry) -> String {
        var h: UInt64 = 5381
        for b in (e.title + "\u{1}" + e.summary + "\u{1}" + e.body).utf8 { h = (h &* 33) ^ UInt64(b) }
        return String(h, radix: 36)
    }

    /// One question per picked fact. Facts without questions yet get them from Claude in one go; they are kept for
    /// later rounds until the fact changes.
    public func quizRound(from facts: [KBEntry], count: Int) async -> [QuizQuestion] {
        let today = KBDate.today()
        let picked = FactQuiz.pick(facts.map { .init(id: $0.id.rawValue, date: $0.date) }, stats: quiz, today: today,
                                   count: count, seed: UInt64.random(in: 0...UInt64.max))
        var cache = cachedQuestions()
        let byID = Dictionary(facts.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        let missing = picked.filter { id in
            guard let e = byID[id] else { return false }
            return cache[id]?.sig != Self.signature(e) || cache[id]?.questions.isEmpty != false
        }
        if !missing.isEmpty {
            let prompt = quizPrompt(missing.compactMap { byID[$0] })
            let reply = await engine.claudeOnce(prompt, system: "You write short quiz questions from facts. Reply with JSON only.",
                                                model: engine.model(for: .background), timeout: 180)
            let found = QuizQuestion.parse(reply ?? "", facts: Set(missing))
            for id in missing {
                guard let e = byID[id] else { continue }
                let qs = found.filter { $0.fact == id }
                if !qs.isEmpty { cache[id] = StoredQuestions(sig: Self.signature(e), questions: qs) }
            }
            storeQuestions(cache)
        }
        return picked.compactMap { cache[$0]?.questions.randomElement() }
    }

    func quizPrompt(_ facts: [KBEntry]) -> String {
        let blocks = facts.map { e -> String in
            let links = index.linkedFacts(of: e.id).map { "“\($0.title)”" }.joined(separator: ", ")
            return """
            ## \(e.id.rawValue)
            Title: \(e.title)
            \(e.summary.isEmpty ? "" : "Summary: \(e.summary)\n")\(e.tags.isEmpty ? "" : "Tags: \(e.tags.joined(separator: ", "))\n")\(links.isEmpty ? "" : "Linked facts: \(links)\n")\(e.body.prefix(1200))
            """
        }.joined(separator: "\n\n")
        return """
        Write quiz questions that help me remember these facts from my own knowledge base. For each fact write 2 \
        short questions with a short answer taken from the fact itself. Ask about what matters (who does what, \
        which system, terms and what they mean, numbers, rules). When a fact has linked facts, one question may ask \
        how they connect (for example "What validates the token issued by the BFF?"). Never ask about the title's \
        wording itself.

        \(blocks)

        Reply with only a JSON array: [{"fact": "<the id after ##>", "question": "…", "answer": "…"}].
        """
    }

    // MARK: Follow-ups

    public func mergeFollowups(keep: String, other: String) async throws {
        defer { engine.reload() }
        try await engine.cli.run(["followup", "merge", keep, other])
    }

    /// Claude reads the open follow-ups of a scope and proposes merging the ones that say the same thing. Returns how
    /// many it proposed; nil when a search is already running.
    public func findDuplicateFollowups(project: String) async -> Int? {
        guard !findingDuplicates else { return nil }
        findingDuplicates = true
        let prompt = "List the open follow-ups of scope `\(project)` (`kb list --section followups --project \(project)`; read any you need with `kb show <id>`). Find pairs that ask or do the same thing, even in different words; a follow-up merely on the same topic is not a duplicate. For each pair run `kb followup propose-merge <the one to keep> <the duplicate> --why '<one line>'`, keeping the one with more detail. Change nothing else. Reply with one line: `PROPOSED <n>`."
        let reply = await engine.claudeOnce(prompt, system: "You find duplicate follow-ups in a knowledge base and propose merges; the user decides.",
                                            model: engine.model(for: .background), tools: ["Bash(kb:*)", "Read"], timeout: 240)
        findingDuplicates = false
        engine.reload()
        return reply.flatMap { r in r.components(separatedBy: "PROPOSED ").last.flatMap { Int($0.prefix { $0.isNumber }) } } ?? 0
    }

    // MARK: Goals

    /// A goal by id, file stem or a word of its title.
    public func goal(_ key: String) throws -> Goal {
        let goals = Goals.load(root: engine.rootURL)
        let k = key.lowercased()
        if let g = goals.first(where: { $0.id.lowercased() == k || $0.stem.lowercased() == k }) { return g }
        if !k.isEmpty, let g = goals.first(where: { $0.title.lowercased().contains(k) }) { return g }
        throw ActionError("I can't find that goal.")
    }

    public func updateGoal(_ goal: Goal, _ change: (inout Goal) -> Void) throws {
        defer { engine.reload() }
        try Goals.update(goal, change)
    }

    /// Adds a dated line to the goal's Progress; false when `text` is empty.
    @discardableResult
    public func logGoalProgress(_ goal: Goal, _ text: String) throws -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        try updateGoal(goal) { $0.body = GoalBody.addingProgress(t, date: KBDate.today(), to: $0.body) }
        return true
    }

    public func deleteGoal(_ goal: Goal) throws {
        defer { engine.reload() }
        goalChats.removeValue(forKey: goal.id)?.stop()
        goalCoachUpdated[goal.id] = nil
        try Goals.delete(goal)
    }

    public func goalChat(_ goal: Goal) -> ClaudeChat {
        if let c = goalChats[goal.id] { return c }
        let c = ClaudeChat()
        c.onEvent = { [weak self] event in
            if case .turnResult = event { self?.engine.reload() }
        }
        goalChats[goal.id] = c
        return c
    }

    /// The goal coach: a session that edits the goal file's Suggestions and answers coaching questions.
    public func sendToGoalCoach(_ goal: Goal, _ text: String, show: Bool = true) throws {
        let chat = goalChat(goal)
        if !chat.isRunning {
            guard let launch = engine.launch(prompt: ClaudeModes.goal(goal.id), sessionID: UUID().uuidString.lowercased(), resume: false,
                                             model: engine.model(for: .work), cwd: engine.rootURL) else {
                throw ActionError(engine.claudeMissingExplanation)
            }
            do { try chat.start(launch, mode: "goal") } catch {
                throw ActionError("Could not start claude: \(error.localizedDescription)")
            }
            chat.send(ClaudeModes.warmup, tag: "connect", show: false)
        }
        chat.send(text, tag: "goal-\(UUID().uuidString.prefix(6))", show: show)
        goalCoachUpdated[goal.id] = Date()
    }

    // MARK: People

    public func loadPeople() {
        people = People.load(root: engine.rootURL)
        peopleLoaded = true
    }

    /// Fetches the Azure DevOps directory when it is missing or a week old, or now when forced.
    public func refreshPeople(force: Bool = false) {
        if !peopleLoaded { loadPeople() }
        guard !peopleSyncing else { return }
        if !force, let at = people.fetched, Date().timeIntervalSince(at) < 7 * 86400 { return }
        peopleSyncing = true
        let cli = engine.cli
        Task {
            _ = try? await cli.run(["people", "sync"])
            loadPeople()
            peopleSyncing = false
        }
    }

    /// Keeps someone in the knowledge base's people.json so they come first next time.
    public func remember(_ p: Person) {
        let cli = engine.cli
        var args = ["people", "add", "--name", p.name]
        if !p.email.isEmpty { args += ["--email", p.email] }
        if !p.initials.isEmpty { args += ["--initials", p.initials] }
        Task {
            _ = try? await cli.run(args)
            loadPeople()
        }
    }

    // MARK: The follow-up check

    private var followupWatchURL: URL { engine.dataFile("followupwatch.json") }

    private var hasOpenFollowups: Bool {
        index.entries.values.contains { $0.section == .followups && !$0.isDraft && $0.followupStatus == .open }
    }

    /// Entries that can settle a follow-up, with a signature that changes when they do. An open follow-up counts
    /// once, when it is new (it may duplicate an older one); a closed one counts again when it closes.
    public func followupWatchCandidates() -> [String: String] {
        var out: [String: String] = [:]
        for e in index.entries.values where !e.isDraft {
            switch e.section {
            case .facts, .architecture:
                out[e.id.rawValue] = "\(e.summary.count)|\(e.body.count)"
            case .decisions where e.status != .superseded:
                out[e.id.rawValue] = "\(e.rawStatus)|\(e.summary.count)|\(e.body.count)"
            case .meetings:
                guard let s = e.meetingStatus, s == .review || s == .filed else { continue }
                out[e.id.rawValue] = "\(MeetingBody.section(.summary, in: e.body)?.count ?? 0)"
            case .followups:
                out[e.id.rawValue] = e.followupStatus == .open ? "open" : "\(e.rawStatus)|\(e.summary.count)"
            default:
                continue
            }
        }
        return out
    }

    /// After a reload: what was saved since the last check goes to the background follow-up check once edits settle.
    public func followupWatchIndexChanged() {
        guard backgroundStarted, engine.loadError == nil else { return }
        if !followupWatch.loaded {
            followupWatch.loaded = true
            if let data = try? Data(contentsOf: followupWatchURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                followupWatch.seeded = obj["seeded"] as? Bool ?? false
                followupWatch.checked = obj["checked"] as? [String: String] ?? [:]
            }
        }
        let candidates = followupWatchCandidates()
        if !followupWatch.seeded {
            followupWatch.checked = candidates
            followupWatch.seeded = true
            saveFollowupWatch()
            return
        }
        let changed = candidates.filter { followupWatch.checked[$0.key] != $0.value }.map(\.key)
        guard !changed.isEmpty else { return }
        guard hasOpenFollowups else {
            for id in changed { followupWatch.checked[id] = candidates[id] }
            saveFollowupWatch()
            return
        }
        followupWatch.pending.formUnion(changed)
        let snapshot = followupWatch.pending
        // Wait until edits settle: a meeting or a fact is often written in several steps.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard let self, self.followupWatch.pending == snapshot else { return }
            self.runFollowupCheck()
        }
    }

    private func saveFollowupWatch() {
        let obj: [String: Any] = ["seeded": followupWatch.seeded, "checked": followupWatch.checked]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: followupWatchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: followupWatchURL, options: .atomic)
    }

    public var isCheckingFollowups: Bool { !followupWatch.running.isEmpty }

    /// Checks a scope's open follow-ups now against what was saved there and product-wide in the last 30 days.
    /// Returns what it says to the user when there is nothing to check, nil when the check started.
    @discardableResult
    public func checkFollowupsNow(project: String) -> String? {
        let cutoff = KBDate.today(Date().addingTimeInterval(-30 * 86_400))
        let wide = index.projects.first { $0.wide }?.id
        let scopes = Set([project] + (wide.map { [$0] } ?? []))
        let recent = followupWatchCandidates().keys.compactMap { EntryID($0).flatMap { index.entry($0) } }
            .filter { scopes.contains($0.id.project) && $0.date >= cutoff && !($0.section == .followups && $0.followupStatus == .open) }
            .sorted { $0.date > $1.date }
            .prefix(12)
        guard !recent.isEmpty else {
            return "Nothing was saved in \(index.project(project)?.title ?? project) in the last 30 days to check the follow-ups against."
        }
        followupWatch.pending.formUnion(recent.map { $0.id.rawValue })
        runFollowupCheck()
        return nil
    }

    public func runFollowupCheck() {
        guard !followupChecker.isRunning, !followupWatch.pending.isEmpty else { return }
        let ids = Array(followupWatch.pending.sorted().prefix(12))
        let wide = index.projects.first { $0.wide }?.id
        guard let launch = engine.launch(prompt: ClaudeModes.followupCheck(ids, wide: wide), sessionID: UUID().uuidString.lowercased(),
                                         resume: false, model: engine.model(for: .background), cwd: engine.rootURL,
                                         tools: ["Bash(kb:*)", "Read", "Grep", "Glob"]) else { return }
        followupChecker.onEvent = { [weak self] event in self?.followupCheckEvent(event) }
        do { try followupChecker.start(launch, mode: "followups") } catch { return }
        followupWatch.running = ids
        followupChecker.send("check", tag: "check", show: false)
    }

    private func followupCheckEvent(_ event: ClaudeEvent) {
        switch event {
        case .turnResult(let text, let isError, let tag) where tag == "check":
            finishFollowupCheck(text: isError ? "" : text)
        case .exited:
            if !followupWatch.running.isEmpty { finishFollowupCheck(text: "") }
        default:
            break
        }
    }

    private func finishFollowupCheck(text: String) {
        followupChecker.stop()
        engine.reload()
        let report = FollowupCheckReport(text)
        let candidates = followupWatchCandidates()
        // What it read, and what it changed itself, count as read.
        for id in followupWatch.running + report.handled.map(\.id) + report.updated.map(\.id) {
            followupWatch.checked[id] = candidates[id] ?? "checked"
            followupWatch.pending.remove(id)
        }
        followupWatch.running = []
        saveFollowupWatch()
        if !report.handled.isEmpty || !report.updated.isEmpty {
            var parts: [String] = []
            if !report.handled.isEmpty {
                let titles = report.handled.prefix(2).map { "“\(EntryID($0.id).flatMap { index.entry($0)?.title } ?? $0.id)”" }
                parts.append("handled \(report.handled.count) follow-up\(report.handled.count == 1 ? "" : "s") (\(titles.joined(separator: ", "))\(report.handled.count > 2 ? ", …" : ""))")
            }
            if !report.updated.isEmpty { parts.append("updated \(report.updated.count)") }
            engine.report("Mindmill " + parts.joined(separator: " and ") + " from what you saved. See Follow-ups.")
        }
        if !followupWatch.pending.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.runFollowupCheck()
            }
        }
    }
}

/// Which saved entries the background follow-up check has read, so each is read once per change.
public struct FollowupWatchState: Equatable, Sendable {
    public var loaded = false
    public var seeded = false
    public var checked: [String: String] = [:]
    public var pending: Set<String> = []
    public var running: [String] = []

    public init() {}
}
