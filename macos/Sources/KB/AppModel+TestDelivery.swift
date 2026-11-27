import AppKit
import Foundation
import KBCore
import KBEngine
import WebKit

/// What only a Mac can do for testing: Xcode builds for the iPhone (installed directly, an ad hoc link over
/// Tailscale, or TestFlight), simulator screenshots, WebKit snapshots of web pages, and the Mac's own probes. The
/// engine (`TestRunner`) does the rest.
@MainActor
final class MacTestPlatform: TestPlatform {
    let ownKinds = TestRunner.appleKinds

    private func targetDirectory(_ t: TestTarget) -> URL {
        let repo = URL(fileURLWithPath: t.repo)
        return t.path.isEmpty ? repo : repo.appendingPathComponent(t.path)
    }

    /// Looks at the toolchains, devices, signing and network.
    func gatherFacts(environment env: [String: String]) async -> TestEnvironmentFacts? {
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

        var tools = await TestShell.probe(TestRunner.toolProbes + [("xcode", "xcodebuild -version")], environment: env)
        tools["xcode"] = tools["xcode"]?.replacingOccurrences(of: "Xcode ", with: "")
        for name in ["gradle", "idf.py"] where tools[name] != nil { tools[name] = "installed" }
        let sdk = env["ANDROID_HOME"] ?? ""
        if FileManager.default.fileExists(atPath: sdk + "/platforms") {
            let platforms = (try? FileManager.default.contentsOfDirectory(atPath: sdk + "/platforms")) ?? []
            tools["android-sdk"] = platforms.sorted().last ?? "installed"
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
        if let x = await sh("defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null") {
            f.xcodeAccount = !x.filter { !$0.isWhitespace }.contains("=();")
        } else if tools["xcode"] != nil {
            f.xcodeAccount = false
        }
        let keyDirs = ["~/.appstoreconnect/private_keys", "~/private_keys", "~/.private_keys"].map { KBConfig.expandTilde($0) }
        f.appStoreConnectKey = keyDirs.contains { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).contains { $0.hasPrefix("AuthKey_") && $0.hasSuffix(".p8") }
        }
        return f
    }

