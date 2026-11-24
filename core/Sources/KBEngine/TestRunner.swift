import Foundation
import KBCore

/// One delivery a platform adapter builds itself (on a Mac: an iPhone build with Xcode).
public struct TestJob {
    public var target: TestTarget
    public var kind: DeliveryKind
    public var delivery: TestDelivery
    /// The delivery's folder, for its files and screenshots.
    public var dir: URL
    /// The target's folder in its repository.
    public var cwd: URL
    public var facts: TestEnvironmentFacts
    /// Runs a command in `cwd` with the test environment and adds it to the log.
    public var run: (String, TimeInterval) async -> TestShell.Result
    /// Says what the delivery is doing now, for the Test menu.
    public var step: (String) -> Void
}

/// What came of a `TestJob`: the delivery as it ended, screenshots for the review card, or why it failed.
public struct TestJobResult {
    public var delivery: TestDelivery
    public var images: [(title: String, file: URL)] = []
    public var failure: String?

    public init(delivery: TestDelivery, images: [(title: String, file: URL)] = [], failure: String? = nil) {
        self.delivery = delivery
        self.images = images
        self.failure = failure
    }
}

/// What testing needs from the machine beyond a POSIX shell: the Mac's Xcode, `simctl`, `devicectl`, TestFlight and
/// WebKit. A platform without it (Windows) delivers Android, web, backend, embedded and desktop targets, and reports
/// iPhone builds as unavailable.
@MainActor
public protocol TestPlatform: AnyObject {
    /// The delivery kinds this adapter builds itself.
    var ownKinds: Set<DeliveryKind> { get }
    /// Everything this machine has for testing; nil to use the engine's portable look.
    func gatherFacts(environment: [String: String]) async -> TestEnvironmentFacts?
    func deliver(_ job: TestJob) async -> TestJobResult
    /// A screenshot of a web page, for a review card; nil when this machine can't take one.
    func snapshot(_ url: URL, into dir: URL, name: String) async -> URL?
}

/// Testing in the engine: what each scope's repositories build (targets), what this machine can do with them, and
/// deliveries to the phone with review cards. `TestCenter` holds the state; this does the work.
@MainActor
public final class TestRunner {
    /// Kinds only a Mac can build.
    public static let appleKinds: Set<DeliveryKind> = [.iosDevice, .iosLink, .testflight]

    /// The Test menu's state. `isolate(in:)` replaces it before first use.
    public internal(set) var center: TestCenter
    /// The machine's own testing powers; nil: the portable ones only.
    public weak var platform: TestPlatform?
    /// A session or factory reached a checkpoint, and testing isn't set up: the host offers it under the session.
    public var onAskToSetUp: ((WorkSession) -> Void)?

    unowned let engine: MindmillEngine

    init(engine: MindmillEngine, folder: URL? = nil) {
        self.engine = engine
        center = folder.map { TestCenter(root: $0.appendingPathComponent("deliveries"), storeURL: $0.appendingPathComponent("testing.json")) }
            ?? TestCenter()
    }

    var remote: RemoteServer { engine.remote }

