import Foundation

/// A point in the work where a factory session stops to ask the user, while it carries on with what doesn't depend
/// on the answer.
public enum FactoryCheckpoint: String, Codable, CaseIterable, Sendable, Identifiable {
    case beforeStart, planReady, missingKnowledge, designChoice, newWorkItems, testsFailing, beforePR, beforeComplete

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .beforeStart: return "Before starting a task"
        case .planReady: return "When the plan is ready, before writing code"
        case .missingKnowledge: return "When it needs knowledge that isn't in the facts"
        case .designChoice: return "When there are several good ways to build something"
        case .newWorkItems: return "Before creating a new work item"
        case .testsFailing: return "When tests keep failing"
        case .beforePR: return "Before opening a pull request"
        case .beforeComplete: return "Before completing (merging) a pull request"
        }
    }

    /// A line under the title in the editor.
    public var detail: String {
        switch self {
        case .beforeStart: return "It tells you how it understood the item and waits for your go-ahead."
        case .planReady: return "You see the steps it will take and can adjust them."
        case .missingKnowledge: return "A business rule, a decision, how an outside system behaves: it asks instead of guessing."
        case .designChoice: return "It lays out the options with its recommendation first."
        case .newWorkItems: return "It asks with the item's title and why."
        case .testsFailing: return "After a few honest attempts, it tells you what it tried."
        case .beforePR: return "You see the title and a summary of the changes first."
        case .beforeComplete: return "It waits for your yes before merging."
        }
    }

    /// A few words, for the outline.
    public var short: String {
        switch self {
        case .beforeStart: return "Before starting"
        case .planReady: return "Plan ready"
        case .missingKnowledge: return "Missing knowledge"
        case .designChoice: return "Design choice"
        case .newWorkItems: return "Before creating it"
        case .testsFailing: return "Tests keep failing"
        case .beforePR: return "Before the pull request"
        case .beforeComplete: return "Before merging"
        }
    }

    /// The line in a task's brief.
    public var instruction: String {
        switch self {
        case .beforeStart: return "Before you start: after reading the work item, ask whether to go ahead, with your understanding of it in a few lines."
        case .planReady: return "When your plan is ready, before writing code: ask the user to approve it (a short list of steps)."
        case .missingKnowledge: return "When you need knowledge that isn't in the facts or the code (a business rule, a decision, how an outside system behaves): ask instead of guessing."
        case .designChoice: return "When there are several reasonable ways to build something the user would care about: ask which, with your recommendation first."
        case .newWorkItems: return "Before creating a new work item: ask, with its title and why."
        case .testsFailing: return "When tests keep failing after a few honest attempts: ask, with what you tried."
        case .beforePR: return "Before opening the pull request: ask, with its title and a summary of the changes."
        case .beforeComplete: return "Before completing (merging) a pull request: ask."
        }
    }
}

/// Which strategy a task gets: the first rule that matches it, else the factory's default.
public struct FactoryStrategyRule: Codable, Equatable, Sendable, Identifiable {
    public enum Match: String, Codable, CaseIterable, Sendable {
        case bug, pbi, tag, title

        public var title: String {
            switch self {
            case .bug: return "Bugs"
            case .pbi: return "PBIs"
            case .tag: return "Tagged"
            case .title: return "Title has"
            }
        }

        /// How the rule reads in the editor: "When <phrase> …".
        public var phrase: String {
            switch self {
            case .bug: return "the item is a bug"
            case .pbi: return "the item is a PBI"
            case .tag: return "it has the tag"
            case .title: return "its title contains"
            }
        }

        public var needsValue: Bool { self == .tag || self == .title }
    }

    public var id: UUID
    public var match: Match
    public var value: String
    /// A strategy slug; empty means one session without a strategy.
    public var strategy: String

    public init(id: UUID = UUID(), match: Match, value: String = "", strategy: String = "") {
        self.id = id
        self.match = match
        self.value = value
        self.strategy = strategy
    }

    /// "Bugs", "Tagged “ble”", for the outline.
    public var label: String {
        let v = value.trimmingCharacters(in: .whitespaces)
        switch match {
        case .bug: return "Bugs"
        case .pbi: return "PBIs"
        case .tag: return v.isEmpty ? "Tagged (no tag yet)" : "Tagged “\(v)”"
        case .title: return v.isEmpty ? "Title has (no words yet)" : "Title has “\(v)”"
        }
    }

    public func matches(_ item: TrackerBacklog.Item) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        switch match {
        case .bug: return item.isBug
        case .pbi: return !item.isBug
        case .tag: return !v.isEmpty && item.tags.contains { $0.lowercased() == v }
        case .title: return !v.isEmpty && item.title.lowercased().contains(v)
        }
    }
}

/// A moment to ask that the user wrote themselves.
public struct FactoryCustomAsk: Codable, Equatable, Sendable, Identifiable, ExpressibleByStringLiteral {
    public var id: UUID
    public var title: String
    /// More for the session than the title says; may be empty.
    public var instruction: String
    public var on: Bool

    public init(id: UUID = UUID(), title: String, instruction: String = "", on: Bool = true) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.on = on
    }

    public init(stringLiteral value: String) { self.init(title: value) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
    }

    enum CodingKeys: String, CodingKey { case id, title, instruction, on }
}

