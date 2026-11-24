import Foundation

/// Build mode's shared files: the app writes `state.json` (every session, for `kb crew status`), and sessions
/// queue orders in `orders/` with `kb crew send|start|stop`, which the app carries out.
public enum CrewDir {
    public static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let v = environment["KB_CREW_DIR"], !v.isEmpty { return URL(fileURLWithPath: KBConfig.expandTilde(v)) }
        return AppPaths.file("crew")
    }
}

public enum CrewSessionState: String, Codable, Sendable {
    /// A turn is running.
    case working
    /// The last reply asks the user something.
    case waiting
    /// Claude was refused a tool and needs the user's permission.
    case blocked
    /// The process runs and waits for a message.
    case idle
    /// No process; a message starts it again.
    case stopped

    public var needsUser: Bool { self == .waiting || self == .blocked }

    public var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .blocked: return "Needs permission"
        case .idle: return "Idle"
        case .stopped: return "Not running"
        }
    }
}

public struct CrewState: Codable, Equatable, Sendable {
    public struct Session: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var role: SessionRole
        public var lead: String?
        public var project: String?
        public var state: CrewSessionState
        public var activity: String
        public var strategy: String?
        public var model: String?
        public var updated: String
        public var last: String
        public var about: String?

        public init(id: String, title: String, role: SessionRole, lead: String?, project: String?, state: CrewSessionState,
                    activity: String, strategy: String?, model: String?, updated: String, last: String, about: String?) {
            self.id = id
            self.title = title
            self.role = role
            self.lead = lead
            self.project = project
            self.state = state
            self.activity = activity
            self.strategy = strategy
            self.model = model
            self.updated = updated
            self.last = last
            self.about = about
        }
    }

    public var updated: String
    public var sessions: [Session]

    public init(updated: String, sessions: [Session]) {
        self.updated = updated
        self.sessions = sessions
    }

    /// The same picture as `kb crew status`, for the overview session's messages.
    public var statusText: String {
        func line(_ s: Session) -> String {
            var parts = ["\(s.title) [\(s.id.prefix(8))]"]
            if let p = s.project { parts.append(p) }
            parts.append(s.state.label.lowercased())
            if !s.activity.isEmpty { parts.append(s.activity) }
            if let st = s.strategy { parts.append("strategy \(st)") }
            if !s.last.isEmpty, s.state != .working {
                let last = s.last.replacingOccurrences(of: "\n", with: " ")
                parts.append("last: " + (last.count > 140 ? String(last.prefix(137)) + "…" : last))
            }
            return parts.joined(separator: " · ")
        }
        let leads = sessions.filter { $0.role == .lead }
        let members = sessions.filter { $0.role == .member }
        let leadIDs = Set(leads.map(\.id))
        let solos = sessions.filter { s in s.role == .solo || (s.role == .member && !leadIDs.contains(s.lead ?? "")) }
        var out: [String] = []
        if leads.isEmpty && solos.isEmpty { return "No sessions are running." }
        for l in leads {
            out.append("★ " + line(l))
            for m in members where m.lead == l.id { out.append("    - " + line(m)) }
        }
        if !solos.isEmpty {
            out.append("Other sessions:")
            out += solos.map { "  - " + line($0) }
        }
        return out.joined(separator: "\n")
    }
}

/// One order a session queued with `kb crew`.
public enum CrewOrder: Equatable, Sendable {
    case send(to: String, text: String, from: String)
    case start(StartRequest)
    case stop(to: String, from: String)
    /// The session reached its purpose and the user said to archive it.
    case archive(to: String, from: String)
    /// A factory session asks the user without blocking.
    case factoryAsk(from: String, text: String, options: [String], checkpoint: String?)
    /// A factory session's progress line.
    case factoryLog(from: String, text: String)
    /// `kb sync`: refresh these now and write the outcome where the command waits for it.
    case sync(SyncRequest)

    public struct SyncRequest: Equatable, Sendable {
        public static let kinds = ["calendar", "email", "tracker", "prs"]
        public var id: String
        public var what: [String]
        public var range: (from: String, to: String)?
        public var from: String

        public init(id: String, what: [String], range: (from: String, to: String)? = nil, from: String = "cli") {
            self.id = id
            self.what = what
            self.range = range
            self.from = from
        }

        public static func == (a: Self, b: Self) -> Bool {
            a.id == b.id && a.what == b.what && a.range?.from == b.range?.from && a.range?.to == b.range?.to && a.from == b.from
        }
    }

