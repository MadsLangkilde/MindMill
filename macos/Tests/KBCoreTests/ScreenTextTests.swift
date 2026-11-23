import Testing
@testable import KBCore

struct ScreenTextTests {
    @Test func aNewSlideIsAllNew() {
        let added = ScreenText.added(["Roadmap 2027", "Android and iOS share one backlog"], since: ["Agenda", "Intro"])
        #expect(added == ["Roadmap 2027", "Android and iOS share one backlog"])
    }

    @Test func scrollingGivesOnlyWhatScrolledIn() {
        let before = ["Step one: create the PBI", "Step two: branch from main"]
        let after = ["Step two: branch from main", "Step three: open the pull request"]
        #expect(ScreenText.added(after, since: before) == ["Step three: open the pull request"])
    }

    @Test func aTickingClockIsNotWorthALine() {
        #expect(ScreenText.added(["12:35", "Mute"], since: ["12:34", "Mute"]) == nil)
    }

    @Test func casingAndSpacingDoNotCountAsNew() {
        #expect(ScreenText.added(["Release  PLAN for v1."], since: ["release plan for v1"]) == nil)
    }

    @Test func linesAreJoinedAndCut() {
        #expect(ScreenText.line(["a b", "c\nd"]) == "a b / c d")
        let long = ScreenText.line([String(repeating: "x", count: ScreenText.maxLength + 50)])
        #expect(long.count == ScreenText.maxLength + 2)
    }

    @Test func difference() {
        #expect(ScreenText.difference([0, 10], [0, 10]) == 0)
        #expect(ScreenText.difference([0, 10], [10, 0]) == 10)
        #expect(ScreenText.difference([], []) == 255)
    }
}
