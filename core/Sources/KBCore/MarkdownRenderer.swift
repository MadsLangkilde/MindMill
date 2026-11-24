import Foundation

/// A small Markdown-to-HTML renderer: headings, paragraphs, emphasis, inline code, fenced code,
/// nested ordered/unordered lists with task checkboxes, links, images, blockquotes, horizontal rules
/// and pipe tables. Raw HTML in the source is escaped, never passed through.
public struct MarkdownRenderer {
    /// Rewrites link targets, e.g. an entry id to `kb://open?id=…`. Return `nil` to keep the href.
    public var linkRewriter: ((String) -> String?)?
    /// Puts an "Edit diagram" link (`kb://diagram?index=<n>`) under each Mermaid diagram.
    public var diagramLinks = false
    private let diagramCount = DiagramCounter()

    public init(linkRewriter: ((String) -> String?)? = nil, diagramLinks: Bool = false) {
        self.linkRewriter = linkRewriter
        self.diagramLinks = diagramLinks
    }

    /// Rewrites entry ids (`project/section/stem`, `project/overview`) to `kb://open?id=…` links.
    public static let entryLinkRewriter: (String) -> String? = { href in
        guard !href.contains(":"), !href.hasPrefix("#"), let id = EntryID(href) else { return nil }
        let encoded = id.rawValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id.rawValue
        return "kb://open?id=\(encoded)"
    }

    public func render(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        diagramCount.n = 0
        return renderBlocks(lines, tight: false)
    }

    // MARK: Blocks

    func renderBlocks(_ lines: [String], tight: Bool) -> String {
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            if let fence = Fence(line) {
                var code: [String] = []
                i += 1
                while i < lines.count, !fence.closes(lines[i]) {
                    code.append(fence.strip(lines[i]))
                    i += 1
                }
                if i < lines.count { i += 1 }
                if fence.language.lowercased() == "mermaid" {
                    let n = diagramCount.n
                    diagramCount.n += 1
                    let edit = diagramLinks ? "<a class=\"diagram-edit\" href=\"kb://diagram?index=\(n)\">Edit diagram</a>" : ""
                    out.append("<div class=\"diagram\"><pre class=\"mermaid\">\(escape(code.joined(separator: "\n")))</pre>\(edit)</div>")
                    continue
                }
                let cls = fence.language.isEmpty ? "" : " class=\"language-\(escape(fence.language))\""
                out.append("<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }
            if let (level, text) = heading(line) {
                out.append("<h\(level) id=\"\(Slug.make(text))\">\(inline(text))</h\(level)>")
                i += 1
                continue
            }
            if isHorizontalRule(line) {
                out.append("<hr>")
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") && indentWidth(line) < 4 {
                var inner: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    if t.hasPrefix(">") {
                        var rest = t.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        inner.append(String(rest))
                    } else if !inner.isEmpty, !startsBlock(lines, i) {
                        inner.append(t)
                    } else {
                        break
                    }
                    i += 1
                }
                out.append("<blockquote>\n\(renderBlocks(inner, tight: false))\n</blockquote>")
                continue
            }
            if ListMarker(line) != nil {
                let (html, next) = renderList(lines, from: i)
                out.append(html)
                i = next
                continue
            }
            if isTableStart(lines, i) {
                let (html, next) = renderTable(lines, from: i)
                out.append(html)
                i = next
                continue
            }

            var para: [String] = [line]
            i += 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !startsBlock(lines, i) {
                para.append(lines[i])
                i += 1
            }
            let html = paragraphHTML(para)
            out.append(tight ? html : "<p>\(html)</p>")
        }
        return out.joined(separator: "\n")
    }

    func paragraphHTML(_ lines: [String]) -> String {
        var parts: [String] = []
        for (n, raw) in lines.enumerated() {
            let isLast = n == lines.count - 1
            var line = raw.drop(while: { $0 == " " || $0 == "\t" })
            var hardBreak = false
            if !isLast {
                if line.hasSuffix("  ") { hardBreak = true }
                else if line.hasSuffix("\\") { hardBreak = true; line = line.dropLast() }
            }
            let text = String(line).trimmingCharacters(in: .whitespaces)
            parts.append(inline(text) + (hardBreak ? "<br>" : ""))
        }
        return parts.joined(separator: "\n")
    }

