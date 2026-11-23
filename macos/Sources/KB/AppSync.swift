import Foundation
import KBCore

/// `kb sync` from a session: the app refreshes what it mirrors or shows, then writes how it went to
/// `<crew>/sync/<id>.json`, where the command waits.
extension AppModel {
    func runSync(_ req: CrewOrder.SyncRequest) {
        Task {
            var results: [[String: Any]] = []
            for what in req.what {
                let (ok, line) = await syncOne(what, range: req.range)
                results.append(["what": what, "ok": ok, "line": line])
            }
            writeSyncResult(req.id, results)
            let failed = results.filter { ($0["ok"] as? Bool) != true }.compactMap { $0["what"] as? String }
            notice = failed.isEmpty ? "A session synced \(req.what.joined(separator: ", "))."
                : "A session's sync of \(failed.joined(separator: ", ")) failed."
        }
    }

    private func syncOne(_ what: String, range: (from: String, to: String)?) async -> (Bool, String) {
        switch what {
        case "calendar":
            let before = calendarSync.finished
            syncCalendar(from: range?.from, to: range?.to)
            guard calendar.isRunning || calendarSync.queued != nil else {
                if morning.isBusy { return (false, "the morning routine is running and syncs the calendar itself; run `kb sync calendar` again in a minute") }
                return (false, claudeMissingExplanation.isEmpty ? "the calendar sync didn't start" : claudeMissingExplanation)
            }
            let done = await waitUntil(seconds: 240) { [self] in
                calendarSync.finished > before
                    && (range == nil || (calendarSync.lastFinishedRange?.from == range?.from && calendarSync.lastFinishedRange?.to == range?.to))
            }
            guard done else { return (false, "still syncing; the meeting files update when it finishes") }
            if let e = calendarSync.error {
                return (false, microsoft365NeedsSignIn
                    ? "Microsoft 365 needs signing in again. Ask the user to press Sign In… on the banner in the Mindmill app (\(e))"
                    : e)
            }
            return (true, calendarSync.summary ?? "synced")
        case "email":
            guard !email.isRunning else {
                _ = await waitUntil(seconds: 240) { [self] in !email.isRunning }
                return emailOutcome()
            }
            syncEmail()
            guard emailSync.inFlight else { return (false, morning.isBusy ? "the morning routine is scanning email now" : "the email scan didn't start") }
            guard await waitUntil(seconds: 240, { [self] in !emailSync.inFlight }) else { return (false, "still scanning") }
            return emailOutcome()
        case "tracker":
            refreshTracker(force: true)
            refreshMyWork(force: true)
            _ = await waitUntil(seconds: 90) { [self] in !trackerLoading && !myWorkLoading }
            if let e = trackerError ?? myWorkError { return (false, e) }
            return (true, "\(tracker?.items.count ?? 0) work items")
        case "prs":
            refreshPullRequests(force: true)
            _ = await waitUntil(seconds: 90) { [self] in !pullRequestsLoading }
            if let e = pullRequestsError { return (false, e) }
            return (true, "\(pullRequests?.prs.count ?? 0) open pull requests")
        default:
            return (false, "unknown")
        }
    }

    private func emailOutcome() -> (Bool, String) {
        if let e = emailSync.error { return (false, e) }
        return (true, emailSync.summary ?? "scanned")
    }

    private func waitUntil(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return condition()
    }

    private func writeSyncResult(_ id: String, _ results: [[String: Any]]) {
        let dir = crewDirectory.appendingPathComponent("sync")
        guard let data = try? JSONSerialization.data(withJSONObject: ["results": results], options: [.prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
    }
}
