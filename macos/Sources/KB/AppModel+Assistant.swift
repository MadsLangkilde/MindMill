import Foundation
import KBCore

extension WorkSession {
    var isAssistant: Bool { about == SessionRecord.assistantAbout }
}

/// The general assistant: a Plan session with every Mindmill action as a tool, for when the user doesn't know where
/// something is, or is on the phone.
extension AppModel {
    /// The most recent assistant session (in `scope` when given), or a new one when there is none or `new` is set.
    func assistantSession(scope: String? = nil, new: Bool = false, show: Bool) async -> (session: WorkSession, created: Bool) {
        loadSessionsIfNeeded()
        _ = await actionServer.ready()
        let wanted = scope.flatMap { index.project($0) != nil ? $0 : nil }
        if !new, let r = SessionRecord.latestAssistant(sessions.map(\.record), scope: wanted),
           let s = sessions.first(where: { $0.id == r.id }) {
            if show { openPlanSession(s) }
            return (s, false)
        }
        let s = newSession(title: "Assistant", project: wanted ?? projectID, about: SessionRecord.assistantAbout, show: false, space: .plan)
        if show { openPlanSession(s) }
        return (s, true)
    }

    func newAssistantSession() {
        Task { _ = await assistantSession(new: true, show: true) }
    }
}
