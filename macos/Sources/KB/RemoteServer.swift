import Foundation
import KBCore
import Network
import Security

/// One phone's connection: a WebSocket over TLS. It must say hello with its token, or pair with the code, before
/// anything else.
final class RemoteClient: @unchecked Sendable {
    let connection: NWConnection
    /// Set once the phone proved who it is.
    var deviceID: String?
    var deviceName = ""
    var onText: ((RemoteClient, String) -> Void)?
    var onBinary: ((RemoteClient, Data) -> Void)?
    var onClose: ((RemoteClient) -> Void)?

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled: self.onClose?(self)
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
                case .text: self.onText?(self, String(decoding: data, as: UTF8.self))
                case .binary: self.onBinary?(self, data)
                case .close:
                    self.connection.cancel()
                    return
                default: break
                }
            }
            self.receive()
        }
    }

    func send(_ message: RemoteMessage) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(content: Data(message.encoded().utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func sendBinary(_ data: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close() { connection.cancel() }
}

/// Remote access: the Mac listens for paired phones on the local network and Tailscale, answers their requests
/// through `RemoteAPI` and pushes events about what changes. When the listener fails (port in use, no network) it
/// tries again by itself, less often each time, and at once when the network changes.
@MainActor
@Observable
final class RemoteServer {
    static let enabledKey = "remoteEnabled"
    static let portKey = "remotePort"
    static let defaultPort = 7878
    /// Wrong codes a pairing code takes before it stops working.
    static let maxPairingAttempts = 5

    enum PairingOutcome: Equatable {
        case paired(name: String)
        case failed(String)
    }

    private(set) var status: RemoteServerStatus = .off
    private(set) var fingerprint = ""
    var devices = RemoteDevices()
    /// Shown while a phone may pair.
    var pairing: PairingCode? {
        didSet { if pairing != nil { pairingOutcome = nil; wrongAttempts = 0 } }
    }
    /// How the last pairing ended, until a new code is shown or it is dismissed.
    var pairingOutcome: PairingOutcome?
    private(set) var wrongAttempts = 0
    /// Phones connected and signed in now, by device id.
    private(set) var connected: [String: String] = [:]
    /// Every address a phone may reach this Mac on, read when it starts and when the network changes.
    private(set) var addresses: [String] = []
    private(set) var tailscaleName: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var clients: [ObjectIdentifier: RemoteClient] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "dk.langkilde.kb.remote")
    @ObservationIgnored private var retry = RemoteRetry()
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPath: String?
    @ObservationIgnored var handle: ((RemoteClient, String, JSONValue) async throws -> JSONValue)?
    @ObservationIgnored var handleBinary: ((RemoteClient, Data) -> Void)?
    /// A phone's connection closed; whatever it had running (a voice conversation) can end.
    @ObservationIgnored var onClientClosed: ((RemoteClient) -> Void)?

    var isRunning: Bool { status.isRunning }
    var error: String? { status.reason }

    var port: Int {
        let p = UserDefaults.standard.integer(forKey: Self.portKey)
        return p > 0 && p < 65536 ? p : Self.defaultPort
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KB/remote")
    }

    private var devicesURL: URL { Self.folder.appendingPathComponent("devices.json") }

    init() {
        if let data = try? Data(contentsOf: devicesURL), let d = try? JSONDecoder().decode(RemoteDevices.self, from: data) { devices = d }
    }

    func saveDevices() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(devices) { try? data.write(to: devicesURL, options: .atomic) }
    }

    func start() {
        guard listener == nil else { return }
        retryTask?.cancel()
        retryTask = nil
        status = .starting
        watchNetwork()
        refreshAddresses()
        do {
            let id = try RemoteIdentity.load(folder: Self.folder)
            fingerprint = id.fingerprint
            let port = port
            let l = try NWListener(using: RemoteIdentity.parameters(id), on: NWEndpoint.Port(rawValue: UInt16(port))!)
            l.stateUpdateHandler = { [weak self, weak l] state in
                Task { @MainActor in
                    guard let self, let l, self.listener === l else { return }
                    switch state {
                    case .ready:
                        self.status = .running(port: port)
                        self.retry.reset()
                    case .waiting(let e):
                        self.status = .waiting(reason: RemoteListenError.describe(e, port: port))
                    case .failed(let e):
                        self.failed(RemoteListenError.describe(e, port: port))
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.start(queue: queue)
            listener = l
        } catch let e as NWError {
            failed(RemoteListenError.describe(e, port: port))
        } catch {
            failed(error.localizedDescription)
        }
    }

    /// Stops listening and tries again later, unless remote access was turned off meanwhile.
    private func failed(_ reason: String) {
        closeListener()
        let delay = retry.next()
        status = .failed(reason: reason, retryAt: Date().addingTimeInterval(delay))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, UserDefaults.standard.bool(forKey: Self.enabledKey), self.listener == nil else { return }
            self.start()
        }
    }

    /// Starts again now: the Retry and Restart buttons.
    func restart() {
        retryTask?.cancel()
        retryTask = nil
        retry.reset()
        closeListener()
        start()
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        retry.reset()
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPath = nil
        closeListener()
        pairing = nil
        status = .off
    }

    private func closeListener() {
        listener?.cancel()
        listener = nil
        for c in clients.values { c.close() }
        clients = [:]
        connected = [:]
    }

    /// A network change: new addresses for the QR code, and the listener starts again at once.
    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let key = "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor in self?.networkChanged(key, satisfied: path.status == .satisfied) }
        }
        m.start(queue: queue)
        pathMonitor = m
    }

    private func networkChanged(_ key: String, satisfied: Bool) {
        guard key != lastPath else { return }
        let first = lastPath == nil
        lastPath = key
        guard !first else { return }
        refreshAddresses()
        switch status {
        case .failed, .waiting:
            if satisfied { restart() }
        case .running:
            // A listener can stay "ready" on an interface that went away; start afresh while no phone would drop.
            if satisfied, connected.isEmpty { restart() }
        default: break
        }
    }

    func refreshAddresses() {
        Task.detached {
            let ts = Self.findTailscaleName()
            var names: [String] = []
            if let ts { names.append(ts) }
            if let local = Host.current().name, local.hasSuffix(".local") { names.append(local) }
            let list = RemoteAddresses.ordered(ips: RemoteAddresses.interfaceIPs(), names: names)
            await MainActor.run { [weak self] in
                self?.tailscaleName = ts
                self?.addresses = list
            }
        }
    }

    private func accept(_ conn: NWConnection) {
        let client = RemoteClient(conn)
        client.onText = { [weak self] c, text in Task { @MainActor in self?.received(text, from: c) } }
        client.onBinary = { [weak self] c, data in Task { @MainActor in
            guard let self, c.deviceID != nil else { return }
            self.handleBinary?(c, data)
        } }
        client.onClose = { [weak self] c in Task { @MainActor in
            guard let self else { return }
            self.clients[ObjectIdentifier(c)] = nil
            if let id = c.deviceID {
                if !self.clients.values.contains(where: { $0.deviceID == id }) { self.connected[id] = nil }
                self.devices.seen(id)
                self.saveDevices()
            }
            self.onClientClosed?(c)
        } }
        clients[ObjectIdentifier(client)] = client
        client.start(queue: queue)
    }

    private func received(_ text: String, from client: RemoteClient) {
        guard case .request(let id, let method, let params) = RemoteMessage.decode(text) else { return }
        if method == "pair" {
            pair(id: id, params: params, client: client)
            return
        }
        if method == "hello" {
            guard let device = devices.device(token: params["token"]?.string ?? "") else {
                client.send(.failure(id: id, code: "unauthorized", message: "This phone isn't paired with this Mac any more. Pair it again."))
                return
            }
            client.deviceID = device.id
            client.deviceName = device.name
            devices.seen(device.id)
            saveDevices()
            connected[device.id] = device.name
        } else if client.deviceID == nil {
            client.send(.failure(id: id, code: "unauthorized", message: "Say hello with the device token first."))
            return
        }
        Task {
            do {
                let result = try await handle?(client, method, params) ?? .null
                client.send(.response(id: id, result: result))
            } catch let e as RemoteError {
                client.send(.failure(id: id, code: e.code, message: e.message))
            } catch {
                client.send(.failure(id: id, code: "failed", message: error.localizedDescription))
            }
        }
    }

    private func pair(id: String, params: JSONValue, client: RemoteClient) {
        let attempt = params["code"]?.string ?? ""
        guard let code = pairing else {
            client.send(.failure(id: id, code: "bad_code", message: "This Mac isn't showing a pairing code. Show one in Mindmill → Settings → Remote."))
            return
        }
        guard code.accepts(attempt) else {
            let expired = Date() >= code.expires
            wrongAttempts += 1
            let message: String
            if expired {
                message = "That pairing code has expired. Show a new one on the Mac."
                pairing = nil
                pairingOutcome = .failed("The code expired before the phone used it.")
            } else if wrongAttempts >= Self.maxPairingAttempts {
                message = "Too many wrong codes. Show a new one on the Mac."
                pairing = nil
                pairingOutcome = .failed("A phone tried \(Self.maxPairingAttempts) wrong codes, so this one stopped working.")
            } else {
                message = "That pairing code is wrong. Check the code on the Mac."
            }
            client.send(.failure(id: id, code: "bad_code", message: message))
            return
        }
        let (device, token) = devices.pair(name: params["name"]?.string ?? "Phone")
        pairing = nil
        pairingOutcome = .paired(name: device.name)
        saveDevices()
        client.deviceID = device.id
        client.deviceName = device.name
        connected[device.id] = device.name
        client.send(.response(id: id, result: ["token": .string(token), "device": .string(device.id)]))
    }

    /// Sends an event to every signed-in phone.
    func broadcast(_ name: String, _ data: JSONValue = .object([:])) {
        for c in clients.values where c.deviceID != nil { c.send(.event(name: name, data: data)) }
    }

    func revoke(_ id: String) {
        devices.remove(id)
        saveDevices()
        for c in clients.values where c.deviceID == id { c.close() }
        connected[id] = nil
    }

    func rename(_ id: String, to name: String) {
        devices.rename(id, to: name)
        saveDevices()
        let n = devices.devices.first { $0.id == id }?.name
        for c in clients.values where c.deviceID == id { c.deviceName = n ?? c.deviceName }
        if connected[id] != nil, let n { connected[id] = n }
    }

    /// The QR code's invite: every address a phone may reach this Mac on.
    func invite() -> PairingInvite? {
        guard let code = pairing, !fingerprint.isEmpty else { return nil }
        return PairingInvite(hosts: addresses, port: port, fingerprint: fingerprint, code: code.code,
                             name: Host.current().localizedName ?? "Mac")
    }

    /// The Mac's MagicDNS name, when Tailscale runs.
    nonisolated private static func findTailscaleName() -> String? {
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

struct RemoteError: Error {
    var code: String
    var message: String
    static func badParams(_ what: String) -> RemoteError { RemoteError(code: "bad_params", message: what) }
    static func notFound(_ what: String) -> RemoteError { RemoteError(code: "not_found", message: what) }
}
