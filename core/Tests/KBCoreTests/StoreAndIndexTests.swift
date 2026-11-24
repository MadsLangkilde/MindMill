import Foundation
import Testing
@testable import KBCore

final class TempDir: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("kbtests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ rel: String, _ text: String) throws {
        let f = url.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: f)
    }

    func read(_ rel: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(rel), encoding: .utf8)
    }
}

func makeKB() throws -> TempDir {
    let dir = try TempDir()
    try dir.write("kb.json", """
    {"version": 1, "projects": [
      {"id": "alpha", "title": "Alpha App", "paths": [], "remotes": [], "related": ["beta"]},
      {"id": "beta", "title": "Beta"}
    ]}
    """)
    try dir.write("projects/alpha/overview.md", "---\ntitle: Alpha\n---\nWhat alpha is.\n")
    try dir.write("projects/alpha/decisions/2026-01-01-use-ble.md",
                  "---\ntitle: Use BLE\ndate: 2026-01-01\nstatus: superseded\nsuperseded_by: alpha/decisions/2026-03-01-use-ble-5\ntags: [ble]\n---\nOld.\n")
    try dir.write("projects/alpha/decisions/2026-03-01-use-ble-5.md",
                  "---\ntitle: Use BLE 5\ndate: 2026-03-01\nsupersedes: [alpha/decisions/2026-01-01-use-ble]\nsummary: Faster transfers\n---\nNew.\n")
    try dir.write("projects/alpha/decisions/2026-02-01-proposal.md",
                  "---\ntitle: Maybe Kotlin\ndate: 2026-02-01\nstatus: proposed\n---\n")
    try dir.write("projects/alpha/facts/zeta.md", "---\ntitle: Zeta fact\n---\nCredit-bound transfer.\n")
    try dir.write("projects/alpha/facts/alpha.md", "---\ntitle: alpha fact\n---\n")
    try dir.write("projects/alpha/meetings/2026-02-10-sync.md", "---\ntitle: Sync\nattendees: [Ann, Bo]\n---\n")
    try dir.write("projects/beta/facts/credit.md", "---\ntitle: Credits\ntags: [Firmware]\n---\n")
    try dir.write("projects/beta/facts/.hidden.md", "x")
    try dir.write("projects/gamma/facts/unregistered.md", "---\ntitle: Not in kb.json\n---\n")
    return dir
}

@Suite struct IndexTests {
    @Test func loadsProjectsAndEntries() throws {
        let kb = try makeKB()
        let index = try KBIndex.load(root: kb.url)
        #expect(index.projects.map(\.id) == ["alpha", "beta"])
        #expect(index.project("alpha")?.title == "Alpha App")
        #expect(index.entries.count == 8)
        #expect(index.count(project: "alpha", section: .decisions) == 3)
        #expect(index.entry(EntryID("alpha/overview")!)?.title == "Alpha")

        let decisions = index.entries(project: "alpha", section: .decisions)
        #expect(decisions.map(\.title) == ["Use BLE 5", "Maybe Kotlin", "Use BLE"])
        #expect(decisions.map(\.status) == [.active, .proposed, .superseded])

        let facts = index.entries(project: "alpha", section: .facts)
        #expect(facts.map(\.title) == ["alpha fact", "Zeta fact"])

        let meeting = index.entries(project: "alpha", section: .meetings).first
        #expect(meeting?.date == "2026-02-10")
    }

    @Test func searchIsScopedToProjectUnlessAll() throws {
        let kb = try makeKB()
        let index = try KBIndex.load(root: kb.url)
        let scoped = index.search("CREDIT", project: "alpha")
        #expect(scoped.map(\.project.id) == ["alpha"])
        #expect(scoped.first?.entries.map(\.title) == ["Zeta fact"])

        let all = index.search("credit")
        #expect(all.map(\.project.id) == ["alpha", "beta"])
        #expect(index.search("firmware").first?.entries.map(\.title) == ["Credits"])
        #expect(index.search("faster transfers").first?.entries.map(\.title) == ["Use BLE 5"])
        #expect(index.search("   ").isEmpty)
        #expect(index.search("ble", project: "beta").isEmpty)
    }

    @Test func timelineLinksSupersedeChains() throws {
        let kb = try makeKB()
        let index = try KBIndex.load(root: kb.url)
        let timeline = index.decisionTimeline(project: "alpha")
        #expect(timeline.chains.count == 1)
        #expect(timeline.chains.first?.entries.map(\.title) == ["Use BLE", "Use BLE 5"])
        #expect(timeline.standalone.map(\.title) == ["Maybe Kotlin"])
    }

    @Test func missingRootAndRegistry() throws {
        let dir = try TempDir()
        #expect(throws: KBLoadError.registryMissing(dir.url.path)) { try KBIndex.load(root: dir.url) }
        let gone = dir.url.appendingPathComponent("nope")
        #expect(throws: KBLoadError.rootMissing(gone.path)) { try KBIndex.load(root: gone) }
        try dir.write("kb.json", "{\"nope\": 1}")
        #expect(throws: KBLoadError.self) { try KBIndex.load(root: dir.url) }
    }
}

