import Foundation
import Testing
@testable import KBCore

@Suite struct PBIMatchTests {
    @Test func similarTitlesScoreHigh() {
        #expect(PBIMatch.score("Show the login screen on top of the current screen", "Login screen on top and resume") >= 0.5)
        #expect(PBIMatch.score("Upload samples one per POST", "Persisted debug logs") == 0)
        #expect(PBIMatch.score("Firmware update", "Firmware update over the BFF") == 1)
        // One shared common word is not a match.
        #expect(PBIMatch.score("Network settings in upload", "Bluetooth settings page") == 0)
    }

    @Test func findsWorkItemNumbers() {
        let text = "App side starts now (417986, 417987); see #418625 and PBI 47712. Meeting at 2026-11-11, 1000000 users."
        let found = PBIMatch.mentionedWorkItems(text)
        #expect(found.map(\.number) == [417986, 417987, 418625, 47712])
        #expect(found.map(\.explicit) == [false, false, true, true])
    }
}

@Suite struct SearchTests {
    @Test func findsAWorkItemByNumberInAnyField() {
        let id = EntryID(project: "p", section: .backlog, stem: "2026-11-06-raw")
        let e = KBEntry(id: id, url: URL(fileURLWithPath: "/x.md"),
                        text: "---\ntitle: Upload export formats\nwork_item: 418625\ndate: 2026-11-06\n---\nBody\n")
        #expect(e.matches("418625"))
        #expect(e.matches("#418625"))
        #expect(!e.matches("2026"))
        let item = TrackerBacklog.Item(id: 421734, title: "Note upload 400", scope: "p", tags: ["Comet"], assignee: "Some One", prs: [319132])
        #expect(item.matches("#421734"))
        #expect(item.matches("comet upload"))
        #expect(item.matches("!319132"))
        #expect(!item.matches("bluetooth"))
    }
}
