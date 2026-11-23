import AppKit
import KBCore
import SwiftUI

extension AppModel {
    /// Runs the claude CLI with `args` in the user's home folder; nil when it isn't found.
    func runClaude(_ args: [String]) async -> CommandResult? {
        guard case .found(let exe) = claudeAvailability else { return nil }
        return await ProcessRunner().run(executable: exe, arguments: args, environment: claudeEnvironment(), stdin: nil,
                                         currentDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }
}

/// Settings → Connections: the tools KB reaches through Claude (Jira, Microsoft 365, Gmail, Slack and more), how
/// each scope tracks work, and adding a tool of your own.
struct ConnectionsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var servers: [ClaudeConnectors.Server] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var adding = false
    @State private var settingUp = false

    static let connectorsURL = URL(string: "https://claude.ai/settings/connectors")!

    var body: some View {
        Form {
            Section {
                Text("Mindmill reaches other tools through Claude: what Claude is connected to, Mindmill can use. Connectors you add at claude.ai (Settings → Connectors) work here too, as do tools you add below. You can also skip them: Mindmill has its own simple tracker, and mail and chat are optional.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ChipRow(spacing: 8, alignment: .top) {
                    Button { settingUp = true } label: { Label("Set Up with \(Brain.name)…", systemImage: "sparkles") }
                        .help("Pick your tracker and tools; a \(Brain.name) session checks them, helps you connect what's missing and saves Mindmill's settings")
                    Button { NSWorkspace.shared.open(Self.connectorsURL) } label: { Label("Open claude.ai Connectors", systemImage: "arrow.up.right.square") }
                    Button { adding = true } label: { Label("Add a Tool…", systemImage: "plus") }
                    Button { model.troubleshootConnections() } label: { Label("Troubleshoot with \(Brain.name)", systemImage: "stethoscope") }
                        .help("A \(Brain.name) session checks each tool, explains what's wrong and walks you through fixing it")
                    if loading { ProgressView().controlSize(.small) }
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Check again")
                        .disabled(loading)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
            Section("Work tracking per scope") {
                ForEach(model.index.projects) { p in
                    LabeledContent(p.title) {
                        HStack(spacing: 8) {
                            Text(Self.trackerTitle(model.trackerKind(p.id))).foregroundStyle(.secondary)
                            Button("Change…") { model.projectSettingsRequest = ProjectSettingsRequest(project: p.id) }
                        }
                    }
                }
                Text("Azure DevOps works directly. Jira goes through Claude's Atlassian connector. Mindmill's own tracker needs nothing: features, PBIs, bugs and tasks with a board and optional sprints, kept in the knowledge base.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Tools through \(Brain.name)") {
                ForEach(ClaudeConnectors.catalog) { service in serviceRow(service) }
            }
            let others = ClaudeConnectors.others(servers)
            if !others.isEmpty {
                Section("Also connected") {
                    ForEach(others) { s in serverRow(s) }
                }
            }
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
        .frame(width: 600, height: 620)
        .onAppear { if !loaded { refresh() } }
        .sheet(isPresented: $adding) { AddToolSheet { refresh() } }
        .sheet(isPresented: $settingUp) { SourceSetupSheet() }
    }

    static func trackerTitle(_ kind: String) -> String {
        switch kind {
        case "azure-devops": return "Azure DevOps"
        case "jira": return "Jira (through \(Brain.name))"
        case "local": return "Mindmill's own tracker"
        case "github": return "GitHub"
        default: return "None"
        }
    }

    private func serviceRow(_ service: ClaudeConnectors.Service) -> some View {
        let found = ClaudeConnectors.servers(for: service, in: servers)
        let best = found.first { $0.status == .connected } ?? found.first
        return AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 240) {
            statusDot(best?.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.title).font(.body.weight(.medium))
                Text(service.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(service.areas.map(\.title).joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
                if let problem = ClaudeConnectors.problems(servers).first(where: { $0.service.id == service.id }) {
                    Text(problem.advice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                switch best?.status {
                case .connected?: Text("Connected").foregroundStyle(.green)
                case .needsAuth?:
                    Button("Sign In…") { signIn(best!) }
                case .failed?, .unknown?:
                    Button("Fix…") { signIn(best!) }
                case nil:
                    Button("Connect…") { NSWorkspace.shared.open(Self.connectorsURL) }
                        .help("Add it under claude.ai → Settings → Connectors; it then shows here")
                }
            }
            .fixedSize()
        }
    }

    private func serverRow(_ s: ClaudeConnectors.Server) -> some View {
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 240) {
            statusDot(s.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.displayName).font(.body.weight(.medium))
                Text(s.fromClaudeAI ? "claude.ai connector" : s.fromPlugin ? "From a Claude Code plugin" : s.target)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if s.status != .connected { Button("Sign In…") { signIn(s) } }
                if !s.fromClaudeAI && !s.fromPlugin {
                    Button("Remove") { remove(s) }
                }
            }
            .fixedSize()
        }
    }

    private func statusDot(_ status: ClaudeConnectors.Server.Status?) -> some View {
        Circle()
            .fill(status == .connected ? Color.green : status == nil ? Color.secondary.opacity(0.3) : Color.orange)
            .frame(width: 9, height: 9)
            .help(status == .connected ? "Connected" : status == nil ? "Not connected" : "Needs attention")
    }

    private func refresh() {
        loading = true
        error = nil
        Task {
            let r = await model.runClaude(["mcp", "list"])
            loading = false
            loaded = true
            guard let r else { error = model.claudeMissingExplanation; return }
            servers = ClaudeConnectors.parse(r.stdout)
            if !servers.isEmpty {
                model.connectorServers = servers
                model.connectorsChecked = Date()
            }
            if servers.isEmpty, r.status != 0 { error = r.stderr.isEmpty ? "claude mcp list failed." : r.stderr }
        }
    }

    /// claude.ai connectors sign in at claude.ai; others in Claude Code's /mcp, in Terminal.
    private func signIn(_ s: ClaudeConnectors.Server) {
        if s.fromClaudeAI {
            NSWorkspace.shared.open(Self.connectorsURL)
        } else {
            let script = "tell application \"Terminal\" to do script \"claude /mcp\"\ntell application \"Terminal\" to activate"
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    private func remove(_ s: ClaudeConnectors.Server) {
        Task {
            let r = await model.runClaude(["mcp", "remove", s.name, "--scope", "user"])
            if r?.status != 0 { error = r?.stderr.isEmpty == false ? r!.stderr : "Could not remove \(s.name)." }
            refresh()
        }
    }
}

/// A tool of your own for Claude: a remote MCP server by URL, added for every project.
struct AddToolSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onDone: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var transport = "http"
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Tool for \(Brain.name)").font(.title3.weight(.semibold))
            Text("Most tools are easiest to add at claude.ai → Settings → Connectors. Use this for a tool that gives you an MCP server address (often in its docs under “MCP” or “AI assistants”).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. jira"))
                TextField("Server address", text: $url, prompt: Text("https://…"))
                Picker("Connection", selection: $transport) {
                    Text("HTTP").tag("http")
                    Text("SSE").tag("sse")
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .multilineTextAlignment(.leading)
            .frame(height: 170)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || ClaudeConnectors.safeName(name).isEmpty || URL(string: url)?.scheme?.hasPrefix("http") != true)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func add() {
        working = true
        error = nil
        Task {
            let r = await model.runClaude(["mcp", "add", "--transport", transport, "--scope", "user",
                                           ClaudeConnectors.safeName(name), url.trimmingCharacters(in: .whitespaces)])
            working = false
            if let r, r.status == 0 {
                onDone()
                dismiss()
            } else {
                error = r.map { $0.stderr.isEmpty ? $0.stdout : $0.stderr } ?? model.claudeMissingExplanation
            }
        }
    }
}
