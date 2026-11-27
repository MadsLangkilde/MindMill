import Foundation
import Testing
@testable import KBCore

@Suite struct OneQuestionTests {
    @Test func sessionsAskInOnePlaceAndTheOverviewDoesntRepeatThem() {
        let lead = ClaudeModes.crew(role: .lead, sessionID: "s1", leadTitle: nil, leadID: nil, project: "p")
        #expect(lead.contains(ClaudeModes.oneQuestion))
        #expect(lead.contains("and won't ask it in this conversation"))
        let solo = ClaudeModes.crew(role: .solo, sessionID: "s2", leadTitle: nil, leadID: nil, project: "p")
        #expect(solo.contains(ClaudeModes.oneQuestion))
        let overview = ClaudeModes.overseer(kbRoot: "/kb")
        #expect(overview.contains("**no question**"))
        #expect(overview.contains("The user answered … directly"))
    }
}

@Suite struct SessionGoalTests {
    @Test func codeThatGoesInByPullRequestIsDoneOnlyOnceItsPullRequestIsOpen() {
        let solo = ClaudeModes.crew(role: .solo, sessionID: "s1", leadTitle: nil, leadID: nil, project: "p", about: "wi:42")
        #expect(solo.contains("This session is tied to work item #42."))
        #expect(solo.contains("the goal is an open pull request"))
        #expect(solo.contains("never offer to archive the session"))
        #expect(solo.contains("kb crew link me --pr <n>"))
        let free = ClaudeModes.crew(role: .lead, sessionID: "s2", leadTitle: nil, leadID: nil, project: "p")
        #expect(free.contains("No work item or pull request is tied to this session yet."))
        #expect(ClaudeModes.crew(role: .lead, sessionID: "s3", leadTitle: nil, leadID: nil, project: "p", about: "mypr:7")
            .contains("tied to pull request !7"))
        #expect(!ClaudeModes.crew(role: .member, sessionID: "s4", leadTitle: nil, leadID: nil, project: "p").contains("When the work is done"))
        #expect(ClaudeModes.finishedCheck.contains("never archiving"))
        #expect(ClaudeModes.overseer(kbRoot: "/kb").contains("no pull request is open for it, it isn't done"))
    }
}
