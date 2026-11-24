import KBCore
import KBEngine
import SwiftUI

/// Keeps follow-ups current: when facts, decisions, meetings or other follow-ups are saved, a background Claude
/// session closes the follow-ups they settle (marked as closed by KB, so the user can reopen them) and notes what
/// changes the ones that stay open. The check runs in the engine (`engine.plan`).
extension AppModel {
    func followupWatchIndexChanged() { engine.plan.followupWatchIndexChanged() }

    var isCheckingFollowups: Bool { engine.plan.isCheckingFollowups }

    var claudeAvailable: Bool { if case .found = claudeAvailability { return true } else { return false } }

    /// Checks a scope's open follow-ups now against what was saved there and product-wide in the last 30 days.
    func checkFollowupsNow(project: String) {
        if let nothing = engine.plan.checkFollowupsNow(project: project) { notice = nothing }
    }

    func runFollowupCheck() { engine.plan.runFollowupCheck() }
}
