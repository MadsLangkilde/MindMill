import Foundation

/// An AI assistant KB can work through. KB drives one through its command line; today only Claude Code has what KB
/// needs (its plugin with Mindmill's skills, streaming sessions, connectors and tool permissions). The others are listed so
/// the user sees them and the rest of the app asks for an assistant by these fields, never by name.
public struct AIProvider: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// How the app names it in buttons and menus: "Ask Claude", "Ask Codex".
    public var shortName: String
    /// The command KB runs.
    public var command: String
    /// Typed in Terminal to install it.
    public var installCommand: String
    public var docsURL: URL
    /// The models it offers, for assigning one to a task; empty takes whatever the assistant defaults to.
    public var models: [String]
    /// KB can run it. Until it can, it is shown but can't be chosen.
    public var supported: Bool

    public static let claudeCode = AIProvider(
        id: "claude-code", name: "Claude Code", shortName: "Claude", command: "claude",
        installCommand: "curl -fsSL https://claude.ai/install.sh | bash",
        docsURL: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!,
        models: ["opus", "sonnet", "haiku"], supported: true)

    public static let codex = AIProvider(
        id: "codex", name: "OpenAI Codex", shortName: "Codex", command: "codex",
        installCommand: "npm install -g @openai/codex",
        docsURL: URL(string: "https://developers.openai.com/codex/cli")!,
        models: [], supported: false)

    public static let gemini = AIProvider(
        id: "gemini", name: "Gemini CLI", shortName: "Gemini", command: "gemini",
        installCommand: "npm install -g @google/gemini-cli",
        docsURL: URL(string: "https://github.com/google-gemini/gemini-cli")!,
        models: [], supported: false)

    public static let all = [claudeCode, codex, gemini]

    public static func with(id: String) -> AIProvider? { all.first { $0.id == id } }
}

/// What KB uses an AI for. Each can go to the brain with its default model, or to another model or assistant.
public enum AITask: String, CaseIterable, Codable, Sendable, Identifiable {
    case work, ask, meetings, voice, background, calendar

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .work: return "Sessions and longer work"
        case .ask: return "Questions"
        case .meetings: return "Live meetings"
        case .voice: return "Voice"
        case .background: return "Background upkeep"
        case .calendar: return "Calendar sync"
        }
    }

    public var note: String {
        switch self {
        case .work: return "Plan and Build sessions, meeting prep, research, email and project scans."
        case .ask: return "Ask, and questions about a proposal before you approve it."
        case .meetings: return "The meeting companion while a meeting runs; a fast model keeps up."
        case .voice: return "Talking to Mindmill on the Mac or phone; a fast model answers sooner."
        case .background: return "Tagging, checking facts and follow-ups, link suggestions, quiz questions."
        case .calendar: return "Mirroring today's and tomorrow's events; a small model is enough."
        }
    }
}

/// Which assistant is the brain, and which assistant and model each task uses. Saved in the user defaults.
public struct AISetup: Codable, Equatable, Sendable {
    public struct Assignment: Codable, Equatable, Sendable {
        public var provider: String
        /// Empty for the assistant's default.
        public var model: String

        public init(provider: String, model: String) {
            self.provider = provider
            self.model = model
        }
    }

    public static let key = "aiSetup"

    public var brain: String
    public var tasks: [AITask: Assignment]
    /// Assistants to put Mindmill's skills in besides those in use (`AssistantSkills`), to use them there directly.
    public var skillsIn: [String]?

    public init(brain: String = AIProvider.claudeCode.id, tasks: [AITask: Assignment] = [:]) {
        self.brain = brain
        self.tasks = tasks
    }

    public var brainProvider: AIProvider { AIProvider.with(id: brain).flatMap { $0.supported ? $0 : nil } ?? .claudeCode }

    /// The assistant a task runs on: its own when set and supported, else the brain.
    public func provider(for task: AITask) -> AIProvider {
        tasks[task].flatMap { AIProvider.with(id: $0.provider) }.flatMap { $0.supported ? $0 : nil } ?? brainProvider
    }

    public func model(for task: AITask) -> String {
        guard let a = tasks[task], provider(for: task).id == a.provider else { return "" }
        return a.model
    }

    /// The first time: the models chosen before there was a brain setting carry over.
    public static func migrated(defaults: UserDefaults) -> AISetup {
        if let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(AISetup.self, from: data) { return s }
        var s = AISetup()
        let claude = AIProvider.claudeCode.id
        func carry(_ legacy: String, _ fallback: String, to tasks: [AITask]) {
            let m = defaults.string(forKey: legacy) ?? fallback
            for t in tasks where !m.isEmpty { s.tasks[t] = Assignment(provider: claude, model: m) }
        }
        carry("defaultModel", "", to: [.work, .ask])
        carry("liveModel", "sonnet", to: [.meetings, .voice, .background])
        carry("calendarModel", "haiku", to: [.calendar])
        return s
    }

    public func save(defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
        Brain.forget()
    }
}

/// The brain's name for buttons, menus and messages, so the app says "Ask Codex" when Codex is the brain.
public enum Brain {
    private static var cached: String?

    public static var name: String {
        if let cached { return cached }
        let n = AISetup.migrated(defaults: .standard).brainProvider.shortName
        cached = n
        return n
    }

    /// After the setup changes.
    static func forget() { cached = nil }
}

/// When the first-run setup shows: until an AI assistant is installed, and on a first launch with no knowledge base.
public enum OnboardingGate {
    public static let completedKey = "onboardingCompleted"

    public enum Step: Int, CaseIterable, Sendable {
        case assistant, knowledgeBase, voice, tools

        public var title: String {
            switch self {
            case .assistant: return "Your AI"
            case .knowledgeBase: return "Knowledge Base"
            case .voice: return "Voice"
            case .tools: return "Your Tools"
            }
        }
    }