/// One moment a factory session may stop to ask, as the editor shows it.
public struct FactoryAskPoint: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var short: String
    public var detail: String
    public var defaultInstruction: String
    public var instruction: String
    public var isOn: Bool
    public var isCustom: Bool
    /// Where in the work it happens.
    public var step: FactoryStep

    public var isEdited: Bool { !isCustom && instruction != defaultInstruction }
}

/// The steps a factory task goes through, for the outline beside the rules.
public enum FactoryStep: String, CaseIterable, Sendable {
    case pick, start, plan, build, newWork, deliver, stop
}

public struct FactoryOutlineStep: Identifiable, Equatable, Sendable {
    public var id: FactoryStep
    public var title: String
    public var detail: String
    public var asks: [String]
}

/// How a software factory picks work, builds it, and when it asks.
public struct FactoryRules: Codable, Equatable, Sendable {
    public enum SprintFilter: String, Codable, CaseIterable, Sendable {
        case current, currentAndNext, any
        public var title: String {
            switch self {
            case .current: return "Current sprint"
            case .currentAndNext: return "Current and next sprint"
            case .any: return "Any sprint"
            }
        }
    }

    public enum Questions: String, Codable, CaseIterable, Sendable {
        case whenUnsure, checkpointsOnly, never
        public var title: String {
            switch self {
            case .whenUnsure: return "Ask when unsure, and at the checkpoints"
            case .checkpointsOnly: return "Ask only at the checkpoints"
            case .never: return "Never ask: decide and note the assumptions"
            }
        }
    }

    public enum NewWorkItems: String, Codable, CaseIterable, Sendable {
        case never, propose, create
        public var title: String {
            switch self {
            case .never: return "Don't create work items"
            case .propose: return "Propose them for my approval"
            case .create: return "Create them, assigned to me, and work on them"
            }
        }
    }

    public enum Duration: String, Codable, CaseIterable, Sendable {
        case untilStopped, hours, until
        public var title: String {
            switch self {
            case .untilStopped: return "Until I stop it"
            case .hours: return "For a number of hours"
            case .until: return "Until a time"
            }
        }
    }

    public var scopes: [String] = []
    public var assignedToMe = true
    /// Take unassigned items too, assigning them to the user first.
    public var unassigned = false
    public var pbis = true
    public var bugs = true
    public var sprint: SprintFilter = .current
    /// Also the user's items already in progress that no session works on.
    public var resumeStarted = false
    public var newWorkItems: NewWorkItems = .propose
    public var questions: Questions = .whenUnsure
    /// A strategy slug; empty means one session without a strategy.
    public var defaultStrategy = ""
    public var strategyRules: [FactoryStrategyRule] = []
    public var checkpoints: Set<FactoryCheckpoint> = [.missingKnowledge, .beforePR]
    public var customCheckpoints: [FactoryCustomAsk] = []
    /// What a session is told for an ask point, where the user changed the wording; keyed by ask point id.
    public var askTexts: [String: String] = [:]
    public var openPRs = true
    public var completePRs = false
    public var maxParallel = 3
    public var duration: Duration = .untilStopped
    public var hours: Double = 4
    public var until: Date = Date().addingTimeInterval(8 * 3600)

    public init() {}

