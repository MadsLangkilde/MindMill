import Foundation

/// What this Mac has for building and testing, gathered with shell commands. The compatibility check and the
/// checklists read it; nothing here decides by project type on its own.
public struct TestEnvironmentFacts: Codable, Equatable, Sendable {
    public struct Device: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable { case iphone, ipad, iosSimulator, android, androidEmulator, other }
        public var id: String
        public var name: String
        public var kind: Kind
        /// Paired with Xcode, or authorised for adb.
        public var paired: Bool
        public var booted: Bool

        public init(id: String, name: String, kind: Kind, paired: Bool = true, booted: Bool = false) {
            self.id = id
            self.name = name
            self.kind = kind
            self.paired = paired
            self.booted = booted
        }
    }

    public var os = ""
    public var osVersion = ""
    public var arch = ""
    public var cpu = ""
    public var gpu = ""
    /// Tool name → version (or "installed"), only for what is installed.
    public var toolchains: [String: String] = [:]
    public var devices: [Device] = []
    public var tailscaleRunning = false
    public var tailscaleName: String?
    public var tailscaleIP: String?
    /// `tailscale cert` works: HTTPS certificates are enabled for the tailnet.
    public var tailscaleHTTPS = false
    public var lanIP: String?
    /// Code-signing identities by name ("Apple Development: …", "Apple Distribution: …").
    public var signingIdentities: [String] = []
    /// An Apple account is signed in to Xcode, so a build with `-allowProvisioningUpdates` makes its own certificate
    /// and profile. Nil when not looked at.
    public var xcodeAccount: Bool?
    /// An App Store Connect API key (.p8) on this Mac.
    public var appStoreConnectKey = false
    /// The Mindmill app on a phone is connected right now.
    public var companionConnected = false
    /// A phone has been paired with this Mac at some point.
    public var companionPaired = false
    /// The phones paired with Mindmill: name and what they run (`android`/`ios`, nil when the phone hasn't said).
    public var phones: [Phone] = []
    public var gathered: Date?

    public struct Phone: Codable, Equatable, Sendable {
        public var name: String
        public var platform: String?

        public init(name: String, platform: String?) {
            self.name = name
            self.platform = platform
        }
    }

    public init() {}

    public func has(_ tool: String) -> Bool { toolchains[tool] != nil }

    /// Paired phones that can take a build for `platform` (any phone for nil). A phone that never said what it runs
    /// (an older app) counts, rather than blocking it.
    public func phones(for platform: String?) -> [Phone] {
        guard let platform else { return phones }
        return phones.filter { $0.platform == nil || $0.platform == platform }
    }

    /// Whether Mindmill on a phone for `platform` is paired. Without the list of phones, any paired phone counts.
    public func phonePaired(_ platform: String?) -> Bool {
        phones.isEmpty ? companionPaired || companionConnected : !phones(for: platform).isEmpty
    }

    /// Changes when something that matters for the compatibility check changes.
    public var fingerprint: String {
        ([os, osVersion, arch] + toolchains.keys.sorted().map { "\($0)=\(toolchains[$0] ?? "")" }
            + ["signing=\(signingIdentities.count)", "account=\(xcodeAccount.map(String.init) ?? "")"]).joined(separator: "|")
    }

    /// The facts as lines for the AI.
    public var summary: String {
        var lines = ["Host: \(os) \(osVersion), \(arch)", "CPU: \(cpu.isEmpty ? "unknown" : cpu)", "GPU: \(gpu.isEmpty ? "unknown" : gpu)"]
        lines.append("Installed toolchains and SDKs: " + (toolchains.isEmpty ? "none found" :
            toolchains.keys.sorted().map { "\($0) \(toolchains[$0] ?? "")" }.joined(separator: "; ")))
        lines.append("Devices and emulators: " + (devices.isEmpty ? "none found" :
            devices.map { "\($0.name) (\($0.kind.rawValue)\($0.paired ? "" : ", not paired")\($0.booted ? ", running" : ""))" }.joined(separator: "; ")))
        lines.append("Code-signing identities: \(signingIdentities.isEmpty ? "none" : signingIdentities.joined(separator: "; "))")
        if let xcodeAccount { lines.append("Apple account signed in to Xcode: \(xcodeAccount ? "yes (builds create their own development certificate)" : "no")") }
        lines.append("App Store Connect API key on this Mac: \(appStoreConnectKey ? "yes" : "no")")
        lines.append("Tailscale: \(tailscaleRunning ? "running\(tailscaleName.map { " as \($0)" } ?? "")\(tailscaleHTTPS ? ", HTTPS certificates on" : "")" : "not running")")
        lines.append("Companion phone app: \(companionConnected ? "connected" : companionPaired ? "paired, not connected now" : "not paired")"
            + (phones.isEmpty ? "" : " (" + phones.map { "\($0.name): \($0.platform ?? "unknown")" }.joined(separator: "; ") + ")"))
        return lines.joined(separator: "\n")
    }
}