    func deliver(_ job: TestJob) async -> TestJobResult {
        let t = job.target
        var d = job.delivery
        let dir = job.dir
        let cwd = job.cwd
        let currentTestFacts = job.facts
        let method = (kind: job.kind, id: "")
        let log = ""
        _ = (method.id, log)
        var images: [(title: String, file: URL)] = []
        func run(_ cmd: String, timeout: TimeInterval = 1800) async -> TestShell.Result { await job.run(cmd, timeout) }
        func step(_ what: String) { job.step(what) }
        func failed(_ d: inout TestDelivery, _ message: String, _ log: String) -> TestJobResult {
            TestJobResult(delivery: d, failure: message)
        }
        switch job.kind {
        case .iosDevice:
            guard let device = t.devices.first ?? currentTestFacts.devices.first(where: { ($0.kind == .iphone || $0.kind == .ipad) && $0.paired })?.id else {
                return failed(&d, "No paired iPhone. Pair it with Xcode first.", log)
            }
            step("Building for the iPhone…")
            guard let scheme = await iosScheme(t, run: run) else { return failed(&d, "Couldn't find an Xcode scheme. Set it under More options.", log) }
            let derived = dir.appendingPathComponent("dd").path
            let build = await run("xcodebuild \(xcodeContainer(cwd)) -scheme \(TestShell.quote(scheme)) -destination 'id=\(device)' -configuration Debug -derivedDataPath \(TestShell.quote(derived)) -allowProvisioningUpdates -allowProvisioningDeviceRegistration build")
            guard build.code == 0, let app = TestRunner.newestFile(in: URL(fileURLWithPath: derived).appendingPathComponent("Build/Products"), suffix: ".app", after: .distantPast, directories: true)
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
            let a = await run("xcodebuild \(xcodeContainer(cwd)) -scheme \(TestShell.quote(scheme)) -configuration Release -destination 'generic/platform=iOS' -archivePath \(TestShell.quote(archive)) -allowProvisioningUpdates -allowProvisioningDeviceRegistration archive")
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
                guard let ipa = TestRunner.newestFile(in: export, suffix: ".ipa", after: .distantPast), let dns = currentTestFacts.tailscaleName else {
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
        default:
            return TestJobResult(delivery: d, failure: "Mindmill on the Mac doesn't build \(job.kind.rawValue) itself.")
        }
        return TestJobResult(delivery: d, images: images)
    }

    private func simulatorScreenshot(_ t: TestTarget, scheme: String, simulator: String, into dir: URL,
                                     run: (String, TimeInterval) async -> TestShell.Result) async -> URL? {
        let derived = dir.appendingPathComponent("sim").path
        let b = await run("xcodebuild \(xcodeContainer(targetDirectory(t))) -scheme \(TestShell.quote(scheme)) -destination 'id=\(simulator)' -derivedDataPath \(TestShell.quote(derived)) build", 1800)
        guard b.code == 0, let app = TestRunner.newestFile(in: URL(fileURLWithPath: derived).appendingPathComponent("Build/Products"), suffix: ".app", after: .distantPast, directories: true) else { return nil }
        let bundle = await run("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \(TestShell.quote(app.path + "/Info.plist"))", 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let shot = dir.appendingPathComponent("ios.png")
        let r = await run("xcrun simctl install \(simulator) \(TestShell.quote(app.path)) && xcrun simctl launch \(simulator) \(bundle) && sleep 4 && xcrun simctl io \(simulator) screenshot \(TestShell.quote(shot.path))", 180)
        return r.code == 0 ? shot : nil
    }

    func snapshot(_ url: URL, into dir: URL, name: String) async -> URL? {
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

    private func iosScheme(_ t: TestTarget, run: (String, TimeInterval) async -> TestShell.Result) async -> String? {
        if let s = t.scheme, !s.isEmpty { return s }
        let r = await run("xcodebuild \(xcodeContainer(targetDirectory(t))) -list -json 2>/dev/null", 120)
        guard let start = r.output.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(r.output[start...].utf8)) as? [String: Any] else { return nil }
        let info = (obj["workspace"] ?? obj["project"]) as? [String: Any]
        let schemes = info?["schemes"] as? [String] ?? []
        let dir = targetDirectory(t)
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let project = items.first { $0.hasSuffix(".xcodeproj") }
        let pbx = project.flatMap { try? String(contentsOf: dir.appendingPathComponent($0).appendingPathComponent("project.pbxproj"), encoding: .utf8) } ?? ""
        return XcodeSchemes.pick(schemes, appTargets: XcodeSchemes.appTargets(pbxproj: pbx),
                                 project: project.map { String($0.dropLast(".xcodeproj".count)) })
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
}

extension AppModel {
    /// Builds, tests and delivers one target as its method says, then sends the phone a review card.
    @discardableResult
    func deliverTest(scope: String, targetID: String, session: String? = nil, factory: String? = nil, workItem: Int? = nil) async -> TestDelivery? {
        await engine.tests.deliver(scope: scope, targetID: targetID, session: session, factory: factory, workItem: workItem)
    }

    func callEndpoint(_ c: EndpointCall, base: String) async -> EndpointCall { await engine.tests.callEndpoint(c, base: base) }

    func ensureDevServer(_ t: TestTarget) async -> Int? { await engine.tests.ensureDevServer(t) }

    func stopDevServer(_ id: String) { engine.tests.stopDevServer(id) }

    func respondToReview(_ id: String, action: String, text: String?) async -> String {
        await engine.tests.respond(id, action: action, text: text)
    }

    func testStatusJSON(scope: String) -> JSONValue { engine.tests.statusJSON(scope: scope) }

    func testStatusResult(scope: String) -> ActionResult { engine.tests.statusResult(scope: scope) }
}

private final class SnapshotLoader: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done = true }
}
