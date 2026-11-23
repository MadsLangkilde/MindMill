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
