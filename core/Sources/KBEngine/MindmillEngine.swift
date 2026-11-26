import Foundation
import KBCore
import Observation

/// "Show this on screen" (`app.show`, a session to open). macOS: the app's window navigates; Windows: the engine
/// host sends `desktop.show` to the shell.
public protocol Presenter: AnyObject {
    @MainActor func show(screen: String, id: String?) throws
}

/// What the engine needs from the machine it runs on. The macOS app fills it with its own adapters; the Windows
/// engine host with Windows ones and the shell's services (docs/engine-host.md).
public struct EnginePlatform {
    /// For the user: "macOS", "Windows".
    public var name: String
    /// What the user calls this machine in a sentence: "Mac", "PC".
    public var machineWord: String
    public var tools: ToolLocating
    public var secrets: SecretStore
    public var transport: CompanionTransport
    public var defaults: UserDefaults
    /// The plugin folder `kb` and Claude Code sessions run from (read each time: Settings can change it).
    public var pluginRoot: () -> String
    public weak var presenter: Presenter?
    public var notifier: Notifier?
    public var speech: SpeechServices?
    /// The MCP endpoint the brain's sessions reach the actions through.
    public weak var actionEndpoint: ActionEndpoint?

    public init(name: String, machineWord: String, tools: ToolLocating = SystemTools(), secrets: SecretStore,
                transport: CompanionTransport, defaults: UserDefaults = .standard, pluginRoot: @escaping () -> String) {
        self.name = name
        self.machineWord = machineWord
        self.tools = tools
        self.secrets = secrets
        self.transport = transport
        self.defaults = defaults
        self.pluginRoot = pluginRoot
    }

    /// The message for something this platform can't do.
    public func unavailable(_ what: String) -> String { "\(what) isn't available on \(name) yet." }
}

/// Remote methods by name. The engine registers what it answers itself; a host adds the rest (the Mac app: meetings,
/// voice audio, test delivery). A method nobody registered is `unknown_method`; one a platform declines is
/// `unavailable`.
@MainActor
public final class RemoteMethods {
    public typealias Handler = @MainActor (RemoteClient, JSONValue) async throws -> JSONValue

    private var exact: [String: Handler] = [:]
    private var prefixHandlers: [String: (String) -> Handler] = [:]

    public init() {}

    public func register(_ method: String, _ handler: @escaping Handler) { exact[method] = handler }

    public func register(_ methods: [String], _ handler: @escaping (String) -> Handler) {
        for m in methods { exact[m] = handler(m) }
    }

    /// Every method starting with `prefix` that has no handler of its own (`voice.`, `meeting.`).
    public func register(prefix: String, _ handler: @escaping (String) -> Handler) {
        prefixHandlers[prefix] = handler
    }

    public func handles(_ method: String) -> Bool { handler(method) != nil }

    public func handler(_ method: String) -> Handler? {
        if let h = exact[method] { return h }
        let best = prefixHandlers.keys.filter { method.hasPrefix($0) }.max { $0.count < $1.count }
        return best.flatMap { prefixHandlers[$0]?(method) }
    }

    public var names: [String] { exact.keys.sorted() }
}

/// The engine: the knowledge base and its current scope, the `kb` CLI, the action layer and the companion hub, with
/// the remote API's methods. The macOS app owns one in process and observes it; on Windows the engine host
/// (`mindmill-engine`) owns it and the desktop shell is one more client of its hub.
@MainActor
@Observable
public final class MindmillEngine {
    public static let lastScopeKey = "lastProjectID"

    public private(set) var rootPath: String
    public private(set) var rootOverride: Bool
    public private(set) var index: KBIndex = .empty
    public private(set) var loadError: KBLoadError?
    /// Bumped on every reload.
    public private(set) var indexVersion = 0
    /// The current scope: what the user works on now. nil only when the knowledge base has no scopes.
    public var scope: String?
    /// `claude`, Python and the user's environment, once found.
    public var shell: LoginShell.Resolved?
    /// The brain and the model for each task (Settings → AI), saved in the platform's preferences.
    public var aiSetup: AISetup {
        didSet { aiSetup.save(defaults: platform.defaults) }
    }
    /// Spoken conversations by id, and the realtime relays of those on an API engine.
    public var voiceConversations: [String: VoiceConversation] = [:]
    @ObservationIgnored public var realtimeRelays: [String: RealtimeRelay] = [:]
    /// Binary frames the engine doesn't handle itself (meeting screenshots and audio), for the host.
    @ObservationIgnored public var onBinaryFrame: ((RemoteFrame, RemoteClient) -> Void)?
    /// A client's connection closed, after the engine ended its voice conversations.
    @ObservationIgnored public var onClientClosed: ((RemoteClient) -> Void)?
    /// Plan or Build, for a desktop shell (the Mac app keeps its own).
    public var mode = "plan"
    /// The last thing to tell the user in the shell's notice bar.
    public var notice: String?

