import Foundation

/// What a `ClaudeSession` reports.
public enum ClaudeEvent: Equatable, Sendable {
    /// From the `init` line; carries the session id Claude is using.
    case sessionStarted(String)
    /// From the `init` line: each MCP server's status (`connected`, `needs-auth`, `failed`, `pending`).
    case connectors([String: String])
    /// A queued message was written to Claude; `tag` is what the caller passed to `send`.
    case turnStarted(tag: String?)
    case assistantText(String)
    /// A piece of the reply as it is written; only with `partialMessages`.
    case textDelta(String)
    case toolUse(String)
    /// What a tool call does, in a line: the shell command, the file, the skill.
    case toolDetail(name: String, summary: String)
    /// From the `init` line: the slash commands (skills and commands) this session knows.
    case commands([String])
    /// Tool calls the permission settings refused during the turn, as `Tool(detail)`.
    case denied([String])
    /// The end of a turn. `text` is the turn's reply.
    case turnResult(text: String, isError: Bool, tag: String?)
    case error(String)
    case exited(Int32)
}

/// One line of `--output-format stream-json`, reduced to what the app uses.
public enum ClaudeStreamLine: Equatable, Sendable {
    case initialized(sessionID: String)
    case connectors([String: String])
    case text(String)
    case textDelta(String)
    case toolUse(String)
    case toolDetail(name: String, summary: String)
    case commands([String])
    case denied([String])
    case result(text: String, isError: Bool)

    /// Parses one stdout line. Lines the app ignores (hooks, rate limits, tool results) give `[]`.
    public static func parse(_ line: String) -> [ClaudeStreamLine] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else { return [] }
        switch type {
        case "system":
            guard json["subtype"] as? String == "init", let id = json["session_id"] as? String else { return [] }
            var status: [String: String] = [:]
            for server in json["mcp_servers"] as? [[String: Any]] ?? [] {
                if let name = server["name"] as? String, let s = server["status"] as? String { status[name] = s }
            }
            var out: [ClaudeStreamLine] = [.initialized(sessionID: id)]
            if !status.isEmpty { out.append(.connectors(status)) }
            if let commands = json["slash_commands"] as? [String], !commands.isEmpty { out.append(.commands(commands)) }
            return out
        case "assistant":
            let message = json["message"] as? [String: Any]
            let content = message?["content"] as? [[String: Any]] ?? []
            return content.flatMap { block -> [ClaudeStreamLine] in
                switch block["type"] as? String {
                case "text":
                    let t = block["text"] as? String ?? ""
                    return t.isEmpty ? [] : [.text(t)]
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let summary = ToolSummary.line(name: name, input: block["input"] as? [String: Any] ?? [:])
                    return summary.isEmpty ? [.toolUse(name)] : [.toolUse(name), .toolDetail(name: name, summary: summary)]
                default:
                    return []
                }
            }
        case "stream_event":
            guard let event = json["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let t = delta["text"] as? String, !t.isEmpty else { return [] }
            return [.textDelta(t)]
        case "result":
            let subtype = json["subtype"] as? String ?? ""
            let isError = (json["is_error"] as? Bool ?? false) || subtype != "success"
            var text = json["result"] as? String ?? ""
            if text.isEmpty, isError {
                text = (json["errors"] as? [String])?.joined(separator: "\n") ?? subtype
            }
            let denials = (json["permission_denials"] as? [[String: Any]] ?? []).map { d -> String in
                let name = d["tool_name"] as? String ?? "tool"
                let detail = ToolSummary.line(name: name, input: d["tool_input"] as? [String: Any] ?? [:])
                    .components(separatedBy: "\t").last ?? ""
                return detail.isEmpty ? name : "\(name)(\(detail))"
            }
            return denials.isEmpty ? [.result(text: text, isError: isError)] : [.denied(denials), .result(text: text, isError: isError)]
        default:
            return []
        }
    }

