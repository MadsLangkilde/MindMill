import Foundation
import KBCore

/// The factory loop's decisions, apart from the sessions and tracker they look at: the host gathers what each
/// session shows (busy, archived, its work stage) and these say what follows. `FactoryRules`, `FactoryPicker` and
/// `FactoryRun` (KBCore) hold the rest.
public enum FactoryDecisions {
    /// What the loop knows about a task's session right now.
    public struct SessionView: Equatable, Sendable {
        public var exists: Bool
        public var busy: Bool
        public var archived: Bool
        /// The session's work badge: its pull request's stage, else its work item's.
        public var work: SessionStatus?

        public init(exists: Bool, busy: Bool = false, archived: Bool = false, work: SessionStatus? = nil) {
            self.exists = exists
            self.busy = busy
            self.archived = archived
            self.work = work
        }
    }

    /// Work stages after which a task no longer takes a place: its pull request is open and moving.
    public static let releasesSlot: Set<SessionStatus> = [.inReview, .approved, .readyToComplete, .completing, .building,
                                                          .buildQueued, .comments, .draft, .inPR]

    /// Whether the task still takes one of the factory's places: it does until its pull request is open and the
    /// session has nothing left to do or answer.
    public static func occupiesSlot(_ t: FactoryTask, session: SessionView, hasOpenQuestion: Bool) -> Bool {
        guard t.isActive, session.exists else { return false }
        if session.busy || hasOpenQuestion { return true }
        // It logged its part done (a pushed branch when PRs are off).
        if t.outcome != nil { return false }
        guard let work = session.work else { return true }
        return !releasesSlot.contains(work)
    }

    /// Why an active task has finished, or nil while it hasn't.
    public static func outcome(session: SessionView, stage: TrackerBacklog.Stage?) -> String? {
        guard session.exists else { return "Session deleted" }
        if session.archived { return "Session archived" }
        if session.work == .done || session.work == .resolved || stage == .resolved || stage == .done { return "Resolved" }
        return nil
    }

    /// The run's time is up.
    public static func timeIsUp(_ run: FactoryRun, now: Date = Date()) -> Bool {
        guard run.status == .running, let end = run.endsAt else { return false }
        return now >= end
    }

    /// A winding-down run stops once none of its active sessions is busy.
    public static func windDownComplete(_ run: FactoryRun, anyBusy: Bool) -> Bool {
        run.status == .windingDown && !anyBusy
    }

    /// Whether another task may start: fewer places taken than the rules allow.
    public static func hasFreeSlot(occupied: Int, rules: FactoryRules) -> Bool { occupied < rules.maxParallel }

    /// Work items this factory must not take: its own tasks and skips, ones being assigned, ones with a live session,
    /// and other running factories' tasks.
    public static func excluded(run: FactoryRun?, assigning: Set<Int>, withLiveSession: Set<Int>, otherFactories: [Factory]) -> Set<Int> {
        var exclude = Set(run?.tasks.map(\.workItem) ?? []).union(run?.skipped ?? []).union(assigning).union(withLiveSession)
        for other in otherFactories { exclude.formUnion(other.run?.activeTasks.map(\.workItem) ?? []) }
        return exclude
    }
}
