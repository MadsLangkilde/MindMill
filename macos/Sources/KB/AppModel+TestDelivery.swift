import AppKit
import Foundation
import KBCore
import WebKit

extension AppModel {
    /// Builds, tests and delivers one target as its method says, then sends the phone a review card.
    /// Returns the delivery.
    @discardableResult
    func deliverTest(scope: String, targetID: String, session: String? = nil, factory: String? = nil, workItem: Int? = nil) async -> TestDelivery? {
        guard let t = testing.store[scope].target(targetID), testing.working[targetID] == nil else { return nil }
        if testing.facts.gathered == nil { await gatherTestFacts() }
        let methodID = t.method ?? t.adapter.recommended(currentTestFacts)
        let method = t.adapter.method(methodID) ?? TestAdapters.preview
        var d = TestDelivery(scope: scope, target: t.id, kind: method.kind, title: t.title)
        d.session = session
        testing.update(d)
        let dir = testing.folder(d.id)
        let cwd = testTargetDirectory(t)
        let env = testEnvironment
        var log = ""
        func step(_ what: String) { testing.working[targetID] = what }
        func run(_ cmd: String, timeout: TimeInterval = 1800) async -> TestShell.Result {
            let r = await TestShell.run(cmd, cwd: cwd, environment: env, timeout: timeout)
            log += "$ \(cmd)\n\(r.output)\n"
            return r
        }
        defer {
            testing.working[targetID] = nil
            testing.logs[targetID] = String(log.suffix(60000))
        }

        var tests: TestRunSummary?
        if let cmd = t.testCommand, !cmd.isEmpty, method.kind != .preview {
            step("Running the tests…")
            let r = await run(cmd)
            tests = TestRunSummary.parse(r.output, exitCode: r.code)
            if testing.store[scope].deliverWhen == .whenTestsPass, tests?.ok == false {
                d.state = .failed
                d.message = "The tests failed, so nothing was delivered."
                testing.update(d)
                await sendReviewCard(scope: scope, target: t, delivery: nil, tests: tests, images: [], session: session, factory: factory,
                                     workItem: workItem, note: d.message)
                return d
            }
        }

        var images: [(title: String, file: URL)] = []
        switch method.kind {
        case .apk:
            step("Building the APK…")
            let started = Date()
            let r = await run(t.buildCommand ?? (FileManager.default.fileExists(atPath: cwd.appendingPathComponent("gradlew").path) ? "./gradlew assembleDebug" : "gradle assembleDebug"))
            guard r.code == 0, let apk = newestFile(in: cwd, suffix: ".apk", after: started) else {
                return failed(&d, "The build failed. See the log in Test.", log)
            }
            let dest = dir.appendingPathComponent(apk.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: apk, to: dest)
            guard let data = try? Data(contentsOf: dest) else { return failed(&d, "Couldn't read the APK.", log) }
            d.file = dest.lastPathComponent
            d.size = data.count
            d.sha256 = DeliveryFiles.sha256(data)
            if let emulator = currentTestFacts.devices.first(where: { $0.kind == .androidEmulator && $0.booted }) {
                step("Taking screenshots on the emulator…")
                if let shot = await androidScreenshot(apk: dest, serial: emulator.id, into: dir) { images.append(("App", shot)) }
            }

        case .url:
            step("Starting the dev server…")
            guard let port = await ensureDevServer(t) else { return failed(&d, "The dev server didn't start. Check the start command.", log + (testing.serverOutput[t.id] ?? "")) }
            let f = currentTestFacts
            let host = f.tailscaleName ?? f.tailscaleIP ?? f.lanIP ?? "localhost"
            let page = t.pages.first.map { $0.hasPrefix("/") ? $0 : "/" + $0 } ?? "/"
            d.url = "http://\(host):\(port)\(page)"
            step("Taking a screenshot…")
            for (i, p) in (t.pages.isEmpty ? ["/"] : Array(t.pages.prefix(3))).enumerated() {
                let path = p.hasPrefix("/") ? p : "/" + p
                if let url = URL(string: "http://localhost:\(port)\(path)"), let shot = await webSnapshot(url, into: dir, name: "page\(i).png") {
                    images.append((path == "/" ? "Home" : path, shot))
                }
            }

        case .preview:
            step("Running the tests…")
            await buildPreview(t, method: methodID, dir: dir, run: run, tests: &tests)

        case .iosDevice:
            guard let device = t.devices.first ?? currentTestFacts.devices.first(where: { ($0.kind == .iphone || $0.kind == .ipad) && $0.paired })?.id else {
                return failed(&d, "No paired iPhone. Pair it with Xcode first.", log)
            }
            step("Building for the iPhone…")
            guard let scheme = await iosScheme(t, run: run) else { return failed(&d, "Couldn't find an Xcode scheme. Set it under More options.", log) }
            let derived = dir.appendingPathComponent("dd").path
            let build = await run("xcodebuild \(xcodeContainer(cwd)) -scheme \(TestShell.quote(scheme)) -destination 'id=\(device)' -configuration Debug -derivedDataPath \(TestShell.quote(derived)) -allowProvisioningUpdates build")
            guard build.code == 0, let app = newestFile(in: URL(fileURLWithPath: derived).appendingPathComponent("Build/Products"), suffix: ".app", after: .distantPast, directories: true)
            else { return failed(&d, "The iOS build failed. See the log in Test.", log) }
            step("Installing on the iPhone…")
            let install = await run("xcrun devicectl device install app --device \(device) \(TestShell.quote(app.path))", timeout: 300)
            guard install.code == 0 else { return failed(&d, "Installing on the iPhone failed. Is it unlocked and on the same network?", log) }
            d.state = .installed
            d.message = "Installed on the iPhone."
            if let sim = currentTestFacts.devices.first(where: { $0.kind == .iosSimulator && $0.booted }) {
                step("Taking a screenshot in the simulator…")
                if let shot = await simulatorScreenshot(t, scheme: scheme, simulator: sim.id, into: dir, run: run) { images.append(("App", shot)) }
            }

        case .iosLink, .testflight:
            guard let scheme = await iosScheme(t, run: run) else { return failed(&d, "Couldn't find an Xcode scheme. Set it under More options.", log) }
            step("Archiving…")
            let archive = dir.appendingPathComponent("App.xcarchive").path
            let a = await run("xcodebuild \(xcodeContainer(cwd)) -scheme \(TestShell.quote(scheme)) -configuration Release -destination 'generic/platform=iOS' -archivePath \(TestShell.quote(archive)) -allowProvisioningUpdates archive")
            guard a.code == 0 else { return failed(&d, "Archiving failed. See the log in Test.", log) }
            let options = dir.appendingPathComponent("ExportOptions.plist")
            try? DeliveryFiles.exportOptions(testflight: method.kind == .testflight).write(to: options, atomically: true, encoding: .utf8)
            let export = dir.appendingPathComponent("export")
            var exportCmd = "xcodebuild -exportArchive -archivePath \(TestShell.quote(archive)) -exportPath \(TestShell.quote(export.path)) -exportOptionsPlist \(TestShell.quote(options.path)) -allowProvisioningUpdates"
            if method.kind == .testflight {
                guard let key = t.ascKeyID, let issuer = t.ascIssuer, let path = ascKeyPath(key) else {
                    return failed(&d, "Enter the App Store Connect key ID and issuer under More options, with the key file on this Mac.", log)
                }
                exportCmd += " -authenticationKeyPath \(TestShell.quote(path)) -authenticationKeyID \(key) -authenticationKeyIssuerID \(issuer)"
                step("Uploading to TestFlight…")
            } else {
                step("Exporting the ad hoc build…")
            }
            let e = await run(exportCmd)
            guard e.code == 0 else { return failed(&d, method.kind == .testflight ? "The upload failed. See the log in Test." : "Exporting failed. Is the iPhone registered in your account?", log) }
            if method.kind == .testflight {
                d.state = .sent
                d.message = "Uploaded. TestFlight shows it on the iPhone once Apple has processed it, usually within 15–30 minutes."
            } else {
                guard let ipa = newestFile(in: export, suffix: ".ipa", after: .distantPast), let dns = currentTestFacts.tailscaleName else {
                    return failed(&d, "No .ipa, or no Tailscale name for the link.", log)
                }
                let info = "\(archive)/Info.plist"
                let bundle = await run("/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' \(TestShell.quote(info))").output.trimmingCharacters(in: .whitespacesAndNewlines)
                let version = await run("/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' \(TestShell.quote(info))").output.trimmingCharacters(in: .whitespacesAndNewlines)
                let base = "https://\(dns)/mindmill/\(d.id)"
                let manifest = DeliveryFiles.installManifest(ipaURL: "\(base)/\(ipa.lastPathComponent)", bundleID: bundle, version: version.isEmpty ? "1" : version, title: t.title)
                try? manifest.write(to: export.appendingPathComponent("manifest.plist"), atomically: true, encoding: .utf8)
                step("Serving the install link over Tailscale…")
                let serve = await run("tailscale serve --bg --set-path /mindmill/\(d.id) \(TestShell.quote(export.path))", timeout: 60)
                guard serve.code == 0 else { return failed(&d, "Tailscale couldn't serve the build. Turn on HTTPS certificates for the tailnet.", log) }
                d.url = DeliveryFiles.installLink(manifestURL: "\(base)/manifest.plist")
                d.message = "Open the link on the iPhone (Mindmill shows a QR code in Test)."
            }
        }

        if d.state == .building { d.state = .ready }
        testing.update(d)
        if let event = d.event, d.kind != .preview || d.state == .ready {
            remote.broadcast("test.delivery", event)
            if d.state == .ready { d.state = .sent; testing.update(d) }
        }
        await sendReviewCard(scope: scope, target: t, delivery: d, tests: tests, images: images, session: session, factory: factory,
                             workItem: workItem, note: d.message)
        return d
    }

