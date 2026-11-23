import AppKit
import KBCore
import SwiftUI

struct CalendarSyncState: Equatable {
    var lastRun: Date?
    var lastSuccess: Date?
    var summary: String?
    var error: String?
    var inFlight = false
    /// The days the running sync covers.
    var range: (from: String, to: String)?
    /// A later week the user asked for while a sync ran; it goes next.
    var queued: (from: String, to: String)?
    /// Syncs that have ended, and the days the last one covered: what `kb sync` waits for.
    var finished = 0
    var lastFinishedRange: (from: String, to: String)?

    static func == (a: Self, b: Self) -> Bool {
        a.lastRun == b.lastRun && a.lastSuccess == b.lastSuccess && a.summary == b.summary && a.error == b.error
            && a.inFlight == b.inFlight && a.range?.from == b.range?.from && a.range?.to == b.range?.to
            && a.queued?.from == b.queued?.from && a.queued?.to == b.queued?.to
    }
}

/// Calendar sync, the automatic morning routine, and connector sign-in.
extension AppModel {
    static let microsoft365 = "claude.ai Microsoft 365"

    var microsoft365NeedsSignIn: Bool {
        ["needs-auth", "failed"].contains(microsoft365Status) || connectorProblems.contains { $0.service.id == "m365" }
    }

    var autoMorning: Bool { UserDefaults.standard.object(forKey: AppSettingsKeys.autoMorning) as? Bool ?? true }
    var calendarMinutes: Int { UserDefaults.standard.object(forKey: AppSettingsKeys.calendarMinutes) as? Int ?? 30 }
    var calendarModel: String { model(for: .calendar) }

    /// Once claude is found: sync the calendar, then run the morning routine if today has no plan yet.
    /// Repeats the sync on a timer, and the whole thing when the Mac wakes on a new day.
    func startBackgroundWork() {
        guard !backgroundStarted, case .found = claudeAvailability, !showOnboarding else { return }
        guard ProcessInfo.processInfo.environment["KB_NO_AUTOSTART"] == nil else { return }
        backgroundStarted = true
        // Delivered on a later main-queue turn, outside any SwiftUI observation pass: mutating observable state
        // straight from the stream handler crashed the app (EXC_BAD_ACCESS in ObservationTracking).
        ClaudeChat.onConnectors = { [weak self] status in
            guard let s = status[Self.microsoft365] else { return }
            DispatchQueue.main.async {
                guard let self, self.microsoft365Status != s else { return }
                // A session's start says "connected" before Microsoft refuses the sign-in, so it never clears a
                // problem `claude mcp list` found: check again instead.
                if s == "connected", self.microsoft365NeedsSignIn {
                    self.checkConnectors()
                    return
                }
                self.microsoft365Status = s
            }
        }
        startDay()
        scheduleSyncTimer()
        refreshPeople()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
    }

