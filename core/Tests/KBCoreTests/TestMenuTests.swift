import Foundation
import Testing
@testable import KBCore

struct ProjectDetectionTests {
    @Test func findsAnAndroidApp() {
        let l = RepoListing(files: ["settings.gradle.kts": "", "gradlew": "", "app/build.gradle.kts": "plugins { id(\"com.android.application\") }",
                                    "app/src/main/AndroidManifest.xml": "<manifest/>"])
        let t = ProjectDetector.detect(l)
        #expect(t.map(\.type) == [.android])
        #expect(t.first?.path == "", "built from the Gradle root, where gradlew is")
        #expect(t.first?.startCommand == "./gradlew assembleDebug")
    }

    @Test func findsAniOSAppByItsSDK() {
        let l = RepoListing(files: ["Shop.xcodeproj/project.pbxproj": "SDKROOT = iphoneos;", "Shop/App.swift": ""])
        #expect(ProjectDetector.detect(l).map(\.type) == [.ios])
        let mac = RepoListing(files: ["Tool.xcodeproj/project.pbxproj": "SDKROOT = macosx;"])
        #expect(ProjectDetector.detect(mac).map(\.type) == [.desktopMac])
    }

    @Test func findsEveryTargetInAMonorepo() {
        let l = RepoListing(files: [
            "mobile/app/build.gradle": "apply plugin: 'com.android.application'",
            "web/package.json": #"{"scripts":{"dev":"vite"},"dependencies":{"react":"18"}}"#,
            "web/index.html": "",
            "api/go.mod": "module x",
            "firmware/platformio.ini": "[env:esp32]",
        ])
        let t = ProjectDetector.detect(l)
        #expect(Set(t.map(\.type)) == [.android, .web, .backend, .embedded])
        #expect(t.first { $0.type == .web }?.startCommand == "npm run dev")
        #expect(t.first { $0.type == .backend }?.path == "api")
    }

