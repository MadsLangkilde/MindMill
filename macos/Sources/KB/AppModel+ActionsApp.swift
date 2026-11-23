import AppKit
import Foundation
import KBCore

/// Handlers for the app itself: navigation, meetings run on the Mac, and settings.
extension AppModel {
    func registerAppActions() {
        let a = actions

        // MARK: Overview and navigation

        a.register("project.select") { [unowned self] p in
            let scope = try scopeParam(p)
            selectProject(scope)
            return ActionResult("\(index.project(scope)?.title ?? scope) is the current project now.")
        }

        a.register("app.show") { [unowned self] p in
            try show(screen: p["screen"]?.string ?? "", id: p["id"]?.string)
            return ActionResult("It's on the Mac's screen now.", data: ["screen": p["screen"] ?? .null])
        }

        a.register("app.mode") { [unowned self] p in
            mode = p["mode"]?.string == "build" ? .build : .plan
            return ActionResult("Switched to \(mode.title).")
        }

        a.register("sync.all") { [unowned self] _ in
            syncEverything()
            return ActionResult("Syncing everything.")
        }

        // MARK: Meetings

        a.register("calendar.upcoming") { [unowned self] p in
            let days = max(1, min(14, p["days"]?.int ?? 1))
            let from = KBDate.today()
            let to = KBDate.today(Calendar(identifier: .gregorian).date(byAdding: .day, value: days - 1, to: Date()) ?? Date())
            let scopes = try p["scope"]?.string.map { [try scopeParam(["scope": .string($0)])] } ?? index.projects.map(\.id)
            let events = scopes.flatMap { index.entries(project: $0, section: .meetings) }
                .filter { $0.date >= from && $0.date <= to && !$0.isDraft }
                .sorted { ($0.date, $0.field("start") ?? "") < ($1.date, $1.field("start") ?? "") }
            let now = MeetingController.clock(Date())
            let next = events.first { $0.meetingStatus == .live }
                ?? events.first { $0.meetingStatus != .cancelled && ($0.date > from || ($0.field("end") ?? $0.field("start") ?? "99:99") >= now) }
            let speech: String
            if let next {
                let when = next.meetingStatus == .live ? "running now" : next.date == from ? "at \(next.field("start") ?? "a time not set")" : "on \(next.date) at \(next.field("start") ?? "?")"
                speech = "\(Self.count(events.count, "meeting")). Next: \(next.title), \(when)."
            } else {
                speech = events.isEmpty ? "No meetings coming up." : "No more meetings \(days == 1 ? "today" : "in that time")."
            }
            return ActionResult(speech, data: ["events": .array(events.map(meetingEventJSON)),
                                               "next": next.map { .string($0.id.rawValue) } ?? .null])
        }

        a.register("meeting.create") { [unowned self] p in
            let scope = try scopeParam(p)
            let date = Self.day(p["date"]?.string)
            let doc = try MeetingFile.create(project: scope, title: p["title"]?.string ?? "Meeting", date: date,
                                             start: p["start"]?.string ?? "", attendees: p["attendees"]?.strings ?? [], root: rootURL)
            reload()
            return ActionResult("Planned it for \(date)\(p["start"]?.string.map { " at \($0)" } ?? "").", data: ["meeting": .string(doc.id.rawValue)])
        }

        a.register("meeting.prepare") { [unowned self] p in
            let id = try entryParam(p, "meeting")
            NSApp.activate(ignoringOtherApps: true)
            prepareMeeting(id)
            return ActionResult("Preparing it in the meeting window on the Mac.")
        }

        a.register("meeting.mac.start") { [unowned self] p in
            let id: EntryID
            if let raw = p["event"]?.string, !raw.isEmpty {
                guard let e = EntryID(raw), e.section == .meetings else { throw ActionError("That isn't a meeting.") }
                id = e
            } else {
                let scope = try p["scope"]?.string.map { try scopeParam(["scope": .string($0)]) } ?? meetingScope
                guard let scope else { throw ActionError("Open a project first.") }
                let now = Date()
                let title = (p["title"]?.string).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    ?? "Quick chat \(MeetingController.clock(now))"
                id = try MeetingFile.create(project: scope, title: title, date: KBDate.today(now), start: MeetingController.clock(now),
                                            attendees: [], root: rootURL).id
                reload()
            }
            let transcribe = p["transcribe"]?.bool ?? true
            let c = meetingController(for: id)
            c.load()
            c.startFromAction(transcribe: transcribe)
            NSApp.activate(ignoringOtherApps: true)
            openMeeting(id)
            broadcastMeeting(c)
            let consent = transcribe && !UserDefaults.standard.bool(forKey: AppSettingsKeys.transcriptConsentAcknowledged)
            return ActionResult("Started \(c.title) on the Mac" + (transcribe ? ", transcribing." : ".")
                                + (consent ? " Tell everyone it's being transcribed." : ""),
                                data: ["meeting": .string(id.rawValue), "title": .string(c.title), "transcribing": .bool(transcribe)])
        }

        a.register("meeting.mac.note") { [unowned self] p in
            let c = try macMeeting(p, live: true)
            c.appendRemoteNote(p["text"]?.string ?? "")
            return ActionResult("Noted.", data: ["meeting": .string(c.id.rawValue)])
        }

        a.register("meeting.mac.transcribe") { [unowned self] p in
            let c = try macMeeting(p, live: true)
            let on = p["on"]?.bool ?? true
            if on { c.beginTranscription() } else { c.stopTranscription() }
            return ActionResult(on ? "Transcribing." : "Stopped transcribing.", data: ["transcribing": .bool(on)])
        }

        a.register("meeting.mac.stop") { [unowned self] p in
            let c = try macMeeting(p, live: true)
            c.finishMeeting()
            broadcastMeeting(c)
            return ActionResult("Ended \(c.title). The summary and proposals are being written; review them in its window.",
                                data: ["meeting": .string(c.id.rawValue), "stage": .string(Self.stageName(c.stage))])
        }

        a.register("meeting.mac.file") { [unowned self] p in
            let c = try macMeeting(p, live: false)
            guard c.stage == .review else {
                throw ActionError(c.stage == .summarizing ? "The summary is still being written." : "\(c.title) isn't waiting for review.")
            }
            c.fileSelected()
            broadcastMeeting(c)
            return ActionResult("Filing \(c.title) with \(Self.count(c.inboxCards.filter { c.isTicked($0.id) }.count, "proposal")).",
                                data: ["meeting": .string(c.id.rawValue)])
        }

        a.register("meeting.mac.status") { [unowned self] p in
            guard let c = try? macMeeting(p, live: false) else { return ActionResult("No meeting is open on the Mac.", data: [:]) }
            let stage = Self.stageName(c.stage)
            let lines = c.transcript.count
            let speech: String = switch c.stage {
            case .live: "\(c.title) is running" + (c.transcriber.isOn ? ", transcribing, \(Self.count(lines, "line")) so far." : ", not transcribing.")
            case .summarizing: "The summary of \(c.title) is being written."
            case .review: "\(c.title) waits for review: \(Self.count(c.inboxCards.count, "proposal"))."
            case .prepare: "\(c.title) hasn't started."
            case .filed: "\(c.title) is filed."
            }
            return ActionResult(speech, data: [
                "meeting": .string(c.id.rawValue), "title": .string(c.title), "stage": .string(stage),
                "transcribing": .bool(c.transcriber.isOn), "lines": .number(Double(lines)), "notes": .string(c.notes),
                "started": c.liveStartedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                "transcript": .array(c.transcript.suffix(40).map { ["time": .string($0.time), "speaker": .string($0.speaker), "text": .string($0.text)] }),
                "proposals": c.stage == .review ? .array(c.inboxCards.map(Self.remoteSummary)) : .null,
            ])
        }

        // MARK: Settings

        a.register("settings.get") { [unowned self] _ in
            let d = UserDefaults.standard
            let voice = VoicePreferences.load()
            var tasks: [String: JSONValue] = [:]
            for t in AITask.allCases {
                tasks[t.rawValue] = ["title": .string(t.title), "provider": .string(aiSetup.provider(for: t).id), "model": .string(model(for: t))]
            }
            return ActionResult("The brain is \(aiSetup.brainProvider.name); sessions use \(model(for: .work).isEmpty ? "the default model" : model(for: .work)).", data: [
                "ai": ["brain": .string(aiSetup.brain), "tasks": .object(tasks),
                       "providers": .array(AIProvider.all.filter(\.supported).map { ["id": .string($0.id), "name": .string($0.name),
                                                                                     "models": .array($0.models.map(JSONValue.string))] })],
                "voice": ["engine": .string(voice.engine.rawValue), "provider": voice.provider.map(JSONValue.string) ?? .null,
                          "rate": .number(voice.rate), "language": .string(voice.language), "bargeIn": .bool(voice.bargeIn),
                          "confirmsRisky": .bool(voice.confirmsRisky)],
                "meetings": ["language": .string(d.string(forKey: AppSettingsKeys.transcriptLanguage) ?? LiveTranscriber.auto),
                             "languages": .array(LiveTranscriber.languages.map { ["id": .string($0.id), "name": .string($0.name)] }),
                             "microphone": .bool(d.object(forKey: AppSettingsKeys.transcriptMicrophone) as? Bool ?? true),
                             "computerAudio": .bool(d.object(forKey: AppSettingsKeys.transcriptComputerAudio) as? Bool ?? true)],
                "general": ["appearance": .string(d.string(forKey: AppSettingsKeys.appearance) ?? "system"),
                            "openIn": .string(d.string(forKey: AppSettingsKeys.launchMode) ?? ""), "morning": .bool(autoMorning),
                            "calendarMinutes": .number(Double(calendarMinutes))],
                "remote": ["enabled": .bool(d.bool(forKey: RemoteServer.enabledKey)), "port": .number(Double(remote.port)),
                           "phones": .array(remote.devices.devices.map { .string($0.name) })],
            ])
        }

        a.register("settings.ai") { [unowned self] p in
            let task = p["task"]?.string ?? ""
            let modelName = (p["model"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            if task == "brain" {
                let id = p["provider"]?.string ?? modelName
                guard let provider = AIProvider.with(id: id), provider.supported else {
                    throw ActionError("The brain can be " + Self.list(AIProvider.all.filter(\.supported).map(\.name), or: true) + ".")
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
                throw ActionError("\(provider.name) has " + Self.list(provider.models, or: true) + ".")
            }
            aiSetup.tasks[t] = .init(provider: provider.id, model: modelName)
            return ActionResult("\(t.title) uses \(modelName) now.")
        }

        a.register("settings.voice") { [unowned self] p in
            var prefs = VoicePreferences.load()
            if let e = p["engine"]?.string.flatMap(VoiceEngineKind.init(rawValue:)) {
                if e == .api, prefs.provider == nil { throw ActionError("Add a real-time API key in Settings → Voice on the Mac first.") }
                prefs.engine = e
            }
            if case .number(let r)? = p["rate"] { prefs.rate = min(2, max(0.5, r)) }
            if let l = p["language"]?.string { prefs.language = l }
            if let b = p["barge_in"]?.bool { prefs.bargeIn = b }
            prefs.save()
            actions.confirmsRisky = prefs.confirmsRisky
            return ActionResult("Changed the voice settings.")
        }

        a.register("settings.meetings") { [unowned self] p in
            let d = UserDefaults.standard
            if let l = p["language"]?.string {
                guard LiveTranscriber.languages.contains(where: { $0.id == l }) else {
                    throw ActionError("The transcript can be " + Self.list(LiveTranscriber.languages.map(\.id), or: true) + ".")
                }
                for c in meetingControllers.values { c.setTranscriptLanguage(l) }
                d.set(l, forKey: AppSettingsKeys.transcriptLanguage)
            }
            if let b = p["microphone"]?.bool { d.set(b, forKey: AppSettingsKeys.transcriptMicrophone) }
            if let b = p["computer_audio"]?.bool { d.set(b, forKey: AppSettingsKeys.transcriptComputerAudio) }
            return ActionResult("Changed the meeting settings.")
        }

        a.register("settings.general") { [unowned self] p in
            let d = UserDefaults.standard
            if let v = p["appearance"]?.string { d.set(v, forKey: AppSettingsKeys.appearance) }
            if let v = p["open_in"]?.string { d.set(v, forKey: AppSettingsKeys.launchMode) }
            if let v = p["morning"]?.bool { d.set(v, forKey: AppSettingsKeys.autoMorning) }
            if let n = Self.intParam(p["calendar_minutes"]) {
                guard [0, 15, 30, 60].contains(n) else { throw ActionError("The calendar syncs every 15, 30 or 60 minutes, or 0 for only at launch.") }
                d.set(n, forKey: AppSettingsKeys.calendarMinutes)
                scheduleSyncTimer()
            }
            return ActionResult("Changed the settings.")
        }
    }

    // MARK: Helpers

    /// Brings the main window forward on a screen; used by `app.show`.
    func show(screen: String, id: String?) throws {
        NSApp.activate(ignoringOtherApps: true)
        func front() {
            if let w = NSApp.windows.first(where: { $0.title.hasPrefix("Mindmill") }) { w.makeKeyAndOrderFront(nil) }
            else { openWindowAction?("main", nil) }
        }
        if let section = KBSection(rawValue: screen) {
            front()
            selectSidebar(.section(section))
            return
        }
        switch screen {
        case "today": front(); selectSidebar(.today)
        case "timeline": front(); selectSidebar(.timeline)
        case "project": front(); selectSidebar(.project)
        case "sessions": front(); selectSidebar(.sessions)
        case "reminders": front(); selectSidebar(.reminders)
        case "goals":
            front()
            selectSidebar(.goals)
            if let id { selectedGoalID = id.hasPrefix("goals/") ? id : "goals/\(id)" }
        case "prs": front(); selectSidebar(.pullRequests)
        case "build":
            front()
            mode = .build
            buildSelection = nil
        case "factory":
            front()
            showFactory(try factoryParam(["factory": .string(id ?? "")]).id)
        case "session":
            let s = try sessionParam(["id": .string(id ?? "")])
            front()
            if s.space == .build { openSession(s) } else { openPlanSession(s) }
        case "test":
            front()
            openTestMenu(scope: try scopeParam(["scope": id.map(JSONValue.string) ?? .null]))
        case "strategies":
            front()
            strategiesSheet = StrategiesSheetRequest(selected: id)
        case "settings":
            (id.flatMap(SettingsPane.init(rawValue:)) ?? .general).select()
            openSettingsAction?()
        case "entry":
            guard let id, EntryID(id) != nil else { throw ActionError("Which entry?") }
            front()
            openLink(id)
        case "meeting":
            guard let id, let e = EntryID(id) else { throw ActionError("Which meeting?") }
            openMeeting(e)
        case "ask":
            if let id, id != projectID, index.project(id) != nil { selectProject(id) }
            openAsk()
        case "assistant": Task { _ = await assistantSession(show: true) }
        default: throw ActionError("I can't show \(screen).")
        }
    }

    /// The meeting an action means: the one named, else the one running on the Mac (the most recent when several).
    private func macMeeting(_ p: JSONValue, live: Bool) throws -> MeetingController {
        if let raw = p["meeting"]?.string, !raw.isEmpty {
            guard let id = EntryID(raw), id.section == .meetings else { throw ActionError("That isn't a meeting.") }
            let c: MeetingController
            if let open = meetingControllers[id] {
                c = open
            } else if !live, index.entry(id)?.meetingStatus == .review {
                c = meetingController(for: id)
                c.load()
            } else {
                throw ActionError("That meeting isn't open on the Mac.")
            }
            if live, c.stage != .live { throw ActionError("\(c.title) isn't running.") }
            return c
        }
        let open = meetingControllers.values
        let pick = open.filter { $0.stage == .live }.max { ($0.liveStartedAt ?? .distantPast) < ($1.liveStartedAt ?? .distantPast) }
            ?? (live ? nil : open.first { $0.stage == .review || $0.stage == .summarizing } ?? open.first)
        guard let pick else { throw ActionError(live ? "No meeting is running on the Mac." : "No meeting is open on the Mac.") }
        return pick
    }

    func meetingEventJSON(_ e: KBEntry) -> JSONValue {
        ["id": .string(e.id.rawValue), "title": .string(e.title), "scope": .string(e.project), "date": .string(e.date),
         "start": .string(e.field("start") ?? ""), "end": .string(e.field("end") ?? ""),
         "attendees": .array(e.listField("attendees").map(JSONValue.string)),
         "online": e.field("online_url").map(JSONValue.string) ?? .null,
         "status": .string((e.meetingStatus ?? .scheduled).rawValue), "open": .bool(meetingControllers[e.id] != nil)]
    }

    static func stageName(_ s: MeetingController.Stage) -> String {
        switch s {
        case .prepare: return "prepare"
        case .live: return "live"
        case .summarizing: return "summarizing"
        case .review: return "review"
        case .filed: return "filed"
        }
    }
}
