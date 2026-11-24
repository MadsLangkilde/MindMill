import Testing
@testable import KBCore

@Suite struct WorkItemTurnTests {
    private func pr(_ blockers: [String], reviewers: [PullRequest.Reviewer] = [], draft: Bool = false) -> PullRequest {
        var p = PullRequest(id: 320052, title: "403 copy", repo: "contoso-android", url: "u", draft: draft,
                            reviewers: reviewers, blockers: blockers)
        p.author = "Mads Langkilde"
        return p
    }

    @Test func aStoppedSessionWhosePRWaitsOnReviewersIsNotImplementing() {
        let p = pr(["Waiting for approval"], reviewers: [.init(name: "Niels Sorensen"), .init(name: "Erik Nord"),
                                                          .init(name: "Mads Langkilde"), .init(name: "Ann Lee", vote: 10)])
        let turn = WorkItemTurn.of(.stopped, pr: p)
        #expect(turn == .waitingForOthers("Waiting for Niels and Erik to approve"))
        #expect(turn.buttonTitle == "Open Session")
    }

    @Test func runningAndAskingWin() {
        let p = pr(["Waiting for approval"])
        #expect(WorkItemTurn.of(.working, pr: p).buttonTitle == "Implementing…")
        #expect(WorkItemTurn.of(.waiting, pr: p) == .needsYou("Needs you"))
    }

    @Test func somethingForTheUserIsNotOthersTurn() {
        #expect(WorkItemTurn.waitingOnOthers(pr(["Waiting for approval", "2 open comments"])) == nil)
        #expect(WorkItemTurn.waitingOnOthers(pr([PRBlocker.buildFailed])) == nil)
        #expect(WorkItemTurn.waitingOnOthers(pr([])) == nil)
        #expect(WorkItemTurn.waitingOnOthers(pr(["Waiting for approval"], draft: true)) == nil)
        #expect(WorkItemTurn.waitingOnOthers(pr([PRBlocker.buildRunning])) == PRBlocker.buildRunning)
        #expect(WorkItemTurn.of(.idle, pr: nil) == .paused)
    }
}