    /// The choices for how many work items it works on at once.
    public static let parallelChoices = [1, 2, 3, 4, 5, 6, 8, 10]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FactoryRules()
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? d.scopes
        assignedToMe = try c.decodeIfPresent(Bool.self, forKey: .assignedToMe) ?? d.assignedToMe
        unassigned = try c.decodeIfPresent(Bool.self, forKey: .unassigned) ?? d.unassigned
        pbis = try c.decodeIfPresent(Bool.self, forKey: .pbis) ?? d.pbis
        bugs = try c.decodeIfPresent(Bool.self, forKey: .bugs) ?? d.bugs
        sprint = (try? c.decodeIfPresent(SprintFilter.self, forKey: .sprint)) ?? d.sprint
        resumeStarted = try c.decodeIfPresent(Bool.self, forKey: .resumeStarted) ?? d.resumeStarted
        newWorkItems = (try? c.decodeIfPresent(NewWorkItems.self, forKey: .newWorkItems)) ?? d.newWorkItems
        questions = (try? c.decodeIfPresent(Questions.self, forKey: .questions)) ?? d.questions
        defaultStrategy = try c.decodeIfPresent(String.self, forKey: .defaultStrategy) ?? d.defaultStrategy
        strategyRules = try c.decodeIfPresent([FactoryStrategyRule].self, forKey: .strategyRules) ?? d.strategyRules
        let raw = try c.decodeIfPresent([String].self, forKey: .checkpoints)
        checkpoints = raw.map { Set($0.compactMap(FactoryCheckpoint.init(rawValue:))) } ?? d.checkpoints
        // Asking before a new work item is part of the new-work setting now.
        if checkpoints.remove(.newWorkItems) != nil, newWorkItems == .create { newWorkItems = .propose }
        customCheckpoints = (try? c.decodeIfPresent([FactoryCustomAsk].self, forKey: .customCheckpoints))
            ?? (try? c.decodeIfPresent([String].self, forKey: .customCheckpoints))?.map { FactoryCustomAsk(title: $0) }
            ?? d.customCheckpoints
        askTexts = try c.decodeIfPresent([String: String].self, forKey: .askTexts) ?? d.askTexts
        openPRs = try c.decodeIfPresent(Bool.self, forKey: .openPRs) ?? d.openPRs
        completePRs = try c.decodeIfPresent(Bool.self, forKey: .completePRs) ?? d.completePRs
        maxParallel = try c.decodeIfPresent(Int.self, forKey: .maxParallel) ?? d.maxParallel
        duration = (try? c.decodeIfPresent(Duration.self, forKey: .duration)) ?? d.duration
        hours = try c.decodeIfPresent(Double.self, forKey: .hours) ?? d.hours
        until = try c.decodeIfPresent(Date.self, forKey: .until) ?? d.until
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scopes, forKey: .scopes)
        try c.encode(assignedToMe, forKey: .assignedToMe)
        try c.encode(unassigned, forKey: .unassigned)
        try c.encode(pbis, forKey: .pbis)
        try c.encode(bugs, forKey: .bugs)
        try c.encode(sprint, forKey: .sprint)
        try c.encode(resumeStarted, forKey: .resumeStarted)
        try c.encode(newWorkItems, forKey: .newWorkItems)
        try c.encode(questions, forKey: .questions)
        try c.encode(defaultStrategy, forKey: .defaultStrategy)
        try c.encode(strategyRules, forKey: .strategyRules)
        try c.encode(checkpoints.map(\.rawValue).sorted(), forKey: .checkpoints)
        try c.encode(customCheckpoints, forKey: .customCheckpoints)
        try c.encode(askTexts, forKey: .askTexts)
        try c.encode(openPRs, forKey: .openPRs)
        try c.encode(completePRs, forKey: .completePRs)
        try c.encode(maxParallel, forKey: .maxParallel)
        try c.encode(duration, forKey: .duration)
        try c.encode(hours, forKey: .hours)
        try c.encode(until, forKey: .until)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case scopes, assignedToMe, unassigned, pbis, bugs, sprint, resumeStarted, newWorkItems, questions
        case defaultStrategy, strategyRules, checkpoints, customCheckpoints, askTexts, openPRs, completePRs, maxParallel
        case duration, hours, until
    }

    /// The checkpoints that apply, in the order the work meets them.
    public var orderedCheckpoints: [FactoryCheckpoint] { askableCheckpoints.filter { checkpoints.contains($0) } }

    /// The checkpoints the editor offers: those that fit how it delivers.
    public var askableCheckpoints: [FactoryCheckpoint] {
        FactoryCheckpoint.allCases.filter { cp in
            switch cp {
            case .newWorkItems: return false
            case .beforePR: return openPRs
            case .beforeComplete: return openPRs && completePRs
            default: return true
            }
        }
    }

    /// The user's own ask points that are on and say something.
    public var customCheckpointList: [FactoryCustomAsk] {
        customCheckpoints.filter { $0.on && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: Asking

    public static let unsureID = "unsure"
    public static let unsureInstruction = "Ask when you're unsure about something that matters."

    /// Whether it asks at all.
    public var asks: Bool {
        get { questions != .never }
        set { questions = newValue ? .whenUnsure : .never }
    }

    public var asksWhenUnsure: Bool {
        get { questions == .whenUnsure }
        set { questions = newValue ? .whenUnsure : (questions == .never ? .never : .checkpointsOnly) }
    }

    /// "When unsure", the checkpoints that fit, then the user's own, as the editor shows them.
    public var askPoints: [FactoryAskPoint] {
        var out = [FactoryAskPoint(id: Self.unsureID, title: "When it's unsure about something that matters",
                                   short: "When unsure", detail: "Anything it can't settle from the work item, the knowledge base or the code.",
                                   defaultInstruction: Self.unsureInstruction, instruction: askText(Self.unsureID, Self.unsureInstruction),
                                   isOn: asksWhenUnsure, isCustom: false, step: .build)]
        for cp in askableCheckpoints {
            let step: FactoryStep = switch cp {
            case .beforeStart: .start
            case .planReady: .plan
            case .beforePR, .beforeComplete: .deliver
            case .newWorkItems: .newWork
            default: .build
            }
            out.append(FactoryAskPoint(id: cp.rawValue, title: cp.title, short: cp.short, detail: cp.detail,
                                       defaultInstruction: cp.instruction, instruction: askText(cp.rawValue, cp.instruction),
                                       isOn: checkpoints.contains(cp), isCustom: false, step: step))
        }
        for c in customCheckpoints {
            out.append(FactoryAskPoint(id: "custom:\(c.id.uuidString)", title: c.title, short: c.title, detail: "",
                                       defaultInstruction: "", instruction: c.instruction, isOn: c.on, isCustom: true, step: .build))
        }
        return out
    }

    private func askText(_ id: String, _ fallback: String) -> String {
        let t = askTexts[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? fallback : t
    }

    private func customIndex(_ id: String) -> Int? {
        guard id.hasPrefix("custom:"), let uuid = UUID(uuidString: String(id.dropFirst(7))) else { return nil }
        return customCheckpoints.firstIndex { $0.id == uuid }
    }

    public mutating func setAsk(_ id: String, on: Bool) {
        if id == Self.unsureID {
            asksWhenUnsure = on
        } else if let cp = FactoryCheckpoint(rawValue: id) {
            if on { checkpoints.insert(cp) } else { checkpoints.remove(cp) }
        } else if let i = customIndex(id) {
            customCheckpoints[i].on = on
        }
    }

    /// Changes what a session is told for an ask point; empty text or the default wording goes back to the default.
    public mutating func setAskInstruction(_ id: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = customIndex(id) {
            customCheckpoints[i].instruction = t
            return
        }
        let fallback = id == Self.unsureID ? Self.unsureInstruction : FactoryCheckpoint(rawValue: id)?.instruction ?? ""
        if t.isEmpty || t == fallback { askTexts[id] = nil } else { askTexts[id] = t }
    }

    public mutating func setAskTitle(_ id: String, _ title: String) {
        if let i = customIndex(id) { customCheckpoints[i].title = title }
    }

    public mutating func removeAsk(_ id: String) {
        if let i = customIndex(id) { customCheckpoints.remove(at: i) }
    }

    /// Adds one of the user's own; returns its ask point id.
    @discardableResult
    public mutating func addAsk(_ title: String) -> String {
        let c = FactoryCustomAsk(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        customCheckpoints.append(c)
        if questions == .never { questions = .checkpointsOnly }
        return "custom:\(c.id.uuidString)"
    }

    /// The ask points that are on.
    public var activeAskPoints: [FactoryAskPoint] { asks ? askPoints.filter { $0.isOn && !$0.title.isEmpty } : [] }

    public func strategy(for item: TrackerBacklog.Item) -> String {
        strategyRules.first { $0.matches(item) }?.strategy ?? defaultStrategy
    }

    /// When a run started now ends; nil runs until stopped.
    public func endDate(from start: Date) -> Date? {
        switch duration {
        case .untilStopped: return nil
        case .hours: return start.addingTimeInterval(max(0.25, hours) * 3600)
        case .until: return until > start ? until : nil
        }
    }

    /// What's wrong with the rules, for the editor; empty when it can start.
    public var problems: [String] {
        var out: [String] = []
        if scopes.isEmpty { out.append("Choose at least one scope.") }
        if !assignedToMe && !unassigned { out.append("Pick assigned to me, unassigned, or both.") }
        if !pbis && !bugs { out.append("Pick PBIs, bugs, or both.") }
        if asks && activeAskPoints.isEmpty { out.append("Tick at least one moment to ask, or turn asking off.") }
        if strategyRules.contains(where: { $0.match.needsValue && $0.value.trimmingCharacters(in: .whitespaces).isEmpty }) {
            out.append("An exception needs a tag or words.")
        }
        if duration == .until && until <= Date() { out.append("The end time has passed.") }
        return out
    }
}

extension FactoryRules {
    /// What the factory will do with each work item, in words, for the outline beside the rules.
    public func outline(scopeTitle: (String) -> String, strategyTitle: (String) -> String) -> [FactoryOutlineStep] {
        let asks = activeAskPoints
        func at(_ step: FactoryStep) -> [String] { asks.filter { $0.step == step }.map(\.short) }

        let kinds = pbis && bugs ? "PBIs and bugs" : bugs ? "bugs" : "PBIs"
        let whose = assignedToMe && unassigned ? "your and unassigned" : unassigned ? "unassigned" : "your"
        let sprintText = switch sprint {
        case .current: "in the current sprint"
        case .currentAndNext: "in the current or next sprint"
        case .any: "in any sprint"
        }
        let names = scopes.map(scopeTitle)
        let place = names.isEmpty ? "the scopes you pick" : ListFormatter.localizedString(byJoining: names)
        var pick = "Takes \(whose) \(kinds) from \(place), \(sprintText)."
        if unassigned { pick += " It assigns unassigned ones to you first." }
        if resumeStarted { pick += " Your items already in progress come first." }
        pick += " Up to \(maxParallel) at a time, never someone else's."

        func name(_ slug: String) -> String { slug.isEmpty ? "one session working alone" : strategyTitle(slug) }
        var start = defaultStrategy.isEmpty ? "One session works alone on each item." : "Each item gets \(strategyTitle(defaultStrategy))."
        let exceptions = strategyRules.map { "\($0.label): \(name($0.strategy))" }
        if !exceptions.isEmpty { start += " Except " + exceptions.joined(separator: "; ") + "." }

        var build = "Writes the code with tests on a branch of its own, following the repo's conventions."
        if !self.asks { build += " It decides on its own and lists its assumptions." }

        let newWork = switch newWorkItems {
        case .never: "Mentions work it finds in its report; creates nothing."
        case .propose: "Asks you first, then creates the item assigned to you; the factory picks it up."
        case .create: "Creates the item assigned to you right away; the factory picks it up."
        }

        let deliver = !openPRs ? "Pushes the branch and reports it ready; no pull request."
            : completePRs ? "Opens a pull request and completes it once it's approved."
            : "Opens a pull request; you review and merge it."

        var stop = switch duration {
        case .untilStopped: "Keeps going until you stop it."
        case .hours: "Stops after \(hours.formatted(.number.precision(.fractionLength(0...1)))) hour\(hours == 1 ? "" : "s")."
        case .until: "Stops at \(until.formatted(date: .abbreviated, time: .shortened))."
        }
        stop += " Sessions finish the step they're on and push their work."

        return [
            FactoryOutlineStep(id: .pick, title: "Picks a work item", detail: pick, asks: []),
            FactoryOutlineStep(id: .start, title: "Starts a Claude session", detail: start, asks: at(.start)),
            FactoryOutlineStep(id: .plan, title: "Plans", detail: "Reads the item and what the knowledge base knows, then plans the steps.", asks: at(.plan)),
            FactoryOutlineStep(id: .build, title: "Builds and tests", detail: build, asks: at(.build)),
            FactoryOutlineStep(id: .newWork, title: "Finds more work", detail: newWork,
                               asks: newWorkItems == .propose ? [FactoryCheckpoint.newWorkItems.short] : []),
            FactoryOutlineStep(id: .deliver, title: "Delivers", detail: deliver, asks: at(.deliver)),
            FactoryOutlineStep(id: .stop, title: "Stops", detail: stop, asks: []),
        ]
    }
}

public struct FactoryTask: Codable, Equatable, Sendable, Identifiable {
    public var workItem: Int
    public var title: String
    public var scope: String
    public var sessionID: String
    public var strategy: String
    public var started: Date
    public var finished: Date?
    public var outcome: String?

    public var id: Int { workItem }
    public var isActive: Bool { finished == nil }

    public init(workItem: Int, title: String, scope: String, sessionID: String, strategy: String = "", started: Date = Date()) {
        self.workItem = workItem
        self.title = title
        self.scope = scope
        self.sessionID = sessionID
        self.strategy = strategy
        self.started = started
    }
}

/// Where a work item stands on the factory's board.
public enum FactoryLane: String, CaseIterable, Sendable, Identifiable {
    case upNext, working, needsYou, review, done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .upNext: return "Up next"
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .review: return "In review"
        case .done: return "Done"
        }
    }

    public var caption: String {
        switch self {
        case .upNext: return "What it takes next, best first"
        case .working: return "Sessions building right now"
        case .needsYou: return "Waiting for your answer; the rest goes on"
        case .review: return "Pull request open; its place is free again"
        case .done: return "Finished in this run"
        }
    }

    public static func of(_ task: FactoryTask, occupiesSlot: Bool, waitsOnUser: Bool) -> FactoryLane {
        if !task.isActive { return .done }
        if waitsOnUser { return .needsYou }
        return occupiesSlot ? .working : .review
    }
}

public struct FactoryQuestion: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sessionID: String
    public var workItem: Int?
    public var checkpoint: String?
    public var text: String
    public var options: [String]
    public var asked: Date
    public var answer: String?
    public var answered: Date?
    /// Settled by something the user answered or decided elsewhere, not by an answer to this question.
    public var indirect: Bool?
    /// What settled it, in a few words.
    public var coveredBy: String?
    /// The user has seen that it was answered for them.
    public var dismissed: Bool?

    public var isOpen: Bool { answer == nil }
    /// Answered for the user, and not dismissed yet.
    public var isAnsweredForYou: Bool { indirect == true && dismissed != true }

    public init(id: UUID = UUID(), sessionID: String, workItem: Int?, checkpoint: String?, text: String, options: [String],
                asked: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.workItem = workItem
        self.checkpoint = checkpoint
        self.text = text
        self.options = options
        self.asked = asked
    }

    /// "Before opening a pull request", or the user's own checkpoint text.
    public var checkpointTitle: String? {
        guard let checkpoint, !checkpoint.isEmpty else { return nil }
        return FactoryCheckpoint(rawValue: checkpoint)?.title ?? checkpoint
    }
}

