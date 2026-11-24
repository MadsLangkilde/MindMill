import AppKit
import KBCore
import KBEngine
import SwiftUI

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
        checkSprints()
        scheduleSharingRefresh(after: 0)
    }

    /// Days ahead the regular sync mirrors: today through the end of next week and a little more.
    static let calendarDaysAhead = RoutineCenter.calendarDaysAhead

    /// Mirrors Outlook events as meeting files: by default today through two weeks on; `from`/`to` for a week the
    /// user opens in the meetings calendar.
    func syncCalendar(from requestedFrom: String? = nil, to requestedTo: String? = nil) {
        engine.routines.syncCalendar(from: requestedFrom, to: requestedTo)
    }

    /// The routines' connector hooks: a failed run checks the connectors, a good calendar sync clears a sign-in problem.
    func wireRoutines() {
        let r = engine.routines
        r.onConnectorTrouble = { [weak self] text in
            guard let self else { return }
            // Claude Code reports the connector as connected while Microsoft refuses its sign-in.
            if ConnectorSignIn.isNeeded(text) { microsoft365Status = "needs-auth" }
            checkConnectors(force: true)
        }
        r.onCalendarSynced = { [weak self] in
            guard let self, microsoft365NeedsSignIn else { return }
            microsoft365Status = "connected"
        }
        r.afterCalendar = { [weak self] in self?.runMorningIfDue() }
        r.needsSignIn = { [weak self] in self?.microsoft365NeedsSignIn ?? false }
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
