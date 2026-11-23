import Foundation

/// A follow-up's `resolved_by`: one or more links (work items, URLs, KB entries) and any words around them.
/// It may be a list, or one string with several links separated by commas or spaces.
public struct ResolvedBy: Equatable, Sendable {
    public enum Item: Equatable, Sendable, Hashable {
        case entry(EntryID)
        case workItem(number: String, url: URL)
        case url(URL)
    }

    public var items: [Item]
    /// What is left when the links are taken out, such as "Fixed in the 1.0.0 (57) build".
    public var text: String

    public init(values: [String]) {
        var items: [Item] = []
        var words: [String] = []
        for value in values {
            for token in value.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
                let t = token.trimmingCharacters(in: CharacterSet(charactersIn: ",;()<>`\"'"))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if let item = Self.item(t) {
                    if !items.contains(item) { items.append(item) }
                } else if !t.isEmpty {
                    words.append(String(token))
                }
            }
        }
        let filler: Set<String> = ["and", "og", ",", "&", "+", "/", "-"]
        let joined = words.filter { !filler.contains($0.lowercased()) }
            .joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        self.items = items
        self.text = items.isEmpty ? values.joined(separator: ", ") : joined
    }

    static func item(_ t: String) -> Item? {
        if let id = EntryID(t) { return .entry(id) }
        guard let url = URL(string: t), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        if let r = t.range(of: "_workitems/edit/") {
            let digits = t[r.upperBound...].prefix { $0.isNumber }
            if !digits.isEmpty { return .workItem(number: String(digits), url: url) }
        }
        return .url(url)
    }

    /// The text to copy for an item.
    public static func copyText(_ item: Item) -> String {
        switch item {
        case .entry(let id): return id.rawValue
        case .workItem(_, let url), .url(let url): return url.absoluteString
        }
    }
}
