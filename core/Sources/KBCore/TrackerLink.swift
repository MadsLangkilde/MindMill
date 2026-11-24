import Foundation

/// The tracker a scope's work lives in, by name, and where its items open in a browser.
public enum TrackerLink {
    /// The tracker's name as the user knows it ("Azure DevOps", "Jira", "Mindmill" for its own tracker).
    public static func name(_ kind: String) -> String {
        switch kind {
        case "local": return "Mindmill"
        case "jira": return "Jira"
        case "github": return "GitHub"
        case "linear": return "Linear"
        default: return "Azure DevOps"
        }
    }

    /// The tracker a work item's link points into, by its host.
    public static func name(forURL url: String) -> String {
        let host = URL(string: url)?.host?.lowercased() ?? ""
        if host.contains("atlassian") || url.contains("/browse/") { return "Jira" }
        if host.contains("github") { return "GitHub" }
        if host.contains("linear.app") { return "Linear" }
        return "Azure DevOps"
    }

    /// The item's page in the tracker, or nil when it has none (Mindmill's own tracker) or the settings are missing.
    /// `item` is a number, or a Jira key such as `APP-12` (a bare number gets the project key in front).
    public static func url(kind: String, organization: String, project: String, item: String) -> URL? {
        let org = organization.trimmingCharacters(in: .whitespaces)
        let proj = project.trimmingCharacters(in: .whitespaces)
        let id = item.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard !id.isEmpty, !org.isEmpty else { return nil }
        let host = org.hasPrefix("http") ? String(org.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) : nil
        switch kind {
        case "azure-devops":
            guard !proj.isEmpty, Int(id) != nil else { return nil }
            let path = proj.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proj
            return URL(string: "\(host ?? "https://dev.azure.com/\(org)")/\(path)/_workitems/edit/\(id)")
        case "jira":
            let key = Int(id) != nil ? (proj.isEmpty ? nil : "\(proj)-\(id)") : id
            guard let key else { return nil }
            return URL(string: "\(host ?? "https://\(org)")/browse/\(key)")
        case "github":
            guard !proj.isEmpty, Int(id) != nil else { return nil }
            return URL(string: "https://github.com/\(org)/\(proj)/issues/\(id)")
        default:
            return nil
        }
    }

    /// The work item a session is about: `wi:<n>` from starting work on an item, or a backlog entry's `work_item`.
    public static func workItem(about: String?, entryWorkItem: (EntryID) -> String?) -> String? {
        guard let about else { return nil }
        if about.hasPrefix("wi:") { return String(about.dropFirst(3)) }
        if let id = EntryID(about), id.section == .backlog { return entryWorkItem(id) }
        return nil
    }
}