    @ObservationIgnored public var platform: EnginePlatform
    @ObservationIgnored public let actions: ActionLayer
    @ObservationIgnored public let methods = RemoteMethods()
    public let remote: RemoteServer

    /// Called after every reload with whether the knowledge base loaded; the host refreshes what it derives from it.
    @ObservationIgnored public var onReload: [(Bool) -> Void] = []
    /// Something changed in the tracker (a work item was created or moved); the host refreshes its backlog.
    @ObservationIgnored public var onTrackerChanged: (() -> Void)?
    /// What the `settings.get`/`settings.set` desktop methods read and change; the host's preferences.
    @ObservationIgnored public var settings: (get: () -> JSONValue, set: (String, JSONValue) throws -> Void)?

    /// The user's names (typed in Settings, the tracker's "me"): whose follow-ups are whose.
    @ObservationIgnored public lazy var myNames: () -> [String] = { [unowned self] in
        [platform.defaults.string(forKey: "myName")?.trimmingCharacters(in: .whitespaces) ?? "", tracker.backlog?.me ?? "",
         tracker.myWork?.me ?? ""].filter { !$0.isEmpty }
    }
    /// What waits for the user now (sessions, factory questions), as `sessions.list` items, for the desktop shell.
    @ObservationIgnored public lazy var needsYouItems: () -> [JSONValue] = { [unowned self] in waitingSessionItems() }
    /// What `app.structure` can't work out from the knowledge base (sessions, factories, pull requests).
    @ObservationIgnored public lazy var structureExtras: (String?) -> StructureExtras = { [unowned self] scope in
        buildStructureExtras(scope: scope)
    }
    /// The factories as `factories.status` lists them.
    @ObservationIgnored public lazy var factoryStatus: () -> [JSONValue] = { [unowned self] in
        factories.loadIfNeeded()
        return factories.list.map(RemotePayloads.factory)
    }
    /// Something to tell the user (`report`): the host's notice bar or error alert.
    @ObservationIgnored public var onReport: ((String, Bool) -> Void)?
    /// What Build sessions and factory sessions are told about this machine's testing for a scope.
    @ObservationIgnored public lazy var testingNote: (String?) -> String = { [unowned self] scope in tests.sessionNote(scope) }
    /// `kb sync` of what only the host can sync (calendar, email): ok and a line, or nil when it can't.
    @ObservationIgnored public var syncSource: ((String, (from: String, to: String)?) async -> (Bool, String)?)?
    /// Plan or Build, as the user sees it now.
    @ObservationIgnored public lazy var currentMode: () -> String = { [unowned self] in mode }

    /// The Claude sessions, the crew and the overview session.
    @ObservationIgnored public private(set) lazy var sessions = SessionHub(engine: self)
    /// The trackers' work items, the user's work and pull requests.
    @ObservationIgnored public private(set) lazy var tracker = TrackerCache(engine: self)
    /// The software factories.
    @ObservationIgnored public private(set) lazy var factories = FactoryLoop(engine: self)
    /// Project scans.
    @ObservationIgnored public private(set) lazy var scans = ScanRunner(engine: self)
    /// Testing: targets, deliveries to the phone and review cards.
    @ObservationIgnored public private(set) lazy var tests = TestRunner(engine: self, folder: dataFolder)
    /// Each tracker's sprints and the sprint reviews.
    @ObservationIgnored public private(set) lazy var sprints = SprintCenter(engine: self, watchURL: dataFile("sprints.json"))
    /// Plan's work with state: fact links, the quiz, follow-up checks, goal coaches, people.
    @ObservationIgnored public private(set) lazy var plan = PlanCenter(engine: self)
    /// The calendar sync, the email scan and the morning routine.
    @ObservationIgnored public private(set) lazy var routines = RoutineCenter(engine: self)
    /// Backlog proposals and their duplicate checks.
    @ObservationIgnored public private(set) lazy var backlog = BacklogCenter(engine: self, verdictsURL: dataFile("duplicate-checks.json"))
    /// Where Build mode keeps its files when not in the data folder (`isolate(in:)`).
    @ObservationIgnored var dataFolder: URL?

