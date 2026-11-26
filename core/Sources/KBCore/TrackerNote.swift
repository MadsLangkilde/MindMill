import Foundation

/// A comment on a work item through `kb tracker note`: Azure DevOps posts it as a comment; Mindmill's own tracker has
/// no comments, so it goes at the end of the description under a heading.
public enum TrackerNote {
    public static func args(_ id: String, _ text: String, scopeArgs: [String], local: Bool) -> [String] {
        ["tracker", "note", id, "--text", text] + scopeArgs + (local ? ["--heading", "Comment"] : ["--comment"])
    }
}
