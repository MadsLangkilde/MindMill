import Foundation
import Testing
@testable import KBCore

struct FollowupOrganisingTests {
    let me = ["Mads Langkilde", "me@example.com"]

    @Test func noOwnerOrMeIsOnMe() {
        #expect(FollowupResponsibility.of(owner: nil, waitingOn: nil, me: me) == .me)
        #expect(FollowupResponsibility.of(owner: "mads langkilde", waitingOn: nil, me: me) == .me)
        #expect(FollowupResponsibility.of(owner: "me", waitingOn: nil, me: []) == .me)
        #expect(FollowupResponsibility.of(owner: "me", waitingOn: "", me: me) == .me)
    }

    @Test func someoneElseOrWaitingOnThemIsWaiting() {
        #expect(FollowupResponsibility.of(owner: "Peder Hanley", waitingOn: nil, me: me) == .others)
        #expect(FollowupResponsibility.of(owner: nil, waitingOn: "Peder Hanley", me: me) == .others)
        #expect(FollowupResponsibility.of(owner: "Pia", waitingOn: "Mads Langkilde", me: me) == .others)
    }

    @Test func linkSuggestionsKeepOnlyCandidatesOnce() {
        let reply = "Here: [{\"id\": \"a/facts/x\", \"why\": \"same token\"}, {\"id\": \"a/facts/x\", \"why\": \"again\"}, {\"id\": \"a/facts/nope\", \"why\": \"?\"}]"
        let s = FactLinkSuggestion.parse(reply, candidates: ["a/facts/x", "a/facts/y"])
        #expect(s == [FactLinkSuggestion(id: "a/facts/x", why: "same token")])
        #expect(FactLinkSuggestion.parse("none", candidates: ["a/facts/x"]).isEmpty)
    }

    @Test func linksReadBothWays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let facts = root.appendingPathComponent("projects/a/facts")
        try FileManager.default.createDirectory(at: facts, withIntermediateDirectories: true)
        try #"{"version": 1, "projects": [{"id": "a", "title": "A", "paths": []}]}"#.write(to: root.appendingPathComponent("kb.json"), atomically: true, encoding: .utf8)
        try "---\ntitle: BFF issues tokens\nrelated: [a/facts/validate]\n---\n".write(to: facts.appendingPathComponent("bff.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: Device validates\n---\n".write(to: facts.appendingPathComponent("validate.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: Alone\n---\n".write(to: facts.appendingPathComponent("alone.md"), atomically: true, encoding: .utf8)
        let index = try KBIndex.load(root: root)
        #expect(index.linkedFacts(of: EntryID("a/facts/validate")!).map(\.title) == ["BFF issues tokens"])
        #expect(index.linkedFacts(of: EntryID("a/facts/bff")!).map(\.title) == ["Device validates"])
        #expect(index.linkedFacts(of: EntryID("a/facts/alone")!).isEmpty)
        #expect(index.factLinks().count == 1)
    }
}
