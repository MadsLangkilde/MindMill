import Foundation
import Testing
@testable import KBCore

struct DiscussionTests {
    let body = """
    ## Summary
    Should failed uploads retry forever?

    ## Points raised
    - 2026-11-10 · Ana B: Retry 3 times, then give up
    - 2026-11-11: The BFF times out after 30 s
    - loose note without a date

    ## Open questions
    - [ ] What does the BFF do with duplicates?
    - [x] Does iOS retry?

    ## Findings
    - The BFF dedups by note id → acme-go/inbox/20261112-1
    - Uploads are one note per POST

    ## Outcome
    """

    @Test func readsTheSections() {
        let d = DiscussionBody(body)
        #expect(d.summary == "Should failed uploads retry forever?")
        #expect(d.points == [
            .init(date: "2026-11-10", who: "Ana B", text: "Retry 3 times, then give up"),
            .init(date: "2026-11-11", who: "", text: "The BFF times out after 30 s"),
            .init(date: "", who: "", text: "loose note without a date"),
        ])
        #expect(d.openQuestions.map(\.text) == ["What does the BFF do with duplicates?"])
        #expect(d.questions.count == 2)
        #expect(d.findings.count == 2)
        #expect(d.findings.filter { !$0.contains("→") } == ["Uploads are one note per POST"])
        #expect(d.outcome.isEmpty)
    }

    @Test func newDiscussionIsOpenWithTheSections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let doc = try KBStore.newDocument(project: "p", section: .discussions, title: "Retries", root: root)
        #expect(doc.frontmatter.string("status") == "open")
        #expect(doc.frontmatter.string("waiting_on") == "nobody")
        for h in ["## Summary", "## Points raised", "## Open questions", "## Findings", "## Outcome"] { #expect(doc.body.contains(h)) }
        #expect(KBSection.discussions.isDated)
        #expect(EntryID("p/discussions/2026-11-12-retries")?.section == .discussions)
    }
}
