import Foundation

/// The MCP side of the action layer: JSON-RPC requests from a Claude Code session (over Streamable HTTP on
/// localhost) become action runs, so the voice brain uses the same actions as the UI and the phone.
@MainActor
public struct MCPActions {
    public static let serverName = "mindmill"
    public static let protocolVersion = "2025-06-18"

    public let layer: ActionLayer
    public let channel: ActionChannel

    public init(layer: ActionLayer, channel: ActionChannel = .model) {
        self.layer = layer
        self.channel = channel
    }

    /// The reply to one JSON-RPC message; nil for notifications, which get none.
    public func handle(_ message: JSONValue) async -> JSONValue? {
        guard let method = message["method"]?.string else { return nil }
        guard let id = message["id"], id != .null else { return nil }
        let params = message["params"] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? Self.protocolVersion
            return Self.result(id, [
                "protocolVersion": .string(asked),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(Self.serverName), "version": "1"],
            ])
        case "ping":
            return Self.result(id, [:])
        case "tools/list":
            return Self.result(id, ["tools": .array(layer.toolDefinitions + [ActionTools.confirm, ActionTools.cancel, ActionTools.find, ActionTools.run])])
        case "tools/call":
            guard let name = params["name"]?.string else { return Self.error(id, -32602, "No tool name") }
            let args = params["arguments"] ?? [:]
            let outcome = await layer.callTool(name, args, channel: channel)
            var isError = false
            if case .failed = outcome { isError = true }
            return Self.result(id, ["content": [["type": "text", "text": .string(outcome.text)]], "isError": .bool(isError)])
        default:
            return Self.error(id, -32601, "Unknown method \(method)")
        }
    }

    static func result(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    /// The `--mcp-config` for a session that should reach this Mac's actions.
    public static func config(port: Int, token: String) -> String {
        let obj: [String: Any] = ["mcpServers": [serverName: [
            "type": "http", "url": "http://127.0.0.1:\(port)/mcp", "headers": ["Authorization": "Bearer \(token)"],
        ]]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The tool names to allow for such a session.
    public static var allowedTools: [String] { ["mcp__\(serverName)"] }
}

/// A minimal HTTP/1.1 request reader for the localhost MCP endpoint.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Takes one complete request off the front of `buffer`; nil until all of it has arrived.
    public static func take(from buffer: inout Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
    }

    public static func response(status: Int, reason: String, body: Data = Data(), contentType: String = "application/json") -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: \(contentType)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}
