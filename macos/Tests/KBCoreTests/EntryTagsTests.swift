import Foundation
import Testing
@testable import KBCore

struct EntryTagsTests {
    @Test func normalizesAndDedupes() {
        #expect(EntryTags.normalize("  #Common   Repo ") == "common repo")
        #expect(EntryTags.normalized(["Auth", "auth", "", "BFF"]) == ["auth", "bff"])
    }

    @Test func removedTagsAreRememberedAndReaddingForgetsThem() {
        #expect(EntryTags.off(old: ["auth", "bff"], new: ["auth"], off: []) == ["bff"])
        #expect(EntryTags.off(old: ["auth"], new: ["auth", "bff"], off: ["bff", "ios"]) == ["ios"])
    }

    @Test func theTaggerNeverAddsBackWhatTheUserRemoved() {
        #expect(EntryTags.autoAdd(["BFF", "auth", "device"], to: ["auth"], off: ["bff"]) == ["auth", "device"])
    }

    @Test func savingRecordsTheUsersRemovals() {
        var old = Frontmatter()
        old.set("tags", .list(["auth", "bff"]))
        var fm = old
        fm.set("tags", .list(["Auth", "Device"]))
        EntryTags.recordUserEdit(&fm, old: old)
        #expect(fm.list("tags") == ["auth", "device"])
        #expect(fm.list("tags_off") == ["bff"])
        var untouched = Frontmatter()
        untouched.set("title", .string("T"))
        EntryTags.recordUserEdit(&untouched, old: untouched)
        #expect(untouched["tags"] == nil && untouched["tags_off"] == nil)
    }

    @Test func filterNeedsEverySelectedTag() {
        #expect(EntryTags.matches(["auth", "bff"], selected: ["auth"]))
        #expect(!EntryTags.matches(["auth"], selected: ["auth", "bff"]))
        #expect(EntryTags.matches([], selected: []))
    }

    @Test func vocabularyCountsItemsMostUsedFirst() {
        let v = EntryTags.vocabulary([["auth", "bff"], ["Auth"], ["bff", "bff"], ["device"]])
        #expect(v.map(\.tag) == ["auth", "bff", "device"])
        #expect(v.map(\.count) == [2, 2, 1])
    }
}
