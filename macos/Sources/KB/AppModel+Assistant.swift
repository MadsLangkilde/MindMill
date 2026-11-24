import Foundation
import KBCore
import KBEngine

/// The general assistant: a Plan session with every Mindmill action as a tool, for when the user doesn't know where
/// something is, or is on the phone.
extension AppModel {
    /// The most recent assistant session (in `scope` when given), or a new one when there is none or `new` is set.
    func assistantSession(scope: String? = nil, new: Bool = false, show: Bool) async -> (session: WorkSession, created: Bool) {
        _ = await actionServer.ready()
        let found = await engine.sessions.assistant(scope: scope, new: new)
        if show { openPlanSession(found.session) }
        return found
    }

    func newAssistantSession() {
        Task { _ = await assistantSession(new: true, show: true) }
    }
}