    /// The environment test commands run with: the user's, with the Android SDK's tools on the PATH.
    public var environment: [String: String] {
        var env = engine.shell?.environment ?? ProcessInfo.processInfo.environment
        #if os(Windows)
        let fallback = (env["LOCALAPPDATA"] ?? NSHomeDirectory() + #"\AppData\Local"#) + #"\Android\Sdk"#
        let sdk = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] ?? fallback
        env["ANDROID_HOME"] = sdk
        env["PATH"] = (env["PATH"] ?? "") + ";\(sdk)\\platform-tools;\(sdk)\\emulator"
        #else
        let sdk = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] ?? (NSHomeDirectory() + "/Library/Android/sdk")
        env["ANDROID_HOME"] = sdk
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":\(sdk)/platform-tools:\(sdk)/emulator:/Applications/Tailscale.app/Contents/MacOS"
        #endif
        return env
    }

    // MARK: What this machine has

    /// Looks at the toolchains, devices and network. Takes a few seconds; runs in the background.
    public func gatherFacts() async {
        guard !center.gathering else { return }
        center.gathering = true
        defer { center.gathering = false }
        let env = environment
        var f: TestEnvironmentFacts
        if let own = await platform?.gatherFacts(environment: env) { f = own } else { f = await portableFacts(env) }
        f.companionConnected = !remote.connected.isEmpty
        f.companionPaired = !remote.devices.devices.isEmpty
        f.phones = remote.devices.devices.map { .init(name: $0.name, platform: $0.platform) }
        f.gathered = Date()
        center.facts = f
    }

    /// What every platform can look at through a shell: toolchains, Android devices, Tailscale, the network.
    func portableFacts(_ env: [String: String]) async -> TestEnvironmentFacts {
        func sh(_ cmd: String, timeout: TimeInterval = 20) async -> String? {
            let r = await TestShell.run(cmd, environment: env, timeout: timeout)
            let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.code == 0 && !out.isEmpty ? out : nil
        }
        func first(_ s: String?) -> String? { s?.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) }
        var f = TestEnvironmentFacts()
        f.os = engine.platform.name
        f.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        f.arch = await sh("uname -m") ?? ""
        var tools: [String: String] = [:]
        let sdk = env["ANDROID_HOME"] ?? ""
        let platforms = URL(fileURLWithPath: sdk).appendingPathComponent("platforms").path
        if FileManager.default.fileExists(atPath: platforms) {
            tools["android-sdk"] = ((try? FileManager.default.contentsOfDirectory(atPath: platforms)) ?? []).sorted().last ?? "installed"
        }
        let probes: [(String, String)] = [
            ("swift", "swift --version"), ("java", "java -version"), ("gradle", "command -v gradle"), ("node", "node --version"),
            ("npm", "npm --version"), ("pnpm", "pnpm --version"), ("python3", "python3 --version"), ("go", "go version"),
            ("cargo", "cargo --version"), ("dotnet", "dotnet --version"), ("docker", "docker --version"),
            ("platformio", "pio --version"), ("idf.py", "command -v idf.py"), ("west", "west --version"), ("adb", "adb version"),
            ("arm-none-eabi-gcc", "arm-none-eabi-gcc --version"), ("cmake", "cmake --version"), ("tailscale", "tailscale version"),
            ("flutter", "flutter --version --machine 2>/dev/null | head -c 200"), ("msbuild", "command -v msbuild"),
        ]
        for (name, cmd) in probes {
            if let x = await sh(cmd + " 2>&1", timeout: 10) {
                tools[name] = ["gradle", "idf.py", "msbuild"].contains(name) ? "installed" : first(x)
            }
        }
        f.toolchains = tools
        if tools["adb"] != nil, let x = await sh("adb devices -l") { f.devices = Self.androidDevices(x) }
        if let x = await sh("tailscale status --json 2>/dev/null", timeout: 10) { Self.readTailscale(x, into: &f) }
        f.lanIP = RemoteAddresses.interfaceIPs().first(where: RemoteAddresses.isPrivateLAN)
        if f.lanIP == nil { f.lanIP = await engine.platform.transport.addresses().addresses.first(where: RemoteAddresses.isPrivateLAN) }
        return f
    }

    /// `adb devices -l`'s phones and emulators.
    public static func androidDevices(_ output: String) -> [TestEnvironmentFacts.Device] {
        output.components(separatedBy: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ").map(String.init)
            guard let serial = parts.first, parts.count > 1 else { return nil }
            let name = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) } ?? serial
            return .init(id: serial, name: name, kind: serial.hasPrefix("emulator-") ? .androidEmulator : .android,
                         paired: parts[1] == "device", booted: parts[1] == "device")
        }
    }

    /// `tailscale status --json`: whether it runs, this machine's name and address, and HTTPS certificates.
    public static func readTailscale(_ json: String, into f: inout TestEnvironmentFacts) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        f.tailscaleRunning = obj["BackendState"] as? String == "Running"
        let me = obj["Self"] as? [String: Any] ?? [:]
        f.tailscaleName = (me["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.flatMap { $0.isEmpty ? nil : $0 }
        f.tailscaleIP = (me["TailscaleIPs"] as? [String])?.first { !$0.contains(":") }
        f.tailscaleHTTPS = !((obj["CertDomains"] as? [String]) ?? []).isEmpty
    }

    /// The facts, with the phone's connection as it is now.
    public var currentFacts: TestEnvironmentFacts {
        var f = center.facts
        f.companionConnected = !remote.connected.isEmpty
        f.companionPaired = !remote.devices.devices.isEmpty
        f.phones = remote.devices.devices.map { .init(name: $0.name, platform: $0.platform) }
        return f
    }

    // MARK: Targets

    /// Finds what the scope's repositories build and merges it into its plan.
    public func detectTargets(_ scope: String) {
        var detected: [TestTarget] = []
        for repo in ScopeRepositories.of(scope, in: engine.index).work {
            guard let checkout = repo.checkout else { continue }
            let listing = RepoListing.scan(checkout)
            for d in ProjectDetector.detect(listing) {
                let t = TestTarget(d, repo: checkout.path, repoTitle: repo.title)
                center.listings[t.id] = listing
                detected.append(t)
            }
        }
        center.edit(scope) { $0.merge(detected: detected) }
    }

    public func directory(_ t: TestTarget) -> URL {
        let repo = URL(fileURLWithPath: t.repo)
        return t.path.isEmpty ? repo : repo.appendingPathComponent(t.path)
    }

    public func context(_ t: TestTarget) -> TestContext {
        let listing = center.listings[t.id] ?? {
            let l = RepoListing.scan(directory(t), depth: 2)
            center.listings[t.id] = l
            return l
        }()
        return TestContext(facts: currentFacts, target: t, listing: listing)
    }

    public func checklist(_ t: TestTarget, method: String? = nil) -> [ChecklistItem] {
        let m = method ?? t.method ?? t.adapter.recommended(currentFacts)
        return TestAdapters.checklist(type: t.type, method: m, context(t))
    }

    public func ready(_ t: TestTarget) -> Bool {
        t.method != nil && ChecklistItem.ready(checklist(t)) && unavailable(t) == nil
    }

    /// Why this machine can't deliver the target as its method says, or nil when it can.
    public func unavailable(_ t: TestTarget, method: String? = nil) -> String? {
        let id = method ?? t.method ?? t.adapter.recommended(currentFacts)
        let kind = (t.adapter.method(id) ?? TestAdapters.preview).kind
        let compatibility = center.store.scopes.values.first { $0.targets.contains { $0.id == t.id } }?.compatibility
        return Self.unsupported(kind: kind, own: platform?.ownKinds ?? [], machine: engine.platform.machineWord,
                                compatibility: compatibility)
    }

    /// Why a delivery kind can't be built here: Apple builds need a Mac's adapter. The compatibility check's
    /// finding says more when it has one.
    public static func unsupported(kind: DeliveryKind, own: Set<DeliveryKind>, machine: String,
                                   compatibility: CompatibilityResult?) -> String? {
        guard appleKinds.contains(kind), !own.contains(kind) else { return nil }
        var text = "iPhone builds need a Mac with Xcode; this \(machine) can't build, install or upload them."
        if let finding = compatibility?.findings.first(where: { !$0.cannot.isEmpty }) {
            text += " \(finding.title): \(finding.cannot)"
            if !finding.canStill.isEmpty { text += " It can still: \(finding.canStill)" }
        }
        return text
    }

    // MARK: Compatibility check

    public func projectDescription(_ scope: String) -> String? {
        let overview = engine.index.entries[EntryID(project: scope, section: .overview, stem: "overview")]
        let text = [engine.index.project(scope)?.title, overview?.summary].compactMap { $0 }.filter { !$0.isEmpty }
        return text.isEmpty ? nil : text.joined(separator: ": ")
    }

    /// Asks the brain whether this machine can build, run and test the scope's targets. `force` runs it even when
    /// nothing changed since the last check.
    public func runCompatibilityCheck(_ scope: String, force: Bool = false) async {
        guard !center.checking.contains(scope) else { return }
        if center.facts.gathered == nil { await gatherFacts() }
        if center.store[scope].targets.isEmpty { detectTargets(scope) }
        let plan = center.store[scope]
        let fingerprint = plan.compatibilityFingerprint(center.facts)
        guard force || plan.needsCompatibilityCheck(fingerprint: fingerprint), engine.claudeExecutable != nil else { return }
        center.checking.insert(scope)
        defer { center.checking.remove(scope) }
        let prompt = CompatibilityCheck.prompt(facts: center.facts, targets: plan.targets, description: projectDescription(scope))
        var model = engine.model(for: .background)
        if model.isEmpty { model = "sonnet" }
        guard let reply = await engine.claudeOnce(prompt, system: CompatibilityCheck.system, model: model, timeout: 180),
              let result = CompatibilityCheck.parse(reply, fingerprint: fingerprint) else { return }
        center.edit(scope) { $0.compatibility = result }
    }

    /// A project was opened or set up: detect its targets, and check compatibility when they or this machine changed.
    public func projectOpened(_ scope: String) {
        Task {
            if center.facts.gathered == nil { await gatherFacts() }
            detectTargets(scope)
            await runCompatibilityCheck(scope)
        }
    }

    /// New scopes (onboarding's first project, or one set up later) get their check as soon as they exist.
    public func scopesChanged() {
        let key = "testSeenScopes"
        let defaults = engine.platform.defaults
        let current = Set(engine.index.projects.filter { !$0.wide }.map(\.id))
        guard let seen = defaults.stringArray(forKey: key) else {
            defaults.set(Array(current), forKey: key)
            return
        }
        let new = current.subtracting(seen)
        guard !new.isEmpty else { return }
        defaults.set(Array(current.union(seen)), forKey: key)
        for id in new where !ScopeRepositories.of(id, in: engine.index).work.compactMap(\.checkout).isEmpty { projectOpened(id) }
    }

    /// What Build sessions and factory sessions are told about this machine's limits for the scope.
    public func sessionNote(_ scope: String?) -> String {
        guard let scope else { return "" }
        let plan = center.store[scope]
        var parts: [String] = []
        if let note = CompatibilityCheck.sessionNote(plan.compatibility) { parts.append(note) }
        if plan.isSetUp {
            let how = plan.targets.compactMap { t in t.method.flatMap { t.adapter.method($0) }.map { "\(t.title): \($0.title)" } }
            parts.append("Testing is set up in Mindmill (\(how.joined(separator: "; "))); builds are delivered to the user's phone at checkpoints, so don't set that up yourself. To suggest a change to the test set-up, run `kb test suggest --scope \(scope) --text '<what and why>'`.")
        }
        return parts.isEmpty ? "" : "\n" + parts.joined(separator: "\n")
    }

    // MARK: Sessions and factories

    /// A session finished a turn: deliver when the plan says every checkpoint and it changed files, at most every
    /// 15 minutes per session.
    public func afterTurn(_ s: WorkSession) {
        guard s.space == .build, let scope = s.project, s.editedFiles else { return }
        let plan = center.store[scope]
        guard plan.isSetUp, plan.deliverWhen != .onRequest else { return }
        if let last = center.lastAutoDelivery[s.id], Date().timeIntervalSince(last) < 900 { return }
        center.lastAutoDelivery[s.id] = Date()
        for t in plan.targets where ready(t) {
            Task { await deliver(scope: scope, targetID: t.id, session: s.id) }
        }
    }

    /// A factory session reached a checkpoint where testing makes sense.
    public func checkpoint(sessionID: String, checkpoint: String?) {
        guard let s = engine.sessions.session(sessionID), let scope = s.project else { return }
        let plan = center.store[scope]
        let worth: Set<String> = [FactoryCheckpoint.testsFailing.rawValue, FactoryCheckpoint.beforePR.rawValue,
                                  FactoryCheckpoint.beforeComplete.rawValue, "done"]
        guard let checkpoint, worth.contains(checkpoint) else { return }
        if !plan.isSetUp {
            if center.ask.shouldAsk(scope: scope, plan: plan) { onAskToSetUp?(s) }
            return
        }
        guard plan.deliverWhen != .onRequest else { return }
        let factory = engine.factories.list.first { $0.run?.task(session: sessionID) != nil }
        let item = factory?.run?.task(session: sessionID)?.workItem
        for t in plan.targets where ready(t) {
            Task { await deliver(scope: scope, targetID: t.id, session: sessionID, factory: factory?.id, workItem: item) }
        }
    }

    /// `kb test suggest` from a session.
    public func suggested(_ data: Data) -> Bool {
        guard let (scope, suggestion) = TestSuggestion.parse(data) else { return false }
        center.edit(scope) { $0.suggestions.append(suggestion) }
        engine.report("A session suggested a change to testing. See Test in Build.")
        return true
    }

    // MARK: Delivering

    /// Builds, tests and delivers one target as its method says, then sends the phone a review card.
    @discardableResult
    public func deliver(scope: String, targetID: String, session: String? = nil, factory: String? = nil, workItem: Int? = nil) async -> TestDelivery? {
        guard let t = center.store[scope].target(targetID), center.working[targetID] == nil else { return nil }
        if center.facts.gathered == nil { await gatherFacts() }
        let methodID = t.method ?? t.adapter.recommended(currentFacts)
        let method = t.adapter.method(methodID) ?? TestAdapters.preview
        var d = TestDelivery(scope: scope, target: t.id, kind: method.kind, title: t.title)
        d.session = session
        center.update(d)
        let dir = center.folder(d.id)
        let cwd = directory(t)
        let env = environment
        var log = ""
        func step(_ what: String) { center.working[targetID] = what }
        func run(_ cmd: String, timeout: TimeInterval = 1800) async -> TestShell.Result {
            let r = await TestShell.run(cmd, cwd: cwd, environment: env, timeout: timeout)
            log += "$ \(cmd)\n\(r.output)\n"
            return r
        }
        defer {
            center.working[targetID] = nil
            center.logs[targetID] = String(log.suffix(60000))
        }
        if let why = unavailable(t, method: methodID) { return failed(&d, why) }

        var tests: TestRunSummary?
        if let cmd = t.testCommand, !cmd.isEmpty, method.kind != .preview {
            step("Running the tests…")
            let r = await run(cmd)
            tests = TestRunSummary.parse(r.output, exitCode: r.code)
            if center.store[scope].deliverWhen == .whenTestsPass, tests?.ok == false {
                d.state = .failed
                d.message = "The tests failed, so nothing was delivered."
                center.update(d)
                await sendReviewCard(scope: scope, target: t, delivery: nil, tests: tests, images: [], session: session,
                                     factory: factory, workItem: workItem, note: d.message)
                return d
            }
        }

        var images: [(title: String, file: URL)] = []
        switch method.kind {
        case .apk:
            step("Building the APK…")
            let started = Date()
            let r = await run(t.buildCommand ?? (FileManager.default.fileExists(atPath: cwd.appendingPathComponent("gradlew").path) ? "./gradlew assembleDebug" : "gradle assembleDebug"))
            guard r.code == 0, let apk = Self.newestFile(in: cwd, suffix: ".apk", after: started) else {
                return failed(&d, "The build failed. See the log in Test.")
            }
            let dest = dir.appendingPathComponent(apk.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: apk, to: dest)
            guard let data = try? Data(contentsOf: dest) else { return failed(&d, "Couldn't read the APK.") }
            d.file = dest.lastPathComponent
            d.size = data.count
            d.sha256 = DeliveryFiles.sha256(data)
            if let emulator = currentFacts.devices.first(where: { $0.kind == .androidEmulator && $0.booted }) {
                step("Taking screenshots on the emulator…")
                if let shot = await androidScreenshot(apk: dest, serial: emulator.id, into: dir) { images.append(("App", shot)) }
            }

        case .url:
            step("Starting the dev server…")
            guard let port = await ensureDevServer(t) else {
                log += center.serverOutput[t.id] ?? ""
                return failed(&d, "The dev server didn't start. Check the start command.")
            }
            let f = currentFacts
            let host = f.tailscaleName ?? f.tailscaleIP ?? f.lanIP ?? "localhost"
            let page = t.pages.first.map { $0.hasPrefix("/") ? $0 : "/" + $0 } ?? "/"
            d.url = "http://\(host):\(port)\(page)"
            if let platform {
                step("Taking a screenshot…")
                for (i, p) in (t.pages.isEmpty ? ["/"] : Array(t.pages.prefix(3))).enumerated() {
                    let path = p.hasPrefix("/") ? p : "/" + p
                    if let url = URL(string: "http://localhost:\(port)\(path)"),
                       let shot = await platform.snapshot(url, into: dir, name: "page\(i).png") {
                        images.append((path == "/" ? "Home" : path, shot))
                    }
                }
            }

        case .preview:
            step("Running the tests…")
            await buildPreview(t, dir: dir, run: { await run($0, timeout: $1) }, tests: &tests)

        case .iosDevice, .iosLink, .testflight:
            guard let platform else { return failed(&d, unavailable(t, method: methodID) ?? "This machine can't build it.") }
            let job = TestJob(target: t, kind: method.kind, delivery: d, dir: dir, cwd: cwd, facts: currentFacts,
                              run: { await run($0, timeout: $1) }, step: step)
            let result = await platform.deliver(job)
            d = result.delivery
            if let failure = result.failure { return failed(&d, failure) }
            images += result.images
        }

        if d.state == .building { d.state = .ready }
        center.update(d)
        if let event = d.event, d.kind != .preview || d.state == .ready {
            remote.broadcast("test.delivery", event, platform: d.platform)
            if d.state == .ready { d.state = .sent; center.update(d) }
        }
        await sendReviewCard(scope: scope, target: t, delivery: d, tests: tests, images: images, session: session, factory: factory,
                             workItem: workItem, note: d.message)
        return d
    }

    private func failed(_ d: inout TestDelivery, _ message: String) -> TestDelivery {
        d.state = .failed
        d.message = message
        center.update(d)
        engine.report(message)
        return d
    }

    // MARK: Previews

    private func buildPreview(_ t: TestTarget, dir: URL, run: (String, TimeInterval) async -> TestShell.Result,
                              tests: inout TestRunSummary?) async {
        let subtitle = "\(t.type.title) · \(Date().formatted(date: .abbreviated, time: .shortened))"
        var sections: [(title: String, text: String)] = []
        if let build = t.buildCommand, !build.isEmpty {
            let r = await run(build, 1800)
            sections.append(("Build output", r.output))
        }
        if let cmd = t.testCommand, !cmd.isEmpty {
            let r = await run(cmd, 1800)
            tests = TestRunSummary.parse(r.output, exitCode: r.code)
            sections.append(("Test output", r.output))
        }
        let html: String
        if t.type == .backend {
            var base = t.url
            if base == nil, t.startCommand != nil, let port = await ensureDevServer(t) { base = "http://localhost:\(port)" }
            if base == nil, let port = t.port { base = "http://localhost:\(port)" }
            var calls: [EndpointCall] = []
            if let base {
                for line in t.pages { if let c = EndpointCall.parse(line) { calls.append(await callEndpoint(c, base: base)) } }
            }
            html = PreviewPages.backend(title: t.title, subtitle: subtitle, base: base, tests: tests, calls: calls, tryPanel: base != nil)
        } else {
            var series: [String: [Double]] = [:]
            if let serial = t.serialCommand, !serial.isEmpty {
                let r = await run(serial, 12)
                sections.insert(("Device output", r.output), at: 0)
                series = PreviewPages.series(from: r.output)
            }
            for r in Self.reportFiles(directory(t)).prefix(3) {
                if let text = try? String(contentsOf: r, encoding: .utf8) { sections.append((r.lastPathComponent, text)) }
            }
            html = PreviewPages.report(title: t.title, subtitle: subtitle, tests: tests, sections: sections, series: series)
        }
        try? html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    /// Test reports the project wrote (JUnit XML and the like), newest first.
    static func reportFiles(_ dir: URL) -> [URL] {
        let names = ["test-results", "reports", "build/test-results", "build/reports/tests", "TestResults", ".pio/test"]
        var out: [URL] = []
        for n in names {
            let base = dir.appendingPathComponent(n)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in e where ["xml", "txt", "log"].contains(url.pathExtension.lowercased()) { out.append(url) }
        }
        return out.sorted { modified($0) > modified($1) }
    }

    nonisolated static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// The newest file (or folder) whose name ends in `suffix`, changed after `after`.
    public nonisolated static func newestFile(in dir: URL, suffix: String, after: Date, directories: Bool = false) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return nil }
        var best: (URL, Date)?
        for case let url as URL in e where url.lastPathComponent.hasSuffix(suffix) {
            if directories { e.skipDescendants() }
            let m = modified(url)
            if m >= after, url.path.contains(".app/") == false, best.map({ m > $0.1 }) ?? true { best = (url, m) }
        }
        return best?.0
    }

    /// A call against one of this machine's local services, for a backend preview.
    public func callEndpoint(_ c: EndpointCall, base: String) async -> EndpointCall {
        var call = c
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + c.path),
              url.host == "localhost" || url.host == "127.0.0.1" || url.host?.hasSuffix(".local") == true || url.host == currentFacts.tailscaleName
        else { call.error = "Only this \(engine.platform.machineWord)'s local services can be called."; return call }
        var r = URLRequest(url: url)
        r.httpMethod = c.method
        r.timeoutInterval = 20
        if let body = c.request, !body.isEmpty {
            r.httpBody = Data(body.utf8)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: r)
            call.status = (response as? HTTPURLResponse)?.statusCode
            call.millis = Int(Date().timeIntervalSince(start) * 1000)
            var text = String(decoding: data.prefix(20000), as: UTF8.self)
            if let obj = try? JSONSerialization.jsonObject(with: data), let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
                text = String(decoding: pretty.prefix(20000), as: UTF8.self)
            }
            call.response = text
        } catch {
            call.error = error.localizedDescription
        }
        return call
    }

    // MARK: Dev servers

    /// Starts the target's server once and keeps it running; returns its port when it answers.
    public func ensureDevServer(_ t: TestTarget) async -> Int? {
        if let p = center.servers[t.id], p.isRunning, let port = t.port ?? serverPort(t.id) { return port }
        guard let cmd = t.startCommand, !cmd.isEmpty else { return t.port }
        let p = Process()
        let single = !cmd.contains("&&") && !cmd.contains(";") && !cmd.contains("|")
        let shell = ShellInvocation.current(single ? "exec " + cmd : cmd)
        p.executableURL = shell.executable
        p.arguments = shell.arguments
        p.currentDirectoryURL = directory(t)
        var env = environment
        env["HOST"] = "0.0.0.0"
        env["BROWSER"] = "none"
        if let port = t.port { env["PORT"] = String(port) }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let id = t.id
        center.serverOutput[id] = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                self.center.serverOutput[id] = String(((self.center.serverOutput[id] ?? "") + text).suffix(20000))
            }
        }
        do { try p.run() } catch { return nil }
        center.servers[id] = p
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard p.isRunning else { return nil }
            if let port = t.port ?? serverPort(id), await answers(port) { return port }
        }
        return t.port ?? serverPort(id)
    }

    public func stopDevServer(_ id: String) {
        center.servers[id]?.terminate()
        center.servers[id] = nil
    }

    public func serverPort(_ id: String) -> Int? {
        let out = (center.serverOutput[id] ?? "").replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        guard let r = out.range(of: #"(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::\]):(\d{2,5})"#, options: .regularExpression) else { return nil }
        return Int(out[r].split(separator: ":").last ?? "")
    }

    private func answers(_ port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/") else { return false }
        var r = URLRequest(url: url)
        r.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: r)) != nil
    }

    // MARK: Screenshots

    private func androidScreenshot(apk: URL, serial: String, into dir: URL) async -> URL? {
        let env = environment
        let sdk = URL(fileURLWithPath: env["ANDROID_HOME"] ?? "")
        let buildTools = sdk.appendingPathComponent("build-tools")
        guard let tools = ((try? FileManager.default.contentsOfDirectory(atPath: buildTools.path)) ?? []).sorted().last else { return nil }
        let aapt = buildTools.appendingPathComponent(tools).appendingPathComponent("aapt2").path
        let pkg = await TestShell.run("\(TestShell.quote(aapt)) dump packagename \(TestShell.quote(apk.path))", environment: env, timeout: 30)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pkg.isEmpty, !pkg.contains(" ") else { return nil }
        let shot = dir.appendingPathComponent("android.png")
        let cmd = "adb -s \(serial) install -r \(TestShell.quote(apk.path)) && adb -s \(serial) shell monkey -p \(pkg) -c android.intent.category.LAUNCHER 1 && sleep 4 && adb -s \(serial) exec-out screencap -p > \(TestShell.quote(shot.path))"
        let r = await TestShell.run(cmd, environment: env, timeout: 180)
        return r.code == 0 && FileManager.default.fileExists(atPath: shot.path) ? shot : nil
    }

    // MARK: Review cards

    public func sendReviewCard(scope: String, target: TestTarget, delivery: TestDelivery?, tests: TestRunSummary?,
                               images: [(title: String, file: URL)], session: String?, factory: String?, workItem: Int?, note: String?) async {
        var card = TestReviewCard(scope: scope, target: target.id, title: workItem.map { "#\($0) · \(target.title)" } ?? target.title,
                                  summary: "", workItem: workItem, session: session, factory: factory, tests: tests, delivery: delivery?.id)
        let dir = center.folder(card.id)
        for img in images {
            let name = img.file.lastPathComponent
            try? FileManager.default.copyItem(at: img.file, to: dir.appendingPathComponent(name))
            card.images.append(.init(title: img.title, path: name))
        }
        let previous = center.cards.first { $0.target == target.id }
        for copy in card.compare(with: previous) {
            let from = center.root.appendingPathComponent(previous?.id ?? "").appendingPathComponent(copy.from)
            try? FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(copy.to))
        }
        let cwd = session.flatMap { engine.sessions.session($0)?.workingDirectory } ?? URL(fileURLWithPath: target.repo)
        let diff = await TestShell.run("git diff --stat HEAD 2>/dev/null | tail -15", cwd: cwd, environment: environment, timeout: 20).output
        var summary = [note, diff.isEmpty ? nil : "Changes:\n" + diff.trimmingCharacters(in: .whitespacesAndNewlines)].compactMap { $0 }.joined(separator: "\n\n")
        if summary.isEmpty { summary = "A new build of \(target.title)." }
        card.summary = summary
        if delivery == nil || delivery?.phoneKind == nil { card.actions.removeAll { $0 == "install" } }
        if session == nil && factory == nil { card.actions.removeAll { $0 == "pause" || $0 == "change" } }
        card.platform = delivery?.platform
        center.add(card)
        remote.broadcast("review.card", card.json, platform: card.platform)
        if let note = PushNote.from(event: "review.card", data: card.json) { remote.sendPush(note) }
        engine.platform.notifier?.notify(title: "Ready for review", body: card.title, action: "review")
    }

    /// The phone's (or the desktop's) answer to a review card.
    public func respond(_ id: String, action: String, text: String?) async -> String {
        guard let card = center.cards.first(where: { $0.id == id }) else { return "That card is gone." }
        center.respond(id, action)
        let hub = engine.sessions
        let s = card.session.flatMap { hub.session($0) }
        switch action {
        case "approve":
            if let fid = card.factory, let sid = card.session,
               let q = engine.factories.factory(fid)?.run?.openQuestions.last(where: { $0.sessionID == sid }) {
                engine.factories.answer(fid, q.id, answer: "Approved after testing the build on my phone.")
                return "Approved. The factory carries on."
            }
            if let s { hub.send("I tested the build on my phone and approve it. Carry on.", in: s); return "Approved. The session carries on." }
            return "Approved."
        case "pause":
            if let fid = card.factory { engine.factories.pause(fid); return "Paused the factory." }
            if let s { hub.stop(s); return "Stopped the session." }
            return "Nothing to pause."
        case "change":
            guard let s, let text, !text.isEmpty else { return "Say what to change." }
            hub.send("From testing the build on my phone: \(text)", in: s)
            return "Sent to the session."
        case "install":
            if let did = card.delivery, let d = center.deliveries.first(where: { $0.id == did }), let event = d.event {
                remote.broadcast("test.delivery", event, platform: d.platform)
                return "Sent the build again."
            }
            guard let target = card.target else { return "Nothing to install." }
            Task { await deliver(scope: card.scope, targetID: target, session: card.session, factory: card.factory, workItem: card.workItem) }
            return "Building it again."
        default:
            return "I don't know \(action)."
        }
    }

    // MARK: Status

    /// Detects the scope's targets the first time its status is asked for (a project-wide scope covers its scopes'
    /// repositories), so a client needn't call `test.detect` first.
    func detectIfNeverDone(_ scope: String) {
        guard center.store[scope].targets.isEmpty, !checkouts(scope).isEmpty else { return }
        detectTargets(scope)
    }

    /// The scope's repositories that are on this computer (for a project-wide scope, its scopes' too).
    public func checkouts(_ scope: String) -> [URL] {
        ScopeRepositories.of(scope, in: engine.index).work.compactMap(\.checkout)
    }

    public func statusJSON(scope: String) -> JSONValue {
        detectIfNeverDone(scope)
        let plan = center.store[scope]
        let facts = currentFacts
        let targets: [JSONValue] = plan.targets.map { t in
            let method = t.method ?? t.adapter.recommended(facts)
            let items = checklist(t, method: method)
            let why = unavailable(t, method: method)
            return ["id": .string(t.id), "type": .string(t.type.rawValue), "title": .string(t.title), "method": .string(method),
                    "methodTitle": .string(t.adapter.method(method)?.title ?? TestAdapters.preview.title),
                    "ready": .bool(t.method != nil && ChecklistItem.ready(items) && why == nil),
                    "unavailable": why.map(JSONValue.string) ?? .null,
                    "checklist": .array(items.map { i in
                        ["id": .string(i.id), "title": .string(i.title), "status": .string(i.status.rawValue),
                         "help": .string(i.help.joined(separator: "\n"))]
                    })]
        }
        var compat: JSONValue = .null
        if let c = plan.compatibility {
            compat = ["checked": .number(c.checked.timeIntervalSince1970), "good": .bool(c.good),
                      "findings": .array(c.findings.map { ["title": .string($0.title), "detail": .string($0.detail),
                                                           "canStill": .string($0.canStill), "cannot": .string($0.cannot)] })]
        }
        let note: JSONValue = checkouts(scope).isEmpty
            ? .string("None of \(engine.index.project(scope)?.title ?? scope)'s repositories is on this \(engine.platform.machineWord): add its folder in the project's settings.")
            : .null
        return ["targets": .array(targets), "compatibility": compat, "note": note,
                "deliveries": .array(center.deliveries.filter { $0.scope == scope && $0.phoneKind != nil }.prefix(15).map(\.summary))]
    }

    public func statusResult(scope: String) -> ActionResult {
        let plan = center.store[scope]
        let data = statusJSON(scope: scope)
        guard plan.isSetUp else {
            return ActionResult(plan.targets.isEmpty ? "Testing isn't set up for this project yet." :
                "Testing isn't set up yet. Mindmill found \(plan.targets.map { $0.type.title.lowercased() }.joined(separator: " and ")).", data: data)
        }
        let ready = plan.targets.filter(ready).count
        var speech = "\(ready) of \(plan.targets.count) test target\(plan.targets.count == 1 ? " is" : "s are") ready."
        if let c = plan.compatibility, !c.good { speech += " This \(engine.platform.machineWord) can't do everything: \(c.findings.first?.title ?? "")." }
        if let last = center.deliveries.first(where: { $0.scope == scope }) {
            speech += " The last delivery \(last.state == .failed ? "failed" : "went out") \(last.created.formatted(.relative(presentation: .named)))."
        }
        return ActionResult(speech, data: data)
    }

    // MARK: Remote methods and actions

    /// Registers the testing methods and actions; `engine.tests` (and its saved state) is only read when one is called.
    static func register(on engine: MindmillEngine) {
        engine.methods.register(["test.status", "test.download", "test.installed", "test.send", "preview.get", "review.list",
                                 "review.respond"]) { method in
            { [unowned engine] client, p in try await engine.tests.call(method, p, from: client) }
        }
        let a = engine.actions
        a.register("test.status") { [unowned engine] p in engine.tests.statusResult(scope: try engine.scopeParam(p)) }
        a.register("test.detect") { [unowned engine] p in
            let scope = try engine.scopeParam(p)
            guard !engine.tests.checkouts(scope).isEmpty else {
                return ActionResult("None of \(engine.index.project(scope)?.title ?? scope)'s repositories is on this \(engine.platform.machineWord).",
                                    data: ["targets": []])
            }
            engine.tests.detectTargets(scope)
            let targets = engine.tests.center.store[scope].targets
            return ActionResult(targets.isEmpty ? "Found nothing to test in its repositories."
                                : "Found " + ActionText.list(targets.map(\.title)) + ".",
                                data: ["targets": .array(targets.map { ["id": .string($0.id), "type": .string($0.type.rawValue), "title": .string($0.title)] })])
        }
        a.register("test.check") { [unowned engine] p in
            let scope = try engine.scopeParam(p)
            await engine.tests.gatherFacts()
            await engine.tests.runCompatibilityCheck(scope, force: true)
            return engine.tests.statusResult(scope: scope)
        }
        a.register("test.deliver") { [unowned engine] p in
            let scope = try engine.scopeParam(p)
            guard let target = p["target"]?.string else { throw ActionError("Which target?") }
            guard let d = await engine.tests.deliver(scope: scope, targetID: target, session: p["session"]?.string) else {
                throw ActionError("The delivery didn't work; see Test on the \(engine.platform.machineWord).")
            }
            return ActionResult(d.state == .failed ? (d.message ?? "The delivery failed.") : "Delivered \(d.title).", data: .from(d))
        }
        a.register("test.server.stop") { [unowned engine] p in
            guard let id = p["id"]?.string, engine.tests.center.servers[id] != nil else { throw ActionError("That server isn't running.") }
            engine.tests.stopDevServer(id)
            return ActionResult("Stopped it.")
        }
    }

    public func call(_ method: String, _ p: JSONValue, from client: RemoteClient) async throws -> JSONValue {
        switch method {
        case "test.status":
            guard let scope = p["scope"]?.string ?? engine.scope else { throw RemoteError.badParams("scope") }
            return statusJSON(scope: scope)

        case "test.download":
            guard let id = p["delivery"]?.string, let d = center.deliveries.first(where: { $0.id == id }), d.kind == .apk, let name = d.file,
                  let data = try? Data(contentsOf: center.folder(id).appendingPathComponent(name)) else { throw RemoteError.notFound("No such build") }
            let frames = DeliveryFiles.frames(data, delivery: id)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                for f in frames { client.sendBinary(f.encoded()) }
            }
            return ["name": .string(name), "size": .number(Double(data.count)), "sha256": .string(DeliveryFiles.sha256(data)),
                    "chunks": .number(Double(frames.count))]

        case "test.installed":
            guard let id = p["delivery"]?.string, var d = center.deliveries.first(where: { $0.id == id }) else { throw RemoteError.notFound("No such build") }
            let ok = p["ok"]?.bool ?? false
            d.state = ok ? .installed : .failed
            d.message = p["message"]?.string ?? (ok ? "Installed on the phone." : "Installing on the phone failed.")
            center.update(d)
            if ok { center.editTarget(d.scope, d.target) { $0.confirm("install-allowed", true) } }
            return ["noted": true]

        case "test.send":
            guard let id = p["delivery"]?.string, let d = center.deliveries.first(where: { $0.id == id }), let event = d.event else {
                throw RemoteError.notFound("No such build")
            }
            remote.sendDelivery(event, platform: d.platform)
            return ["sent": true, "platform": d.platform.map(JSONValue.string) ?? .null]

        case "preview.get":
            guard let id = p["delivery"]?.string, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
                  let raw = p["path"]?.string else { throw RemoteError.badParams("delivery and path") }
            if raw.hasPrefix("try?") || raw.hasPrefix("try/") { return try await previewTryCall(id, raw) }
            guard let path = DeliveryFiles.safePath(raw),
                  let data = try? Data(contentsOf: center.root.appendingPathComponent(id).appendingPathComponent(path)) else {
                throw RemoteError.notFound("No such file in the preview")
            }
            return ["mime": .string(DeliveryFiles.mime(path)), "base64": .string(data.base64EncodedString())]

        case "review.list":
            let scope = p["scope"]?.string
            return ["cards": .array(center.cards.filter { scope == nil || $0.scope == scope }.prefix(30).map(\.json))]

        case "review.respond":
            guard let id = p["card"]?.string, let action = p["action"]?.string else { throw RemoteError.badParams("card and action") }
            return ["speech": .string(await respond(id, action: action, text: p["text"]?.string))]

        default:
            throw RemoteError(code: "unknown_method", message: "Mindmill on this \(engine.platform.machineWord) doesn't know \(method). Update it.")
        }
    }

    /// The backend preview's "try this call": the engine makes it against the target's local service.
    private func previewTryCall(_ delivery: String, _ raw: String) async throws -> JSONValue {
        guard let d = center.deliveries.first(where: { $0.id == delivery }), let t = center.store[d.scope].target(d.target) else {
            throw RemoteError.notFound("No such preview")
        }
        let query = URLComponents(string: "x://y/" + raw)?.queryItems ?? []
        func q(_ k: String) -> String { query.first { $0.name == k }?.value ?? "" }
        let base = t.url ?? (t.port ?? serverPort(t.id)).map { "http://localhost:\($0)" }
        guard let base else { throw RemoteError(code: "failed", message: "The service isn't running.") }
        let path = q("path").hasPrefix("/") ? q("path") : "/" + q("path")
        let call = await callEndpoint(EndpointCall(method: q("method").isEmpty ? "GET" : q("method").uppercased(), path: path, request: q("body")), base: base)
        let text = call.error.map { "Failed: \($0)" } ?? "\(call.status ?? 0) · \(call.millis ?? 0) ms\n\n\(call.response)"
        return ["mime": "text/plain", "base64": .string(Data(text.utf8).base64EncodedString())]
    }
}
