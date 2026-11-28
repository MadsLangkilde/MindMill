import AppKit
import KBCore
import KBEngine
import SwiftUI

/// Mindmill without its window: running on in the menu bar, opening at login, and starting when a paired phone asks
/// (`BackgroundAgents`). Each is off until the user turns it on in Settings → General or in onboarding.
enum BackgroundMode {
    static let keepRunningKey = "runInBackground"
    static let openAtLoginKey = "openAtLogin"
    static let phoneCanStartKey = "phoneCanStartMindmill"

    static var keepsRunning: Bool { UserDefaults.standard.bool(forKey: keepRunningKey) }

    /// Opened by the launcher, at login, or by a switch of instance while in the menu bar: no window, menu bar only.
    static var startsHidden: Bool {
        keepsRunning && ProcessInfo.processInfo.arguments.contains(BackgroundAgents.backgroundArgument)
    }

    static var appPath: String { Bundle.main.bundleURL.path }

    /// Gives Mindmill its Dock icon and menus back and brings it forward.
    @MainActor
    static func comeForward() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// No window open: only the menu bar item is left.
    @MainActor
    static func hasOpenWindow(except closing: NSWindow? = nil) -> Bool {
        NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
    }

    @MainActor
    static func closeMainWindow() {
        for w in NSApp.windows where WindowClosing.isMain(w) && w.isVisible { w.close() }
    }

    /// Runs `launchctl` and says whether it worked.
    @discardableResult
    static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static var domain: String { "gui/\(getuid())" }
}

