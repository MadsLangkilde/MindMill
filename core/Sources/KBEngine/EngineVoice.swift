import Foundation
import KBCore

/// Serves the action layer as an MCP server to the Claude Code sessions the engine starts (the voice brain, the
/// assistant). macOS: `LocalActionServer` on Network.framework; Windows: the engine host's loopback HTTP listener.
/// Both answer with `MCPHTTP.respond`.
public protocol ActionEndpoint: AnyObject {
    /// The `--mcp-config` JSON for a session, once the endpoint listens; nil when it can't.
    @MainActor func mcpConfig() async -> String?
}

/// The HTTP side of the local MCP endpoint, the same on every platform: a bearer token, POST `/mcp`, JSON-RPC
/// messages (or a batch of them) answered by `MCPActions`.
public enum MCPHTTP {
    @MainActor
    public static func respond(_ r: HTTPRequest, token: String, mcp: MCPActions) async -> Data {
        guard r.header("authorization") == "Bearer \(token)" else {
            return HTTPRequest.response(status: 401, reason: "Unauthorized")
        }
        guard r.path.hasPrefix("/mcp") else { return HTTPRequest.response(status: 404, reason: "Not Found") }
        guard r.method == "POST" else { return HTTPRequest.response(status: 405, reason: "Method Not Allowed") }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: r.body) else {
            return HTTPRequest.response(status: 400, reason: "Bad Request")
        }
        if case .array(let batch) = message {
            var replies: [JSONValue] = []
            for m in batch { if let reply = await mcp.handle(m) { replies.append(reply) } }
            if replies.isEmpty { return HTTPRequest.response(status: 202, reason: "Accepted") }
            return HTTPRequest.response(status: 200, reason: "OK", body: (try? JSONEncoder().encode(JSONValue.array(replies))) ?? Data())
        }
        guard let reply = await mcp.handle(message) else { return HTTPRequest.response(status: 202, reason: "Accepted") }
        return HTTPRequest.response(status: 200, reason: "OK", body: (try? JSONEncoder().encode(reply)) ?? Data())
    }
}

/// The AI settings and Claude Code launches: which brain and model each task uses, and how a session starts.
extension MindmillEngine {
    /// `KB_MODEL` (diagnostics) overrides every task's model for one run.
    private var modelOverride: String? {
        ProcessInfo.processInfo.environment["KB_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The model a task runs on (Settings → AI); empty for the assistant's default.
    public func model(for task: AITask) -> String { modelOverride ?? aiSetup.model(for: task) }

    public var brainName: String { aiSetup.brainProvider.shortName }

    /// Where `claude` is, nil while looking or when it isn't installed.
    public var claudeExecutable: URL? { shell?.claude }

    public var claudeMissingExplanation: String {
        guard shell != nil else { return "Looking for the claude CLI…" }
        #if os(Windows)
        return "Claude Code wasn't found (claude.exe on PATH or in %USERPROFILE%\\.local\\bin). Install Claude Code and Git for Windows, then start Mindmill again."
        #else
        return "The claude CLI was not found on your login shell's PATH (zsh -lc 'command -v claude'). Install Claude Code, then relaunch Mindmill."
        #endif
    }

    /// A Claude Code launch with the user's environment, `KB_ROOT` and the plugin; nil when `claude` isn't found.
    public func launch(prompt: String, sessionID: String, resume: Bool, model: String, cwd: URL,
                       tools: [String] = ClaudeLaunch.bridgeTools) -> ClaudeLaunch? {
        guard let exe = claudeExecutable else { return nil }
        return ClaudeLaunch(executable: exe, pluginRoot: pluginRootPath, systemPrompt: prompt + "\n" + ClaudeModes.linkCapture,
                            sessionID: sessionID, resume: resume, model: model, workingDirectory: cwd, allowedTools: tools,
                            environment: claudeEnvironment())
    }
}

/// A voice API key read from the secret store (`readVoiceKey`).
public enum VoiceKeyRead: Equatable, Sendable {
    case key(String)
    /// None saved.
    case missing
    /// Saved, but reading it was refused or is still waiting for the user to allow it.
    case locked
}

public struct VoiceStartError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The first of several racing tasks claims it.
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}

/// Voice conversations (remote-api.md, Voice): a persistent Claude session per conversation with the action tools
/// (the "brain"), driven by the client that owns the microphone: a phone, the desktop shell's Voice screen or the
/// Mac's own voice mode. Keyless: the client recognises and speaks, sending `voice.say` and speaking `voice.sentence`.
/// API engine: the client streams microphone audio and plays the audio the realtime relay sends back.
extension MindmillEngine {
    public var voiceEngineChoice: VoiceEngineChoice {
        let prefs = VoicePreferences.load()
        return VoiceEngineChoice(preferred: prefs.engine, provider: prefs.provider,
                                 hasKey: prefs.provider.map { platform.secrets.hasSecret(SecretVoiceKeys.name($0)) } ?? false)
    }

