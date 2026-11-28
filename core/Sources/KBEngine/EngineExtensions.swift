import Foundation
import KBCore

/// What sessions can use beyond Mindmill: the AI's skills and commands, its plugins and its tools (MCP servers);
/// and, for the phone, entries' sharing and the suggestions waiting on a session or a note.
extension MindmillEngine {
    public var brainHasPlugins: Bool { aiSetup.brainProvider.id == AIProvider.claudeCode.id }
    public var skillHome: SkillCatalog.Home { .of(brain: aiSetup.brainProvider.id) }
    /// Puts Mindmill's skills where the assistants in use read them, and takes them away where none does.
    public func placeSkills() {
        let root = URL(fileURLWithPath: KBConfig.expandTilde(pluginRootPath))
        let setup = aiSetup
        Task {
            let line: String? = await Task.detached(priority: .utility) {
                do {
                    let c = try AssistantSkills.sync(setup, skills: root.appendingPathComponent("skills"),
                                                     kbCommand: root.appendingPathComponent("bin/kb").path)
                    return c.isEmpty ? nil : "skills: placed \(c.written), removed \(c.removed)"
                } catch {
                    return "skills: \(error.localizedDescription)"
                }
            }.value
            if let line { ClaudeChat.log(line) }
        }
    }

    public var connectorsURL: URL? { brainHasPlugins ? URL(string: "https://claude.ai/settings/connectors") : nil }

