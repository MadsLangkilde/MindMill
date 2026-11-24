import AppKit
import KBCore
import KBEngine
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

/// Scans run in the engine (`ScanRunner`); these are what the views call.
extension AppModel {
    var scanDirectory: URL { engine.scans.directory }

    static let scanTools = ScanRunner.tools

    var scans: [ScanRun] { engine.scans.list }
    var scanApplying: Set<String> { engine.scans.applying }
    var scanActivity: [String: String] { engine.scans.activity }

    func loadScansIfNeeded() { engine.scans.loadIfNeeded() }

    func reloadScans() { engine.scans.reload() }

    func scan(_ id: String) -> ScanRun? { engine.scans.scan(id) }

    func isScanning(_ id: String) -> Bool { engine.scans.isScanning(id) }

    func scans(group: String) -> [ScanRun] { engine.scans.scans(group: group) }

    func pendingFindings(group: String) -> Int { engine.scans.pendingFindings(group: group) }

    /// The scopes of the project `group` that have a repository, wide scope excluded.
    func repoScopes(group: String) -> [KBProject] {
        (index.groups.first { $0.id == group }?.scopes ?? []).compactMap { index.project($0) }.filter { !$0.wide }
    }

    func startScans(scopes: [String], kinds: [ScanKind], sources: [ScanSource], focus: String) {
        engine.scans.start(scopes: scopes, kinds: kinds, sources: sources, focus: focus)
    }

    func stopScan(_ id: String) { engine.scans.stop(id) }

    func applyFindings(run: String, ids: [String]) { engine.scans.apply(run: run, ids: ids) }

    func dismissFindings(run: String, ids: [String]) { engine.scans.dismiss(run: run, ids: ids) }

    func deleteScan(_ id: String) { engine.scans.delete(id) }

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

    var registryURL: URL { KBLayout.home(root: rootURL).appendingPathComponent("kb.json") }

    func editRegistry(_ change: (inout Registry) -> Void) -> Bool {
        do {
            var r = (try? Registry.load(registryURL)) ?? Registry()
            change(&r)
            try r.save(root: rootURL)
            reload()
            remoteProjectsChanged()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
