import AppKit
import KBCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        if let path = ProcessInfo.processInfo.environment["KB_SNAPSHOT"], !path.isEmpty {
            startSnapshots(to: URL(fileURLWithPath: path))
        }
    }

    /// Diagnostics: with `KB_SNAPSHOT=<file.png>` set, renders the main window to that file every two seconds,
    /// every other window to `<file>-<window title>.png`, and an attached sheet to `…-sheet.png`.
    /// Needs no screen-recording permission because the app draws its own windows.
    private func startSnapshots(to url: URL) {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let base = url.deletingPathExtension()
                for window in NSApp.windows where window.isVisible && window.contentView != nil && !window.isSheet {
                    guard !window.title.isEmpty else { continue }
                    let isMain = window.title.hasPrefix("Mindmill")
                    let target = isMain ? url : URL(fileURLWithPath: base.path + "-" + Slug.make(window.title) + ".png")
                    Self.render(window, to: target)
                    if let sheet = window.attachedSheet {
                        Self.render(sheet, to: URL(fileURLWithPath: (isMain ? base.path : target.deletingPathExtension().path) + "-sheet.png"))
                    }
                }
            }
        }
    }

    @MainActor
    private static func render(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        model?.morning.stop()
        model?.calendar.stop()
        model?.email.stop()
        model?.goalChats.values.forEach { $0.stop() }
        model?.askConversations.values.forEach { $0.chat.stop() }
        model?.testing.stopServers()
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(model.document?.title ?? "this entry")”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return model.save() ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }
}

@main
struct KBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
        // Scroll bars float over the content (shown while scrolling) instead of taking a column: a list that gains a
        // scroll bar would otherwise get narrower and rewrap its rows. Mindmill's own setting; the system's is untouched.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    var body: some Scene {
        Window("Mindmill", id: "main") {
            ContentView()
                .environment(model)
                .onAppear { delegate.model = model }
                .onOpenURL { model.handle(url: $0) }
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1280, height: 800)
        .handlesExternalEvents(matching: ["*"])
        .commands { KBCommands(model: model) }

        WindowGroup("Meeting", id: "meeting", for: String.self) { $id in
            MeetingWindow(meetingID: id ?? "")
                .environment(model)
        }
        .defaultSize(width: 1180, height: 780)
        .commandsRemoved()

        WindowGroup("Web Page", id: "capture", for: String.self) { $id in
            WebCaptureView(requestID: id ?? "")
                .environment(model)
                .frame(minWidth: 700, minHeight: 500)
        }
        .defaultSize(width: 1100, height: 820)
        .commandsRemoved()

        Window("Ask", id: "ask") {
            AskWindow()
                .environment(model)
        }
        .defaultSize(width: 720, height: 760)

        Window("Voice", id: "voice") {
            VoiceWindow()
                .environment(model)
        }
        .defaultSize(width: 440, height: 620)

        Window("\(Brain.name)", id: "claude") {
            SessionsWindow()
                .environment(model)
        }
        .defaultSize(width: 1040, height: 820)

        Settings {
            AppSettingsView()
                .environment(model)
        }
    }
}