    /// One stdin line: asks Claude to stop the turn under way, as Esc does in the terminal.
    public static func interrupt(id: String) -> String {
        let obj: [String: Any] = ["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// One stdin line: a user message, with any images in front of its text.
    public static func userMessage(_ text: String, images: [ImageBlock] = []) -> String {
        let pictures: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.base64]]
        }
        let obj: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": pictures + [["type": "text", "text": text]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// Splits a byte stream into lines.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<nl]
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }

    public mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// One readable line for a tool call's input.
public enum ToolSummary {
    public static func line(name: String, input: [String: Any]) -> String {
        func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let raw: String
        switch name {
        case "Bash": raw = str("command") ?? ""
        case "Read", "Write", "Edit", "NotebookEdit": raw = str("file_path").map { ($0 as NSString).lastPathComponent } ?? ""
        case "Grep", "Glob": raw = str("pattern") ?? ""
        case "Skill": raw = [str("skill"), str("args")].compactMap { $0 }.joined(separator: " ")
        case "WebFetch": raw = str("url") ?? ""
        case "WebSearch": raw = str("query") ?? ""
        case "Agent", "Task": raw = str("description") ?? ""
        default: raw = str("query") ?? str("description") ?? ""
        }
        let line = oneLine(raw)
        // A command keeps its own description and its full text, after tabs: "<description>\t<command>".
        if name == "Bash", let command = str("command") {
            let desc = (str("description") ?? "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            let code = command.count > 1500 ? String(command.prefix(1500)) + "\n…" : command
            return desc.isEmpty ? line + "\t" + code : desc + "\t" + code
        }
        return line
    }

    static func oneLine(_ raw: String) -> String {
        let one = raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return one.count > 160 ? String(one.prefix(157)) + "…" : one
    }
}

/// A tool step in words: "Read MeetingWindow.swift", "Messaged a session", "Ran the unit tests". The command
/// itself, when there is one, is shown apart as code.
public enum ToolDescription {
    public struct Step: Equatable, Sendable {
        public let title: String
        public let code: String?
    }

    /// `text` is a transcript tool line: `<tool>\t<summary>[\t<command>]`.
    public static func step(_ text: String) -> Step {
        let parts = text.components(separatedBy: "\t")
        let name = parts.first ?? ""
        let summary = parts.count > 1 ? parts[1] : ""
        let code = parts.count > 2 ? parts[2...].joined(separator: "\t") : nil
        if name == "Bash" {
            let command = code ?? summary
            // Claude's own description is the title; without one, the command says what it does.
            let described = code != nil && summary != ToolSummary.oneLine(command)
            return Step(title: described ? summary : bash(command), code: command)
        }
        return Step(title: describe(name, summary), code: nil)
    }

    static func describe(_ name: String, _ s: String) -> String {
        switch name {
        case "Read": return s.isEmpty ? "Read a file" : "Read \(s)"
        case "Write": return s.isEmpty ? "Wrote a file" : "Wrote \(s)"
        case "Edit", "MultiEdit", "NotebookEdit": return s.isEmpty ? "Edited a file" : "Edited \(s)"
        case "Grep": return s.isEmpty ? "Searched the code" : "Searched the code for “\(s)”"
        case "Glob": return s.isEmpty ? "Looked for files" : "Looked for files: \(s)"
        case "WebFetch": return "Read \(URL(string: s)?.host ?? "a web page")"
        case "WebSearch": return s.isEmpty ? "Searched the web" : "Searched the web for “\(s)”"
        case "Agent", "Task": return s.isEmpty ? "Asked a helper" : "Helper: \(s)"
        case "Skill": return s.isEmpty ? "Used a skill" : "Used the \(s.split(separator: " ").first.map(String.init) ?? s) skill"
        case "TodoWrite": return "Updated its to-do list"
        case "ToolSearch": return "Loaded tools"
        default:
            if name.hasPrefix("mcp__") {
                let bits = name.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
                let server = bits.dropFirst().first ?? "a connector"
                let tool = bits.dropFirst(2).joined(separator: " ")
                return "\(server): \(tool)\(s.isEmpty ? "" : " “\(s)”")"
            }
            return s.isEmpty ? name : "\(name): \(s)"
        }
    }