public struct FactoryEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case info, started, question, answer, fact, done, warning, run }

    public var id: UUID
    public var at: Date
    public var workItem: Int?
    public var kind: Kind
    public var text: String

    public init(id: UUID = UUID(), at: Date = Date(), workItem: Int? = nil, kind: Kind = .info, text: String) {
        self.id = id
        self.at = at
        self.workItem = workItem
        self.kind = kind
        self.text = text
    }
}

public struct FactoryRun: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running, windingDown, stopped
        public var title: String {
            switch self {
            case .running: return "Running"
            case .windingDown: return "Finishing up"
            case .stopped: return "Stopped"
            }
        }
    }

    public var started: Date
    /// When it was last started again after stopping; the board and history carry on from before.
    public var resumed: Date?
    public var endsAt: Date?
    public var status: Status
    public var stopped: Date?
    public var tasks: [FactoryTask] = []
    public var questions: [FactoryQuestion] = []
    public var events: [FactoryEvent] = []
    /// Work items the user told it to leave alone this run.
    public var skipped: [Int] = []
    /// Fact id → a hash of its text, to notice facts that change while it runs.
    public var facts: [String: String] = [:]
    /// Paused: it takes no new work items, while the sessions working carry on.
    public var paused: Bool?

    public init(started: Date = Date(), endsAt: Date?, status: Status = .running) {
        self.started = started
        self.endsAt = endsAt
        self.status = status
    }

    public var activeTasks: [FactoryTask] { tasks.filter(\.isActive) }

    public var isPaused: Bool { status == .running && paused == true }

    /// Whether it may start another work item now.
    public var takesNewWork: Bool { status == .running && paused != true }

    /// Since when it has been running this time: an end time counts from here.
    public var since: Date { resumed ?? started }

    /// Starts a stopped run again, keeping its tasks, questions and history.
    public mutating func resume(endsAt: Date?, at now: Date = Date()) {
        status = .running
        paused = nil
        stopped = nil
        resumed = now
        self.endsAt = endsAt
    }

    public var openQuestions: [FactoryQuestion] { questions.filter(\.isOpen) }
    public var answeredForYou: [FactoryQuestion] { questions.filter(\.isAnsweredForYou) }

    public mutating func log(_ text: String, kind: FactoryEvent.Kind = .info, workItem: Int? = nil, at: Date = Date()) {
        events.append(FactoryEvent(at: at, workItem: workItem, kind: kind, text: text))
        if events.count > 500 { events.removeFirst(events.count - 500) }
    }

    public func task(session id: String) -> FactoryTask? { tasks.last { $0.sessionID == id } }

    /// How far a run with an end time has come, 0 to 1; nil when it runs until stopped.
    public func progress(at now: Date = Date()) -> Double? {
        guard let endsAt, endsAt > since else { return nil }
        return min(1, max(0, now.timeIntervalSince(since) / endsAt.timeIntervalSince(since)))
    }

    /// What happened with one work item, oldest first.
    public func events(for item: Int) -> [FactoryEvent] { events.filter { $0.workItem == item } }

    /// The latest milestone a work item's session logged, for its card.
    public func lastMilestone(for item: Int) -> FactoryEvent? {
        events.last { $0.workItem == item && ($0.kind == .info || $0.kind == .done) }
    }
}

