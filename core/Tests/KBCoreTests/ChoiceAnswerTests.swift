import Foundation
import Testing
@testable import KBCore

@Suite struct ChoiceAnswerTests {
    let reply = "Shall I?\n\n```choices\nCreate it (Recommended)\nEdit title\nKeep as proposal\n```"

    @Test func aClickedOptionIsAnAnswerAndTypedTextIsNot() {
        #expect(ChoiceAnswer.picked("Create it", reply: reply) == ["Create it"])
        #expect(ChoiceAnswer.picked("Edit title ", reply: reply) == ["Edit title"])
        #expect(ChoiceAnswer.picked("Create it, but shorter", reply: reply) == nil)
        #expect(ChoiceAnswer.picked("Create it", reply: "No choices here.") == nil)
        let multi = "Which?\n```choices multi\nA\nB (Recommended)\nC\n```"
        #expect(ChoiceAnswer.picked("A, B", reply: multi) == ["A", "B"])
        #expect(ChoiceAnswer.picked("A, D", reply: multi) == nil)
    }

    @Test func onlyTheMessageRightAfterTheReplyCountsAndToolStepsDontBreakIt() {
        let r = UUID(), tool = UUID(), a = UUID(), later = UUID()
        let out = ChoiceAnswer.answered([(r, .reply, reply), (tool, .other, "ran"), (a, .user, "Edit title"), (later, .user, "Create it")])
        #expect(out.picks == [r: ["Edit title"]])
        #expect(out.answers == [a])
    }

    @Test func theChoicesComeOutOfTheText() {
        #expect(ChoiceAnswer.withoutChoices("Text\n\n```choices\nA\nB\n```\n") == "Text")
        #expect(ChoiceAnswer.withoutChoices("```swift\nlet a = 1\n```") == "```swift\nlet a = 1\n```")
    }
}
