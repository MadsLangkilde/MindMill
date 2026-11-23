import AppKit
import KBCore
import SwiftUI

/// What the Project view's detail shows.
enum ProjectPane: Equatable {
    case home
    /// The scan form, with these repositories ticked.
    case newScan([String])
    case run(String)
}

/// The Add a Project sheet: a new project, or more repositories for `project`.
struct AddProjectRequest: Identifiable {
    let id = UUID()
    var project: String?
}

extension AppModel {
    var scanDirectory: URL { ScanDir.url() }

    static let scanTools = ["Read", "Grep", "Glob", "Bash(kb:*)", "Bash(git log:*)", "Bash(git -C:*)", "Bash(git show:*)",
                            "Bash(git blame:*)", "Bash(ls:*)"]

    func loadScansIfNeeded() {
        guard !scansLoaded else { return }
        scansLoaded = true
        reloadScans()
    }

    func reloadScans() {
        scansLastRead = Date()
        let fresh = ScanRun.loadAll(dir: scanDirectory)
        if fresh != scans { scans = fresh }
    }

    /// While a scan runs, its findings show up as it records them.
    func scanTick() {
        guard !scanChats.isEmpty, Date().timeIntervalSince(scansLastRead) > 2 else { return }
        reloadScans()
    }

    func scan(_ id: String) -> ScanRun? { scans.first { $0.id == id } }

    func isScanning(_ id: String) -> Bool { scanChats[id] != nil && !(scan(id)?.isFinished ?? true) }

    /// Scans of the project `group`'s scopes, newest first.
    func scans(group: String) -> [ScanRun] {
        let ids = Set(index.groups.first { $0.id == group }?.scopes ?? [])
        return scans.filter { ids.contains($0.scope) }
    }

    func pendingFindings(group: String) -> Int {
        scans(group: group).reduce(0) { $0 + $1.pending.count }
    }

    /// The scopes of the project `group` that have a repository, wide scope excluded.
    func repoScopes(group: String) -> [KBProject] {
        (index.groups.first { $0.id == group }?.scopes ?? []).compactMap { index.project($0) }.filter { !$0.wide }
    }

    // MARK: Scanning

    func startScans(scopes: [String], kinds: [ScanKind], sources: [ScanSource], focus: String) {
        guard case .found = claudeAvailability else {
            errorMessage = claudeMissingExplanation
            return
        }
        Task {
            var first: String?
            for scope in scopes {
                if let id = await startScan(scope: scope, kinds: kinds, sources: sources, focus: focus), first == nil { first = id }
            }
            reloadScans()
            if let first { projectPane = .run(first) }
        }
    }

