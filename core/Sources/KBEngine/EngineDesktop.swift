import Foundation
import KBCore
import Observation

/// Desktop-only methods of docs/engine-host.md: the tools check for onboarding, phone pairing and devices, and the
/// events that keep the shell's chrome current (`desktop.needsYou`, `remote.changed`).
extension MindmillEngine {
    func registerDesktopExtras() {
        let m = methods
        m.register("desktop.tools") { [unowned self] client, p in
            try desktopOnly(client)
            if p["refresh"]?.bool == true || shell == nil {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in resolveTools { c.resume() } }
            }
            return await toolsReport()
        }
        m.register("remote.status") { [unowned self] client, _ in
            try desktopOnly(client)
            return remoteStatus()
        }
        m.register("remote.pairing.show") { [unowned self] client, _ in
            try desktopOnly(client)
            if !platform.defaults.bool(forKey: RemoteServer.enabledKey) {
                platform.defaults.set(true, forKey: RemoteServer.enabledKey)
            }
            if !remote.isRunning { remote.start() }
            remote.pairing = PairingCode.new()
            return remoteStatus()
        }
        m.register("remote.pairing.hide") { [unowned self] client, _ in
            try desktopOnly(client)
            remote.pairing = nil
            remote.pairingOutcome = nil
            return remoteStatus()
        }
        m.register("remote.device.remove") { [unowned self] client, p in
            try desktopOnly(client)
            guard let id = p["id"]?.string, remote.devices.devices.contains(where: { $0.id == id }) else { throw RemoteError.notFound("No such phone") }
            remote.revoke(id)
            return remoteStatus()
        }
        m.register("remote.device.rename") { [unowned self] client, p in
            try desktopOnly(client)
            guard let id = p["id"]?.string, let name = p["name"]?.string, !name.trimmingCharacters(in: .whitespaces).isEmpty
            else { throw RemoteError.badParams("id and name") }
            guard remote.devices.devices.contains(where: { $0.id == id }) else { throw RemoteError.notFound("No such phone") }
            remote.rename(id, to: name)
            return remoteStatus()
        }
    }

    private func desktopOnly(_ client: RemoteClient) throws {
        guard client.isDesktop else { throw RemoteError(code: "unauthorized", message: "Only Mindmill's own window can do that.") }
    }

    // MARK: Tools

    /// What onboarding checks: Claude Code (found, signed in), Git (Git for Windows: Claude Code needs its bash),
    /// Python for `kb`, and the plugin.
    public func toolsReport() async -> JSONValue {
        let env = shell?.environment ?? ProcessInfo.processInfo.environment
        var claude: [String: JSONValue] = ["found": .bool(shell?.claude != nil)]
        if let exe = shell?.claude {
            claude["path"] = .string(exe.path)
            let r = await ProcessRunner().run(executable: exe, arguments: ["auth", "status", "--json"], environment: env, stdin: nil,
                                              currentDirectory: nil)
            if let status = ClaudeAuth.Status.decode(r.stdout) {
                claude["signedIn"] = .bool(status.loggedIn)
                if let email = status.email { claude["account"] = .string(email) }
            } else {
                claude["signedIn"] = .null
            }
        } else {
            claude["problem"] = .string(claudeMissingExplanation)
        }
        let git = Self.findGit(environment: env)
        var gitInfo: [String: JSONValue] = ["found": .bool(git != nil)]
        if let git { gitInfo["path"] = .string(git) } else {
            #if os(Windows)
            gitInfo["problem"] = .string("Install Git for Windows: Claude Code needs its Git Bash.")
            #else
            gitInfo["problem"] = .string("Install Git.")
            #endif
        }
        var python: [String: JSONValue] = ["found": .bool(shell?.python3 != nil)]
        if let py = shell?.python3 { python["path"] = .string(py.path) } else { python["problem"] = .string("Install Python 3 for the kb command.") }
        let pluginFound = PluginLocation.hasScripts(pluginRootPath)
        let signedIn = claude["signedIn"]?.bool == true
        return [
            "claude": .object(claude), "git": .object(gitInfo), "python": .object(python),
            "plugin": ["found": .bool(pluginFound), "path": .string(KBConfig.expandTilde(pluginRootPath))],
            "knowledgeBase": ["path": .string(rootURL.path), "loaded": .bool(loadError == nil),
                              "problem": loadError.map { .string($0.localizedDescription) } ?? .null],
            "ready": .bool(shell?.claude != nil && signedIn && git != nil && shell?.python3 != nil && pluginFound && loadError == nil),
        ]
    }

    static func findGit(environment: [String: String]) -> String? {
        let exists = { (p: String) in FileManager.default.isExecutableFile(atPath: p) }
        #if os(Windows)
        if let g = WindowsTools.onPath("git", environment: environment, exists: exists) { return g }
        let program = environment.first { $0.key.caseInsensitiveCompare("ProgramFiles") == .orderedSame }?.value ?? "C:\\Program Files"
        return [program + "\\Git\\cmd\\git.exe", program + "\\Git\\bin\\git.exe"].first(where: exists)
        #else
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        return (path.split(separator: ":").map { "\($0)/git" } + ["/usr/bin/git"]).first(where: exists)
        #endif
    }

    // MARK: Phones

    /// Phone access as the shell's Settings → Phones shows it.
    public func remoteStatus() -> JSONValue {
        let status: String
        switch remote.status {
        case .off: status = "off"
        case .starting: status = "starting"
        case .running: status = "running"
        case .waiting: status = "waiting"
        case .failed: status = "failed"
        }
        var pairing: JSONValue = .null
        if let code = remote.pairing {
            var o: [String: JSONValue] = ["code": .string(code.code), "expires": .string(Self.iso(code.expires))]
            if let invite = remote.invite() {
                o["invite"] = ["url": .string(invite.url), "hosts": .array(invite.hosts.map(JSONValue.string)), "port": .number(Double(invite.port)),
                               "fingerprint": .string(invite.fingerprint), "name": .string(invite.name)]
            } else {
                o["invite"] = .null
            }
            pairing = .object(o)
        }
        var outcome: JSONValue = .null
        switch remote.pairingOutcome {
        case .paired(let name)?: outcome = ["paired": .string(name)]
        case .failed(let message)?: outcome = ["failed": .string(message)]
        case nil: break
        }
        let devices: [JSONValue] = remote.devices.devices.map { d in
            ["id": .string(d.id), "name": .string(d.name), "platform": d.platform.map(JSONValue.string) ?? .null,
             "paired": .string(Self.iso(d.paired)), "lastSeen": d.lastSeen.map { .string(Self.iso($0)) } ?? .null,
             "connected": .bool(remote.connected[d.id] != nil), "push": .bool(d.push != nil)]
        }
        return [
            "enabled": .bool(platform.defaults.bool(forKey: RemoteServer.enabledKey)), "status": .string(status),
            "reason": remote.error.map(JSONValue.string) ?? .null, "port": .number(Double(remote.port)),
            "fingerprint": remote.fingerprint.isEmpty ? .null : .string(remote.fingerprint),
            "addresses": .array(remote.addresses.map(JSONValue.string)), "pairing": pairing, "outcome": outcome,
            "devices": .array(devices),
        ]
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// Sends `remote.changed` to the desktop shells whenever phone access, the pairing or the devices change.
    func observeRemote() {
        withObservationTracking {
            _ = remote.status
            _ = remote.pairing
            _ = remote.pairingOutcome
            _ = remote.devices
            _ = remote.connected
            _ = remote.addresses
            _ = remote.fingerprint
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !self.remote.desktops.isEmpty { self.remote.broadcastDesktop("remote.changed", self.remoteStatus()) }
                self.observeRemote()
            }
        }
    }

    // MARK: Needs you

    /// Sends `desktop.needsYou` when what waits for the user changed; hosts call it when sessions or factories change.
    public func needsYouChanged() {
        let items = needsYouItems()
        let key = items.compactMap { $0["id"]?.string }.joined(separator: ",")
        guard key != lastNeedsYou else { return }
        lastNeedsYou = key
        remote.broadcastDesktop("desktop.needsYou", ["count": .number(Double(items.count)), "items": .array(items)])
    }
}
