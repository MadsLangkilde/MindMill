import Foundation
import Testing
@testable import KBCore

@Suite struct FrontmatterTests {
    let sample = """
    ---
    title: Export format after retry
    date: 2026-11-04
    status: active
    custom_owner: "Tom: firmware"
    # a comment line
    tags: [ble, upload,  "a, b" ]
    supersedes: []
    weird:   kept   as is
    ---

    ## Decision
    Send the export format.
    """

    @Test func parsesFlatValuesAndLists() {
        let parsed = FrontmatterCodec.parse(sample)
        #expect(parsed.hasFrontmatter)
        let fm = parsed.frontmatter
        #expect(fm.string("title") == "Export format after retry")
        #expect(fm.string("date") == "2026-11-04")
        #expect(fm.string("custom_owner") == "Tom: firmware")
        #expect(fm.list("tags") == ["ble", "upload", "a, b"])
        #expect(fm.list("supersedes") == [])
        #expect(fm.string("weird") == "kept   as is")
        #expect(fm.keys == ["title", "date", "status", "custom_owner", "tags", "supersedes", "weird"])
        #expect(parsed.body == "\n## Decision\nSend the export format.")
    }

    @Test func unchangedRoundTripIsByteIdentical() {
        let parsed = FrontmatterCodec.parse(sample)
        #expect(FrontmatterCodec.serialize(parsed.frontmatter, body: parsed.body) == sample)
    }

