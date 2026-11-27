import Foundation

/// Which tool the user works with for mail, chat, calendar and documents, by `ClaudeConnectors.catalog` id. Kept in
/// `tools.json` in the knowledge base, where `kb tools` reads it for the skills, so a skill reaches the user's own
/// tools rather than whichever happens to be connected. Work tracking is per scope, in each scope's settings.
public struct UserTools: Equatable, Sendable {
    public static let file = "tools.json"
    public static let areas: [ClaudeConnectors.Area] = [.mail, .chat, .calendar, .docs]

    public var picked: [ClaudeConnectors.Area: [String]] = [:]

    public init(picked: [ClaudeConnectors.Area: [String]] = [:]) {
        self.picked = picked
    }

    /// The read-only connector tools of each area, which background syncs and sessions may use without asking.
    /// Which service a skill reads is the user's pick (`kb tools`); this only lets it read there.
    public static func readTools(_ area: ClaudeConnectors.Area) -> [String] {
        let m365 = "mcp__claude_ai_Microsoft_365__"
        let gmail = "mcp__claude_ai_Gmail__"
        let gcal = "mcp__claude_ai_Google_Calendar__"
        let slack = "mcp__claude_ai_Slack__"
        switch area {
        case .mail:
            return [m365 + "outlook_email_search", m365 + "read_resource",
                    gmail + "search_gmail_messages", gmail + "read_gmail_message", gmail + "read_gmail_thread"]
        case .calendar:
            return [m365 + "outlook_calendar_search", gcal + "list_gcal_events", gcal + "fetch_gcal_event", gcal + "list_gcal_calendars"]
        case .chat:
            return [m365 + "teams_list_chats", m365 + "chat_message_search", m365 + "teams_list_channel_messages", m365 + "read_resource",
                    slack + "slack_search_public_and_private", slack + "slack_read_channel", slack + "slack_read_thread"]
        case .docs, .work:
            return []
        }
    }

    /// The catalog's services for an area.
    public static func services(for area: ClaudeConnectors.Area) -> [ClaudeConnectors.Service] {
        ClaudeConnectors.catalog.filter { $0.areas.contains(area) }
    }

    /// Mail, chat and calendar are one tool each; documents can be several.
    public static func allowsSeveral(_ area: ClaudeConnectors.Area) -> Bool { area == .docs }

    public func tools(for area: ClaudeConnectors.Area) -> [String] { picked[area] ?? [] }

    public mutating func set(_ area: ClaudeConnectors.Area, _ ids: [String]) {
        let known = Set(Self.services(for: area).map(\.id))
        var clean: [String] = []
        for id in ids where known.contains(id) && !clean.contains(id) { clean.append(id) }
        if !Self.allowsSeveral(area) { clean = Array(clean.prefix(1)) }
        picked[area] = clean.isEmpty ? nil : clean
    }

    /// Tools picked in the setup fill the areas nothing is picked for yet.
    public mutating func adopt(_ serviceIDs: [String]) {
        for id in serviceIDs {
            guard let s = ClaudeConnectors.catalog.first(where: { $0.id == id }) else { continue }
            for area in s.areas where Self.areas.contains(area) {
                if picked[area] == nil { set(area, [id]) }
                else if Self.allowsSeveral(area) { set(area, tools(for: area) + [id]) }
            }
        }
    }

    public static func load(root: URL) -> UserTools {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(file)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return UserTools() }
        var t = UserTools()
        for area in areas {
            let v = json[area.rawValue]
            t.set(area, (v as? [String]) ?? (v as? String).map { [$0] } ?? [])
        }
        return t
    }

    public func save(root: URL) throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent(Self.file)),
           let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { json = old }
        for area in Self.areas { json[area.rawValue] = tools(for: area) }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent(Self.file), options: .atomic)
    }
}
