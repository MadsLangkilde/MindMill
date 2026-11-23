import Foundation
import KBCore

/// What a paired phone can ask the Mac for. Every method is listed in docs/remote-api.md; `kb.run` reaches anything
/// the `kb` command can do that has no method of its own yet.
extension AppModel {
    func startRemoteIfEnabled() {
        remote.handle = { [weak self] client, method, params in
            guard let self else { return .null }
            return try await self.remoteCall(method, params, from: client)
        }
        remote.handleBinary = { [weak self] client, data in
            guard let self, let frame = RemoteFrame.decode(data) else { return }
            self.remoteBinary(frame, from: client)
        }
        remote.onClientClosed = { [weak self] client in self?.remoteClientClosed(client) }
        if UserDefaults.standard.bool(forKey: RemoteServer.enabledKey) { remote.start() }
    }

    func setRemoteEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: RemoteServer.enabledKey)
        if on { startRemoteIfEnabled() } else { remote.stop() }
    }

    /// Tells the phones a session changed, so they fetch what's new with `session.get` and `since`.
    func remoteSessionChanged(_ s: WorkSession) {
        guard remote.isRunning, !remote.connected.isEmpty else { return }
        remote.broadcast("session.changed", ["id": .string(s.id), "count": .number(Double(s.chat.items.count)),
                                             "busy": .bool(s.chat.isBusy), "state": .string(s.crewState.rawValue)])
    }

    func remoteIndexChanged() {
        guard remote.isRunning, !remote.connected.isEmpty else { return }
        remote.broadcast("index.changed")
    }

    func remoteCall(_ method: String, _ p: JSONValue, from client: RemoteClient) async throws -> JSONValue {
        switch method {
        case "hello", "state":
            return [
                "name": .string(Host.current().localizedName ?? "Mac"),
                "version": .number(Double(RemoteMessage.version)),
                "brain": .string(brainName),
                "scope": projectID.map(JSONValue.string) ?? .null,
                "scopes": .array(index.projects.map { ["id": .string($0.id), "title": .string($0.title)] }),
                "sections": .array(KBSection.allCases.map { .string($0.rawValue) }),
            ]

        case "entries.list":
            guard let scope = p["scope"]?.string ?? projectID else { throw RemoteError.badParams("scope") }
            guard let section = p["section"]?.string.flatMap(KBSection.init(rawValue:)) else { throw RemoteError.badParams("section") }
            var list = index.entries(project: scope, section: section).filter { !$0.isDraft }
            if let q = p["query"]?.string, !q.isEmpty { list = list.filter { $0.matches(q) } }
            let tags = Set(p["tags"]?.strings ?? [])
            if !tags.isEmpty { list = list.filter { EntryTags.matches($0.tags, selected: tags) } }
            let limit = p["limit"]?.int ?? 500
            return ["entries": .array(list.prefix(limit).map(Self.remoteSummary))]

        case "entries.search":
            let q = p["query"]?.string ?? ""
            return ["entries": .array(index.search(q, project: p["scope"]?.string).flatMap(\.entries).prefix(100).map(Self.remoteSummary))]

        case "entry.get":
            let id = try entryID(p)
            let doc = try KBStore.load(id, root: rootURL)
            var fm: [String: JSONValue] = [:]
            for k in doc.frontmatter.keys {
                switch doc.frontmatter[k] {
                case .list(let l)?: fm[k] = .array(l.map(JSONValue.string))
                case .string(let s)?: fm[k] = .string(s)
                case nil: break
                }
            }
            var extra: JSONValue = [:]
            if id.section == .facts {
                extra = ["linked": .array(index.linkedFacts(of: id).map(Self.remoteSummary))]
            }
            return ["id": .string(id.rawValue), "frontmatter": .object(fm), "body": .string(doc.body), "extra": extra]

        case "entry.save":
            let id = try entryID(p)
            var doc = try KBStore.load(id, root: rootURL)
            if case .object(let fm)? = p["frontmatter"] {
                for (k, v) in fm {
                    switch v {
                    case .array(let a): doc.frontmatter.set(k, .list(a.compactMap(\.string)))
                    case .string(let s): doc.frontmatter.set(k, s.isEmpty ? nil : .string(s))
                    case .null: doc.frontmatter.set(k, nil)
                    default: break
                    }
                }
            }
            if let body = p["body"]?.string { doc.body = body }
            _ = try KBStore.save(&doc, root: rootURL)
            reload()
            return ["saved": true]

        case "entry.new":
            guard let scope = p["scope"]?.string ?? projectID, let section = p["section"]?.string,
                  let title = p["title"]?.string, !title.isEmpty else { throw RemoteError.badParams("scope, section and title") }
            var fields: [String: String] = [:]
            if case .object(let f)? = p["fields"] { for (k, v) in f { if let s = v.string { fields[k] = s } } }
            let id = try await createEntryWithCLI(scope: scope, section: section, title: title, summary: p["summary"]?.string,
                                                  tags: p["tags"]?.strings ?? [], fields: fields, body: p["body"]?.string)
            return ["id": .string(id)]

        case "inbox.approve":
            for id in p["ids"]?.strings.compactMap(EntryID.init) ?? [] { _ = try await cli.approveInbox(id) }
            reload()
            return ["done": true]

        case "inbox.reject":
            for id in p["ids"]?.strings ?? [] { _ = try await cli.run(["inbox", "reject", id]) }
            reload()
            return ["done": true]

        case "facts.proposed":
            guard let scope = p["scope"]?.string ?? projectID else { throw RemoteError.badParams("scope") }
            return ["entries": .array(factProposals(project: scope).map(Self.remoteSummary))]

        case "tracker.items":
            guard let scope = p["scope"]?.string ?? projectID else { throw RemoteError.badParams("scope") }
            var items = trackerItems(scope: scope)
            if p["mine"]?.bool == true { items = items.filter(\.mine) }
            return ["me": .string(tracker?.me ?? ""), "items": .from(items)]

        case "sessions.list":
            loadSessionsIfNeeded()
            loadMeetingChatsIfNeeded()
            let scope = p["scope"]?.string
            let withArchived = p["archived"]?.bool == true
            let build = sessions.filter { s in
                s.space == .build && (scope.map { PlanSessions.shows(project: s.project, about: s.about, in: $0, index: index) } ?? true)
            }
            let items = (planItems(scope: scope).map { ($0.updated, isArchived($0), remoteItem($0)) }
                         + build.map { ($0.updated, sessionArchived($0), remoteSession($0)) })
                .filter { withArchived || !$0.1 }
                .sorted { $0.0 > $1.0 }
            return ["sessions": .array(items.map(\.2))]

        case "session.get":
            guard let s = session(p["id"]?.string) else { throw RemoteError.notFound("No such session") }
            let since = max(0, p["since"]?.int ?? 0)
            let items = s.chat.items.dropFirst(since).map { item -> JSONValue in
                ["role": .string(item.role.rawValue), "text": .string(item.text)]
            }
            return ["session": remoteSession(s), "items": .array(items), "count": .number(Double(s.chat.items.count))]

        case "session.send":
            guard let s = session(p["id"]?.string), let text = p["text"]?.string, !text.isEmpty else { throw RemoteError.badParams("id and text") }
            send(text, in: s)
            return ["sent": true]

        case "session.new":
            let space: SessionSpace = p["space"]?.string == "build" ? .build : .plan
            let s = newSession(title: p["title"]?.string, project: p["scope"]?.string ?? projectID, message: p["message"]?.string,
                               show: false, space: space)
            return ["id": .string(s.id)]

        case "session.archive":
            guard let id = p["id"]?.string, let on = p["archived"]?.bool else { throw RemoteError.badParams("id and archived") }
            loadSessionsIfNeeded()
            loadMeetingChatsIfNeeded()
            if let item = planItem(id) {
                setArchived(item, on)
            } else if let s = session(id) {
                setArchived(s, on)
            } else {
                throw RemoteError.notFound("No such session")
            }
            return ["archived": .bool(on)]

        case "app.structure":
            return appStructure(scope: p["scope"]?.string)

        case "kb.run":
            let args = p["args"]?.strings ?? []
            guard !args.isEmpty else { throw RemoteError.badParams("args") }
            let out = try await cli.run(args, stdin: p["stdin"]?.string)
            reload()
            return ["output": .string(out)]

        default:
            if let handled = try await remoteCallMore(method, p, from: client) { return handled }
            throw RemoteError(code: "unknown_method", message: "The Mac doesn't know \(method). Update Mindmill on the Mac.")
        }
    }

    private func entryID(_ p: JSONValue) throws -> EntryID {
        guard let raw = p["id"]?.string, let id = EntryID(raw) else { throw RemoteError.badParams("id") }
        return id
    }

    static func remoteSummary(_ e: KBEntry) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for k in ["status", "kind", "owner", "due", "waiting_on", "start", "end", "work_item", "raised_in", "proposed_by", "reason"] {
            if let v = e.field(k) { fields[k] = .string(v) }
        }
        return ["id": .string(e.id.rawValue), "section": .string(e.section.rawValue), "scope": .string(e.project),
                "title": .string(e.title), "date": .string(e.date), "summary": .string(e.summary),
                "tags": .array(e.tags.map(JSONValue.string)), "fields": .object(fields)]
    }

    /// Plan sessions are archived only by the user; Build ones also once their work is done.
    func sessionArchived(_ s: WorkSession) -> Bool { s.space == .plan ? s.archived == true : isArchived(s) }

    func remoteSession(_ s: WorkSession) -> JSONValue {
        let archived = sessionArchived(s)
        var o: [String: JSONValue] = [
            "id": .string(s.id), "title": .string(s.title), "space": .string(s.space.rawValue),
            "role": .string(s.isAssistant ? "assistant" : s.role.rawValue),
            "scope": s.project.map(JSONValue.string) ?? .null, "state": .string(s.crewState.rawValue),
            "busy": .bool(s.chat.isBusy), "updated": .number(s.updated.timeIntervalSince1970),
            "count": .number(Double(s.chat.items.count)), "archived": .bool(archived),
            "needsYou": .bool(!archived && s.crewState.needsUser),
        ]
        if s.space == .plan {
            o["kind"] = .string(s.planKind.rawValue)
            o["kindTitle"] = .string(s.planKind.title)
        }
        if let origin = PlanSessions.origin(about: s.about) { o["origin"] = .string(origin) }
        return .object(o)
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

extension AppModel {
    /// Methods added by later parts (voice, meetings); nil when none of them knows the method.
    func remoteCallMore(_ method: String, _ p: JSONValue, from client: RemoteClient) async throws -> JSONValue? {
        switch method {
        case "actions.list":
            return ["areas": .array(ActionCatalog.areas.map { .string($0.title) }),
                    "actions": .array(actions.catalog.map { s in
                        ["name": .string(s.name), "area": .string(s.area), "about": .string(s.about), "risk": .string(s.risk.rawValue),
                         "input": s.inputSchema]
                    }), "confirmsRisky": .bool(actions.confirmsRisky)]
        case "action.run":
            guard let name = p["name"]?.string else { throw RemoteError.badParams("name") }
            let channel: ActionChannel = p["voice"]?.bool == true ? .voice : .remote
            return await actions.run(name, p["params"] ?? [:], channel: channel).json
        case "action.confirm":
            guard let token = p["token"]?.string else { throw RemoteError.badParams("token") }
            return await actions.confirm(token, channel: .remote).json
        case "action.cancel":
            actions.cancel(p["token"]?.string ?? "")
            return ["status": "cancelled"]
        default:
            if let handled = try await remoteConfig(method, p) { return handled }
            return try await remoteCallVoice(method, p, from: client)
        }
    }

    /// Voice and test methods; nil when none of them knows the method.
    func remoteCallVoice(_ method: String, _ p: JSONValue, from client: RemoteClient) async throws -> JSONValue? {
        if method.hasPrefix("voice.") { return try await remoteVoice(method, p, from: client) }
        if method.hasPrefix("meeting.") { return try await remoteMeeting(method, p) }
        return try await remoteCallTest(method, p, from: client)
    }
}
