import KBCore
import SwiftUI

extension AppModel {
    var quiz: QuizStats {
        if let s = quizStatsCache { return s }
        let s = QuizStats.load(root: rootURL)
        quizStatsCache = s
        return s
    }

    func recordQuizAnswer(_ fact: String, correct: Bool) {
        var s = quiz
        s.record(fact, correct: correct, today: KBDate.today())
        quizStatsCache = s
        do { try s.save(root: rootURL) } catch { errorMessage = "Could not save the quiz results: \(error.localizedDescription)" }
    }

    private var quizQuestionsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KB/quiz-questions.json")
    }

    /// Questions written before, by fact id, with the fact's signature then: a changed fact gets new questions.
    private func cachedQuestions() -> [String: (sig: String, questions: [QuizQuestion])] {
        struct Stored: Codable { var sig: String; var questions: [QuizQuestion] }
        guard let data = try? Data(contentsOf: quizQuestionsURL),
              let map = try? JSONDecoder().decode([String: Stored].self, from: data) else { return [:] }
        return map.mapValues { ($0.sig, $0.questions) }
    }

    private func storeQuestions(_ map: [String: (sig: String, questions: [QuizQuestion])]) {
        struct Stored: Codable { var sig: String; var questions: [QuizQuestion] }
        guard let data = try? JSONEncoder().encode(map.mapValues { Stored(sig: $0.sig, questions: $0.questions) }) else { return }
        try? FileManager.default.createDirectory(at: quizQuestionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: quizQuestionsURL, options: .atomic)
    }

    /// One question per picked fact. Facts without questions yet get them from Claude in one go; they are kept for
    /// later rounds until the fact changes.
    func quizRound(from facts: [KBEntry], count: Int) async -> [QuizQuestion] {
        let today = KBDate.today()
        let picked = FactQuiz.pick(facts.map { .init(id: $0.id.rawValue, date: $0.date) }, stats: quiz, today: today,
                                   count: count, seed: UInt64.random(in: 0...UInt64.max))
        var cache = cachedQuestions()
        let byID = Dictionary(facts.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        let missing = picked.filter { id in
            guard let e = byID[id] else { return false }
            return cache[id]?.sig != Self.scopeSignature(e) || cache[id]?.questions.isEmpty != false
        }
        if !missing.isEmpty {
            let blocks = missing.compactMap { id -> String? in
                guard let e = byID[id] else { return nil }
                let links = index.linkedFacts(of: e.id).map { "“\($0.title)”" }.joined(separator: ", ")
                return """
                ## \(id)
                Title: \(e.title)
                \(e.summary.isEmpty ? "" : "Summary: \(e.summary)\n")\(e.tags.isEmpty ? "" : "Tags: \(e.tags.joined(separator: ", "))\n")\(links.isEmpty ? "" : "Linked facts: \(links)\n")\(e.body.prefix(1200))
                """
            }.joined(separator: "\n\n")
            let prompt = """
            Write quiz questions that help me remember these facts from my own knowledge base. For each fact write 2 \
            short questions with a short answer taken from the fact itself. Ask about what matters (who does what, \
            which system, terms and what they mean, numbers, rules). When a fact has linked facts, one question may ask \
            how they connect (for example "What validates the token issued by the BFF?"). Never ask about the title's \
            wording itself.

            \(blocks)

            Reply with only a JSON array: [{"fact": "<the id after ##>", "question": "…", "answer": "…"}].
            """
            let reply = await claudeOnce(prompt, system: "You write short quiz questions from facts. Reply with JSON only.",
                                         model: backgroundModel, timeout: 180)
            let found = QuizQuestion.parse(reply ?? "", facts: Set(missing))
            for id in missing {
                guard let e = byID[id] else { continue }
                let qs = found.filter { $0.fact == id }
                if !qs.isEmpty { cache[id] = (Self.scopeSignature(e), qs) }
            }
            storeQuestions(cache)
        }
        return picked.compactMap { cache[$0]?.questions.randomElement() }
    }
}

