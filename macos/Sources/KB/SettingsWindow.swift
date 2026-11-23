import AppKit
import KBCore
import SwiftUI

/// The app's settings (⌘,), one pane per sidebar row so every pane stays reachable however many there are.
struct AppSettingsView: View {
    @AppStorage(AppSettingsKeys.settingsPane) private var paneID = SettingsPane.general.rawValue

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { pane in
                Label(pane.title, systemImage: pane.icon).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let pane = SettingsPane(rawValue: paneID) ?? .general
            Group {
                if pane.sizesToContent {
                    ScrollView { content(pane).frame(maxWidth: .infinity) }
                } else {
                    content(pane).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 820, minHeight: 560)
        .themedWindow()
    }

    private var selection: Binding<SettingsPane?> {
        Binding(get: { SettingsPane(rawValue: paneID) ?? .general }, set: { if let p = $0 { paneID = p.rawValue } })
    }

    @ViewBuilder
    private func content(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .knowledgeBase: SettingsView()
        case .ai: ClaudeSettingsView()
        case .meetings: MeetingSettingsView()
        case .sources: GlobalSourcesView()
        case .connections: ConnectionsSettingsView()
        case .voice: VoiceSettingsView()
        case .remote: RemoteSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, knowledgeBase, ai, meetings, sources, connections, voice, remote, shortcuts, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .knowledgeBase: "Knowledge Base"
        case .ai: "AI"
        case .meetings: "Meetings"
        case .sources: "Sources"
        case .connections: "Connections"
        case .voice: "Voice"
        case .remote: "Remote"
        case .shortcuts: "Shortcuts"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .knowledgeBase: "books.vertical"
        case .ai: "sparkles"
        case .meetings: "person.2.wave.2"
        case .sources: "point.3.connected.trianglepath.dotted"
        case .connections: "link"
        case .voice: "waveform"
        case .remote: "iphone.radiowaves.left.and.right"
        case .shortcuts: "keyboard"
        case .about: "info.circle"
        }
    }

    /// Panes that take their content's height and need the window to scroll them; the rest scroll themselves.
    var sizesToContent: Bool {
        switch self {
        case .general, .knowledgeBase, .ai, .meetings, .remote, .about: true
        default: false
        }
    }

    /// Opens Settings at this pane.
    @MainActor
    func select() {
        UserDefaults.standard.set(rawValue, forKey: AppSettingsKeys.settingsPane)
    }
}

