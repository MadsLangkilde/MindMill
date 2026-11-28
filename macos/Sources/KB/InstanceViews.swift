import AppKit
import KBCore
import KBEngine
import SwiftUI

/// Instances on the Mac: the list in kb's config, a new one, and switching, which restarts Mindmill on the other one
/// so every part of the app (sessions, factories, tests, scans) reads that instance's own data from the start.
extension AppModel {
    var instance: MindmillInstance { engine.instance ?? instances.open }

    func reloadInstances() { instances = engine.instanceList() }

    func createInstance(name: String, folder: URL) throws -> MindmillInstance {
        let made = try engine.createInstance(name: name, folder: folder)
        reloadInstances()
        return made
    }

    func renameInstance(_ id: String, to name: String) throws {
        var list = engine.instanceList()
        try list.rename(id, to: name)
        try list.save(configURL: engine.configURL)
        if engine.instance?.id == id { engine.instance = list.instance(id) }
        reloadInstances()
    }

    func forgetInstance(_ id: String) throws {
        var list = engine.instanceList()
        try list.forget(id)
        try list.save(configURL: engine.configURL)
        reloadInstances()
    }

    /// Restarts Mindmill on `target`. Asks first, saying which sessions stop, unless the phone asked (it asks there).
    func switchInstance(to target: MindmillInstance, askFirst: Bool = true) {
        guard target.id != instance.id else { return }
        if askFirst {
            let busy = engine.sessions.list.filter { $0.chat.isBusy }.count
            let alert = NSAlert()
            alert.messageText = "Switch to \(target.name)?"
            alert.informativeText = "Mindmill restarts on \(target.name): its knowledge base, sessions and factories."
                + (busy > 0 ? " \(busy == 1 ? "A session is" : "\(busy) sessions are") working now and will stop; continue \(busy == 1 ? "it" : "them") when you switch back." : "")
            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        pendingInstance = target
        relaunchInBackground = BackgroundMode.keepsRunning && !BackgroundMode.hasOpenWindow()
        NSApp.terminate(nil)
    }

    /// At quit after a switch: records the other instance as open and opens Mindmill again once this one has gone.
    func relaunchIfSwitching() {
        guard let target = pendingInstance else { return }
        var list = engine.instanceList()
        guard list.instance(target.id) != nil else { return }
        list.current = target.id
        do { try list.save(configURL: engine.configURL) } catch { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; exec \"$@\"", "sh"]
            + BackgroundAgents.openCommand(app: BackgroundMode.appPath, background: relaunchInBackground)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// Settings → Knowledge Base: every instance, the open one marked, with a new one, switching, renaming and removing.
struct InstancesSection: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var renaming: MindmillInstance?
    @State private var newName = ""
    @State private var forgetting: MindmillInstance?
    @State private var problem: String?

    var body: some View {
        Section {
            ForEach(model.instances.instances) { i in
                AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 220) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(i.name).font(.body.weight(.medium))
                        Text(KBConfig.abbreviateTilde(i.rootURL.path))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !FileManager.default.fileExists(atPath: i.rootURL.path) {
                            Text("This folder isn't there any more.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    ChipRow(spacing: 8, alignment: .top) {
                        if i.id == model.instance.id {
                            Text("Open").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        } else {
                            Button("Switch") { model.switchInstance(to: i) }
                        }
                        Menu("More") {
                            Button("Rename…") {
                                newName = i.name
                                renaming = i
                            }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([i.rootURL]) }
                            if i.id != model.instance.id {
                                Divider()
                                Button("Remove from Mindmill…") { forgetting = i }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .padding(.vertical, 2)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("New Instance…") { creating = true }
            }
        } header: {
            Text("Instances")
        } footer: {
            Text("Each instance is a knowledge base of its own, with its own projects, scopes, sessions and factories. One is open at a time; switching restarts Mindmill on the other one. Your phone pairing and settings are shared.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $creating) { NewInstanceSheet() }
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                guard let i = renaming else { return }
                do { try model.renameInstance(i.id, to: newName); problem = nil } catch { problem = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove \(forgetting?.name ?? "") from Mindmill?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Remove", role: .destructive) {
                guard let i = forgetting else { return }
                do { try model.forgetInstance(i.id); problem = nil } catch { problem = error.localizedDescription }
            }
        } message: {
            Text("Its folder and everything in it stay where they are. Add it again with New Instance and the same folder.")
        }
        .onAppear { model.reloadInstances() }
    }
}

/// A new instance: a name and a folder, new or empty (Mindmill starts a knowledge base there) or one already.
struct NewInstanceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = ""
    @State private var problem: String?

    private var suggested: String { "~/Mindmill/" + Slug.make(name.isEmpty ? "instance" : name, maxLength: 40) }
    private var folder: URL { KBConfig.rootURL(for: path.trimmingCharacters(in: .whitespaces).isEmpty ? suggested : path) }
    private var state: KnowledgeBaseFolder { KnowledgeBaseFolder.check(folder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Instance").font(.title2.weight(.semibold))
            Text("A knowledge base of its own, with its own projects and scopes, in a folder you choose.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("Work, Private, a client…"))
                HStack {
                    TextField("Folder", text: $path, prompt: Text(suggested)).font(.body.monospaced())
                    Button("Choose…", action: choose)
                }
                Label(state.message, systemImage: state.usable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(state.usable ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.grouped)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ChipRow(spacing: 8, alignment: .top) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create(open: false) }
                    .disabled(!ready)
                Button("Create and Switch") { create(open: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(width: 520)
    }

    private var ready: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && state.usable }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a new or empty folder for the instance, or a knowledge base"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { path = KBConfig.abbreviateTilde(url.path) }
    }

    private func create(open: Bool) {
        do {
            let made = try model.createInstance(name: name, folder: folder)
            dismiss()
            if open { DispatchQueue.main.async { model.switchInstance(to: made) } }
        } catch {
            problem = error.localizedDescription
        }
    }
}