/// What the factory needs to know about a session to tell whether it started it.
public struct FactorySessionInfo: Sendable {
    public var id: String
    public var title: String
    public var project: String?
    public var about: String?
    public var firstMessage: String
    public var created: Date
    public var archived: Bool

    public init(id: String, title: String, project: String?, about: String?, firstMessage: String, created: Date, archived: Bool) {
        self.id = id
        self.title = title
        self.project = project
        self.about = about
        self.firstMessage = firstMessage
        self.created = created
        self.archived = archived
    }
}

public struct Factory: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var rules: FactoryRules
    public var run: FactoryRun?
    public var dashboard: FactoryDashboard

    public init(id: String = UUID().uuidString.lowercased(), name: String, rules: FactoryRules = FactoryRules(), run: FactoryRun? = nil,
                dashboard: FactoryDashboard = .standard) {
        self.id = id
        self.name = name
        self.rules = rules
        self.run = run
        self.dashboard = dashboard
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        rules = try c.decodeIfPresent(FactoryRules.self, forKey: .rules) ?? FactoryRules()
        run = try c.decodeIfPresent(FactoryRun.self, forKey: .run)
        dashboard = (try? c.decodeIfPresent(FactoryDashboard.self, forKey: .dashboard)) ?? .standard
    }

    enum CodingKeys: String, CodingKey { case id, name, rules, run, dashboard }

    public var isRunning: Bool { run.map { $0.status != .stopped } ?? false }

    /// The first line of a session the factory starts, which also marks the session as this factory's.
    public static func sessionLabel(factory name: String, item: Int, title: String) -> String {
        "Software factory “\(name)” · #\(item) \(title)"
    }

    /// Sessions this factory started that its run no longer lists (an earlier run was replaced), as tasks to put
    /// back on the board. Archived sessions and work items the run already has are left out.
    public func lostTasks(_ sessions: [FactorySessionInfo]) -> [FactoryTask] {
        let known = Set(run?.tasks.map(\.workItem) ?? [])
        let prefix = "Software factory “\(name)” · #"
        var out: [FactoryTask] = []
        for s in sessions.sorted(by: { $0.created < $1.created }) where !s.archived && s.firstMessage.hasPrefix(prefix) {
            guard let about = s.about, about.hasPrefix("wi:"), let item = Int(about.dropFirst(3)),
                  !known.contains(item), !out.contains(where: { $0.workItem == item }) else { continue }
            var title = s.title
            if title.hasPrefix("#\(item) ") { title = String(title.dropFirst("#\(item) ".count)) }
            out.append(FactoryTask(workItem: item, title: title, scope: s.project ?? "", sessionID: s.id, started: s.created))
        }
        return out
    }

    public static func decodeList(_ data: Data) -> [Factory] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([Factory].self, from: data)) ?? []
    }

    public static func encodeList(_ list: [Factory]) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(list)
    }
}