    public struct StartRequest: Equatable, Sendable {
        public var title: String
        public var parent: String?
        public var lead: Bool
        public var project: String?
        public var model: String?
        public var strategy: String?
        public var about: String?
        public var text: String
        public var from: String

        public init(title: String, parent: String? = nil, lead: Bool = false, project: String? = nil, model: String? = nil,
                    strategy: String? = nil, about: String? = nil, text: String = "", from: String = "cli") {
            self.title = title
            self.parent = parent
            self.lead = lead
            self.project = project
            self.model = model
            self.strategy = strategy
            self.about = about
            self.text = text
            self.from = from
        }
    }

    public static func parse(_ data: Data) -> CrewOrder? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func str(_ k: String) -> String? {
            guard let v = obj[k] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let from = str("from") ?? "cli"
        switch obj["kind"] as? String {
        case "send":
            guard let to = str("to"), let text = str("text") else { return nil }
            return .send(to: to, text: text, from: from)
        case "start":
            guard let title = str("title") else { return nil }
            return .start(StartRequest(title: title, parent: str("parent"), lead: (obj["lead"] as? Bool) ?? false,
                                       project: str("project"), model: str("model"), strategy: str("strategy"),
                                       about: str("about"), text: str("text") ?? "", from: from))
        case "stop":
            guard let to = str("to") else { return nil }
            return .stop(to: to, from: from)
        case "archive":
            guard let to = str("to") else { return nil }
            return .archive(to: to, from: from)
        case "factory_ask":
            guard let text = str("text") else { return nil }
            let options = (obj["options"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .factoryAsk(from: from, text: text, options: options, checkpoint: str("checkpoint"))
        case "factory_log":
            guard let text = str("text") else { return nil }
            return .factoryLog(from: from, text: text)
        case "sync":
            guard let id = str("id"), id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            let what = (obj["what"] as? [String] ?? []).filter(SyncRequest.kinds.contains)
            guard !what.isEmpty else { return nil }
            let range = str("range_from").flatMap { f in str("range_to").map { (from: f, to: $0) } }
            return .sync(SyncRequest(id: id, what: what, range: range, from: from))
        default:
            return nil
        }
    }
}

/// A way of working a session can follow: instructions it gets, and whether it leads and starts sessions of its own.
/// A strategy as a picture: who works on it, and the steps it goes through.
public struct StrategyShape: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public enum Kind: Sendable { case work, approval, review }
        public let title: String
        public let kind: Kind
        /// Done again for each part or step, not once.
        public let repeats: Bool
    }

    public struct Helper: Equatable, Sendable {
        public let label: String
        public let model: String
        public var role: StrategyRole?
    }

    public let steps: [Step]
    public let helpers: [Helper]
    /// The whole flow runs once per behaviour, part or step ("For every …").
    public let loops: Bool
}

