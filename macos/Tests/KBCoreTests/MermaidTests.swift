import Foundation
import Testing
@testable import KBCore

@Suite struct MermaidTests {
    private let doc = "# Arch\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\nText\n\n```kotlin\nval x = 1\n```\n\n```mermaid\nsequenceDiagram\n  A->>B: hi\n```\n"

    @Test func rendersDiagramsWithEditLinks() {
        let html = MarkdownRenderer(diagramLinks: true).render(doc)
        #expect(html.contains("<pre class=\"mermaid\">flowchart LR\n  A --&gt; B</pre><a class=\"diagram-edit\" href=\"kb://diagram?index=0\">"))
        #expect(html.contains("kb://diagram?index=1"))
        #expect(html.contains("language-kotlin"))
        #expect(MarkdownRenderer.page(body: html).contains(MarkdownRenderer.mermaidScript))
        #expect(!MarkdownRenderer.page(body: "<p>x</p>").contains(MarkdownRenderer.mermaidScript))
        #expect(!MarkdownRenderer().render(doc).contains("diagram-edit"))
    }

    @Test func replacesOrAppendsADiagram() {
        #expect(MermaidBlocks.find(in: doc).map(\.source) == ["flowchart LR\n  A --> B", "sequenceDiagram\n  A->>B: hi"])
        let edited = MermaidBlocks.replacing(1, with: "sequenceDiagram\n  A->>C: yo\n", in: doc)
        #expect(MermaidBlocks.find(in: edited).map(\.source) == ["flowchart LR\n  A --> B", "sequenceDiagram\n  A->>C: yo"])
        #expect(edited.contains("val x = 1"))
        let added = MermaidBlocks.replacing(5, with: "graph TD\n  X", in: "# T\n")
        #expect(added == "# T\n\n```mermaid\ngraph TD\n  X\n```\n")
    }
}
