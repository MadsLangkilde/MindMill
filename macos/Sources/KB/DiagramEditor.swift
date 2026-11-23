import AppKit
import KBCore
import SwiftUI

struct DiagramRequest: Identifiable {
    let id = UUID()
    var title: String
    var source: String
    /// The scope whose repository Claude reads when it draws.
    var project: String?
    let onSave: (String) -> Void
}

/// Mermaid source with a live preview, templates, and Claude to draw or change it from a description.
struct DiagramEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: DiagramRequest
    @State private var source = ""
    @State private var preview = ""
    @State private var ask = ""
    @State private var chat = ClaudeChat()
    @State private var drawError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(request.title).font(.title2.weight(.semibold))
                Spacer()
                Menu("Start From") {
                    ForEach(MermaidBlocks.templates, id: \.name) { t in
                        Button(t.name) { source = t.source }
                    }
                }
                .fixedSize()
                Link("Mermaid Syntax", destination: URL(string: "https://mermaid.js.org/intro/syntax-reference.html")!)
                    .font(.callout)
            }
            HSplitView {
                TextEditor(text: $source)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .frame(minWidth: 260)
                MarkdownWebView(html: MarkdownRenderer.page(body: MarkdownRenderer().render("```mermaid\n\(preview)\n```"),
                                                            accentHex: NSColor.controlAccentColor.hexString),
                                baseURL: nil, onLink: { model.openLink($0) })
                    .frame(minWidth: 300)
            }
            .frame(minHeight: 340)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TextField(source.isEmpty ? "Describe it: “how the app connects to a device over BLE”"
                                             : "Describe a change: “add the BFF between app and Vault”", text: $ask, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(draw)
                    if chat.isBusy { ProgressView().controlSize(.small) }
                    Button("Draw with \(Brain.name)", action: draw)
                        .disabled(ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isBusy)
                }
                if let drawError { Text(drawError).font(.caption).foregroundStyle(.red) }
            }
            HStack {
                Text("The preview draws with Mermaid, loaded from the web.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    request.onSave(source)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 900, minHeight: 560, idealHeight: 640)
        .onAppear {
            source = request.source
            preview = request.source
        }
        .task(id: source) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { preview = source }
        }
        .onDisappear { chat.stop() }
    }

    private func draw() {
        let want = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty, !chat.isBusy else { return }
        drawError = nil
        if !chat.isRunning {
            let project = request.project.flatMap { model.index.project($0) }
            guard let launch = model.launch(prompt: ClaudeModes.diagram, sessionID: UUID().uuidString.lowercased(), resume: false,
                                            model: model.defaultModel,
                                            cwd: ClaudeLaunch.workingDirectory(project: project, root: model.rootURL),
                                            tools: ClaudeLaunch.bridgeTools + ["Read", "Grep", "Glob", "Bash(kb:*)"]) else {
                drawError = model.claudeMissingExplanation
                return
            }
            do { try chat.start(launch, mode: "diagram") } catch {
                drawError = error.localizedDescription
                return
            }
            chat.onEvent = { event in
                guard case .turnResult(let text, let isError, _) = event else { return }
                if isError {
                    drawError = text.isEmpty ? "\(Brain.name) couldn't draw it." : text
                } else if let drawn = MermaidBlocks.find(in: text).last?.source {
                    source = drawn
                    ask = ""
                } else {
                    drawError = "\(Brain.name) answered without a diagram. Try describing it differently."
                }
            }
        }
        let current = source.trimmingCharacters(in: .whitespacesAndNewlines)
        chat.send(current.isEmpty ? want : "\(want)\n\nThe current diagram:\n```mermaid\n\(current)\n```", show: false)
    }
}