extension Strategy {
    public var shape: StrategyShape {
        let lines = instructions.components(separatedBy: "\n")
        var steps: [StrategyShape.Step] = []
        var current: [String] = []
        var preamble: [String] = []
        func flush() {
            guard let first = current.first else { return }
            let text = current.joined(separator: " ")
            let lower = text.lowercased()
            let title = Self.stepTitle(first)
            let approval = lower.contains("approv") || lower.contains("```choices") || lower.contains("ask for")
            let repeats = ["each step", "one step at a time", "after each", "for every", "each part", "every step", "until"]
                .contains { lower.contains($0) }
            steps.append(.init(title: title, kind: approval ? .approval : .work, repeats: repeats))
            current = []
        }
        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: #"^\d+\.\s+"#, options: .regularExpression), raw.first?.isNumber == true {
                flush()
                current = [String(t[r.upperBound...])]
            } else if !current.isEmpty {
                current.append(t)
            } else if !t.isEmpty {
                preamble.append(t)
            }
        }
        flush()
        if steps.isEmpty, !instructions.isEmpty {
            steps = [.init(title: Self.stepTitle(preamble.first ?? title), kind: .work, repeats: false)]
        }
        if !roles.isEmpty, steps.count <= 1 { steps = roleSteps }
        var helpers: [StrategyShape.Helper] = []
        if !roles.isEmpty {
            helpers = roles.map { .init(label: $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name, model: $0.model, role: $0) }
        } else if spawns {
            let lower = instructions.lowercased()
            if lower.contains("reviewer") {
                helpers = [.init(label: "Reviewer", model: model)]
            } else {
                helpers = (0..<max(1, min(maxSessions, 4))).map { i in .init(label: "Part \(i + 1)", model: model) }
            }
        }
        let pre = preamble.joined(separator: " ").lowercased()
        return StrategyShape(steps: steps, helpers: helpers, loops: pre.contains("for every") || pre.contains("for each"))
    }

    /// The steps a role-based strategy goes through, when its instructions don't number their own.
    var roleSteps: [StrategyShape.Step] {
        let builders = roles.filter { $0.kind == .builder }
        let reviewers = roles.filter { $0.kind == .reviewer }
        let helpers = roles.filter { $0.kind == .helper }
        let eachStep = reviewers.filter { $0.checkpoint == .eachStep }
        var steps: [StrategyShape.Step] = [.init(title: "Lead reads the task and plans", kind: .work, repeats: false)]
        if !builders.isEmpty {
            steps.append(.init(title: "Splits it into parts", kind: .work, repeats: false))
            steps.append(.init(title: builders.map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }.joined(separator: ", ") + " build in parallel", kind: .work, repeats: false))
            steps.append(.init(title: "Lead integrates each part", kind: .work, repeats: true))
        } else {
            steps.append(.init(title: "Lead builds in small steps", kind: .work, repeats: !eachStep.isEmpty))
        }
        for r in eachStep { steps.append(.init(title: "\(r.name) checks each step", kind: .review, repeats: true)) }
        for r in helpers { steps.append(.init(title: r.name + (r.duty.isEmpty ? " helps" : ": " + Self.stepTitle(r.duty)), kind: .work, repeats: false)) }
        for r in reviewers where r.checkpoint == .beforePR { steps.append(.init(title: "\(r.name) checks it all", kind: .review, repeats: false)) }
        steps.append(.init(title: "Tests pass, lead sums up for you", kind: .work, repeats: false))
        return steps
    }

    /// `**Size it up.** Read …` → "Size it up"; otherwise the first clause, kept short.
    static func stepTitle(_ line: String) -> String {
        if line.hasPrefix("**"), let end = line.dropFirst(2).range(of: "**") {
            var t = String(line.dropFirst(2)[..<end.lowerBound])
            while let last = t.last, ".:".contains(last) { t.removeLast() }
            return t
        }
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        let cut = plain.firstIndex { ".:;(,".contains($0) } ?? plain.endIndex
        let first = String(plain[..<cut]).trimmingCharacters(in: .whitespaces)
        return first.count > 44 ? String(first.prefix(42)) + "…" : first
    }
}

/// One kind of session a strategy's lead starts under it: who it is, which model, how many, and what it does.
public struct StrategyRole: Equatable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        /// Builds a part of the work, in parallel with the others.
        case builder
        /// Checks the lead's work at a checkpoint; the lead fixes its findings before going on.
        case reviewer
        /// Anything else: tests, docs, research.
        case helper

        public var title: String {
            switch self {
            case .builder: return "Builder"
            case .reviewer: return "Reviewer"
            case .helper: return "Helper"
            }
        }
    }

    /// When a reviewer checks.
    public enum Checkpoint: String, CaseIterable, Sendable {
        case eachStep = "each-step", beforePR = "before-pr", whenAsked = "when-asked"

        public var title: String {
            switch self {
            case .eachStep: return "After each step"
            case .beforePR: return "Before the PR"
            case .whenAsked: return "When the lead asks"
            }
        }
    }

    public var id = UUID()
    public var name: String
    public var kind: Kind
    public var model: String
    public var count: Int
    public var checkpoint: Checkpoint
    /// What it does and how it behaves; becomes its brief.
    public var duty: String

    public init(name: String, kind: Kind = .builder, model: String = "", count: Int = 1,
                checkpoint: Checkpoint = .eachStep, duty: String = "") {
        self.name = name
        self.kind = kind
        self.model = model
        self.count = count
        self.checkpoint = checkpoint
        self.duty = duty
    }

    public static func == (a: StrategyRole, b: StrategyRole) -> Bool {
        a.name == b.name && a.kind == b.kind && a.model == b.model && a.count == b.count
            && a.checkpoint == b.checkpoint && a.duty == b.duty
    }

    /// `Reviewer | reviewer | opus | 2 | each-step | Checks correctness and tests`
    public var line: String {
        [name, kind.rawValue, model, String(count), checkpoint.rawValue, duty.replacingOccurrences(of: "\n", with: " ")]
            .joined(separator: " | ")
    }

    public static func parse(_ line: String) -> StrategyRole? {
        let parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 6, !parts[0].isEmpty else { return nil }
        return StrategyRole(name: parts[0], kind: Kind(rawValue: parts[1]) ?? .helper, model: parts[2],
                            count: max(1, min(10, Int(parts[3]) ?? 1)), checkpoint: Checkpoint(rawValue: parts[4]) ?? .eachStep,
                            duty: parts[5...].joined(separator: " | "))
    }

    /// The `kb crew start` line the lead runs for one of these sessions.
    var startCommand: String {
        let brief = duty.isEmpty ? "<brief>" : duty.replacingOccurrences(of: "\"", with: "'")
        let m = model.isEmpty ? "" : " --model \(model)"
        return "`kb crew start --under me --title \"\(name)\"\(m) \"\(brief)\"`"
    }
}

