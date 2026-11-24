import Foundation
import Testing
@testable import KBCore

struct AISetupTests {
    private func fresh() -> UserDefaults {
        let name = "AISetupTests-" + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func earlierModelChoicesCarryOver() {
        let d = fresh()
        d.set("opus", forKey: "defaultModel")
        let s = AISetup.migrated(defaults: d)
        #expect(s.brain == "claude-code")
        #expect(s.model(for: .work) == "opus")
        #expect(s.model(for: .ask) == "opus")
        #expect(s.model(for: .meetings) == "sonnet")
        #expect(s.model(for: .calendar) == "haiku")
    }

    @Test func tasksFallBackToTheBrainAndUnsupportedAssistantsAreNeverUsed() {
        var s = AISetup(brain: "codex")
        #expect(s.brainProvider.id == "claude-code")
        s.tasks[.background] = .init(provider: "gemini", model: "x")
        #expect(s.provider(for: .background).id == "claude-code")
        #expect(s.model(for: .background) == "")
        s.tasks[.background] = .init(provider: "claude-code", model: "haiku")
        #expect(s.model(for: .background) == "haiku")
    }

    @Test func savedSetupRoundTrips() {
        let d = fresh()
        var s = AISetup()
        s.tasks[.meetings] = .init(provider: "claude-code", model: "haiku")
        s.save(defaults: d)
        #expect(AISetup.migrated(defaults: d) == s)
    }
}
