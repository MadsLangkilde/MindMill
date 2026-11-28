import AppKit
import KBCore
import KBEngine
import SwiftUI

/// Calendar sync, the automatic morning routine, and connector sign-in.
extension AppModel {
    /// The calendar the sync mirrors; none until the user picks one.
    var calendarSource: CalendarSource { engine.calendarChoice }

    /// The chosen calendar's connector needs signing in again, or isn't connected to Claude.
    var calendarNeedsSignIn: Bool {
        let source = calendarSource
        guard source.isSet else { return false }
        return ["needs-auth", "failed"].contains(calendarStatus) || connectorProblems.contains { $0.server.name == source.server }
    }

    /// Picks the calendar the sync mirrors (`.none` for none), then syncs it.
    func chooseCalendar(_ source: CalendarSource) {
        guard engine.calendarSource != source else { return }
        engine.calendarSource = source
        calendarStatus = ""
        calendarSync.error = nil
        calendarSync.signInNeeded = false
        if source.isSet, backgroundStarted { syncCalendar() }
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
            DispatchQueue.main.async {
                guard let self, let s = status[self.calendarSource.server], self.calendarStatus != s else { return }
                // A session's start says "connected" before the service refuses the sign-in, so it never clears a
                // problem `claude mcp list` found: check again instead.
                if s == "connected", self.calendarNeedsSignIn {
                    self.checkConnectors()
                    return
                }
                self.calendarStatus = s
            }
        }
        startDay()
        scheduleSyncTimer()
        refreshPeople()
        checkSprints(force: true)
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
        // The morning routine runs after the calendar sync, or straight away without a calendar.
        if engine.calendarSource == nil {
            Task { [weak self] in
                guard let self else { return }
                if await engine.resolveCalendarSource().isSet { syncCalendar() } else { runMorningIfDue() }
            }
        } else if calendarSource.isSet {
            syncCalendar()
        } else {
            runMorningIfDue()
        }
    }

    private func appBecameActive() {
        checkConnectors()
        if lastAutoDay != KBDate.today() {
            startDay()
        } else if calendarSource.isSet, !calendarNeedsSignIn, calendarSync.lastRun.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
            syncCalendar()
        }
        if pullRequests != nil { refreshPullRequests() }
        if myWork != nil || mode == .build { refreshMyWork() }
        checkSprints()
        scheduleSharingRefresh(after: 0)
    }

    /// Days ahead the regular sync mirrors: today through the end of next week and a little more.
    static let calendarDaysAhead = RoutineCenter.calendarDaysAhead

    /// Mirrors the chosen calendar's events as meeting files: by default today through two weeks on; `from`/`to` for a
    /// week the user opens in the meetings calendar. Does nothing without a calendar.
    func syncCalendar(from requestedFrom: String? = nil, to requestedTo: String? = nil) {
        engine.routines.syncCalendar(from: requestedFrom, to: requestedTo)
    }

    /// The routines' connector hooks: a failed run checks the connectors, a good calendar sync clears a sign-in problem.
    func wireRoutines() {
        let r = engine.routines
        r.onConnectorTrouble = { [weak self] text in
            guard let self else { return }
            // Claude Code reports the connector as connected while the service refuses its sign-in. The email scan
            // reads Microsoft 365 too, so its refusal counts when that is the calendar.
            if calendarSync.signInNeeded || (calendarSource.kind == .microsoft365 && ConnectorSignIn.isNeeded(text)) {
                calendarStatus = "needs-auth"
            }
            checkConnectors(force: true)
        }
        r.onCalendarSynced = { [weak self] in
            guard let self, calendarNeedsSignIn else { return }
            calendarStatus = "connected"
        }
        r.afterCalendar = { [weak self] in self?.runMorningIfDue() }
        r.needsSignIn = { [weak self] in self?.calendarNeedsSignIn ?? false }
    }

    private func runMorningIfDue() {
        guard morningAfterSync else { return }
        morningAfterSync = false
        guard !morning.isBusy, !FileManager.default.fileExists(atPath: DailyPlan.url(date: KBDate.today(), root: rootURL).path) else { return }
        if dailyDate != KBDate.today() { setDailyDate(KBDate.today()) }
        runMorningRoutine()
    }

    /// Opens Terminal on `claude /mcp`, where the user picks the connector (`server`, or the one that needs it) →
    /// Authenticate. KB checks again when it becomes active.
    func signInToConnectors(_ server: String? = nil) {
        guard case .found(let exe) = claudeAvailability else {
            errorMessage = claudeMissingExplanation
            return
        }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/zsh -il
        cd \(quote(rootURL.path))
        clear
        echo "Sign in for Mindmill: choose \(server.map { "“\($0)”" } ?? "the tool that needs it") → Authenticate, finish in the browser,"
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
        Task {
            do {
                let moved = try await engine.moveEntry(id, to: project)
                busyEntries.remove(id)
                if let new = moved {
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
