import Foundation
import Testing
@testable import KBCore

struct WorkItemLinksTests {
    @Test func parentIsReadFromTheWaysPeopleWriteIt() {
        #expect(WorkItemLinks.parentMentions(in: "Parent: Feature #431006 \"Offline usage limit\". Requested on 23 Nov.") == [431006])
        #expect(WorkItemLinks.parentMentions(in: "Create PBIs under Feature #431006 after the meeting") == [431006])
        #expect(WorkItemLinks.parentMentions(in: "Feature here: https://dev.azure.com/O/P/_workitems/edit/431006") == [431006])
        #expect(WorkItemLinks.parentMentions(in: "Feature 431006 says the app blocks measuring.") == [431006])
        #expect(WorkItemLinks.parentMentions(in: "Feature 431006 says so.", strongOnly: true) == [])
        #expect(WorkItemLinks.parentMentions(in: "- 14:17 **Screen:** Add link / Parent / $ 446324 General maintenance") == [])
        #expect(WorkItemLinks.parentMentions(in: "The parent is unclear. See PBI #12345") == [])
        #expect(WorkItemLinks.refs(in: "PBI #430094 and https://dev.azure.com/O/P/_workitems/edit/7 and Bug 123456") == [430094, 7, 123456])
    }

    @Test func inferredParentNeedsOneClearCandidate() {
        #expect(WorkItemLinks.inferredParent(body: "Parent: Feature #431006.")?.number == 431006)
        #expect(WorkItemLinks.inferredParent(body: "Parent: Feature #1. Also Feature 2222 and Epic 3333") == nil)
        let meeting = (title: "Planning", body: "- [ ] Create PBIs under Feature #431006\nFeature 453956 was on screen")
        let found = WorkItemLinks.inferredParent(body: "Block it.", sources: [meeting])
        #expect(found?.number == 431006)
        #expect(found?.from == "“Planning”")
        #expect(WorkItemLinks.inferredParent(body: "Parent: #431006", ownWorkItem: "431006") == nil)
    }

    @Test func fieldsAndRelatedValues() {
        #expect(WorkItemLinks.parentNumber("none") == nil)
        #expect(WorkItemLinks.parentNumber("#431006") == 431006)
        #expect(WorkItemLinks.parentNumber(nil) == nil)
        #expect(WorkItemLinks.relatedValues(["#431549", " a/backlog/x ", "none", "431549"]) == ["431549", "a/backlog/x"])
    }
}

struct BacklogDuplicatesTests {
    let info: [String: BacklogDuplicates.ScopeInfo] = [
        "android": .init(project: "acme", wide: false), "ios": .init(project: "acme", wide: false),
        "acme": .init(project: "acme", wide: true), "other": .init(project: "other", wide: true),
    ]

    func item(_ n: Int, _ title: String, scope: String = "android", parent: Int? = nil, text: String = "") -> DuplicateCandidate {
        DuplicateCandidate(kind: .workItem, id: String(n), number: n, title: title, state: "New", scopes: [scope], parent: parent, text: text)
    }

    @Test func wordsDropCommonWordsVerbsAndPlurals() {
        #expect(BacklogDuplicates.words("Show the Offline settings for Users") == ["offline", "setting"])
        #expect(BacklogDuplicates.bareTitle("Android: Block measuring", prefix: "") == "Block measuring")
        #expect(BacklogDuplicates.bareTitle("App A: iOS: Block", prefix: "App A: ") == "Block")
    }

    @Test func classifiesLikelyPossibleAndNone() {
        let p = DuplicateProposal(id: "android/backlog/x", scope: "android",
                                  title: "Block upload after the offline days are used up", parent: 431006)
        let likely = BacklogDuplicates.score(p, item(5, "Android: Block upload after offline days are used up"))
        #expect(likely.verdict == .likely)
        let possible = BacklogDuplicates.score(p, item(7, "Offline days grace period blocks upload settings"))
        #expect(possible.verdict == .possible)
        #expect(BacklogDuplicates.score(p, item(8, "Show the offline message")).verdict == .none)
        let sameParent = BacklogDuplicates.score(p, item(9, "Upload limit", parent: 431006))
        #expect(sameParent.reasons.contains("same parent #431006"))
        let mentioning = DuplicateProposal(id: "a", scope: "android", title: "Login with a passkey", refs: [888])
        #expect(BacklogDuplicates.score(mentioning, item(888, "Something else entirely")).verdict == .possible)
    }