    public var voiceKeys: SecretVoiceKeys { SecretVoiceKeys(platform.secrets) }

    /// The voice API key for `provider`, read away from the main thread: macOS asks for the login password before a
    /// new build of Mindmill may read it, and no one may be at the Mac to answer. `locked` once `wait` passes with
    /// no answer (the read carries on, so the key is there next time) or when reading it was refused.
    public func readVoiceKey(_ provider: String, wait: TimeInterval = 10) async -> VoiceKeyRead {
        let name = SecretVoiceKeys.name(provider)
        guard platform.secrets.hasSecret(name) else { return .missing }
        let read: Task<String?, Never>
        if let pending = voiceKeyReads[provider] {
            read = pending
        } else {
            nonisolated(unsafe) let store = platform.secrets
            read = Task.detached { store.secret(name) }
            voiceKeyReads[provider] = read
            Task { [weak self] in
                _ = await read.value
                if self?.voiceKeyReads[provider] == read { self?.voiceKeyReads[provider] = nil }
            }
        }
        let value: String?? = await withCheckedContinuation { done in
            let once = Once()
            Task { let v = await read.value; if once.claim() { done.resume(returning: .some(v)) } }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
                if once.claim() { done.resume(returning: .none) }
            }
        }
        guard let got = value, let key = got, !key.isEmpty else { return .locked }
        return .key(key)
    }

    /// Starts a conversation's brain: a persistent Claude session with the action tools, streaming its reply.
    public func startVoiceConversation(scope: String?, engine: VoiceEngineKind? = nil) async -> VoiceConversation {
        let c = VoiceConversation(scope: scope ?? self.scope)
        c.engine = engine ?? voiceEngineChoice.engine()
        voiceConversations[c.id] = c
        c.chat.onEvent = { [weak c] e in c?.handle(e) }
        await bootVoiceBrain(c)
        return c
    }

    public func bootVoiceBrain(_ c: VoiceConversation) async {
        let mcp = await platform.actionEndpoint?.mcpConfig()
        let title = index.projects.first { $0.id == c.scope }?.title
        let cwd = ClaudeLaunch.workingDirectory(project: index.project(c.scope ?? ""), root: rootURL)
        var model = model(for: .voice)
        if model.isEmpty { model = "sonnet" }
        guard var launch = launch(prompt: VoicePrompt.system(project: c.scope, projectTitle: title),
                                  sessionID: UUID().uuidString.lowercased(), resume: false, model: model, cwd: cwd,
                                  tools: ClaudeLaunch.bridgeTools + MCPActions.allowedTools) else {
            c.emit(.error(claudeMissingExplanation))
            return
        }
        launch.mcpConfig = mcp
        launch.partialMessages = true
        launch.persist = false
        do {
            try c.chat.start(launch, mode: "voice")
            c.started = true
        } catch {
            c.emit(.error("Couldn't start the voice brain: \(error.localizedDescription)"))
        }
    }

    /// Says something in a conversation, starting its brain again if it stopped. Returns the turn's id.
    public func voiceSay(_ text: String, in c: VoiceConversation) async -> String {
        if !c.chat.isRunning { await bootVoiceBrain(c) }
        return c.say(text)
    }

