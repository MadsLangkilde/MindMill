import Testing
@testable import KBCore

@Suite struct SpokenReplyTests {
    @Test func theNoteFollowsWhatWasSaid() {
        let m = SpokenReply.message("  What needs me today?\n")
        #expect(m.hasPrefix("What needs me today?\n\n"))
        #expect(m.hasSuffix(SpokenReply.note))
        #expect(SpokenReply.note.contains("choices block"))
    }
}
