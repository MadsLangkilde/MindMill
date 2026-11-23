import Foundation

public enum KBConfig {
    public static let defaultRootPath = "~/projects/knowledge"

    public static var defaultConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config")
            .appendingPathComponent("kb")
            .appendingPathComponent("config.json")
    }

    public static func expandTilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    public static func abbreviateTilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The configured root as written in the config file (may start with `~`), or the default.
    public static func loadRootPath(configURL: URL = defaultConfigURL) -> String {
        guard let data = try? Data(contentsOf: configURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let root = json["root"] as? String,
              !root.trimmingCharacters(in: .whitespaces).isEmpty
        else { return defaultRootPath }
        return root.trimmingCharacters(in: .whitespaces)
    }

    public static func rootURL(for path: String, home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: expandTilde(path, home: home)).standardizedFileURL
    }

    /// Writes `root`, keeping any other keys already in the file.
    public static func saveRootPath(_ path: String, configURL: URL = defaultConfigURL) throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json = existing
        }
        json["root"] = path
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: configURL, options: .atomic)
    }
}