    /// A file in the engine's data folder (the isolated one in tests and a second engine).
    public func dataFile(_ name: String) -> URL { (dataFolder ?? AppPaths.data).appendingPathComponent(name) }

    @ObservationIgnored var lastNeedsYou = ""
    @ObservationIgnored private var watcher: FileWatching?
    @ObservationIgnored private var teamWatchers: [FileWatching] = []
    @ObservationIgnored private var watchedTeamPaths: Set<String> = []

    public init(rootPath: String, rootOverride: Bool = false, platform: EnginePlatform,
                remoteFolder: URL = RemoteServer.defaultFolder) {
        self.rootPath = rootPath
        self.rootOverride = rootOverride
        self.platform = platform
        self.aiSetup = AISetup.migrated(defaults: platform.defaults)
        self.actions = ActionLayer()
        self.remote = RemoteServer(transport: platform.transport, folder: remoteFolder, defaults: platform.defaults)
        actions.unavailable = { [name = platform.name] action in "\(action) isn't available on \(name) yet." }
        remote.handle = { [weak self] client, method, params in
            guard let self else { return .null }
            return try await self.call(method, params, from: client)
        }
        remote.handleBinary = { [weak self] client, data in self?.receivedBinary(data, from: client) }
        remote.onClientClosed = { [weak self] client in self?.clientClosed(client) }
        actions.onRun = { [weak self] name, channel, result in self?.forwardVoiceAction(name, channel, result) }
        registerMethods()
        registerVoiceMethods()
        registerDesktopExtras()
        registerActions()
        registerBuildMethods()
        registerProjectMethods()
        TestRunner.register(on: self)
        registerBuildActions()
        registerSprintActions()
        registerBacklogActions()
        registerPlanActions()
        onTrackerChanged = { [weak self] in self?.tracker.refreshBacklog(force: true) }
        onReload.append { [weak self] _ in self?.tracker.kindCache = [:] }
        observeRemote()
    }

    /// The knowledge base a process starts on: `flag <path>` on the command line, else `KB_ROOT`, else kb's config.
    nonisolated public static func startRoot(arguments: [String] = ProcessInfo.processInfo.arguments,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 flags: [String] = ["--root"]) -> (path: String, override: Bool) {
        for flag in flags {
            if let i = arguments.firstIndex(of: flag), i + 1 < arguments.count { return (arguments[i + 1], true) }
        }
        if let env = environment["KB_ROOT"], !env.isEmpty { return (env, true) }
        return (KBConfig.loadRootPath(), false)
    }

    public var rootURL: URL { KBConfig.rootURL(for: rootPath) }

    public var pluginRootPath: String { platform.pluginRoot() }

    public var cli: KBCLI {
        KBCLI(pluginRoot: URL(fileURLWithPath: KBConfig.expandTilde(pluginRootPath)), kbRoot: rootURL,
              python: shell?.python3 ?? URL(fileURLWithPath: "/usr/bin/python3"), pythonArguments: shell?.python3Arguments ?? [],
              environment: withMe(shell?.environment ?? ProcessInfo.processInfo.environment))
    }

    public func claudeEnvironment() -> [String: String] {
        var env = withMe(shell?.environment ?? ProcessInfo.processInfo.environment)
        env["KB_ROOT"] = rootURL.path
        return env
    }

    /// `KB_ME`: who "me" is in Mindmill's own tracker, the same name the app assigns local work items to.
    private func withMe(_ env: [String: String]) -> [String: String] {
        var env = env
        if let me = sprints.workItemNames.first { env["KB_ME"] = me }
        return env
    }

    /// Finds `claude` and Python off the main thread, then calls `done`.
    public func resolveTools(_ done: @escaping @MainActor () -> Void = {}) {
        let tools = platform.tools
        Task.detached(priority: .userInitiated) {
            let resolved = tools.resolve()
            await MainActor.run { [weak self] in
                self?.shell = resolved
                done()
            }
        }
    }

