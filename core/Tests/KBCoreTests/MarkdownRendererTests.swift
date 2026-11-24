import Testing
@testable import KBCore

@Suite struct MarkdownRendererTests {
    let r = MarkdownRenderer(linkRewriter: MarkdownRenderer.entryLinkRewriter)

    @Test func headings() {
        #expect(r.render("# Title") == "<h1 id=\"title\">Title</h1>")
        #expect(r.render("### Why it *matters* ###") == "<h3 id=\"why-it-matters\">Why it <em>matters</em></h3>")
        #expect(r.render("####### seven") == "<p>####### seven</p>")
        #expect(r.render("#nospace") == "<p>#nospace</p>")
    }

    @Test func paragraphsAndInline() {
        #expect(r.render("Hello **bold** and *it* and _it_ and `a<b>`.\nnext line")
                == "<p>Hello <strong>bold</strong> and <em>it</em> and <em>it</em> and <code>a&lt;b&gt;</code>.\nnext line</p>")
        #expect(r.render("snake_case_name stays") == "<p>snake_case_name stays</p>")
        #expect(r.render("a ~~gone~~ b") == "<p>a <del>gone</del> b</p>")
        #expect(r.render("***both***") == "<p><strong><em>both</em></strong></p>")
        #expect(r.render("<script>alert(1)</script>") == "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")
        #expect(r.render("2 * 3 * 4") == "<p>2 * 3 * 4</p>")
        #expect(r.render("one  \ntwo") == "<p>one<br>\ntwo</p>")
        #expect(r.render("p1\n\np2") == "<p>p1</p>\n<p>p2</p>")
    }

    @Test func links() {
        #expect(r.render("[Docs](https://example.com/a_(b)) and https://foo.dk/x.")
                == "<p><a href=\"https://example.com/a_(b)\">Docs</a> and <a href=\"https://foo.dk/x\">https://foo.dk/x</a>.</p>")
        #expect(r.render("see [old](acme-go/decisions/2026-11-04-x)")
                == "<p>see <a href=\"kb://open?id=acme-go/decisions/2026-11-04-x\">old</a></p>")
        #expect(r.render("[x](javascript:alert(1))") == "<p><a href=\"#\">x</a></p>")
        #expect(r.render("<https://a.dk>") == "<p><a href=\"https://a.dk\">https://a.dk</a></p>")
        #expect(r.render("[not a link] here") == "<p>[not a link] here</p>")
    }

    @Test func fencedCode() {
        let md = "```kotlin\nval x = a < b && c\n\n# not a heading\n```\nafter"
        #expect(r.render(md) == "<pre><code class=\"language-kotlin\">val x = a &lt; b &amp;&amp; c\n\n# not a heading</code></pre>\n<p>after</p>")
        #expect(r.render("~~~\nunclosed") == "<pre><code>unclosed</code></pre>")
    }

    @Test func unorderedAndNestedLists() {
        let md = """
        - one
        - two
          - nested **b**
          - nested 2
        - three
        """
        #expect(r.render(md) == """
        <ul>
        <li>one</li>
        <li>two
        <ul>
        <li>nested <strong>b</strong></li>
        <li>nested 2</li>
        </ul></li>
        <li>three</li>
        </ul>
        """)
    }

    @Test func orderedAndLooseLists() {
        #expect(r.render("3. c\n4. d") == "<ol start=\"3\">\n<li>c</li>\n<li>d</li>\n</ol>")
        #expect(r.render("1. a\n\n2. b") == "<ol>\n<li><p>a</p></li>\n<li><p>b</p></li>\n</ol>")
        #expect(r.render("- a\n\npara") == "<ul>\n<li>a</li>\n</ul>\n<p>para</p>")
        #expect(r.render("- a\n1. b") == "<ul>\n<li>a</li>\n</ul>\n<ol>\n<li>b</li>\n</ol>")
    }

    @Test func taskLists() {
        #expect(r.render("- [ ] todo\n- [x] done") == """
        <ul class="contains-task-list">
        <li class="task"><input type="checkbox" disabled> todo</li>
        <li class="task"><input type="checkbox" disabled checked> done</li>
        </ul>
        """)
    }

    @Test func tables() {
        let md = """
        | Name | Count | Note |
        |:-----|------:|:----:|
        | a | 1 | `x|y` |
        | b \\| c | 2 |
        """
        #expect(r.render(md) == """
        <table>
        <thead>
        <tr><th style="text-align:left">Name</th><th style="text-align:right">Count</th><th style="text-align:center">Note</th></tr>
        </thead>
        <tbody>
        <tr><td style="text-align:left">a</td><td style="text-align:right">1</td><td style="text-align:center"><code>x|y</code></td></tr>
        <tr><td style="text-align:left">b | c</td><td style="text-align:right">2</td><td style="text-align:center"></td></tr>
        </tbody>
        </table>
        """)
        #expect(r.render("a | b\nnot a delimiter") == "<p>a | b\nnot a delimiter</p>")
    }

    @Test func blockquotesAndRules() {
        #expect(r.render("> quoted *text*\n> more\n\n---\n***") ==
                "<blockquote>\n<p>quoted <em>text</em>\nmore</p>\n</blockquote>\n<hr>\n<hr>")
        #expect(r.render("> # H\n> - item") == "<blockquote>\n<h1 id=\"h\">H</h1>\n<ul>\n<li>item</li>\n</ul>\n</blockquote>")
    }

    @Test func pageWrapsBody() {
        let page = MarkdownRenderer.page(body: "<p>x</p>")
        #expect(page.contains("prefers-color-scheme: dark"))
        #expect(page.contains("-apple-system"))
        #expect(page.contains("<p>x</p>"))
    }
}