    /// Runs the `claude` CLI; nil when it isn't found.
    public func runClaudeCLI(_ args: [String], cwd: URL? = nil) async -> CommandResult? {
        guard let exe = claudeExecutable else { return nil }
        return await ProcessRunner().run(executable: exe, arguments: args, environment: claudeEnvironment(), stdin: nil,
                                         currentDirectory: cwd ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The installed plugins, from `claude plugin list --json`, kept for a minute; Mindmill's own plugin is
    /// always there, since every session loads it.
    public func installedPlugins(refresh: Bool = false) async -> [AIExtensions.InstalledPlugin] {
        guard brainHasPlugins else { return [] }
        if !refresh, let c = pluginCache, Date().timeIntervalSince(c.at) < 60 { return c.plugins }
        guard let r = await runClaudeCLI(["plugin", "list", "--json"]), r.status == 0 else { return pluginCache?.plugins ?? [] }
        let plugins = AIExtensions.parsePlugins(r.stdout).installed
        pluginCache = (Date(), plugins)
        return plugins
    }

    /// Every skill and command a session in `scope` (or, without one, any of the user's projects) can run.
    public func skillCatalog(scope: String?, session: WorkSession? = nil) async -> [SkillInfo] {
        let layout = KBLayout.of(root: rootURL)
        var repos: [(scope: String, folder: URL)] = []
        if let s = session, let sc = s.project { repos.append((sc, s.workingDirectory)) }
        let scopes = scope.map { [$0] } ?? (session == nil ? index.projects.map(\.id) : [])
        for sc in scopes {
            for r in ScopeRepositories.of(sc, in: index).work {
                if let dir = r.checkout ?? layout.checkouts[r.scope], !repos.contains(where: { $0.folder.standardizedFileURL == dir.standardizedFileURL }) {
                    repos.append((r.scope, dir))
                }
            }
        }
        var plugins = await installedPlugins().filter(\.enabled).compactMap { p in
            p.folder.map { SkillCatalog.Plugin(name: p.name, folder: URL(fileURLWithPath: $0)) }
        }
        if !plugins.contains(where: { $0.name == "mindmill" }) {
            plugins.insert(SkillCatalog.Plugin(name: "mindmill", folder: URL(fileURLWithPath: KBConfig.expandTilde(pluginRootPath))), at: 0)
        }
        return SkillCatalog.scan(home: skillHome, repos: repos, plugins: plugins, listed: session?.chat.commands ?? [])
    }

    /// Where a skill of the user's is (or goes): a skill folder's SKILL.md, or a command file of that name.
    public func skillFile(name: String, location: SkillLocation, scope: String?) throws -> URL {
        let repo = scope.flatMap { KBLayout.of(root: rootURL).checkouts[$0] }
        if location == .project, repo == nil { throw ActionError("That project has no repository on this \(platform.machineWord).") }
        guard let file = SkillCatalog.file(name: name, location: location, home: skillHome, repo: repo) else { throw ActionError("Give the skill a name.") }
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let commands = location == .user ? skillHome.user.appendingPathComponent("commands")
            : repo!.appendingPathComponent(skillHome.projectFolder).appendingPathComponent("commands")
        let command = commands.appendingPathComponent(name + ".md")
        return FileManager.default.fileExists(atPath: command.path) ? command : file
    }

    public func saveSkill(name: String, location: SkillLocation, scope: String?, content: String) throws {
        let file = try skillFile(name: name, location: location, scope: scope)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
        skillsChanged()
    }

    public func deleteSkill(name: String, location: SkillLocation, scope: String?) throws {
        let file = try skillFile(name: name, location: location, scope: scope)
        guard FileManager.default.fileExists(atPath: file.path) else { throw ActionError("There's no skill \(name).") }
        try FileManager.default.removeItem(at: file.lastPathComponent == "SKILL.md" ? file.deletingLastPathComponent() : file)
        skillsChanged()
    }

    /// The AI writes a skill from the user's words, or changes `current` as they describe. Not saved.
    public func draftSkill(description: String, name: String?, current: String?) async throws -> String {
        let prompt = SkillCatalog.draftPrompt(description: description, name: name, current: current)
        guard let reply = await claudeOnce(prompt, system: "You write skills (SKILL.md files) for AI coding assistants. Reply with the file only.",
                                           model: model(for: .ask), timeout: 180) else {
            throw ActionError(claudeExecutable == nil ? claudeMissingExplanation : "\(Brain.name) didn't write it. Try again.")
        }
        return SkillCatalog.cleanDraft(reply)
    }

    public func skillsChanged() {
        remote.broadcast("skills.changed")
        onSkillsChanged?()
    }

    func requirePlugins() throws {
        guard brainHasPlugins else { throw RemoteError(code: "unavailable", message: "\(Brain.name) has no plugins.") }
    }

    /// Runs a plugin or MCP change; its error output when it fails.
    public func claudeChange(_ args: [String]) async throws {
        guard let r = await runClaudeCLI(args) else { throw ActionError(claudeMissingExplanation) }
        guard r.status == 0 else {
            let why = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ActionError(why.isEmpty ? "claude \(args.prefix(2).joined(separator: " ")) failed." : why)
        }
        pluginCache = nil
        skillsChanged()
    }

    // MARK: Sharing and suggestions

    /// The entry's sharing, from `kb share status`.
    public func sharingJSON(_ id: EntryID) async -> JSONValue {
        let r = await cli.result(["share", "status", "--scope", id.project, "--json"])
        let status = SharingStatus.parse(r.stdout) ?? SharingStatus()
        let state = status.state(of: id)
        let repo = status.repos[id.project]
        var out: [String: JSONValue] = ["state": .string(state.rawValue), "title": .string(state.title), "shared": .bool(state.isShared),
                                        "canChange": .bool(id.section != .inbox && repo?.path != nil),
                                        "help": .string(state.help(repo: repo?.name, branch: repo?.branch))]
        if let name = repo?.name { out["repo"] = .string(name) }
        return .object(out)
    }

    /// Inbox entries proposed by any of `origins` (a session as `session:<id>`, a note's or idea's id), as the phone
    /// shows them; fact changes are left to Facts.
    public func suggestions(from origins: Set<String>) -> [KBEntry] {
        index.entries.values
            .filter { $0.section == .inbox && $0.field("updates") == nil && ($0.proposedBy.map(origins.contains) ?? false) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func suggestionOrigins(_ s: WorkSession) -> Set<String> {
        var out: Set<String> = ["session:\(s.id)"]
        if let o = PlanSessions.origin(about: s.about) { out.insert(o) }
        return out
    }

    static func suggestionJSON(_ e: KBEntry) -> JSONValue {
        let section = e.proposedSection
        return ["id": .string(e.id.rawValue), "section": .string(section?.rawValue ?? ""),
                "sectionTitle": .string(section?.singularTitle ?? "Entry"), "title": .string(e.title),
                "summary": .string(e.summary), "reason": .string(e.reason ?? "")]
    }

    func registerExtensionMethods() {
        let m = methods

        m.register("skills.list") { [unowned self] _, p in
            sessions.loadIfNeeded()
            let s = sessions.session(p["session"]?.string)
            let skills = await skillCatalog(scope: p["scope"]?.string ?? (s == nil ? nil : s?.project), session: s)
            return ["skills": .array(skills.map { k in
                var o: [String: JSONValue] = ["name": .string(k.name), "command": .string(k.command), "description": .string(k.description),
                                              "source": .string(k.source.rawValue), "editable": .bool(k.editable)]
                if let v = k.plugin { o["plugin"] = .string(v) }
                if let v = k.location { o["location"] = .string(v.rawValue) }
                if let v = k.scope { o["scope"] = .string(v) }
                return .object(o)
            })]
        }

        func skillTarget(_ p: JSONValue) throws -> (String, SkillLocation, String?) {
            guard let name = p["name"]?.string, !name.isEmpty else { throw RemoteError.badParams("name") }
            let location = p["location"]?.string.flatMap(SkillLocation.init(rawValue:)) ?? .user
            return (name, location, p["scope"]?.string)
        }

        m.register("skill.get") { [unowned self] _, p in
            let (name, location, scope) = try skillTarget(p)
            let file = try skillFile(name: name, location: location, scope: scope)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw RemoteError.notFound("No such skill") }
            return ["name": .string(name), "description": .string(SkillCatalog.frontmatter(text).description ?? ""), "content": .string(text)]
        }

        m.register("skill.save") { [unowned self] _, p in
            let (name, location, scope) = try skillTarget(p)
            guard let content = p["content"]?.string, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteError.badParams("content") }
            try saveSkill(name: name, location: location, scope: scope, content: content)
            return ["saved": true]
        }

        m.register("skill.draft") { [unowned self] _, p in
            guard let d = p["description"]?.string, !d.isEmpty else { throw RemoteError.badParams("description") }
            let text = try await draftSkill(description: d, name: p["name"]?.string, current: p["content"]?.string)
            let name = SkillCatalog.frontmatter(text).name ?? p["name"]?.string ?? ""
            return ["name": .string(SkillCatalog.safeName(name)), "content": .string(text)]
        }

        m.register("skill.delete") { [unowned self] _, p in
            let (name, location, scope) = try skillTarget(p)
            try deleteSkill(name: name, location: location, scope: scope)
            return ["deleted": true]
        }

        m.register("plugins.list") { [unowned self] _, p in
            try requirePlugins()
            var available: [AIExtensions.AvailablePlugin] = []
            var installed = await installedPlugins(refresh: true)
            if p["available"]?.bool == true, let r = await runClaudeCLI(["plugin", "list", "--available", "--json"]), r.status == 0 {
                let both = AIExtensions.parsePlugins(r.stdout)
                installed = both.installed
                available = AIExtensions.search(both.available, query: p["query"]?.string ?? "")
            }
            return ["plugins": .array(installed.map { x in
                ["id": .string(x.id), "name": .string(x.name), "marketplace": .string(x.marketplace), "version": .string(x.version),
                 "scope": .string(x.scope), "enabled": .bool(x.enabled)]
            }), "available": .array(available.map { x in
                var o: [String: JSONValue] = ["id": .string(x.id), "name": .string(x.name), "marketplace": .string(x.marketplace),
                                              "description": .string(x.description)]
                if let n = x.installs { o["installs"] = .number(Double(n)) }
                return .object(o)
            })]
        }

        m.register("plugin.set") { [unowned self] _, p in
            try requirePlugins()
            guard let id = p["id"]?.string, let on = p["enabled"]?.bool else { throw RemoteError.badParams("id and enabled") }
            try await claudeChange(["plugin", on ? "enable" : "disable", id])
            return ["done": true]
        }

        m.register(["plugin.install", "plugin.uninstall"]) { method in { [unowned self] _, p in
            try requirePlugins()
            guard let id = p["id"]?.string, !id.isEmpty else { throw RemoteError.badParams("id") }
            try await claudeChange(["plugin", method == "plugin.install" ? "install" : "uninstall", id])
            return ["done": true]
        } }

        m.register("mcp.list") { [unowned self] _, _ in
            try requirePlugins()
            guard let r = await runClaudeCLI(["mcp", "list"]) else { throw ActionError(claudeMissingExplanation) }
            let servers = ClaudeConnectors.parse(r.stdout)
            var out: [String: JSONValue] = ["servers": .array(servers.map { s in
                ["name": .string(s.displayName), "id": .string(s.name), "target": .string(s.target), "status": .string(s.status.rawValue),
                 "origin": .string(s.fromClaudeAI ? "claude.ai" : s.fromPlugin ? "plugin" : "user"),
                 "removable": .bool(!s.fromClaudeAI && !s.fromPlugin)]
            })]
            if let u = connectorsURL { out["connectorsURL"] = .string(u.absoluteString) }
            return .object(out)
        }

        m.register("mcp.add") { [unowned self] _, p in
            try requirePlugins()
            let name = ClaudeConnectors.safeName(p["name"]?.string ?? "")
            guard !name.isEmpty, let url = p["url"]?.string?.trimmingCharacters(in: .whitespaces), url.hasPrefix("http") else {
                throw RemoteError.badParams("name and url")
            }
            let transport = p["transport"]?.string == "sse" ? "sse" : "http"
            try await claudeChange(["mcp", "add", "--transport", transport, "--scope", "user", name, url])
            return ["done": true]
        }

        m.register("mcp.remove") { [unowned self] _, p in
            try requirePlugins()
            guard let name = p["name"]?.string, !name.isEmpty else { throw RemoteError.badParams("name") }
            do { try await claudeChange(["mcp", "remove", name]) } catch { try await claudeChange(["mcp", "remove", name, "--scope", "user"]) }
            return ["done": true]
        }

        m.register("entry.share") { [unowned self] _, p in
            guard let raw = p["id"]?.string, let id = EntryID(raw), let on = p["shared"]?.bool else { throw RemoteError.badParams("id and shared") }
            try await setShared(id, on)
            onSharingChanged?()
            return ["sharing": await sharingJSON(id)]
        }

        m.register("sharing.defaults") { [unowned self] _, p in
            let scope = try scopeParam(p)
            let r = await cli.result(["share", "defaults", "--scope", scope, "--json"])
            guard r.status == 0, let data = r.stdout.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ActionError(r.stderr) }
            let chosen = obj["defaults"] as? [String: String] ?? [:]
            let kinds = KBSection.allCases.filter { $0 != .inbox && chosen[$0.rawValue] != nil }
            var out: [String: JSONValue] = ["scope": .string(scope), "defaults": .array(kinds.map { s in
                ["section": .string(s.rawValue), "title": .string(s.title), "visibility": .string(chosen[s.rawValue] ?? "private")]
            })]
            if let repo = obj["repo"] as? String { out["repo"] = .string(URL(fileURLWithPath: repo).lastPathComponent) }
            return .object(out)
        }

        m.register("sharing.setDefault") { [unowned self] _, p in
            let scope = try scopeParam(p)
            guard let section = p["section"]?.string, let vis = p["visibility"]?.string, ["private", "shared"].contains(vis) else {
                throw RemoteError.badParams("section and visibility")
            }
            var args = ["share", "default", section, vis, "--scope", scope, "--json"]
            if p["applyExisting"]?.bool == true { args.append("--apply") }
            let r = await cli.result(args)
            guard r.status == 0 else { throw ActionError(r.stderr.replacingOccurrences(of: "kb: ", with: "")) }
            let changed = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any])?["changed"] as? Int ?? 0
            reload()
            onSharingChanged?()
            return ["changed": .number(Double(changed))]
        }

