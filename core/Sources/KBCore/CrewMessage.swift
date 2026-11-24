import Foundation

/// A message between sessions as shown in a transcript: `✉ <from>` and the text, made easier to read.
public enum CrewMessage {
    /// The sender and the text of a `✉` line; `nil` for anything else.
    public static func split(_ display: String) -> (from: String, text: String)? {
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
