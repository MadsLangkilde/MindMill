import Foundation
import KBCore
import Observation

/// One phone's connection. It must say hello with its token, or pair with the code, before anything else.
public final class RemoteClient: @unchecked Sendable {
    public let connection: CompanionConnection
    /// Set once the phone proved who it is.
    public var deviceID: String?
    public var deviceName = ""
    /// What the phone runs (`android`/`ios`), when it says; nil gets everything.
    public var platform: String?
    /// Accepted on the engine host's loopback listener, so it may sign in as a desktop shell (docs/engine-host.md).
    public var isLocal = false
    /// A desktop shell on this machine signed in with the engine's token: not a phone, never listed or pushed to.
    public var isDesktop = false
    /// The engine's own requests to this client (`platform.*`), waiting for their answers. Main actor only.
    var waiting: [String: CheckedContinuation<JSONValue, Error>] = [:]

    public init(_ connection: CompanionConnection) {
        self.connection = connection
    }

    public func send(_ message: RemoteMessage) { connection.sendText(message.encoded()) }

    public func sendBinary(_ data: Data) { connection.sendBinary(data) }

    public func close() { connection.close() }
}

public struct RemoteError: Error {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static func badParams(_ what: String) -> RemoteError { RemoteError(code: "bad_params", message: what) }
    public static func notFound(_ what: String) -> RemoteError { RemoteError(code: "not_found", message: what) }
    /// Something this machine can't do: a feature its platform doesn't have (yet), or no desktop shell to ask.
    public static func unavailable(_ message: String) -> RemoteError { RemoteError(code: "unavailable", message: message) }
}

extension RemoteError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Remote access: the engine listens for paired phones on the local network and Tailscale, answers their requests
/// through `handle` and pushes events about what changes. When the listener fails (port in use, no network) it
/// tries again by itself, less often each time, and at once when the network changes. The listening itself is the
/// platform's `CompanionTransport`; everything here (pairing, hello, routing, devices) is the same everywhere.
@MainActor
@Observable
public final class RemoteServer {
    public static let enabledKey = "remoteEnabled"
    public static let portKey = "remotePort"
    public static let defaultPort = 7878
    /// Wrong codes a pairing code takes before it stops working.
    public static let maxPairingAttempts = 5

    public enum PairingOutcome: Equatable {
        case paired(name: String)
        case failed(String)
    }

    public private(set) var status: RemoteServerStatus = .off
    public private(set) var fingerprint = ""
    public var devices = RemoteDevices()
    /// Shown while a phone may pair.
    public var pairing: PairingCode? {
        didSet { if pairing != nil { pairingOutcome = nil; wrongAttempts = 0 } }
    }
    /// How the last pairing ended, until a new code is shown or it is dismissed.
    public var pairingOutcome: PairingOutcome?
    public private(set) var wrongAttempts = 0
    /// Phones connected and signed in now, by device id.
    public private(set) var connected: [String: String] = [:]
    /// Every address a phone may reach this machine on, read when it starts and when the network changes.
    public private(set) var addresses: [String] = []
    public private(set) var tailscaleName: String?

    @ObservationIgnored public let transport: CompanionTransport
    @ObservationIgnored public let folder: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var listener: CompanionListening?
    @ObservationIgnored private var clients: [ObjectIdentifier: RemoteClient] = [:]
    @ObservationIgnored private var retry = RemoteRetry()
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var lastPath: String?
    @ObservationIgnored public var handle: ((RemoteClient, String, JSONValue) async throws -> JSONValue)?
    @ObservationIgnored public var handleBinary: ((RemoteClient, Data) -> Void)?
    /// A phone's connection closed; whatever it had running (a voice conversation) can end.
    @ObservationIgnored public var onClientClosed: ((RemoteClient) -> Void)?
    /// Sends a push to phones that aren't connected (APNs on the Mac). Set by the platform; nil: no push.
    @ObservationIgnored public var push: ((PushNote, [RemoteDevices.Device]) -> Void)?
    /// Whether `push` can deliver now (a key is set up).
    @ObservationIgnored public var pushReady: () -> Bool = { true }
    /// The engine host's token: a local client saying hello with it and `client: desktop` is a desktop shell.
    @ObservationIgnored public var desktopToken: String?
    /// The platform services the engine expects a desktop shell to provide, sent in its `hello` answer.
    @ObservationIgnored public var desktopServices: [String] = []
    /// A desktop shell signed in (true) or left (false).
    @ObservationIgnored public var onDesktop: ((RemoteClient, Bool) -> Void)?
    /// An event a desktop shell sent (`platform.speech.partial`, `platform.notify.clicked`…).
    @ObservationIgnored public var onClientEvent: ((RemoteClient, String, JSONValue) -> Void)?
    @ObservationIgnored private var nextRequest = 0

