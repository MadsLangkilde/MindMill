import Foundation

/// One thing to test in a project, with how it's delivered.
public struct TestTarget: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var type: ProjectType
    /// The repository checkout (its scope's folder) and the folder in it.
    public var repo: String
    public var path: String
    public var title: String
    /// The chosen delivery method; nil until the user picks one.
    public var method: String?
    public var startCommand: String?
    public var buildCommand: String?
    public var testCommand: String?
    /// A local URL or port for web and backend targets.
    public var url: String?
    public var port: Int?
    /// Pages to open first (web), or endpoints to call (backend), one per line, e.g. `GET /health`.
    public var pages: [String] = []
    public var devices: [String] = []
    /// iOS: the scheme to build, and the App Store Connect key id and issuer for TestFlight (not the key itself).
    public var scheme: String?
    public var ascKeyID: String?
    public var ascIssuer: String?
    public var serialCommand: String?
    /// Checklist items only the user can tell, ticked.
    public var confirmed: [String] = []
    /// A module: the id of the app it belongs to.
    public var partOf: String?
    /// A module's last build and test.
    public var lastRun: ModuleRun?

    public init(id: String = UUID().uuidString.prefix(8).lowercased(), type: ProjectType, repo: String, path: String, title: String) {
        self.id = id
        self.type = type
        self.repo = repo
        self.path = path
        self.title = title
    }

    public init(_ d: DetectedTarget, repo: String, repoTitle: String) {
        self.init(id: Self.stableID(repo: repo, path: d.path, type: d.type), type: d.type, repo: repo, path: d.path,
                  title: d.path.isEmpty ? "\(repoTitle) · \(d.type.title)" : "\(d.path) · \(d.type.title)")
        startCommand = d.startCommand
        testCommand = d.testCommand
        if d.type == .android { buildCommand = d.startCommand; startCommand = nil }
        if let app = d.partOf {
            partOf = Self.stableID(repo: repo, path: app, type: d.type)
            title = d.name ?? d.path
            buildCommand = d.buildCommand
        }
    }

    static func stableID(repo: String, path: String, type: ProjectType) -> String {
        var h: UInt32 = 2166136261
        for b in "\(repo)|\(path)|\(type.rawValue)".utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return String(h, radix: 36)
    }

    public var adapter: any TestAdapter { TestAdapters.adapter(for: type) }

    public mutating func confirm(_ item: String, _ on: Bool) {
        confirmed.removeAll { $0 == item }
        if on { confirmed.append(item) }
    }

    /// Sets a field by the name a suggestion uses. Returns false for a name it doesn't know.
    @discardableResult
    public mutating func set(_ key: String, _ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let opt: String? = v.isEmpty ? nil : v
        switch key {
        case "method": method = opt
        case "start", "startCommand": startCommand = opt
        case "build", "buildCommand": buildCommand = opt
        case "test", "testCommand": testCommand = opt
        case "url": url = opt
        case "port": port = Int(v)
        case "pages", "endpoints": pages = v.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "devices": devices = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case "scheme": scheme = opt
        case "serial", "serialCommand": serialCommand = opt
        default: return false
        }
        return true
    }
}

public enum DeliverWhen: String, Codable, CaseIterable, Sendable {
    case everyCheckpoint, whenTestsPass, onRequest

    public var title: String {
        switch self {
        case .everyCheckpoint: return "At every checkpoint"
        case .whenTestsPass: return "When the tests pass"
        case .onRequest: return "Only when I ask"
        }
    }
}

