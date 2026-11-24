import Foundation
import KBCore

/// The action handlers that need nothing but the engine: the knowledge base, the `kb` CLI and the current scope.
/// A host registers the rest on `actions` (the Mac app: those that drive its windows, meetings, the tracker cache),
/// and may register its own handler over one of these defaults when it does more (busy marks, navigation).
extension MindmillEngine {
    func registerActions() {
        let a = actions
        a.confirmsRisky = VoicePreferences.load().confirmsRisky

        a.register("projects.list") { [unowned self] _ in
            let list = index.projects.map { p -> JSONValue in
                ["id": .string(p.id), "title": .string(p.title), "current": .bool(p.id == self.scope), "project": .string(p.group),
                 "projectTitle": .string(index.groups.first { $0.id == p.group }?.title ?? p.group), "wide": .bool(p.wide)]
            }
            let current = index.projects.first { $0.id == self.scope }?.title
            return ActionResult(current.map { "The current project is \($0), of \(index.projects.count)." } ?? "\(index.projects.count) projects.",
                                data: ["projects": .array(list)])
        }

        a.register("knowledge.search") { [unowned self] p in
            let q = p["query"]?.string ?? ""
            let found = index.search(q, project: p["scope"]?.string).flatMap(\.entries).filter { !$0.isDraft }.prefix(12)
            guard !found.isEmpty else { return ActionResult("I found nothing about \(q).") }
            let top = found.prefix(3).map { "\($0.title)" }
            return ActionResult("I found \(ActionText.count(found.count, "entry", plural: "entries")). The first: " + ActionText.list(top) + ".",
                                data: ["entries": .array(found.map(RemotePayloads.entrySummary))])
        }

        a.register("entry.read") { [unowned self] p in
            guard let raw = p["id"]?.string, let id = EntryID(raw) else { throw ActionError("That isn't an entry id.") }
            let doc = try KBStore.load(id, root: rootURL)
            let title = doc.frontmatter["title"].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? raw
            return ActionResult(title, data: ["id": .string(raw), "title": .string(title), "body": .string(String(doc.body.prefix(12000)))])
        }

        a.register("facts.list") { [unowned self] p in
            let scope = try scopeParam(p)
            let facts = index.entries(project: scope, section: .facts).filter { !$0.isDraft }.sorted { $0.date > $1.date }
            let list = facts.prefix(p["limit"]?.int ?? 20)
            var data: [String: JSONValue] = ["entries": .array(list.map(RemotePayloads.entrySummary))]
            if p["links"]?.bool == true {
                var links: [String: JSONValue] = [:]
                for f in list { links[f.id.rawValue] = .array(index.linkedFacts(of: f.id).map { .string($0.id.rawValue) }) }
                data["links"] = .object(links)
            }
            return ActionResult(ActionText.count(facts.count, "fact") + ".", data: .object(data))
        }

        a.register("facts.proposed") { [unowned self] p in
            let scope = try scopeParam(p)
            let list = factProposals(project: scope)
            guard let first = list.first else { return ActionResult("No proposed facts are waiting.") }
            return ActionResult("\(ActionText.count(list.count, "proposed fact")) waiting. The first: \(first.title). \(first.summary)",
                                data: ["entries": .array(list.map(RemotePayloads.entrySummary))])
        }

        a.register("meetings.list") { [unowned self] p in
            let scope = try scopeParam(p)
            let day = ActionText.day(p["day"]?.string)
            let list = index.entries(project: scope, section: .meetings).filter { $0.date.hasPrefix(day) }
                .sorted { ($0.field("start") ?? "") < ($1.field("start") ?? "") }
            guard !list.isEmpty else { return ActionResult("No meetings on \(day).") }
            return ActionResult("\(ActionText.count(list.count, "meeting")): " + ActionText.list(list.prefix(5).map(\.title)) + ".",
                                data: ["day": .string(day), "entries": .array(list.map(RemotePayloads.entrySummary))])
        }

        a.register("followups.list") { [unowned self] p in
            let scope = try scopeParam(p)
            let filter = p["filter"]?.string ?? "mine"
            var list = openFollowups(scope)
            if filter == "mine" { list = list.filter { $0.responsibility(me: myNames()) == .me } }
            if filter == "waiting" { list = list.filter { $0.responsibility(me: myNames()) == .others } }
            guard !list.isEmpty else { return ActionResult(filter == "waiting" ? "Nothing is waiting on others." : "No open follow-ups.") }
            return ActionResult("\(ActionText.count(list.count, "follow-up")). The first: " + ActionText.list(list.prefix(3).map(\.title)) + ".",
                                data: ["entries": .array(list.map(RemotePayloads.entrySummary))])
        }

        a.register("followup.create") { [unowned self] p in
            let scope = try scopeParam(p)
            let title = p["title"]?.string ?? ""
            var args = ["new", "followup", "--project", scope, "--cross-project", "--title", title,
                        "--type", p["kind"]?.string ?? "action", "--status", "open"]
            if let owner = p["owner"]?.string, !owner.isEmpty { args += ["--field", "owner=\(owner)"] }
            if let due = p["due"]?.string, !due.isEmpty { args += ["--field", "due=\(due)"] }
            let out = try await cli.run(args)
            reload()
            let id = Self.newEntryID(out)
            return ActionResult("Added the follow-up.", data: ["id": .string(id)])
        }

        a.register("workitem.create") { [unowned self] p in
            let scope = try scopeParam(p)
            let title = p["title"]?.string ?? ""
            var args = ["new", "backlog", "--project", scope, "--cross-project", "--title", title, "--type", p["kind"]?.string ?? "pbi"]
            let body = p["description"]?.string
            if body != nil { args.append("--body-stdin") }
            let out = try await cli.run(args, stdin: body)
            let entry = Self.newEntryID(out)
            guard !entry.isEmpty else { throw ActionError("Couldn't write the backlog entry.") }
            let posted = try await cli.run(["backlog", "create", entry, "--sprint", p["sprint"]?.string ?? "none", "--yes"])
            reload()
            onTrackerChanged?()
            let number = posted.range(of: "#[0-9]+", options: .regularExpression).map { String(posted[$0].dropFirst()) }
            return ActionResult(number.map { "Created work item \($0)." } ?? "Created it.", data: ["entry": .string(entry), "output": .string(posted)])
        }

        a.register("entries.list") { [unowned self] p in
            let scope = try scopeParam(p)
            guard let section = p["section"]?.string.flatMap(KBSection.init(rawValue:)) else { throw ActionError("Which section?") }
            var list = index.entries(project: scope, section: section).filter { !$0.isDraft }.sorted { $0.date > $1.date }
            if let q = p["query"]?.string, !q.isEmpty { list = list.filter { $0.matches(q) } }
            let tags = Set(p["tags"]?.strings ?? [])
            if !tags.isEmpty { list = list.filter { EntryTags.matches($0.tags, selected: tags) } }
            let shown = list.prefix(p["limit"]?.int ?? 50)
            guard let first = list.first else { return ActionResult("No \(section.title.lowercased()) match.") }
            return ActionResult("\(ActionText.count(list.count, section.singularTitle.lowercased())). The newest: \(first.title).",
                                data: ["entries": .array(shown.map(RemotePayloads.entrySummary))])
        }

        a.register("entry.create") { [unowned self] p in
            let scope = try scopeParam(p)
            guard let section = p["section"]?.string, let title = p["title"]?.string else { throw ActionError("A section and a title, please.") }
            var fields: [String: String] = [:]
            for kv in p["fields"]?.strings ?? [] {
                let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { fields[parts[0]] = parts[1] }
            }
            let id = try await createEntry(scope: scope, section: section, title: title, summary: p["summary"]?.string,
                                                  tags: p["tags"]?.strings ?? [], fields: fields, body: p["body"]?.string)
            return ActionResult("Wrote “\(title)”.", data: ["id": .string(id)])
        }

        a.register("entry.update") { [unowned self] p in
            let id = try entryParam(p)
            var doc = try KBStore.load(id, root: rootURL)
            var said: [String] = []
            for key in ["title", "summary", "status"] {
                if let v = p[key]?.string { doc.frontmatter.set(key, v.isEmpty ? nil : .string(v)); said.append(key) }
            }
            if let field = p["field"]?.string, !field.isEmpty {
                let v = p["value"]?.string ?? ""
                doc.frontmatter.set(field, v.isEmpty ? nil : .string(v))
                said.append(field)
            }
            if let body = p["body"]?.string { doc.body = body; said.append("text") }
            if let more = p["append"]?.string, !more.isEmpty {
                doc.body = doc.body.trimmingCharacters(in: .newlines) + "\n\n" + more + "\n"
                said.append("text")
            }
            guard !said.isEmpty else { return ActionResult("Nothing to change.") }
            _ = try KBStore.save(&doc, root: rootURL)
            reload()
            var seen = Set<String>()
            return ActionResult("Changed the " + ActionText.list(said.filter { seen.insert($0).inserted }) + ".")
        }

        a.register("fact.propose") { [unowned self] p in
            let scope = try scopeParam(p)
            let title = p["title"]?.string ?? ""
            let out = try await cli.addInboxFact(project: scope, title: title, proposedBy: "voice",
                                                 reason: p["reason"]?.string ?? "Said by the user", body: p["body"]?.string ?? title)
            reload()
            return ActionResult("Proposed it. Approve it when you're ready.", data: ["output": .string(out)])
        }

        a.register("fact.links") { [unowned self] p in
            let id = try entryParam(p)
            let linked = index.linkedFacts(of: id)
            guard !linked.isEmpty else { return ActionResult("No facts are linked to it.") }
            return ActionResult("\(ActionText.count(linked.count, "linked fact")): " + ActionText.list(linked.prefix(3).map(\.title)) + ".",
                                data: ["entries": .array(linked.map(RemotePayloads.entrySummary))])
        }

        a.register("reminders.list") { [unowned self] p in
            let which = p["status"]?.string ?? "open"
            let list = Reminders.load(root: rootURL).filter { which == "all" || $0.status.rawValue == which }.sorted { ($0.due.isEmpty ? "9" : $0.due) < ($1.due.isEmpty ? "9" : $1.due) }
            guard let first = list.first else { return ActionResult("No \(which == "all" ? "" : which + " ")reminders.") }
            return ActionResult("\(ActionText.count(list.count, "reminder")). The first: \(first.title)" + (first.due.isEmpty ? "." : ", due \(first.due)."),
                                data: ["reminders": .array(list.map(Self.reminderJSON))])
        }

        a.register("goals.list") { [unowned self] _ in
            let goals = Goals.load(root: rootURL)
            guard !goals.isEmpty else { return ActionResult("No goals yet.") }
            let active = goals.filter { $0.status == .active }
            return ActionResult("\(ActionText.count(active.count, "active goal")): " + ActionText.list(active.prefix(3).map(\.title)) + ".",
                                data: ["goals": .array(goals.map { g in
                                    ["id": .string(g.id), "title": .string(g.title), "horizon": .string(g.horizon),
                                     "status": .string(g.status.rawValue), "lastProgress": g.lastProgress.map(JSONValue.string) ?? .null,
                                     "openSuggestions": .number(Double(g.openSuggestions))]
                                })])
        }

        a.register("goal.create") { [unowned self] p in
            let g = try Goals.create(title: p["title"]?.string ?? "", horizon: p["horizon"]?.string ?? "", why: p["why"]?.string ?? "", root: rootURL)
            reload()
            return ActionResult("Added the goal.", data: ["id": .string(g.id)])
        }

        a.register("backlog.proposed") { [unowned self] p in
            let scope = try scopeParam(p)
            let list = index.entries(project: scope, section: .backlog).filter { $0.backlogStatus == .proposed }
            guard let first = list.first else { return ActionResult("No proposed backlog items.") }
            return ActionResult("\(ActionText.count(list.count, "proposed item")). The first: \(first.title).",
                                data: ["entries": .array(list.map(RemotePayloads.entrySummary))])
        }

        a.register("backlog.drop") { [unowned self] p in
            let id = try entryParam(p)
            guard let of = p["of"]?.string ?? ActionText.intParam(p["of"]).map(String.init) else { throw ActionError("A duplicate of what?") }
            let key = of.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            try await cli.dropBacklog(id, duplicateOf: key, comment: p["comment"]?.bool == true && Int(key) != nil)
            reload()
            return ActionResult("Dropped it as a duplicate of \(Int(key) != nil ? "#" + key : key).")
        }

        a.register("meeting.create") { [unowned self] p in
            let scope = try scopeParam(p)
            let date = ActionText.day(p["date"]?.string)
            let doc = try MeetingFile.create(project: scope, title: p["title"]?.string ?? "Meeting", date: date,
                                             start: p["start"]?.string ?? "", attendees: p["attendees"]?.strings ?? [], root: rootURL)
            reload()
            return ActionResult("Planned it for \(date)\(p["start"]?.string.map { " at \($0)" } ?? "").", data: ["meeting": .string(doc.id.rawValue)])
        }

        a.register("settings.voice") { [unowned self] p in
            var prefs = VoicePreferences.load()
            if let e = p["engine"]?.string.flatMap(VoiceEngineKind.init(rawValue:)) {
                if e == .api, prefs.provider == nil { throw ActionError("Add a real-time API key in Settings → Voice on the \(platform.machineWord) first.") }
                prefs.engine = e
            }
            if case .number(let r)? = p["rate"] { prefs.rate = min(2, max(0.5, r)) }
            if let l = p["language"]?.string { prefs.language = l }
            if let b = p["barge_in"]?.bool { prefs.bargeIn = b }
            prefs.save()
            actions.confirmsRisky = prefs.confirmsRisky
            return ActionResult("Changed the voice settings.")
        }

        a.register("app.show") { [unowned self] p in
            guard let presenter = platform.presenter else { throw ActionError("Open Mindmill on the \(platform.machineWord) first.") }
            try presenter.show(screen: p["screen"]?.string ?? "", id: p["id"]?.string)
            return ActionResult("It's on the \(platform.machineWord)'s screen now.", data: ["screen": p["screen"] ?? .null])
        }

        // Defaults a host with a window replaces with its own (busy marks, navigation).
        registerSettingsActions()

        a.register("fact.approve") { [unowned self] p in
            _ = try await cli.approveInbox(try entryParam(p))
            reload()
            return ActionResult("Approved.")
        }
        a.register("fact.decline") { [unowned self] p in
            try await cli.rejectInbox(try entryParam(p))
            reload()
            return ActionResult("Declined.")
        }
        a.register("followup.update") { [unowned self] p in
            guard let id = p["id"]?.string else { throw ActionError("Which follow-up?") }
            var said: [String] = []
            if let note = p["note"]?.string, !note.isEmpty {
                _ = try await cli.run(["followup", "note", id, "--text", note])
                said.append("Noted")
            }
            if let raw = p["status"]?.string, let status = FollowupStatus(rawValue: raw), let entry = EntryID(id) {
                try await cli.closeFollowup(entry, status: status, resolvedBy: p["resolved_by"]?.string, answer: p["answer"]?.string)
                said.append(status == .open ? "Reopened" : status == .done ? "Closed" : "Dropped")
            }
            reload()
            return ActionResult(said.isEmpty ? "Nothing to change." : said.joined(separator: " and ") + ".")
        }
        a.register("project.select") { [unowned self] p in
            let scope = try scopeParam(p)
            selectScope(scope)
            remote.broadcast("projects.changed")
            remote.broadcast("index.changed")
            return ActionResult("\(index.project(scope)?.title ?? scope) is the current project now.")
        }
        a.register("app.mode") { [unowned self] p in
            mode = p["mode"]?.string == "build" ? "build" : "plan"
            remote.broadcastDesktop("desktop.state", desktopState())
            return ActionResult("Switched to \(mode == "build" ? "Build" : "Plan").")
        }
    }

    /// The AI settings, and defaults for the other settings a host with more of them replaces (the Mac: meetings'
    /// transcription languages, the calendar timer).
    func registerSettingsActions() {
        let a = actions
        a.register("settings.ai") { [unowned self] p in
            let task = p["task"]?.string ?? ""
            let modelName = (p["model"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            if task == "brain" {
                let id = p["provider"]?.string ?? modelName
                guard let provider = AIProvider.with(id: id), provider.supported else {
                    throw ActionError("The brain can be " + ActionText.list(AIProvider.all.filter(\.supported).map(\.name), or: true) + ".")
                }
                aiSetup.brain = provider.id
                return ActionResult("The brain is \(provider.name) now.")
            }
            guard let t = AITask(rawValue: task) else { throw ActionError("Which task?") }
            if modelName.isEmpty {
                aiSetup.tasks[t] = nil
                return ActionResult("\(t.title) uses the default model now.")
            }
            let providerID = p["provider"]?.string ?? aiSetup.brain
            guard let provider = AIProvider.with(id: providerID), provider.supported else { throw ActionError("I don't know the provider \(providerID).") }
            guard provider.models.contains(modelName) else {
                throw ActionError("\(provider.name) has " + ActionText.list(provider.models, or: true) + ".")
            }
            aiSetup.tasks[t] = .init(provider: provider.id, model: modelName)
            return ActionResult("\(t.title) uses \(modelName) now.")
        }
        a.register("settings.get") { [unowned self] _ in
            ActionResult("The brain is \(aiSetup.brainProvider.name); sessions use \(model(for: .work).isEmpty ? "the default model" : model(for: .work)).",
                         data: settingsData())
        }
        a.register("settings.meetings") { [unowned self] p in
            let d = platform.defaults
            if let l = p["language"]?.string { d.set(l, forKey: SettingKeys.transcriptLanguage) }
            if let b = p["microphone"]?.bool { d.set(b, forKey: SettingKeys.transcriptMicrophone) }
            if let b = p["computer_audio"]?.bool { d.set(b, forKey: SettingKeys.transcriptComputerAudio) }
            return ActionResult("Changed the meeting settings.")
        }
        a.register("settings.general") { [unowned self] p in
            let d = platform.defaults
            if let v = p["appearance"]?.string { d.set(v, forKey: SettingKeys.appearance) }
            if let v = p["open_in"]?.string { d.set(v, forKey: SettingKeys.launchMode) }
            if let v = p["morning"]?.bool { d.set(v, forKey: SettingKeys.autoMorning) }
            if let n = ActionText.intParam(p["calendar_minutes"]) {
                guard [0, 15, 30, 60].contains(n) else { throw ActionError("The calendar syncs every 15, 30 or 60 minutes, or 0 for only at launch.") }
                d.set(n, forKey: SettingKeys.calendarMinutes)
            }
            return ActionResult("Changed the settings.")
        }
    }

    /// The `settings.get` action's data (remote-api.md, "Data the screens need").
    public func settingsData(meetingLanguages: [(id: String, name: String)] = [], defaultLanguage: String = "auto",
                             morning: Bool? = nil, calendarMinutes: Int? = nil) -> JSONValue {
        let d = platform.defaults
        let voice = VoicePreferences.load()
        var tasks: [String: JSONValue] = [:]
        for t in AITask.allCases {
            tasks[t.rawValue] = ["title": .string(t.title), "provider": .string(aiSetup.provider(for: t).id), "model": .string(model(for: t))]
        }
        return [
            "ai": ["brain": .string(aiSetup.brain), "tasks": .object(tasks),
                   "providers": .array(AIProvider.all.filter(\.supported).map { ["id": .string($0.id), "name": .string($0.name),
                                                                                 "models": .array($0.models.map(JSONValue.string))] })],
            "voice": ["engine": .string(voice.engine.rawValue), "provider": voice.provider.map(JSONValue.string) ?? .null,
                      "rate": .number(voice.rate), "language": .string(voice.language), "bargeIn": .bool(voice.bargeIn),
                      "confirmsRisky": .bool(voice.confirmsRisky)],
            "meetings": ["language": .string(d.string(forKey: SettingKeys.transcriptLanguage) ?? defaultLanguage),
                         "languages": .array(meetingLanguages.map { ["id": .string($0.id), "name": .string($0.name)] }),
                         "microphone": .bool(d.object(forKey: SettingKeys.transcriptMicrophone) as? Bool ?? true),
                         "computerAudio": .bool(d.object(forKey: SettingKeys.transcriptComputerAudio) as? Bool ?? true)],
            "general": ["appearance": .string(d.string(forKey: SettingKeys.appearance) ?? "system"),
                        "openIn": .string(d.string(forKey: SettingKeys.launchMode) ?? ""),
                        "morning": .bool(morning ?? d.bool(forKey: SettingKeys.autoMorning)),
                        "calendarMinutes": .number(Double(calendarMinutes ?? (d.object(forKey: SettingKeys.calendarMinutes) as? Int ?? 15)))],
            "remote": ["enabled": .bool(d.bool(forKey: RemoteServer.enabledKey)), "port": .number(Double(remote.port)),
                       "phones": .array(remote.devices.devices.map { .string($0.name) })],
        ]
    }

    public func factProposals(project: String) -> [KBEntry] {
        index.entries(project: project, section: .inbox).filter(\.isFactProposal)
    }

    public func openFollowups(_ scope: String) -> [KBEntry] {
        index.entries(project: scope, section: .followups).filter { !$0.isDraft && ($0.rawStatus.isEmpty || $0.rawStatus == "open") }
    }

    public static func reminderJSON(_ r: Reminder) -> JSONValue {
        ["id": .string(r.id), "title": .string(r.title), "due": .string(r.due), "status": .string(r.status.rawValue),
         "note": .string(r.note), "scope": r.project.map(JSONValue.string) ?? .null, "link": r.link.map { .string($0.absoluteString) } ?? .null]
    }
}

/// Preference keys the engine shares with the Mac app's Settings.
public enum SettingKeys {
    public static let appearance = "appearance"
    public static let launchMode = "launchMode"
    public static let autoMorning = "autoMorning"
    public static let calendarMinutes = "calendarSyncMinutes"
    public static let transcriptLanguage = "transcriptLanguage"
    public static let transcriptMicrophone = "transcriptMicrophone"
    public static let transcriptComputerAudio = "transcriptComputerAudio"
}
