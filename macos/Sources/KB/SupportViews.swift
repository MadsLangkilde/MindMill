import AppKit
import KBCore
import KBEngine
import SwiftUI
import WebKit

struct MarkdownWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    let onLink: (String) -> Void
    /// When set, the page is as tall as its content and reports that height, so an enclosing ScrollView scrolls
    /// it together with what is above it; the web view passes the scroll wheel on instead of scrolling itself.
    var contentHeight: Binding<CGFloat>?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        if contentHeight != nil {
            let script = """
            (function() {
              function report() {
                var b = document.body, cs = getComputedStyle(b);
                var h = b.getBoundingClientRect().height + parseFloat(cs.marginTop) + parseFloat(cs.marginBottom);
                window.webkit.messageHandlers.height.postMessage(Math.ceil(h) + 4);
              }
              new ResizeObserver(report).observe(document.body);
              window.addEventListener('load', report);
              report();
            })();
            """
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            config.userContentController.add(WeakScriptHandler(context.coordinator), name: "height")
        }
        let view = PassThroughWebView(frame: .zero, configuration: config)
        view.passesScroll = contentHeight != nil
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = contentHeight == nil
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onLink = onLink
        context.coordinator.baseURL = baseURL
        context.coordinator.height = contentHeight
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: baseURL)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastHTML: String?
        var baseURL: URL?
        var onLink: ((String) -> Void)?
        var height: Binding<CGFloat>?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let n = message.body as? NSNumber else { return }
            let h = CGFloat(truncating: n)
            // Outside the current view update: setting state from inside one can corrupt SwiftUI's observation.
            DispatchQueue.main.async { [weak self] in
                guard let binding = self?.height, abs(binding.wrappedValue - h) > 1 else { return }
                binding.wrappedValue = h
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.fragment != nil, let base = baseURL, url.isFileURL,
               url.standardizedFileURL.path == base.standardizedFileURL.path {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            onLink?(url.absoluteString)
        }
    }
}

/// A web view that hands scroll-wheel events to the view around it, for pages sized to their content.
final class PassThroughWebView: WKWebView {
    var passesScroll = false

