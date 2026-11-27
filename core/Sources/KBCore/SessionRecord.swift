import Foundation

/// A Claude session window's conversation, saved so it survives quitting the app and can be resumed.
public struct SessionRecord: Codable, Identifiable, Equatable, Sendable {
    public struct Message: Codable, Equatable, Sendable {
        public var role: String
        public var text: String
        public var attachments: [Attachment]?
        /// When it was sent or arrived; nil for messages saved before times were kept.
        public var at: Date?
        public init(role: String, text: String, attachments: [Attachment]? = nil, at: Date? = nil) {
            self.role = role
            self.text = text
            self.attachments = attachments
            self.at = at
        }
    }

    public var id: String
    public var title: String
    public var project: String?
    /// Claude's own session id, for `--resume`.
    public var claudeSessionID: String?
    public var workingDirectory: String
    public var created: Date
    public var updated: Date
    /// Tools the user allowed on top of the defaults, after Claude was refused them.
    public var extraTools: [String]
    public var messages: [Message]
    /// Where the session sits in Build mode: alone, the overview session, a lead, or a session under a lead.
    public var role: SessionRole
    /// The lead a member reports to.
    public var parentID: String?
    /// The slug of the strategy the session follows.
    public var strategy: String?
    /// Empty or nil means the user's default model.
    public var model: String?
    /// The KB entry the session works on, so Plan mode can show it is in progress.
    public var about: String?
    /// A strategy was picked for this session at some point. Kept for sessions saved by older versions.
    public var strategyOffered: Bool
    /// Plan sessions live in the Claude window; Build sessions in Build mode. Neither shows the other's.
    public var space: SessionSpace
    /// nil: archived once its work is done; true: archived by the user; false: kept out of the archive.
    public var archived: Bool?
    /// The app asked once whether this Build session is research and should move to Plan.
    public var researchOffered: Bool?
    /// What the user asked for when starting it: shown pinned at the top, not as a message.
    public var brief: String?
    /// Separate copies of the code the session said it works in (`kb crew folder`), for testing what it built.
    public var folders: [String]?

    public init(id: String = UUID().uuidString.lowercased(), title: String, project: String?, claudeSessionID: String? = nil,
                workingDirectory: String, created: Date = Date(), updated: Date = Date(), extraTools: [String] = [],
                messages: [Message] = [], role: SessionRole = .solo, parentID: String? = nil, strategy: String? = nil,
                model: String? = nil, about: String? = nil, strategyOffered: Bool = false, space: SessionSpace? = nil,
                archived: Bool? = nil, researchOffered: Bool? = nil, brief: String? = nil, folders: [String]? = nil) {
        self.brief = brief
        self.folders = folders
        self.archived = archived
        self.researchOffered = researchOffered
        self.id = id
        self.title = title
        self.project = project
        self.claudeSessionID = claudeSessionID
        self.workingDirectory = workingDirectory
        self.created = created
        self.updated = updated
        self.extraTools = extraTools
        self.messages = messages
        self.role = role
        self.parentID = parentID
        self.strategy = strategy
        self.model = model
        self.about = about
        self.strategyOffered = strategyOffered
        self.space = space ?? (role == .solo ? .plan : .build)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, project, claudeSessionID, workingDirectory, created, updated, extraTools, messages
        case role, parentID, strategy, model, about, strategyOffered, space, archived, researchOffered, brief, folders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        claudeSessionID = try c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        created = try c.decode(Date.self, forKey: .created)
        updated = try c.decode(Date.self, forKey: .updated)
        extraTools = try c.decodeIfPresent([String].self, forKey: .extraTools) ?? []
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        role = (try? c.decodeIfPresent(SessionRole.self, forKey: .role)) ?? .solo
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        strategy = try c.decodeIfPresent(String.self, forKey: .strategy)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        about = try c.decodeIfPresent(String.self, forKey: .about)
        strategyOffered = try c.decodeIfPresent(Bool.self, forKey: .strategyOffered) ?? false
        space = (try? c.decodeIfPresent(SessionSpace.self, forKey: .space)) ?? (role == .solo ? .plan : .build)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived)
        researchOffered = try c.decodeIfPresent(Bool.self, forKey: .researchOffered)
        brief = try c.decodeIfPresent(String.self, forKey: .brief)
        folders = try c.decodeIfPresent([String].self, forKey: .folders)
    }

    /// A research's session: kept as long as the research is, whatever its age.
    public var isResearch: Bool { about?.hasPrefix("research:") == true }
    /// Research and notes keep their session as long as they exist.
    public var keptWithItsEntry: Bool { isResearch || about?.hasPrefix("note:") == true }

    /// `about` of the general assistant: a Plan session that can do anything in Mindmill through its actions.
    public static let assistantAbout = "assistant"
    public var isAssistant: Bool { about == Self.assistantAbout }

    /// The most recent assistant session that isn't archived, in a scope when one is given.
    public static func latestAssistant(_ records: [SessionRecord], scope: String?) -> SessionRecord? {
        records.filter { $0.isAssistant && $0.archived != true && (scope == nil || $0.project == scope) }
            .max { $0.updated < $1.updated }
    }
}

public enum SessionSpace: String, Codable, Sendable {
    case plan, build
}

public enum SessionRole: String, Codable, Sendable, CaseIterable {
    case solo, overseer, lead, member
}

public enum SessionStore {
    /// Sessions older than this are dropped when the list is saved.
    public static let keepDays = 30
    public static let maxSessions = 60

    public static func load(from url: URL) -> [SessionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([SessionRecord].self, from: data)) ?? []).sorted { $0.updated > $1.updated }
    }

    public static func save(_ records: [SessionRecord], to url: URL, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        let research = records.filter { $0.keptWithItsEntry && !$0.messages.isEmpty }
        let rest = records.filter { !$0.keptWithItsEntry && ($0.updated >= cutoff || $0.role == .overseer) && (!$0.messages.isEmpty || $0.role == .overseer) }
            .sorted { $0.updated > $1.updated }
            .prefix(maxSessions)
        let kept = (research + rest).sorted { $0.updated > $1.updated }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Array(kept)).write(to: url, options: .atomic)
    }
}
