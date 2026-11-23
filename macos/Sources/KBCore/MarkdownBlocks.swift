import Foundation

/// Block structure of a Claude reply, for rendering it as a document rather than one run of text.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `ordered` lists keep their numbers; `checked` is nil for a plain bullet.
    case listItem(indent: Int, marker: String, checked: Bool?, text: String)
    case code(language: String, text: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
    /// A ```choices block: options the user can click to answer.
    case choices(multi: Bool, options: [String])
    /// A ```strategy block: strategy slugs to pick from, the recommended one marked `(Recommended)`.
    case strategies(options: [String])
    /// A ```capture block: links Claude can't open, for the user to open in the app and share.
    case capture(urls: [String])
}

public enum MarkdownBlocks {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0

        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flush()
                let info = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                i += 1
                let words = info.lowercased().split(separator: " ")
                if words.first == "capture" {
                    let urls = body.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("http") }
                    if !urls.isEmpty { blocks.append(.capture(urls: urls)) }
                } else if words.first == "strategy" || words.first == "strategies" {
                    let options = body.map(cleanOption).filter { !$0.isEmpty }
                    if !options.isEmpty { blocks.append(.strategies(options: options)) }
                } else if words.first == "choices" {
                    let options = body.map(cleanOption).filter { !$0.isEmpty }
                    if !options.isEmpty { blocks.append(.choices(multi: words.contains("multi"), options: options)) }
                } else {
                    blocks.append(.code(language: info, text: body.joined(separator: "\n")))
                }
                continue
            }
            if t.isEmpty {
                flush()
                i += 1
                continue
            }
            if let h = heading(t) {
                flush()
                blocks.append(h)
                i += 1
                continue
            }
            if t == "---" || t == "***" || t == "___" {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }
            if t.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let header = cells(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if t.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if let item = listItem(line) {
                flush()
                blocks.append(item)
                i += 1
                // Lazy continuation lines belong to the item.
                while i < lines.count {
                    let next = lines[i]
                    let nt = next.trimmingCharacters(in: .whitespaces)
                    guard !nt.isEmpty, listItem(next) == nil, heading(nt) == nil, !nt.hasPrefix("```"),
                          next.hasPrefix("  ") || next.hasPrefix("\t") else { break }
                    if case .listItem(let indent, let marker, let checked, let text) = blocks.removeLast() {
                        blocks.append(.listItem(indent: indent, marker: marker, checked: checked, text: text + " " + nt))
                    }
                    i += 1
                }
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    /// The options of the last choices block, if the reply ends by asking.
    public static func trailingChoices(_ markdown: String) -> (multi: Bool, options: [String])? {
        for block in parse(markdown).reversed() {
            if case .choices(let multi, let options) = block { return (multi, options) }
            if case .strategies(let options) = block { return (false, options) }
            if case .paragraph = block { continue }
            return nil
        }
        return nil
    }

    static func heading(_ t: String) -> MarkdownBlock? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), t.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: t.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    static func listItem(_ line: String) -> MarkdownBlock? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let t = line.dropFirst(leading.count)
        var marker: String
        var rest: Substring
        if let first = t.first, "-*+".contains(first), t.dropFirst().first == " " {
            marker = "•"
            rest = t.dropFirst(2)
        } else {
            let digits = t.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count < 4 else { return nil }
            let after = t.dropFirst(digits.count)
            guard let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " else { return nil }
            marker = "\(digits)."
            rest = after.dropFirst(2)
        }
        var checked: Bool?
        if rest.hasPrefix("[ ] ") { checked = false; rest = rest.dropFirst(4) }
        else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { checked = true; rest = rest.dropFirst(4) }
        if checked != nil, marker == "•" { marker = "" }
        return .listItem(indent: indent, marker: marker, checked: checked, text: rest.trimmingCharacters(in: .whitespaces))
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ row: String) -> [String] {
        var t = row
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func cleanOption(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- [ ] ", "- ", "* ", "• "] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
            break
        }
        if let d = t.firstIndex(where: { !$0.isNumber }), d != t.startIndex, t[d] == "." || t[d] == ")" {
            t = t[t.index(after: d)...].trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}

extension MarkdownBlocks {
    /// The end of a reply, whole paragraphs only, about `limit` characters long: where a waiting session's question
    /// and its choices are. `cut` is whether anything before it was left out.
    public static func tail(_ markdown: String, limit: Int = 700) -> (text: String, cut: Bool) {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return (text, false) }
        let paragraphs = text.components(separatedBy: "\n\n")
        var kept: [String] = []
        var size = 0
        for p in paragraphs.reversed() {
            if !kept.isEmpty, size + p.count > limit { break }
            kept.insert(p, at: 0)
            size += p.count + 2
        }
        return (kept.joined(separator: "\n\n"), kept.count < paragraphs.count)
    }
}