/// Light, dark or the system's look, for every KB window.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: AppSettingsKeys.appearance) ?? "") ?? .system
    }

    static func apply() {
        let theme = ThemeStore.current
        if theme.hasBackgrounds, let dark = AppTheme.isDark(theme.contentBackground) ?? AppTheme.isDark(theme.sidebarBackground) {
            NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            return
        }
        switch current {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettingsKeys.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppSettingsKeys.launchMode) private var launchMode = ""
    @AppStorage(AppSettingsKeys.autoMorning) private var autoMorning = true
    @AppStorage(AppSettingsKeys.calendarMinutes) private var calendarMinutes = 30

    var body: some View {
        Form {
            Section("Starting Mindmill") {
                Picker("Open in", selection: $launchMode) {
                    Text("Where I left off").tag("")
                    Text("Plan").tag(AppMode.plan.rawValue)
                    Text("Build").tag(AppMode.build.rawValue)
                }
                Toggle("Run the morning routine when Mindmill opens on a new day", isOn: $autoMorning)
                Picker("Sync the calendar", selection: $calendarMinutes) {
                    Text("Every 15 minutes").tag(15)
                    Text("Every 30 minutes").tag(30)
                    Text("Every hour").tag(60)
                    Text("Only at launch and on demand").tag(0)
                }
                .onChange(of: calendarMinutes) { _, _ in model.scheduleSyncTimer() }
            }
            Section("Finding things") {
                Text("⌘F searches where you are: Plan's search field (type words, or describe what you remember and press Ask \(Brain.name) to find it), the conversation of the session in front in Build, or the session list.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Layout") {
                Text("Column widths, the order of the sidebar, folded sections and where panels sit are remembered. Put them back the way Mindmill comes when something ends up in a bad place.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ChipRow(spacing: 8, alignment: .top) {
                    ForEach(LayoutReset.Screen.allCases, id: \.self) { screen in
                        Button("Reset \(screen.title)") { model.resetLayout([screen]) }
                    }
                    Button("Reset All Layouts") { model.resetLayout(LayoutReset.Screen.allCases) }
                }
            }
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MeetingSettingsView: View {
    @AppStorage(AppSettingsKeys.transcriptLanguage) private var language = LiveTranscriber.auto
    @AppStorage(AppSettingsKeys.transcriptMicrophone) private var microphone = true
    @AppStorage(AppSettingsKeys.transcriptComputerAudio) private var computerAudio = true
    @AppStorage(AppSettingsKeys.transcriptConsentAcknowledged) private var consentAcknowledged = false
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Language", selection: $language) {
                    ForEach(LiveTranscriber.languages, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle("Your microphone", isOn: $microphone)
                Toggle("The call (computer audio)", isOn: $computerAudio)
                Toggle("Don't remind me to tell the attendees", isOn: $consentAcknowledged)
                Text("Audio is turned into text on this Mac and never stored or sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("\(model.brainName) in meetings") {
                Text("Following a window or screen shows \(model.brainName) each new slide unless you turn it off for that meeting. The model for live meetings is under AI.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Every keyboard shortcut: read from the menus, so the list is always what KB does, plus the keys that work
/// inside meetings and sessions.
struct ShortcutsSettingsView: View {
    @State private var groups: [KBShortcuts.Group] = []
    @State private var query = ""

    var body: some View {
        Form {
            Section {
                TextField("Search shortcuts", text: $query).textFieldStyle(.roundedBorder)
            }
            ForEach(filtered, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items, id: \.self) { item in
                        LabeledContent(item.title) {
                            Text(item.keys)
                                .font(.body.monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
            Section {
                Text("Any menu command can get a shortcut of your own in System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts, using its exact menu title. It shows up here too.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
        .frame(width: 560, height: 600)
        .onAppear { groups = KBShortcuts.menuGroups() + [KBShortcuts.inViews] }
    }

    private var filtered: [KBShortcuts.Group] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return groups }
        return groups.compactMap { g in
            let items = g.items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.keys.contains(q) }
            return items.isEmpty ? nil : KBShortcuts.Group(title: g.title, items: items)
        }
    }
}

enum KBShortcuts {
    struct Item: Hashable { let title: String; let keys: String }
    struct Group { let title: String; let items: [Item] }

    /// The menu bar's commands that have a key, by menu.
    @MainActor
    static func menuGroups() -> [Group] {
        guard let bar = NSApp.mainMenu else { return [] }
        return bar.items.compactMap { top in
            guard let menu = top.submenu else { return nil }
            var items: [Item] = []
            var seen = Set<String>()
            func walk(_ m: NSMenu) {
                for i in m.items where !i.isSeparatorItem && !i.isHidden {
                    if let sub = i.submenu { walk(sub) }
                    let title = i.title.trimmingCharacters(in: .whitespaces)
                    guard !i.keyEquivalent.isEmpty, !title.isEmpty, seen.insert(title).inserted else { continue }
                    items.append(Item(title: title, keys: keys(i.keyEquivalent, i.keyEquivalentModifierMask)))
                }
            }
            walk(menu)
            let name = top.title.isEmpty ? menu.title : top.title
            return items.isEmpty ? nil : Group(title: name == "KB" ? "KB" : name, items: items)
        }
    }

    static func keys(_ key: String, _ mods: NSEvent.ModifierFlags) -> String {
        var out = ""
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option) { out += "⌥" }
        let upper = key.count == 1 && key.uppercased() == key && key.lowercased() != key
        if mods.contains(.shift) || upper { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }
        let names: [String: String] = ["\r": "↩", "\u{1b}": "⎋", "\t": "⇥", " ": "Space", "\u{7f}": "⌫",
                                       "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→"]
        return out + (names[key] ?? key.uppercased())
    }

    static let inViews = Group(title: "Inside meetings and sessions", items: [
        Item(title: "Start the meeting, or Done", keys: "⌘↩"),
        Item(title: "Next match in a session's find bar", keys: "↩"),
        Item(title: "Previous match", keys: "⇧↩"),
        Item(title: "Close the find bar", keys: "⎋"),
    ])
}

struct AboutSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "–"
        let commit = info["KBGitCommit"] as? String
        let built = info["KBBuildDate"] as? String
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mindmill").font(.title.weight(.semibold))
                        Text("Version \(version) (\(build))" + (commit.map { " · \($0)" } ?? "")).foregroundStyle(.secondary)
                        if let built { Text("Built \(built)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text("Your knowledge base, meetings, work items and \(Brain.name) sessions in one place. Plan is for knowing and deciding; Build is for getting it done.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Where things are") {
                pathRow("Knowledge base", model.rootURL.path)
                pathRow("Plugin", KBConfig.expandTilde(model.pluginRootPath))
                pathRow("App data", FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("KB").path)
                switch model.claudeAvailability {
                case .found(let url): pathRow("claude CLI", url.path)
                case .resolving: LabeledContent("claude CLI", value: "Looking…")
                case .missing: LabeledContent("claude CLI", value: "Not found")
                }
            }
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pathRow(_ title: String, _ path: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(KBConfig.abbreviateTilde(path)).font(.callout.monospaced()).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
    }
}