        m.register("voice.test") { [unowned self] _, params in
            let prefs = VoicePreferences.load()
            guard let provider = params["provider"]?.string ?? prefs.provider, let p = RealtimeProvider.with(id: provider) else {
                return ["ok": false, "message": .string("No voice API key on the \(platform.machineWord). Add one in Settings → Voice there.")]
            }
            return await voiceKeyTest(p)
        }
        m.register("voice.providers") { [unowned self] _, _ in
            let prefs = VoicePreferences.load()
            let engine = voiceEngineChoice.engine()
            return ["providers": .array(RealtimeProvider.all.map { p in
                        ["id": .string(p.id), "name": .string(p.name), "available": .bool(p.available),
                         "hasKey": .bool(platform.secrets.hasSecret(SecretVoiceKeys.name(p.id))), "keyPage": .string(p.keyPage),
                         "models": .array(p.models.map(JSONValue.string)), "model": .string(prefs.model(for: p.id)),
                         "voices": .array(p.voices.map(JSONValue.string)), "voice": .string(prefs.apiVoice(for: p.id))]
                    }),
                    "active": engine == .api ? prefs.provider.map(JSONValue.string) ?? .null : .null,
                    "engine": .string(engine.rawValue)]
        }
        m.register("voice.key.set") { [unowned self] _, params in
            guard let id = params["provider"]?.string, let p = RealtimeProvider.with(id: id) else { throw RemoteError.badParams("provider") }
            let key = (params["key"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, key.count <= 4096, !key.contains(where: \.isNewline) else { throw RemoteError.badParams("key") }
            voiceKeys.set(key, provider: id)
            voiceKeyReads[id] = nil
            if params["use"]?.bool ?? true, p.available {
                var prefs = VoicePreferences.load()
                prefs.provider = id
                prefs.engine = .api
                prefs.save()
            }
            checkVoiceSettings()
            var out = await voiceKeyTest(p)
            if case .object(var o) = out { o["saved"] = true; out = .object(o) }
            return out
        }
        m.register("voice.key.remove") { [unowned self] _, params in
            guard let id = params["provider"]?.string, RealtimeProvider.with(id: id) != nil else { throw RemoteError.badParams("provider") }
            voiceKeys.set(nil, provider: id)
            var prefs = VoicePreferences.load()
            if prefs.provider == id {
                prefs.provider = nil
                prefs.engine = .keyless
                prefs.save()
            }
            checkVoiceSettings()
            return ["removed": true]
        }
        m.register("voice.use") { [unowned self] _, params in
            var prefs = VoicePreferences.load()
            if let id = params["provider"]?.string, !id.isEmpty {
                guard let p = RealtimeProvider.with(id: id), p.available else { throw RemoteError.badParams("provider") }
                guard platform.secrets.hasSecret(SecretVoiceKeys.name(id)) else {
                    throw RemoteError(code: "bad_params", message: "The \(platform.machineWord) has no \(p.name) key. Send one first.")
                }
                prefs.provider = id
                prefs.engine = .api
                if let model = params["model"]?.string {
                    guard p.models.contains(model) else { throw RemoteError.badParams("model") }
                    prefs.models[id] = model
                }
                if let voice = params["voice"]?.string {
                    guard p.voices.contains(voice) else { throw RemoteError.badParams("voice") }
                    prefs.apiVoices[id] = voice
                }
            } else {
                prefs.engine = .keyless
            }
            prefs.save()
            checkVoiceSettings()
            return prefs.remoteConfig(engine: voiceEngineChoice.engine())
        }
    }

    /// `voice.test` for one provider: its key checked with the provider's cheapest call.
    func voiceKeyTest(_ p: RealtimeProvider) async -> JSONValue {
        let key: String
        switch await readVoiceKey(p.id) {
        case .key(let k): key = k
        case .missing:
            return ["ok": false, "message": .string("The \(p.name) key is missing on the \(platform.machineWord)."), "providerName": .string(p.name)]
        case .locked:
            return ["ok": false, "message": .string(VoiceEngineChoice.fallbackMessage(.keyLocked, provider: p.name, machine: platform.machineWord)),
                    "providerName": .string(p.name)]
        }
        let message = await RealtimeKeyTest.test(provider: p.id, key: key)
        return ["ok": .bool(RealtimeKeyTest.passed(message)), "message": .string(message), "providerName": .string(p.name)]
    }

    // MARK: Voice settings watch

    /// What the phone needs to know about voice, with a stamp of each key that changes when it does, so a new key
    /// counts as a change. Never reads a key: macOS would ask for the password at launch.
    func voiceSignature() -> String {
        let prefs = VoicePreferences.load()
        let stamps = RealtimeProvider.all.map { platform.secrets.secretStamp(SecretVoiceKeys.name($0.id)) ?? "-" }
        return "\(prefs.remoteConfig(engine: voiceEngineChoice.engine()))|\(stamps.joined(separator: ","))"
    }

    /// Checks every few seconds whether voice settings or keys changed, wherever they were changed, and tells phones.
    public func watchVoiceSettings() {
        voiceSignatureSeen = voiceSignature()
        // Starts reading the key in use now, so whoever is at the computer can allow it before a phone needs it.
        let prefs = VoicePreferences.load()
        if prefs.engine == .api, let provider = prefs.provider { Task { _ = await readVoiceKey(provider, wait: 0) } }
        voiceWatch?.invalidate()
        voiceWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkVoiceSettings() }
        }
    }

    public func checkVoiceSettings() {
        let now = voiceSignature()
        guard now != voiceSignatureSeen else { return }
        voiceSignatureSeen = now
        remote.broadcast("voice.changed", VoicePreferences.load().remoteConfig(engine: voiceEngineChoice.engine()))
        onVoiceChanged?()
    }
}
