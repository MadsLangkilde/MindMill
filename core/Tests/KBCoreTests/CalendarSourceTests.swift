import Foundation
import Testing
@testable import KBCore

@Suite struct CalendarSourceTests {
    private func server(_ name: String, _ status: ClaudeConnectors.Server.Status = .connected) -> ClaudeConnectors.Server {
        .init(name: name, target: "https://x", status: status)
    }

    @Test func toolPrefixMatchesClaudeCodesNames() {
        #expect(CalendarSource.toolPrefix("claude.ai Microsoft 365") == "mcp__claude_ai_Microsoft_365")
        #expect(CalendarSource.toolPrefix("claude.ai Google Calendar") == "mcp__claude_ai_Google_Calendar")
        #expect(CalendarSource.toolPrefix("my-cal_2") == "mcp__my-cal_2")
    }

    @Test func toolsAreOutlooksSearchOrTheConnectorsOwn() {
        #expect(CalendarSource.none.tools.isEmpty)
        #expect(CalendarSource.microsoft365.tools == ["mcp__claude_ai_Microsoft_365__outlook_calendar_search"])
        #expect(CalendarSource.google.tools == ["mcp__claude_ai_Google_Calendar"])
        #expect(CalendarSource(kind: .other, server: "fastmail calendar").tools == ["mcp__fastmail_calendar"])
    }

    @Test func choicesOfferNoneOutlookGoogleAndCalendarConnectors() {
        let servers = [server("claude.ai Google Drive"), server("claude.ai Claude Docs"), server("caldav-home")]
        let choices = CalendarSource.choices(servers: servers)
        #expect(choices.map(\.kind) == [.none, .microsoft365, .google, .other])
        // Google Drive isn't a calendar: the Google choice keeps the name its calendar connector gets.
        #expect(choices[2].server == "claude.ai Google Calendar")
        #expect(choices[3].server == "caldav-home")
        #expect(CalendarSource.choices(servers: servers, anyServer: true).contains { $0.server == "claude.ai Claude Docs" })

        let listed = CalendarSource.choices(servers: [server("Google Calendar (work)")])
        #expect(listed[2] == CalendarSource(kind: .google, server: "Google Calendar (work)"))
    }

    @Test func onlyAnExistingMicrosoft365ConnectorIsAdopted() {
        #expect(CalendarSource.adopted(from: [server("claude.ai Microsoft 365", .needsAuth)]) == .microsoft365)
        #expect(CalendarSource.adopted(from: [server("claude.ai Google Drive"), server("claude.ai Claude Docs")]) == .none)
        #expect(CalendarSource.adopted(from: []) == .none)
    }

    @Test func savesAndLoadsAndIsNilUntilChosen() throws {
        let defaults = try #require(UserDefaults(suiteName: "calendar-source-\(UUID().uuidString)"))
        #expect(CalendarSource.load(defaults: defaults) == nil)
        CalendarSource.google.save(defaults: defaults)
        #expect(CalendarSource.load(defaults: defaults) == .google)
        CalendarSource.none.save(defaults: defaults)
        #expect(CalendarSource.load(defaults: defaults) == CalendarSource.none)
    }

    @Test func problemSaysMissingOnlyOnceChecked() {
        let missing = CalendarSource.google.problem(in: [], checked: true)
        #expect(missing.missing)
        #expect(missing.headline == "Google Calendar isn't connected to Claude")
        #expect(!CalendarSource.google.problem(in: [], checked: false).missing)

        let refused = CalendarSource.microsoft365.problem(in: [server("claude.ai Microsoft 365")], checked: true)
        #expect(!refused.missing)
        #expect(refused.headline == "Outlook needs signing in")
    }

    @Test func promptsNameTheCalendarOrSkipIt() {
        let sync = ClaudeModes.calendar(from: "2026-11-25", to: "2026-12-08", source: .google)
        #expect(sync.contains("`claude.ai Google Calendar`"))
        #expect(sync.contains("mcp__claude_ai_Google_Calendar__"))

        #expect(ClaudeModes.morning("2026-11-25").contains("No calendar is connected"))
        #expect(ClaudeModes.morning("2026-11-25", calendarSynced: true, calendar: .microsoft365).contains("skip the mindmill:calendar step and read"))
        #expect(ClaudeModes.morning("2026-11-25", calendar: .google).contains("Google Calendar"))
    }
}
