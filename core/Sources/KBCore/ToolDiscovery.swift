import Foundation

/// Finding `claude` and Python on Windows, where GUI apps get the user's PATH directly (no login shell to ask).
/// The search is pure so it is tested on any platform; `resolve` runs it against the real file system.
///
/// Claude Code's native installer puts `claude.exe` in `%USERPROFILE%\.local\bin`. An npm install leaves only a
/// `claude.cmd` shim, which can't be started without `cmd.exe` quoting the long prompts; it is not used.
/// Python: a real `python.exe` on PATH (not the Microsoft Store's `WindowsApps` stub, which opens the Store), else
/// the `py` launcher with `-3`, else the python.org per-user installs under `%LOCALAPPDATA%\Programs\Python`.
public enum WindowsTools {
    public struct Python: Equatable, Sendable {
        public var path: String
        public var arguments: [String]
    }

    public static func resolve(environment: [String: String],
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                               listDirectory: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] })
        -> LoginShell.Resolved {
        let found = claude(environment: environment, exists: exists)
        let claudeURL = LoginShell.newestClaude(preferring: found.map { URL(fileURLWithPath: $0) })
        let py = python(environment: environment, exists: exists, listDirectory: listDirectory)
        return LoginShell.Resolved(environment: environment, claude: claudeURL, python3: py.map { URL(fileURLWithPath: $0.path) },
                                   python3Arguments: py?.arguments ?? [])
    }

    /// PATH's folders, in order; Windows calls the variable `Path`, and environment names aren't case-sensitive.
    public static func pathFolders(_ environment: [String: String]) -> [String] {
        let value = environment.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
        return value.split(separator: ";").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }.filter { !$0.isEmpty }
    }

    static func value(_ name: String, _ environment: [String: String]) -> String? {
        environment.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value.nilIfEmpty
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("\\") || folder.hasSuffix("/") ? folder + name : folder + "\\" + name
    }

    /// The first `name.exe` on PATH, like `where.exe` would list it first.
    public static func onPath(_ name: String, environment: [String: String], exists: (String) -> Bool) -> String? {
        pathFolders(environment).map { join($0, name + ".exe") }.first(where: exists)
    }

    /// Where Claude Code's installers put `claude.exe`, beyond PATH.
    public static func knownClaudes(environment: [String: String]) -> [String] {
        var out: [String] = []
        if let home = value("USERPROFILE", environment) {
            out.append(join(home, ".local\\bin\\claude.exe"))
            out.append(join(home, ".claude\\local\\claude.exe"))
        }
        if let local = value("LOCALAPPDATA", environment) {
            out.append(join(local, "Programs\\claude\\claude.exe"))
            out.append(join(local, "AnthropicClaude\\claude.exe"))
        }
        return out
    }

    public static func claude(environment: [String: String], exists: (String) -> Bool) -> String? {
        onPath("claude", environment: environment, exists: exists) ?? knownClaudes(environment: environment).first(where: exists)
    }

    public static func python(environment: [String: String], exists: (String) -> Bool,
                              listDirectory: (String) -> [String]) -> Python? {
        for folder in pathFolders(environment) where !folder.lowercased().contains("\\microsoft\\windowsapps") {
            for name in ["python3.exe", "python.exe"] {
                let p = join(folder, name)
                if exists(p) { return Python(path: p, arguments: []) }
            }
        }
        var launchers: [String] = []
        if let py = onPath("py", environment: environment, exists: exists) { launchers.append(py) }
        if let windir = value("SystemRoot", environment) ?? value("windir", environment) { launchers.append(join(windir, "py.exe")) }
        if let local = value("LOCALAPPDATA", environment) { launchers.append(join(local, "Programs\\Python\\Launcher\\py.exe")) }
        if let py = launchers.first(where: exists) { return Python(path: py, arguments: ["-3"]) }
        if let local = value("LOCALAPPDATA", environment) {
            let base = join(local, "Programs\\Python")
            let versions = listDirectory(base).filter { $0.lowercased().hasPrefix("python3") }
                .sorted { (Int($0.dropFirst(7)) ?? 0) > (Int($1.dropFirst(7)) ?? 0) }
            if let p = versions.map({ join(join(base, $0), "python.exe") }).first(where: exists) { return Python(path: p, arguments: []) }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
