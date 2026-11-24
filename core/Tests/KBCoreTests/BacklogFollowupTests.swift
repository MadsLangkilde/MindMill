import Testing
@testable import KBCore

struct BacklogFollowupTests {
    @Test func createAPBIFollowupsAreBacklogWork() {
        #expect(BacklogFollowup.workTitle("Create an Android PBI for hiding More-menu entries") == "Hiding More-menu entries")
        #expect(BacklogFollowup.workTitle("Create PBI(s) for the retry design") == "The retry design")
        #expect(BacklogFollowup.workTitle("Opret en PBI til login") == "Login")
        #expect(BacklogFollowup.workTitle("Create a bug") == "Create a bug")
    }

    @Test func otherFollowupsAreNot() {
        #expect(BacklogFollowup.workTitle("Add the Android PBI number to the notes") == nil)
        #expect(BacklogFollowup.workTitle("Make sure the bug fix ships") == nil)
        #expect(BacklogFollowup.workTitle("Ask Anna about login issues") == nil)
    }
}
