import Foundation
import Testing
@testable import KBCore

struct SplitViewMemoryTests {
    private func fresh() -> UserDefaults {
        let name = "SplitViewMemoryTests-" + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private let plan = ["0, 0, 240, 900, NO, NO", "241, 0, 400, 900, NO, NO", "642, 0, 870, 900, NO, NO"]
    private let build = ["0, 0, 270, 900, NO, NO", "271, 0, 1241, 900, NO, NO"]

    @Test func aModeSeenForTheFirstTimeStartsWithoutTheOtherModesColumns() {
        let d = fresh()
        d.set(plan, forKey: SplitViewMemory.sharedKey)
        SplitViewMemory.swap(from: "plan", to: "build", defaults: d)
        #expect(d.object(forKey: SplitViewMemory.sharedKey) == nil)
    }

    @Test func eachModeGetsItsOwnColumnsBack() {
        let d = fresh()
        let build = ["0, 0, 240, 900, NO, NO", "241, 0, 1271, 900, NO, NO"]
        d.set(plan, forKey: SplitViewMemory.sharedKey)
        SplitViewMemory.swap(from: "plan", to: "build", defaults: d)
        d.set(build, forKey: SplitViewMemory.sharedKey)
        SplitViewMemory.swap(from: "build", to: "plan", defaults: d)
        #expect(d.stringArray(forKey: SplitViewMemory.sharedKey) == plan)
        SplitViewMemory.swap(from: "plan", to: "build", defaults: d)
        #expect(d.stringArray(forKey: SplitViewMemory.sharedKey) == build)
    }

    @Test func theSidebarKeepsItsWidthAcrossModes() {
        let d = fresh()
        d.set(plan, forKey: SplitViewMemory.sharedKey)
        SplitViewMemory.swap(from: "plan", to: "build", defaults: d)
        d.set(build, forKey: SplitViewMemory.sharedKey)
        SplitViewMemory.swap(from: "build", to: "plan", defaults: d)
        #expect(d.stringArray(forKey: SplitViewMemory.sharedKey) == ["0, 0, 270, 900, NO, NO", "271, 0, 370, 900, NO, NO", "642, 0, 870, 900, NO, NO"])
        let wider = ["0, 0, 300, 900, NO, NO", "301, 0, 340, 900, NO, NO", "642, 0, 870, 900, NO, NO"]
        d.set(wider, forKey: SplitViewMemory.sharedKey)
        SplitViewMemory.swap(from: "plan", to: "build", defaults: d)
        #expect(d.stringArray(forKey: SplitViewMemory.sharedKey) == ["0, 0, 300, 900, NO, NO", "301, 0, 1211, 900, NO, NO"])
    }

    @Test func aCollapsedSidebarDoesntSetTheWidth() {
        #expect(SplitViewMemory.sidebarWidth(["0, 0, 0, 900, YES, NO"]) == nil)
        #expect(SplitViewMemory.sidebarWidth(["0, 0, 250, 900, NO, NO"]) == 250)
    }

    @Test func stayingInTheSameModeChangesNothing() {
        let d = fresh()
        d.set(build, forKey: SplitViewMemory.sharedKey)
        SplitViewMemory.swap(from: "build", to: "build", defaults: d)
        #expect(d.stringArray(forKey: SplitViewMemory.sharedKey) == build)
    }
}