    func scheduleSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
        let minutes = calendarMinutes
        guard minutes > 0 else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncCalendar() }
        }
    }

    private func startDay() {
        let today = KBDate.today()
        lastAutoDay = today
        if dailyDate != today { setDailyDate(today) }
        morningAfterSync = autoMorning && !FileManager.default.fileExists(atPath: DailyPlan.url(date: today, root: rootURL).path)
        syncCalendar()
    }

    private func appBecameActive() {
        checkConnectors()
        if lastAutoDay != KBDate.today() {
            startDay()
        } else if !microsoft365NeedsSignIn, calendarSync.lastRun.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
            syncCalendar()
        }
        if pullRequests != nil { refreshPullRequests() }
        if myWork != nil || mode == .build { refreshMyWork() }
        scheduleSharingRefresh(after: 0)
    }

    /// Mirrors today's and tomorrow's events as meeting files through a short headless session.
    /// Days ahead the regular sync mirrors: today through the end of next week and a little more.
    static let calendarDaysAhead = 13

    /// Mirrors Outlook events as meeting files: by default today through two weeks on; `from`/`to` for a week the
    /// user opens in the meetings calendar.
    func syncCalendar(from requestedFrom: String? = nil, to requestedTo: String? = nil) {
        if let requestedFrom, let requestedTo, calendar.isRunning || morning.isBusy {
            calendarSync.queued = (requestedFrom, requestedTo)
            return
        }
        guard !calendar.isRunning, !morning.isBusy else { return }
        let from = requestedFrom ?? KBDate.today()
        let to = requestedTo ?? KBDate.today(Calendar(identifier: .gregorian).date(byAdding: .day, value: Self.calendarDaysAhead, to: Date()) ?? Date())
        guard let launch = launch(prompt: ClaudeModes.calendar(from: from, to: to), sessionID: UUID().uuidString.lowercased(),
                                  resume: false, model: calendarModel, cwd: rootURL,
                                  tools: ["Bash(kb:*)", "Bash(python3:*)", "mcp__claude_ai_Microsoft_365__outlook_calendar_search"]) else { return }
        calendar.onEvent = { [weak self] event in self?.calendarEvent(event) }
        do {
            try calendar.start(launch, mode: "calendar")
        } catch {
            calendarSync.error = error.localizedDescription
            return
        }
        if requestedFrom == nil { calendarSync.lastRun = Date() }
        calendarSync.inFlight = true
        calendarSync.range = (from, to)
        calendar.send(ClaudeModes.warmup, tag: "connect", show: false)
        calendar.send("sync", tag: "calendar", show: false)
    }

    private func calendarEvent(_ event: ClaudeEvent) {
        switch event {
        case .turnResult(let text, let isError, let tag) where tag == "calendar":
            calendarSync.inFlight = false
            let line = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            if !isError, line.hasPrefix("calendar:") {
                calendarSync.summary = line
                calendarSync.error = nil
                calendarSync.lastSuccess = Date()
                if microsoft365NeedsSignIn { microsoft365Status = "connected" }
            } else {
                calendarSync.error = line.hasPrefix("ERROR") ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) : (line.isEmpty ? "Calendar sync failed." : line)
                // Claude Code reports the connector as connected while Microsoft refuses its sign-in.
                if ConnectorSignIn.isNeeded(text) { microsoft365Status = "needs-auth" }
                checkConnectors(force: true)
            }
            calendarSync.finished += 1
            calendarSync.lastFinishedRange = calendarSync.range
            calendar.stop()
            calendarSync.range = nil
            reload()
            runMorningIfDue()
            syncQueuedWeek()
        case .exited:
            guard calendarSync.inFlight else { return }
            calendarSync.inFlight = false
            calendarSync.finished += 1
            calendarSync.lastFinishedRange = calendarSync.range
            calendarSync.range = nil
            calendarSync.error = "\(Brain.name) stopped before the calendar was synced."
            runMorningIfDue()
            syncQueuedWeek()
        default:
            break
        }
    }

    private func syncQueuedWeek() {
        guard let q = calendarSync.queued else { return }
        calendarSync.queued = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            syncCalendar(from: q.from, to: q.to)
        }
    }

    private func runMorningIfDue() {
        guard morningAfterSync else { return }
        morningAfterSync = false
        guard !morning.isBusy, !FileManager.default.fileExists(atPath: DailyPlan.url(date: KBDate.today(), root: rootURL).path) else { return }
        if dailyDate != KBDate.today() { setDailyDate(KBDate.today()) }
        runMorningRoutine()
    }

    /// Opens Terminal on `claude /mcp`, where the user picks claude.ai Microsoft 365 → Authenticate.
    /// KB checks again when it becomes active.
    func signInToConnectors() {
        guard case .found(let exe) = claudeAvailability else {
            errorMessage = claudeMissingExplanation
            return
        }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/zsh -il
        cd \(quote(rootURL.path))
        clear
        echo "Sign in for Mindmill: choose “claude.ai Microsoft 365” → Authenticate, finish in the browser,"
        echo "then type /exit and go back to Mindmill. Mindmill checks again by itself."
        echo
        \(quote(exe.path)) /mcp
        """
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KB")
        let url = dir.appendingPathComponent("sign-in.command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            errorMessage = "Could not write \(url.path): \(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Meetings

    /// Every meeting on `date`, in all projects, by start time.
    func meetings(on date: String) -> [KBEntry] {
        // Straight from the index: a meeting tagged with several scopes is still one meeting.
        index.entries.values.filter { $0.section == .meetings && $0.date == date }
            .sorted { ($0.field("start") ?? "99", $0.title) < ($1.field("start") ?? "99", $1.title) }
    }

    /// Opens the meeting window and starts Claude preparing it.
    func prepareMeeting(_ id: EntryID) {
        if meetingControllers[id] != nil {
            meetingControllers[id]?.prepareWithClaude()
        } else {
            pendingPrepare.insert(id)
        }
        openMeeting(id)
    }

    /// Opens the meeting window straight into note-taking with the meeting companion.
    func takeNotes(_ id: EntryID) {
        if let c = meetingControllers[id] {
            c.startMeeting()
        } else {
            pendingStart.insert(id)
        }
        openMeeting(id)
    }

    func moveEntry(_ id: EntryID, to project: String, then: ((EntryID) -> Void)? = nil) {
        if document?.id == id {
            if document?.isDirty == true { save() }
            closeDocument()
        }
        if id.section == .meetings { closeMeetingController(id) }
        busyEntries.insert(id)
        let cli = cli
        Task {
            do {
                let out = try await cli.run(["move", id.rawValue, "--project", project])
                busyEntries.remove(id)
                reload()
                if let raw = out.components(separatedBy: .newlines).first, let new = EntryID(raw) {
                    notice = "Moved to \(index.project(project)?.title ?? project)."
                    then?(new)
                }
            } catch {
                busyEntries.remove(id)
                errorMessage = error.localizedDescription
            }
        }
    }
}
