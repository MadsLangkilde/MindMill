import Testing
@testable import KBCore

@Suite struct OpenQuestionTests {
    @Test func choicesWaitOnTheUser() {
        let reply = "**Record it?**\n\n```choices\nYes (Recommended)\nNo\n```"
        #expect(OpenQuestion.waitsOnUser(reply))
        #expect(OpenQuestion.of(reply) == nil)
    }

    @Test func bareQuestionDoesNotWaitButIsFound() {
        let reply = "So it's probably from the docs. That makes it a good question for your colleague: where does this come from, and what counts as \"repeated\"?"
        #expect(!OpenQuestion.waitsOnUser(reply))
        #expect(OpenQuestion.of(reply) == "That makes it a good question for your colleague: where does this come from, and what counts as \"repeated\"?")
    }

    @Test func statementIsNoQuestion() {
        #expect(OpenQuestion.of("All done. The PR is up.") == nil)
    }

    @Test func asksOncePerReplyAndNeverAboutItsOwnRequest() {
        let reply = "Should I push it?"
        #expect(OpenQuestion.shouldAsk(reply: reply, turnTag: nil, alreadyAsked: false))
        #expect(!OpenQuestion.shouldAsk(reply: reply, turnTag: nil, alreadyAsked: true))
        #expect(!OpenQuestion.shouldAsk(reply: reply, turnTag: "open-question-1", alreadyAsked: false))
        #expect(!OpenQuestion.shouldAsk(reply: reply, turnTag: "connect", alreadyAsked: false))
    }

    @Test func everySessionPromptSaysQuestionsComeWithOptions() {
        #expect(ClaudeModes.session(project: nil, projectTitle: nil, kbRoot: "/kb").contains(ClaudeModes.askingRule))
    }
}
