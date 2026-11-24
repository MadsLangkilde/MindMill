import Testing
@testable import KBCore

struct ImplementWayTests {
    private let crew = Strategy(slug: "auto-crew", title: "Auto crew", spawns: true)
    private let plan = Strategy(slug: "plan-first", title: "Plan first")

    @Test func aSpawningStrategyMovesTheSkillsSubagentsIntoSessions() {
        let note = ImplementWay.strategyNote(crew, skill: "implement-fast", fast: true)
        #expect(note.contains("`implement-fast` skill as the recipe"))
        #expect(note.contains("kb crew start --under me"))
        #expect(note.contains("replaces the strategy's rule to ask"))
    }

    @Test func guidedKeepsTheStrategysRuleToAskBeforePushing() {
        let note = ImplementWay.strategyNote(crew, skill: "implement", fast: false)
        #expect(!note.contains("replaces the strategy's rule"))
    }

    @Test func aStrategyThatDoesNotSpawnStartsNoSessions() {
        let note = ImplementWay.strategyNote(plan, skill: "implement", fast: false)
        #expect(!note.contains("kb crew start"))
        #expect(ImplementWay.strategyNote(plan, skill: nil, fast: false).isEmpty)
    }
}
