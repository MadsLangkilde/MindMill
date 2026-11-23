import Foundation
import KBCore

extension AppModel {
    var testEnvironment: [String: String] {
        var env = shell?.environment ?? ProcessInfo.processInfo.environment
        let sdk = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] ?? (NSHomeDirectory() + "/Library/Android/sdk")
        env["ANDROID_HOME"] = sdk
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":\(sdk)/platform-tools:\(sdk)/emulator:/Applications/Tailscale.app/Contents/MacOS"
        return env
    }

    // MARK: What this Mac has

    /// Looks at the toolchains, devices, signing and network. Takes a few seconds; runs in the background.
    func gatherTestFacts() async {
        guard !testing.gathering else { return }
        testing.gathering = true
        defer { testing.gathering = false }
        let env = testEnvironment
        func sh(_ cmd: String, timeout: TimeInterval = 20) async -> String? {
            let r = await TestShell.run(cmd, environment: env, timeout: timeout)
            let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.code == 0 && !out.isEmpty ? out : nil
        }
        func first(_ s: String?) -> String? { s?.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) }

        var f = TestEnvironmentFacts()
        f.os = await sh("sw_vers -productName") ?? "macOS"
        f.osVersion = await sh("sw_vers -productVersion") ?? ""
        f.arch = await sh("uname -m") ?? ""
        f.cpu = await sh("sysctl -n machdep.cpu.brand_string") ?? ""
        if let gpu = await sh("system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{print $2; exit}'") { f.gpu = gpu }

        var tools: [String: String] = [:]
        if let x = await sh("xcodebuild -version 2>/dev/null") { tools["xcode"] = first(x)?.replacingOccurrences(of: "Xcode ", with: "") }
        if let x = await sh("swift --version 2>&1") { tools["swift"] = first(x) }
        let sdk = env["ANDROID_HOME"] ?? ""
        if FileManager.default.fileExists(atPath: sdk + "/platforms") {
            let platforms = (try? FileManager.default.contentsOfDirectory(atPath: sdk + "/platforms")) ?? []
            tools["android-sdk"] = platforms.sorted().last ?? "installed"
        }
        if let x = await sh("java -version 2>&1") { tools["java"] = first(x) }
        let probes: [(String, String)] = [
            ("gradle", "command -v gradle"), ("node", "node --version"), ("npm", "npm --version"), ("pnpm", "pnpm --version"),
            ("python3", "python3 --version"), ("go", "go version"), ("cargo", "cargo --version"), ("dotnet", "dotnet --version"),
            ("docker", "docker --version"), ("platformio", "pio --version"), ("idf.py", "command -v idf.py"), ("west", "west --version"),
            ("adb", "adb version"), ("arm-none-eabi-gcc", "arm-none-eabi-gcc --version"), ("cmake", "cmake --version"),
            ("tailscale", "tailscale version"), ("flutter", "flutter --version --machine 2>/dev/null | head -c 200"),
        ]
        for (name, cmd) in probes {
            if let x = await sh(cmd + " 2>&1", timeout: 10) { tools[name] = name == "gradle" || name == "idf.py" ? "installed" : first(x) }
        }
        f.toolchains = tools

        var devices: [TestEnvironmentFacts.Device] = []
        if tools["xcode"] != nil {
            let json = NSTemporaryDirectory() + "mindmill-devices-\(UUID().uuidString).json"
            if await sh("xcrun devicectl list devices --json-output \(TestShell.quote(json)) >/dev/null 2>&1 && echo ok", timeout: 30) != nil,
               let data = FileManager.default.contents(atPath: json),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = (obj["result"] as? [String: Any])?["devices"] as? [[String: Any]] {
                for d in list {
                    let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
                    let props = d["deviceProperties"] as? [String: Any] ?? [:]
                    let conn = d["connectionProperties"] as? [String: Any] ?? [:]
                    let type = (hw["deviceType"] as? String ?? "").lowercased()
                    let kind: TestEnvironmentFacts.Device.Kind = type.contains("ipad") ? .ipad : type.contains("iphone") ? .iphone : .other
                    guard kind != .other else { continue }
                    devices.append(.init(id: hw["udid"] as? String ?? d["identifier"] as? String ?? "", name: props["name"] as? String ?? "iPhone",
                                         kind: kind, paired: conn["pairingState"] as? String == "paired",
                                         booted: (conn["tunnelState"] as? String).map { $0 != "unavailable" } ?? false))
                }
            }
            try? FileManager.default.removeItem(atPath: json)
            if let x = await sh("xcrun simctl list devices booted -j 2>/dev/null"),
               let obj = try? JSONSerialization.jsonObject(with: Data(x.utf8)) as? [String: Any],
               let byRuntime = obj["devices"] as? [String: [[String: Any]]] {
                for d in byRuntime.values.flatMap({ $0 }) {
                    devices.append(.init(id: d["udid"] as? String ?? "", name: d["name"] as? String ?? "Simulator", kind: .iosSimulator, booted: true))
                }
            }
        }
        if tools["adb"] != nil, let x = await sh("adb devices -l") {
            for line in x.components(separatedBy: "\n").dropFirst() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let parts = line.split(separator: " ").map(String.init)
                guard let serial = parts.first, parts.count > 1 else { continue }
                let name = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) } ?? serial
                devices.append(.init(id: serial, name: name, kind: serial.hasPrefix("emulator-") ? .androidEmulator : .android,
                                     paired: parts[1] == "device", booted: parts[1] == "device"))
            }
        }
        f.devices = devices

        if let x = await sh("tailscale status --json 2>/dev/null", timeout: 10),
           let obj = try? JSONSerialization.jsonObject(with: Data(x.utf8)) as? [String: Any] {
            f.tailscaleRunning = obj["BackendState"] as? String == "Running"
            let me = obj["Self"] as? [String: Any] ?? [:]
            f.tailscaleName = (me["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.flatMap { $0.isEmpty ? nil : $0 }
            f.tailscaleIP = (me["TailscaleIPs"] as? [String])?.first { !$0.contains(":") }
            f.tailscaleHTTPS = !((obj["CertDomains"] as? [String]) ?? []).isEmpty
        }
        f.lanIP = RemoteAddresses.interfaceIPs().first(where: RemoteAddresses.isPrivateLAN)
        if let x = await sh("security find-identity -v -p codesigning") {
            f.signingIdentities = x.components(separatedBy: "\n").compactMap { line in
                guard let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b else { return nil }
                return String(line[line.index(after: a)..<b])
            }
        }
        let keyDirs = ["~/.appstoreconnect/private_keys", "~/private_keys", "~/.private_keys"].map { KBConfig.expandTilde($0) }
        f.appStoreConnectKey = keyDirs.contains { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).contains { $0.hasPrefix("AuthKey_") && $0.hasSuffix(".p8") }
        }
        f.companionConnected = !remote.connected.isEmpty
        f.companionPaired = !remote.devices.devices.isEmpty
        f.gathered = Date()
        testing.facts = f
    }

    /// The facts, with the phone's connection as it is now.
    var currentTestFacts: TestEnvironmentFacts {
        var f = testing.facts
        f.companionConnected = !remote.connected.isEmpty
        f.companionPaired = !remote.devices.devices.isEmpty
        return f
    }

    // MARK: Targets

    /// Finds what the scope's repositories build and merges it into its plan.
    func detectTestTargets(_ scope: String) {
        var detected: [TestTarget] = []
        for repo in repositories(of: scope).work {
            guard let checkout = repo.checkout else { continue }
            let listing = RepoListing.scan(checkout)
            for d in ProjectDetector.detect(listing) {
                let t = TestTarget(d, repo: checkout.path, repoTitle: repo.title)
                testing.listings[t.id] = listing
                detected.append(t)
            }
        }
        testing.edit(scope) { $0.merge(detected: detected) }
    }

    func testTargetDirectory(_ t: TestTarget) -> URL {
        let repo = URL(fileURLWithPath: t.repo)
        return t.path.isEmpty ? repo : repo.appendingPathComponent(t.path)
    }

    func testContext(_ t: TestTarget) -> TestContext {
        let listing = testing.listings[t.id] ?? {
            let l = RepoListing.scan(testTargetDirectory(t), depth: 2)
            testing.listings[t.id] = l
            return l
        }()
        return TestContext(facts: currentTestFacts, target: t, listing: listing)
    }

    func testChecklist(_ t: TestTarget, method: String? = nil) -> [ChecklistItem] {
        let m = method ?? t.method ?? t.adapter.recommended(currentTestFacts)
        return TestAdapters.checklist(type: t.type, method: m, testContext(t))
    }

    func testTargetReady(_ t: TestTarget) -> Bool {
        t.method != nil && ChecklistItem.ready(testChecklist(t))
    }

    // MARK: Compatibility check

    func projectDescription(_ scope: String) -> String? {
        let overview = index.entries[EntryID(project: scope, section: .overview, stem: "overview")]
        let text = [index.project(scope)?.title, overview?.summary].compactMap { $0 }.filter { !$0.isEmpty }
        return text.isEmpty ? nil : text.joined(separator: ": ")
    }

    /// Asks the brain whether this Mac can build, run and test the scope's targets. `force` runs it even when
    /// nothing changed since the last check.
    func runCompatibilityCheck(_ scope: String, force: Bool = false) async {
        guard !testing.checking.contains(scope) else { return }
        if testing.facts.gathered == nil { await gatherTestFacts() }
        if testing.store[scope].targets.isEmpty { detectTestTargets(scope) }
        let plan = testing.store[scope]
        let fingerprint = plan.compatibilityFingerprint(testing.facts)
        guard force || plan.needsCompatibilityCheck(fingerprint: fingerprint), claudeAvailable else { return }
        testing.checking.insert(scope)
        defer { testing.checking.remove(scope) }
        let prompt = CompatibilityCheck.prompt(facts: testing.facts, targets: plan.targets, description: projectDescription(scope))
        var model = backgroundModel
        if model.isEmpty { model = "sonnet" }
        guard let reply = await claudeOnce(prompt, system: CompatibilityCheck.system, model: model, timeout: 180),
              let result = CompatibilityCheck.parse(reply, fingerprint: fingerprint) else { return }
        testing.edit(scope) { $0.compatibility = result }
    }

    /// A project was opened or set up: detect its targets, and check compatibility when they or this Mac changed.
    func testProjectOpened(_ scope: String) {
        Task {
            if testing.facts.gathered == nil { await gatherTestFacts() }
            detectTestTargets(scope)
            await runCompatibilityCheck(scope)
        }
    }

    /// New scopes (onboarding's first project, or one set up later) get their check as soon as they exist.
    func testScopesChanged() {
        let key = "testSeenScopes"
        let current = Set(index.projects.filter { !$0.wide }.map(\.id))
        guard let seen = UserDefaults.standard.stringArray(forKey: key) else {
            UserDefaults.standard.set(Array(current), forKey: key)
            return
        }
        let new = current.subtracting(seen)
        guard !new.isEmpty else { return }
        UserDefaults.standard.set(Array(current.union(seen)), forKey: key)
        for id in new where !repositories(of: id).work.compactMap(\.checkout).isEmpty { testProjectOpened(id) }
    }

    /// What Build sessions and factory sessions are told about this Mac's limits for the scope.
    func testingNote(_ scope: String?) -> String {
        guard let scope else { return "" }
        let plan = testing.store[scope]
        var parts: [String] = []
        if let note = CompatibilityCheck.sessionNote(plan.compatibility) { parts.append(note) }
        if plan.isSetUp {
            let how = plan.targets.compactMap { t in t.method.flatMap { t.adapter.method($0) }.map { "\(t.title): \($0.title)" } }
            parts.append("Testing is set up in Mindmill (\(how.joined(separator: "; "))); builds are delivered to the user's phone at checkpoints, so don't set that up yourself. To suggest a change to the test set-up, run `kb test suggest --scope \(scope) --text '<what and why>'`.")
        }
        return parts.isEmpty ? "" : "\n" + parts.joined(separator: "\n")
    }

    // MARK: Asking sessions and factories

    /// After a Build session's turn that changed files: offer to set up testing once, when the scope has none.
    func offerTesting(_ s: WorkSession) {
        guard s.space == .build, s.role != .overseer, !s.testAskShown, !s.chat.isBusy, let scope = s.project,
              testing.ask.shouldAsk(scope: scope, plan: testing.store[scope]), sessionEditedFiles(s) else { return }
        s.testAskShown = true
    }

    func sessionEditedFiles(_ s: WorkSession) -> Bool {
        s.chat.items.contains { $0.role == .tool && ($0.text.hasPrefix("Edit\t") || $0.text.hasPrefix("Write\t") || $0.text.hasPrefix("MultiEdit\t")) }
    }

    func testAnswer(_ s: WorkSession?, scope: String, _ answer: String) {
        switch answer {
        case "setup": openTestMenu(scope: scope)
        case "never": testing.edit(scope) { TestAsk.dontAsk(&$0) }
        default: testing.ask.notNow(scope)
        }
        for other in sessions where other.project == scope { other.testAskShown = false }
        if let s { s.testAskShown = false }
    }

    func openTestMenu(scope: String) {
        if testing.store[scope].targets.isEmpty { detectTestTargets(scope) }
        testing.selectedScope = scope
        testing.preselectType = testing.store[scope].targets.first?.type
        mode = .build
        buildSelection = Self.testTag
    }

    static let testTag = "test:"

    /// A session finished a turn: deliver when the plan says every checkpoint and it changed files, at most every
    /// 15 minutes per session.
    func testingAfterTurn(_ s: WorkSession) {
        guard s.space == .build, let scope = s.project, sessionEditedFiles(s) else { return }
        let plan = testing.store[scope]
        guard plan.isSetUp, plan.deliverWhen != .onRequest else { return }
        if let last = testing.lastAutoDelivery[s.id], Date().timeIntervalSince(last) < 900 { return }
        testing.lastAutoDelivery[s.id] = Date()
        for t in plan.targets where testTargetReady(t) {
            Task { await deliverTest(scope: scope, targetID: t.id, session: s.id) }
        }
    }

    /// A factory session reached a checkpoint where testing makes sense.
    func testingCheckpoint(sessionID: String, checkpoint: String?) {
        guard let s = session(sessionID), let scope = s.project else { return }
        let plan = testing.store[scope]
        let worth: Set<String> = [FactoryCheckpoint.testsFailing.rawValue, FactoryCheckpoint.beforePR.rawValue,
                                  FactoryCheckpoint.beforeComplete.rawValue, "done"]
        guard let checkpoint, worth.contains(checkpoint) else { return }
        if !plan.isSetUp {
            if testing.ask.shouldAsk(scope: scope, plan: plan) { s.testAskShown = true }
            return
        }
        guard plan.deliverWhen != .onRequest else { return }
        let factory = factories.first { $0.run?.task(session: sessionID) != nil }
        let item = factory?.run?.task(session: sessionID)?.workItem
        for t in plan.targets where testTargetReady(t) {
            Task { await deliverTest(scope: scope, targetID: t.id, session: sessionID, factory: factory?.id, workItem: item) }
        }
    }

    /// `kb test suggest` from a session.
    func testSuggested(_ data: Data) -> Bool {
        guard let (scope, suggestion) = TestSuggestion.parse(data) else { return false }
        testing.edit(scope) { $0.suggestions.append(suggestion) }
        notice = "A session suggested a change to testing. See Test in Build."
        return true
    }
}
