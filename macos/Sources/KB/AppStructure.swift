import Foundation
import KBCore
import KBEngine

/// The sidebar of each mode as data, for `app.structure` on the phone: the engine builds it, the app adds what only
/// it knows (sessions, factories, pull requests, scans, which of today's items show).
extension AppModel {
    func sidebarBadge(_ section: KBSection, project: String) -> (count: Int, needsYou: Bool) {
        engine.sidebarBadge(section, project: project)
    }

    static let planningOrderKey = MindmillEngine.planningOrderKey
    static let workOrderKey = MindmillEngine.workOrderKey

    func appStructure(scope: String?) -> JSONValue { engine.appStructure(scope: scope) }

    func structureExtras(scope: String?) -> StructureExtras {
        var x = engine.buildStructureExtras(scope: scope)
        x.todayOpen = dailyPlan?.today.filter { $0.done == false && !$0.notRelevant && todayShows($0) }.count ?? 0
        return x
    }
}
