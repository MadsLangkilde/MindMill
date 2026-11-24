import Foundation
import Testing
@testable import KBCore

@Suite struct PlanSessionsTests {
    @Test func sessionsAreGroupedByWhatTheyAreFor() {
        #expect(PlanSessions.kind(title: "PBI: Login", about: nil, firstMessage: "") == .workItems)
        #expect(PlanSessions.kind(title: "Create iOS and Android PBIs for features 1, 2", about: "acme-go/followups/2026-11-17-x",
                                  firstMessage: "we need to figure out which PBI's to create") == .workItems)
        #expect(PlanSessions.kind(title: "Set up the common repo", about: "acme-go/followups/2026-11-12-set-up",
                                  firstMessage: "Add more details about it") == .followups)
        #expect(PlanSessions.kind(title: "Fact: Sync", about: "acme-go/facts/sync", firstMessage: "Is this still true?") == .entries)
        #expect(PlanSessions.kind(title: "New session", about: nil, firstMessage: "How does sync work?") == .questions)
        #expect(PlanSessions.kind(title: "Bugs", about: nil, firstMessage: "Which bugs did we see last week?") == .questions)
    }

    @Test func sessionsGoInTheSectionOfWhereTheyWereStarted() {
        #expect(PlanSessions.kind(title: "auth investigation", about: "research:acme/research/2026-11-20-auth", firstMessage: "") == .research)
        #expect(PlanSessions.kind(title: "Idea: Offline", about: "idea:acme/ideas/2026-11-01-offline",
                                  firstMessage: "/mindmill:idea turn pbi acme/ideas/2026-11-01-offline") == .ideas)
        #expect(PlanSessions.kind(title: "Discussion: Login", about: "discussion:acme/discussions/2026-11-02-login",
                                  firstMessage: "/mindmill:discussion catch-up acme/discussions/2026-11-02-login") == .discussions)
        #expect(PlanSessions.kind(title: "New discussion", about: nil, firstMessage: "/mindmill:discussion start acme mail about login") == .discussions)
        #expect(PlanSessions.kind(title: "Older discussion", about: nil, firstMessage: "/kb:discussion start acme mail about login") == .discussions)
        #expect(PlanSessions.kind(title: "Older PBI", about: nil, firstMessage: "/kb:create-pbi acme/followups/x") == .workItems)
        #expect(PlanSessions.kind(title: "Stand-up", about: "acme/meetings/2026-11-12-stand-up", firstMessage: "What did we agree?") == .meetings)
        #expect(PlanSessions.kind(title: "Assistant", about: "assistant", firstMessage: "Create a PBI") == .assistant)
        #expect(PlanSessions.kind(title: "Notes", about: "acme/research/2026-11-20-auth", firstMessage: "Tidy the notes") == .research)
        #expect(PlanSessions.kind(title: "Coach", about: "goals/run-a-marathon", firstMessage: "How am I doing?") == .goals)
        #expect(PlanSessionKind.allCases.map(\.title) == ["Assistant", "Work items", "Research", "Ideas", "Discussions",
                                                           "Follow-ups", "Meetings", "Goals", "On entries", "Questions"])
    }

    @Test func originIsTheEntryWithoutItsPrefix() {
        #expect(PlanSessions.origin(about: "research:acme/research/2026-11-20-auth") == "acme/research/2026-11-20-auth")
        #expect(PlanSessions.origin(about: "acme/followups/2026-11-12-x") == "acme/followups/2026-11-12-x")
        #expect(PlanSessions.origin(about: "goals/run") == "goals/run")
        #expect(PlanSessions.origin(about: "wi:123") == nil)
        #expect(PlanSessions.origin(about: "assistant") == nil)
        #expect(PlanSessions.origin(about: nil) == nil)
    }

    /// A research in the wide scope tagged with Android shows in Android's Research list, so its session shows in
    /// Android's Sessions too.
    @Test func aSessionShowsWhereItsEntryShows() {
        let dir = URL(fileURLWithPath: "/tmp/none")
        let tagged = EntryID("all/research/2026-11-20-auth")!
        let plain = EntryID("all/research/2026-11-21-other")!
        let index = KBIndex(root: dir, projects: [
            KBProject(id: "all", title: "Overview", group: "p", wide: true),
            KBProject(id: "android", title: "Android", group: "p", wide: false),
            KBProject(id: "ios", title: "iOS", group: "p", wide: false),
        ], entries: [
            tagged: KBEntry(id: tagged, url: dir, text: "---\ntitle: Auth\nscopes: [all, android]\n---\n"),
            plain: KBEntry(id: plain, url: dir, text: "---\ntitle: Other\n---\n"),
        ])
        let about = "research:" + tagged.rawValue
        #expect(PlanSessions.shows(project: "all", about: about, in: "all", index: index))
        #expect(PlanSessions.shows(project: "all", about: about, in: "android", index: index))
        #expect(!PlanSessions.shows(project: "all", about: about, in: "ios", index: index))
        #expect(!PlanSessions.shows(project: "all", about: "research:" + plain.rawValue, in: "android", index: index))
        #expect(PlanSessions.shows(project: "android", about: nil, in: "all", index: index))
        #expect(!PlanSessions.shows(project: "android", about: nil, in: "ios", index: index))
        #expect(PlanSessions.shows(project: nil, about: nil, in: "ios", index: index))
    }

    @Test func groupsHideEmptySectionsFoldOldOnesAndArchiveLast() {
        struct S { let id: String; let kind: PlanSessionKind; let age: Double; var archived = false; var active = false }
        let now = Date()
        let items = [
            S(id: "q1", kind: .questions, age: 1),
            S(id: "r1", kind: .research, age: 2),
            S(id: "r2", kind: .research, age: 0.5),
            S(id: "old", kind: .research, age: 30),
            S(id: "oldWaiting", kind: .ideas, age: 40, active: true),
            S(id: "gone", kind: .research, age: 1, archived: true),
            S(id: "goneOld", kind: .questions, age: 50, archived: true),
        ]
        let g = PlanSessions.group(items, now: now, kind: \.kind, updated: { now.addingTimeInterval(-$0.age * 86_400) },
                                   archived: \.archived, active: \.active)
        #expect(g.sections.map(\.kind) == [.research, .ideas, .questions])
        #expect(g.sections.first?.items.map(\.id) == ["r2", "r1"])
        #expect(g.older.map(\.id) == ["old"])
        #expect(g.archived.map(\.id) == ["gone", "goneOld"])
    }

    @Test func createdWorkItemsAreFoundInLinksAndTheCLILine() {
        let texts = ["created 418901 https://dev.azure.com/o/p/_workitems/edit/418901",
                     "Created [#418902](https://dev.azure.com/o/p/_workitems/edit/418902) and linked it.",
                     "See #12345 for context."]
        #expect(PlanSessions.createdItems(texts) == [418901, 418902])
    }

    @Test func aFreshWorkItemCanBeImplemented() {
        let d = WorkItemDetail(id: 7, title: "Login", state: "New", type: "Product Backlog Item", iteration: "S\\1",
                               assignee: "", tags: [], description: "", acceptance: "", repro: "", url: "u")
        let item = d.asMyWork(scope: "android")
        #expect(item.stage == .notStarted)
        #expect(item.project == "android")
        #expect(item.type == "pbi")
    }
}