/// Which work items a factory may take next, best first.
public enum FactoryPicker {
    /// Not-started items follow the same rules as Build's Ready to Start (`Startable`): the same current sprint and
    /// the same idea of whose an item is.
    public static func candidates(_ backlog: TrackerBacklog, rules: FactoryRules, exclude: Set<Int>, me: [String] = []) -> [TrackerBacklog.Item] {
        let scopes = Set(rules.scopes)
        let picked = backlog.items.filter { item in
            guard !exclude.contains(item.id), scopes.contains(item.scope) || !scopes.isDisjoint(with: item.scopes) else { return false }
            guard item.isBug ? rules.bugs : rules.pbis else { return false }
            let mine = Startable.isMine(item.assignee, flagged: item.mine, me: me)
            guard (mine && rules.assignedToMe) || (item.isUnassigned && rules.unassigned) else { return false }
            switch item.stage {
            case .notStarted: break
            case .inProgress: guard mine && rules.resumeStarted else { return false }
            default: return false
            }
            return inSprint(item, backlog: backlog, filter: rules.sprint)
        }
        return picked.sorted { a, b in
            let (ra, rb) = (a.stage == .inProgress, b.stage == .inProgress)
            if ra != rb { return ra }
            let (ca, cb) = (Startable.inCurrentSprint(a, backlog), Startable.inCurrentSprint(b, backlog))
            if ca != cb { return ca }
            let (ma, mb) = (Startable.isMine(a.assignee, flagged: a.mine, me: me), Startable.isMine(b.assignee, flagged: b.mine, me: me))
            if ma != mb { return ma }
            return a.id < b.id
        }
    }

