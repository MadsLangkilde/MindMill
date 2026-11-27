import Foundation
import Testing
@testable import KBCore

@Suite struct ReadableTests {
    @Test func toolStepsInWords() {
        #expect(ToolDescription.step("Read\tMeetingWindow.swift") == .init(title: "Read MeetingWindow.swift", code: nil))
        let send = ToolDescription.step("Bash\tkb crew send bd4b04b9 \"Overview here: what exactly is the scope?\"")
        #expect(send.title == "Messaged a session: “Overview here: what exactly is the scope?”")
        #expect(send.code == "kb crew send bd4b04b9 \"Overview here: what exactly is the scope?\"")
        // Claude's own description wins, and the full command is kept apart.
        let cmd = "cd /x && ./gradlew :app:testDebugUnitTest"
        let line = ToolSummary.line(name: "Bash", input: ["command": cmd, "description": "Run the app's unit tests"])
        #expect(ToolDescription.step("Bash\t" + line) == .init(title: "Run the app's unit tests", code: cmd))
        let bare = ToolSummary.line(name: "Bash", input: ["command": cmd])
        #expect(ToolDescription.step("Bash\t" + bare).title == "Ran the tests")
        #expect(ToolDescription.step("Bash\tgit status --short").title == "Checked what changed")
        #expect(ToolDescription.step("mcp__claude_ai_Microsoft_365__outlook_email_search\tsprint").title.hasPrefix("claude: "))
    }

    @Test func crewMessagesSplitAndRead() {
        let old = "✉ #418750 Pairing: never connects (lead): 418750 scope decision. Options: (1) RECOMMENDED: log it; (2) logging only. (3) Reproduce first."
        let m = CrewMessage.split(old)!
        #expect(m.from == "#418750 Pairing: never connects (lead)")
        let r = CrewMessage.readable(m.text)
        #expect(r == "418750 scope decision. **Options:**\n1. **RECOMMENDED:** log it;\n2. logging only.\n3. Reproduce first.")
        #expect(CrewMessage.split("✉ the overview session\nHello\nthere")! == ("the overview session", "Hello\nthere"))
        #expect(CrewMessage.split("Hello") == nil)
        #expect(CrewMessage.readable("Pick (1) only") == "Pick (1) only")
    }
}

@Suite struct StrategyShapeTests {
    private func load(_ slug: String) throws -> Strategy {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../strategies/\(slug).md")
        return Strategy.parse(try String(contentsOf: url, encoding: .utf8), slug: slug, origin: .builtIn)
    }

    @Test func builtInsDrawSensibly() throws {
        let crew = try load("auto-crew").shape
        #expect(crew.steps.map(\.title) == ["Size it up", "Split it", "Coordinate", "Report up", "Ask the user only for decisions"])
        #expect(crew.helpers.count == 4)
        let plan = try load("plan-first").shape
        #expect(plan.steps.map(\.kind) == [.work, .work, .approval, .work])
        #expect(plan.steps.last?.repeats == true)
        #expect(plan.helpers.isEmpty)
        let review = try load("builder-reviewer").shape
        #expect(review.helpers.map(\.label) == ["Reviewer"])
        #expect(try load("tests-first").shape.loops)
    }
}

@Suite struct PrepLinkTests {
    @Test func findsDocumentLinksNotJoinLinks() {
        let prep = "- **Invite:** plan here: https://claude.ai/artifact/ExampleArtifactId00001. Join: https://teams.microsoft.com/l/meetup-join/abc (and https://acme.sharepoint.com/sites/x/Plan.docx)"
        let urls = PrepLinks.find(prep)
        #expect(urls.map(\.absoluteString) == ["https://claude.ai/artifact/ExampleArtifactId00001", "https://acme.sharepoint.com/sites/x/Plan.docx"])
        #expect(PrepLinks.label(urls[0]) == "Claude artifact")
        #expect(PrepLinks.label(urls[1]) == "acme.sharepoint.com/Plan.docx")
        #expect(MarkdownBlocks.parse("Can't open it.\n\n```capture\nhttps://claude.ai/artifact/x\n```") == [.paragraph("Can't open it."), .capture(urls: ["https://claude.ai/artifact/x"])])
    }

    @Test func messagesFromOtherSessionsNameTheirSenderAndPreviewOnOneLine() {
        #expect(CrewMessage.split("[From the overview session]\nDo **this**\nnow")! == ("the overview session", "Do **this**\nnow"))
        #expect(CrewMessage.split("[From the Mindmill app] Your reply ended")! == ("the Mindmill app", "Your reply ended"))
        #expect(CrewMessage.split("[From you, through Login's crew]\nBuild it") == nil)
        #expect(CrewMessage.split("Just me") == nil)
        #expect(CrewMessage.sender("the overview session") == "Overview")
        #expect(CrewMessage.sender("Login (lead)") == "Session “Login” (lead)")
        #expect(CrewMessage.sender("UI part") == "Session “UI part”")
        #expect(CrewMessage.preview("**Status:** done\n\n- `a`\n- b") == "Status: done - a - b")
        #expect(CrewMessage.preview(String(repeating: "x", count: 200)).count == 140)
    }
}

