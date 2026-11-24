import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    /// The scope's tracker kind from its settings: azure-devops, jira, local, github or none.
    func trackerKind(_ scope: String) -> String { engine.tracker.kind(scope) }

    func loadLocalTracker(_ scope: String) {
        guard localTrackers[scope] == nil else { return }
        localTrackers[scope] = LocalTracker.load(scope: scope, root: rootURL)
    }

    func localTracker(_ scope: String) -> LocalTracker { localTrackers[scope] ?? LocalTracker() }

    /// Changes the scope's tracker and saves it.
    func editLocalTracker(_ scope: String, _ change: (inout LocalTracker) -> Void) {
        var t = localTrackers[scope] ?? LocalTracker.load(scope: scope, root: rootURL)
        change(&t)
        localTrackers[scope] = t
        do {
            try t.save(scope: scope, root: rootURL)
        } catch {
            errorMessage = "Could not save the work items: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func addLocalItem(_ scope: String, _ kind: LocalTracker.Kind, title: String, parent: Int? = nil) -> Int {
        var id = 0
        editLocalTracker(scope) { t in
            let sprint = t.useSprints && kind != .feature ? (t.currentSprint(today: KBDate.today())?.name ?? "") : ""
            id = t.add(kind, title: title, parent: parent, sprint: sprint)
        }
        return id
    }
}