    func startsBlock(_ lines: [String], _ i: Int) -> Bool {
        let line = lines[i]
        let t = line.trimmingCharacters(in: .whitespaces)
        return Fence(line) != nil || heading(line) != nil || isHorizontalRule(line)
            || (t.hasPrefix(">") && indentWidth(line) < 4) || ListMarker(line) != nil || isTableStart(lines, i)
    }

    func heading(_ line: String) -> (Int, String)? {
        guard indentWidth(line) < 4 else { return nil }
        let t = line.trimmingCharacters(in: .whitespaces)
        let hashes = t.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = t.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(range) }
        else if text.allSatisfy({ $0 == "#" }) { text = "" }
        return (hashes, text)
    }

    func isHorizontalRule(_ line: String) -> Bool {
        guard indentWidth(line) < 4 else { return false }
        let chars = line.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3, let c = chars.first, c == "-" || c == "*" || c == "_" else { return false }
        return chars.allSatisfy { $0 == c }
    }

    // MARK: Lists

    func renderList(_ lines: [String], from start: Int) -> (String, Int) {
        guard let first = ListMarker(lines[start]) else { return ("", start + 1) }
        var items: [[String]] = []
        var contentOffset = first.contentOffset
        var loose = false
        var i = start
        var previousBlank = false

        while i < lines.count {
            let line = lines[i]
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if !blank, let m = ListMarker(line), m.indent < contentOffset {
                guard m.ordered == first.ordered, m.bullet == first.bullet else { break }
                if previousBlank { loose = true }
                items.append([m.content])
                contentOffset = m.contentOffset
                previousBlank = false
                i += 1
                continue
            }
            if blank {
                var j = i
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                guard j < lines.count else { break }
                if indentWidth(lines[j]) >= contentOffset {
                    items[items.count - 1].append("")
                    previousBlank = true
                    i += 1
                    continue
                }
                if let m = ListMarker(lines[j]), m.indent < contentOffset, m.ordered == first.ordered, m.bullet == first.bullet {
                    previousBlank = true
                    i = j
                    continue
                }
                break
            }
            if indentWidth(line) >= contentOffset {
                if previousBlank, items[items.count - 1].contains(where: { !$0.isEmpty }) { loose = true }
                items[items.count - 1].append(dedent(line, contentOffset))
                previousBlank = false
                i += 1
                continue
            }
            if !previousBlank, !startsBlock(lines, i) {
                items[items.count - 1].append(line.trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }
            break
        }

        var hasTasks = false
        var lis: [String] = []
        for var item in items {
            while item.last?.isEmpty == true { item.removeLast() }
            var checkbox = ""
            if let firstLine = item.first, let (checked, rest) = taskPrefix(firstLine) {
                hasTasks = true
                item[0] = rest
                checkbox = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
            }
            let inner = renderBlocks(item, tight: !loose)
            let cls = checkbox.isEmpty ? "" : " class=\"task\""
            lis.append("<li\(cls)>\(checkbox)\(inner)</li>")
        }
        let tag = first.ordered ? "ol" : "ul"
        var attrs = ""
        if first.ordered, let n = first.number, n != 1 { attrs += " start=\"\(n)\"" }
        if hasTasks { attrs += " class=\"contains-task-list\"" }
        return ("<\(tag)\(attrs)>\n\(lis.joined(separator: "\n"))\n</\(tag)>", i)
    }

    func taskPrefix(_ s: String) -> (Bool, String)? {
        for (marker, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] {
            if s == marker { return (checked, "") }
            if s.hasPrefix(marker + " ") { return (checked, String(s.dropFirst(4))) }
        }
        return nil
    }

    // MARK: Tables

    func isTableStart(_ lines: [String], _ i: Int) -> Bool {
        guard i + 1 < lines.count, lines[i].contains("|"), indentWidth(lines[i]) < 4 else { return false }
        guard let aligns = delimiterRow(lines[i + 1]) else { return false }
        return splitRow(lines[i]).count == aligns.count
    }

    func delimiterRow(_ line: String) -> [String?]? {
        guard line.contains("-") else { return nil }
        let cells = splitRow(line)
        guard !cells.isEmpty, line.contains("|") || cells.count > 1 else { return nil }
        var aligns: [String?] = []
        for c in cells {
            let t = c.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            let left = t.hasPrefix(":"), right = t.hasSuffix(":")
            aligns.append(left && right ? "center" : right ? "right" : left ? "left" : nil)
        }
        return aligns
    }

    func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in t {
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    func renderTable(_ lines: [String], from start: Int) -> (String, Int) {
        let header = splitRow(lines[start])
        let aligns = delimiterRow(lines[start + 1]) ?? []
        func cell(_ tag: String, _ text: String, _ col: Int) -> String {
            let a = col < aligns.count ? aligns[col] : nil
            let style = a.map { " style=\"text-align:\($0)\"" } ?? ""
            return "<\(tag)\(style)>\(inline(text))</\(tag)>"
        }
        var html = "<table>\n<thead>\n<tr>"
        html += header.enumerated().map { cell("th", $1, $0) }.joined()
        html += "</tr>\n</thead>\n"
        var i = start + 2
        var rows: [String] = []
        while i < lines.count {
            let l = lines[i]
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || !t.contains("|") { break }
            if Fence(l) != nil || heading(l) != nil || (t.hasPrefix(">")) { break }
            var cells = splitRow(l)
            if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
            if cells.count > header.count { cells = Array(cells.prefix(header.count)) }
            rows.append("<tr>" + cells.enumerated().map { cell("td", $1, $0) }.joined() + "</tr>")
            i += 1
        }
        if !rows.isEmpty { html += "<tbody>\n\(rows.joined(separator: "\n"))\n</tbody>\n" }
        html += "</table>"
        return (html, i)
    }

    // MARK: Inline

    public func inline(_ s: String) -> String {
        let c = Array(s)
        var out = ""
        var i = 0
        while i < c.count {
            let ch = c[i]
            switch ch {
            case "\\":
                if i + 1 < c.count, c[i + 1].isASCII, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                    out += escape(String(c[i + 1]))
                    i += 2
                } else {
                    out += "\\"
                    i += 1
                }
            case "`":
                let n = run(c, i, "`")
                if let close = findBacktickClose(c, from: i + n, count: n) {
                    var code = String(c[(i + n)..<close])
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    out += "<code>\(escape(code))</code>"
                    i = close + n
                } else {
                    out += String(repeating: "`", count: n)
                    i += n
                }
            case "!" where i + 1 < c.count && c[i + 1] == "[":
                if let link = parseLink(c, i + 1) {
                    out += "<img src=\"\(escape(safeURL(link.url, rewrite: false)))\" alt=\"\(escape(plainText(link.text)))\">"
                    i = link.end
                } else {
                    out += "!"
                    i += 1
                }
            case "[":
                if let link = parseLink(c, i) {
                    let titleAttr = link.title.map { " title=\"\(escape($0))\"" } ?? ""
                    out += "<a href=\"\(escape(safeURL(link.url, rewrite: true)))\"\(titleAttr)>\(inline(link.text))</a>"
                    i = link.end
                } else {
                    out += "["
                    i += 1
                }
            case "<":
                if let close = c[(i + 1)...].firstIndex(of: ">") {
                    let inner = String(c[(i + 1)..<close])
                    if inner.range(of: #"^(https?|mailto|kb):[^\s<>]+$"#, options: .regularExpression) != nil {
                        out += "<a href=\"\(escape(safeURL(inner, rewrite: true)))\">\(escape(inner))</a>"
                        i = close + 1
                        continue
                    }
                }
                out += "&lt;"
                i += 1
            case "*", "_", "~":
                let n = run(c, i, ch)
                if ch == "_" && i > 0 && (c[i - 1].isLetter || c[i - 1].isNumber) {
                    out += String(repeating: "_", count: n)
                    i += n
                    continue
                }
                if ch == "~" && n != 2 {
                    out += String(repeating: "~", count: n)
                    i += n
                    continue
                }
                let len = (ch == "~") ? 2 : (n >= 2 ? 2 : 1)
                let openEnd = i + len
                if openEnd < c.count, !c[openEnd].isWhitespace,
                   let close = findCloser(c, from: openEnd, char: ch, length: len) {
                    let inner = String(c[openEnd..<close])
                    let tag = ch == "~" ? "del" : (len == 2 ? "strong" : "em")
                    out += "<\(tag)>\(inline(inner))</\(tag)>"
                    i = close + len
                } else {
                    out += String(repeating: String(ch), count: n)
                    i += n
                }
            case "h" where (i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber || c[i - 1] == "/")):
                if let end = bareURLEnd(c, i) {
                    let url = String(c[i..<end])
                    out += "<a href=\"\(escape(url))\">\(escape(url))</a>"
                    i = end
                } else {
                    out += "h"
                    i += 1
                }
            default:
                out += escape(String(ch))
                i += 1
            }
        }
        return out
    }

    struct Link { var text: String; var url: String; var title: String?; var end: Int }

    func parseLink(_ c: [Character], _ open: Int) -> Link? {
        guard c[open] == "[" else { return nil }
        var depth = 0
        var j = open
        var closeBracket: Int?
        while j < c.count {
            let ch = c[j]
            if ch == "\\" { j += 2; continue }
            if ch == "`" {
                let n = run(c, j, "`")
                if let close = findBacktickClose(c, from: j + n, count: n) { j = close + n; continue }
                j += n
                continue
            }
            if ch == "[" { depth += 1 }
            if ch == "]" {
                depth -= 1
                if depth == 0 { closeBracket = j; break }
            }
            j += 1
        }
        guard let cb = closeBracket, cb + 1 < c.count, c[cb + 1] == "(" else { return nil }
        var k = cb + 2
        while k < c.count, c[k] == " " { k += 1 }
        var url = ""
        if k < c.count, c[k] == "<" {
            guard let close = c[k...].firstIndex(of: ">") else { return nil }
            url = String(c[(k + 1)..<close])
            k = close + 1
        } else {
            var parens = 0
            while k < c.count {
                let ch = c[k]
                if ch == "\\", k + 1 < c.count { url.append(c[k + 1]); k += 2; continue }
                if ch == "(" { parens += 1 }
                if ch == ")" {
                    if parens == 0 { break }
                    parens -= 1
                }
                if ch == " " { break }
                url.append(ch)
                k += 1
            }
        }
        while k < c.count, c[k] == " " { k += 1 }
        var title: String?
        if k < c.count, c[k] == "\"" || c[k] == "'" {
            let q = c[k]
            guard let close = c[(k + 1)...].firstIndex(of: q) else { return nil }
            title = String(c[(k + 1)..<close])
            k = close + 1
            while k < c.count, c[k] == " " { k += 1 }
        }
        guard k < c.count, c[k] == ")" else { return nil }
        return Link(text: String(c[(open + 1)..<cb]), url: url, title: title, end: k + 1)
    }

    func safeURL(_ url: String, rewrite: Bool) -> String {
        let lower = url.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:text/html") { return "#" }
        if rewrite, let rewritten = linkRewriter?(url) { return rewritten }
        return url
    }

    func bareURLEnd(_ c: [Character], _ i: Int) -> Int? {
        let rest = String(c[i..<min(c.count, i + 8)])
        guard rest.hasPrefix("https://") || rest.hasPrefix("http://") else { return nil }
        var j = i
        var parens = 0
        while j < c.count, !c[j].isWhitespace, c[j] != "<" {
            if c[j] == "(" { parens += 1 }
            if c[j] == ")" { if parens == 0 { break }; parens -= 1 }
            j += 1
        }
        while j > i, ".,;:!?'\"*_".contains(c[j - 1]) { j -= 1 }
        return j > i + 8 ? j : nil
    }

    func run(_ c: [Character], _ i: Int, _ ch: Character) -> Int {
        var n = 0
        while i + n < c.count, c[i + n] == ch { n += 1 }
        return n
    }

    func findBacktickClose(_ c: [Character], from: Int, count: Int) -> Int? {
        var j = from
        while j < c.count {
            if c[j] == "`" {
                let n = run(c, j, "`")
                if n == count { return j }
                j += n
            } else {
                j += 1
            }
        }
        return nil
    }

    /// Finds a closing delimiter run of exactly `length` (or the tail of a longer run for strong).
    func findCloser(_ c: [Character], from: Int, char: Character, length: Int) -> Int? {
        var j = from
        while j < c.count {
            let ch = c[j]
            if ch == "\\" { j += 2; continue }
            if ch == "`" {
                let n = run(c, j, "`")
                if let close = findBacktickClose(c, from: j + n, count: n) { j = close + n; continue }
                j += n
                continue
            }
            if ch == char {
                let n = run(c, j, char)
                let precededBySpace = c[j - 1].isWhitespace
                let followedByWord = j + n < c.count && (c[j + n].isLetter || c[j + n].isNumber)
                let okForUnderscore = char != "_" || !followedByWord
                if !precededBySpace, okForUnderscore, j > from {
                    if n == length { return j }
                    if length == 2 && n == 3 { return j + 1 }
                    if length == 1 && n == 3 { return j + 2 }
                }
                j += n
                continue
            }
            j += 1
        }
        return nil
    }

    func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    func plainText(_ s: String) -> String {
        s.filter { !"*_`[]".contains($0) }
    }

    func indentWidth(_ line: String) -> Int {
        var w = 0
        for ch in line {
            if ch == " " { w += 1 } else if ch == "\t" { w += 4 - (w % 4) } else { break }
        }
        return w
    }

    func dedent(_ line: String, _ width: Int) -> String {
        var removed = 0
        var idx = line.startIndex
        while idx < line.endIndex, removed < width {
            let ch = line[idx]
            if ch == " " { removed += 1 } else if ch == "\t" { removed += 4 - (removed % 4) } else { break }
            idx = line.index(after: idx)
        }
        return String(line[idx...])
    }

    // MARK: Page

    /// A complete HTML document styled with the system font, following light/dark appearance.
    public static let mermaidScript = "https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"

    public static func page(body: String, accentHex: String? = nil) -> String {
        let accent = accentHex ?? "#0a64d8"
        // Diagrams draw with Mermaid when it loads; offline, their source shows as code.
        let mermaid = body.contains("class=\"mermaid\"") ? """
        <script src="\(mermaidScript)"></script>
        <script>
        if (window.mermaid) {
          mermaid.initialize({ startOnLoad: false, securityLevel: 'strict',
            theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default' });
          mermaid.run({ querySelector: 'pre.mermaid' }).catch(function () {});
        }
        </script>
        """ : ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
        :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --border: rgba(0,0,0,.12);
                --code-bg: rgba(0,0,0,.05); --link: \(accent); }
        @media (prefers-color-scheme: dark) {
          :root { --fg: #ececee; --muted: #a1a1a6; --border: rgba(255,255,255,.16); --code-bg: rgba(255,255,255,.08); }
        }
        html, body { background: transparent; }
        body { font: 14px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--fg);
               margin: 0; padding: 6px 28px 40px; max-width: 820px; -webkit-font-smoothing: antialiased;
               word-wrap: break-word; }
        h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 1.4em 0 .5em; }
        h1 { font-size: 1.6em; } h2 { font-size: 1.3em; } h3 { font-size: 1.1em; } h4, h5, h6 { font-size: 1em; }
        body > :first-child { margin-top: .6em; }
        p { margin: .6em 0; }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: .88em ui-monospace, "SF Mono", Menlo, monospace; background: var(--code-bg); padding: .1em .35em; border-radius: 4px; }
        pre { background: var(--code-bg); padding: 10px 14px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; font-size: 12px; line-height: 1.5; }
        blockquote { margin: .8em 0; padding: .1em 1em; border-left: 3px solid var(--border); color: var(--muted); }
        ul, ol { padding-left: 1.6em; } li { margin: .2em 0; } li > p { margin: .3em 0; }
        ul.contains-task-list { list-style: none; padding-left: 1.2em; }
        li.task > input { margin: 0 .45em 0 -1.25em; vertical-align: -1px; }
        hr { border: none; border-top: 1px solid var(--border); margin: 1.6em 0; }
        table { border-collapse: collapse; margin: .8em 0; font-size: .95em; }
        th, td { border: 1px solid var(--border); padding: 5px 11px; vertical-align: top; }
        th { background: var(--code-bg); font-weight: 600; text-align: left; }
        img { max-width: 100%; }
        del { color: var(--muted); }
        .empty { color: var(--muted); font-style: italic; }
        .diagram { margin: .8em 0; }
        pre.mermaid { background: none; padding: 4px 0; text-align: center; font-size: 12px; }
        .diagram-edit { display: block; text-align: right; font-size: 12px; }
        </style></head>
        <body>
        \(body)
        \(mermaid)
        </body></html>
        """
    }
}

struct Fence {
    let char: Character
    let count: Int
    let indent: Int
    let language: String

    init?(_ line: String) {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent < 4 else { return nil }
        let t = line.dropFirst(indent)
        guard let ch = t.first, ch == "`" || ch == "~" else { return nil }
        let n = t.prefix(while: { $0 == ch }).count
        guard n >= 3 else { return nil }
        let info = t.dropFirst(n).trimmingCharacters(in: .whitespaces)
        if ch == "`" && info.contains("`") { return nil }
        self.char = ch
        self.count = n
        self.indent = indent
        self.language = info.split(separator: " ").first.map(String.init) ?? ""
    }

    func closes(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= count && t.allSatisfy { $0 == char }
    }

    func strip(_ line: String) -> String {
        var removed = 0
        var s = Substring(line)
        while removed < indent, s.first == " " { s = s.dropFirst(); removed += 1 }
        return String(s)
    }
}

struct ListMarker {
    let ordered: Bool
    let bullet: Character?
    let number: Int?
    let indent: Int
    let contentOffset: Int
    let content: String

    init?(_ line: String) {
        var indent = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            indent += line[idx] == "\t" ? 4 - (indent % 4) : 1
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex else { return nil }
        let rest = line[idx...]
        var markerLen = 0
        var ordered = false
        var bullet: Character?
        var number: Int?
        if let f = rest.first, f == "-" || f == "*" || f == "+" {
            markerLen = 1
            bullet = f
        } else {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard (1...9).contains(digits.count) else { return nil }
            let after = rest.dropFirst(digits.count)
            guard let d = after.first, d == "." || d == ")" else { return nil }
            markerLen = digits.count + 1
            ordered = true
            number = Int(digits)
        }
        let afterMarker = rest.dropFirst(markerLen)
        if afterMarker.isEmpty {
            self.init(ordered: ordered, bullet: bullet, number: number, indent: indent, contentOffset: indent + markerLen + 1, content: "")
            return
        }
        guard afterMarker.first == " " || afterMarker.first == "\t" else { return nil }
        let spaces = afterMarker.prefix(while: { $0 == " " }).count
        let pad = (1...4).contains(spaces) ? spaces : 1
        let content = String(afterMarker.dropFirst(pad))
        self.init(ordered: ordered, bullet: bullet, number: number, indent: indent, contentOffset: indent + markerLen + pad, content: content)
    }

    init(ordered: Bool, bullet: Character?, number: Int?, indent: Int, contentOffset: Int, content: String) {
        self.ordered = ordered
        self.bullet = bullet
        self.number = number
        self.indent = indent
        self.contentOffset = contentOffset
        self.content = content
    }
}

final class DiagramCounter: @unchecked Sendable {
    var n = 0
}

/// The Mermaid diagrams in a Markdown text, in the order the renderer numbers them, to edit one in place.
public enum MermaidBlocks {
    public struct Block: Equatable, Sendable {
        /// Line range of the code inside the fence.
        public var lines: Range<Int>
        public var source: String
    }

    public static func find(in markdown: String) -> [Block] {
        let lines = markdown.components(separatedBy: "\n")
        var out: [Block] = []
        var i = 0
        while i < lines.count {
            guard let fence = Fence(lines[i]) else { i += 1; continue }
            let start = i + 1
            var j = start
            while j < lines.count, !fence.closes(lines[j]) { j += 1 }
            if fence.language.lowercased() == "mermaid" {
                out.append(Block(lines: start..<j, source: lines[start..<j].map(fence.strip).joined(separator: "\n")))
            }
            i = j + 1
        }
        return out
    }

    /// Replaces diagram `index`; past the last one, appends a new diagram at the end.
    public static func replacing(_ index: Int, with source: String, in markdown: String) -> String {
        let blocks = find(in: markdown)
        let code = source.trimmingCharacters(in: .newlines)
        guard blocks.indices.contains(index) else {
            var text = markdown
            while text.hasSuffix("\n\n") { text.removeLast() }
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            return text + (text.isEmpty ? "" : "\n") + "```mermaid\n\(code)\n```\n"
        }
        var lines = markdown.components(separatedBy: "\n")
        lines.replaceSubrange(blocks[index].lines, with: code.components(separatedBy: "\n"))
        return lines.joined(separator: "\n")
    }

    public static let templates: [(name: String, source: String)] = [
        ("Flowchart", "flowchart LR\n    App[Android app] --> BFF[BFF]\n    BFF --> Vault[(Vault)]"),
        ("Sequence", "sequenceDiagram\n    participant App\n    participant Device\n    App->>Device: Connect\n    Device-->>App: Ready"),
        ("Class", "classDiagram\n    class Repository {\n        +load()\n    }\n    Repository <|-- ReadingRepository"),
        ("State", "stateDiagram-v2\n    [*] --> Idle\n    Idle --> Connecting\n    Connecting --> Connected\n    Connected --> [*]"),
        ("Entities", "erDiagram\n    DEVICE ||--o{ READING : records\n    READING }o--|| PRODUCT : of"),
    ]
}
