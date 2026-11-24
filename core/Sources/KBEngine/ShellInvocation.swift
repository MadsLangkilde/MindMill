import Foundation
import KBCore

/// How to run one shell command line. macOS: `/bin/zsh -c`. Windows: Git for Windows' bash, which Claude Code needs
/// anyway (it honours the same `CLAUDE_CODE_GIT_BASH_PATH`), so commands written for a POSIX shell work unchanged;
/// `cmd.exe /d /c` only when there is no Git Bash.
public struct ShellInvocation: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public static func current(_ command: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> ShellInvocation {
        #if os(Windows)
        return windows(command, environment: environment, exists: { FileManager.default.fileExists(atPath: $0) })
        #else
        return ShellInvocation(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-c", command])
        #endif
    }

    public static func windows(_ command: String, environment: [String: String], exists: (String) -> Bool) -> ShellInvocation {
        if let bash = gitBash(environment: environment, exists: exists) {
            return ShellInvocation(executable: URL(fileURLWithPath: bash), arguments: ["-c", command])
        }
        let root = value("SystemRoot", environment) ?? #"C:\Windows"#
        return ShellInvocation(executable: URL(fileURLWithPath: root + #"\System32\cmd.exe"#), arguments: ["/d", "/c", command])
    }

    public static func gitBash(environment: [String: String], exists: (String) -> Bool) -> String? {
        var candidates: [String] = []
        if let set = value("CLAUDE_CODE_GIT_BASH_PATH", environment) { candidates.append(set) }
        for name in ["ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"] {
            if let base = value(name, environment) { candidates.append(base + #"\Git\bin\bash.exe"#) }
        }
        if let local = value("LOCALAPPDATA", environment) { candidates.append(local + #"\Programs\Git\bin\bash.exe"#) }
        if let onPath = WindowsTools.onPath("bash", environment: environment, exists: exists),
           !onPath.lowercased().contains(#"\system32\"#) {
            candidates.append(onPath)
        }
        return candidates.first(where: exists)
    }

    private static func value(_ name: String, _ environment: [String: String]) -> String? {
        environment.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }.map(\.value).flatMap { $0.isEmpty ? nil : $0 }
    }
}
