import Foundation
import KBCore
import KBEngine
import Network
import Security

/// The companion server's transport on the Mac: a TLS WebSocket listener from Network.framework, with the identity
/// `RemoteIdentity` keeps in Application Support. `RemoteServer` (KBEngine) does pairing and requests on top.
final class MacCompanionTransport: CompanionTransport {
    private let queue = DispatchQueue(label: "dk.langkilde.kb.remote")
    private var pathMonitor: NWPathMonitor?

    var machineName: String { Host.current().localizedName ?? "Mac" }

    @MainActor
    func listen(port: Int, folder: URL) throws -> CompanionListening {
        let id = try RemoteIdentity.load(folder: folder)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "KB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Port \(port) isn't a valid port."])
        }
        do {
            let l = try NWListener(using: RemoteIdentity.parameters(id), on: nwPort)
            return NWCompanionListener(l, port: port, fingerprint: id.fingerprint, queue: queue)
        } catch let e as NWError {
            throw NSError(domain: "KB", code: 2, userInfo: [NSLocalizedDescriptionKey: RemoteListenError.describe(e, port: port)])
        }
    }

    @MainActor
    func watchNetwork(_ changed: @escaping @MainActor (String, Bool) -> Void) {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let key = "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            let satisfied = path.status == .satisfied
            Task { @MainActor in changed(key, satisfied) }
        }
        m.start(queue: queue)
        pathMonitor = m
    }

    @MainActor
    func stopWatchingNetwork() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func addresses() async -> (addresses: [String], tailscaleName: String?) {
        await Task.detached {
            let ts = Self.findTailscaleName()
            var names: [String] = []
            if let ts { names.append(ts) }
            if let local = Host.current().name, local.hasSuffix(".local") { names.append(local) }
            return (RemoteAddresses.ordered(ips: RemoteAddresses.interfaceIPs(), names: names), ts)
        }.value
    }

    /// The Mac's MagicDNS name, when Tailscale runs.
    private static func findTailscaleName() -> String? {
        for path in ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["status", "--json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let me = obj["Self"] as? [String: Any], let dns = me["DNSName"] as? String, !dns.isEmpty else { continue }
            return dns.hasSuffix(".") ? String(dns.dropLast()) : dns
        }
        return nil
    }
}

@MainActor
final class NWCompanionListener: CompanionListening {
    let fingerprint: String
    var onState: ((CompanionListenerState) -> Void)?
    var onConnection: ((CompanionConnection) -> Void)?
    private let listener: NWListener
    private let port: Int
    private let queue: DispatchQueue

    init(_ listener: NWListener, port: Int, fingerprint: String, queue: DispatchQueue) {
        self.listener = listener
        self.port = port
        self.fingerprint = fingerprint
        self.queue = queue
    }

    func start() {
        let port = port
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.onState?(.ready)
                case .waiting(let e): self.onState?(.waiting(RemoteListenError.describe(e, port: port)))
                case .failed(let e): self.onState?(.failed(RemoteListenError.describe(e, port: port)))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                guard let self else {
                    conn.cancel()
                    return
                }
                self.onConnection?(NWCompanionConnection(conn, queue: self.queue))
            }
        }
        listener.start(queue: queue)
    }

    func cancel() {
        onState = nil
        onConnection = nil
        listener.cancel()
    }
}

/// One phone's WebSocket over TLS.
final class NWCompanionConnection: CompanionConnection, @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var onText: (@Sendable (String) -> Void)?
    private var onBinary: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start(onText: @escaping @Sendable (String) -> Void, onBinary: @escaping @Sendable (Data) -> Void,
               onClose: @escaping @Sendable () -> Void) {
        self.onText = onText
        self.onBinary = onBinary
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.onClose?()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                self.connection.cancel()
                return
            }
            if let data, let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text: self.onText?(String(decoding: data, as: UTF8.self))
                case .binary: self.onBinary?(data)
                case .close:
                    self.connection.cancel()
                    return
                default: break
                }
            }
            self.receive()
        }
    }

    func sendText(_ text: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func sendBinary(_ data: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close() { connection.cancel() }
}