/// One thing that must be in place before a delivery method works.
public struct ChecklistItem: Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case ok, missing, unknown }

    public var id: String
    public var title: String
    public var required: Bool
    public var status: Status
    /// Step-by-step instructions, including those on the phone.
    public var help: [String]
    /// Only the user can tell (a setting on the phone, a device registered in the developer account): they tick it.
    public var confirmable: Bool

    public init(id: String, title: String, required: Bool = true, status: Status, help: [String] = [], confirmable: Bool = false) {
        self.id = id
        self.title = title
        self.required = required
        self.status = status
        self.help = help
        self.confirmable = confirmable
    }

    /// Ready only when every required item passes; unknown is not a pass.
    public static func ready(_ items: [ChecklistItem]) -> Bool {
        items.allSatisfy { !$0.required || $0.status == .ok }
    }
}

/// How a build reaches the user.
public enum DeliveryKind: String, Codable, Sendable {
    /// An APK the phone downloads and installs.
    case apk
    /// A URL the phone opens.
    case url
    /// A page the Mac makes and the phone shows.
    case preview
    /// Installed on a paired iPhone from Xcode's tools.
    case iosDevice
    /// An ad hoc build with an install link.
    case iosLink
    /// Uploaded to TestFlight.
    case testflight
}

public struct TestMethod: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Why it's a good choice, in a sentence or two.
    public var why: String
    public var kind: DeliveryKind

    public init(id: String, title: String, why: String, kind: DeliveryKind) {
        self.id = id
        self.title = title
        self.why = why
        self.kind = kind
    }
}

/// What a checklist or delivery knows about one target.
public struct TestContext: Sendable {
    public var facts: TestEnvironmentFacts
    public var target: TestTarget
    public var listing: RepoListing?

    public init(facts: TestEnvironmentFacts, target: TestTarget, listing: RepoListing? = nil) {
        self.facts = facts
        self.target = target
        self.listing = listing
    }

    func confirmed(_ id: String) -> Bool { target.confirmed.contains(id) }
    func has(file: String) -> Bool { listing?.paths.contains(where: { $0 == file || $0.hasSuffix("/" + file) }) ?? false }
}

/// Testing for one kind of project: its delivery methods, the best one now, and what each needs. New adapters
/// are added to `TestAdapters.registry` without changing anything else.
public protocol TestAdapter: Sendable {
    var type: ProjectType { get }
    var methods: [TestMethod] { get }
    func recommended(_ facts: TestEnvironmentFacts) -> String
    func checklist(_ method: String, _ c: TestContext) -> [ChecklistItem]
}

public extension TestAdapter {
    func method(_ id: String?) -> TestMethod? { methods.first { $0.id == id } }

    /// The recommended method first, then the others.
    func ordered(_ facts: TestEnvironmentFacts) -> [TestMethod] {
        let rec = recommended(facts)
        return methods.filter { $0.id == rec } + methods.filter { $0.id != rec }
    }
}

public enum TestAdapters {
    public nonisolated(unsafe) static var registry: [any TestAdapter] = [
        AndroidTestAdapter(), WebTestAdapter(), IOSTestAdapter(), BackendTestAdapter(), MacDesktopTestAdapter(),
        ReportTestAdapter(type: .desktopWindows), ReportTestAdapter(type: .embedded), ReportTestAdapter(type: .unknown),
    ]

    public static func adapter(for type: ProjectType) -> any TestAdapter {
        registry.first { $0.type == type } ?? ReportTestAdapter(type: type)
    }

