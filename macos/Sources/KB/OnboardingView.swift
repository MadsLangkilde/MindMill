import AppKit
import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    var hasKnowledgeBase: Bool {
        FileManager.default.fileExists(atPath: KBLayout.home(root: rootURL).appendingPathComponent("kb.json").path)
    }

    var showOnboarding: Bool {
        let found: Bool?
        switch claudeAvailability {
        case .resolving: found = nil
        case .found: found = true
        case .missing: found = false
        }
        return onboardingInProgress || OnboardingGate.needed(aiFound: found, hasKnowledgeBase: hasKnowledgeBase, forced: onboardingForced)
    }

    var pythonFound: Bool { shell?.python3.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false }

    var pluginFound: Bool {
        FileManager.default.fileExists(atPath: KBConfig.expandTilde(pluginRootPath) + "/scripts/kb.py")
    }

    func finishOnboarding() {
        onboardingCompleted = true
        UserDefaults.standard.set(true, forKey: OnboardingGate.completedKey)
        onboardingForced = false
        onboardingInProgress = false
        startBackgroundWork()
    }

    /// Starts the Claude session that checks, connects and saves the chosen tools, in Plan → Sessions.
    func startSourceSetup(tracker: String?, tools: [String], calendar: CalendarSource = .none, servers: [ClaudeConnectors.Server]) {
        let scopes = index.projects.map { SourceSetup.Scope(id: $0.id, title: $0.title, tracker: trackerKind($0.id)) }
        var picked = UserTools.load(root: rootURL)
        picked.adopt(tools)
        try? picked.save(root: rootURL)
        let brief = SourceSetup.brief(tracker: tracker, tools: tools, calendar: calendar, scopes: scopes, connected: servers)
        mode = .plan
        sidebarSelection = .sessions
        openWindowAction?("main", nil)
        newSession(title: "Set up my tools", message: brief, display: "Set up my tools with \(Brain.name)", space: .plan)
    }

    static let pluginID = "mindmill@mindmill"

    /// Whether `/mindmill` works in Claude Code outside KB: the plugin installed from Mindmill's own copy.
    func checkClaudePlugin() {
        guard case .found(let exe) = claudeAvailability else { return }
        let env = claudeEnvironment()
        Task {
            let r = await AzureCLISignIn.run(exe, ["plugin", "list"], environment: env)
            claudePluginInstalled = r.output.contains(Self.pluginID)
        }
    }

    /// Adds Mindmill's plugin to Claude Code: its folder as a marketplace, then the plugin from it.
    func installClaudePlugin() {
        guard case .found(let exe) = claudeAvailability else { return }
        let env = claudeEnvironment()
        let path = KBConfig.expandTilde(pluginRootPath)
        installingClaudePlugin = true
        Task {
            defer { installingClaudePlugin = false }
            // The plugin was called kb before; take that one out so the skills don't load twice.
            _ = await AzureCLISignIn.run(exe, ["plugin", "uninstall", "kb@kb"], environment: env)
            _ = await AzureCLISignIn.run(exe, ["plugin", "marketplace", "remove", "kb"], environment: env)
            _ = await AzureCLISignIn.run(exe, ["plugin", "marketplace", "add", path], environment: env)
            let r = await AzureCLISignIn.run(exe, ["plugin", "install", Self.pluginID], environment: env)
            let list = await AzureCLISignIn.run(exe, ["plugin", "list"], environment: env)
            claudePluginInstalled = list.output.contains(Self.pluginID)
            if claudePluginInstalled != true {
                errorMessage = "Claude Code didn't add Mindmill's plugin:\n\n" + String(r.output.suffix(600))
            }
        }
    }

    /// Runs commands in a new Terminal window, where the user sees what happens.
    func runInTerminal(_ lines: [String], name: String) {
        let script = (["#!/bin/zsh -il", "clear"] + lines).joined(separator: "\n") + "\n"
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KB")
        let url = dir.appendingPathComponent("\(name).command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            errorMessage = "Could not write \(url.path): \(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// The first-run setup, in the main window: an AI assistant first (required), then the knowledge base, then the
/// tools KB reaches, set up by Claude.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = OnboardingGate.Step.assistant
    @State private var picked = false
    @State private var tracker: String?
    @State private var tools: Set<String> = []
    /// nil until the user picks one in the Tools step: the saved choice stands.
    @State private var calendar: CalendarSource?
    @State private var servers: [ClaudeConnectors.Server] = []
    @State private var serversLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    switch step {
                    case .assistant: AssistantStep()
                    case .knowledgeBase: KnowledgeBaseStep()
                    case .voice: VoiceStep()
                    case .background: BackgroundStep()
                    case .tools: ToolsPicker(tracker: $tracker, tools: $tools, servers: $servers, loaded: $serversLoaded,
                                             calendar: Binding(get: { calendar ?? model.calendarSource }, set: { calendar = $0 }))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            Divider()
            footer
        }
        .onAppear {
            model.onboardingInProgress = true
            if !picked {
                picked = true
                step = OnboardingGate.firstStep(assistantReady: assistantReady, hasKnowledgeBase: model.hasKnowledgeBase)
                if case .found = model.claudeAvailability { model.checkClaudeSignIn() }
            }
        }
        .onChange(of: model.claudeAvailability) { _, now in
            if case .found = now { model.checkClaudeSignIn() }
        }
    }

    private var pickedCalendar: CalendarSource { calendar ?? model.calendarSource }

    private var assistantReady: Bool {
        guard case .found = model.claudeAvailability, case .signedIn = model.claudeSignIn.phase else { return false }
        return model.pythonFound && model.pluginFound
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set Up Mindmill").font(.largeTitle.weight(.semibold))
            Text("Mindmill works through an AI assistant: it reads your tracker, mail and calendar, and does the work, through the assistant's connections. A few short steps.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ChipRow(alignment: .top) {
                ForEach(OnboardingGate.Step.allCases, id: \.self) { s in
                    Text("\(s.rawValue + 1). \(s.title)")
                        .font(.callout.weight(s == step ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(s == step ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1)))
                        .foregroundStyle(s.rawValue <= step.rawValue ? .primary : .secondary)
                }
            }
        }
    }

    private var footer: some View {
        ChipRow(spacing: 8, alignment: .top) {
            if step != .assistant {
                Button("Back") { step = OnboardingGate.Step(rawValue: step.rawValue - 1) ?? .assistant }
            }
            if step == .tools {
                Button("Skip for Now") {
                    model.chooseCalendar(pickedCalendar)
                    model.finishOnboarding()
                }
                .help("Finish without connecting anything now. The calendar you picked is kept; Settings → Connections → Set Up with \(Brain.name) does the rest later")
                Button("Set Up with \(Brain.name)") {
                    let picked = pickedCalendar
                    model.chooseCalendar(picked)
                    model.finishOnboarding()
                    model.startSourceSetup(tracker: tracker, tools: Array(tools).sorted(), calendar: picked, servers: servers)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tracker == nil && tools.isEmpty && !pickedCalendar.isSet)
            } else if step == .assistant, model.onboardingCompleted, !model.onboardingForced, model.hasKnowledgeBase {
                Button("Done") { model.finishOnboarding() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!assistantReady)
            } else {
                Button("Continue") { step = OnboardingGate.Step(rawValue: step.rawValue + 1) ?? .tools }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .assistant ? !assistantReady
                              : step == .knowledgeBase ? !OnboardingGate.knowledgeBaseReady(hasKnowledgeBase: model.hasKnowledgeBase,
                                                                                            projects: model.index.projects.count)
                              : false)
                    .help(step == .knowledgeBase && model.index.projects.isEmpty ? "Add a project first" : "")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

extension AppModel {
    var hasKnowledgeBaseFolder: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// A requirement: its state, what it is, and what to do about it.
private struct RequirementRow<Action: View>: View {
    let ok: Bool?
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 200) {
            Group {
                switch ok {
                case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case false?: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case nil: ProgressView().controlSize(.small)
                }
            }
            .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) { action }.fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }
}

/// Step 1: pick the brain, the AI KB works through, which must be installed and signed in, and Mindmill's own pieces found,
/// before anything else. Other models can take specific tasks.
private struct AssistantStep: View {
    @Environment(AppModel.self) private var model
    @State private var checking = false
    @State private var showTasks = false

    private var provider: AIProvider { model.aiSetup.brainProvider }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. Your AI").font(.title2.weight(.semibold))
            Text("Pick the brain: the AI that runs your sessions, answers your questions and keeps the knowledge base up to date. Mindmill names it in buttons and menus.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            BrainPicker()
            DisclosureGroup("Use other models for specific tasks", isExpanded: $showTasks) {
                TaskAssignments().padding(.top, 6)
            }
            .font(.callout)
            Divider().padding(.vertical, 2)
            installed
            if case .found = model.claudeAvailability { signedIn }
            RequirementRow(ok: model.shell == nil ? nil : model.pythonFound, title: "Python 3",
                           detail: model.pythonFound ? "Found." : "Mindmill's command line runs on Python 3. Installing Apple's command line tools brings it.") {
                if model.shell != nil, !model.pythonFound {
                    Button("Install…") { model.runInTerminal(["xcode-select --install"], name: "install-python") }
                }
            }
            RequirementRow(ok: model.pluginFound, title: "Mindmill plugin",
                           detail: model.pluginFound ? (model.pluginLocation.source == .bundled ? "Comes with Mindmill." : KBConfig.abbreviateTilde(KBConfig.expandTilde(model.pluginRootPath)))
                               : "Not found. Reinstall Mindmill, or choose the folder that has scripts/kb.py.") {
                if !model.pluginFound { Button("Choose…", action: choosePlugin) }
            }
            if case .found = model.claudeAvailability, model.pluginFound, model.aiSetup.brainProvider.id == AIProvider.claudeCode.id {
                RequirementRow(ok: model.claudePluginInstalled,
                               title: "Mindmill in Claude Code (optional)",
                               detail: model.claudePluginInstalled == true ? "/mindmill works in Claude Code in Terminal too."
                                   : "Adds Mindmill's skills to Claude Code, so /mindmill works in Terminal and your editor too. Mindmill itself works without it.") {
                    if model.installingClaudePlugin {
                        ProgressView().controlSize(.small)
                    } else if model.claudePluginInstalled != true {
                        Button("Add to Claude Code") { model.installClaudePlugin() }
                    }
                }
                .onAppear { model.checkClaudePlugin() }
            }
        }
    }

    @ViewBuilder
    private var installed: some View {
        switch model.claudeAvailability {
        case .resolving:
            RequirementRow(ok: nil, title: provider.name, detail: "Looking for it…") { EmptyView() }
        case .found(let url):
            RequirementRow(ok: true, title: "\(provider.name) is installed", detail: KBConfig.abbreviateTilde(url.path)) { EmptyView() }
        case .missing:
            VStack(alignment: .leading, spacing: 8) {
                RequirementRow(ok: false, title: "\(provider.name) isn't installed",
                               detail: "Install it in Terminal with the command below, then press Check Again.") {
                    Button("Install in Terminal") {
                        model.runInTerminal(["echo 'Installing \(provider.name) for Mindmill…'", "echo", provider.installCommand,
                                             "echo", "echo 'Done. Go back to Mindmill and press Check Again.'"],
                                            name: "install-claude")
                    }
                    Button("Check Again", action: checkAgain).disabled(checking)
                }
                Text(provider.installCommand).font(.callout.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Other ways to install", destination: provider.docsURL).font(.callout)
            }
        }
    }

    @ViewBuilder
    private var signedIn: some View {
        let phase = model.claudeSignIn.phase
        switch phase {
        case .checking:
            RequirementRow(ok: nil, title: "Signed in", detail: "Checking…") { EmptyView() }
        case .signedIn(let account), .done(let account):
            RequirementRow(ok: true, title: "Signed in", detail: account.isEmpty ? "Signed in." : account) { EmptyView() }
        case .waiting:
            RequirementRow(ok: nil, title: "Signing in", detail: "Finish signing in in your browser.") {
                if let url = model.claudeSignIn.url { Button("Open the Page") { NSWorkspace.shared.open(url) } }
                Button("Cancel") { model.claudeSignIn.cancel() }
            }
        case .signedOut, .failed:
            RequirementRow(ok: false, title: "Not signed in",
                           detail: phaseError(phase) ?? "Sign in with your \(Brain.name) account (Pro, Max, Team or Enterprise) or an Anthropic Console account.") {
                Button("Sign In") { model.startClaudeLogin() }
                Menu("More") {
                    Button("Sign In in Terminal") { model.claudeLoginInTerminal() }
                    Button("Check Again") { model.checkClaudeSignIn() }
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    private func phaseError(_ phase: ClaudeSignIn.Phase) -> String? {
        if case .failed(let why) = phase { return why }
        return nil
    }

    private func checkAgain() {
        checking = true
        model.resolveShell()
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if case .found = model.claudeAvailability { model.checkClaudeSignIn(); break }
                if case .missing = model.claudeAvailability { break }
            }
            checking = false
        }
    }

    private func choosePlugin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(KBConfig.abbreviateTilde(url.path), forKey: AppSettingsKeys.pluginRoot)
            model.resolveShell()
        }
    }
}

/// Step 2: Mindmill's own folder for everything it keeps across projects, never a project's folder, and the projects
/// in it. Continue waits for the first project.
private struct KnowledgeBaseStep: View {
    @Environment(AppModel.self) private var model
    @State private var path = ""

    var body: some View {
        let typedURL = KBConfig.rootURL(for: path)
        let typed = KnowledgeBaseFolder.check(typedURL)
        let isCurrent = model.hasKnowledgeBase && typedURL == model.rootURL
        VStack(alignment: .leading, spacing: 12) {
            Text("2. Knowledge Base").font(.title2.weight(.semibold))
            Text("Mindmill's own folder for everything it learns across all your projects: decisions, meetings, facts and work, as Markdown files you own. It isn't a project's folder: pick a new or empty one, or a Mindmill knowledge base you already have. Your projects' code stays where it is; you add the projects below.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.hasKnowledgeBase, case .inUse(let what) = KnowledgeBaseFolder.check(model.rootURL) {
                Label("Mindmill was set to \(KBConfig.abbreviateTilde(model.rootURL.path)), which is \(what), not a knowledge base. Pick a new folder for it here; nothing in that folder was changed.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ChipRow(spacing: 8, alignment: .top) {
                TextField("Folder", text: $path, prompt: Text(KnowledgeBaseFolder.suggestedPath))
                    .font(.body.monospaced())
                    .frame(minWidth: 220)
                Button("Choose…", action: choose)
                Button("Use This Folder", action: use)
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty || !typed.usable || isCurrent)
            }
            if isCurrent {
                RequirementRow(ok: true, title: KBConfig.abbreviateTilde(model.rootURL.path), detail: "Your knowledge base.") { EmptyView() }
            } else if !path.trimmingCharacters(in: .whitespaces).isEmpty {
                Label(typed.message, systemImage: typed.usable ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(typed.usable ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.hasKnowledgeBase {
                Text("Projects").font(.headline).padding(.top, 6)
                if model.index.projects.isEmpty {
                    Text("A project is one product or codebase, such as an app and its repository folders. Mindmill keeps each project's knowledge apart.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ChipRow(alignment: .top) {
                        ForEach(model.index.projects) { p in
                            Text(p.title).font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }
                    }
                }
                Button { model.addProjectRequest = AddProjectRequest() } label: { Label("Add a Project…", systemImage: "plus") }
                if model.index.projects.isEmpty {
                    Label("Add at least one project to continue.", systemImage: "arrow.turn.down.right")
                        .font(.callout.weight(.medium)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { path = model.hasKnowledgeBase ? model.rootPath : KnowledgeBaseFolder.suggestedPath }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a new or empty folder for Mindmill's knowledge base, not a project's folder."
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url { path = KBConfig.abbreviateTilde(url.path) }
    }

    /// Makes the folder and starts a knowledge base in it, unless it has one already.
    private func use() {
        let url = KBConfig.rootURL(for: path)
        let state = KnowledgeBaseFolder.check(url)
        guard state.usable else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if state != .knowledgeBase { try Registry.createKnowledgeBase(root: url) }
        } catch {
            model.errorMessage = "Could not start a knowledge base in \(url.path): \(error.localizedDescription)"
            return
        }
        model.changeRoot(to: path)
    }
}

/// Where work is tracked and which other tools to connect, with each one's state in Claude. Used by the first-run
/// setup and by Settings → Connections → Set Up with Claude.
struct ToolsPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var tracker: String?
    @Binding var tools: Set<String>
    @Binding var servers: [ClaudeConnectors.Server]
    @Binding var loaded: Bool
    /// The first-run setup picks the calendar here; Settings has its own picker.
    var calendar: Binding<CalendarSource>?
    @State private var loading = false

    private var otherTools: [ClaudeConnectors.Service] {
        ClaudeConnectors.catalog.filter { s in !SourceSetup.trackers.contains { $0.kind == s.id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Tools").font(.title2.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Check what \(Brain.name) is connected to again").disabled(loading)
            }
            Text("Pick what you use. Claude then checks each one, walks you through connecting what's missing (most connect at claude.ai → Settings → Connectors) and saves Mindmill's settings. You can change it any time in Settings → Connections.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Text("Where do you track work?").font(.headline).padding(.top, 4)
            ForEach(SourceSetup.trackers) { t in
                choiceRow(selected: tracker == t.kind, title: t.title, note: t.note,
                          status: t.kind == "azure-devops" || t.kind == "local" ? nil : status(of: t.kind)) {
                    tracker = tracker == t.kind ? nil : t.kind
                }
            }

            if let calendar {
                Text("Which calendar should Mindmill read?").font(.headline).padding(.top, 4)
                Text("Optional. Mindmill mirrors its meetings so you can prepare them and take notes; without one you add meetings yourself.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(calendarChoices(calendar.wrappedValue)) { c in
                    choiceRow(selected: calendar.wrappedValue.id == c.id, title: c.title, note: c.note,
                              status: c.isSet ? c.server(in: servers)?.status : nil) {
                        calendar.wrappedValue = c
                    }
                }
            }

            Text("Anything else?").font(.headline).padding(.top, 4)
            ForEach(otherTools) { s in
                choiceRow(selected: tools.contains(s.id), title: s.title, note: s.note, status: status(of: s.id)) {
                    if tools.contains(s.id) { tools.remove(s.id) } else { tools.insert(s.id) }
                }
            }
        }
        .onAppear { if !loaded { refresh() } }
    }

    private func calendarChoices(_ current: CalendarSource) -> [CalendarSource] {
        let choices = CalendarSource.choices(servers: servers)
        return choices.contains(current) ? choices : choices + [current]
    }

    private func status(of serviceID: String) -> ClaudeConnectors.Server.Status? {
        guard let s = ClaudeConnectors.catalog.first(where: { $0.id == serviceID }) else { return nil }
        let found = ClaudeConnectors.servers(for: s, in: servers)
        return (found.first { $0.status == .connected } ?? found.first)?.status
    }

    private func choiceRow(selected: Bool, title: String, note: String, status: ClaudeConnectors.Server.Status?,
                           toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 200) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    switch status {
                    case .connected?: Text("Connected").foregroundStyle(.green)
                    case .needsAuth?: Text("Needs sign-in").foregroundStyle(.orange)
                    case .failed?, .unknown?: Text("Needs attention").foregroundStyle(.orange)
                    case nil: EmptyView()
                    }
                }
                .font(.callout)
                .fixedSize()
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func refresh() {
        loading = true
        Task {
            let r = await model.runClaude(["mcp", "list"])
            servers = r.map { ClaudeConnectors.parse($0.stdout) } ?? []
            loading = false
            loaded = true
        }
    }
}

/// Settings → Connections → Set Up with Claude: the same choices as the first-run setup, then a Claude session.
struct SourceSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tracker: String?
    @State private var tools: Set<String> = []
    @State private var servers: [ClaudeConnectors.Server] = []
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                ToolsPicker(tracker: $tracker, tools: $tools, servers: $servers, loaded: $loaded)
                    .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set Up with \(Brain.name)") {
                    model.startSourceSetup(tracker: tracker, tools: Array(tools).sorted(), servers: servers)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tracker == nil && tools.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 360, idealWidth: 560, minHeight: 420, idealHeight: 640)
    }
}

/// Voice works without setup; a key for a voice API is optional and can be added later in Settings → Voice.
private struct VoiceStep: View {
    @State private var addKey = false
    @State private var provider = RealtimeProvider.all.first { $0.available }?.id ?? "openai"
    @State private var key = ""
    @State private var result: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Voice is on", systemImage: "waveform").font(.title3.weight(.semibold))
            Text("Talk to Mindmill on this Mac with ⌥⌘V, or from the Mindmill app on your phone. It uses the speech recognition and voices built into your Mac and phone, with \(Brain.name) doing the thinking. Nothing to set up.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Add an API key for smoother voice (optional)", isExpanded: $addKey) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A real-time voice API answers faster and sounds more natural. The key stays on this Mac, readable only by your user; your phone talks through the Mac. If the key stops working, Mindmill switches back to the built-in voice by itself.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("Provider", selection: $provider) {
                        ForEach(RealtimeProvider.all.filter(\.available)) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        SecureField("API key", text: $key).textFieldStyle(.roundedBorder)
                        Button(saving ? "Checking…" : "Save and Test") { save() }
                            .disabled(saving || key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let page = RealtimeProvider.with(id: provider)?.keyPage, let url = URL(string: page) {
                        Link("Get a key", destination: url).font(.caption)
                    }
                    if let result { Text(result).font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.top, 8)
            }
        }
    }

    private func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        MacVoiceKeys().set(k, provider: provider)
        var prefs = VoicePreferences.load()
        prefs.provider = provider
        prefs.engine = .api
        prefs.save()
        key = ""
        saving = true
        Task {
            result = await RealtimeKeyTest.test(provider: provider, key: k)
            saving = false
        }
    }
}