@Suite struct StoreTests {
    @Test func createsEntriesWithTemplates() throws {
        let kb = try makeKB()
        let decision = try KBStore.create(project: "alpha", section: .decisions, title: "Store export formats", root: kb.url, date: "2026-11-06")
        #expect(decision.id.rawValue == "alpha/decisions/2026-11-06-store-export-formats")
        let text = try kb.read("projects/alpha/decisions/2026-11-06-store-export-formats.md")
        #expect(text == """
        ---
        title: Store export formats
        date: 2026-11-06
        status: active
        summary:
        tags: []
        ---

        ## Decision


        ## Why


        ## Consequences


        """)
        let again = try KBStore.create(project: "alpha", section: .decisions, title: "Store export formats", root: kb.url, date: "2026-11-06")
        #expect(again.id.stem == "2026-11-06-store-export-formats-2")

        let fact = try KBStore.create(project: "alpha", section: .facts, title: "Ærø fact", root: kb.url)
        #expect(fact.id.rawValue == "alpha/facts/aeroe-fact")
        let meeting = try KBStore.create(project: "beta", section: .meetings, title: "Kickoff", root: kb.url, date: "2026-11-06")
        #expect(try kb.read("projects/beta/meetings/2026-11-06-kickoff.md").contains("attendees: []\n"))
        #expect(meeting.frontmatter.keys == ["title", "date", "summary", "attendees", "tags"])
        #expect(throws: KBStoreError.emptyTitle) {
            try KBStore.create(project: "alpha", section: .facts, title: "  ", root: kb.url)
        }
    }

    @Test func supersedeUpdatesBothFilesOnFirstSave() throws {
        let kb = try makeKB()
        let old = EntryID("alpha/decisions/2026-02-01-proposal")!
        var doc = try KBStore.newDocument(project: "alpha", section: .decisions, title: "Kotlin it is",
                                          root: kb.url, date: "2026-04-01", supersedes: [old])
        #expect(doc.isNew)
        #expect(doc.frontmatter.list("supersedes") == [old.rawValue])
        #expect(!FileManager.default.fileExists(atPath: doc.url.path))
        #expect(!(try kb.read("projects/alpha/decisions/2026-02-01-proposal.md")).contains("superseded"))

        doc.body = "\n## Decision\nKotlin.\n"
        let result = try KBStore.save(&doc, root: kb.url)
        #expect(result.superseded == [old])
        #expect(!doc.isDirty)

        let newText = try kb.read("projects/alpha/decisions/2026-04-01-kotlin-it-is.md")
        #expect(newText.contains("supersedes: [alpha/decisions/2026-02-01-proposal]\n"))
        #expect(newText.hasSuffix("## Decision\nKotlin.\n"))
        #expect(try kb.read("projects/alpha/decisions/2026-02-01-proposal.md") == """
        ---
        title: Maybe Kotlin
        date: 2026-02-01
        status: superseded
        superseded_by: alpha/decisions/2026-04-01-kotlin-it-is
        ---

        """)

        let index = try KBIndex.load(root: kb.url)
        #expect(index.decisionTimeline(project: "alpha").chains.map { $0.entries.map(\.title) }
                .contains(["Maybe Kotlin", "Kotlin it is"]))

        // A later save does not touch the old file again.
        try kb.write("projects/alpha/decisions/2026-02-01-proposal.md", "---\ntitle: Maybe Kotlin\n---\nedited\n")
        doc.body += "more\n"
        #expect(try KBStore.save(&doc, root: kb.url).superseded.isEmpty)
        #expect(try kb.read("projects/alpha/decisions/2026-02-01-proposal.md") == "---\ntitle: Maybe Kotlin\n---\nedited\n")
    }

    @Test func supersedeSkipsIdsThatDoNotExist() throws {
        let kb = try makeKB()
        var doc = try KBStore.newDocument(project: "alpha", section: .decisions, title: "X", root: kb.url, date: "2026-05-01",
                                          supersedes: [EntryID("beta/decisions/2026-01-01-missing")!])
        let result = try KBStore.save(&doc, root: kb.url)
        #expect(result.missing == ["beta/decisions/2026-01-01-missing"])
        #expect(!FileManager.default.fileExists(atPath: kb.url.appendingPathComponent("projects/beta/decisions").path))
    }

    @Test func refusesToWriteOutsideItsProject() throws {
        let kb = try makeKB()
        let id = EntryID("alpha/facts/x")!
        var doc = EntryDocument(id: id, url: kb.url.appendingPathComponent("projects/beta/facts/x.md"),
                                frontmatter: Frontmatter(), body: "x")
        #expect(throws: KBStoreError.self) { try KBStore.save(&doc, root: kb.url) }
    }

    @Test func savePreservesUnknownKeysAndBody() throws {
        let kb = try makeKB()
        try kb.write("projects/alpha/facts/u.md", "---\ntitle: U\nowner: \"Bo: fw\"\nx_list: [1, 2]\n---\nBody stays\n")
        var doc = try KBStore.load(EntryID("alpha/facts/u")!, root: kb.url)
        doc.frontmatter.setString("title", "U2")
        try KBStore.save(&doc, root: kb.url)
        #expect(try kb.read("projects/alpha/facts/u.md") == "---\ntitle: U2\nowner: \"Bo: fw\"\nx_list: [1, 2]\n---\nBody stays\n")
    }
}

@Suite struct FileWatcherTests {
    @Test func reportsFileChanges() async throws {
        let dir = try TempDir()
        let queue = DispatchQueue(label: "test")
        let received = await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            let once = OnceBox(cont)
            let watcher = FileWatcher(path: dir.url.path, debounce: 0.1, callbackQueue: queue) { paths in
                once.resume(paths)
            }
            #expect(watcher.start())
            once.keepAlive = watcher
            queue.asyncAfter(deadline: .now() + 0.5) {
                try? Data("x".utf8).write(to: dir.url.appendingPathComponent("a.md"))
            }
            queue.asyncAfter(deadline: .now() + 10) { once.resume([]) }
        }
        #expect(received.contains { $0.hasSuffix("/a.md") })
    }
}

final class OnceBox: @unchecked Sendable {
    private var cont: CheckedContinuation<[String], Never>?
    private let lock = NSLock()
    var keepAlive: AnyObject?

    init(_ c: CheckedContinuation<[String], Never>) { cont = c }

    func resume(_ value: [String]) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