    public static func register(_ adapter: any TestAdapter) {
        registry.removeAll { $0.type == adapter.type }
        registry.append(adapter)
    }

    /// Every type can fall back to a page the Mac makes and the phone shows.
    public static let preview = TestMethod(id: "preview", title: "Preview page on the phone",
        why: "The Mac makes a page with the results, logs and screenshots, and the phone app shows it. Works for anything.", kind: .preview)

    public static func checklist(type: ProjectType, method: String, _ c: TestContext) -> [ChecklistItem] {
        if method == preview.id { return [Checks.phone(c)] + Checks.command(c, kind: "test") }
        return adapter(for: type).checklist(method, c)
    }
}

/// Checks several adapters share.
enum Checks {
    static func phone(_ c: TestContext, platform: String? = nil, required: Bool = true) -> ChecklistItem {
        let phone = TestAskText.phoneName(platform)
        return ChecklistItem(id: "phone", title: "Mindmill on \(phone.article) is paired", required: required,
                             status: c.facts.phonePaired(platform) ? .ok : .missing,
                             help: ["Install Mindmill on \(phone.the).", "On this Mac: Settings → Remote → turn it on → Show Pairing Code.",
                                    "On \(phone.the): open Mindmill and scan the code."])
    }

    static func tool(_ c: TestContext, _ name: String, title: String, help: [String], required: Bool = true) -> ChecklistItem {
        ChecklistItem(id: "tool-" + name, title: title, required: required, status: c.facts.has(name) ? .ok : .missing, help: help)
    }

    static func confirm(_ c: TestContext, _ id: String, _ title: String, help: [String], required: Bool = true) -> ChecklistItem {
        ChecklistItem(id: id, title: title, required: required, status: c.confirmed(id) ? .ok : .unknown, help: help, confirmable: true)
    }

    static func command(_ c: TestContext, kind: String) -> [ChecklistItem] {
        let value = kind == "start" ? c.target.startCommand : kind == "build" ? c.target.buildCommand : c.target.testCommand
        let set = !(value ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return [ChecklistItem(id: "cmd-" + kind, title: "A \(kind) command", status: set ? .ok : .missing,
                              help: ["Under More options, enter the command that \(kind == "start" ? "starts it" : kind == "build" ? "builds it" : "runs its tests"), e.g. \(kind == "test" ? "`npm test`" : "`npm run dev`")."])]
    }

    static func tailscale(_ c: TestContext, required: Bool) -> ChecklistItem {
        ChecklistItem(id: "tailscale", title: "Phone reachable over Tailscale", required: required,
                      status: c.facts.tailscaleRunning ? .ok : .missing,
                      help: ["Install Tailscale on this Mac and the phone and sign in to the same tailnet.",
                             "Leave it on: the phone then reaches this Mac away from home too."])
    }
}

public struct AndroidTestAdapter: TestAdapter {
    public init() {}
    public let type = ProjectType.android
    public let methods = [
        TestMethod(id: "companion", title: "Install on the phone through Mindmill",
                   why: "The Mac builds the APK and Mindmill on the phone downloads and installs it. No cable or wireless debugging, and it works away from home over Tailscale.", kind: .apk),
        TestAdapters.preview,
    ]

    public func recommended(_ facts: TestEnvironmentFacts) -> String { "companion" }

    public func checklist(_ method: String, _ c: TestContext) -> [ChecklistItem] {
        [
            ChecklistItem(id: "android-sdk", title: "Android SDK and Java on this Mac",
                          status: c.facts.has("android-sdk") && c.facts.has("java") ? .ok : .missing,
                          help: ["Install Android Studio, open it once and let it install the SDK.", "Install a JDK 17 or newer (Android Studio's bundled one works)."]),
            ChecklistItem(id: "gradle", title: "The project builds with Gradle",
                          status: c.listing == nil ? .unknown : (c.has(file: "gradlew") || c.facts.has("gradle") ? .ok : .missing),
                          help: ["Add the Gradle wrapper to the project (`gradle wrapper`), or install Gradle."]),
            Checks.phone(c, platform: RemotePlatform.android),
            Checks.confirm(c, "install-allowed", "Mindmill on the phone may install apps", help: [
                "On the phone: Settings → Apps → Mindmill → Install unknown apps → Allow from this source.",
                "Mindmill asks for this the first time it installs a build; this ticks itself after the first install.",
            ], required: false),
            Checks.tailscale(c, required: false),
        ]
    }
}

public struct WebTestAdapter: TestAdapter {
    public init() {}
    public let type = ProjectType.web
    public let methods = [
        TestMethod(id: "tailscale-url", title: "Open the local version on the phone",
                   why: "The Mac runs the dev server and the phone opens it at the Mac's address, in Mindmill or the browser. Changes show on reload, at home or away over Tailscale.", kind: .url),
        TestAdapters.preview,
    ]