    override func scrollWheel(with event: NSEvent) {
        if passesScroll { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

/// WKUserContentController keeps its handlers strongly; this keeps the coordinator from leaking.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: Timeline

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject

    var body: some View {
        let full = model.index.decisionTimeline(project: project.id)
        let query = model.listQuery(.decisions)
        let chains = query.isEmpty ? full.chains : full.chains.filter { $0.entries.contains { $0.matches(query) } }
        let standalone = query.isEmpty ? full.standalone : full.standalone.filter { $0.matches(query) }
        if full.chains.isEmpty && full.standalone.isEmpty {
            ListEmptyState(title: "No decisions", systemImage: "arrow.triangle.branch",
                           message: "\(project.title) has no decisions yet.")
        } else if chains.isEmpty && standalone.isEmpty {
            ListEmptyState(title: "No decisions match “\(query)”", systemImage: "magnifyingglass")
        } else {
            List(selection: model.entrySelection) {
                if chains.isEmpty && query.isEmpty {
                    Section("Supersede chains") {
                        Text("No decision in \(project.title) has been superseded yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(chains.enumerated()), id: \.element.id) { n, chain in
                    Section {
                        ForEach(Array(chain.entries.enumerated()), id: \.element.id) { i, entry in
                            ChainNodeRow(entry: entry, isFirst: i == 0, isLast: i == chain.entries.count - 1)
                                .tag(entry.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text(n == 0 ? "Supersede chains" : " ")
                    }
                }
                if !standalone.isEmpty || query.isEmpty {
                    Section("Not superseded") {
                        ForEach(standalone) { entry in
                            EntryRow(entry: entry).tag(entry.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .navigationSubtitle("Decisions Timeline")
        }
    }
}

struct ChainNodeRow: View {
    let entry: KBEntry
    let isFirst: Bool
    let isLast: Bool

    private var color: Color {
        switch entry.status {
        case .superseded: return .gray
        case .proposed: return .orange
        default: return .accentColor
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.gray.opacity(0.5))
                    .frame(width: 2, height: 11)
                ZStack {
                    Circle().fill(entry.status == .superseded ? Color.clear : color)
                    Circle().strokeBorder(color, lineWidth: 2)
                }
                .frame(width: 11, height: 11)
                Rectangle()
                    .fill(isLast ? Color.clear : Color.gray.opacity(0.5))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                        .font(.headline)
                        .strikethrough(entry.status == .superseded)
                        .foregroundStyle(entry.status == .superseded ? .secondary : .primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    StatusBadge(status: entry.status)
                }
                Text(DateText.display(entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !isLast {
                    Label("superseded by", systemImage: "arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

// MARK: New entry

struct NewEntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NewEntryRequest
    @State private var title = ""
    @State private var scopes: Set<String> = []

    private var projectTitle: String { model.index.project(request.project)?.title ?? request.project }

    private var fileName: String {
        let slug = Slug.make(title)
        return request.section.isDated ? "\(KBDate.today())-\(slug).md" : "\(slug).md"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.supersedes == nil ? "New \(request.section.singularTitle)" : "Supersede Decision")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    Text("in ") + Text(projectTitle).bold()
                }
                .font(.callout)
            }
            if let old = request.supersedes {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replaces").font(.caption).foregroundStyle(.secondary)
                    Text(model.index.entry(old)?.title ?? old.rawValue).strikethrough()
                    Text("The old decision is marked superseded when you first save the new one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .onSubmit(create)
            let siblings = model.index.siblings(of: request.project)
            if !siblings.isEmpty, request.section != .overview {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Also in").font(.caption).foregroundStyle(.secondary)
                    ScopeToggles(scopes: siblings, selected: $scopes,
                                 suggested: Set(model.suggestedScopes(text: title, in: request.project).map(\.id)))
                }
            }
            Text("projects/\(request.project)/\(request.section.rawValue)/\(fileName)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.supersedes == nil ? "Create" : "Write New Decision", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { title = request.suggestedTitle }
    }

    private func create() {
        let t = KBEntry.oneLine(title)
        guard !t.isEmpty else { return }
        dismiss()
        var r = request
        r.scopes = Array(scopes)
        model.createEntry(r, title: t)
    }
}

// MARK: Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var path = ""
    @AppStorage(AppModel.myNameKey) private var myName = ""

    private var status: (ok: Bool, text: String) {
        let url = KBConfig.rootURL(for: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return (false, "Folder does not exist")
        }
        guard FileManager.default.fileExists(atPath: KBLayout.home(root: url).appendingPathComponent("kb.json").path) else {
            return (false, "No kb.json in this folder or its shared/ folder")
        }
        return (true, KBLayout.isSplit(root: url) ? "Knowledge base found (private here, team knowledge in each repo)" : "Knowledge base found")
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Knowledge base root", text: $path, prompt: Text(KBConfig.defaultRootPath))
                        .font(.body.monospaced())
                    Button("Choose…", action: choose)
                }
                Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.ok ? .green : .orange)
                    .font(.callout)
                Text("Stored in \(KBConfig.abbreviateTilde(KBConfig.defaultConfigURL.path)), shared with the kb plugin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.rootOverride {
                    Text("This launch uses \(model.rootPath) from --root or KB_ROOT. Applying writes the config file and switches to it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Knowledge Base")
            }
            Section {
                TextField("Your name", text: $myName, prompt: Text(model.tracker?.me ?? "As people write it"))
                Text("Follow-ups you own, or with no owner, count as on you. Empty uses your Azure DevOps name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("You")
            }
            HStack {
                Spacer()
                Button("Apply") { model.changeRoot(to: path) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty || (path == model.rootPath && !model.rootOverride))
            }
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { path = model.rootPath }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = KBConfig.rootURL(for: path)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            path = KBConfig.abbreviateTilde(url.path)
        }
    }
}