extension AppModel {
    func setKeepRunning(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: BackgroundMode.keepRunningKey)
        if !on { UserDefaults.standard.set(false, forKey: BackgroundMode.phoneCanStartKey) }
        syncBackgroundAgents()
    }

    func setOpenAtLogin(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: BackgroundMode.openAtLoginKey)
        syncBackgroundAgents()
    }

    /// Starting from the phone needs Mindmill to run on without a window and the phone to reach it: it turns both on.
    func setPhoneCanStart(_ on: Bool) {
        let d = UserDefaults.standard
        d.set(on, forKey: BackgroundMode.phoneCanStartKey)
        if on {
            d.set(true, forKey: BackgroundMode.keepRunningKey)
            if !d.bool(forKey: RemoteServer.enabledKey) { setRemoteEnabled(true) }
        }
        syncBackgroundAgents()
    }

    var phoneCanStart: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: BackgroundMode.phoneCanStartKey) && d.bool(forKey: BackgroundMode.keepRunningKey)
            && d.bool(forKey: RemoteServer.enabledKey)
    }

    var launcherPort: Int { BackgroundAgents.launcherPort(remotePort: remote.port) }

    /// Writes or removes the login item and the launcher to match the switches: at launch and whenever one changes.
    func syncBackgroundAgents() {
        let d = UserDefaults.standard
        let fm = FileManager.default
        var problems: [String] = []
        try? fm.createDirectory(at: BackgroundAgents.agentsFolder(), withIntermediateDirectories: true)

        let login = BackgroundAgents.plistURL(BackgroundAgents.loginLabel)
        if d.bool(forKey: BackgroundMode.openAtLoginKey) {
            if !Self.write(BackgroundAgents.loginPlist(app: BackgroundMode.appPath, background: BackgroundMode.keepsRunning), to: login) {
                problems.append("Mindmill couldn't add itself to the login items.")
            }
        } else {
            try? fm.removeItem(at: login)
        }

        let launcher = BackgroundAgents.plistURL(BackgroundAgents.launcherLabel)
        let script = BackgroundAgents.launcherScriptURL()
        let job = "\(BackgroundMode.domain)/\(BackgroundAgents.launcherLabel)"
        if phoneCanStart {
            remote.writeLauncherKeys()
            let keys = BackgroundAgents.keysURL(remoteFolder: remote.folder)
            let wroteScript = Self.write(Data(BackgroundAgents.launcherScript(keys: keys, app: BackgroundMode.appPath).utf8), to: script)
            let wrotePlist = Self.write(BackgroundAgents.launcherPlist(script: script, port: launcherPort), to: launcher)
            let loaded = BackgroundMode.launchctl(["print", job])
            if wroteScript || wrotePlist || !loaded {
                if loaded { BackgroundMode.launchctl(["bootout", job]) }
                if !BackgroundMode.launchctl(["bootstrap", BackgroundMode.domain, launcher.path]) {
                    problems.append("macOS didn't start the launcher. Allow Mindmill under System Settings → General → Login Items & Extensions, then turn this off and on.")
                }
            }
            engine.launcherPort = BackgroundMode.launchctl(["print", job]) ? launcherPort : nil
        } else {
            if fm.fileExists(atPath: launcher.path) {
                BackgroundMode.launchctl(["bootout", job])
                try? fm.removeItem(at: launcher)
            }
            try? fm.removeItem(at: script)
            engine.launcherPort = nil
        }
        backgroundProblem = problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    /// Writes `data` unless the file holds it already; true when it wrote, false when it was the same or failed.
    private static func write(_ data: Data, to url: URL) -> Bool {
        if (try? Data(contentsOf: url)) == data { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// The menu bar item while Mindmill keeps running in the background.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Mindmill") {
            BackgroundMode.comeForward()
            openWindow(id: "main")
        }
        Divider()
        if model.instances.instances.count > 1 {
            Menu("Instance: \(model.instance.name)") {
                ForEach(model.instances.instances) { i in
                    Button(i.id == model.instance.id ? "✓ \(i.name)" : i.name) { model.switchInstance(to: i) }
                        .disabled(i.id == model.instance.id)
                }
            }
        } else {
            Text(model.instance.name)
        }
        Text(model.remote.isRunning ? "Your phone can reach this Mac" : "Remote access is off")
        if model.phoneCanStart { Text("Your phone can start Mindmill") }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Mindmill") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Settings → General: running on without the window, opening at login, and starting from the phone.
struct BackgroundSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(BackgroundMode.keepRunningKey) private var keepRunning = false
    @AppStorage(BackgroundMode.openAtLoginKey) private var openAtLogin = false

    var body: some View {
        Toggle("Keep running when the window is closed", isOn: Binding(get: { keepRunning }, set: { model.setKeepRunning($0) }))
        Text("Mindmill stays in the menu bar, so your phone, sessions and factories keep working. Quit it from there.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Toggle("Open Mindmill when you log in", isOn: Binding(get: { openAtLogin }, set: { model.setOpenAtLogin($0) }))
        Text(keepRunning ? "It opens in the menu bar, without its window." : "It opens with its window.")
            .font(.caption).foregroundStyle(.secondary)
        PhoneStartSetting()
    }
}

/// The switch for starting Mindmill from a paired phone, in General and in Remote.
struct PhoneStartSetting: View {
    @Environment(AppModel.self) private var model
    @AppStorage(BackgroundMode.phoneCanStartKey) private var phoneCanStart = false

    var body: some View {
        Toggle("Let a paired phone start Mindmill", isOn: Binding(get: { phoneCanStart }, set: { model.setPhoneCanStart($0) }))
        Text("A small launcher on port \(model.launcherPort) opens Mindmill in the menu bar when a phone paired under Remote asks, even after you quit it. Only paired phones can, and only while this Mac is awake. Turning it on also keeps Mindmill running in the background and turns on remote access.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let problem = model.backgroundProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Onboarding: the same switches, all off until the user turns them on.
struct BackgroundStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mindmill can keep working when its window is closed, and your phone can reach it, even start it. All of this is off unless you turn it on here or later in Settings → General.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form { BackgroundSettings() }
                .formStyle(.grouped)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pair your phone in Settings → Remote.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
