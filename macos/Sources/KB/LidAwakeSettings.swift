import IOKit.ps
import KBCore
import KBEngine
import SwiftUI

/// Settings → Remote → Stay reachable with the lid closed: the switch, and the helper that makes it work (`LidAwake`).
extension AppModel {
    static let stayAwakeKey = "stayAwakeLidClosed"

    /// The switch is on and phones may use this Mac.
    var wantsLidAwake: Bool {
        UserDefaults.standard.bool(forKey: Self.stayAwakeKey) && UserDefaults.standard.bool(forKey: RemoteServer.enabledKey)
    }

    /// Writes or removes the file the helper checks.
    func syncLidAwakeFlag() {
        let url = LidAwake.flagURL()
        if wantsLidAwake {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: Data()) }
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The installed helper's version; nil when there is none.
    static var lidHelperVersion: Int? {
        LidAwake.installedVersion(scriptText: try? String(contentsOfFile: LidAwake.scriptPath, encoding: .utf8))
    }

    /// The helper has sleep turned off right now.
    static var lidAwakeActive: Bool { FileManager.default.fileExists(atPath: LidAwake.markPath) }

    static var onPower: Bool { IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() != nil }

    /// Installs or updates the helper; macOS asks for an administrator's password. nil when it worked, "" when the
    /// user cancelled, else what went wrong.
    func installLidHelper() async -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mindmill-lid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let script = dir.appendingPathComponent("stayawake.sh")
            let plist = dir.appendingPathComponent("stayawake.plist")
            try LidAwake.script(flag: LidAwake.flagURL().path).write(to: script, atomically: true, encoding: .utf8)
            try LidAwake.plist().write(to: plist)
            return await runPrivileged(LidAwake.installCommand(script: script.path, plist: plist.path),
                                       prompt: "Mindmill wants to install its helper that keeps this Mac awake with the lid closed while it's plugged in.")
        } catch {
            return error.localizedDescription
        }
    }

    /// Removes the helper and lets the Mac sleep as usual again.
    func removeLidHelper() async -> String? {
        await runPrivileged(LidAwake.uninstallCommand, prompt: "Mindmill wants to remove its lid helper, so this Mac sleeps as usual again.")
    }

    private func runPrivileged(_ command: String, prompt: String) async -> String? {
        let r = await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                                          arguments: ["-e", LidAwake.privileged(command, prompt: prompt)],
                                          environment: ProcessInfo.processInfo.environment, stdin: nil, currentDirectory: nil)
        if r.status == 0 { return nil }
        if r.stderr.contains("(-128)") { return "" }
        let why = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return why.isEmpty ? "It didn't work (exit \(r.status))." : why
    }
}

struct LidAwakeSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.stayAwakeKey) private var stayAwake = false
    @AppStorage(RemoteServer.enabledKey) private var remoteOn = false
    @State private var busy = false
    @State private var error: String?
    @State private var checked = 0

    var body: some View {
        let _ = checked
        let version = AppModel.lidHelperVersion
        Toggle("Stay reachable with the lid closed", isOn: $stayAwake)
            .onChange(of: stayAwake) { _, _ in model.syncLidAwakeFlag() }
        Text("macOS sleeps when you close the lid, and a sleeping Mac can't answer the phone. With this on, the Mac stays awake while it's plugged in and Mindmill is open, also with the lid closed or idle, and the Apple menu's Sleep waits too. On battery it sleeps as usual.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if stayAwake {
            if let version, version >= LidAwake.version {
                SwiftUI.TimelineView(.periodic(from: .now, by: 5)) { _ in status }
            } else {
                AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 220) {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text(version == nil
                         ? "Only an administrator can keep a Mac awake with its lid closed, so this needs a small helper, installed once. macOS asks for your password."
                         : "Mindmill has a newer lid helper. Update it to keep using this; macOS asks for your password.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Button(version == nil ? "Install Helper…" : "Update Helper…") { run { await model.installLidHelper() } }
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .fixedSize()
                    .disabled(busy)
                }
            }
        }
        if version != nil {
            Button("Remove Helper…") { run { await model.removeLidHelper() } }
                .disabled(busy)
                .help("Stops the helper and removes it; the Mac sleeps as usual when you close the lid")
        }
        if let error, !error.isEmpty {
            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var status: some View {
        if AppModel.lidAwakeActive {
            Label("Keeping this Mac awake now. Close the lid and phones still reach it.", systemImage: "sun.max")
                .foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
        } else if !remoteOn {
            Label("Not now: turn on remote access above.", systemImage: "moon")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if !AppModel.onPower {
            Label("Not now: the Mac is on battery, so it sleeps as usual. Plug it in to stay reachable.", systemImage: "battery.50")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Label("Starting in a few seconds…", systemImage: "hourglass")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func run(_ work: @escaping () async -> String?) {
        busy = true
        error = nil
        Task {
            error = await work()
            busy = false
            checked += 1
        }
    }
}
