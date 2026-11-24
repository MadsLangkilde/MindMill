import Foundation
import Testing
@testable import KBCore

@Suite struct LayoutTests {
    @Test func panelDocksByWhereItIsDropped() {
        let size = CGSize(width: 800, height: 600)
        #expect(PanelDock.drop(at: CGPoint(x: 700, y: 100), in: size) == .top)
        #expect(PanelDock.drop(at: CGPoint(x: 100, y: 500), in: size) == .bottomLeading)
        #expect(PanelDock.drop(at: CGPoint(x: 600, y: 500), in: size) == .bottomTrailing)
        #expect(PanelDock.standard == .bottomTrailing)
    }

    @Test func resetRemovesOnlyThatScreensLayout() throws {
        let d = try #require(UserDefaults(suiteName: "kb-layout-\(UUID().uuidString)"))
        for key in LayoutReset.keys(.build) + LayoutReset.keys(.plan) { d.set("x", forKey: key) }
        d.set("frames", forKey: SplitViewMemory.sharedKey)
        d.set("keep", forKey: "appTheme")
        LayoutReset.reset([.build], current: .build, defaults: d)
        #expect(LayoutReset.keys(.build).allSatisfy { d.object(forKey: $0) == nil })
        #expect(LayoutReset.keys(.plan).allSatisfy { d.object(forKey: $0) != nil })
        #expect(d.object(forKey: SplitViewMemory.sharedKey) == nil)
        #expect(d.string(forKey: "appTheme") == "keep")
    }

    @Test func badgesCountTheSameThings() {
        let t = WaitingTally(buildSessions: 1, overseer: true, factoryQuestions: 0, planSessions: 1)
        #expect(t.overview == 2)
        #expect(t.build == 2)
        #expect(WaitingTally(buildSessions: 0, overseer: false, factoryQuestions: 2, planSessions: 0).overview == 2)
    }

    @Test func conflictPromptNamesBothBranchesAndNeverRewritesHistory() {
        let pr = PullRequest(id: 7, title: "x", source: "feature/a", target: "develop", blockers: [PRBlocker.conflicts])
        let text = PRFix.conflicts(pr)
        #expect(text.contains("`origin/develop`") && text.contains("`feature/a`"))
        #expect(text.contains("Never rebase, force-push or rewrite history"))
    }
}