    public func recommended(_ facts: TestEnvironmentFacts) -> String { "tailscale-url" }

    public func checklist(_ method: String, _ c: TestContext) -> [ChecklistItem] {
        var items = Checks.command(c, kind: "start")
        if c.has(file: "package.json") {
            items.append(Checks.tool(c, "node", title: "Node.js on this Mac", help: ["Install Node.js (nodejs.org or `brew install node`)."]))
        }
        items.append(Checks.confirm(c, "listens-all", "The dev server accepts other devices", help: [
            "Start it on all interfaces, not only localhost: e.g. `vite --host`, `next dev -H 0.0.0.0`, `ng serve --host 0.0.0.0`.",
            "Put that in the start command under More options.",
        ]))
        items.append(Checks.phone(c))
        items.append(Checks.tailscale(c, required: false))
        return items
    }
}

public struct IOSTestAdapter: TestAdapter {
    public init() {}
    public let type = ProjectType.ios
    public let methods = [
        TestMethod(id: "direct", title: "Install directly on your iPhone",
                   why: "Fastest: Xcode's tools install over the network on a paired iPhone. Pair once over a cable; works best on the same network.", kind: .iosDevice),
        TestMethod(id: "link", title: "Install link over Tailscale",
                   why: "Fast and works away from home: an ad hoc build with a link you open on the iPhone. The iPhone must be registered in your developer account.", kind: .iosLink),
        TestMethod(id: "testflight", title: "TestFlight",
                   why: "The most robust away from home, but each build waits for upload and processing.", kind: .testflight),
        TestAdapters.preview,
    ]

    public func recommended(_ facts: TestEnvironmentFacts) -> String {
        if facts.devices.contains(where: { ($0.kind == .iphone || $0.kind == .ipad) && $0.paired }) { return "direct" }
        if facts.tailscaleHTTPS { return "link" }
        return "direct"
    }

