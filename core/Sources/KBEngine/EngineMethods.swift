import Foundation
import KBCore

/// The remote API methods (docs/remote-api.md) the engine answers by itself, and the desktop methods of
/// docs/engine-host.md. Hosts register the rest on `methods`.
extension MindmillEngine {
    func registerMethods() {
        let m = methods
        m.register(["hello", "state"]) { _ in { [unowned self] _, _ in helloResult() } }

        m.register("entries.list") { [unowned self] _, p in
            guard let scope = p["scope"]?.string ?? scope else { throw RemoteError.badParams("scope") }
            guard let section = p["section"]?.string.flatMap(KBSection.init(rawValue:)) else { throw RemoteError.badParams("section") }
            var list = index.entries(project: scope, section: section).filter { !$0.isDraft }
            if let q = p["query"]?.string, !q.isEmpty { list = list.filter { $0.matches(q) } }
            let tags = Set(p["tags"]?.strings ?? [])
            if !tags.isEmpty { list = list.filter { EntryTags.matches($0.tags, selected: tags) } }
            let limit = p["limit"]?.int ?? 500
            return ["entries": .array(list.prefix(limit).map(RemotePayloads.entrySummary))]
        }

        m.register("entries.search") { [unowned self] _, p in
            let q = p["query"]?.string ?? ""
            return ["entries": .array(index.search(q, project: p["scope"]?.string).flatMap(\.entries).prefix(100)
                .map(RemotePayloads.entrySummary))]
        }

        m.register("entry.get") { [unowned self] _, p in
            guard let raw = p["id"]?.string, let id = EntryID(raw) else { throw RemoteError.badParams("id") }
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
                extra = ["linked": .array(index.linkedFacts(of: id).map(RemotePayloads.entrySummary))]
            }
            return ["id": .string(id.rawValue), "frontmatter": .object(fm), "body": .string(doc.body), "extra": extra,
                    "sharing": await sharingJSON(id),
                    "suggestions": .array(suggestions(from: [id.rawValue]).map(Self.suggestionJSON))]
        }

        m.register("entry.save") { [unowned self] _, p in
            guard let raw = p["id"]?.string, let id = EntryID(raw) else { throw RemoteError.badParams("id") }
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
            suggestForNote(doc.id)
            return ["saved": true, "id": .string(doc.id.rawValue)]
        }

        m.register("entry.new") { [unowned self] _, p in
            guard let scope = p["scope"]?.string ?? scope, let section = p["section"]?.string,
                  let title = p["title"]?.string, !title.isEmpty else { throw RemoteError.badParams("scope, section and title") }
            var fields: [String: String] = [:]
            if case .object(let f)? = p["fields"] { for (k, v) in f { if let s = v.string { fields[k] = s } } }
            let id = try await createEntry(scope: scope, section: section, title: title, summary: p["summary"]?.string,
                                           tags: p["tags"]?.strings ?? [], fields: fields, body: p["body"]?.string)
            if let e = EntryID(id) { suggestForNote(e) }
            return ["id": .string(id)]
        }

        m.register("inbox.approve") { [unowned self] _, p in
            for id in p["ids"]?.strings.compactMap(EntryID.init) ?? [] { _ = try await cli.approveInbox(id) }
            reload()
            return ["done": true]
        }

        m.register("inbox.reject") { [unowned self] _, p in
            for id in p["ids"]?.strings ?? [] { _ = try await cli.run(["inbox", "reject", id]) }
            reload()
            return ["done": true]
        }

        m.register("facts.proposed") { [unowned self] _, p in
            guard let scope = p["scope"]?.string ?? scope else { throw RemoteError.badParams("scope") }
            return ["entries": .array(factProposals(project: scope).map(RemotePayloads.entrySummary))]
        }

        m.register("app.structure") { [unowned self] _, p in appStructure(scope: p["scope"]?.string) }

        m.register("kb.run") { [unowned self] _, p in
            let args = p["args"]?.strings ?? []
            guard !args.isEmpty else { throw RemoteError.badParams("args") }
            let out = try await cli.run(args, stdin: p["stdin"]?.string)
            reload()
            return ["output": .string(out)]
        }

        m.register("actions.list") { [unowned self] _, _ in
            ["areas": .array(ActionCatalog.areas.map { .string($0.title) }),
             "actions": .array(actions.catalog.map { s in
                 ["name": .string(s.name), "area": .string(s.area), "about": .string(s.about), "risk": .string(s.risk.rawValue),
                  "input": s.inputSchema]
             }), "confirmsRisky": .bool(actions.confirmsRisky)]
        }
        m.register("action.run") { [unowned self] _, p in
            guard let name = p["name"]?.string else { throw RemoteError.badParams("name") }
            let channel: ActionChannel = p["voice"]?.bool == true ? .voice : .remote
            return await actions.run(name, p["params"] ?? [:], channel: channel).json
        }
        m.register("action.confirm") { [unowned self] _, p in
            guard let token = p["token"]?.string else { throw RemoteError.badParams("token") }
            return await actions.confirm(token, channel: .remote).json
        }
        m.register("action.cancel") { [unowned self] _, p in
            actions.cancel(p["token"]?.string ?? "")
            return ["status": "cancelled"]
        }

