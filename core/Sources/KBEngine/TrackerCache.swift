import Foundation
import KBCore
import Observation

/// What the engine knows of the trackers and pull requests, fetched with the `kb` CLI: every open PBI and bug
/// (`kb tracker backlog`), the user's own work (`kb tracker mine`) and their open pull requests (`kb pr list`).
/// Build sessions read their status from it and the factory picks its work from it.
@MainActor
@Observable
public final class TrackerCache {
    public var backlog: TrackerBacklog?
    public var backlogLoading = false
    public var backlogError: String?
    public var backlogFetched: Date?
    /// Forced refreshes asked for, and the latest one a finished fetch covers.
    @ObservationIgnored var backlogWanted = 0
    @ObservationIgnored var backlogHave = 0
    public var myWork: MyWork?
    public var myWorkLoading = false
    public var myWorkError: String?
    public var myWorkFetched: Date?
    public var pullRequests: PullRequestList?
    public var pullRequestsLoading = false
    public var pullRequestsError: String?
    public var pullRequestsFetched: Date?
    /// When the engine last queued each pull request's expired build again.
    @ObservationIgnored public var expiredBuildRetries: [Int: Date] = [:]

    /// After the pull requests were read: the open ones before, for the host to look for merged ones.
    @ObservationIgnored public var onPullRequests: ((_ before: Set<Int>) -> Void)?
    /// Before each fetch of the backlog and of the pull requests (the Mac starts its refresh timers).
    @ObservationIgnored public var willRefreshBacklog: (() -> Void)?
    @ObservationIgnored public var willRefreshPullRequests: (() -> Void)?

    @ObservationIgnored unowned let engine: MindmillEngine

    init(engine: MindmillEngine) {
        self.engine = engine
    }

    /// Fetches every PBI and bug from the trackers. Skipped when fetched in the last two minutes, unless forced. A
    /// forced refresh while one runs fetches again after it, so a change made meanwhile is never missed.
    public func refreshBacklog(force: Bool = false) {
        willRefreshBacklog?()
        if force { backlogWanted += 1 }
        guard !backlogLoading else { return }
        if !force, let at = backlogFetched, Date().timeIntervalSince(at) < 120 { return }
        backlogLoading = true
        if pullRequests == nil { refreshPullRequests() }
        let cli = engine.cli
        let generation = backlogWanted
        Task {
            do {
                let out = try await cli.run(["tracker", "backlog", "--json"])
                backlog = try TrackerBacklog.decode(out)
                backlogError = nil
                backlogFetched = Date()
                backlogHave = max(backlogHave, generation)
            } catch {
                backlogError = error.localizedDescription
            }
            backlogLoading = false
            if backlogError == nil, backlogHave < backlogWanted { refreshBacklog(force: true) }
        }
    }

    /// The backlog doesn't show a change yet: never fetched, or changed (a forced refresh) since the last fetch began.
    public var backlogStale: Bool { backlog == nil || backlogHave < backlogWanted }

    /// Waits for a backlog that shows every change made so far (up to `seconds`), fetching it when needed.
    public func freshBacklog(seconds: Double = 90) async {
        guard backlogStale else { return }
        if !backlogLoading { refreshBacklog(force: true) }
        _ = await engine.waitUntil(seconds: seconds) { [self] in !backlogStale || (!backlogLoading && backlogError != nil) }
    }

    public func refreshMyWork(force: Bool = false) {
        guard !myWorkLoading else { return }
        if !force, let at = myWorkFetched, Date().timeIntervalSince(at) < 300 { return }
        myWorkLoading = true
        let cli = engine.cli
        Task {
            do {
                let out = try await cli.run(["tracker", "mine", "--json"])
                myWork = try MyWork.decode(out)
                myWorkError = nil
                myWorkFetched = Date()
                engine.sessions.groupSessionsByWork()
            } catch {
                myWorkError = error.localizedDescription
            }
            myWorkLoading = false
        }
    }