    public func checklist(_ method: String, _ c: TestContext) -> [ChecklistItem] {
        var items = [Checks.tool(c, "xcode", title: "Xcode on this Mac", help: ["Install Xcode from the App Store and open it once."])]
        let development = c.facts.signingIdentities.contains { $0.contains("Apple Development") || $0.contains("iPhone Developer") }
        let distribution = c.facts.signingIdentities.contains { $0.contains("Apple Distribution") || $0.contains("iPhone Distribution") }
        switch method {
        case "direct":
            items.append(ChecklistItem(id: "paired", title: "iPhone paired with Xcode",
                                       status: c.facts.devices.contains { ($0.kind == .iphone || $0.kind == .ipad) && $0.paired } ? .ok : .missing,
                                       help: ["Connect the iPhone with a cable and unlock it.", "On the iPhone: tap Trust This Computer.",
                                              "In Xcode: Window → Devices and Simulators → select the iPhone → Connect via network.",
                                              "On the iPhone: Settings → Privacy & Security → Developer Mode → On, then restart it."]))
            items.append(ChecklistItem(id: "signing", title: development ? "A development signing certificate" : "Your Apple account in Xcode",
                                       status: development || c.facts.xcodeAccount == true ? .ok : .missing,
                                       help: ["Open Xcode → Settings → Accounts → + → Apple Account, and sign in (a free account works).",
                                              "That's all: the first build makes the signing certificate and installs it."]))
        case "link":
            items.append(ChecklistItem(id: "signing", title: "A distribution signing certificate", status: distribution ? .ok : .missing,
                                       help: ["In Xcode: Settings → Accounts → Manage Certificates → + Apple Distribution."]))
            items.append(Checks.confirm(c, "registered", "The iPhone is registered in your developer account", help: [
                "On developer.apple.com → Certificates, IDs & Profiles → Devices → +, add the iPhone's UDID (Finder shows it when the iPhone is connected).",
            ]))
            items.append(ChecklistItem(id: "tailscale-https", title: "Tailscale HTTPS certificates on", status: c.facts.tailscaleHTTPS ? .ok : .missing,
                                       help: ["In the Tailscale admin console → DNS: turn on MagicDNS and HTTPS Certificates.", "Install Tailscale on the iPhone and sign in."]))
        case "testflight":
            items.append(ChecklistItem(id: "asc-key", title: "App Store Connect API key on this Mac", status: c.facts.appStoreConnectKey ? .ok : .missing,
                                       help: ["App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key with the App Manager role.",
                                              "Save the .p8 file in ~/.appstoreconnect/private_keys/ on this Mac (it stays on the Mac).",
                                              "Enter the key ID and issuer ID under More options."]))
            items.append(ChecklistItem(id: "signing", title: "A distribution signing certificate", status: distribution ? .ok : .missing,
                                       help: ["In Xcode: Settings → Accounts → Manage Certificates → + Apple Distribution."]))
            items.append(Checks.confirm(c, "app-record", "The app exists in App Store Connect", help: ["App Store Connect → Apps → + New App, with the project's bundle id."]))
            items.append(Checks.confirm(c, "testflight-app", "TestFlight is on the iPhone", help: ["On the iPhone: install TestFlight from the App Store and sign in with the tester's Apple ID."]))
        default:
            return [Checks.phone(c)] + Checks.command(c, kind: "test")
        }
        return items
    }
}

public struct BackendTestAdapter: TestAdapter {
    public init() {}
    public let type = ProjectType.backend
    public let methods = [
        TestMethod(id: "backend-preview", title: "Results page on the phone",
                   why: "The Mac runs the tests and the endpoints you list, and the phone shows the results, example requests and responses, failures, and a panel to try a call.", kind: .preview),
    ]

    public func recommended(_ facts: TestEnvironmentFacts) -> String { "backend-preview" }

    public func checklist(_ method: String, _ c: TestContext) -> [ChecklistItem] {
        Checks.command(c, kind: "test") + [Checks.phone(c)]
    }
}

public struct MacDesktopTestAdapter: TestAdapter {
    public init() {}
    public let type = ProjectType.desktopMac
    public let methods = [
        TestMethod(id: "mac-report", title: "Build here, report on the phone",
                   why: "It runs on this Mac, so the Mac builds and tests it and the phone shows the results and logs.", kind: .preview),
    ]

    public func recommended(_ facts: TestEnvironmentFacts) -> String { "mac-report" }

    public func checklist(_ method: String, _ c: TestContext) -> [ChecklistItem] {
        Checks.command(c, kind: "test") + [Checks.phone(c)]
    }
}

/// Windows apps, embedded software and anything unrecognised: a report page with tests, logs, device output and graphs.
public struct ReportTestAdapter: TestAdapter {
    public let type: ProjectType
    public init(type: ProjectType) { self.type = type }
    public var methods: [TestMethod] {
        [TestMethod(id: "report", title: "Report page on the phone",
                    why: type == .embedded ? "The Mac builds and tests it, captures the device's serial output, and the phone shows reports, logs and graphs."
                        : "The Mac runs the build and tests and the phone shows the report and logs.", kind: .preview)]
    }

    public func recommended(_ facts: TestEnvironmentFacts) -> String { "report" }

    public func checklist(_ method: String, _ c: TestContext) -> [ChecklistItem] {
        var items = Checks.command(c, kind: "test")
        if type == .embedded {
            items.append(ChecklistItem(id: "serial", title: "Serial output command", required: false,
                                       status: (c.target.serialCommand ?? "").isEmpty ? .missing : .ok,
                                       help: ["Optional: a command that prints the device's output for a few seconds, e.g. `pio device monitor` or `cat /dev/cu.usbmodem1101`."]))
        }
        items.append(Checks.phone(c))
        return items
    }
}
