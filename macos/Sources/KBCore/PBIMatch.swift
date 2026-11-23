import Foundation

/// Finds PBIs and bugs that may already cover something: by shared words in the title, and by work-item
/// numbers written in a text.
public enum PBIMatch {
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "that", "this", "when", "then", "than", "are", "was", "were",
        "will", "should", "can", "not", "but", "all", "any", "its", "our", "you", "your", "have", "has", "had",
        "how", "what", "who", "why", "where", "which", "about", "after", "before", "over", "under", "per", "via",
        "add", "make", "use", "new", "get", "set", "app", "android", "ios",
        "og", "der", "det", "den", "som", "til", "med", "for", "fra", "ikke", "skal", "kan", "vil", "har", "eller",
        "pbi", "bug", "task",
    ]

    /// Lowercased words of three or more letters, without common words and a plural `s`.
    public static func words(_ s: String) -> Set<String> {
        let parts = s.lowercased().split { !($0.isLetter || $0.isNumber) }
        var out = Set<String>()
        for p in parts where p.count >= 3 {
            var w = String(p)
            if stopWords.contains(w) || w.allSatisfy(\.isNumber) { continue }
            if w.count > 4, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }
            out.insert(w)
        }
        return out
    }

    /// How much two titles overlap, 0…1: shared words over the shorter title's words.
    public static func score(_ a: String, _ b: String) -> Double {
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        let shared = wa.intersection(wb).count
        guard shared >= 2 || (shared == 1 && min(wa.count, wb.count) == 1) else { return 0 }
        return Double(shared) / Double(min(wa.count, wb.count))
    }

    /// Work-item numbers in a text: `#417986`, or a 5–7 digit number after PBI, bug, task or work item, or a bare
    /// six-digit number. `explicit` is false for the bare ones, which callers check against known items.
    public static func mentionedWorkItems(_ text: String) -> [(number: Int, explicit: Bool)] {
        let pattern = #"(?i)(#|\b(?:pbi|bug|task|work item|workitem|wi)\s*#?\s*)?\b(\d{5,7})\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<Int>()
        var out: [(Int, Bool)] = []
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let digits = ns.substring(with: m.range(at: 2))
            let explicit = m.range(at: 1).location != NSNotFound
            guard explicit || digits.count == 6, let n = Int(digits) else { continue }
            if seen.insert(n).inserted { out.append((n, explicit)) }
        }
        return out
    }
}
