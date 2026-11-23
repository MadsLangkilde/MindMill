import Foundation
import Testing
@testable import KBCore

@Suite struct PRRescueTests {
    private let approved = [PullRequest.Reviewer(name: "Erik", vote: 10)]

    @Test func picksApprovedPRsThatAreStuck() {
        let prs = [
            PullRequest(id: 4, title: "Failed", scope: "android", reviewers: approved, blockers: ["The build failed"]),
            PullRequest(id: 2, title: "Conflicts", reviewers: [.init(name: "E", vote: 5)], blockers: ["It has merge conflicts", "The build is queued"]),
            PullRequest(id: 3, title: "Running", reviewers: approved, blockers: ["The build is running"]),
            PullRequest(id: 5, title: "Not approved", reviewers: [.init(name: "E", vote: 0)], blockers: ["The build failed"]),
            PullRequest(id: 6, title: "Rejected too", reviewers: approved + [.init(name: "N", vote: -10)], blockers: ["The build failed"]),
            PullRequest(id: 7, title: "Comments", reviewers: approved, openThreads: 2, blockers: ["2 open comments"]),
            PullRequest(id: 8, title: "Draft", draft: true, reviewers: approved, blockers: ["It is a draft"]),
            PullRequest(id: 9, title: "Ready", reviewers: approved),
        ]
        #expect(PRRescue.blocked(prs).map(\.id) == [2, 4])
    }

    @Test func reportsOnlyWhenAPRJoins() {
        let prs = [PullRequest(id: 1, title: "A", reviewers: approved, blockers: ["The build failed"]),
                   PullRequest(id: 2, title: "B", reviewers: approved, blockers: ["It has merge conflicts"])]
        #expect(PRRescue.shouldReport(prs, lastReported: []))
        #expect(PRRescue.shouldReport(prs, lastReported: [1]))
        #expect(!PRRescue.shouldReport(prs, lastReported: [1, 2]))
        #expect(!PRRescue.shouldReport([prs[0]], lastReported: [1, 2]))
    }

    @Test func reportCarriesTheBrief() {
        let pr = PullRequest(id: 319230, title: "Upload fix", repo: "contoso-android", scope: "contoso-android",
                             reviewers: approved, blockers: ["The build failed"])
        let text = PRRescue.report([pr])
        #expect(text.contains("!319230 contoso-android: Upload fix"))
        #expect(text.contains("--project contoso-android"))
        #expect(text.contains("kb pr checks <id> --requeue"))
        #expect(text.contains("The user said yes"))
    }

    @Test func problemPicksWhatNeedsFixingFirst() {
        #expect(PRProblem.of(PullRequest(id: 1, title: "", blockers: ["The build failed", "It has merge conflicts"])) == .conflicts)
        #expect(PRProblem.of(PullRequest(id: 1, title: "", blockers: ["The build is queued", "The build failed"])) == .buildFailed)
        #expect(PRProblem.of(PullRequest(id: 1, title: "", blockers: ["The build is queued"]))?.needsFixing == false)
        #expect(PRProblem.of(PullRequest(id: 1, title: "", blockers: ["The build is running"])) == nil)
        #expect(PRProblem.of(PullRequest(id: 1, title: "", draft: true, blockers: ["It has merge conflicts"])) == nil)
    }
}
