import Foundation

/// A work item `kb tracker find` matched, offered as a parent or related item.
public struct FoundWorkItem: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var type: String
    public var title: String
    public var state: String
    public var url: String

    public init(id: Int, type: String, title: String, state: String, url: String = "") {
        self.id = id
        self.type = type
        self.title = title
        self.state = state
        self.url = url
    }

    public static func decode(_ json: String) throws -> [FoundWorkItem] {
        struct Out: Decodable { var items: [FoundWorkItem] }
        return try JSONDecoder().decode(Out.self, from: Data(json.utf8)).items
    }

    /// "pbi" / "Product Backlog Item" → "PBI", "bug" → "Bug", "feature" → "Feature".
    public var typeTitle: String {
        switch type.lowercased() {
        case "pbi", "product backlog item": return "PBI"
        case "user story", "story": return "Story"
        default: return type.prefix(1).uppercased() + type.dropFirst()
        }
    }
}
