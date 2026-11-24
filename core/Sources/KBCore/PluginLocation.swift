import Foundation

/// Where Mindmill's plugin (scripts/kb.py, the skills and hooks) is: a folder the user chose, else the copy inside Mindmill.app,
/// else a checkout of the repo at the usual place. A fresh Mac needs nothing but the app.
public enum PluginLocation {
    public static let developmentPath = "~/projects/claude_plugins/kb"

    public enum Source: Equatable, Sendable {
        case chosen, bundled, development, missing
    }

    public static func hasScripts(_ path: String, exists: (String) -> Bool = FileManager.default.fileExists) -> Bool {
        exists(KBConfig.expandTilde(path) + "/scripts/kb.py")
    }

    /// `chosen` is the path from Settings, if any; `bundled` the plugin folder in the app's resources.
    public static func resolve(chosen: String?, bundled: String?, exists: (String) -> Bool = FileManager.default.fileExists)
        -> (path: String, source: Source) {
        if let chosen, !chosen.trimmingCharacters(in: .whitespaces).isEmpty, hasScripts(chosen, exists: exists) {
            return (chosen, .chosen)
        }
        if let bundled, hasScripts(bundled, exists: exists) { return (bundled, .bundled) }
        if hasScripts(developmentPath, exists: exists) { return (developmentPath, .development) }
        return (chosen.flatMap { $0.isEmpty ? nil : $0 } ?? bundled ?? developmentPath, .missing)
    }
}
