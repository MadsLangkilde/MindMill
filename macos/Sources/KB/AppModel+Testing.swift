import Foundation
import KBCore
import KBEngine

/// Testing runs in the engine (`TestRunner`); the Mac adds Xcode, simulators, TestFlight and WebKit through
/// `MacTestPlatform`, and keeps what its windows show (the Test menu, offers under sessions).
extension AppModel {
    var testing: TestCenter { engine.tests.center }

    var testEnvironment: [String: String] { engine.tests.environment }

    func gatherTestFacts() async { await engine.tests.gatherFacts() }

    var currentTestFacts: TestEnvironmentFacts { engine.tests.currentFacts }

    func detectTestTargets(_ scope: String) { engine.tests.detectTargets(scope) }

    func testTargetDirectory(_ t: TestTarget) -> URL { engine.tests.directory(t) }

    func testContext(_ t: TestTarget) -> TestContext { engine.tests.context(t) }

    func testChecklist(_ t: TestTarget, method: String? = nil) -> [ChecklistItem] { engine.tests.checklist(t, method: method) }

    func testTargetReady(_ t: TestTarget) -> Bool { engine.tests.ready(t) }

    func projectDescription(_ scope: String) -> String? { engine.tests.projectDescription(scope) }

    func runCompatibilityCheck(_ scope: String, force: Bool = false) async { await engine.tests.runCompatibilityCheck(scope, force: force) }

    func testProjectOpened(_ scope: String) { engine.tests.projectOpened(scope) }

    func testScopesChanged() { engine.tests.scopesChanged() }

    func testingNote(_ scope: String?) -> String { engine.tests.sessionNote(scope) }

    // MARK: Asking sessions and factories

    /// After a Build session's turn that changed files: offer to set up testing once, when the scope has none.
    func offerTesting(_ s: WorkSession) {
        guard s.space == .build, s.role != .overseer, !s.testAskShown, !s.chat.isBusy, let scope = s.project,
              testing.ask.shouldAsk(scope: scope, plan: testing.store[scope]), s.editedFiles else { return }
        s.testAskShown = true
    }

    func sessionEditedFiles(_ s: WorkSession) -> Bool { s.editedFiles }

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

    func testingAfterTurn(_ s: WorkSession) { engine.tests.afterTurn(s) }

    func testingCheckpoint(sessionID: String, checkpoint: String?) { engine.tests.checkpoint(sessionID: sessionID, checkpoint: checkpoint) }

    func testSuggested(_ data: Data) -> Bool { engine.tests.suggested(data) }
}