/// Practise the facts: a question, the answer on request, and whether you knew it. Weak and new facts come up most.
struct QuizView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    @AppStorage("quizCount") private var count = 10
    @State private var questions: [QuizQuestion] = []
    @State private var position = 0
    @State private var revealed = false
    @State private var results: [Bool] = []
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        let every = model.index.entries(project: project.id, section: .facts).filter { !$0.isDraft }
        let facts = model.tagFiltered(every, .quiz)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Writing questions…").foregroundStyle(.secondary)
                        }
                    } else if questions.isEmpty {
                        start(facts: facts, every: every)
                    } else if position < questions.count {
                        card(questions[position])
                    } else {
                        summary(facts: facts)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationSubtitle("Facts quiz")
    }

    @ViewBuilder
    private func start(facts: [KBEntry], every: [KBEntry]) -> some View {
        let today = KBDate.today()
        let due = facts.filter { model.quiz.isDue($0.id.rawValue, today: today) }.count
        let weak = Set(model.quiz.weakSpots).intersection(facts.map(\.id.rawValue)).count
        Text("Practise your facts").font(.title3.weight(.semibold))
        Text("Questions favour facts you got wrong, facts added lately and facts due again. Pick tags to practise one area before you work on it.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        TagFilterBar(key: .quiz, available: every.map(\.tags), inset: 0)
        Text("\(facts.count) fact\(facts.count == 1 ? "" : "s") · \(due) due · \(weak) weak spot\(weak == 1 ? "" : "s")")
            .font(.callout)
            .foregroundStyle(.secondary)
        ChipRow(spacing: 10) {
            Picker("Questions", selection: $count) {
                Text("5 questions").tag(5)
                Text("10 questions").tag(10)
                Text("20 questions").tag(20)
            }
            .labelsHidden()
            .fixedSize()
            Button("Start") { begin(facts) }
                .buttonStyle(.borderedProminent)
                .disabled(facts.isEmpty || !model.claudeAvailable)
        }
        if failed {
            Text("\(Brain.name) didn't write any questions. Try again in a moment.").font(.callout).foregroundStyle(.orange)
        }
    }

    private func card(_ q: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Question \(position + 1) of \(questions.count)").font(.caption).foregroundStyle(.secondary)
            Text(q.question).font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if revealed {
                VStack(alignment: .leading, spacing: 6) {
                    Text(q.answer).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    EntryLink(raw: q.fact).font(.caption)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                ChipRow(spacing: 10) {
                    Button("I Knew It") { answer(q, correct: true) }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .keyboardShortcut("1", modifiers: [])
                    Button("I Didn't") { answer(q, correct: false) }
                        .keyboardShortcut("2", modifiers: [])
                }
            } else {
                Button("Show Answer") { revealed = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])
                Text("Answer in your head, then check.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Stop") { reset() }.buttonStyle(.link).font(.caption)
        }
    }

    private func summary(facts: [KBEntry]) -> some View {
        let right = results.filter { $0 }.count
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(right) of \(results.count) right").font(.title2.weight(.semibold))
            Text(right == results.count ? "All of them. Those facts come up less often now."
                 : "The ones you missed come back tomorrow.")
                .foregroundStyle(.secondary)
            ChipRow(spacing: 10) {
                Button("Another Round") { begin(facts) }.buttonStyle(.borderedProminent)
                Button("Done") { reset() }
            }
        }
    }

    private func begin(_ facts: [KBEntry]) {
        reset()
        loading = true
        Task {
            let round = await model.quizRound(from: facts, count: count)
            loading = false
            failed = round.isEmpty
            questions = round
        }
    }

    private func answer(_ q: QuizQuestion, correct: Bool) {
        model.recordQuizAnswer(q.fact, correct: correct)
        results.append(correct)
        revealed = false
        position += 1
    }

    private func reset() {
        questions = []
        position = 0
        revealed = false
        results = []
        failed = false
    }
}