struct KBCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Set Up Mindmill…") { model.onboardingForced = true }
            Button("Sign In to Azure…") { model.openAzureSignIn() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Decision…") { model.requestNewEntry(.decisions) }
                .keyboardShortcut("n")
            Button("New Meeting…") { model.requestNewEntry(.meetings) }
            Button("Quick Meeting") { model.startQuickMeeting() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Fact…") { model.requestNewEntry(.facts) }
            Button("New Architecture Note…") { model.requestNewEntry(.architecture) }
            Button("New Follow-up…") { model.requestNewEntry(.followups) }
            Button("New Backlog Item…") { model.requestNewEntry(.backlog) }
            Divider()
            Button("New Reminder…") { model.newReminder() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("New Goal…") { model.newGoal() }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }
                .keyboardShortcut("s")
                .disabled(!((model.document?.isDirty ?? false) || (model.document?.isDraft ?? false)))
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Ask…") { model.openAsk() }
                .keyboardShortcut("k")
                .disabled(model.project == nil)
            Button("New \(Brain.name) Session") { model.newSession(space: model.mode == .build ? .build : .plan) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("New Assistant Session") { model.newAssistantSession() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("\(Brain.name) Sessions") { model.openSessions() }
            VoiceMenuButton()
        }
        CommandGroup(before: .sidebar) {
            Button("Plan") { model.mode = .plan }
                .keyboardShortcut("p", modifiers: [.command, .control])
            Button("Build") { model.mode = .build }
                .keyboardShortcut("b", modifiers: [.command, .control])
            Button("New Session in Build…") {
                model.mode = .build
                model.newLeadRequest = NewLeadRequest(project: model.projectID)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Strategies…") { model.strategiesSheet = StrategiesSheetRequest() }
            Button("Projects and Scopes…") { model.scopesSheet = true }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Sync") { model.syncEverything() }
                .keyboardShortcut("r")
            Button("Auto-Tag Everything") { model.autoTagEverything() }
                .disabled(model.tagger.isRunning || !model.claudeAvailable)
                .help("\(Brain.name) tags every meeting, fact, follow-up, decision and backlog item that has no tags yet, in the background")
            Button("Pull Repositories of This Scope") { if let p = model.projectID { model.pullRepos(scope: p) } }
                .disabled(model.projectID.map { model.repositories(of: $0).all.allSatisfy { $0.checkout == nil } } ?? true)
            Divider()
            Button("Reset \(model.mode == .build ? "Build" : "Plan") Layout") {
                model.resetLayout([model.mode == .build ? .build : .plan])
            }
            Button("Reset All Layouts") { model.resetLayout(LayoutReset.Screen.allCases) }
            Divider()
            Button("Today") { model.selectSidebar(.today) }
                .keyboardShortcut("0")
            Button("Reminders") { model.selectSidebar(.reminders) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button("Goals") { model.selectSidebar(.goals) }
            ForEach(Array([KBSection.overview, .decisions, .meetings, .facts, .architecture].enumerated()), id: \.element) { n, section in
                Button(section.title) { model.selectSidebar(.section(section)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n + 1)")))
            }
            Button("Decisions Timeline") {
                UserDefaults.standard.set(true, forKey: "decisionsTimeline")
                model.selectSidebar(.section(.decisions))
            }
                .keyboardShortcut("6")
            Button("Follow-ups") { model.selectSidebar(.section(.followups)) }
                .keyboardShortcut("7")
            Button("Backlog") { model.selectSidebar(.section(.backlog)) }
                .keyboardShortcut("8")
            Button("Inbox") { model.selectSidebar(.section(.inbox)) }
                .keyboardShortcut("9")
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { model.findRequest += 1 }
                .keyboardShortcut("f")
        }
        CommandMenu("Entry") {
            Button(model.isEditing ? "Show Preview" : "Edit") { model.toggleEditing() }
                .keyboardShortcut("e")
                .disabled(model.document == nil)
            Divider()
            Button("Supersede…") { model.requestSupersede() }
                .disabled(!(model.document.map { $0.status == .active && !$0.isNew } ?? false))
            Divider()
            Button("Reveal in Finder") { model.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.document?.isNew ?? true)
            Button("Open in Default Editor") { model.openInDefaultEditor() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Delete…") { if let id = model.document?.id { model.requestDelete(id) } }
                .disabled(model.document?.isNew ?? true)
                .disabled(model.document?.isNew ?? true)
        }
    }
}

/// Opens the voice window and starts listening.
struct VoiceMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Talk to \(Brain.name)") { openWindow(id: "voice") }
            .keyboardShortcut("v", modifiers: [.command, .option])
    }
}
