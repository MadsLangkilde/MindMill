import AppKit
import KBCore
import KBEngine
import SwiftUI

struct SprintReviewRequest: Identifiable, Equatable {
    var id: String { key + "|" + sprint.path }
    let key: String
    /// The scope whose tracker it is, for the CLI.
    let scope: String
    let sprint: SprintInfo
}

extension AppModel {
    /// Reads every tracker's sprints and notices a new sprint, or one that ended with nothing after it. At most
    /// once an hour unless forced (Sync, the morning routine, Review Last Sprint).
    func checkSprints(force: Bool = false) { engine.sprints.check(force: force) }

    /// The sprint news for the current project's scopes (all scopes when none is open).
    var sprintMoments: [SprintMoment] { engine.sprints.moments(scope: projectID) }

    /// The tracker a scope's work is in, as `kb sprint status` saw it.
    func sprintTracker(scope: String) -> TrackerSprints? { engine.sprints.tracker(scope: scope) }

    func snoozeSprint(_ key: String) { engine.sprints.snooze(key) }

    func finishSprintReview(_ key: String, sprint: String) {
        engine.sprints.finish(key, sprint: sprint)
        if sprintReviewRequest?.key == key { sprintReviewRequest = nil }
    }

    func openSprintReview(_ moment: SprintMoment) {
        guard let sprint = moment.review?.sprint ?? moment.tracker.previous, let scope = moment.tracker.scopes.first else { return }
        sprintReviewRequest = SprintReviewRequest(key: moment.tracker.key, scope: scope, sprint: sprint)
    }

    /// "Review Last Sprint": the review of the sprint before today's, done before or not. A tracker only Claude
    /// can read gets a session that does it with its connector.
    func reviewLastSprint(scope: String) {
        guard let t = sprintTracker(scope: scope) else {
            let kind = trackerKind(scope)
            if TrackerStart.route(kind: kind) != .local, TrackerStart.route(kind: kind) != .cli, kind != "none", !kind.isEmpty {
                reviewSprintWithClaude(scope: scope, kind: kind)
            } else {
                checkSprints(force: true)
                notice = "Reading the sprints… try again in a moment."
            }
            return
        }
        if t.throughClaude {
            reviewSprintWithClaude(scope: scope, kind: t.kind)
            return
        }
        guard t.reachable else {
            errorMessage = "Mindmill can't read \(t.trackerName)'s sprints: \(t.note)"
            return
        }
        guard let previous = t.previous else {
            notice = "No sprint has finished yet in \(t.trackerName)."
            return
        }
        engine.sprints.request(t.key, sprint: previous, target: t.current ?? t.next)
        sprintReviewRequest = SprintReviewRequest(key: t.key, scope: t.scopes.first ?? scope, sprint: previous)
    }

    /// Jira, GitHub and the like: Mindmill can't read their sprints, so a Plan session does the review with
    /// Claude's connector, asking before it changes anything.
    func reviewSprintWithClaude(scope: String, kind: String) {
        let name = TrackerSprints.trackerName(kind)
        let message = SprintCenter.claudeReviewMessage(name)
        newSession(title: "Review last sprint in \(name)", project: scope, message: message,
                   display: "Review the last sprint in \(name)", space: .plan)
    }

    /// Adds the next sprint where Mindmill can (its own tracker); for Azure DevOps it opens the page to do it.
    func createNextSprint(_ t: TrackerSprints) {
        guard t.canCreate, let scope = t.scopes.first else {
            if let url = URL(string: t.createURL), !t.createURL.isEmpty { NSWorkspace.shared.open(url) }
            return
        }
        sprintCreating.insert(t.key)
        Task {
            defer { sprintCreating.remove(t.key) }
            do {
                let made = try await engine.sprints.createNext(t, scope: scope)
                notice = "Added \(made.name), \(DateText.short(made.start)) to \(DateText.short(made.finish))."
            } catch {
                errorMessage = (error as? KBCLIError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription
            }
        }
    }

    func loadSprintReview(scope: String, sprint: SprintInfo) async throws -> SprintReviewData {
        try await engine.sprints.loadReview(scope: scope, sprint: sprint)
    }

    /// Carries out the decisions in the tracker, each on its own, and refreshes what shows the items.
    func applySprintDecisions(_ decisions: [Int: SprintDecision], review: SprintReviewData, scope: String) async throws -> [SprintApplyResult] {
        try await engine.sprints.apply(decisions, review: review, scope: scope)
    }

    /// Names that mean the user on a work item: Settings' name, the tracker account, and this Mac's user.
    var workItemNames: [String] { engine.sprints.workItemNames }

    /// Whether a Build session (not archived) works on this key.
    func hasBuildSession(_ key: String) -> Bool { engine.sprints.hasBuildSession(key) }

    var activeSessionKeys: Set<String> { engine.sprints.activeSessionKeys }

    /// What can be started now in a scope, as Build's Ready to Start shows it.
    func startableWork(scope: String, filter: WorkFilter) -> [StartableWork] { engine.sprints.startable(scope: scope, filter: filter) }

    /// Start from Ready to Start: the usual Implement sheet, and an unassigned item is assigned to the user as it starts.
    func startReady(_ w: StartableWork) {
        implementRequest = ImplementRequest(item: w.asMyWork, show: true, assignToMe: w.isUnassigned)
    }

    /// Assigns a work item to the user in its tracker, before starting it.
    func assignToMe(_ id: Int, scope: String) {
        switch TrackerStart.route(kind: trackerKind(scope)) {
        case .local:
            guard let name = workItemNames.first else { return }
            editLocalTracker(scope) { t in
                guard var item = t.item(id), item.assignee.isEmpty else { return }
                item.assignee = name
                t.update(item)
            }
        case .cli:
            let cli = cli
            Task {
                do {
                    _ = try await cli.run(["tracker", "assign", String(id), "--to", "me"])
                    refreshTracker(force: true)
                } catch {
                    notice = "Could not assign #\(id) to you: \((error as? KBCLIError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription)"
                }
            }
        case .claude, .none:
            break
        }
    }
}
