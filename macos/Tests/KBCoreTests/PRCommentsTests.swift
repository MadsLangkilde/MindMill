import Testing
@testable import KBCore

struct PRCommentsTests {
    private let pr = PullRequest(id: 42, title: "Fix it", source: "feature/42-fix")

    @Test func withMeAsksBeforeEveryChange() {
        let p = PRCommentsMode.withMe.prompt(pr)
        #expect(p.contains("kb pr show 42"))
        #expect(p.contains("Ask me with choices before you change code"))
        #expect(!p.contains("You have my permission"))
    }

    @Test func simpleOnlyActsAloneOnlyOnTheSimpleOnes() {
        let p = PRCommentsMode.simpleOnly.prompt(pr)
        #expect(p.contains("For the simple ones you have my permission"))
        #expect(p.contains("ask me about each needs-me thread"))
        #expect(p.contains("push to `feature/42-fix`"))
    }

    @Test func allNeverResolvesADisagreement() {
        let p = PRCommentsMode.all.prompt(pr)
        #expect(p.contains("permission to handle every open thread without asking"))
        #expect(p.contains("leave the thread open for the reviewer"))
    }

    @Test func repliesNeverMentionClaude() {
        for m in PRCommentsMode.allCases {
            #expect(m.prompt(pr).contains("Never mention Claude"))
            #expect(m.display(pr).contains("!42"))
        }
    }
}
