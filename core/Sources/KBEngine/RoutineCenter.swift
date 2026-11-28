import Foundation
import KBCore
import Observation

/// What the calendar sync did last and does now.
public struct CalendarSyncState: Equatable, Sendable {
    public var lastRun: Date?
    public var lastSuccess: Date?
    public var summary: String?
    public var error: String?
    /// The last sync failed because the calendar's connector needs signing in, or isn't there.
    public var signInNeeded = false
    public var inFlight = false
    /// The days the running sync covers.
    public var range: (from: String, to: String)?
    /// A later week the user asked for while a sync ran; it goes next.
    public var queued: (from: String, to: String)?
    /// Syncs that have ended, and the days the last one covered: what `kb sync` waits for.
    public var finished = 0
    public var lastFinishedRange: (from: String, to: String)?

    public init() {}

    public static func == (a: Self, b: Self) -> Bool {
        a.lastRun == b.lastRun && a.lastSuccess == b.lastSuccess && a.summary == b.summary && a.error == b.error
            && a.signInNeeded == b.signInNeeded && a.inFlight == b.inFlight && a.range?.from == b.range?.from && a.range?.to == b.range?.to
            && a.queued?.from == b.queued?.from && a.queued?.to == b.queued?.to
    }
}

public struct EmailSyncState: Equatable, Sendable {
    public var lastRun: Date?
    public var summary: String?
    public var error: String?
    public var inFlight = false

    public init() {}
}

/// `engine.routines`: the headless Claude runs that reach the user's tools through Claude's connectors: the calendar
/// sync (the chosen calendar's events as meeting files), the email scan (reminders from new Outlook mail) and the
/// morning routine (the day's plan).
@MainActor
@Observable
public final class RoutineCenter {
    /// Days ahead the regular sync mirrors: today through the end of next week and a little more.
    public static let calendarDaysAhead = 13

    public var morning = ClaudeChat()
    public var calendar = ClaudeChat()
    public var email = ClaudeChat()
    public var calendarSync = CalendarSyncState()
    public var emailSync = EmailSyncState()

    /// A run failed in a way that may be the connector's sign-in: the host checks its connectors (`text` is the reply).
    @ObservationIgnored public var onConnectorTrouble: ((String) -> Void)?
    /// A calendar sync worked: the connector is signed in.
    @ObservationIgnored public var onCalendarSynced: (() -> Void)?
    /// After every calendar sync, worked or not (the Mac runs the morning routine when it's due).
    @ObservationIgnored public var afterCalendar: (() -> Void)?
    /// Whether the connector needs signing in again, for what `kb sync calendar` tells a session.
    @ObservationIgnored public var needsSignIn: () -> Bool = { false }
    @ObservationIgnored private var resolvingSource = false

    public static let noCalendar = "No calendar is connected to Mindmill. Choose one in Settings → Connections."

    @ObservationIgnored unowned let engine: MindmillEngine

    init(engine: MindmillEngine) {
        self.engine = engine
    }

    // MARK: Calendar

    /// Mirrors the chosen calendar's events as meeting files: by default today through two weeks on; `from`/`to` for a
    /// week the user opens in the meetings calendar. False when it couldn't start (and isn't queued), as when no
    /// calendar is connected.
    @discardableResult
    public func syncCalendar(from requestedFrom: String? = nil, to requestedTo: String? = nil) -> Bool {
        let source = engine.calendarChoice
        guard source.isSet else {
            if engine.calendarSource == nil { resolveThenSync(from: requestedFrom, to: requestedTo) }
            return false
        }
        if let requestedFrom, let requestedTo, calendar.isRunning || morning.isBusy {
            calendarSync.queued = (requestedFrom, requestedTo)
            return true
        }
        guard !calendar.isRunning, !morning.isBusy else { return false }
        let from = requestedFrom ?? KBDate.today()
        let to = requestedTo ?? KBDate.today(Calendar(identifier: .gregorian).date(byAdding: .day, value: Self.calendarDaysAhead, to: Date()) ?? Date())
        guard let launch = engine.launch(prompt: ClaudeModes.calendar(from: from, to: to, source: source), sessionID: UUID().uuidString.lowercased(),
                                         resume: false, model: engine.model(for: .calendar), cwd: engine.rootURL,
                                         tools: ["Bash(kb:*)", "Bash(python3:*)"] + source.tools) else { return false }
        calendar.onEvent = { [weak self] event in self?.calendarEvent(event) }
        do {
            try calendar.start(launch, mode: "calendar")
        } catch {
            calendarSync.error = error.localizedDescription
            return false
        }
        if requestedFrom == nil { calendarSync.lastRun = Date() }
        calendarSync.inFlight = true
        calendarSync.range = (from, to)
        calendar.send(ClaudeModes.warmup, tag: "connect", show: false)
        calendar.send("sync", tag: "calendar", show: false)
        return true
    }