    private func startScan(scope: String, kinds: [ScanKind], sources: [ScanSource], focus: String) async -> String? {
        guard let p = index.project(scope), let checkout = ScopeRepo.of(paths: p.paths).checkout else {
            errorMessage = "\(index.project(scope)?.title ?? scope) has no repository on this Mac. Locate it first."
            return nil
        }
        var args = ["scan", "new", "--scope", scope, "--kinds", kinds.map(\.rawValue).joined(separator: ","),
                    "--sources", sources.map(\.rawValue).joined(separator: ",")]
        if !focus.trimmingCharacters(in: .whitespaces).isEmpty { args += ["--focus", focus] }
        let id: String
        do {
            id = try await cli.run(args).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            errorMessage = (error as? KBCLIError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription
            return nil
        }
        reloadScans()
        guard let run = scan(id) else { return nil }
        let group = index.group(of: scope)
        let siblings = (group?.scopes ?? []).compactMap { index.project($0) }
        let wide = siblings.first { $0.wide && $0.id != scope }?.id
        let others = siblings.filter { !$0.wide && $0.id != scope }.map(\.id)
        let hasOverview = index.entry(EntryID(project: scope, section: .overview, stem: "overview")) != nil
        let prompt = ScanPrompt.system(run: run, scopeTitle: p.title, project: group?.title ?? p.title, wideScope: wide,
                                       otherScopes: others, checkout: checkout.path, hasOverview: hasOverview)
        guard var launch = launch(prompt: prompt, sessionID: UUID().uuidString.lowercased(), resume: false, model: defaultModel,
                                  cwd: checkout, tools: Self.scanTools) else { return nil }
        launch.disallowedTools = ["Write", "Edit", "NotebookEdit"]
        let chat = ClaudeChat()
        chat.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.scanEvent(id, event) }
        }
        do {
            try chat.start(launch, mode: "scan")
        } catch {
            _ = try? await cli.run(["scan", "done", "--run", id, "--failed", "--note", error.localizedDescription])
            reloadScans()
            return nil
        }
        scanChats[id] = chat
        chat.send(ScanPrompt.start, tag: "scan", show: false)
        return id
    }

    private func scanEvent(_ id: String, _ event: ClaudeEvent) {
        switch event {
        case .toolDetail(_, let summary):
            scanActivity[id] = summary
        case .turnResult(let text, let isError, _):
            finishScan(id, note: text, failed: isError)
        case .exited:
            finishScan(id, note: "\(Brain.name) stopped before the scan was done.", failed: true)
        default:
            break
        }
    }

    /// Ends a scan's session; marks the run done when the session didn't.
    private func finishScan(_ id: String, note: String, failed: Bool) {
        guard let chat = scanChats.removeValue(forKey: id) else { return }
        chat.onEvent = nil
        chat.stop()
        scanActivity[id] = nil
        reloadScans()
        let title = scan(id).flatMap { index.project($0.scope)?.title } ?? "the repository"
        if scan(id)?.isFinished == false {
            let line = note.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            Task {
                _ = try? await cli.run(["scan", "done", "--run", id, "--note", String(line.prefix(300))] + (failed ? ["--failed"] : []))
                reloadScans()
                announce(id, title: title)
            }
        } else {
            announce(id, title: title)
        }
    }

    private func announce(_ id: String, title: String) {
        guard let run = scan(id) else { return }
        notice = run.failed ? "The scan of \(title) stopped: \(run.note)"
            : "The scan of \(title) found \(run.pending.count) thing\(run.pending.count == 1 ? "" : "s") to review."
    }

    func stopScan(_ id: String) {
        guard let chat = scanChats.removeValue(forKey: id) else { return }
        chat.onEvent = nil
        chat.stop()
        scanActivity[id] = nil
        Task {
            _ = try? await cli.run(["scan", "done", "--run", id, "--note", "Stopped by you."])
            reloadScans()
        }
    }

    func applyFindings(run: String, ids: [String]) {
        guard !ids.isEmpty else { return }
        scanApplying.formUnion(ids)
        Task {
            defer { scanApplying.subtract(ids) }
            do {
                let out = try await cli.run(["scan", "apply", "--run", run] + ids)
                let n = out.split(whereSeparator: \.isNewline).count
                reload()
                reloadScans()
                notice = "Added \(n) to the knowledge base."
            } catch {
                reloadScans()
                errorMessage = (error as? KBCLIError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription
            }
        }
    }

    func dismissFindings(run: String, ids: [String]) {
        guard !ids.isEmpty else { return }
        Task {
            _ = try? await cli.run(["scan", "dismiss", "--run", run] + ids)
            reloadScans()
        }
    }

    /// Throws a finished scan away, with what it found and didn't add.
    func deleteScan(_ id: String) {
        guard !isScanning(id) else { return }
        try? FileManager.default.removeItem(at: scanDirectory.appendingPathComponent("\(id).jsonl"))
        if projectPane == .run(id) { projectPane = .home }
        reloadScans()
    }

    /// Opens a finding's entry once it is in the KB.
    func openFinding(_ f: ScanFinding) {
        if f.kind == .docs {
            selectSidebar(.section(.architecture))
            return
        }
        guard let id = EntryID(f.entry) else { return }
        if index.project(id.project) != nil, id.project != projectID { selectProject(id.project) }
        selectSidebar(.section(id.section))
        selectEntry(id)
    }

    // MARK: Projects and repositories

    private var registryURL: URL { KBLayout.home(root: rootURL).appendingPathComponent("kb.json") }

    func editRegistry(_ change: (inout Registry) -> Void) -> Bool {
        do {
            var r = (try? Registry.load(registryURL)) ?? Registry()
            change(&r)
            try r.save(root: rootURL)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Adds a new project (when `title` is given) or repositories to `project`; returns the repositories' scope ids.
    func addProject(title: String?, into project: String?, repos: [(url: URL, title: String)]) -> [String] {
        var scopeIDs: [String] = []
        let ok = editRegistry { r in
            let pid = title.map { r.addProject(title: $0) } ?? project ?? ""
            for repo in repos {
                scopeIDs.append(r.addRepository(path: repo.url.path, title: repo.title, project: pid))
            }
        }
        return ok ? scopeIDs : []
    }

    func locateScope(_ scope: String) {
        let title = index.project(scope)?.title ?? scope
        guard let url = chooseFolders(message: "Where is \(title)'s repository on this Mac?", multiple: false).first else { return }
        if editRegistry({ $0.locate(scope: scope, path: url.path) }) {
            let repo = ScopeRepo.of(paths: [url.path])
            notice = repo.hasTeamFolder ? "\(title): found knowledgebase/ with \(repo.teamEntries) entries; they are in the knowledge base now."
                : "\(title) points at \(url.lastPathComponent) now."
        }
    }

    func chooseFolders(message: String, multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = multiple
        panel.message = message
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// A fresh knowledge base at the root KB is set to, for a new Mac.
    func createKnowledgeBase() {
        do {
            try Registry.createKnowledgeBase(root: rootURL)
            reload()
            startWatching()
            addProjectRequest = AddProjectRequest()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showProject(scan scopes: [String]? = nil) {
        selectSidebar(.project)
        if let scopes { projectPane = .newScan(scopes) }
    }
}
