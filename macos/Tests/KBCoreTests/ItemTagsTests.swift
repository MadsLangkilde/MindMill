import Foundation
import Testing
@testable import KBCore

struct ItemTagsTests {
    @Test func localTagsNeverLeakUnlessAligned() {
        var store = ItemTags()
        let key = ItemTags.key(kind: "azure-devops", id: "7")
        store.setTags(["Auth", "bff"], for: key)
        #expect(store.pending(for: key, toolTags: ["Android"]).isEmpty)
        store.setAligned("bff", true, for: key)
        #expect(store.pending(for: key, toolTags: ["Android"]) == ["bff"])
        store.setAlignedEverywhere("auth", true)
        #expect(store.pending(for: key, toolTags: ["Android", "BFF"]) == ["auth"])
        #expect(store.pending(for: ItemTags.key(kind: "azure-devops", id: "8"), toolTags: []).isEmpty)
    }

    @Test func mergingKeepsEveryToolTagAsItIs() {
        #expect(TrackerTagSync.merged(toolTags: ["Android", "Release"], additions: ["bff", "release"]) == ["Android", "Release", "bff"])
    }

    @Test func removingATagDropsItsAlignmentAndEmptyItemsGo() {
        var store = ItemTags()
        store.setTags(["auth"], for: "jira:K-1")
        store.setAligned("auth", true, for: "jira:K-1")
        store.setTags(["bff"], for: "jira:K-1")
        #expect(store.items["jira:K-1"]?.aligned == [])
        store.setTags([], for: "jira:K-1")
        #expect(store.items.isEmpty)
    }

    @Test func readsTheCLIsFile() throws {
        let json = #"{"version": 1, "aligned_tags": ["release"], "items": {"azure-devops:7": {"tags": ["auth"]}}}"#
        let store = try JSONDecoder().decode(ItemTags.self, from: Data(json.utf8))
        #expect(store.alignedTags == ["release"])
        #expect(store.tags("azure-devops:7") == ["auth"])
        #expect(store.items["azure-devops:7"]?.aligned == [])
    }
}
