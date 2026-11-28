import Foundation

/// The tools Claude can reach (its MCP servers and claude.ai connectors), from `claude mcp list`, and the services
/// KB knows how to use through them.
public enum ClaudeConnectors {
    public struct Server: Equatable, Sendable, Identifiable {
        public enum Status: String, Sendable { case connected, needsAuth, failed, unknown }

        public var name: String
        public var target: String
        public var status: Status

        public var id: String { name }

        public init(name: String, target: String, status: Status) {
            self.name = name
            self.target = target
            self.status = status
        }
        /// Added at claude.ai (Settings → Connectors) and shared with Claude Code through the account.
        public var fromClaudeAI: Bool { name.hasPrefix("claude.ai ") }
        /// Brought by a Claude Code plugin.
        public var fromPlugin: Bool { name.hasPrefix("plugin:") }
        public var displayName: String {
            if fromClaudeAI { return String(name.dropFirst("claude.ai ".count)) }
            if fromPlugin { return name.split(separator: ":").last.map(String.init) ?? name }
            return name
        }
    }

    /// `name: target [(HTTP)] - ✔ Connected` lines; anything else is skipped.
    public static func parse(_ output: String) -> [Server] {
        output.split(separator: "\n").compactMap { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard let colon = line.range(of: ": "), let dash = line.range(of: " - ", options: .backwards),
                  colon.upperBound <= dash.lowerBound else { return nil }
            let name = String(line[..<colon.lowerBound])
            var target = String(line[colon.upperBound..<dash.lowerBound])
            for suffix in [" (HTTP)", " (SSE)", " (stdio)"] where target.hasSuffix(suffix) { target.removeLast(suffix.count) }
            let tail = line[dash.upperBound...].lowercased()
            let status: Server.Status = tail.contains("connected") && !tail.contains("failed") ? .connected
                : tail.contains("auth") ? .needsAuth : tail.contains("fail") ? .failed : .unknown
            return Server(name: name, target: target, status: status)
        }
    }

    public enum Area: String, CaseIterable, Sendable {
        case work, mail, chat, calendar, docs

        public var title: String {
            switch self {
            case .work: return "Work tracking"
            case .mail: return "Mail"
            case .chat: return "Chat"
            case .calendar: return "Calendar"
            case .docs: return "Documents and design"
            }
        }
    }

    /// A service KB can use through Claude.
    public struct Service: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var areas: [Area]
        /// Lower-case words that identify its server in `claude mcp list`.
        public var match: [String]
        public var note: String
    }

    public static let catalog: [Service] = [
        Service(id: "jira", title: "Jira and Confluence", areas: [.work, .docs], match: ["atlassian", "jira", "confluence"],
                note: "Issues, sprints and boards in Jira; pages in Confluence. Add the Atlassian connector."),
        Service(id: "m365", title: "Microsoft 365", areas: [.mail, .calendar, .chat, .docs],
                match: ["microsoft 365", "microsoft365", "outlook", "teams", "sharepoint"],
                note: "Outlook mail and calendar, Teams chats and channels, SharePoint and OneDrive."),
        Service(id: "google", title: "Gmail and Google Calendar", areas: [.mail, .calendar, .docs],
                match: ["gmail", "google calendar", "google drive", "google"],
                note: "Mail, calendar and Drive in Google Workspace."),
        Service(id: "slack", title: "Slack", areas: [.chat], match: ["slack"], note: "Channels and direct messages."),
        Service(id: "github", title: "GitHub", areas: [.work], match: ["github"], note: "Issues and pull requests on GitHub."),
        Service(id: "linear", title: "Linear", areas: [.work], match: ["linear"], note: "Issues and cycles in Linear."),
        Service(id: "figma", title: "Figma", areas: [.docs], match: ["figma"], note: "Designs to read and link."),
    ]

    /// The servers that provide a service.
    public static func servers(for service: Service, in servers: [Server]) -> [Server] {
        servers.filter { s in
            let n = s.displayName.lowercased()
            return service.match.contains { n.contains($0) }
        }
    }

    /// Servers no catalog service accounts for.
    public static func others(_ servers: [Server]) -> [Server] {
        servers.filter { s in !catalog.contains { !Self.servers(for: $0, in: [s]).isEmpty } }
    }

    /// A name `claude mcp add` accepts: letters, digits, dashes and underscores.
    public static func safeName(_ raw: String) -> String {
        let mapped = raw.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }
}

/// Telling from a failed sync's reply that the connector needs signing in again, even when Claude Code still lists
/// it as connected: Microsoft refused the existing sign-in, so its tools are missing.
public enum ConnectorSignIn {
    static let phrases = ["needs to sign in", "need to sign in", "needs sign-in", "needs-auth", "authenticate",
                          "no such tool available", "was refused", "not authorized", "sign in again", "/mcp",
                          "tool is missing", "tool isn't available", "tool is not available", "not connected",
                          "unauthorized", "401"]

    public static func isNeeded(_ text: String) -> Bool {
        let t = text.lowercased()
        return phrases.contains { t.contains($0) }
    }
}

extension ClaudeConnectors {
    /// A tool KB uses that Claude can't reach now, and what to do about it.
    public struct Problem: Equatable, Sendable, Identifiable {
        public var service: Service
        public var server: Server
        /// Claude doesn't list the server at all.
        public var missing: Bool
        public var id: String { server.name }

        public init(service: Service, server: Server, missing: Bool = false) {
            self.service = service
            self.server = server
            self.missing = missing
        }

        public var headline: String {
            missing ? "\(service.title) isn't connected to Claude"
                : server.status == .needsAuth ? "\(service.title) needs signing in" : "\(service.title) isn't working"
        }

        /// Why it happens and the fix, in a sentence or two.
        public var advice: String {
            if missing {
                return "Add it at claude.ai → Settings → Connectors, or choose another calendar, or none, in Settings → Connections."
            }
            switch (server.status, server.fromClaudeAI) {
            case (.needsAuth, true):
                return "Its sign-in expired or was revoked, which a password change does. Reconnect it at claude.ai → Settings → Connectors, sign in, then come back here."
            case (.needsAuth, false):
                return "Its sign-in expired or was revoked. Sign in again in Claude Code's /mcp (Sign In opens it in Terminal)."
            case (_, true):
                return "Claude couldn't reach it. Check it at claude.ai → Settings → Connectors, or try again in a minute."
            default:
                return "Claude couldn't start or reach it. Sign In opens Claude Code's /mcp in Terminal, where its error shows."
            }
        }
    }

    /// The catalog's tools that have a server Claude knows but can't use: signed out, or failing. A service with
    /// one working server isn't a problem.
    public static func problems(_ servers: [Server]) -> [Problem] {
        catalog.compactMap { service in
            let found = Self.servers(for: service, in: servers)
            guard !found.isEmpty, !found.contains(where: { $0.status == .connected }),
                  let bad = found.first(where: { $0.status == .needsAuth }) ?? found.first(where: { $0.status == .failed })
            else { return nil }
            return Problem(service: service, server: bad)
        }
    }
}