public struct Strategy: Identifiable, Equatable, Sendable {
    public enum Origin: String, Sendable { case builtIn, custom, override }

    public var slug: String
    public var title: String
    public var summary: String
    /// The session leads and starts sessions under it as it needs them.
    public var spawns: Bool
    public var maxSessions: Int
    /// The model for the sessions it starts; empty means the default.
    public var model: String
    public var instructions: String
    public var origin: Origin
    /// The model for the lead session itself; empty means the default.
    public var leadModel: String
    /// The sessions the lead starts, when the strategy defines them; otherwise the instructions say.
    public var roles: [StrategyRole]

    public var id: String { slug }
    public var isBuiltIn: Bool { origin != .custom }
    public var sessionCount: Int { roles.isEmpty ? maxSessions : roles.reduce(0) { $0 + $1.count } }

    public init(slug: String, title: String, summary: String = "", spawns: Bool = false, maxSessions: Int = 3,
                model: String = "", instructions: String = "", origin: Origin = .custom,
                leadModel: String = "", roles: [StrategyRole] = []) {
        self.slug = slug
        self.title = title
        self.summary = summary
        self.spawns = spawns
        self.maxSessions = maxSessions
        self.model = model
        self.instructions = instructions
        self.origin = origin
        self.leadModel = leadModel
        self.roles = roles
    }

    public static func parse(_ text: String, slug: String, origin: Origin) -> Strategy {
        let parsed = FrontmatterCodec.parse(text)
        let fm = parsed.frontmatter
        let roles = (1...20).compactMap { fm.string("role_\($0)").flatMap(StrategyRole.parse) }
        return Strategy(slug: slug, title: fm.string("title") ?? slug, summary: fm.string("summary") ?? "",
                        spawns: fm.string("spawn") == "auto" || !roles.isEmpty, maxSessions: Int(fm.string("max_sessions") ?? "") ?? 3,
                        model: fm.string("model") ?? "", instructions: parsed.body.trimmingCharacters(in: .whitespacesAndNewlines),
                        origin: origin, leadModel: fm.string("lead_model") ?? "", roles: roles)
    }