    public func endVoiceConversation(_ id: String) {
        guard let c = voiceConversations.removeValue(forKey: id) else { return }
        c.interrupt()
        c.chat.stop()
        realtimeRelays[id]?.close()
        realtimeRelays[id] = nil
    }

    /// Actions the voice brain ran show as cards in the conversation that was talking.
    func forwardVoiceAction(_ name: String, _ channel: ActionChannel, _ result: ActionResult) {
        guard channel == .model || channel == .voice else { return }
        for c in voiceConversations.values where c.isBusy || c.engine == .api {
            c.emit(.action(name: name, status: "done", speech: result.speech, data: result.data))
        }
    }

    /// Connects a conversation to its realtime API; without a provider, key or wire it falls back to keyless and
    /// says so.
    public func startRealtime(_ c: VoiceConversation, keyWait: TimeInterval = 10, audioOut: @escaping (RealtimeRelay.Audio) -> Void) async {
        let prefs = VoicePreferences.load()
        guard let provider = prefs.provider, let wire = RealtimeWires.wire(for: provider) else {
            voiceFallBack(c, .badKey)
            return
        }
        let key: String
        switch await readVoiceKey(provider, wait: keyWait) {
        case .key(let k): key = k
        case .missing: voiceFallBack(c, .badKey); return
        case .locked: voiceFallBack(c, .keyLocked); return
        }
        guard voiceConversations[c.id] != nil else { return }
        let relay = RealtimeRelay(wire: wire, conversation: c, layer: actions,
                                  askBrain: { [weak self, weak c] request in
                                      guard let self, let c else { return "The brain isn't available." }
                                      return await self.askVoiceBrain(request, in: c)
                                  },
                                  audioOut: audioOut,
                                  onFail: { [weak self, weak c] reason, detail in
                                      guard let self, let c else { return }
                                      self.voiceFallBack(c, reason, detail: detail)
                                  })
        realtimeRelays[c.id] = relay
        let title = index.projects.first { $0.id == c.scope }?.title
        let instructions = RealtimeTools.instructions + (title.map { " The current project is \($0)." } ?? "")
        relay.connect(model: prefs.model(for: provider), key: key, voice: prefs.apiVoice(for: provider), instructions: instructions)
    }

    /// Live voice in a work session (`voice.start` with `session`): no brain of its own; the realtime model hands
    /// what the user says to the session and says its progress and answer. Without the API engine it can't start.
    /// With `new` instead of a session, the first thing handed over starts one (`voice.start` with `newSession`).
    public func startSessionVoice(_ s: WorkSession?, new: NewSessionPlan? = nil, keyWait: TimeInterval = 10,
                                  audioOut: @escaping (RealtimeRelay.Audio) -> Void) async throws -> VoiceConversation {
        let prefs = VoicePreferences.load()
        guard voiceEngineChoice.engine() == .api, let provider = prefs.provider, let wire = RealtimeWires.wire(for: provider) else {
            throw VoiceStartError("Live voice in a session needs a voice API key in Settings → Voice on the \(platform.machineWord).")
        }
        let key: String
        switch await readVoiceKey(provider, wait: keyWait) {
        case .key(let k): key = k
        case .missing:
            throw VoiceStartError("Live voice in a session needs a voice API key in Settings → Voice on the \(platform.machineWord).")
        case .locked:
            throw VoiceStartError(VoiceEngineChoice.fallbackMessage(.keyLocked, provider: RealtimeProvider.with(id: provider)?.name,
                                                                    machine: platform.machineWord))
        }
        let c = VoiceConversation(scope: s?.project ?? new?.project)
        c.engine = .api
        c.sessionID = s?.id
        c.newSession = s == nil ? new : nil
        c.started = true
        voiceConversations[c.id] = c
        let tools = RealtimeRelay.Tools(definitions: SessionVoice.tools) { [weak self, weak c] name, args in
            guard let self, let c else { return "The session is gone." }
            return await self.runSessionVoiceTool(name, args, conversation: c)
        }
        let relay = RealtimeRelay(wire: wire, conversation: c, layer: actions,
                                  askBrain: { _ in "Use send_to_session." },
                                  audioOut: audioOut,
                                  onFail: { [weak self, weak c] reason, detail in
                                      guard let self, let c else { return }
                                      self.voiceFallBack(c, reason, detail: detail)
                                  },
                                  tools: tools)
        realtimeRelays[c.id] = relay
        let project = c.scope.flatMap { p in index.projects.first { $0.id == p }?.title }
        relay.connect(model: prefs.model(for: provider), key: key, voice: prefs.apiVoice(for: provider),
                      instructions: SessionVoice.instructions(session: s?.title, project: project))
        return c
    }