    @Test func checkSkipsTwinsParentRelatedAndDismissed() {
        let p = DuplicateProposal(id: "android/backlog/x", scope: "android", title: "Block upload after offline days",
                                  parent: 100, related: ["6"], dismissed: ["7"])
        let pool = [
            item(5, "Block upload after offline days", scope: "ios"),
            item(6, "Block upload after offline days"),
            item(7, "Block upload after offline days"),
            item(100, "Block upload after offline days"),
            item(8, "Block upload after the offline days", scope: "acme"),
            item(9, "Block upload after offline days", scope: "other"),
            DuplicateCandidate(kind: .proposal, id: "android/backlog/x", title: "Block upload after offline days", scopes: ["android"]),
        ]
        let f = BacklogDuplicates.check(p, candidates: pool, info: info)
        #expect(f.matches.map(\.label) == ["#8"])
        #expect(f.verdict == .likely)
        #expect(BacklogDuplicates.sameFamily("acme", ["ios"], info: info))
        #expect(!BacklogDuplicates.sameFamily("android", ["ios"], info: info))
    }

    @Test func poolKeepsTheSearchedCopyAndDropsEntriesAlreadyInTheTracker() {
        let cached = item(5, "Cached")
        var searched = item(5, "Searched")
        searched.text = "with text"
        let entry = DuplicateCandidate(kind: .entry, id: "android/backlog/y", number: 5, title: "Entry", scopes: ["android"])
        let other = DuplicateCandidate(kind: .entry, id: "android/backlog/z", number: 6, title: "Older", scopes: ["android"])
        let pool = BacklogDuplicates.pool(tracker: [cached], searched: [searched], entries: [entry, other])
        #expect(pool.map(\.title) == ["Searched", "Older"])
    }

    @Test func decodesTheCLIReport() throws {
        let json = """
        {"checked": "2026-11-23T10:00:00Z", "notes": [], "proposals": [{"id": "android/backlog/x", "scope": "android",
         "title": "Block", "verdict": "possible", "matches": [{"kind": "work_item", "id": "431548", "number": 431548,
         "title": "Block it", "state": "New", "type": "pbi", "url": "u", "score": 0.6, "verdict": "possible",
         "reasons": ["title words: block"]}]}],
         "candidates": [{"kind": "work_item", "id": "431548", "number": 431548, "title": "Block it", "state": "New",
         "type": "pbi", "scopes": ["android"], "parent": null, "text": "", "url": "u"}]}
        """
        let r = try DuplicateReport.decode(json)
        #expect(r.proposals.first?.best?.label == "#431548")
        #expect(r.proposals.first?.verdict == .possible)
        #expect(r.candidates.first?.scopes == ["android"])
    }

    @Test func proposalFromAnEntryReadsParentRelatedAndMentions() {
        let text = """
        ---
        title: "iOS: Block"
        parent: none
        related: [contoso-android/backlog/x, "431548"]
        not_duplicate_of: [430093]
        ---

        Parent: Feature #431006. Overlap with PBI #430094.
        """
        let e = KBEntry(id: EntryID("contoso-ios/backlog/2026-11-23-ios-block")!, url: URL(fileURLWithPath: "/x.md"), text: text)
        let p = DuplicateProposal(entry: e)
        #expect(p.parent == 431006)
        #expect(p.related == ["contoso-android/backlog/x", "431548"])
        #expect(p.refs == [430094])
        #expect(p.dismissed == ["430093"])
    }
}

@Suite struct BacklogCLIArgumentTests {
    @Test func createPassesTheParentAndLinkPassesEverything() async throws {
        let runner = MockRunner(result: CommandResult(status: 0, stdout: "created 101 https://x/101\nparent #5\n", stderr: ""))
        let c = KBCLI(pluginRoot: URL(fileURLWithPath: "/plugin"), kbRoot: URL(fileURLWithPath: "/kb"), environment: [:], runner: runner)
        let made = try await c.createBacklog(EntryID("a/backlog/x")!, sprint: .none, parent: "")
        #expect(made?.id == "101")
        #expect(runner.calls.args[0].suffix(2) == ["--parent", "none"])
        try await c.linkBacklog(["a/backlog/x", "431549"], parent: "431006", related: ["7"])
        #expect(Array(runner.calls.args[1].dropFirst()) == ["backlog", "link", "a/backlog/x", "431549", "--yes", "--parent", "431006", "--related", "7"])
        try await c.dropBacklog(EntryID("a/backlog/x")!, duplicateOf: "5", comment: true)
        #expect(runner.calls.args[2].last == "--comment")
    }
}