    /// `aiFound` is nil while KB is still looking for it; that alone never shows the setup.
    public static func needed(completed: Bool, aiFound: Bool?, hasKnowledgeBase: Bool, forced: Bool) -> Bool {
        forced || aiFound == false || (!completed && !hasKnowledgeBase)
    }

    /// The step to open on: the first one that isn't ready.
    public static func firstStep(assistantReady: Bool, hasKnowledgeBase: Bool) -> Step {
        !assistantReady ? .assistant : !hasKnowledgeBase ? .knowledgeBase : .tools
    }
}

/// Setting up the tools KB reaches (work tracker, mail, calendar, chat, docs) with Claude as the middle man: the
/// app collects what the user wants, and a Claude session checks, connects and writes Mindmill's settings.
public enum SourceSetup {
    public struct Tracker: Equatable, Sendable, Identifiable {
        public var kind: String
        public var title: String
        public var note: String
        public var id: String { kind }
    }

    public static let trackers: [Tracker] = [
        Tracker(kind: "azure-devops", title: "Azure DevOps", note: "Boards, sprints and pull requests; Mindmill talks to it directly."),
        Tracker(kind: "jira", title: "Jira", note: "Through Claude's Atlassian connector."),
        Tracker(kind: "github", title: "GitHub Issues", note: "Through Claude's GitHub connector."),
        Tracker(kind: "linear", title: "Linear", note: "Through Claude's Linear connector."),
        Tracker(kind: "local", title: "Mindmill's own tracker", note: "Features, PBIs, bugs and tasks kept in the knowledge base. Nothing to connect."),
    ]

    public struct Scope: Equatable, Sendable {
        public var id: String
        public var title: String
        public var tracker: String

        public init(id: String, title: String, tracker: String) {
            self.id = id
            self.title = title
            self.tracker = tracker
        }
    }

    /// The first message of the setup session. `tracker` is nil to leave it as each scope has it, `tools` are
    /// `ClaudeConnectors.catalog` ids besides the tracker, and `connected` is what `claude mcp list` showed.
    public static func brief(tracker: String?, tools: [String], scopes: [Scope],
                             connected: [ClaudeConnectors.Server]) -> String {
        var out = ["Help me set up the tools Mindmill works with. You are the middle man: check what is connected, walk me through connecting what is missing, and write Mindmill's settings. Ask one thing at a time, with choices where you can. Change nothing besides Mindmill's settings and Claude's connectors."]

        let reach = connected.map { "\($0.displayName) (\($0.status.rawValue))" }
        out.append("## Connected to Claude now\n\n" + (reach.isEmpty ? "Nothing yet." : reach.joined(separator: ", "))
                   + "\n\nAfter I connect something, check again with `claude mcp list`.")

        if !scopes.isEmpty {
            let lines = scopes.map { "- \($0.title) (`\($0.id)`): " + ($0.tracker.isEmpty || $0.tracker == "none" ? "no tracker" : $0.tracker) }
            out.append("## My scopes and their trackers\n\n" + lines.joined(separator: "\n"))
        }

        if let tracker, let t = trackers.first(where: { $0.kind == tracker }) {
            var steps = "## Work tracking: \(t.title)\n\nAsk which scopes use it, then for each one:\n"
            switch tracker {
            case "azure-devops":
                steps += """
                - Find the organization and project (from the repository's git remote when there is one, else ask me).
                - KB reads a personal access token from `~/.git-credentials` (a line like `https://<name>:<token>@dev.azure.com`) or `KB_ADO_PAT`. If none is there, tell me how to make one (Work Items and Code: read and write) and how to store it. Never ask me to paste a token into this chat.
                - Check that KB reaches it with `kb tracker sprints --scope <id>`, then offer the area path and iteration root from `kb tracker areas --scope <id>` and the sprints.
                - Save with `kb settings set tracker '{"kind": "azure-devops", "organization": …, "project": …, "area_path": …, "iteration_root": …}' --scope <id>`, keeping keys it already has.
                """
            case "local":
                steps += "- Save `kb settings set tracker '{\"kind\": \"local\"}' --scope <id>`; there is nothing to connect. Offer sprints with `kb work sprint add`."
            default:
                steps += """
                - If \(t.title) isn't connected above, tell me to add it at claude.ai → Settings → Connectors (https://claude.ai/settings/connectors), wait until I say it's done, and check again.
                - Use the connector to find the site or organization and the project, and confirm them with me.
                - Save with `kb settings set tracker '{"kind": "\(tracker)", "organization": …, "project": …}' --scope <id>`.
                """
            }
            out.append(steps)
        }

        let picked = tools.compactMap { id in ClaudeConnectors.catalog.first { $0.id == id } }
        if !picked.isEmpty {
            let lines = picked.map { s -> String in
                let have = !ClaudeConnectors.servers(for: s, in: connected).filter { $0.status == .connected }.isEmpty
                return "- \(s.title): " + (have ? "connected; check it answers with one small read." : "not connected. \(s.note)")
            }
            out.append("## Other tools\n\n" + lines.joined(separator: "\n")
                       + "\n\nFor one that isn't connected, send me to claude.ai → Settings → Connectors, or for a tool with its own MCP address, to Mindmill's Settings → Connections → Add a Tool. One that needs signing in again: Settings → Connections → Sign In.")
        }

        out.append("Mindmill's skills use the tools saved with `kb tools` (mail, chat, calendar, documents) and each scope's tracker. When I tell you I use a different one for something, save it with `kb tools set <area> <tool>`.")
        out.append("End with a short table: each tool, whether it works now, and what is left for me to do.")
        return out.joined(separator: "\n\n")
    }
}
