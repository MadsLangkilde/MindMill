import Foundation

/// Starting Mindmill without the user at the Mac: at login, and when a paired phone asks. Both are launchd agents of
/// the user's own (no administrator needed), written only while the user has them on.
///
/// The launcher listens on the remote port + 1. For each connection launchd runs a small script with the socket as
/// its input and output: it asks the phone to prove it is paired (docs/remote-api.md, "Starting Mindmill from the
/// phone") against the paired phones' token hashes in `launcher-keys`, and opens Mindmill in the background.
public enum BackgroundAgents {
    public static let launcherLabel = "dk.langkilde.kb.launcher"
    public static let loginLabel = "dk.langkilde.kb.login"
    /// Bumped when the script changes, so an installed launcher is rewritten.
    public static let launcherVersion = 1
    /// The launch argument that opens Mindmill without its window, in the menu bar.
    public static let backgroundArgument = "--background"

    public static func agentsFolder(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public static func plistURL(_ label: String, home: String = NSHomeDirectory()) -> URL {
        agentsFolder(home: home).appendingPathComponent(label + ".plist")
    }

    public static func launcherScriptURL(data: URL = AppPaths.data) -> URL { data.appendingPathComponent("launcher.sh") }

    /// The paired phones' token hashes, one a line, next to the phones they belong to.
    public static func keysURL(remoteFolder: URL) -> URL { remoteFolder.appendingPathComponent("launcher-keys") }

    public static func keysText(tokenHashes: [String]) -> String {
        tokenHashes.filter { !$0.isEmpty }.map { $0 + "\n" }.joined()
    }

    public static func launcherPort(remotePort: Int) -> Int { remotePort < 65535 ? remotePort + 1 : remotePort - 1 }

    /// What a phone answers to `nonce`: SHA-256 of its token's hash and the nonce, so the token never travels.
    public static func proof(tokenHash: String, nonce: String) -> String { Digest.sha256Hex(tokenHash + nonce) }

    public static func openCommand(app: String, background: Bool) -> [String] {
        background ? ["/usr/bin/open", "-g", "-j", "-a", app, "--args", backgroundArgument] : ["/usr/bin/open", "-a", app]
    }

    /// `start` opens Mindmill; `running` succeeds when it runs already. Both are shell commands.
    public static func launcherScript(keys: String, start: String, running: String) -> String {
        """
        #!/bin/bash
        # Mindmill's launcher: launchd runs this for each connection to the launcher port while Settings → General →
        # Let a paired phone start Mindmill is on. It opens Mindmill for a phone that proves it is paired.
        # Version: \(launcherVersion)
        keys=\(LidAwake.shellQuoted(keys))
        nonce=$(/usr/bin/openssl rand -hex 16) || exit 0
        printf 'MINDMILL 1 %s\\n' "$nonce"
        IFS= read -r -t 10 line || exit 0
        line=${line%$'\\r'}
        case "$line" in
            "START "*) proof=${line#START } ;;
            *) echo NO; exit 0 ;;
        esac
        ok=0
        if [ -f "$keys" ]; then
            while IFS= read -r key; do
                [ -n "$key" ] || continue
                want=$(printf '%s%s' "$key" "$nonce" | /usr/bin/shasum -a 256 | /usr/bin/cut -d ' ' -f 1)
                if [ "$want" = "$proof" ]; then ok=1; break; fi
            done < "$keys"
        fi
        if [ "$ok" != 1 ]; then echo NO; exit 0; fi
        if \(running); then echo "OK running"; exit 0; fi
        \(start) </dev/null >/dev/null 2>&1
        echo "OK started"

        """
    }

    public static func launcherScript(keys: URL, app: String) -> String {
        launcherScript(keys: keys.path, start: openCommand(app: app, background: true).map(LidAwake.shellQuoted).joined(separator: " "),
                       running: "/usr/bin/pgrep -xq Mindmill")
    }

    public static func launcherPlist(script: URL, port: Int) -> Data {
        plist([
            "Label": launcherLabel,
            "ProgramArguments": ["/bin/bash", script.path],
            "inetdCompatibility": ["Wait": false],
            "Sockets": ["Listeners": ["SockServiceName": String(port), "SockType": "stream"]],
        ])
    }

    /// Opens Mindmill when the user logs in: in the menu bar when it keeps running in the background, else as usual.
    public static func loginPlist(app: String, background: Bool) -> Data {
        plist(["Label": loginLabel, "ProgramArguments": openCommand(app: app, background: background), "RunAtLoad": true])
    }

    static func plist(_ job: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)) ?? Data()
    }

    public static func installedVersion(scriptText: String?) -> Int? { LidAwake.installedVersion(scriptText: scriptText) }
}
