import Foundation
import Testing
@testable import KBCore

struct TestScopesTests {
    let index = KBIndex(root: URL(fileURLWithPath: "/tmp/none"), projects: [
        KBProject(id: "all", title: "Overview", group: "p", wide: true),
        KBProject(id: "android", title: "Android", group: "p", wide: false),
        KBProject(id: "ios", title: "iOS", group: "p", wide: false),
        KBProject(id: "mobile", title: "Mobile", group: "p", wide: false, includes: ["android", "ios"]),
    ], entries: [:])

    @Test func aPlatformScopeOffersOnlyItself() {
        #expect(TestScopes.choices(for: "ios", in: index) == ["ios"])
    }

    @Test func aScopeThatSpansOthersOffersThePlatformsInIt() {
        #expect(TestScopes.choices(for: "all", in: index) == ["android", "ios"])
        #expect(TestScopes.choices(for: "mobile", in: index) == ["android", "ios"])
        #expect(TestScopes.choices(for: nil, in: index).isEmpty)
    }

    @Test func picksTheChosenOneWhileOnOfferElseOneSetUp() {
        #expect(TestScopes.pick(["android", "ios"], chosen: "ios", isSetUp: { _ in false }) == "ios")
        #expect(TestScopes.pick(["android", "ios"], chosen: "vault", isSetUp: { $0 == "ios" }) == "ios")
        #expect(TestScopes.pick(["android", "ios"], chosen: nil, isSetUp: { _ in false }) == "android")
    }
}

@Suite struct TestSourcesTests {
    let porcelain = """
    worktree /r/app
    HEAD abc
    branch refs/heads/main

    worktree /r/app/.worktrees/login-flow
    HEAD def
    branch refs/heads/feature/login

    worktree /r/other-copy
    HEAD 123
    detached

    """

    @Test func checkoutsListTheMainFolderFirstWithBranches() {
        let c = TestSources.checkouts(porcelain: porcelain)
        #expect(c.map(\.path) == ["/r/app", "/r/app/.worktrees/login-flow", "/r/other-copy"])
        #expect(c.map(\.branch) == ["main", "feature/login", nil])
    }

    @Test func aSessionsCopyIsWhatItReportedElseWhatItsConversationNamesLast() {
        let c = TestSources.checkouts(porcelain: porcelain)
        #expect(TestSources.sessionCopy(c, reported: ["/r/other-copy/src"], texts: ["cd /r/app/.worktrees/login-flow"])?.path == "/r/other-copy")
        #expect(TestSources.sessionCopy(c, reported: [], texts: ["cd /r/other-copy", "cd /r/app/.worktrees/login-flow && swift build"])?.branch == "feature/login")
        #expect(TestSources.sessionCopy(c, reported: [], texts: ["git worktree add .worktrees/login-flow -b feature/login"])?.path == "/r/app/.worktrees/login-flow")
        #expect(TestSources.sessionCopy(c, reported: [], texts: ["cd /r/app && swift build"]) == nil)
        #expect(TestSources.sessionCopy(Array(c.prefix(1)), reported: ["/r/app"], texts: []) == nil)
    }
}