    static func quoted(_ command: String) -> String? {
        guard let a = command.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let q = command[a]
        let rest = command[command.index(after: a)...]
        guard let b = rest.firstIndex(of: q) else { return String(rest.prefix(80)) }
        return String(rest[..<b])
    }

    /// The first command of a shell line, in words.
    static func bash(_ command: String) -> String {
        // The first part that isn't a `cd`.
        let segments = command.components(separatedBy: "&&").flatMap { $0.components(separatedBy: ";") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let c = segments.first { !$0.isEmpty && !$0.hasPrefix("cd ") } ?? command
        let words = c.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let tool = (words.first ?? "").split(separator: "/").last.map(String.init) ?? ""
        let sub = words.count > 1 ? words[1] : ""
        let third = words.count > 2 ? words[2] : ""
        switch tool {
        case "kb":
            switch (sub, third) {
            case ("crew", "send"): return "Messaged a session" + (quoted(c).map { ": “\(String($0.prefix(70)))\($0.count > 70 ? "…" : "")”" } ?? "")
            case ("crew", "status"): return "Checked the sessions"
            case ("crew", "start"): return "Started a session"
            case ("crew", "stop"): return "Stopped a session"
            case ("show", _): return "Read \(third.isEmpty ? "an entry" : third) in the knowledge base"
            case ("search", _): return "Searched the knowledge base" + (quoted(c).map { " for “\($0)”" } ?? "")
            case ("list", _): return "Listed the knowledge base"
            case ("new", _): return "Wrote a new \(third.isEmpty ? "entry" : third)"
            case ("inbox", _): return third == "add" ? "Proposed it in the inbox" : "Worked on the inbox"
            case ("tracker", _): return "Looked in Azure DevOps" + (quoted(c).map { " for “\($0)”" } ?? "")
            case ("backlog", "create"): return "Created the work item"
            case ("followup", _): return "Closed a follow-up"
            default: return "Used the knowledge base (\(sub))"
            }
        case "git":
            switch sub {
            case "status": return "Checked what changed"
            case "diff": return "Looked at the changes"
            case "log", "show": return "Read the history"
            case "worktree": return "Set up a worktree"
            case "commit": return "Committed"
            case "push": return "Pushed"
            case "fetch", "pull": return "Fetched from the server"
            case "checkout", "switch": return "Switched branch"
            case "branch": return "Looked at branches"
            default: return "Git: \(sub)"
            }
        case "gradlew":
            let tasks = words.dropFirst().filter { !$0.hasPrefix("-") }
            if tasks.contains(where: { $0.contains("test") || $0.contains("Test") }) { return "Ran the tests" }
            if tasks.contains(where: { $0.lowercased().contains("assemble") || $0 == "build" }) { return "Built the app" }
            return "Ran Gradle" + (tasks.isEmpty ? "" : ": " + tasks.prefix(3).joined(separator: ", "))
        case "swift": return sub == "test" ? "Ran the tests" : "Built with Swift"
        case "grep", "rg": return "Searched the code" + (quoted(c).map { " for “\($0)”" } ?? "")
        case "cat", "head", "tail", "sed", "less": return "Read \(words.last.map { ($0 as NSString).lastPathComponent } ?? "a file")"
        case "ls", "find", "tree": return "Listed files"
        case "gh", "az": return "Called \(tool == "gh" ? "GitHub" : "Azure DevOps")"
        case "curl": return "Called a web service"
        case "adb": return "Talked to the phone"
        case "python3", "python": return "Ran a script"
        case "mkdir", "cp", "mv", "rm": return "Moved files around"
        default: return tool.isEmpty ? "Ran a command" : "Ran \(tool)"
        }
    }
}
