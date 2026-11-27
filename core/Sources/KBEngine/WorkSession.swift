import Foundation
import KBCore
import Observation

/// One Claude session: a task the user works on with Claude (Plan) or an implementation session with its crew
/// (Build). What a window shows of it (the input box, offers on screen) is the host's; this is the session itself.
@MainActor
@Observable
public final class WorkSession: Identifiable {
    nonisolated public let id: String
    public var title: String
    public let project: String?
    public let workingDirectory: URL
    public var claudeSessionID: String?
    public var extraTools: [String]
    public let created: Date
    public var updated: Date
    public let chat = ClaudeChat()
    /// Context from "Work on it with Claude", sent with the first message and shown as a chip until then.
    public var subject: AskSubject?
    public var role: SessionRole
    public var parentID: String?
    public var strategy: String?
    public var model: String?
    public var about: String?
    public var strategyOffered: Bool
    public var space: SessionSpace
    public var archived: Bool?
    public var researchOffered: Bool
    /// What the user asked for when starting it, pinned at the top of the session instead of shown as a message.
    public var brief: String?
    /// Separate copies of the code it said it works in, newest last.
    public var folders: [String] = []
    /// Started with Quick Start: unlisted and not kept until something is written in it.
    public var quickDraft = false
    public var isEmptyDraft: Bool { quickDraft && chat.items.isEmpty && !chat.isBusy }
    /// Messages from other sessions that arrived during a turn; each is sent when the turn ends.
    public var inbox: [(text: String, display: String)] = []
    /// How to work (a strategy, sessions to start), sent in front of the first message.
    public var pendingSetup: String?
    /// A message the user took back after Claude had read it; the next message says so.
    public var withdrawn: String?
    /// When the current state began, for "working 3m" in the overview.
    public var stateSince = Date()
    @ObservationIgnored public var createdItemsCache: (count: Int, ids: [Int]) = (-1, [])
    /// Archived during its turn: the process stops once the turn ends.
    public var stopAfterTurn = false
    /// The reply that ended with a bare question the engine already asked the session to put as options.
    @ObservationIgnored var openQuestionAsked: UUID?

    public init(record: SessionRecord) {
        id = record.id
        title = record.title
        project = record.project
        workingDirectory = URL(fileURLWithPath: record.workingDirectory)
        claudeSessionID = record.claudeSessionID
        extraTools = record.extraTools
        created = record.created
        updated = record.updated
        role = record.role
        parentID = record.parentID
        strategy = record.strategy
        model = record.model
        about = record.about
        strategyOffered = record.strategyOffered
        space = record.space
        archived = record.archived
        researchOffered = record.researchOffered ?? false
        brief = record.brief
        folders = record.folders ?? []
        chat.showsTools = true
        chat.items = record.messages.map {
            ClaudeChat.Item(role: ClaudeChat.Role(rawValue: $0.role) ?? .status, text: $0.text, attachments: $0.attachments ?? [], at: $0.at)
        }
    }

    public var record: SessionRecord {
        SessionRecord(id: id, title: title, project: project, claudeSessionID: claudeSessionID,
                      workingDirectory: workingDirectory.path, created: created, updated: updated, extraTools: extraTools,
                      messages: chat.items.filter { $0.role != .status }.map { .init(role: $0.role.rawValue, text: $0.text, attachments: $0.attachments.isEmpty ? nil : $0.attachments, at: $0.at) },
                      role: role, parentID: parentID, strategy: strategy, model: model, about: about,
                      strategyOffered: strategyOffered, space: space, archived: archived,
                      researchOffered: researchOffered ? true : nil, brief: brief,
                      folders: folders.isEmpty ? nil : folders)
    }

    /// The last assistant message, when the conversation is waiting on the user.
    public var waitingChoices: (itemID: UUID, multi: Bool, options: [String])? {
        guard !chat.isBusy, let last = chat.items.last(where: { $0.role != .tool && $0.role != .status }),
              last.role == .assistant, let c = MarkdownBlocks.trailingChoices(last.text) else { return nil }
        return (last.id, c.multi, c.options)
    }

    /// What the overview shows: working, waiting on the user, refused a tool, idle or not running.
    public var crewState: CrewSessionState {
        if chat.isBusy { return .working }
        if !chat.denials.isEmpty { return .blocked }
        if let last = chat.items.last(where: { $0.role == .assistant || $0.role == .user }), last.role == .assistant {
            if OpenQuestion.waitsOnUser(last.text) { return .waiting }
        }
        return chat.isRunning ? .idle : .stopped
    }

    /// The start of the last reply, one line.
    public var lastReply: String {
        guard let last = chat.items.last(where: { $0.role == .assistant }) else { return "" }
        let blocks = MarkdownBlocks.parse(last.text)
        for b in blocks.reversed() {
            switch b {
            case .paragraph(let t), .heading(_, let t), .quote(let t): return Self.plain(t)
            case .listItem(_, _, _, let t): return Self.plain(t)
            default: continue
            }
        }
        return Self.plain(last.text)
    }

    private static func plain(_ t: String) -> String {
        t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    public var isLead: Bool { role == .lead }

    /// The general assistant: a Plan session with every Mindmill action as a tool.
    public var isAssistant: Bool { about == SessionRecord.assistantAbout }

    /// The work items this session created, worked out again only when the conversation grows.
    public var createdItems: [Int] {
        if createdItemsCache.count == chat.items.count { return createdItemsCache.ids }
        let ids = PlanSessions.createdItems(chat.items.filter { $0.role != .user }.map(\.text))
        createdItemsCache = (chat.items.count, ids)
        return ids
    }

    public var isResearchSession: Bool { about?.hasPrefix("research:") == true }

    public var planKind: PlanSessionKind {
        PlanSessions.kind(title: title, about: about, firstMessage: chat.items.first { $0.role == .user }?.text ?? "")
    }

    public func matches(_ query: String) -> Bool {
        KBSearch.matches(query, in: [title, about ?? "", project ?? "", strategy ?? "", subject?.title ?? ""]
            .joined(separator: "\n").lowercased())
    }

    /// Whether the session changed files: an Edit or Write tool ran.
    public var editedFiles: Bool {
        chat.items.contains { $0.role == .tool && ($0.text.hasPrefix("Edit\t") || $0.text.hasPrefix("Write\t") || $0.text.hasPrefix("MultiEdit\t")) }
    }
}
