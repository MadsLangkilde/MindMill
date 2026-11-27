import Foundation

/// A message between sessions as shown in a transcript: `✉ <from>` and the text, made easier to read.
public enum CrewMessage {
    /// The sender and the text of a `✉` line, or of a `[From …]` message as a resumed conversation has it; `nil` for
    /// anything else, and for the user's own words passed on through a lead (`[From you, …]`).
    public static func split(_ display: String) -> (from: String, text: String)? {
        if display.hasPrefix("[From "), let close = display.firstIndex(of: "]") {
            let from = String(display[display.index(display.startIndex, offsetBy: 6)..<close])
            guard !from.isEmpty, !from.lowercased().hasPrefix("you") else { return nil }
            let text = display[display.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return (from, text)
        }
        guard display.hasPrefix("✉ ") else { return nil }
        let rest = String(display.dropFirst(2))
        if let nl = rest.firstIndex(of: "\n") {
            return (String(rest[..<nl]), String(rest[rest.index(after: nl)...]))
        }
        // Older lines: "✉ <from>: <text>", where a lead's name ends in "(lead)".
        if let r = rest.range(of: "(lead): ") {
            return (String(rest[..<r.lowerBound]) + "(lead)", String(rest[r.upperBound...]))
        }
        if let r = rest.range(of: ": ") { return (String(rest[..<r.lowerBound]), String(rest[r.upperBound...])) }
        return (rest, "")
    }

    /// Who sent it, for the message's header: "Overview", "Mindmill", "Session “Login” (lead)".
    public static func sender(_ from: String) -> String {
        switch from {
        case "the overview session": return "Overview"
        case "the Mindmill app": return "Mindmill"
        case "the command line": return "The command line"
        default:
            if from.hasSuffix(" (lead)") { return "Session “\(from.dropLast(7))” (lead)" }
            if from.hasPrefix("the ") { return from.prefix(1).uppercased() + from.dropFirst() }
            return "Session “\(from)”"
        }
    }

    /// The start of the message on one line, without Markdown, for the collapsed header.
    public static func preview(_ text: String, limit: Int = 140) -> String {
        var t = text.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.count > limit ? String(t.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : t
    }

    /// Inline option lists ("Options: (1) … (2) …") become numbered lines, and a leading label such as
    /// "Context:" or "RECOMMENDED:" turns bold. Text that already has line structure is left alone.
    public static func readable(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        var out = text
        // Numbered options, only when they run 1, 2, … in order.
        var n = 1
        var positions: [Range<String.Index>] = []
        var search = out.startIndex
        while let r = out.range(of: "(\(n)) ", range: search..<out.endIndex) {
            positions.append(r)
            search = r.upperBound
            n += 1
        }
        if positions.count >= 2 {
            for (i, r) in positions.enumerated().reversed() {
                out.replaceSubrange(r, with: "\n\(i + 1). ")
            }
        }
        let labels = ["Context:", "Options:", "Option:", "RECOMMENDED:", "Recommended:", "Status:", "Done:", "Next:",
                      "Blocked:", "Question:", "Questions:", "Decision:", "Result:", "Results:", "Summary:", "Why:"]
        for label in labels {
            out = out.replacingOccurrences(of: label, with: "**\(label)**")
        }
        while out.contains(" \n") { out = out.replacingOccurrences(of: " \n", with: "\n") }
        return out
    }
}

/// Links in a meeting's prep worth opening for Claude: documents, not join or calendar links.
public enum PrepLinks {
    static let skipHosts = ["teams.microsoft.com", "teams.live.com", "outlook.office365.com", "outlook.office.com", "zoom.us", "meet.google.com"]

    public static func find(_ text: String) -> [URL] {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s<>()\[\]"'`]+"#) else { return [] }
        let ns = text as NSString
        var out: [URL] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var raw = ns.substring(with: m.range)
            while let last = raw.last, ".,;:!?*_".contains(last) { raw.removeLast() }
            guard let url = URL(string: raw), let host = url.host?.lowercased(),
                  !skipHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  !out.contains(url) else { continue }
            out.append(url)
        }
        return out
    }

    /// "Claude artifact", or the host and the last part of the path.
    public static func label(_ url: URL) -> String {
        let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        if host == "claude.ai" { return url.path.contains("artifact") ? "Claude artifact" : "claude.ai" }
        let last = url.pathComponents.last(where: { $0 != "/" }) ?? ""
        let tail = last.count > 24 ? String(last.prefix(22)) + "…" : last
        return tail.isEmpty ? host : "\(host)/\(tail)"
    }
}