    // MARK: The knowledge base

    public func reload() {
        var loaded = false
        do {
            index = try KBIndex.load(root: rootURL)
            loadError = nil
            loaded = true
            watchTeamFolders()
        } catch let error as KBLoadError {
            index = .empty
            loadError = error
        } catch {
            index = .empty
            loadError = .registryInvalid(error.localizedDescription)
        }
        if scope == nil || index.project(scope!) == nil {
            let remembered = platform.defaults.string(forKey: Self.lastScopeKey)
            scope = (remembered.flatMap { index.project($0) } ?? index.projects.first)?.id
        }
        indexVersion += 1
        for hook in onReload { hook(loaded) }
        if remote.isRunning || !remote.desktops.isEmpty { remote.broadcast("index.changed") }
    }

    /// Makes `id` the current scope and remembers it for the next start.
    @discardableResult
    public func selectScope(_ id: String) -> Bool {
        guard index.project(id) != nil else { return false }
        scope = id
        platform.defaults.set(id, forKey: Self.lastScopeKey)
        return true
    }

    /// Points the engine at another knowledge base and saves it in kb's config.
    public func changeRoot(to path: String, save: Bool = true) throws {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if save { try KBConfig.saveRootPath(trimmed) }
        rootPath = trimmed
        rootOverride = false
        scope = nil
    }

    /// Watches the knowledge base folder and every repository's `knowledgebase/` folder that exists.
    public func startWatching() {
        watcher?.stop()
        watcher = nil
        teamWatchers.forEach { $0.stop() }
        teamWatchers = []
        watchedTeamPaths = []
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        let w = FileWatchers.make(path: rootURL.path) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        if w.start() { watcher = w }
        watchTeamFolders()
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
        teamWatchers.forEach { $0.stop() }
        teamWatchers = []
        watchedTeamPaths = []
    }

    /// Repositories' team folders appear when the first team entry is written or a pull brings one; watch new ones.
    private func watchTeamFolders() {
        guard watcher != nil else { return }
        let layout = KBLayout.of(root: rootURL)
        let dirs = layout.checkouts.keys.compactMap { layout.teamDir($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let paths = Set(dirs.map(\.path))
        guard paths != watchedTeamPaths else { return }
        teamWatchers.forEach { $0.stop() }
        teamWatchers = paths.sorted().compactMap { path in
            let w = FileWatchers.make(path: path) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
            return w.start() ? w : nil
        }
        watchedTeamPaths = paths
    }

    // MARK: Remote calls

    /// Answers one remote-api request, from a phone or a desktop shell.
    public func call(_ method: String, _ params: JSONValue, from client: RemoteClient) async throws -> JSONValue {
        if let h = methods.handler(method) { return try await h(client, params) }
        if let feature = Self.platformFeature(of: method) {
            throw RemoteError.unavailable(platform.unavailable(feature))
        }
        throw RemoteError(code: "unknown_method", message: "Mindmill on this \(platform.machineWord) doesn't know \(method). Update it.")
    }

    /// Methods that belong to a feature some platforms don't have; without a handler they answer `unavailable`.
    public static func platformFeature(of method: String) -> String? {
        if method.hasPrefix("voice.") { return "Voice" }
        if method.hasPrefix("meeting.") { return "Meeting transcription" }
        if method.hasPrefix("test.") || method.hasPrefix("review.") || method == "preview.get" { return "Testing" }
        return nil
    }

    // MARK: Parameters

    /// The scope a call names (by id or title), else the current one.
    public func scopeParam(_ p: JSONValue) throws -> String {
        if let s = p["scope"]?.string, !s.isEmpty {
            if let match = index.projects.first(where: { $0.id == s || $0.title.lowercased() == s.lowercased() }) { return match.id }
            throw ActionError("I don't know the project \(s).")
        }
        guard let id = scope ?? index.projects.first?.id else { throw ActionError("Open a project first.") }
        return id
    }

    public func entryParam(_ p: JSONValue, _ key: String = "id") throws -> EntryID {
        guard let raw = p[key]?.string, let id = EntryID(raw) else { throw ActionError("That isn't an entry id.") }
        return id
    }
}
