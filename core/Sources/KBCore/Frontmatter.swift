import Foundation

public enum FrontmatterValue: Hashable, Sendable {
    case string(String)
    case list([String])

    public var stringValue: String {
        switch self {
        case .string(let s): return s
        case .list(let items): return items.joined(separator: ", ")
        }
    }

    public var listValue: [String] {
        switch self {
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? [] : [t]
        case .list(let items): return items
        }
    }
}

/// Flat YAML frontmatter that keeps the original line order, unknown keys and
/// the original spelling of every value it was not asked to change.
public struct Frontmatter: Hashable, Sendable {
    public enum Line: Hashable, Sendable {
        /// `raw` is the original line, written back verbatim while the value is unchanged.
        case field(key: String, value: FrontmatterValue, raw: String?)
        case other(String)
    }

    public var lines: [Line]

    public init(lines: [Line] = []) {
        self.lines = lines
    }

    public var keys: [String] {
        lines.compactMap { if case .field(let k, _, _) = $0 { return k } else { return nil } }
    }

    public subscript(key: String) -> FrontmatterValue? {
        for line in lines {
            if case .field(let k, let v, _) = line, k == key { return v }
        }
        return nil
    }

    public func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    public func list(_ key: String) -> [String] {
        self[key]?.listValue ?? []
    }

    /// Sets a value in place, keeping its position. A new key is appended. `nil` removes the key.
    /// Setting a value equal to the current one keeps the original spelling.
    public mutating func set(_ key: String, _ value: FrontmatterValue?) {
        if let idx = lines.firstIndex(where: { if case .field(let k, _, _) = $0 { return k == key } else { return false } }) {
            guard let value else {
                lines.remove(at: idx)
                return
            }
            if case .field(_, let old, _) = lines[idx], old == value { return }
            lines[idx] = .field(key: key, value: value, raw: nil)
        } else if let value {
            lines.append(.field(key: key, value: value, raw: nil))
        }
    }

    /// Like `set`, but an empty string for a key that is not present is a no-op,
    /// so focusing and leaving an empty field never dirties a document.
    public mutating func setString(_ key: String, _ value: String) {
        if self[key] == nil && value.isEmpty { return }
        set(key, .string(value))
    }

    public mutating func setList(_ key: String, _ value: [String]) {
        if self[key] == nil && value.isEmpty { return }
        if case .string(let s)? = self[key], value == FrontmatterValue.string(s).listValue { return }
        set(key, .list(value))
    }
}

public enum FrontmatterCodec {
    public struct Parsed: Equatable, Sendable {
        public var frontmatter: Frontmatter
        public var body: String
        public var hasFrontmatter: Bool
    }

    public static func parse(_ rawText: String) -> Parsed {
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix("---\n") || text == "---" else {
            return Parsed(frontmatter: Frontmatter(), body: text, hasFrontmatter: false)
        }
        var rest = text.dropFirst(4)
        var lines: [Frontmatter.Line] = []
        while true {
            let lineEnd = rest.firstIndex(of: "\n")
            let line = String(rest[rest.startIndex..<(lineEnd ?? rest.endIndex)])
            let after = lineEnd.map { rest[rest.index(after: $0)...] } ?? rest[rest.endIndex...]
            if line == "---" || line == "..." {
                return Parsed(frontmatter: Frontmatter(lines: lines), body: String(after), hasFrontmatter: true)
            }
            if lineEnd == nil {
                // No closing fence: treat the whole file as body.
                return Parsed(frontmatter: Frontmatter(), body: text, hasFrontmatter: false)
            }
            lines.append(parseLine(line))
            rest = after
        }
    }

    static func parseLine(_ line: String) -> Frontmatter.Line {
        guard let colon = line.firstIndex(of: ":") else { return .other(line) }
        let key = String(line[..<colon])
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
              key.first?.isLetter == true || key.first == "_" else { return .other(line) }
        let afterColon = line[line.index(after: colon)...]
        if let first = afterColon.first, first != " " && first != "\t" { return .other(line) }
        let raw = afterColon.trimmingCharacters(in: .whitespaces)
        return .field(key: key, value: parseValue(raw), raw: line)
    }

    public static func parseValue(_ raw: String) -> FrontmatterValue {
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast())
            return .list(splitList(inner).map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty })
        }
        return .string(unquote(raw))
    }

    static func splitList(_ s: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if let q = quote {
                if ch == "\\" && q == "\"" { current.append(ch); escaped = true; continue }
                if ch == q { quote = nil }
                current.append(ch)
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; current.append(ch); continue }
            if ch == "," { items.append(current); current = ""; continue }
            current.append(ch)
        }
        items.append(current)
        return items
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            var out = ""
            var escaped = false
            for ch in s.dropFirst().dropLast() {
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else {
                    out.append(ch)
                }
            }
            return out
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    public static func serialize(_ fm: Frontmatter, body: String, forceFrontmatter: Bool = false) -> String {
        if fm.lines.isEmpty && !forceFrontmatter { return body }
        var out = "---\n"
        for line in fm.lines {
            switch line {
            case .other(let s):
                out += s + "\n"
            case .field(let key, let value, let raw):
                if let raw {
                    out += raw + "\n"
                } else {
                    let rendered = format(value)
                    out += rendered.isEmpty ? "\(key):\n" : "\(key): \(rendered)\n"
                }
            }
        }
        out += "---\n"
        return out + body
    }

    public static func format(_ value: FrontmatterValue) -> String {
        switch value {
        case .string(let s):
            return formatScalar(s)
        case .list(let items):
            return "[" + items.map(formatListItem).joined(separator: ", ") + "]"
        }
    }

    static func formatScalar(_ s: String) -> String {
        if s.isEmpty { return "" }
        let special: Set<Character> = ["[", "]", "{", "}", "\"", "'", "#", "&", "*", "!", "|", ">", "%", "@", "`", ",", "?"]
        var needsQuote = special.contains(s.first!)
        needsQuote = needsQuote || s.hasPrefix("- ") || s == "-"
        needsQuote = needsQuote || s.contains(": ") || s.hasSuffix(":") || s.contains(" #")
        needsQuote = needsQuote || s.first!.isWhitespace || s.last!.isWhitespace || s.contains("\n")
        needsQuote = needsQuote || s.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
        return needsQuote ? doubleQuoted(s) : s
    }

    static func formatListItem(_ s: String) -> String {
        let special: Set<Character> = [",", "[", "]", "\"", "'", "{", "}", "#"]
        if s.isEmpty || s.contains(where: { special.contains($0) }) || s.contains(": ")
            || s.first!.isWhitespace || s.last!.isWhitespace {
            return doubleQuoted(s)
        }
        return s
    }

    static func doubleQuoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
