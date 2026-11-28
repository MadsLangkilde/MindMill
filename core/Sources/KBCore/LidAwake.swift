import Foundation

/// Keeping a Mac reachable from the phone with its lid closed. macOS sleeps on lid close whatever an app asserts, and
/// only an administrator can turn that off (`pmset disablesleep`), so a small helper runs as a launchd daemon: every
/// few seconds it turns sleep off while the Mac is plugged in, Mindmill is open and the user's switch is on (`flag`
/// exists), and back on otherwise, putting a closed Mac to sleep then as closing the lid would have.
public enum LidAwake {
    public static let label = "dk.langkilde.kb.stayawake"
    /// Bumped when the script changes, so the app offers to update an installed one.
    public static let version = 1
    public static let scriptPath = "/Library/PrivilegedHelperTools/\(label).sh"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    /// Exists while the helper has sleep turned off, so it only turns back on what it turned off itself.
    public static let markPath = "/Library/Application Support/\(label)/active"
    static let interval = 10

    /// The switch, as a file the helper can see: there while Mindmill wants the Mac kept awake.
    public static func flagURL(data: URL = AppPaths.data) -> URL { data.appendingPathComponent("stay-awake") }

    /// `text` as one argument for `/bin/sh`.
    public static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// `text` as an AppleScript string literal.
    public static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func script(flag: String) -> String {
        """
        #!/bin/sh
        # Mindmill's lid helper: keeps this Mac awake with the lid closed while it is plugged in, Mindmill is open and
        # Settings → Remote → Stay reachable with the lid closed is on. Otherwise the Mac sleeps as usual.
        # Version: \(version)
        flag=\(shellQuoted(flag))
        mark=\(shellQuoted(markPath))
        want=0
        if [ -f "$flag" ] && /usr/bin/pgrep -xq Mindmill && /usr/bin/pmset -g ps | /usr/bin/head -n 1 | /usr/bin/grep -q "AC Power"; then
            want=1
        fi
        if [ "$want" = 1 ]; then
            if [ ! -f "$mark" ]; then
                /usr/bin/pmset -a disablesleep 1 && /usr/bin/touch "$mark"
            fi
        elif [ -f "$mark" ]; then
            /usr/bin/pmset -a disablesleep 0
            /bin/rm -f "$mark"
            if /usr/sbin/ioreg -r -k AppleClamshellState -d 1 | /usr/bin/grep -q '"AppleClamshellState" = Yes'; then
                /usr/bin/pmset sleepnow
            fi
        fi

        """
    }

    public static func plist() -> Data {
        let job: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/sh", scriptPath],
                                  "RunAtLoad": true, "StartInterval": interval]
        return (try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)) ?? Data()
    }

    /// Run as root: installs the script and the daemon from the files the app wrote, and starts it.
    public static func installCommand(script: String, plist: String) -> String {
        let markDir = (markPath as NSString).deletingLastPathComponent
        return [
            "set -e",
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools \(shellQuoted(markDir))",
            "/usr/bin/install -o root -g wheel -m 755 \(shellQuoted(script)) \(shellQuoted(scriptPath))",
            "/usr/bin/install -o root -g wheel -m 644 \(shellQuoted(plist)) \(shellQuoted(plistPath))",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "/bin/sleep 1",
            "/bin/launchctl bootstrap system \(shellQuoted(plistPath))",
        ].joined(separator: "\n")
    }

    /// Run as root: stops the daemon, turns sleep back on if it had turned it off, and removes its files.
    public static var uninstallCommand: String {
        let markDir = (markPath as NSString).deletingLastPathComponent
        return [
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "if [ -f \(shellQuoted(markPath)) ]; then /usr/bin/pmset -a disablesleep 0; fi",
            "/bin/rm -rf \(shellQuoted(markDir))",
            "/bin/rm -f \(shellQuoted(plistPath)) \(shellQuoted(scriptPath))",
        ].joined(separator: "\n")
    }

    /// AppleScript that runs `command` as root after macOS asks for an administrator's password.
    public static func privileged(_ command: String, prompt: String) -> String {
        "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
    }

    /// The installed script's version; nil when there is none.
    public static func installedVersion(scriptText: String?) -> Int? {
        guard let scriptText else { return nil }
        for line in scriptText.split(separator: "\n") where line.hasPrefix("# Version: ") {
            return Int(line.dropFirst("# Version: ".count).trimmingCharacters(in: .whitespaces))
        }
        return 0
    }
}