    public var fileText: String {
        func q(_ s: String) -> String {
            s.isEmpty || s.contains(":") || s.contains("#") || s.hasPrefix("[") || s.hasPrefix("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : s
        }
        var lines = ["---", "title: \(q(title))"]
        if !summary.isEmpty { lines.append("summary: \(q(summary))") }
        let spawning = spawns || !roles.isEmpty
        lines.append("spawn: \(spawning ? "auto" : "none")")
        if spawning { lines.append("max_sessions: \(sessionCount)") }
        if !model.isEmpty { lines.append("model: \(model)") }
        if !leadModel.isEmpty { lines.append("lead_model: \(leadModel)") }
        for (i, r) in roles.enumerated() { lines.append("role_\(i + 1): \(q(r.line))") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + instructions.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// What the session is told when the user picks the strategy.
    public var message: String {
        var s = "From now on, work with the strategy **\(title)**"
        if !summary.isEmpty { s += " (\(summary))" }
        s += ":\n\n" + instructions
        if !roles.isEmpty {
            s += (instructions.isEmpty ? "" : "\n\n") + teamInstructions
        } else if spawns {
            s += "\n\nYou may start up to \(maxSessions) session\(maxSessions == 1 ? "" : "s") under you with `kb crew start --under me`"
            s += model.isEmpty ? "." : " (model `\(model)` unless a part clearly needs another)."
        }
        return s
    }

    /// A strategy in plain words, a line per point, for its details.
    public var howItWorks: [String] {
        var lines: [String] = []
        let lead = leadModel.isEmpty ? "" : " (\(leadModel.capitalized))"
        if roles.isEmpty && !spawns {
            lines.append("One session does all the work\(lead), following the steps below. Nothing runs beside it.")
        } else {
            lines.append("The session you start is the lead\(lead): it plans, starts the other sessions and puts their work together.")
        }
        for r in roles {
            let who = r.count > 1 ? "\(r.count) \(r.name) sessions" : "A \(r.name) session"
            let model = r.model.isEmpty ? "" : " on \(r.model.capitalized)"
            switch r.kind {
            case .builder:
                lines.append("\(who)\(model) each build\(r.count > 1 ? "" : "s") a part, in parallel, on files the others don't touch.")
            case .reviewer:
                lines.append("\(who)\(model) check\(r.count > 1 ? "" : "s") the lead's work \(r.checkpoint.title.lowercased()). The lead fixes the findings before going on. Reviewers never edit files.")
            case .helper:
                lines.append("\(who)\(model): \(r.duty.isEmpty ? "helps where the lead needs it." : r.duty)")
            }
        }
        if roles.isEmpty && spawns {
            let m = model.isEmpty ? "" : " on \(model.capitalized)"
            lines.append("It decides itself which sessions to start: at most \(maxSessions)\(m), as the steps below describe.")
        }
        if roles.isEmpty == false || spawns {
            lines.append("They show under the lead in Build. You talk to the lead; the Overview session sees all of them and tells you what needs you.")
        }
        lines.append("Nothing is committed or pushed without your yes, unless you start it with Fast.")
        return lines
    }

    /// What the lead is told about the sessions it starts, generated from the roles.
    public var teamInstructions: String {
        var lines = ["## Your team", "You lead. Start these sessions under you, and only these:"]
        for r in roles {
            let who = r.count > 1 ? "\(r.count) × **\(r.name)**" : "**\(r.name)**"
            let model = r.model.isEmpty ? "" : " (model \(r.model))"
            switch r.kind {
            case .builder:
                lines.append("- \(who)\(model): builds a part of the work in parallel with the others. Give each a part that touches different files. \(r.duty)")
            case .reviewer:
                lines.append("- \(who)\(model): reviews your work \(r.checkpoint.title.lowercased()). Send it what changed and wait for its findings; fix them before you go on, or say why not. It never edits files. \(r.duty)")
            case .helper:
                lines.append("- \(who)\(model): \(r.duty.isEmpty ? "helps where you need it." : r.duty)")
            }
            lines.append("  Start with \(r.startCommand)" + (r.count > 1 ? ", once per session." : "."))
        }
        lines.append("Every brief says the goal, the files, when it is done, and to report back with `kb crew send lead \"<what changed, what is left>\"`. `kb crew status` shows your sessions.")
        return lines.joined(separator: "\n")
    }

    public static func slugify(_ title: String) -> String {
        let lowered = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let s = String(lowered).split(separator: "-").joined(separator: "-")
        return s.isEmpty ? "strategy" : String(s.prefix(40))
    }
}

/// Built-in strategies ship with the plugin (`strategies/`); the user's own live in the KB (`strategies/`) and
/// override a built-in with the same slug.
public enum StrategyStore {
    public static func load(pluginRoot: URL, kbRoot: URL) -> [Strategy] {
        let builtIns = read(pluginRoot.appendingPathComponent("strategies"), origin: .builtIn)
        let own = read(kbRoot.appendingPathComponent("strategies"), origin: .custom)
        var bySlug: [String: Strategy] = [:]
        for s in builtIns { bySlug[s.slug] = s }
        for var s in own {
            if bySlug[s.slug]?.origin == .builtIn { s.origin = .override }
            bySlug[s.slug] = s
        }
        let order = builtIns.map(\.slug)
        return bySlug.values.sorted { a, b in
            let ia = order.firstIndex(of: a.slug) ?? Int.max
            let ib = order.firstIndex(of: b.slug) ?? Int.max
            return ia != ib ? ia < ib : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    private static func read(_ dir: URL, origin: Strategy.Origin) -> [Strategy] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return Strategy.parse(text, slug: url.deletingPathExtension().lastPathComponent, origin: origin)
        }
    }

    public static func save(_ s: Strategy, kbRoot: URL) throws {
        let dir = kbRoot.appendingPathComponent("strategies")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try s.fileText.write(to: dir.appendingPathComponent("\(s.slug).md"), atomically: true, encoding: .utf8)
    }

    /// Deletes the user's file: a custom strategy goes away, an override falls back to the built-in.
    public static func delete(_ slug: String, kbRoot: URL) throws {
        let url = kbRoot.appendingPathComponent("strategies/\(slug).md")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