    private func failed(_ d: inout TestDelivery, _ message: String, _ log: String) -> TestDelivery {
        d.state = .failed
        d.message = message
        testing.update(d)
        notice = message
        return d
    }

    // MARK: Previews

    private func buildPreview(_ t: TestTarget, method: String, dir: URL, run: (String, TimeInterval) async -> TestShell.Result,
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
            let reports = reportFiles(testTargetDirectory(t))
            for r in reports.prefix(3) {
                if let text = try? String(contentsOf: r, encoding: .utf8) { sections.append((r.lastPathComponent, text)) }
            }
            html = PreviewPages.report(title: t.title, subtitle: subtitle, tests: tests, sections: sections, series: series)
        }
        try? html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    /// Test reports the project wrote (JUnit XML and the like), newest first.
    private func reportFiles(_ dir: URL) -> [URL] {
        let names = ["test-results", "reports", "build/test-results", "build/reports/tests", "TestResults", ".pio/test"]
        var out: [URL] = []
        for n in names {
            let base = dir.appendingPathComponent(n)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in e where ["xml", "txt", "log"].contains(url.pathExtension.lowercased()) { out.append(url) }
        }
        return out.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    func callEndpoint(_ c: EndpointCall, base: String) async -> EndpointCall {
        var call = c
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + c.path),
              url.host == "localhost" || url.host == "127.0.0.1" || url.host?.hasSuffix(".local") == true || url.host == currentTestFacts.tailscaleName
        else { call.error = "Only this Mac's local services can be called."; return call }
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
    func ensureDevServer(_ t: TestTarget) async -> Int? {
        if let p = testing.servers[t.id], p.isRunning, let port = t.port ?? serverPort(t.id) { return port }
        guard let cmd = t.startCommand, !cmd.isEmpty else { return t.port }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let single = !cmd.contains("&&") && !cmd.contains(";") && !cmd.contains("|")
        p.arguments = ["-c", single ? "exec " + cmd : cmd]
        p.currentDirectoryURL = testTargetDirectory(t)
        var env = testEnvironment
        env["HOST"] = "0.0.0.0"
        env["BROWSER"] = "none"
        if let port = t.port { env["PORT"] = String(port) }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let id = t.id
        testing.serverOutput[id] = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                self.testing.serverOutput[id] = String(((self.testing.serverOutput[id] ?? "") + text).suffix(20000))
            }
        }
        do { try p.run() } catch { return nil }
        testing.servers[id] = p
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            guard p.isRunning else { return nil }
            if let port = t.port ?? serverPort(id), await answers(port) { return port }
        }
        return t.port ?? serverPort(id)
    }

    func stopDevServer(_ id: String) {
        testing.servers[id]?.terminate()
        testing.servers[id] = nil
    }

    private func serverPort(_ id: String) -> Int? {
        let out = (testing.serverOutput[id] ?? "").replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
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
        let env = testEnvironment
        let sdk = env["ANDROID_HOME"] ?? ""
        let tools = ((try? FileManager.default.contentsOfDirectory(atPath: sdk + "/build-tools")) ?? []).sorted().last
        guard let tools else { return nil }
        let pkg = await TestShell.run("\(TestShell.quote(sdk + "/build-tools/" + tools + "/aapt2")) dump packagename \(TestShell.quote(apk.path))", environment: env, timeout: 30)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pkg.isEmpty, !pkg.contains(" ") else { return nil }
        let shot = dir.appendingPathComponent("android.png")
        let cmd = "adb -s \(serial) install -r \(TestShell.quote(apk.path)) && adb -s \(serial) shell monkey -p \(pkg) -c android.intent.category.LAUNCHER 1 && sleep 4 && adb -s \(serial) exec-out screencap -p > \(TestShell.quote(shot.path))"
        let r = await TestShell.run(cmd, environment: env, timeout: 180)
        return r.code == 0 && FileManager.default.fileExists(atPath: shot.path) ? shot : nil
    }

    private func simulatorScreenshot(_ t: TestTarget, scheme: String, simulator: String, into dir: URL,
                                     run: (String, TimeInterval) async -> TestShell.Result) async -> URL? {
        let derived = dir.appendingPathComponent("sim").path
        let b = await run("xcodebuild \(xcodeContainer(testTargetDirectory(t))) -scheme \(TestShell.quote(scheme)) -destination 'id=\(simulator)' -derivedDataPath \(TestShell.quote(derived)) build", 1800)
        guard b.code == 0, let app = newestFile(in: URL(fileURLWithPath: derived).appendingPathComponent("Build/Products"), suffix: ".app", after: .distantPast, directories: true) else { return nil }
        let bundle = await run("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \(TestShell.quote(app.path + "/Info.plist"))", 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let shot = dir.appendingPathComponent("ios.png")
        let r = await run("xcrun simctl install \(simulator) \(TestShell.quote(app.path)) && xcrun simctl launch \(simulator) \(bundle) && sleep 4 && xcrun simctl io \(simulator) screenshot \(TestShell.quote(shot.path))", 180)
        return r.code == 0 ? shot : nil
    }

    func webSnapshot(_ url: URL, into dir: URL, name: String) async -> URL? {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
        let loader = SnapshotLoader()
        view.navigationDelegate = loader
        view.load(URLRequest(url: url, timeoutInterval: 20))
        for _ in 0..<60 where !loader.done { try? await Task.sleep(for: .milliseconds(250)) }
        guard loader.done else { return nil }
        try? await Task.sleep(for: .seconds(1.5))
        let config = WKSnapshotConfiguration()
        guard let image = try? await view.takeSnapshot(configuration: config), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let file = dir.appendingPathComponent(name)
        return (try? png.write(to: file)) != nil ? file : nil
    }

    // MARK: iOS helpers

    private func iosScheme(_ t: TestTarget, run: (String, TimeInterval) async -> TestShell.Result) async -> String? {
        if let s = t.scheme, !s.isEmpty { return s }
        let r = await run("xcodebuild \(xcodeContainer(testTargetDirectory(t))) -list -json 2>/dev/null", 120)
        guard let start = r.output.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(r.output[start...].utf8)) as? [String: Any] else { return nil }
        let info = (obj["workspace"] ?? obj["project"]) as? [String: Any]
        return (info?["schemes"] as? [String])?.first
    }

    private func xcodeContainer(_ dir: URL) -> String {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if let ws = items.first(where: { $0.hasSuffix(".xcworkspace") }) { return "-workspace \(TestShell.quote(ws))" }
        if let p = items.first(where: { $0.hasSuffix(".xcodeproj") }) { return "-project \(TestShell.quote(p))" }
        return ""
    }

    private func ascKeyPath(_ id: String) -> String? {
        ["~/.appstoreconnect/private_keys", "~/private_keys", "~/.private_keys"].map { KBConfig.expandTilde($0) + "/AuthKey_\(id).p8" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private func newestFile(in dir: URL, suffix: String, after: Date, directories: Bool = false) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return nil }
        var best: (URL, Date)?
        for case let url as URL in e where url.lastPathComponent.hasSuffix(suffix) {
            if directories { e.skipDescendants() }
            let m = url.modified ?? .distantPast
            if m >= after, url.path.contains(".app/") == false, best.map({ m > $0.1 }) ?? true { best = (url, m) }
        }
        return best?.0
    }

    // MARK: Review cards

    func sendReviewCard(scope: String, target: TestTarget, delivery: TestDelivery?, tests: TestRunSummary?, images: [(title: String, file: URL)],
                        session: String?, factory: String?, workItem: Int?, note: String?) async {
        var card = TestReviewCard(scope: scope, target: target.id, title: workItem.map { "#\($0) · \(target.title)" } ?? target.title,
                              summary: "", workItem: workItem, session: session, factory: factory, tests: tests, delivery: delivery?.id)
        let dir = testing.folder(card.id)
        for img in images {
            let name = img.file.lastPathComponent
            try? FileManager.default.copyItem(at: img.file, to: dir.appendingPathComponent(name))
            card.images.append(.init(title: img.title, path: name))
        }
        let previous = testing.cards.first { $0.target == target.id }
        for copy in card.compare(with: previous) {
            let from = TestCenter.folder.appendingPathComponent(previous?.id ?? "").appendingPathComponent(copy.from)
            try? FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(copy.to))
        }
        let cwd = session.flatMap { self.session($0)?.workingDirectory } ?? URL(fileURLWithPath: target.repo)
        let diff = await TestShell.run("git diff --stat HEAD 2>/dev/null | tail -15", cwd: cwd, environment: testEnvironment, timeout: 20).output
        var summary = [note, diff.isEmpty ? nil : "Changes:\n" + diff.trimmingCharacters(in: .whitespacesAndNewlines)].compactMap { $0 }.joined(separator: "\n\n")
        if summary.isEmpty { summary = "A new build of \(target.title)." }
        card.summary = summary
        if delivery == nil || delivery?.phoneKind == nil { card.actions.removeAll { $0 == "install" } }
        if session == nil && factory == nil { card.actions.removeAll { $0 == "pause" || $0 == "change" } }
        testing.add(card)
        remote.broadcast("review.card", card.json)
    }

    /// The phone's answer to a review card.
    func respondToReview(_ id: String, action: String, text: String?) async -> String {
        guard let card = testing.cards.first(where: { $0.id == id }) else { return "That card is gone." }
        testing.respond(id, action)
        let s = card.session.flatMap { session($0) }
        switch action {
        case "approve":
            if let fid = card.factory, let sid = card.session,
               let q = factory(fid)?.run?.openQuestions.last(where: { $0.sessionID == sid }) {
                answerFactoryQuestion(fid, q.id, answer: "Approved after testing the build on my phone.")
                return "Approved. The factory carries on."
            }
            if let s { send("I tested the build on my phone and approve it. Carry on.", in: s); return "Approved. The session carries on." }
            return "Approved."
        case "pause":
            if let fid = card.factory { pauseFactory(fid); return "Paused the factory." }
            if let s { stopSession(s); return "Stopped the session." }
            return "Nothing to pause."
        case "change":
            guard let s, let text, !text.isEmpty else { return "Say what to change." }
            send("From testing the build on my phone: \(text)", in: s)
            return "Sent to the session."
        case "install":
            if let did = card.delivery, let d = testing.deliveries.first(where: { $0.id == did }), let event = d.event {
                remote.broadcast("test.delivery", event)
                return "Sent the build again."
            }
            guard let target = card.target else { return "Nothing to install." }
            Task { await deliverTest(scope: card.scope, targetID: target, session: card.session, factory: card.factory, workItem: card.workItem) }
            return "Building it again."
        default:
            return "I don't know \(action)."
        }
    }

    // MARK: Status

    func testStatusJSON(scope: String) -> JSONValue {
        let plan = testing.store[scope]
        let facts = currentTestFacts
        let targets: [JSONValue] = plan.targets.map { t in
            let method = t.method ?? t.adapter.recommended(facts)
            let items = testChecklist(t, method: method)
            return ["id": .string(t.id), "type": .string(t.type.rawValue), "title": .string(t.title), "method": .string(method),
                    "methodTitle": .string(t.adapter.method(method)?.title ?? TestAdapters.preview.title),
                    "ready": .bool(t.method != nil && ChecklistItem.ready(items)),
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
        return ["targets": .array(targets), "compatibility": compat,
                "deliveries": .array(testing.deliveries.filter { $0.scope == scope && $0.phoneKind != nil }.prefix(15).map(\.summary))]
    }

    func testStatusResult(scope: String) -> ActionResult {
        let plan = testing.store[scope]
        let data = testStatusJSON(scope: scope)
        guard plan.isSetUp else {
            return ActionResult(plan.targets.isEmpty ? "Testing isn't set up for this project yet." :
                "Testing isn't set up yet. Mindmill found \(plan.targets.map { $0.type.title.lowercased() }.joined(separator: " and ")).", data: data)
        }
        let ready = plan.targets.filter(testTargetReady).count
        var speech = "\(ready) of \(plan.targets.count) test target\(plan.targets.count == 1 ? " is" : "s are") ready."
        if let c = plan.compatibility, !c.good { speech += " This Mac can't do everything: \(c.findings.first?.title ?? "")." }
        if let last = testing.deliveries.first(where: { $0.scope == scope }) {
            speech += " The last delivery \(last.state == .failed ? "failed" : "went out") \(last.created.formatted(.relative(presentation: .named)))."
        }
        return ActionResult(speech, data: data)
    }

    // MARK: Phone methods

    func remoteTest(_ method: String, _ p: JSONValue, from client: RemoteClient) async throws -> JSONValue? {
        switch method {
        case "test.status":
            guard let scope = p["scope"]?.string ?? projectID else { throw RemoteError.badParams("scope") }
            return testStatusJSON(scope: scope)

        case "test.download":
            guard let id = p["delivery"]?.string, let d = testing.deliveries.first(where: { $0.id == id }), d.kind == .apk, let name = d.file,
                  let data = try? Data(contentsOf: testing.folder(id).appendingPathComponent(name)) else { throw RemoteError.notFound("No such build") }
            let frames = DeliveryFiles.frames(data, delivery: id)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                for f in frames { client.sendBinary(f.encoded()) }
            }
            return ["name": .string(name), "size": .number(Double(data.count)), "sha256": .string(DeliveryFiles.sha256(data)),
                    "chunks": .number(Double(frames.count))]

        case "test.installed":
            guard let id = p["delivery"]?.string, var d = testing.deliveries.first(where: { $0.id == id }) else { throw RemoteError.notFound("No such build") }
            let ok = p["ok"]?.bool ?? false
            d.state = ok ? .installed : .failed
            d.message = p["message"]?.string ?? (ok ? "Installed on the phone." : "Installing on the phone failed.")
            testing.update(d)
            if ok { testing.editTarget(d.scope, d.target) { $0.confirm("install-allowed", true) } }
            return ["noted": true]

        case "preview.get":
            guard let id = p["delivery"]?.string, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
                  let raw = p["path"]?.string else { throw RemoteError.badParams("delivery and path") }
            if raw.hasPrefix("try?") || raw.hasPrefix("try/") { return try await previewTryCall(id, raw) }
            guard let path = DeliveryFiles.safePath(raw),
                  let data = try? Data(contentsOf: TestCenter.folder.appendingPathComponent(id).appendingPathComponent(path)) else {
                throw RemoteError.notFound("No such file in the preview")
            }
            return ["mime": .string(DeliveryFiles.mime(path)), "base64": .string(data.base64EncodedString())]

        case "review.list":
            let scope = p["scope"]?.string
            return ["cards": .array(testing.cards.filter { scope == nil || $0.scope == scope }.prefix(30).map(\.json))]

        case "review.respond":
            guard let id = p["card"]?.string, let action = p["action"]?.string else { throw RemoteError.badParams("card and action") }
            return ["speech": .string(await respondToReview(id, action: action, text: p["text"]?.string))]

        default:
            return nil
        }
    }

    /// The backend preview's "try this call": the Mac makes it against the target's local service.
    private func previewTryCall(_ delivery: String, _ raw: String) async throws -> JSONValue {
        guard let d = testing.deliveries.first(where: { $0.id == delivery }), let t = testing.store[d.scope].target(d.target) else {
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

private final class SnapshotLoader: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done = true }
}

private extension URL {
    var modified: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}