    @Test func tellsAFrontEndFromANodeService() {
        let api = RepoListing(files: ["package.json": #"{"scripts":{"start":"node index.js","test":"jest"},"dependencies":{"express":"4"}}"#])
        let t = ProjectDetector.detect(api)
        #expect(t.map(\.type) == [.backend])
        #expect(t.first?.testCommand == "npm test")
    }

    @Test func unknownWhenNothingMatches() {
        let t = ProjectDetector.detect(RepoListing(files: ["notes.txt": "hello"]))
        #expect(t.map(\.type) == [.unknown])
    }

    @Test func doesNotCountTheSameAppTwice() {
        let l = RepoListing(files: ["build.gradle": "com.android.application", "app/build.gradle": "com.android.application"])
        #expect(ProjectDetector.detect(l).count == 1)
    }
}

struct TestAdapterTests {
    var facts: TestEnvironmentFacts {
        var f = TestEnvironmentFacts()
        f.toolchains = ["xcode": "26.1", "android-sdk": "36", "java": "21", "node": "22"]
        return f
    }

    @Test func everyTypeHasAnAdapterWithARecommendation() {
        for type in ProjectType.allCases {
            let a = TestAdapters.adapter(for: type)
            #expect(a.type == type)
            #expect(a.method(a.recommended(facts)) != nil)
            #expect(a.ordered(facts).first?.id == a.recommended(facts))
        }
    }

    @Test func androidGoesThroughTheCompanionApp() {
        let a = TestAdapters.adapter(for: .android)
        #expect(a.recommended(facts) == "companion")
        #expect(a.method("companion")?.kind == .apk)
    }

    @Test func iOSPrefersDirectInstallWithAPairedPhoneAndTheLinkWithoutOne() {
        var f = facts
        f.tailscaleHTTPS = true
        let a = TestAdapters.adapter(for: .ios)
        #expect(a.recommended(f) == "link")
        f.devices = [.init(id: "1", name: "iPhone", kind: .iphone, paired: true)]
        #expect(a.recommended(f) == "direct")
        #expect(a.methods.map(\.id) == ["direct", "link", "testflight", "preview"])
    }

    @Test func newAdaptersCanBeRegistered() {
        struct Fake: TestAdapter {
            let type = ProjectType.desktopWindows
            let methods = [TestMethod(id: "vm", title: "VM", why: "", kind: .preview)]
            func recommended(_ facts: TestEnvironmentFacts) -> String { "vm" }
            func checklist(_ method: String, _ c: TestContext) -> [ChecklistItem] { [] }
        }
        let before = TestAdapters.registry
        defer { TestAdapters.registry = before }
        TestAdapters.register(Fake())
        #expect(TestAdapters.adapter(for: .desktopWindows).recommended(facts) == "vm")
    }
}

struct ChecklistTests {
    func context(_ f: TestEnvironmentFacts, confirmed: [String] = [], files: [String: String] = ["gradlew": ""]) -> TestContext {
        var t = TestTarget(type: .android, repo: "/r", path: "", title: "App")
        t.confirmed = confirmed
        return TestContext(facts: f, target: t, listing: RepoListing(files: files))
    }

    @Test func readyOnlyWhenEveryRequiredItemPasses() {
        var f = TestEnvironmentFacts()
        f.toolchains = ["android-sdk": "36", "java": "21"]
        var items = TestAdapters.checklist(type: .android, method: "companion", context(f))
        #expect(!ChecklistItem.ready(items))
        #expect(items.first { $0.id == "phone" }?.status == .missing)
        #expect(items.first { $0.id == "install-allowed" }?.status == .unknown)

        f.companionPaired = true
        items = TestAdapters.checklist(type: .android, method: "companion", context(f))
        #expect(items.first { $0.id == "tailscale" }?.status == .missing)
        #expect(ChecklistItem.ready(items), "the phone asks to install apps at the first build, and Tailscale is optional")

        items = TestAdapters.checklist(type: .android, method: "companion", context(f, confirmed: ["install-allowed"]))
        #expect(items.first { $0.id == "install-allowed" }?.status == .ok)
    }

    @Test func missingToolBlocks() {
        var f = TestEnvironmentFacts()
        f.companionPaired = true
        let items = TestAdapters.checklist(type: .android, method: "companion", context(f, confirmed: ["install-allowed"]))
        #expect(items.first { $0.id == "android-sdk" }?.status == .missing)
        #expect(!ChecklistItem.ready(items))
    }

    @Test func webNeedsAStartCommand() {
        var f = TestEnvironmentFacts()
        f.companionConnected = true
        var t = TestTarget(type: .web, repo: "/r", path: "", title: "Site")
        t.confirmed = ["listens-all"]
        var items = TestAdapters.checklist(type: .web, method: "tailscale-url", TestContext(facts: f, target: t))
        #expect(!ChecklistItem.ready(items))
        t.startCommand = "npm run dev -- --host"
        items = TestAdapters.checklist(type: .web, method: "tailscale-url", TestContext(facts: f, target: t))
        #expect(ChecklistItem.ready(items))
    }
}

struct TestPlanTests {
    @Test func dontAskStopsThePromptForGoodAndNotNowOnlyForThisRun() {
        var store = TestStore()
        var ask = TestAsk()
        #expect(ask.shouldAsk(scope: "shop", plan: store["shop"]))
        ask.notNow("shop")
        #expect(!ask.shouldAsk(scope: "shop", plan: store["shop"]))
        #expect(TestAsk().shouldAsk(scope: "shop", plan: store["shop"]), "a new run asks again")

        TestAsk.dontAsk(&store["shop"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("testing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        store.save(url)
        let reloaded = TestStore.load(url)
        #expect(!TestAsk().shouldAsk(scope: "shop", plan: reloaded["shop"]), "after Don't ask, a new run doesn't ask")
        #expect(TestAsk().shouldAsk(scope: "other", plan: reloaded["other"]))
    }

    @Test func noPromptOnceSetUp() {
        var plan = ScopeTestPlan()
        var t = TestTarget(type: .web, repo: "/r", path: "", title: "Site")
        plan.targets = [t]
        #expect(TestAsk().shouldAsk(scope: "s", plan: plan))
        t.method = "tailscale-url"
        plan.targets = [t]
        #expect(!TestAsk().shouldAsk(scope: "s", plan: plan))
    }

    @Test func suggestionsCanBeAcceptedOrDismissed() {
        var plan = ScopeTestPlan()
        plan.targets = [TestTarget(id: "w", type: .web, repo: "/r", path: "", title: "Site")]
        plan.suggestions = [
            TestSuggestion(id: "a", text: "Use port 5173", target: "w", set: ["port": "5173", "start": "npm run dev -- --host"]),
            TestSuggestion(id: "b", text: "Deliver only when tests pass", set: ["deliverWhen": "whenTestsPass"]),
            TestSuggestion(id: "c", text: "Nah"),
        ]
        let acceptedA = plan.accept("a")
        #expect(acceptedA)
        #expect(plan.targets[0].port == 5173)
        #expect(plan.targets[0].startCommand == "npm run dev -- --host")
        let acceptedB = plan.accept("b")
        #expect(acceptedB)
        #expect(plan.deliverWhen == .whenTestsPass)
        plan.dismiss("c")
        #expect(plan.suggestions.isEmpty)
        let again = plan.accept("a")
        #expect(!again)
    }

    @Test func parsesQueuedSuggestions() throws {
        let data = try JSONSerialization.data(withJSONObject: ["kind": "test_suggest", "scope": "shop", "text": "Open /cart first",
                                                               "target": "w", "set": ["pages": "/cart"], "from": "s1"])
        let (scope, s) = try #require(TestSuggestion.parse(data))
        #expect(scope == "shop")
        #expect(s.set == ["pages": "/cart"])
        #expect(s.from == "s1")
    }

    @Test func mergingKeepsSettingsAndDropsVanishedUnsetTargets() {
        var plan = ScopeTestPlan()
        var kept = TestTarget(id: "k", type: .web, repo: "/r", path: "web", title: "Web")
        kept.method = "tailscale-url"
        plan.targets = [kept, TestTarget(id: "gone", type: .backend, repo: "/r", path: "api", title: "API")]
        plan.merge(detected: [TestTarget(id: "k", type: .web, repo: "/r", path: "web", title: "Web"),
                              TestTarget(id: "new", type: .android, repo: "/r", path: "app", title: "App")])
        #expect(plan.targets.map(\.id) == ["k", "new"])
        #expect(plan.targets[0].method == "tailscale-url")
    }
}

struct CompatibilityCheckTests {
    @Test func goodToGoWithoutCriticalFindings() throws {
        let r = try #require(CompatibilityCheck.parse("Sure:\n{\"critical\": []}", fingerprint: "f"))
        #expect(r.good)
        #expect(CompatibilityCheck.sessionNote(r) == nil)
    }

    @Test func readsCriticalFindings() throws {
        let reply = #"{"critical":[{"title":"No Xcode on Windows","detail":"iOS needs macOS.","canStill":"Write code","cannot":"Build or run the iOS app","fix":""}]}"#
        let r = try #require(CompatibilityCheck.parse(reply, fingerprint: "f"))
        #expect(!r.good)
        #expect(r.findings.first?.cannot == "Build or run the iOS app")
        #expect(r.findings.first?.fix == nil)
        #expect(CompatibilityCheck.sessionNote(r)?.contains("Build or run the iOS app") == true)
    }

    @Test func notJSONIsNoResult() {
        #expect(CompatibilityCheck.parse("Looks fine to me!", fingerprint: "f") == nil)
    }

    @Test func runsAgainWhenTargetsOrToolsChange() {
        var plan = ScopeTestPlan()
        plan.targets = [TestTarget(type: .ios, repo: "/r", path: "", title: "App")]
        var facts = TestEnvironmentFacts()
        facts.toolchains = ["xcode": "26.0"]
        let fp = plan.compatibilityFingerprint(facts)
        #expect(plan.needsCompatibilityCheck(fingerprint: fp))
        plan.compatibility = CompatibilityResult(checked: Date(), findings: [], fingerprint: fp)
        #expect(!plan.needsCompatibilityCheck(fingerprint: fp))
        facts.toolchains["xcode"] = "26.1"
        #expect(plan.needsCompatibilityCheck(fingerprint: plan.compatibilityFingerprint(facts)))
    }

    @Test func thePromptCarriesTheFactsNotRules() {
        var facts = TestEnvironmentFacts()
        facts.os = "macOS"
        facts.arch = "arm64"
        facts.toolchains = ["node": "22.1"]
        let p = CompatibilityCheck.prompt(facts: facts, targets: [TestTarget(type: .web, repo: "/r", path: "web", title: "W")], description: "A shop")
        #expect(p.contains("arm64") && p.contains("node 22.1") && p.contains("Website") && p.contains("A shop"))
    }
}

struct DeliveryTests {
    @Test func splitsFilesIntoFramesWithAChecksum() throws {
        let data = Data((0..<(DeliveryFiles.chunkSize * 2 + 10)).map { UInt8($0 % 251) })
        let frames = DeliveryFiles.frames(data, delivery: "d1")
        #expect(frames.count == 3)
        #expect(frames.last?.header["last"] == .bool(true))
        #expect(frames.first?.header["last"] == .bool(false))
        let back = frames.reduce(Data()) { $0 + (RemoteFrame.decode($1.encoded())?.payload ?? Data()) }
        #expect(DeliveryFiles.sha256(back) == DeliveryFiles.sha256(data))
    }

    @Test func previewPathsStayInsideTheFolder() {
        #expect(DeliveryFiles.safePath("index.html") == "index.html")
        #expect(DeliveryFiles.safePath("") == "index.html")
        #expect(DeliveryFiles.safePath("img/a.png?x=1") == "img/a.png")
        #expect(DeliveryFiles.safePath("../secrets") == nil)
    }

    @Test func readsTestTotals() {
        #expect(TestRunSummary.parse("Tests:       1 failed, 12 passed, 13 total", exitCode: 1).failed == 1)
        #expect(TestRunSummary.parse("===== 5 passed, 2 failed in 0.3s =====", exitCode: 1).passed == 5)
        let x = TestRunSummary.parse("Executed 7 tests, with 0 failures (0 unexpected)", exitCode: 0)
        #expect(x.passed == 7 && x.ok)
        #expect(TestRunSummary.parse("10 tests completed, 3 failed", exitCode: 1).failed == 3)
        #expect(!TestRunSummary.parse("boom", exitCode: 2).ok)
    }

    @Test func deliveriesSayWhichPhoneTheyAreFor() {
        #expect(TestDelivery(scope: "s", target: "t", kind: .iosDevice, title: "x").event == nil)
        let apk = TestDelivery(scope: "s", target: "t", kind: .apk, title: "x").event
        #expect(apk?["kind"]?.string == "apk")
        #expect(apk?["platform"]?.string == "android")
        let link = TestDelivery(scope: "s", target: "t", kind: .iosLink, title: "x")
        #expect(link.phoneKind == "url")
        #expect(link.event?["platform"]?.string == "ios")
        let tf = TestDelivery(scope: "s", target: "t", kind: .testflight, title: "x")
        #expect(tf.event?["kind"]?.string == "testflight")
        #expect(tf.event?["platform"]?.string == "ios")
        #expect(tf.summary["platform"]?.string == "ios")
        #expect(TestDelivery(scope: "s", target: "t", kind: .preview, title: "x").event?["platform"] == nil)
        var card = TestReviewCard(scope: "s", title: "t", summary: "", delivery: tf.id)
        card.platform = tf.platform
        #expect(card.json["platform"]?.string == "ios")
    }

    @Test func reviewCardsCompareWithTheOneBefore() {
        let old = TestReviewCard(id: "old", scope: "s", title: "a", summary: "", images: [.init(title: "Home", path: "home.png")])
        var new = TestReviewCard(id: "new", scope: "s", title: "b", summary: "", images: [.init(title: "Home", path: "home.png"), .init(title: "Cart", path: "cart.png")])
        let copies = new.compare(with: old)
        #expect(new.images[0].before == "before-home.png")
        #expect(new.images[1].before == nil)
        #expect(copies.count == 1)
        #expect(new.json["images"]?.array?.first?["before"]?.string == "before-home.png")
    }

    @Test func plotsNumbersFromDeviceOutput() {
        let s = PreviewPages.series(from: "temp=21.5\ntemp=21.7 rpm: 1200\ntemp=22.0 rpm: 1250\nrpm: 1300")
        #expect(s["temp"] == [21.5, 21.7, 22.0])
        #expect(s["rpm"]?.count == 3)
        #expect(PreviewPages.chart([1, 2, 3]).contains("<polyline"))
    }

    @Test func endpointsFromLines() {
        #expect(EndpointCall.parse("GET /health")?.path == "/health")
        #expect(EndpointCall.parse("post /items {\"a\":1}")?.request == "{\"a\":1}")
        #expect(EndpointCall.parse("health") == nil)
    }
}