        m.register("projects.config.get") { [unowned self] _, _ in
            let r = (try? Registry.load(registryURL)) ?? Registry()
            let counts = Dictionary(grouping: index.entries.values, by: \.project).mapValues(\.count)
            return ["current": scope.map(JSONValue.string) ?? .null, "home": .string(NSHomeDirectory()),
                    "projects": .array(r.projects.map { ProjectDraft.json(project: $0.id, registry: r, entries: { counts[$0] ?? 0 }) })]
        }

        m.register("folders.list") { _, p in
            do {
                return try FolderListing.list(p["path"]?.string)
            } catch {
                throw RemoteError.badParams(error.localizedDescription)
            }
        }

        registerDesktopMethods()
    }

    /// `hello` and `state`: the machine, the brain and the scopes in the user's order.
    public func helloResult() -> JSONValue {
        [
            "name": .string(platform.transport.machineName),
            "version": .number(Double(RemoteMessage.version)),
            "brain": .string(brainName),
            "scope": scope.map(JSONValue.string) ?? .null,
            "scopes": .array(index.groups.flatMap { g in
                g.scopes.compactMap { index.project($0) }.map { s -> JSONValue in
                    ["id": .string(s.id), "title": .string(s.title), "project": .string(g.id), "projectTitle": .string(g.title),
                     "wide": .bool(s.wide)]
                }
            }),
            "sections": .array(KBSection.allCases.map { .string($0.rawValue) }),
        ]
    }

    public var registryURL: URL { KBLayout.home(root: rootURL).appendingPathComponent("kb.json") }

    /// `kb new` for a section, as the phone's `entry.new` and the `entry.create` action do. Returns the new id.
    public func createEntry(scope: String, section: String, title: String, summary: String?, tags: [String],
                            fields: [String: String], body: String?) async throws -> String {
        var args = ["new", String(section.dropLast(section.hasSuffix("s") ? 1 : 0)), "--project", scope, "--cross-project", "--title", title]
        if let summary, !summary.isEmpty { args += ["--summary", summary] }
        if !tags.isEmpty { args += ["--tags", tags.joined(separator: ",")] }
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) { args += ["--field", "\(k)=\(v)"] }
        if body != nil { args.append("--body-stdin") }
        let out = try await cli.run(args, stdin: body)
        reload()
        return Self.newEntryID(out)
    }

    /// The id in what `kb new` prints: the id, then the path (on the same line or the next).
    nonisolated public static func newEntryID(_ output: String) -> String {
        output.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first.map(String.init) ?? ""
    }

    // MARK: Desktop shells (docs/engine-host.md)

    private func registerDesktopMethods() {
        let m = methods
        m.register("desktop.state") { [unowned self] _, _ in desktopState() }
        m.register("desktop.mode") { [unowned self] _, p in
            guard let mode = p["mode"]?.string, mode == "plan" || mode == "build" else { throw RemoteError.badParams("mode (plan or build)") }
            self.mode = mode
            remote.broadcastDesktop("desktop.state", desktopState())
            return ["mode": .string(mode)]
        }
        m.register("desktop.scope") { [unowned self] _, p in
            guard let id = p["scope"]?.string, selectScope(id) else { throw RemoteError.notFound("No such scope") }
            remote.broadcast("projects.changed")
            return ["scope": .string(id)]
        }
        m.register("settings.get") { [unowned self] _, p in
            guard let settings else { throw RemoteError.unavailable(platform.unavailable("Settings")) }
            let all = settings.get()
            if let key = p["key"]?.string { return ["key": .string(key), "value": all[key] ?? .null] }
            return all
        }
        m.register("settings.set") { [unowned self] _, p in
            guard let settings else { throw RemoteError.unavailable(platform.unavailable("Settings")) }
            guard let key = p["key"]?.string else { throw RemoteError.badParams("key") }
            do { try settings.set(key, p["value"] ?? .null) } catch { throw RemoteError.badParams(error.localizedDescription) }
            return ["key": .string(key), "value": settings.get()[key] ?? .null]
        }
    }

    /// Everything a desktop shell's chrome shows at once.
    public func desktopState() -> JSONValue {
        let waiting = needsYouItems()
        return [
            "mode": .string(mode),
            "scope": scope.map(JSONValue.string) ?? .null,
            "scopes": helloResult()["scopes"] ?? [],
            "notice": notice.map(JSONValue.string) ?? .null,
            "needsYou": ["count": .number(Double(waiting.count)), "items": .array(waiting)],
            "factories": .array(factoryStatus()),
            "loadError": loadError.map { .string($0.localizedDescription) } ?? .null,
        ]
    }

    /// Tells the desktop shells something for their notice bar.
    public func tell(_ text: String) {
        notice = text
        remote.broadcastDesktop("desktop.notice", ["text": .string(text)])
    }
}