/// A change to the test set-up that a session suggested, waiting for the user.
public struct TestSuggestion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var target: String?
    public var set: [String: String]
    public var from: String
    public var created: Date

    public init(id: String = UUID().uuidString.prefix(8).lowercased(), text: String, target: String? = nil, set: [String: String] = [:],
                from: String = "cli", created: Date = Date()) {
        self.id = id
        self.text = text
        self.target = target
        self.set = set
        self.from = from
        self.created = created
    }

    /// From a queued order: `{"kind": "test_suggest", "scope", "text", "target"?, "set"?: {}, "from"}`.
    public static func parse(_ data: Data) -> (scope: String, suggestion: TestSuggestion)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["kind"] as? String == "test_suggest",
              let scope = (obj["scope"] as? String)?.trimmingCharacters(in: .whitespaces), !scope.isEmpty,
              let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let set = (obj["set"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        let target = (obj["target"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (scope, TestSuggestion(text: text, target: target, set: set, from: obj["from"] as? String ?? "cli"))
    }
}

/// The result of asking the AI whether this Mac can build, run and test the project.
public struct CompatibilityResult: Codable, Equatable, Sendable {
    public struct Finding: Codable, Equatable, Sendable, Identifiable {
        public var title: String
        public var detail: String
        /// What the user can still do here, e.g. write the code.
        public var canStill: String
        /// What can't be done on this Mac.
        public var cannot: String
        /// How to install what's missing, when that fixes it.
        public var fix: String?
        public var id: String { title }

        public init(title: String, detail: String, canStill: String, cannot: String, fix: String? = nil) {
            self.title = title
            self.detail = detail
            self.canStill = canStill
            self.cannot = cannot
            self.fix = fix
        }
    }

    public var checked: Date
    public var findings: [Finding]
    public var fingerprint: String

    public var good: Bool { findings.isEmpty }

    public init(checked: Date, findings: [Finding], fingerprint: String) {
        self.checked = checked
        self.findings = findings
        self.fingerprint = fingerprint
    }
}

/// A module's last build and test: when, whether it built, and the tests' totals.
public struct ModuleRun: Codable, Equatable, Sendable {
    public var at: Date
    public var built: Bool
    public var tests: TestRunSummary?

    public init(at: Date = Date(), built: Bool, tests: TestRunSummary?) {
        self.at = at
        self.built = built
        self.tests = tests
    }

    public var ok: Bool { built && tests?.ok != false }
}

/// Everything about testing one scope (project).
public struct ScopeTestPlan: Codable, Equatable, Sendable {
    /// The apps, sites, services and firmware, each delivered on its own.
    public var targets: [TestTarget] = []
    /// The apps' modules, built and tested on their own (`partOf` names the app).
    public var modules: [TestTarget] = []
    public var deliverWhen: DeliverWhen = .everyCheckpoint
    /// "Don't ask for this project": no more prompts from sessions and factories.
    public var dontAsk = false
    public var suggestions: [TestSuggestion] = []
    public var compatibility: CompatibilityResult?
    /// The `ProjectDetector.version` that found the targets: an older one looks again once.
    public var detectorVersion = 0

    public init() {}

    enum CodingKeys: String, CodingKey { case targets, modules, deliverWhen, dontAsk, suggestions, compatibility, detectorVersion }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targets = try c.decodeIfPresent([TestTarget].self, forKey: .targets) ?? []
        modules = try c.decodeIfPresent([TestTarget].self, forKey: .modules) ?? []
        deliverWhen = try c.decodeIfPresent(DeliverWhen.self, forKey: .deliverWhen) ?? .everyCheckpoint
        dontAsk = try c.decodeIfPresent(Bool.self, forKey: .dontAsk) ?? false
        suggestions = try c.decodeIfPresent([TestSuggestion].self, forKey: .suggestions) ?? []
        compatibility = try c.decodeIfPresent(CompatibilityResult.self, forKey: .compatibility)
        detectorVersion = try c.decodeIfPresent(Int.self, forKey: .detectorVersion) ?? 0
    }

    public func modules(of app: String) -> [TestTarget] { modules.filter { $0.partOf == app } }

    /// Set up: at least one target and every target has a method.
    public var isSetUp: Bool { !targets.isEmpty && targets.allSatisfy { $0.method != nil } }

    public func target(_ id: String?) -> TestTarget? { targets.first { $0.id == id } }

    /// Applies a suggestion's changes and drops it. Returns false when it no longer applies.
    @discardableResult
    public mutating func accept(_ id: String) -> Bool {
        guard let i = suggestions.firstIndex(where: { $0.id == id }) else { return false }
        let s = suggestions.remove(at: i)
        if s.set["deliverWhen"].flatMap(DeliverWhen.init(rawValue:)) != nil { deliverWhen = DeliverWhen(rawValue: s.set["deliverWhen"]!)! }
        let fields = s.set.filter { $0.key != "deliverWhen" }
        guard !fields.isEmpty else { return true }
        guard let t = targets.firstIndex(where: { $0.id == s.target }) ?? (targets.count == 1 ? 0 : nil) else { return false }
        for (k, v) in fields { targets[t].set(k, v) }
        return true
    }

    public mutating func dismiss(_ id: String) {
        suggestions.removeAll { $0.id == id }
    }

    /// Merges newly detected targets in: known ones keep their settings, new ones are added, gone ones stay
    /// unless they were never set up.
    public mutating func merge(detected: [TestTarget]) {
        let apps = detected.filter { $0.partOf == nil }
        let ids = Set(apps.map(\.id))
        for d in apps where !targets.contains(where: { $0.id == d.id }) {
            // The same app found in another folder of its repository (as when detection learnt where a Gradle
            // build's root is): it takes the folder and the commands found there and keeps what the user set up.
            if let i = targets.firstIndex(where: { !ids.contains($0.id) && $0.repo == d.repo && $0.type == d.type && $0.partOf == nil }) {
                var moved = d
                let old = targets[i]
                moved.method = old.method
                moved.url = old.url
                moved.port = old.port
                moved.pages = old.pages
                moved.devices = old.devices
                moved.scheme = old.scheme
                moved.ascKeyID = old.ascKeyID
                moved.ascIssuer = old.ascIssuer
                moved.serialCommand = old.serialCommand
                moved.confirmed = old.confirmed
                targets[i] = moved
            } else {
                targets.append(d)
            }
        }
        targets.removeAll { !ids.contains($0.id) && $0.method == nil }
        detectorVersion = ProjectDetector.version
        let known = modules
        modules = detected.filter { $0.partOf != nil }.map { m in known.first { $0.id == m.id } ?? m }
    }

    /// The compatibility check should run again: never ran, or the targets or the Mac's tools changed.
    public func needsCompatibilityCheck(fingerprint: String) -> Bool {
        compatibility?.fingerprint != fingerprint
    }

    public func compatibilityFingerprint(_ facts: TestEnvironmentFacts) -> String {
        (targets.map { "\($0.type.rawValue):\($0.path)" }.sorted() + [facts.fingerprint]).joined(separator: ";")
    }
}

/// The Test menu's file: one plan per scope.
public struct TestStore: Codable, Equatable, Sendable {
    public var scopes: [String: ScopeTestPlan] = [:]

    public init() {}

    public static var defaultURL: URL {
        AppPaths.instanceFile("testing.json")
    }

    public static func load(_ url: URL = defaultURL) -> TestStore {
        guard let data = try? Data(contentsOf: url) else { return TestStore() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(TestStore.self, from: data)) ?? TestStore()
    }

    public func save(_ url: URL = defaultURL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? e.encode(self) { try? data.write(to: url, options: .atomic) }
    }

    public subscript(scope: String) -> ScopeTestPlan {
        get { scopes[scope] ?? ScopeTestPlan() }
        set { scopes[scope] = newValue }
    }
}

/// The words of the "Try it?" question under a Build session, for the kind of project and the phones paired.
public enum TestAskText {
    /// The platform a project's builds install on: Android phones for an Android app, iPhones for an iOS app.
    public static func platform(_ type: ProjectType?) -> String? {
        switch type {
        case .android?: return RemotePlatform.android
        case .ios?: return RemotePlatform.ios
        default: return nil
        }
    }

    /// "an Android phone" / "the Android phone", "an iPhone" / "the iPhone", "a phone" / "the phone".
    public static func phoneName(_ platform: String?) -> (article: String, the: String) {
        switch platform {
        case RemotePlatform.android?: return ("an Android phone", "the Android phone")
        case RemotePlatform.ios?: return ("an iPhone", "the iPhone")
        default: return ("a phone", "the phone")
        }
    }

    public static func question(_ type: ProjectType?) -> String {
        switch type {
        case .android?: return "Try what this session builds on your Android phone?"
        case .ios?: return "Try what this session builds on your iPhone?"
        case .web?: return "Try what this session builds on your phone?"
        case .backend?: return "See this session's test results on your phone?"
        case .desktopMac?, .desktopWindows?: return "Try what this session builds?"
        default: return "Set up testing for what this session builds?"
        }
    }

    /// The line under the question: which phone builds reach, or that none that can take them is paired yet.
    public static func detail(_ type: ProjectType?, facts: TestEnvironmentFacts) -> String {
        let platform = platform(type)
        let once = "Set up testing\(type.map { " for this \($0.title.lowercased())" } ?? "") once"
        switch type {
        case .desktopMac?, .desktopWindows?, .embedded?, .unknown?, nil:
            return once + ", and each checkpoint is built for you to try."
        case .ios?:
            // iPhone builds install through Xcode's tools or TestFlight; Mindmill on the iPhone isn't needed.
            return once + ", and builds reach your iPhone at each checkpoint."
        default:
            let phones = facts.phones(for: platform).map(\.name)
            let kind = platform == RemotePlatform.android ? "Android phone" : "phone"
            if !facts.phonePaired(platform) {
                return once + ". No \(kind) has Mindmill paired yet; setting up shows how."
            }
            let target = phones.isEmpty ? "your \(kind)" : phones.count == 1 ? phones[0]
                : phones.dropLast().joined(separator: ", ") + " and " + phones[phones.count - 1]
            return once + ", and builds reach \(target) at each checkpoint."
        }
    }
}

/// Whether to ask "Set up testing?" in a session or factory: not once it's set up, not after "Don't ask for this
/// project", and not again in this run of the app after "Not now".
public struct TestAsk: Equatable, Sendable {
    public private(set) var notNow: Set<String> = []

    public init() {}

    public func shouldAsk(scope: String, plan: ScopeTestPlan) -> Bool {
        !plan.isSetUp && !plan.dontAsk && !notNow.contains(scope)
    }

    public mutating func notNow(_ scope: String) { notNow.insert(scope) }

    public static func dontAsk(_ plan: inout ScopeTestPlan) { plan.dontAsk = true }
}

/// The verification step: the AI gets the facts about this Mac and the project's targets and reports only what
/// blocks building, running or testing here.
public enum CompatibilityCheck {
    public static let system = """
    You check whether a software project can be built, run and tested on the user's current computer. You get facts \
    about the machine (OS and version, CPU architecture, GPU, installed toolchains and SDKs with versions, devices and \
    emulators) and the project's targets. Reason about it yourself; there are no rules to follow.

    Report ONLY critical findings: hard limitations that make it impossible to build, run or test a target on this \
    machine (for example, building an iOS app needs macOS with Xcode, so it can't be done on Windows), or a missing \
    required toolchain or SDK that stops the build (say how to install it). Ignore nitpicks, minor version \
    differences, optional tools, best-practice suggestions and anything that doesn't block the work. When in doubt, \
    it is not critical. Don't suggest workarounds for hard limitations.

    Answer with JSON only, no prose: {"critical": [{"title": "...", "detail": "one or two sentences", \
    "canStill": "what the user can still do on this machine", "cannot": "what they can't do here", "fix": "how to \
    install what's missing, or empty"}]}. An empty list means good to go.
    """

    public static func prompt(facts: TestEnvironmentFacts, targets: [TestTarget], description: String?) -> String {
        var lines = ["Machine:", facts.summary, "", "Project targets:"]
        for t in targets {
            lines.append("- \(t.type.title) in \(t.path.isEmpty ? "the repository root" : t.path)"
                         + (t.method.map { ", delivered by \(t.adapter.method($0)?.title ?? $0)" } ?? ""))
        }
        if let description, !description.isEmpty { lines += ["", "Project description: \(description)"] }
        return lines.joined(separator: "\n")
    }

    /// Reads the AI's answer; nil when it isn't the JSON asked for.
    public static func parse(_ reply: String, at date: Date = Date(), fingerprint: String) -> CompatibilityResult? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let list = obj["critical"] as? [[String: Any]] else { return nil }
        let findings = list.compactMap { f -> CompatibilityResult.Finding? in
            func s(_ k: String) -> String { (f[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !s("title").isEmpty else { return nil }
            return .init(title: s("title"), detail: s("detail"), canStill: s("canStill"), cannot: s("cannot"), fix: s("fix").isEmpty ? nil : s("fix"))
        }
        return CompatibilityResult(checked: date, findings: findings, fingerprint: fingerprint)
    }

    /// What Build sessions and factories are told, so they don't try what can't work here; nil when nothing blocks.
    public static func sessionNote(_ result: CompatibilityResult?) -> String? {
        guard let result, !result.good else { return nil }
        let items = result.findings.map { "- \($0.title): \($0.cannot.isEmpty ? $0.detail : $0.cannot)" }.joined(separator: "\n")
        return "This Mac can't do everything for this project (checked \(result.checked.formatted(date: .abbreviated, time: .shortened))):\n\(items)\nDon't attempt those steps here; do what can be done (e.g. write the code) and say what must happen elsewhere."
    }
}
