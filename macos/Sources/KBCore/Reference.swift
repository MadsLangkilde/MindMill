import Foundation

/// What a saved reference is a copy of.
public enum ReferenceKind: String, CaseIterable, Sendable {
    case artifact, email, teams, web, document, file, note

    public var title: String {
        switch self {
        case .artifact: return "Claude artifact"
        case .email: return "Email"
        case .teams: return "Teams chat"
        case .web: return "Web page"
        case .document: return "Document"
        case .file: return "File"
        case .note: return "Note"
        }
    }

    public var icon: String {
        switch self {
        case .artifact: return "sparkles.rectangle.stack"
        case .email: return "envelope"
        case .teams: return "bubble.left.and.text.bubble.right"
        case .web: return "globe"
        case .document: return "doc.richtext"
        case .file: return "doc"
        case .note: return "note.text"
        }
    }

    /// A page saved from the browser: an artifact, a document in SharePoint or OneDrive, mail on the web, or a page.
    public static func guess(_ url: URL) -> ReferenceKind {
        let host = (url.host ?? "").lowercased()
        if host == "claude.ai" || host.hasSuffix(".claude.ai") || host.hasSuffix("claude.site") || host.hasSuffix("claudeusercontent.com") {
            return .artifact
        }
        if host.hasPrefix("outlook.") { return .email }
        if host.contains("teams.microsoft") || host.contains("teams.cloud.microsoft") { return .teams }
        if host.hasSuffix("sharepoint.com") || host.contains("onedrive") || host == "docs.google.com"
            || ["pdf", "docx", "pptx", "xlsx"].contains(url.pathExtension.lowercased()) {
            return .document
        }
        return .web
    }
}

extension KBEntry {
    public var referenceKind: ReferenceKind { field("kind").flatMap(ReferenceKind.init(rawValue:)) ?? .web }
    public var referenceURL: URL? { field("url").flatMap(URL.init(string:)) }
}

/// The body of a reference: why it matters, and the copy.
public enum ReferenceBody {
    public static func make(note: String, content: String) -> String {
        "## Why it matters\n\(note.trimmingCharacters(in: .whitespacesAndNewlines))\n\n## Content\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// The same body with a new copy under `## Content`; the note above stays.
    public static func replacingContent(_ body: String, with content: String) -> String {
        let marker = "## Content"
        guard let range = body.range(of: "\n" + marker + "\n") ?? (body.hasPrefix(marker + "\n") ? body.range(of: marker + "\n") : nil) else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n\(marker)\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        return String(body[..<range.upperBound]) + content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public static func content(_ body: String) -> String {
        guard let r = body.range(of: "## Content\n") else { return "" }
        return String(body[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