    public func refreshPullRequests(force: Bool = false) {
        willRefreshPullRequests?()
        guard !pullRequestsLoading else { return }
        if !force, let at = pullRequestsFetched, Date().timeIntervalSince(at) < 120 { return }
        pullRequestsLoading = true
        let cli = engine.cli
        Task {
            do {
                let before = Set(pullRequests?.prs.map(\.id) ?? [])
                pullRequests = try PullRequestList.decode(try await cli.run(["pr", "list", "--json"]))
                onPullRequests?(before)
                pullRequestsError = nil
                pullRequestsFetched = Date()
                engine.sessions.groupSessionsByWork()
                engine.sessions.reportStuckPRs()
                engine.sessions.askFinishedSessions()
                retryExpiredBuilds()
            } catch {
                pullRequestsError = error.localizedDescription
            }
            pullRequestsLoading = false
        }
    }

    /// Everything at once: after starting a factory, or the Sync button.
    public func refreshAll() {
        refreshBacklog(force: true)
        refreshPullRequests(force: true)
        refreshMyWork(force: true)
    }

    /// Runs an expired build again, as Azure DevOps's "Re-queue" does: at most once every 15 minutes per pull
    /// request, so a build that keeps expiring isn't requeued in a loop.
    public func retryExpiredBuilds() {
        let now = Date()
        let due = (pullRequests?.prs ?? []).filter { pr in
            pr.buildExpired && !pr.draft && expiredBuildRetries[pr.id].map { now.timeIntervalSince($0) > 900 } ?? true
        }
        guard !due.isEmpty else { return }
        for pr in due { expiredBuildRetries[pr.id] = now }
        let cli = engine.cli
        Task {
            var done: [Int] = []
            for pr in due {
                do {
                    _ = try await cli.run(["pr", "checks", String(pr.id), "--requeue-expired", "--log-lines", "0"])
                    done.append(pr.id)
                } catch {
                    engine.report("Could not run the expired build of !\(pr.id) again: \(error.localizedDescription)")
                }
            }
            guard !done.isEmpty else { return }
            engine.report("The build of " + done.map { "!\($0)" }.joined(separator: ", ") + " had expired. Mindmill queued it again.")
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            refreshPullRequests(force: true)
        }
    }

    /// The tracker's items for a scope: its own, what it includes, and for a project-wide scope the whole project.
    public func items(scope: String) -> [TrackerBacklog.Item] {
        backlog?.items(in: engine.index.members(of: scope)) ?? []
    }

    /// The scope's tracker kind from its settings: azure-devops, jira, local, github or none.
    public func kind(_ scope: String) -> String {
        if let k = kindCache[scope] { return k }
        let k = ProjectSettings.tracker(scope: scope, root: engine.rootURL).kind
        kindCache[scope] = k
        return k
    }

    @ObservationIgnored var kindCache: [String: String] = [:]

    /// Changes Mindmill's own tracker of a scope and saves it. A host with its own copy of the tracker replaces it.
    @ObservationIgnored public lazy var editLocal: (String, (inout LocalTracker) -> Void) -> Void = { [unowned self] scope, change in
        var t = LocalTracker.load(scope: scope, root: engine.rootURL)
        change(&t)
        do { try t.save(scope: scope, root: engine.rootURL) } catch {
            engine.report("Could not save the work items: \(error.localizedDescription)", error: true)
        }
    }

    /// Moves the item to its tracker's in-progress state as work starts, so the board shows it. Returns the
    /// instruction for the session when only Claude can reach the tracker (Jira, GitHub and the like).
    @discardableResult
    public func markWorkStarted(_ id: Int, scope: String, ref: String) -> String? {
        let kind = kind(scope)
        switch TrackerStart.route(kind: kind) {
        case .local:
            editLocal(scope) { $0.start(id) }
            return nil
        case .cli:
            let cli = engine.cli
            Task {
                do {
                    _ = try await cli.run(["tracker", "start", String(id), "--scope", scope])
                    refreshMyWork(force: true)
                    refreshBacklog(force: true)
                } catch {
                    engine.report("Could not move #\(id) to in progress: \(error.localizedDescription)")
                }
            }
            return nil
        case .claude, .none:
            return TrackerStart.sessionNote(kind: kind, ref: ref)
        }
    }

    /// The PR as the list knows it.
    public func pullRequest(_ id: Int) -> PullRequest? { pullRequests?.pr(id) }
}
