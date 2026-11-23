import KBCore
import SwiftUI

/// Which saved entries the background follow-up check has read, so each is read once per change.
struct FollowupWatchState: Equatable {
    var loaded = false
    var seeded = false
    var checked: [String: String] = [:]
    var pending: Set<String> = []
    var running: [String] = []
}

/// Keeps follow-ups current: when facts, decisions, meetings or other follow-ups are saved, a background Claude
/// session closes the follow-ups they settle (marked as closed by KB, so the user can reopen them) and notes what
/// changes the ones that stay open.
extension AppModel {
    private var followupWatchURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KB/followupwatch.json")
    }

    private var hasOpenFollowups: Bool {
        index.entries.values.contains { $0.section == .followups && !$0.isDraft && $0.followupStatus == .open }
    }

    /// Entries that can settle a follow-up, with a signature that changes when they do. An open follow-up counts
    /// once, when it is new (it may duplicate an older one); a closed one counts again when it closes.
    private func followupWatchCandidates() -> [String: String] {
        var out: [String: String] = [:]
        for e in index.entries.values where !e.isDraft {
            switch e.section {
            case .facts, .architecture:
                out[e.id.rawValue] = "\(e.summary.count)|\(e.body.count)"
            case .decisions where e.status != .superseded:
                out[e.id.rawValue] = "\(e.rawStatus)|\(e.summary.count)|\(e.body.count)"
            case .meetings:
                guard let s = e.meetingStatus, s == .review || s == .filed else { continue }
                out[e.id.rawValue] = "\(MeetingBody.section(.summary, in: e.body)?.count ?? 0)"
            case .followups:
                out[e.id.rawValue] = e.followupStatus == .open ? "open" : "\(e.rawStatus)|\(e.summary.count)"
            default:
                continue
            }
        }
        return out
    }

    func followupWatchIndexChanged() {
        guard backgroundStarted, loadError == nil else { return }
        if !followupWatch.loaded {
            followupWatch.loaded = true
            if let data = try? Data(contentsOf: followupWatchURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                followupWatch.seeded = obj["seeded"] as? Bool ?? false
                followupWatch.checked = obj["checked"] as? [String: String] ?? [:]
            }
        }
        let candidates = followupWatchCandidates()
        if !followupWatch.seeded {
            followupWatch.checked = candidates
            followupWatch.seeded = true
            saveFollowupWatch()
            return
        }
        let changed = candidates.filter { followupWatch.checked[$0.key] != $0.value }.map(\.key)
        guard !changed.isEmpty else { return }
        guard hasOpenFollowups else {
            for id in changed { followupWatch.checked[id] = candidates[id] }
            saveFollowupWatch()
            return
        }
        followupWatch.pending.formUnion(changed)
        let snapshot = followupWatch.pending
        // Wait until edits settle: a meeting or a fact is often written in several steps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.followupWatch.pending == snapshot else { return }
            self.runFollowupCheck()
        }
    }

    private func saveFollowupWatch() {
        let obj: [String: Any] = ["seeded": followupWatch.seeded, "checked": followupWatch.checked]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: followupWatchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: followupWatchURL, options: .atomic)
    }

    var isCheckingFollowups: Bool { !followupWatch.running.isEmpty }

    var claudeAvailable: Bool { if case .found = claudeAvailability { return true } else { return false } }

    /// Checks a scope's open follow-ups now against what was saved there and product-wide in the last 30 days.
    func checkFollowupsNow(project: String) {
        let cutoff = KBDate.today(Date().addingTimeInterval(-30 * 86_400))
        let wide = index.projects.first { $0.wide }?.id
        let scopes = Set([project] + (wide.map { [$0] } ?? []))
        let recent = followupWatchCandidates().keys.compactMap { EntryID($0).flatMap { index.entry($0) } }
            .filter { scopes.contains($0.id.project) && $0.date >= cutoff && !($0.section == .followups && $0.followupStatus == .open) }
            .sorted { $0.date > $1.date }
            .prefix(12)
        guard !recent.isEmpty else {
            notice = "Nothing was saved in \(index.project(project)?.title ?? project) in the last 30 days to check the follow-ups against."
            return
        }
        followupWatch.pending.formUnion(recent.map { $0.id.rawValue })
        runFollowupCheck()
    }

    func runFollowupCheck() {
        guard !followupChecker.isRunning, !followupWatch.pending.isEmpty else { return }
        let ids = Array(followupWatch.pending.sorted().prefix(12))
        let wide = index.projects.first { $0.wide }?.id
        guard let launch = launch(prompt: ClaudeModes.followupCheck(ids, wide: wide), sessionID: UUID().uuidString.lowercased(),
                                  resume: false, model: backgroundModel, cwd: rootURL, tools: ["Bash(kb:*)", "Read", "Grep", "Glob"]) else { return }
        followupChecker.onEvent = { [weak self] event in self?.followupCheckEvent(event) }
        do { try followupChecker.start(launch, mode: "followups") } catch { return }
        followupWatch.running = ids
        followupChecker.send("check", tag: "check", show: false)
    }

    private func followupCheckEvent(_ event: ClaudeEvent) {
        switch event {
        case .turnResult(let text, let isError, let tag) where tag == "check":
            finishFollowupCheck(text: isError ? "" : text)
        case .exited:
            if !followupWatch.running.isEmpty { finishFollowupCheck(text: "") }
        default:
            break
        }
    }

    private func finishFollowupCheck(text: String) {
        followupChecker.stop()
        reload()
        let report = FollowupCheckReport(text)
        let candidates = followupWatchCandidates()
        // What it read, and what it changed itself, count as read.
        for id in followupWatch.running + report.handled.map(\.id) + report.updated.map(\.id) {
            followupWatch.checked[id] = candidates[id] ?? "checked"
            followupWatch.pending.remove(id)
        }
        followupWatch.running = []
        saveFollowupWatch()
        if !report.handled.isEmpty || !report.updated.isEmpty {
            var parts: [String] = []
            if !report.handled.isEmpty {
                let titles = report.handled.prefix(2).map { "“\(EntryID($0.id).flatMap { index.entry($0)?.title } ?? $0.id)”" }
                parts.append("handled \(report.handled.count) follow-up\(report.handled.count == 1 ? "" : "s") (\(titles.joined(separator: ", "))\(report.handled.count > 2 ? ", …" : ""))")
            }
            if !report.updated.isEmpty { parts.append("updated \(report.updated.count)") }
            notice = "Mindmill " + parts.joined(separator: " and ") + " from what you saved. See Follow-ups."
        }
        if !followupWatch.pending.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.runFollowupCheck() }
        }
    }
}
