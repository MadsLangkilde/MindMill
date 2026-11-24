import XCTest
@testable import KBCore

final class TestAskTextTests: XCTestCase {
    private func facts(_ phones: [(String, String?)]) -> TestEnvironmentFacts {
        var f = TestEnvironmentFacts()
        f.phones = phones.map { .init(name: $0.0, platform: $0.1) }
        f.companionPaired = !phones.isEmpty
        return f
    }

    func testAndroidAppNamesTheAndroidPhone() {
        XCTAssertEqual(TestAskText.question(.android), "Try what this session builds on your Android phone?")
        let d = TestAskText.detail(.android, facts: facts([("Pixel 9", "android"), ("iPhone", "ios")]))
        XCTAssertTrue(d.hasSuffix("builds reach Pixel 9 at each checkpoint."), d)
    }

    func testAnIPhoneAloneDoesNotCountForAnAndroidApp() {
        let f = facts([("iPhone", "ios")])
        XCTAssertFalse(f.phonePaired(RemotePlatform.android))
        XCTAssertTrue(f.phonePaired(nil))
        XCTAssertTrue(TestAskText.detail(.android, facts: f).contains("No Android phone has Mindmill paired yet"))
    }

    func testAPhoneThatNeverSaidItsPlatformCounts() {
        XCTAssertTrue(facts([("Old phone", nil)]).phonePaired(RemotePlatform.android))
    }

    func testWebAppReachesEveryPhone() {
        let d = TestAskText.detail(.web, facts: facts([("Pixel 9", "android"), ("iPhone", "ios")]))
        XCTAssertTrue(d.hasSuffix("builds reach Pixel 9 and iPhone at each checkpoint."), d)
        XCTAssertTrue(TestAskText.detail(.web, facts: facts([])).contains("No phone has Mindmill paired yet"))
    }

    func testAndroidChecklistNeedsAnAndroidPhone() {
        let target = TestTarget(id: "t", type: .android, repo: "app", path: "/x", title: "App")
        var c = TestContext(facts: facts([("iPhone", "ios")]), target: target)
        let phone = AndroidTestAdapter().checklist("companion", c).first { $0.id == "phone" }
        XCTAssertEqual(phone?.status, .missing)
        XCTAssertEqual(phone?.title, "Mindmill on an Android phone is paired")
        c.facts = facts([("Pixel", "android")])
        XCTAssertEqual(AndroidTestAdapter().checklist("companion", c).first { $0.id == "phone" }?.status, .ok)
    }
}