    @Test func editKeepsKeyOrderAndUnknownKeys() {
        var fm = FrontmatterCodec.parse(sample).frontmatter
        fm.set("status", .string("superseded"))
        fm.set("superseded_by", .string("acme-go/decisions/2026-12-01-export-format-after-retry"))
        fm.setList("tags", ["ble", "upload", "a, b", "new"])
        let out = FrontmatterCodec.serialize(fm, body: "body\n")
        #expect(out == """
        ---
        title: Export format after retry
        date: 2026-11-04
        status: superseded
        custom_owner: "Tom: firmware"
        # a comment line
        tags: [ble, upload, "a, b", new]
        supersedes: []
        weird:   kept   as is
        superseded_by: acme-go/decisions/2026-12-01-export-format-after-retry
        ---
        body

        """)
        let reparsed = FrontmatterCodec.parse(out).frontmatter
        #expect(reparsed.list("tags") == ["ble", "upload", "a, b", "new"])
        #expect(reparsed.string("custom_owner") == "Tom: firmware")
        #expect(reparsed.string("superseded_by") == "acme-go/decisions/2026-12-01-export-format-after-retry")
    }

    @Test func settingSameValueKeepsOriginalSpelling() {
        var fm = FrontmatterCodec.parse("---\ntags: [ a ,b ]\ntitle: 'It''s'\n---\n").frontmatter
        fm.setList("tags", ["a", "b"])
        fm.setString("title", "It's")
        fm.setString("summary", "")
        #expect(FrontmatterCodec.serialize(fm, body: "") == "---\ntags: [ a ,b ]\ntitle: 'It''s'\n---\n")
    }

    @Test func quotesValuesThatNeedIt() {
        #expect(FrontmatterCodec.format(.string("plain words")) == "plain words")
        #expect(FrontmatterCodec.format(.string("2026-11-04")) == "2026-11-04")
        #expect(FrontmatterCodec.format(.string("Why: because")) == "\"Why: because\"")
        #expect(FrontmatterCodec.format(.string("[not a list]")) == "\"[not a list]\"")
        #expect(FrontmatterCodec.format(.string("say \"hi\"")) == "say \"hi\"")
        #expect(FrontmatterCodec.format(.string("\"quoted\"")) == "\"\\\"quoted\\\"\"")
        #expect(FrontmatterCodec.format(.list(["x", "y z", "a,b"])) == "[x, y z, \"a,b\"]")
        for value in ["Why: because", "\"quoted\"", "#hash", "trailing:"] {
            let line = "---\nk: \(FrontmatterCodec.format(.string(value)))\n---\n"
            #expect(FrontmatterCodec.parse(line).frontmatter.string("k") == value)
        }
    }

    @Test func fileWithoutFrontmatterIsAllBody() {
        let parsed = FrontmatterCodec.parse("# Hello\n\ntext")
        #expect(!parsed.hasFrontmatter)
        #expect(parsed.body == "# Hello\n\ntext")
        #expect(FrontmatterCodec.serialize(parsed.frontmatter, body: parsed.body) == "# Hello\n\ntext")
    }

    @Test func unterminatedFrontmatterIsTreatedAsBody() {
        let text = "---\ntitle: x\nno closing fence"
        let parsed = FrontmatterCodec.parse(text)
        #expect(!parsed.hasFrontmatter)
        #expect(parsed.body == text)
    }

    @Test func documentDirtiness() {
        let text = "---\ntitle: A\n---\nBody\n"
        let id = EntryID("p/facts/a")!
        var doc = EntryDocument(id: id, url: URL(fileURLWithPath: "/tmp/a.md"), text: text)
        #expect(!doc.isDirty)
        doc.frontmatter.setString("title", "B")
        #expect(doc.isDirty)
        doc.frontmatter.setString("title", "A")
        #expect(!doc.isDirty)
        doc.body += "x"
        #expect(doc.isDirty)
    }
}

@Suite struct EntryIDTests {
    let root = URL(fileURLWithPath: "/kb")

    @Test func parsesIds() {
        let id = EntryID("acme-go/decisions/2026-11-04-network-retry-per-device")
        #expect(id?.project == "acme-go")
        #expect(id?.section == .decisions)
        #expect(id?.stem == "2026-11-04-network-retry-per-device")
        #expect(id?.datePrefix == "2026-11-04")
        #expect(EntryID("vault/overview")?.section == .overview)
        #expect(EntryID("vault/facts/x.md")?.rawValue == "vault/facts/x")
        #expect(EntryID("vault/unknown/x") == nil)
        #expect(EntryID("vault/facts/x/y") == nil)
        #expect(EntryID("https://example.com") == nil)
        #expect(EntryID("vault/../x") == nil)
        #expect(EntryID("vault/facts/a")?.datePrefix == nil)
    }

    @Test func derivesIdFromPath() {
        let url = URL(fileURLWithPath: "/kb/projects/acme-go/meetings/2026-11-04-sync.md")
        #expect(EntryID(fileURL: url, root: root)?.rawValue == "acme-go/meetings/2026-11-04-sync")
        let overview = URL(fileURLWithPath: "/kb/projects/acme-go/overview.md")
        #expect(EntryID(fileURL: overview, root: root)?.rawValue == "acme-go/overview")
        #expect(EntryID(fileURL: URL(fileURLWithPath: "/kb/kb.json"), root: root) == nil)
        #expect(EntryID(fileURL: URL(fileURLWithPath: "/kb/projects/acme-go/facts/notes.txt"), root: root) == nil)
        #expect(EntryID(fileURL: URL(fileURLWithPath: "/other/projects/acme-go/facts/a.md"), root: root) == nil)
    }

    @Test func idToPathRoundTrip() {
        for raw in ["a/decisions/2026-01-01-x", "a/facts/y", "a/overview", "a/architecture/z", "a/meetings/2026-01-02-m"] {
            let id = EntryID(raw)!
            #expect(EntryID(fileURL: id.fileURL(root: root), root: root) == id)
        }
    }

    @Test func slugs() {
        #expect(Slug.make("Network retry per device!") == "network-retry-per-device")
        #expect(Slug.make("  Café  Ærø   & Co  ") == "cafe-aeroe-and-co")
        #expect(Slug.make("???") == "untitled")
        #expect(Slug.make(String(repeating: "word ", count: 40)).count <= 60)
        #expect(!Slug.make(String(repeating: "word ", count: 40)).hasSuffix("-"))
    }

    @Test func config() throws {
        #expect(KBConfig.expandTilde("~/projects/knowledge", home: "/Users/me") == "/Users/me/projects/knowledge")
        #expect(KBConfig.expandTilde("/abs", home: "/Users/me") == "/abs")
        #expect(KBConfig.abbreviateTilde("/Users/me/kb", home: "/Users/me") == "~/kb")
        let dir = try TempDir()
        let cfg = dir.url.appendingPathComponent("sub/config.json")
        #expect(KBConfig.loadRootPath(configURL: cfg) == "~/projects/knowledge")
        try Data("{\"root\": \"~/x\", \"other\": 1}".utf8).write(to: cfg.deletingLastPathComponent().creatingDirectory())
        try KBConfig.saveRootPath("~/y", configURL: cfg)
        #expect(KBConfig.loadRootPath(configURL: cfg) == "~/y")
        try Data("{\"root\": \"~/x\", \"other\": 1}".utf8).write(to: cfg)
        try KBConfig.saveRootPath("~/z", configURL: cfg)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: cfg)) as? [String: Any]
        #expect(json?["other"] as? Int == 1)
        #expect(json?["root"] as? String == "~/z")
    }
}

extension URL {
    func creatingDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return appendingPathComponent("config.json")
    }
}

@Suite struct DiskSyncTests {
    let id = EntryID("p/facts/a")!
    let url = URL(fileURLWithPath: "/tmp/p/facts/a.md")

    @Test func cleanDocumentReloadsSilently() {
        let doc = EntryDocument(id: id, url: url, text: "---\ntitle: A\n---\nx\n")
        #expect(DiskSync.decide(doc, diskText: "---\ntitle: A\n---\nx\n") == .unchanged)
        guard case .reload(let fresh) = DiskSync.decide(doc, diskText: "---\ntitle: B\n---\nx\n") else {
            Issue.record("expected reload")
            return
        }
        #expect(fresh.title == "B")
        #expect(!fresh.isDirty)
        #expect(DiskSync.decide(doc, diskText: nil) == .close)
    }

    @Test func dirtyDocumentConflicts() {
        var doc = EntryDocument(id: id, url: url, text: "---\ntitle: A\n---\nx\n")
        doc.body = "mine\n"
        #expect(DiskSync.decide(doc, diskText: "---\ntitle: A\n---\nx\n") == .unchanged)
        #expect(DiskSync.decide(doc, diskText: "---\ntitle: A\n---\ntheirs\n") == .conflictModified)
        #expect(DiskSync.decide(doc, diskText: nil) == .conflictDeleted)
    }

    @Test func ownSaveDoesNotConflict() throws {
        let kb = try makeKB()
        var doc = try KBStore.load(EntryID("alpha/facts/zeta")!, root: kb.url)
        doc.body = "changed\n"
        try KBStore.save(&doc, root: kb.url)
        let disk = try String(contentsOf: doc.url, encoding: .utf8)
        #expect(DiskSync.decide(doc, diskText: disk) == .unchanged)
    }

    @Test func unsavedNewDocumentIgnoresDisk() throws {
        let kb = try makeKB()
        let doc = try KBStore.newDocument(project: "alpha", section: .facts, title: "N", root: kb.url)
        #expect(DiskSync.decide(doc, diskText: nil) == .unchanged)
    }
}
