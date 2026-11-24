import Foundation
import KBCore
import KBEngine
import Network

/// Serves the action layer as an MCP server on 127.0.0.1, for Claude Code sessions this app starts (the voice
/// brain). Only this Mac can reach it, and every request needs the token made at launch.
@MainActor
final class LocalActionServer {
    private(set) var port: Int?
    let token = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private let mcp: MCPActions

    init(layer: ActionLayer) {
        mcp = MCPActions(layer: layer, channel: .model)
    }

    /// The `--mcp-config` for a session, once the server listens.
    var mcpConfig: String? { port.map { MCPActions.config(port: $0, token: token) } }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.acceptLocalOnly = true
        guard let l = try? NWListener(using: params) else { return }
        listener = l
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.port = l.port.map { Int($0.rawValue) }
                case .failed, .cancelled: self.listener = nil; self.port = nil
                default: break
                }
            }
        }
        l.newConnectionHandler = { [weak self] c in
            Task { @MainActor in self?.serve(c) }
        }
        l.start(queue: .main)
    }

    /// Waits up to a second for the port, so a session started right after launch still gets the tools.
    func ready() async -> String? {
        start()
        for _ in 0..<20 where port == nil { try? await Task.sleep(for: .milliseconds(50)) }
        return mcpConfig
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer + (data ?? Data())
                while let request = HTTPRequest.take(from: &buffer) {
                    let reply = await self.respond(request)
                    c.send(content: reply, completion: .contentProcessed { _ in })
                }
                if done || error != nil || buffer.count > 8 << 20 { c.cancel(); return }
                self.receive(c, buffer: buffer)
            }
        }
    }

    private func respond(_ r: HTTPRequest) async -> Data {
        await MCPHTTP.respond(r, token: token, mcp: mcp)
    }
}

extension LocalActionServer: ActionEndpoint {
    func mcpConfig() async -> String? { await ready() }
}