    public var isRunning: Bool { status.isRunning }
    public var error: String? { status.reason }

    public var port: Int {
        let p = defaults.integer(forKey: Self.portKey)
        return p > 0 && p < 65536 ? p : Self.defaultPort
    }

    nonisolated public static var defaultFolder: URL { AppPaths.file("remote") }

    private var devicesURL: URL { folder.appendingPathComponent("devices.json") }

    public init(transport: CompanionTransport, folder: URL = RemoteServer.defaultFolder, defaults: UserDefaults = .standard) {
        self.transport = transport
        self.folder = folder
        self.defaults = defaults
        if let data = try? Data(contentsOf: devicesURL), let d = try? JSONDecoder().decode(RemoteDevices.self, from: data) { devices = d }
    }

    public func saveDevices() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(devices) { try? data.write(to: devicesURL, options: .atomic) }
        writeLauncherKeys()
    }

    /// The paired phones' token hashes for the launcher (`BackgroundAgents`), which can't read devices.json.
    public func writeLauncherKeys() {
        let url = BackgroundAgents.keysURL(remoteFolder: folder)
        let text = BackgroundAgents.keysText(tokenHashes: devices.devices.map(\.tokenHash))
        guard (try? String(contentsOf: url, encoding: .utf8)) != text else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func start() {
        guard listener == nil else { return }
        retryTask?.cancel()
        retryTask = nil
        status = .starting
        watchNetwork()
        refreshAddresses()
        let port = port
        do {
            let l = try transport.listen(port: port, folder: folder)
            fingerprint = l.fingerprint
            l.onState = { [weak self, weak l] state in
                guard let self, let l, self.listener === l else { return }
                switch state {
                case .ready:
                    self.fingerprint = l.fingerprint
                    self.status = .running(port: port)
                    self.retry.reset()
                case .waiting(let reason):
                    self.status = .waiting(reason: reason)
                case .failed(let reason):
                    self.failed(reason)
                }
            }
            l.onConnection = { [weak self, weak l] conn in
                guard let self, let l, self.listener === l else {
                    conn.close()
                    return
                }
                self.accept(conn)
            }
            listener = l
            l.start()
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
            guard !Task.isCancelled, let self, self.defaults.bool(forKey: Self.enabledKey), self.listener == nil else { return }
            self.start()
        }
    }

    /// Starts again now: the Retry and Restart buttons.
    public func restart() {
        retryTask?.cancel()
        retryTask = nil
        retry.reset()
        closeListener()
        start()
    }

    public func stop() {
        retryTask?.cancel()
        retryTask = nil
        retry.reset()
        transport.stopWatchingNetwork()
        watching = false
        lastPath = nil
        closeListener()
        pairing = nil
        status = .off
    }

    private func closeListener() {
        listener?.cancel()
        listener = nil
        // Desktop shells came through the engine host's own loopback listener and stay.
        for (key, c) in clients where !c.isLocal {
            c.close()
            clients[key] = nil
        }
        connected = [:]
    }

    /// A network change: new addresses for the QR code, and the listener starts again at once.
    private func watchNetwork() {
        guard !watching else { return }
        watching = true
        transport.watchNetwork { [weak self] key, satisfied in self?.networkChanged(key, satisfied: satisfied) }
    }

    func networkChanged(_ key: String, satisfied: Bool) {
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

    public func refreshAddresses() {
        let transport = transport
        Task { [weak self] in
            let found = await transport.addresses()
            self?.tailscaleName = found.tailscaleName
            self?.addresses = found.addresses
        }
    }

    /// A connection on the engine host's loopback listener: a desktop shell (or anything local that knows the token).
    public func acceptLocal(_ conn: CompanionConnection) {
        accept(conn, local: true)
    }

    /// Desktop shells signed in now.
    public var desktops: [RemoteClient] { clients.values.filter(\.isDesktop) }

    private func accept(_ conn: CompanionConnection, local: Bool = false) {
        let client = RemoteClient(conn)
        client.isLocal = local
        clients[ObjectIdentifier(client)] = client
        conn.start(
            onText: { [weak self, weak client] text in
                Task { @MainActor in
                    guard let self, let client else { return }
                    self.received(text, from: client)
                }
            },
            onBinary: { [weak self, weak client] data in
                Task { @MainActor in
                    guard let self, let client, client.deviceID != nil else { return }
                    self.handleBinary?(client, data)
                }
            },
            onClose: { [weak self, weak client] in
                Task { @MainActor in
                    guard let self, let client else { return }
                    self.closed(client)
                }
            })
    }

    private func closed(_ c: RemoteClient) {
        clients[ObjectIdentifier(c)] = nil
        let waiting = c.waiting
        c.waiting = [:]
        for w in waiting.values { w.resume(throwing: RemoteError.unavailable("The desktop app closed.")) }
        if c.isDesktop {
            onDesktop?(c, false)
        } else if let id = c.deviceID {
            if !clients.values.contains(where: { $0.deviceID == id }) { connected[id] = nil }
            devices.seen(id)
            saveDevices()
        }
        onClientClosed?(c)
    }

    func received(_ text: String, from client: RemoteClient) {
        let message = RemoteMessage.decode(text)
        switch message {
        case .response(let id, let result)?:
            client.waiting.removeValue(forKey: id)?.resume(returning: result)
            return
        case .failure(let id, let code, let text)?:
            client.waiting.removeValue(forKey: id)?.resume(throwing: RemoteError(code: code, message: text))
            return
        case .event(let name, let data)?:
            if client.isDesktop { onClientEvent?(client, name, data) }
            return
        default:
            break
        }
        guard case .request(let id, let method, let params)? = message else { return }
        if method == "hello", params["client"]?.string == "desktop" {
            guard client.isLocal, let token = desktopToken, !token.isEmpty, params["token"]?.string == token else {
                client.send(.failure(id: id, code: "unauthorized", message: "That isn't this engine's token."))
                return
            }
            let first = !client.isDesktop
            client.isDesktop = true
            client.deviceID = "desktop"
            client.deviceName = "Desktop"
            if first { onDesktop?(client, true) }
            reply(id, client) { [weak self] in
                guard let self else { return .null }
                var result = try await self.handle?(client, method, params) ?? .null
                if case .object(var o) = result {
                    o["desktop"] = true
                    o["services"] = .array(self.desktopServices.map(JSONValue.string))
                    result = .object(o)
                }
                return result
            }
            return
        }
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
            client.platform = RemotePlatform.parse(params["platform"]?.string) ?? device.platform
            devices.setPlatform(device.id, client.platform)
            devices.seen(device.id)
            saveDevices()
            connected[device.id] = device.name
        } else if client.deviceID == nil {
            client.send(.failure(id: id, code: "unauthorized", message: "Say hello with the device token first."))
            return
        } else if method == "push.register", !client.isDesktop {
            client.send(.response(id: id, result: registerPush(client, params: params)))
            return
        }
        reply(id, client) { [weak self] in try await self?.handle?(client, method, params) ?? .null }
    }

    private func reply(_ id: String, _ client: RemoteClient, _ work: @escaping @MainActor () async throws -> JSONValue) {
        Task {
            do {
                client.send(.response(id: id, result: try await work()))
            } catch let e as RemoteError {
                client.send(.failure(id: id, code: e.code, message: e.message))
            } catch {
                client.send(.failure(id: id, code: "failed", message: error.localizedDescription))
            }
        }
    }

    /// Asks a client something (the engine's `platform.*` services to a desktop shell) and waits for its answer.
    /// Ids start with `e`, so they never collide with the client's own.
    public func request(_ client: RemoteClient, _ method: String, _ params: JSONValue = [:],
                        timeout: TimeInterval = 30) async throws -> JSONValue {
        nextRequest += 1
        let id = "e\(nextRequest)"
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSONValue, Error>) in
            client.waiting[id] = c
            client.send(.request(id: id, method: method, params: params))
            Task { [weak client] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let client, let w = client.waiting.removeValue(forKey: id) else { return }
                w.resume(throwing: RemoteError.unavailable("The desktop app didn't answer \(method)."))
            }
        }
    }

    /// Sends an event to the desktop shells only.
    public func broadcastDesktop(_ name: String, _ data: JSONValue = .object([:])) {
        for c in clients.values where c.isDesktop { c.send(.event(name: name, data: data)) }
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
        client.platform = RemotePlatform.parse(params["platform"]?.string)
        devices.setPlatform(device.id, client.platform)
        pairing = nil
        pairingOutcome = .paired(name: device.name)
        saveDevices()
        client.deviceID = device.id
        client.deviceName = device.name
        connected[device.id] = device.name
        client.send(.response(id: id, result: ["token": .string(token), "device": .string(device.id)]))
    }

    /// Sends an event to every signed-in phone, or with `platform` only to phones of that platform (and those that
    /// don't say which they are).
    public func broadcast(_ name: String, _ data: JSONValue = .object([:]), platform: String? = nil) {
        for c in clients.values where c.deviceID != nil && RemotePlatform.accepts(phone: c.platform, item: platform) {
            c.send(.event(name: name, data: data))
        }
    }

    /// `push.register`: where Apple's push service reaches this phone; an empty token stops pushes.
    public func registerPush(_ client: RemoteClient, params: JSONValue) -> JSONValue {
        guard let id = client.deviceID else { return ["registered": false] }
        let token = params["token"]?.string ?? ""
        let target = PushTarget(token: token, environment: params["environment"]?.string ?? "sandbox", topic: params["topic"]?.string ?? "")
        devices.setPush(id, token.isEmpty ? nil : target)
        saveDevices()
        if !token.isEmpty && target == nil { return ["registered": false, "message": "That isn't a push token."] }
        if push == nil || !pushReady() { return ["registered": false, "message": "Push isn't set up on this Mac (Settings → Remote)."] }
        return ["registered": .bool(!token.isEmpty)]
    }

    @ObservationIgnored private var waitingSessions = Set<String>()
    @ObservationIgnored private var factoryQuestions: [String: Int] = [:]

    /// A session's state changed: push once when it starts to need the user.
    public func sessionStateChanged(id: String, title: String, state: String) {
        let waiting = state == "waiting" || state == "blocked"
        let was = waitingSessions.contains(id)
        if waiting { waitingSessions.insert(id) } else { waitingSessions.remove(id) }
        if let note = PushNote.from(event: "session.changed", data: ["id": .string(id), "title": .string(title), "state": .string(state)], wasWaiting: was) {
            sendPush(note)
        }
    }

    /// A factory's open questions: push when there are more than before.
    public func factoryQuestionsChanged(id: String, count: Int) {
        let before = factoryQuestions[id] ?? 0
        factoryQuestions[id] = count
        guard count > before, let note = PushNote.from(event: "factory.changed", data: ["id": .string(id)], factoryQuestions: count) else { return }
        sendPush(note)
    }

    /// `test.send`: a delivery again to the phones of its platform (a desktop asked, as it can't install it), with a
    /// push to those that aren't connected.
    public func sendDelivery(_ event: JSONValue, platform: String?) {
        broadcast("test.delivery", event, platform: platform)
        sendPush(PushNote(title: "A build to install", body: event["title"]?.string ?? "A new build is ready to try.",
                          route: "test", platform: platform))
    }

    /// Pushes `note` to the registered phones that aren't connected now.
    public func sendPush(_ note: PushNote) {
        guard let push, pushReady() else { return }
        let targets = devices.pushTargets(for: note, connected: Set(connected.keys))
        if !targets.isEmpty { push(note, targets) }
    }

    public func revoke(_ id: String) {
        devices.remove(id)
        saveDevices()
        for c in clients.values where c.deviceID == id { c.close() }
        connected[id] = nil
    }

    public func rename(_ id: String, to name: String) {
        devices.rename(id, to: name)
        saveDevices()
        let n = devices.devices.first { $0.id == id }?.name
        for c in clients.values where c.deviceID == id { c.deviceName = n ?? c.deviceName }
        if connected[id] != nil, let n { connected[id] = n }
    }

    /// The QR code's invite: every address a phone may reach this machine on.
    public func invite() -> PairingInvite? {
        guard let code = pairing, !fingerprint.isEmpty else { return nil }
        return PairingInvite(hosts: addresses, port: port, fingerprint: fingerprint, code: code.code, name: transport.machineName)
    }
}
