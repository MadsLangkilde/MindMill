import Foundation
import Testing
@testable import KBCore

struct ResearchTests {
    let body = """
    ## Question
    Can we upload samples in the background on iOS?

    ## Findings
    - BGTaskScheduler gives about 30 s
    - URLSession background uploads survive the app being killed

    ## Open questions
    - [ ] Does the BFF accept chunked uploads?
    - [x] Is iOS 15 still supported?

    ## Sources
    - https://developer.apple.com/documentation/backgroundtasks

    ## Summary
    Yes, with a background URLSession.

    ## Takeaways
    - Use a background URLSession, not BGTaskScheduler
    - Uploads must be files on disk
    """

    @Test func readsTheSections() {
        let r = ResearchBody(body)
        #expect(r.question == "Can we upload samples in the background on iOS?")
        #expect(r.findings.count == 2)
        #expect(r.openQuestions == ["Does the BFF accept chunked uploads?"])
        #expect(r.sources == ["https://developer.apple.com/documentation/backgroundtasks"])
        #expect(r.summary == "Yes, with a background URLSession.")
        #expect(r.takeaways == ["Use a background URLSession, not BGTaskScheduler", "Uploads must be files on disk"])
    }

    @Test func templateHasEverySection() {
        let r = ResearchBody(ResearchBody.template(question: "Why?"))
        #expect(r.question == "Why?")
        #expect(r.findings.isEmpty && r.takeaways.isEmpty && r.summary.isEmpty)
        for h in ["Question", "Findings", "Open questions", "Sources", "Summary", "Takeaways"] {
            #expect(GoalBody.section(h, in: ResearchBody.template(question: "")) != nil)
        }
    }

    @Test func targets() {
        #expect(ResearchTarget("wi:1234") == .workItem(1234))
        #expect(ResearchTarget("#77") == .workItem(77))
        #expect(ResearchTarget("acme-go/ideas/2026-11-01-x") == .entry(EntryID("acme-go/ideas/2026-11-01-x")!))
        #expect(ResearchTarget("acme-go/research/2026-11-01-x") == nil)
        #expect(ResearchTarget("nonsense") == nil)
        #expect(ResearchTarget.workItem(5).rawValue == "wi:5")
    }

    @Test func transferText() {
        #expect(ResearchTransfer.text(["  a ", "", "b"]) == "- a\n- b")
    }

    @Test func appendsUnderResearchHeading() {
        let first = ResearchTransfer.appending("- a", to: "## The idea\nX\n", title: "Uploads", date: "2026-11-20")
        #expect(first.hasSuffix("## Research\n\n**Uploads** (2026-11-20)\n\n- a\n"))
        let second = ResearchTransfer.appending("- b", to: first, title: "More", date: "2026-11-21")
        let section = GoalBody.section("Research", in: second) ?? ""
        #expect(section.contains("- a") && section.contains("**More** (2026-11-21)\n\n- b"))
        #expect(second.components(separatedBy: "## Research").count == 2)
    }

    @Test func detectsResearch() {
        #expect(ResearchDetect.looksLikeResearch("How does the BFF dedupe uploads?"))
        #expect(ResearchDetect.looksLikeResearch("Compare Room and SQLDelight for us"))
        #expect(ResearchDetect.looksLikeResearch("Undersøg om vi kan bruge passkeys"))
        #expect(!ResearchDetect.looksLikeResearch("Implement the upload retry"))
        #expect(!ResearchDetect.looksLikeResearch("Fix the crash on login, why does it happen?"))
        #expect(!ResearchDetect.looksLikeResearch("/kb:work-item 1234"))
        #expect(!ResearchDetect.looksLikeResearch("Rename the module"))
    }

    @Test func offersOnlyOnceAndNotAfterEdits() {
        let q = "Which library should we use for charts?"
        #expect(ResearchDetect.shouldOffer(firstMessage: q, toolLines: ["Read\tFoo.kt", "WebSearch\tcharts"], offered: false))
        #expect(!ResearchDetect.shouldOffer(firstMessage: q, toolLines: [], offered: true))
        #expect(!ResearchDetect.shouldOffer(firstMessage: q, toolLines: ["Edit\tFoo.kt"], offered: false))
        #expect(!ResearchDetect.shouldOffer(firstMessage: q, toolLines: ["Bash\tgit commit -m x"], offered: false))
    }

    @Test func researchSessionsAreKept() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kb-research-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let old = Date(timeIntervalSinceNow: -90 * 86_400)
        let msg = [SessionRecord.Message(role: "user", text: "hi")]
        let research = SessionRecord(title: "R", project: nil, workingDirectory: "/", updated: old, messages: msg,
                                     about: "research:x/research/2026-01-01-r")
        let stale = SessionRecord(title: "S", project: nil, workingDirectory: "/", updated: old, messages: msg)
        let many = (0..<SessionStore.maxSessions).map { SessionRecord(title: "N\($0)", project: nil, workingDirectory: "/", messages: msg) }
        try SessionStore.save([research, stale] + many, to: url)
        let loaded = SessionStore.load(from: url)
        #expect(loaded.contains { $0.id == research.id })
        #expect(!loaded.contains { $0.id == stale.id })
        #expect(loaded.count == SessionStore.maxSessions + 1)
    }

    @Test func researchOfferedRoundTrips() throws {
        let r = SessionRecord(title: "T", project: nil, workingDirectory: "/", researchOffered: true)
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(SessionRecord.self, from: data).researchOffered == true)
    }

    @Test func planKind() {
        #expect(PlanSessions.kind(title: "Research: x", about: "research:a/research/b", firstMessage: "/kb:research start") == .research)
    }

    @Test func sidebarPutsResearchAfterIdeas() {
        let order = SidebarOrder.resolve(["inbox", "ideas", "facts"], defaults: SidebarOrder.planning)
        #expect(order.firstIndex(of: "research") == order.firstIndex(of: "ideas")! + 1)
    }
}
