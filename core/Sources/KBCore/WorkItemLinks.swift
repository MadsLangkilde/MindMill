import Foundation

/// The parent and related work items a backlog proposal names, read the same way `kb backlog create` reads them.
public enum WorkItemLinks {
    /// What every prompt that writes backlog proposals tells Claude about the parent and related fields.
    public static let proposalRule = "Links: when the source (the notes, the user's words, a work item) names a parent feature, epic or PBI, by a link such as `…/_workitems/edit/431006`, as `#431006` or as \"Feature 431006\", set `--field parent=<number>` on the backlog entry (not only in its text, and never `parent=none` then). Proposals written together for the same work (one per platform, or parts of one change) name each other: give each `--field related=\"[<the others' backlog entry ids, or work item numbers for items that exist>]\"`, adding the later ones' ids to the earlier ones with `kb backlog link <entry> --related <id> --yes`. `kb backlog create` turns them into Related links in the tracker."
    static let refPattern = #"_workitems/edit/(\d+)|#\s?(\d{3,})\b|\b(?:feature|epic|pbi|bug|product backlog item|user story|work item)\s+#?(\d{4,})\b"#
    static let cuePattern = #"\bparent\b|\bunder\s+(?:the\s+)?(?:feature|epic)\b|\b(?:feature|epic)\b(?=[^\n:]{0,12}:\s*\S*_workitems/edit/\d)"#
    static let nearPattern = #"_workitems/edit/(\d+)|#\s?(\d+)\b|\b(?:feature|epic|pbi|product backlog item|user story)\s+#?(\d+)\b|^\s*(?:is\s+|:\s*)?(\d{3,})\b"#
    static let weakPattern = #"\b(?:feature|epic)\s+#?(\d{4,})\b"#
    static let timestampedPattern = #"^\s*[-*]\s*\d{1,2}:\d{2}\b"#

    private static func regex(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    private static let ref = regex(refPattern)
    private static let cue = regex(cuePattern)
    private static let near = regex(nearPattern)
    private static let weak = regex(weakPattern)
    private static let timestamped = regex(timestampedPattern)
    private static let sentenceEnd = regex(#"[.;]\s"#)

    private static func firstNumber(_ m: NSTextCheckingResult, in ns: NSString) -> Int? {
        for i in 1..<m.numberOfRanges where m.range(at: i).location != NSNotFound {
            return Int(ns.substring(with: m.range(at: i)))
        }
        return nil
    }

    private static func unique(_ xs: [Int]) -> [Int] {
        var seen = Set<Int>()
        return xs.filter { seen.insert($0).inserted }
    }

    /// Work item numbers a text names: Azure DevOps links, `#431006`, or "Feature 431006".
    public static func refs(in text: String) -> [Int] {
        let ns = text as NSString
        return unique(ref.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { firstNumber($0, in: ns) })
    }

    /// Work items a text names as the parent: "Parent: Feature #431006", "under Feature #431006", "Feature here: <link>".
    /// Without `strongOnly` a plain "Feature 431006" counts too. Timestamped lines (transcript, screen text) are skipped.
    public static func parentMentions(in text: String, strongOnly: Bool = false) -> [Int] {
        var out: [Int] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            let all = NSRange(location: 0, length: ns.length)
            if timestamped.firstMatch(in: line, range: all) != nil { continue }
            for m in cue.matches(in: line, range: all) {
                let start = m.range.location + m.range.length
                var window = ns.substring(with: NSRange(location: start, length: min(160, ns.length - start))) as NSString
                if let end = sentenceEnd.firstMatch(in: window as String, range: NSRange(location: 0, length: window.length)) {
                    window = window.substring(to: end.range.location) as NSString
                }
                if let hit = near.firstMatch(in: window as String, range: NSRange(location: 0, length: window.length)),
                   let n = firstNumber(hit, in: window) {
                    out.append(n)
                }
            }
            if !strongOnly {
                out += weak.matches(in: line, range: all).compactMap { firstNumber($0, in: ns) }
            }
        }
        return unique(out)
    }

    /// The one parent the entry's text names, else the one its sources clearly name. Several candidates: none.
    public static func inferredParent(body: String, ownWorkItem: String? = nil,
                                      sources: [(title: String, body: String)] = []) -> (number: Int, from: String)? {
        let own = Int(ownWorkItem ?? "")
        let found = parentMentions(in: body).filter { $0 != own }
        if found.count == 1 { return (found[0], "the text") }
        if !found.isEmpty { return nil }
        var hits: [(Int, String)] = []
        for s in sources {
            for n in parentMentions(in: s.body, strongOnly: true) where n != own && !hits.contains(where: { $0.0 == n }) {
                hits.append((n, s.title))
            }
        }
        return hits.count == 1 ? (hits[0].0, "“\(hits[0].1)”") : nil
    }

    /// A `parent` field's number; `none` or empty is no parent.
    public static func parentNumber(_ field: String?) -> Int? {
        let v = (field ?? "").trimmingCharacters(in: .whitespaces)
        guard v.lowercased() != "none", let r = v.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(v[r])
    }

    /// `related` (or `not_duplicate_of`) as work item numbers and entry ids, without `#`.
    public static func relatedValues(_ values: [String]) -> [String] {
        var out: [String] = []
        for v in values {
            let s = v.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, s.lowercased() != "none", !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// What a related value reads as: `#431549` for a number, else the entry's title when known.
    public static func label(_ value: String, title: (String) -> String?) -> String {
        Int(value) != nil ? "#\(value)" : (title(value) ?? value)
    }
}
