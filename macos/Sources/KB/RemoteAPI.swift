import Foundation
import KBCore
import KBEngine

/// What a paired phone can ask the Mac for. Every method is listed in docs/remote-api.md; `kb.run` reaches anything
/// the `kb` command can do that has no method of its own yet.
extension AppModel {
    func startRemoteIfEnabled() {
        registerRemoteMethods()
        engine.onBinaryFrame = { [weak self] frame, client in self?.remoteBinary(frame, from: client) }
        remote.push = { [weak self] note, devices in self?.pusher.send(note, to: devices) }
        remote.pushReady = { [weak self] in self?.pusher.isSetUp ?? false }
        if UserDefaults.standard.bool(forKey: RemoteServer.enabledKey) { remote.start() }
        syncLidAwakeFlag()
    }

    /// The methods the engine can't answer by itself on a Mac: meetings still live in the app.
    func registerRemoteMethods() {
        let m = engine.methods
        m.register(prefix: "meeting.") { method in
            { [unowned self] _, p in try await orUnknown(method, remoteMeeting(method, p)) }
        }
    }

    private func orUnknown(_ method: String, _ result: JSONValue?) throws -> JSONValue {
        guard let result else {
            throw RemoteError(code: "unknown_method", message: "The Mac doesn't know \(method). Update Mindmill on the Mac.")
        }
        return result
    }

    func setRemoteEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: RemoteServer.enabledKey)
        if on { startRemoteIfEnabled() } else { remote.stop(); syncLidAwakeFlag() }
        syncBackgroundAgents()
    }

    static func remoteSummary(_ e: KBEntry) -> JSONValue { RemotePayloads.entrySummary(e) }

    func sessionArchived(_ s: WorkSession) -> Bool { engine.sessions.sessionArchived(s) }

    func remoteSession(_ s: WorkSession) -> JSONValue { engine.sessionJSON(s) }

    /// The Plan conversations that live elsewhere (meeting chats, goal coaches, Ask), for the engine's `sessions.list`.
    func linkedSessionItems(scope: String?) -> [SessionHub.LinkedItem] {
        loadMeetingChatsIfNeeded()
        return linkedConversations.map(PlanItem.linked)
            .filter { item in scope.map { PlanSessions.shows(project: item.project, about: item.about, in: $0, index: index) } ?? true }
            .map { SessionHub.LinkedItem(updated: $0.updated, archived: isArchived($0), json: remoteItem($0)) }
    }

    func remoteItem(_ item: PlanItem) -> JSONValue {
        let c: LinkedConversation
        switch item {
        case .session(let s): return remoteSession(s)
        case .linked(let linked): c = linked
        }
        let screen: String
        switch c.place {
        case .meeting: screen = "meeting"
        case .goals: screen = "goals"
        case .ask: screen = "ask"
        }
        var o: [String: JSONValue] = [
            "id": .string(c.id), "title": .string(c.title), "space": "plan", "role": "linked",
            "scope": c.project.map(JSONValue.string) ?? .null,
            "state": .string(c.busy ? CrewSessionState.working.rawValue : CrewSessionState.stopped.rawValue),
            "busy": .bool(c.busy), "updated": .number(c.updated.timeIntervalSince1970), "count": .number(Double(c.count)),
            "archived": .bool(isArchived(item)), "needsYou": false, "kind": .string(c.kind.rawValue),
            "kindTitle": .string(c.kind.title), "link": ["screen": .string(screen), "id": .string(c.target)],
        ]
        if let origin = c.origin { o["origin"] = .string(origin) }
        return .object(o)
    }
}
