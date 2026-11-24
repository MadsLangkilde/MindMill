import Testing
@testable import KBCore

struct StrategyRoleTests {
    private let team = Strategy(slug: "two-and-review", title: "Two builders + reviewer", summary: "Split, build, check",
                                instructions: "", leadModel: "opus", roles: [
        StrategyRole(name: "Builder", kind: .builder, model: "sonnet", count: 2, duty: "Builds its part: with tests, \"no\" shortcuts."),
        StrategyRole(name: "Reviewer", kind: .reviewer, model: "opus", checkpoint: .beforePR, duty: "Reads the diff | ranks findings"),
    ])

    @Test func rolesSurviveSavingAndLoading() {
        let back = Strategy.parse(team.fileText, slug: team.slug, origin: .custom)
        #expect(back.roles == team.roles)
        #expect(back.leadModel == "opus")
        #expect(back.spawns)
        #expect(back.sessionCount == 3)
        #expect(!back.isBuiltIn)
    }

    @Test func theLeadIsToldWhoToStartAndWhen() {
        let m = team.message
        #expect(m.contains("2 × **Builder** (model sonnet)"))
        #expect(m.contains("reviews your work before the pr"))
        #expect(m.contains("kb crew start --under me --title \"Builder\" --model sonnet"))
    }

    @Test func theDiagramShowsTheRolesAndTheReviewStep() {
        let shape = team.shape
        #expect(shape.helpers.map(\.label) == ["Builder ×2", "Reviewer"])
        #expect(shape.steps.contains { $0.kind == .review && $0.title == "Reviewer checks it all" })
        #expect(shape.steps.contains { $0.title == "Builder ×2 build in parallel" })
    }

    @Test func howItWorksNamesEveryRole() {
        let lines = team.howItWorks
        #expect(lines.contains { $0.contains("2 Builder sessions on Sonnet") })
        #expect(lines.contains { $0.contains("before the pr") })
        #expect(Strategy(slug: "solo", title: "Solo", instructions: "1. Do it").howItWorks.first?.contains("One session") == true)
    }

    @Test func builtInsAreNotYours() {
        #expect(Strategy(slug: "a", title: "A", origin: .builtIn).isBuiltIn)
        #expect(Strategy(slug: "a", title: "A", origin: .override).isBuiltIn)
    }
}