    static func inSprint(_ item: TrackerBacklog.Item, backlog: TrackerBacklog, filter: FactoryRules.SprintFilter) -> Bool {
        switch filter {
        case .any: return true
        case .current: return Startable.inCurrentSprint(item, backlog)
        case .currentAndNext:
            if Startable.inCurrentSprint(item, backlog) { return true }
            let targets = backlog.moveTargets(for: item)
            guard let current = backlog.currentSprint(scope: item.scope),
                  let i = targets.firstIndex(where: { $0.path == current.path }), i + 1 < targets.count else { return false }
            return item.sprint == targets[i + 1].path
        }
    }
}

/// What a factory tells the sessions it starts.
public enum FactoryBrief {
    /// The first message of the session that builds one work item.
    public static func task(_ item: TrackerBacklog.Item, rules: FactoryRules, factory: String, overviewScope: String?,
                            skill: String?) -> String {
        var s: [String] = []
        s.append("You work for the software factory “\(factory)”: it picks work items one after another under rules the user set, and the user follows it in the Mindmill app's Factory view. Your work item is #\(item.id) “\(item.title)” (\(item.isBug ? "bug" : "PBI"), \(item.state)). Read it first: `kb tracker item \(item.id)`. Check what the KB knows before you decide anything: `kb search \"<keywords>\"` and the facts of the scope (`kb list --section facts --project \(item.scope)`).")
        let recipe = skill.map { "Use the repo's `\($0)` skill as the recipe (Skill tool, args `\(item.id)`)." } ?? "Plan, then implement it with tests, following the repo's conventions."
        s.append("**Build it.** \(recipe) " + prRules(rules))
        s += askRules(rules)
        s.append(newWorkRules(rules, item: item))
        let overview = overviewScope.map { ", or `\($0)` when it holds for the whole product" } ?? ""
        s.append("**Knowledge.** When you learn something durable that isn't in the facts (from the code, docs, or the user's answers), propose it as a fact for the user to confirm: `kb inbox add --scope <\(item.scope)\(overview)> --section facts --proposed-by \"session:$KB_SESSION_ID\" --title \"…\" --summary \"…\" --reason \"…\" --body \"…\"`. Never write facts directly. When a message says a fact or decision changed, check whether it affects your work and adjust.")
        s.append("**Progress.** Log each milestone in one line with `kb factory log \"<what happened>\"`: plan ready, a part done, tests passing, pull request opened, blocked. When your part is done (the pull request is open, or the branch is ready), log `done: <one line>` and reply with a short report. Work only on this work item and its branch.")
        return s.joined(separator: "\n\n")
    }

    /// Sent to the sessions at work when the user changes the rules during a run.
    public static func rulesChanged(_ rules: FactoryRules, scope: String, item: Int) -> String {
        let item = TrackerBacklog.Item(id: item, title: "", scope: scope)
        return (["The user changed the factory's rules. From now on, these replace the matching parts of your brief:", "**Pull requests.** " + prRules(rules)]
                + askRules(rules) + [newWorkRules(rules, item: item)]).joined(separator: "\n\n")
    }

    static func prRules(_ rules: FactoryRules) -> String {
        var pr: String
        if rules.openPRs {
            pr = "Commit on a new branch from the default branch (in a worktree), push, and open a pull request linked to the work item, the way the repo does it. The user approves the commits, the push and the pull request for this work item"
            pr += rules.orderedCheckpoints.contains(.beforePR) && rules.asks ? ", but asks to see it before the pull request is opened (checkpoint below)." : ", so don't stop to ask for those."
        } else {
            pr = "Commit on a new branch (in a worktree) and push it, but don't open a pull request: report that the branch is ready."
        }
        let complete = rules.completePRs
            ? "When the pull request is approved and nothing blocks it, complete it with the repo's merge policy\(rules.orderedCheckpoints.contains(.beforeComplete) && rules.asks ? " after asking (checkpoint below)" : "")."
            : "Never complete or merge a pull request; the user does that."
        return pr + " " + complete
    }