    private func calendarEvent(_ event: ClaudeEvent) {
        switch event {
        case .turnResult(let text, let isError, let tag) where tag == "calendar":
            calendarSync.inFlight = false
            let line = Self.firstLine(text)
            if !isError, line.hasPrefix("calendar:") {
                calendarSync.summary = line
                calendarSync.error = nil
                calendarSync.signInNeeded = false
                calendarSync.lastSuccess = Date()
                onCalendarSynced?()
            } else {
                calendarSync.error = line.hasPrefix("ERROR") ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) : (line.isEmpty ? "Calendar sync failed." : line)
                calendarSync.signInNeeded = ConnectorSignIn.isNeeded(text)
                onConnectorTrouble?(text)
            }
            calendarSync.finished += 1
            calendarSync.lastFinishedRange = calendarSync.range
            calendar.stop()
            calendarSync.range = nil
            engine.reload()
            afterCalendar?()
            syncQueuedWeek()
        case .exited:
            guard calendarSync.inFlight else { return }
            calendarSync.inFlight = false
            calendarSync.finished += 1
            calendarSync.lastFinishedRange = calendarSync.range
            calendarSync.range = nil
            calendarSync.error = "\(Brain.name) stopped before the calendar was synced."
            afterCalendar?()
            syncQueuedWeek()
        default:
            break
        }
    }

    /// No choice saved yet: settle it from Claude's connectors once, then sync if that kept a calendar.
    private func resolveThenSync(from: String?, to: String?) {
        guard !resolvingSource else { return }
        resolvingSource = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let source = await engine.resolveCalendarSource()
            resolvingSource = false
            if source.isSet { syncCalendar(from: from, to: to) }
        }
    }

    private func syncQueuedWeek() {
        guard let q = calendarSync.queued else { return }
        calendarSync.queued = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.syncCalendar(from: q.from, to: q.to)
        }
    }

    // MARK: Email

    /// Has Claude read new mail and propose reminders for what needs the user, skipping newsletters and noise.
    @discardableResult
    public func syncEmail() -> Bool {
        guard !email.isRunning, !morning.isBusy else { return false }
        guard let launch = engine.launch(prompt: ClaudeModes.email, sessionID: UUID().uuidString.lowercased(), resume: false,
                                         model: engine.model(for: .work), cwd: engine.rootURL,
                                         tools: ["Bash(kb:*)", "Read", "Edit"] + UserTools.readTools(.mail)) else {
            engine.report(engine.claudeMissingExplanation, error: true)
            return false
        }
        email.onEvent = { [weak self] event in self?.emailEvent(event) }
        do {
            try email.start(launch, mode: "email")
        } catch {
            emailSync.error = error.localizedDescription
            return false
        }
        emailSync.lastRun = Date()
        emailSync.inFlight = true
        email.send(ClaudeModes.warmup, tag: "connect", show: false)
        email.send("scan", tag: "email", show: false)
        return true
    }

    private func emailEvent(_ event: ClaudeEvent) {
        switch event {
        case .turnResult(let text, let isError, let tag) where tag == "email":
            emailSync.inFlight = false
            let line = Self.firstLine(text)
            if !isError, line.hasPrefix("EMAIL") {
                emailSync.summary = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                emailSync.error = nil
                engine.report("Email: \(emailSync.summary ?? "")")
            } else {
                emailSync.error = line.hasPrefix("ERROR") ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) : (line.isEmpty ? "Email scan failed." : line)
                onConnectorTrouble?(text)
            }
            email.stop()
            engine.reload()
        case .exited:
            guard emailSync.inFlight else { return }
            emailSync.inFlight = false
            emailSync.error = "\(Brain.name) stopped before the email scan finished."
        default:
            break
        }
    }

    // MARK: Morning

    /// Writes the day's plan (`daily/<date>.md`) from the calendar, follow-ups, reminders and goals.
    @discardableResult
    public func runMorning(date: String = KBDate.today()) -> Bool {
        engine.sprints.check(force: true)
        let synced = calendarSync.lastSuccess.map { Calendar.current.isDateInToday($0) } ?? false
        let source = engine.calendarChoice
        let tools = ClaudeLaunch.bridgeTools + source.tools.filter { !ClaudeLaunch.bridgeTools.contains($0) }
        guard let launch = engine.launch(prompt: ClaudeModes.morning(date, calendarSynced: synced, calendar: source),
                                         sessionID: UUID().uuidString.lowercased(), resume: false, model: engine.model(for: .work),
                                         cwd: engine.rootURL, tools: tools) else {
            engine.report(engine.claudeMissingExplanation, error: true)
            return false
        }
        do {
            morning.reset()
            try morning.start(launch, mode: "morning")
            morning.items.append(.init(role: .status, text: "Morning routine for \(ActionText.displayDate(date)) started."))
            morning.send(ClaudeModes.warmup, tag: "connect", show: false)
            morning.send("today", tag: "morning", show: false)
            return true
        } catch {
            engine.report("Could not start claude: \(error.localizedDescription)", error: true)
            return false
        }
    }

    // MARK: `kb sync` from a session

    /// Syncs the calendar or email for a session's `kb sync` and waits for the outcome.
    public func sync(_ what: String, range: (from: String, to: String)?) async -> (Bool, String) {
        switch what {
        case "calendar":
            guard await engine.resolveCalendarSource().isSet else { return (false, Self.noCalendar) }
            let before = calendarSync.finished
            syncCalendar(from: range?.from, to: range?.to)
            guard calendar.isRunning || calendarSync.queued != nil else {
                if morning.isBusy { return (false, "the morning routine is running and syncs the calendar itself; run `kb sync calendar` again in a minute") }
                return (false, engine.claudeExecutable == nil ? engine.claudeMissingExplanation : "the calendar sync didn't start")
            }
            let done = await engine.waitUntil(seconds: 240) { [self] in
                calendarSync.finished > before
                    && (range == nil || (calendarSync.lastFinishedRange?.from == range?.from && calendarSync.lastFinishedRange?.to == range?.to))
            }
            guard done else { return (false, "still syncing; the meeting files update when it finishes") }
            if let e = calendarSync.error {
                return (false, needsSignIn()
                    ? "\(engine.calendarChoice.title) needs signing in again. Ask the user to press Reconnect… on the banner in the Mindmill app (\(e))"
                    : e)
            }
            return (true, calendarSync.summary ?? "synced")
        case "email":
            guard !email.isRunning else {
                _ = await engine.waitUntil(seconds: 240) { [self] in !email.isRunning }
                return emailOutcome()
            }
            syncEmail()
            guard emailSync.inFlight else { return (false, morning.isBusy ? "the morning routine is scanning email now" : "the email scan didn't start") }
            guard await engine.waitUntil(seconds: 240, { [self] in !emailSync.inFlight }) else { return (false, "still scanning") }
            return emailOutcome()
        default:
            return (false, "unknown")
        }
    }

    private func emailOutcome() -> (Bool, String) {
        if let e = emailSync.error { return (false, e) }
        return (true, emailSync.summary ?? "scanned")
    }

    public func stopAll() {
        morning.stop()
        calendar.stop()
        email.stop()
    }

    static func firstLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}

extension MindmillEngine {
    /// The chosen calendar, none until there is one.
    public var calendarChoice: CalendarSource { calendarSource ?? .none }

    /// With no choice saved, settles it from Claude's connectors (`CalendarSource.adopted`). A host that lists them
    /// anyway passes what it found.
    public func adoptCalendarSource(from servers: [ClaudeConnectors.Server]) {
        guard calendarSource == nil else { return }
        calendarSource = CalendarSource.adopted(from: servers)
    }

    /// The chosen calendar, listing Claude's connectors once to settle it when no choice is saved yet.
    public func resolveCalendarSource() async -> CalendarSource {
        if let calendarSource { return calendarSource }
        guard let exe = claudeExecutable else { return .none }
        let r = await ProcessRunner().run(executable: exe, arguments: ["mcp", "list"], environment: claudeEnvironment(),
                                          stdin: nil, currentDirectory: FileManager.default.homeDirectoryForCurrentUser)
        if r.status == 0 { adoptCalendarSource(from: ClaudeConnectors.parse(r.stdout)) }
        return calendarChoice
    }
}