    /// The tools of live voice in a session; for a new session, the first message starts it.
    func runSessionVoiceTool(_ name: String, _ args: JSONValue, conversation c: VoiceConversation) async -> String {
        let s = c.sessionID.flatMap { sessions.session($0) }
        switch name {
        case SessionVoice.send:
            let message = (args["message"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return "Nothing to send: ask the user what they want." }
            if let s {
                c.sessionFollower.begin(count: s.chat.items.count)
                sessions.send(SpokenReply.message(message), in: s, display: message)
                c.sessionFollower.markSent()
                return SessionVoice.sentResult
            }
            guard let plan = c.newSession else { return "The session is gone." }
            c.newSession = nil
            if plan.assistant { await sessions.prepareActionEndpoint() }
            c.sessionFollower.begin(count: 0)
            let started = sessions.newSession(title: nil, project: plan.project, message: SpokenReply.message(message), display: message,
                                              about: plan.assistant ? SessionRecord.assistantAbout : nil, show: false, space: plan.space)
            c.sessionID = started.id
            c.sessionFollower.markSent()
            c.emit(.sessionStarted(started.id))
            return SessionVoice.sentResult
        case SessionVoice.stop:
            c.sessionFollower.reset()
            guard let s, s.chat.isBusy else { return SessionVoice.idleResult }
            sessions.stop(s)
            return SessionVoice.stoppedResult
        default:
            return "There is no tool called \(name)."
        }
    }

    /// A session changed: the live voices in it say what it finished saying.
    func sessionVoiceChanged(_ s: WorkSession) {
        for c in voiceConversations.values where c.sessionID == s.id && c.sessionFollower.following {
            guard let relay = realtimeRelays[c.id] else { continue }
            let items = s.chat.items.map { SessionVoiceFollower.Item(role: $0.role.rawValue, text: $0.text) }
            for note in c.sessionFollower.update(items: items, busy: s.chat.isBusy) { relay.say(SessionVoice.prompt(note)) }
        }
    }

    private func voiceFallBack(_ c: VoiceConversation, _ reason: VoiceFailure, detail: String? = nil) {
        realtimeRelays[c.id]?.close()
        realtimeRelays[c.id] = nil
        c.apiFailed = true
        c.engine = .keyless
        let provider = RealtimeProvider.with(id: VoicePreferences.load().provider)?.name
        c.emit(.fallback(reason: reason, speech: VoiceEngineChoice.fallbackSpeech(reason),
                         message: VoiceEngineChoice.fallbackMessage(reason, provider: provider, machine: platform.machineWord, detail: detail)))
    }

    /// The realtime model's `ask_brain`: one turn of the conversation's Claude session, answered in text.
    public func askVoiceBrain(_ request: String, in c: VoiceConversation) async -> String {
        if !c.chat.isRunning { await bootVoiceBrain(c) }
        return await c.ask(request)
    }

    func registerVoiceMethods() {
        let m = methods
        m.register("voice.config") { [unowned self] _, _ in
            VoicePreferences.load().remoteConfig(engine: voiceEngineChoice.engine())
        }
        m.register("voice.start") { [unowned self] client, p in
            let id = p["session"]?.string
            let new: NewSessionPlan? = p["newSession"].flatMap { n in
                guard case .object = n else { return nil }
                return NewSessionPlan(space: n["space"]?.string == "build" ? .build : .plan, project: p["scope"]?.string ?? scope,
                                      assistant: n["assistant"]?.bool == true)
            }
            if id != nil || new != nil {
                sessions.loadIfNeeded()
                let s = id.flatMap { sessions.session($0) }
                if id != nil, s == nil { throw RemoteError.notFound("No such session") }
                var holder: VoiceConversation?
                let c: VoiceConversation
                do {
                    c = try await startSessionVoice(s, new: new, audioOut: { [weak client] audio in
                        guard let id = holder?.id else { return }
                        client?.sendBinary(RemoteFrame(header: ["kind": "voice", "conversation": .string(id), "format": "pcm24k",
                                                                "seq": .number(Double(audio.seq))], payload: audio.pcm).encoded())
                    })
                } catch {
                    throw RemoteError(code: "unavailable", message: error.localizedDescription)
                }
                holder = c
                c.owner = ObjectIdentifier(client)
                c.listen { [weak client] out in
                    guard let client, let (name, data) = out.remoteEvent(conversation: c.id) else { return }
                    client.send(.event(name: name, data: data))
                }
                var out: [String: JSONValue] = ["conversation": .string(c.id), "engine": .string(c.engine.rawValue),
                                                "session": s.map { .string($0.id) } ?? .null]
                if s == nil { out["newSession"] = true }
                return .object(out)
            }
            let force = p["engine"]?.string == VoiceEngineKind.keyless.rawValue
            let engine = voiceEngineChoice.engine(forceKeyless: force)
            let c = await startVoiceConversation(scope: p["scope"]?.string, engine: engine)
            guard c.started else {
                endVoiceConversation(c.id)
                throw RemoteError(code: "failed", message: claudeExecutable == nil ? claudeMissingExplanation : "Couldn't start the voice brain.")
            }
            c.owner = ObjectIdentifier(client)
            c.listen { [weak client] out in
                guard let client, let (name, data) = out.remoteEvent(conversation: c.id) else { return }
                client.send(.event(name: name, data: data))
            }
            if engine == .api {
                Task {
                    await startRealtime(c) { [weak client] audio in
                        client?.sendBinary(RemoteFrame(header: ["kind": "voice", "conversation": .string(c.id), "format": "pcm24k",
                                                                "seq": .number(Double(audio.seq))], payload: audio.pcm).encoded())
                    }
                }
            }
            return ["conversation": .string(c.id), "engine": .string(c.engine.rawValue)]
        }
        m.register("voice.say") { [unowned self] _, p in
            guard let c = p["conversation"]?.string.flatMap({ voiceConversations[$0] }), let text = p["text"]?.string, !text.isEmpty
            else { throw RemoteError.badParams("conversation and text") }
            return ["turn": .string(await voiceSay(text, in: c))]
        }
        m.register("voice.interrupt") { [unowned self] _, p in
            guard let c = p["conversation"]?.string.flatMap({ voiceConversations[$0] }) else { throw RemoteError.badParams("conversation") }
            c.interrupt()
            realtimeRelays[c.id]?.interrupt()
            return ["stopped": true]
        }
        m.register("voice.end") { [unowned self] _, p in
            if let id = p["conversation"]?.string { endVoiceConversation(id) }
            return ["ended": true]
        }
    }

    /// Binary frames from a client: voice audio for its own API-engine conversation here; other kinds (meeting
    /// screenshots, meeting audio) go to the host.
    func receivedBinary(_ data: Data, from client: RemoteClient) {
        guard let frame = RemoteFrame.decode(data) else { return }
        if frame.kind == "voice" {
            guard let id = frame.header["conversation"]?.string, let c = voiceConversations[id], c.owner == ObjectIdentifier(client)
            else { return }
            realtimeRelays[id]?.sendAudio(frame.payload, rate: Self.sampleRate(frame.header["format"]?.string))
            return
        }
        onBinaryFrame?(frame, client)
    }

    /// `pcm16k` (phones; also when a frame doesn't say) or `pcm24k` (the Windows shell).
    public static func sampleRate(_ format: String?) -> Double { format == "pcm24k" ? 24000 : 16000 }

    /// A client went away: end the conversations it was having, then let the host know.
    func clientClosed(_ client: RemoteClient) {
        for c in voiceConversations.values where c.owner == ObjectIdentifier(client) { endVoiceConversation(c.id) }
        onClientClosed?(client)
    }
}