    static func askRules(_ rules: FactoryRules) -> [String] {
        var s: [String] = []
        let points = rules.orderedCheckpoints.map { cp in
            let text = rules.askPoints.first { $0.id == cp.rawValue }?.instruction ?? cp.instruction
            return "- `\(cp.rawValue)`: \(text)"
        } + rules.customCheckpointList.map { c in
            "- \"\(c.title.trimmingCharacters(in: .whitespacesAndNewlines))\"" + (c.instruction.isEmpty ? "" : ": \(c.instruction)")
        }
        switch rules.questions {
        case .never:
            let except = rules.newWorkItems == .propose ? ", except before creating a work item (below)" : ""
            s.append("**Questions.** Don't ask the user anything\(except): make the reasonable choice, and list each assumption in your report and in the pull request description.")
        case .whenUnsure, .checkpointsOnly:
            let unsure = rules.askPoints.first { $0.id == FactoryRules.unsureID }?.instruction ?? FactoryRules.unsureInstruction
            var q = rules.questions == .whenUnsure
                ? "**Questions.** \(unsure)" + (points.isEmpty ? "" : " Always ask at the checkpoints below too.")
                : "**Questions.** Ask only at the checkpoints below; anywhere else, make the reasonable choice and note the assumption in your report."
            q += " Ask with `kb factory ask \"<the question in a sentence or two, with the context>\" --option \"<recommended>\" --option \"<another>\" [--checkpoint <name>]`. It shows in the Factory view and doesn't block you: go on with everything that doesn't depend on the answer (other parts, tests, docs, cleanup). The answer arrives as a message starting with `[From the user via the factory]`. Only when nothing is left, say so in one line and wait. Don't ask with a choices block or AskUserQuestion here."
            s.append(q)
            if !points.isEmpty {
                s.append("**Checkpoints** (ask here, with `--checkpoint <name>`; for the quoted ones the name is the quoted text):\n" + points.joined(separator: "\n"))
            }
        }
        return s
    }

    static func newWorkRules(_ rules: FactoryRules, item: TrackerBacklog.Item) -> String {
        let create = "create it assigned to the user, following the mindmill:work-item skill's conventions: write it with `kb new backlog --project \(item.scope) --title \"…\" --field assignee=me --field related=\"[\(item.id)]\"` (and `--field parent=<number>` when it belongs under the same feature as this item), check it with `kb backlog duplicates --entry <entry id>` (don't create one that already exists), and create it with `kb backlog create <entry id> --sprint current --yes`; the factory picks it up by its rules. Don't create items that only restate this one."
        switch rules.newWorkItems {
        case .never:
            return "**New work.** Don't create work items. Mention work you found that should be done in your report."
        case .propose:
            return "**New work.** For work you find that should be its own item (a bug, a missing piece), ask first: `kb factory ask \"Create a work item: <title>? <why, in a line>\" --option \"Create it\" --option \"Leave it\" --checkpoint newWorkItems`, and carry on meanwhile; the answer arrives as a message starting with `[From the user via the factory]`. When the answer is to create it, \(create) When it isn't, mention it in your report."
        case .create:
            return "**New work.** For work you find that should be its own item, \(create)"
        }
    }

    /// The side conversation the user opens on a question: a throwaway copy of the asking session.
    public static let asideSystemPrompt = "This is a short side conversation, copied from your work session, with the user who is about to answer a question you asked. You are not the working session: don't change files, don't commit or push, and don't run `kb factory`, `kb inbox` or `kb crew` commands; the working session carries on by itself. Answer the user's follow-up questions briefly and concretely from what you know of the work, reading the code or the KB when that helps. Never answer your own question for the user."

    /// The first message of the side conversation: a catch-up before the user answers.
    public static func catchUp(_ question: String) -> String {
        "The user is about to answer your question: “\(question)”. First give them a short catch-up, at most about 120 words, in exactly this shape and with no preamble:\n\n**Done so far**\n- 2 to 4 bullets\n\n**Decided**\n- the decisions made so far and why, in a few words each (or “Nothing yet”)\n\n**Why it asks**\nOne or two lines: what depends on the answer, and your recommendation."
    }

    /// Sent to a task's session when the factory stops or its time is up.
    public static let windDown = "The factory is stopping. Finish the step you're on, commit and push work in progress to your branch, log where you stopped with `kb factory log \"stopped: <where>\"`, and don't start anything new."

    public static func factChanged(_ title: String, id: String, summary: String, kind: String = "fact") -> String {
        "A \(kind) changed while you work: “\(title)” (`\(id)`)\(summary.isEmpty ? "" : ": \(summary)"). Read it with `kb show \(id)` if it may matter. If it affects your work, adjust and log it with `kb factory log`; otherwise carry on and say nothing about it."
    }

    public static func answer(_ question: String, _ answer: String) -> String {
        "Answer to your question “\(question)”:\n\n\(answer)\n\nIf the answer is knowledge others would need too, propose it as a fact as your brief says."
    }
}

extension FactoryRun {
    /// A stable fingerprint of a text (FNV-1a), to notice a fact that changed between two looks.
    public static func fingerprint(_ text: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// Facts that are new or changed since `facts` was taken; ids in `now` → fingerprint.
    public func changedFacts(_ now: [String: String]) -> [String] {
        now.filter { facts[$0.key] != $0.value }.map(\.key).sorted()
    }
}
