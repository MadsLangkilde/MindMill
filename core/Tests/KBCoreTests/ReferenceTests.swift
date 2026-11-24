import Foundation
import Testing
@testable import KBCore

struct ReferenceTests {
    @Test func guessesTheKindFromTheLink() {
        let cases: [(String, ReferenceKind)] = [
            ("https://claude.ai/public/artifacts/abc", .artifact),
            ("https://claude.ai/code/artifact/123", .artifact),
            ("https://outlook.office.com/mail/id/AAQk", .email),
            ("https://teams.microsoft.com/l/message/1", .teams),
            ("https://acme.sharepoint.com/sites/x/Doc.aspx", .document),
            ("https://example.com/spec.pdf", .document),
            ("https://developer.android.com/compose", .web),
        ]
        for (raw, kind) in cases { #expect(ReferenceKind.guess(URL(string: raw)!) == kind, "\(raw)") }
    }

    @Test func replacingTheCopyKeepsTheNote() {
        let body = ReferenceBody.make(note: "Dedup rules", content: "old text\n## A heading in the page")
        #expect(ReferenceBody.content(body) == "old text\n## A heading in the page")
        let updated = ReferenceBody.replacingContent(body, with: "new text")
        #expect(updated == "## Why it matters\nDedup rules\n\n## Content\nnew text\n")
    }

    @Test func aBodyWithoutContentGetsOne() {
        #expect(ReferenceBody.replacingContent("Just a note\n", with: "copy") == "Just a note\n\n## Content\ncopy\n")
    }

    @Test func referencesAreAFolder() {
        #expect(KBSection.folders.contains(.references))
        #expect(EntryID("p/references/2026-11-12-spec")?.section == .references)
        #expect(KBStore.template(for: .references).contains("## Content"))
    }
}
