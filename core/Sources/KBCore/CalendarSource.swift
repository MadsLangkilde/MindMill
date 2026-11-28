import Foundation

/// The calendar the calendar sync mirrors as meeting files, read through one of Claude's connectors. Mindmill works
/// without one, so it stays none until the user picks one and nothing waits on a calendar they don't use.
public struct CalendarSource: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case none, microsoft365, google, other
    }

    public var kind: Kind
    /// The connector's name in `claude mcp list`, such as "claude.ai Microsoft 365".
    public var server: String

    public init(kind: Kind, server: String) {
        self.kind = kind
        self.server = server
    }

    public var id: String { kind == .other ? "other:\(server)" : kind.rawValue }

    public static let none = CalendarSource(kind: .none, server: "")
    public static let microsoft365 = CalendarSource(kind: .microsoft365, server: "claude.ai Microsoft 365")
    public static let google = CalendarSource(kind: .google, server: "claude.ai Google Calendar")

    public var isSet: Bool { kind != .none && !server.isEmpty }

    public var title: String {
        switch kind {
        case .none: return "No calendar"
        case .microsoft365: return "Outlook"
        case .google: return "Google Calendar"
        case .other: return ClaudeConnectors.Server(name: server, target: "", status: .unknown).displayName
        }
    }

    public var note: String {
        switch kind {
        case .none: return "Mindmill works without one: you add meetings yourself. You can pick a calendar any time in Settings → Connections."
        case .microsoft365: return "Outlook and Teams meetings, through Claude's Microsoft 365 connector."
        case .google: return "Through Claude's Google Calendar connector."
        case .other: return "Through the \(title) connector."
        }
    }

    /// Claude Code's prefix for a connector's tools: `mcp__` and its name with every character besides letters, digits,
    /// `_` and `-` as `_` ("claude.ai Microsoft 365" → `mcp__claude_ai_Microsoft_365`).
    public static func toolPrefix(_ server: String) -> String {
        "mcp__" + String(server.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
    }

    /// What a headless sync may call: the claude.ai Microsoft 365 connector's calendar search, else the connector's
    /// tools, of which the calendar skill only reads.
    public var tools: [String] {
        guard isSet else { return [] }
        let prefix = Self.toolPrefix(server)
        return server == Self.microsoft365.server ? [prefix + "__outlook_calendar_search"] : [prefix]
    }

    /// For the calendar skill: the connector to read and how to tell its tools.
    public var brief: String {
        guard isSet else { return "No calendar is connected to Mindmill." }
        return "Read the calendar from the `\(server)` connector (\(title)); its tools are named `\(Self.toolPrefix(server))__…`."
    }

    /// The connector as Claude lists it; nil when it isn't connected to Claude at all.
    public func server(in servers: [ClaudeConnectors.Server]) -> ClaudeConnectors.Server? {
        servers.first { $0.name == server }
    }

    /// The banner's problem once a sync was refused: signing in again when Claude lists the connector, adding it
    /// when `checked` found it missing.
    public func problem(in servers: [ClaudeConnectors.Server], checked: Bool) -> ClaudeConnectors.Problem {
        let service = ClaudeConnectors.Service(id: "calendar", title: title, areas: [.calendar], match: [], note: note)
        guard var listed = server(in: servers) else {
            return .init(service: service, server: .init(name: server, target: "", status: .needsAuth), missing: checked)
        }
        if listed.status == .connected || listed.status == .unknown { listed.status = .needsAuth }
        return .init(service: service, server: listed)
    }

    static let googleWords = ["google calendar", "gcal"]
    static let calendarWords = ["calendar", "caldav", "ical"]

    /// The calendars to offer: none, Outlook and Google Calendar (each with the connector Claude lists for it, or the
    /// name the claude.ai one gets), then other connectors. `anyServer` offers every other connector; otherwise only
    /// those whose name says calendar.
    public static func choices(servers: [ClaudeConnectors.Server], anyServer: Bool = false) -> [CalendarSource] {
        let google = servers.first { s in googleWords.contains { s.displayName.lowercased().contains($0) } }
        var out: [CalendarSource] = [.none, .microsoft365, google.map { CalendarSource(kind: .google, server: $0.name) } ?? .google]
        for s in ClaudeConnectors.others(servers) where anyServer || calendarWords.contains(where: { s.displayName.lowercased().contains($0) }) {
            out.append(CalendarSource(kind: .other, server: s.name))
        }
        return out
    }

    /// Before Mindmill asked, the calendar sync always read the claude.ai Microsoft 365 connector: whoever has it keeps
    /// it, and anyone else starts with none.
    public static func adopted(from servers: [ClaudeConnectors.Server]) -> CalendarSource {
        servers.contains { $0.name == microsoft365.server } ? .microsoft365 : .none
    }

    public static let key = "calendarSource"

    /// nil when the user hasn't chosen yet.
    public static func load(defaults: UserDefaults) -> CalendarSource? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CalendarSource.self, from: $0) }
    }

    public func save(defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
