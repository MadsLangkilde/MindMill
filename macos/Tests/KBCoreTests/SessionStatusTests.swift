import Foundation
import Testing
@testable import KBCore

struct SessionStatusTests {
    @Test func titlesLoseTheirReference() {
        #expect(SessionTitle.split("#418750 Stale login token") == ("Stale login token", "#418750"))
        #expect(SessionTitle.split("Review !319228 Pairing fix") == ("Pairing fix", "Review !319228"))
        #expect(SessionTitle.split("!319185 comments: Retry lock") == ("Retry lock", "!319185 comments"))
        #expect(SessionTitle.split("Plain title") == ("Plain title", nil))
        #expect(SessionTitle.split("#12") == ("#12", "#12"))
    }

    @Test func aQuestionWinsOverThePR() {
        let ready = SessionStatus.PRState(canComplete: true, openThreads: 0, draft: false)
        #expect(SessionStatus.of(.waiting, pr: ready, workDone: false) == .needsInput)
        #expect(SessionStatus.of(.blocked, pr: nil, workDone: true) == .needsPermission)
        #expect(SessionStatus.of(.working, pr: ready, workDone: false) == .running)
    }

    @Test func thePRDecidesOnceNothingRuns() {
        #expect(SessionStatus.of(.idle, pr: .init(canComplete: true, openThreads: 0, draft: false), workDone: false) == .readyToComplete)
        #expect(SessionStatus.of(.stopped, pr: .init(canComplete: false, openThreads: 2, draft: false), workDone: false) == .comments)
        #expect(SessionStatus.of(.stopped, pr: .init(canComplete: false, openThreads: 0, draft: false), workDone: false) == .inReview)
        // Approved but blocked by a build or a conflict: not just "in review".
        #expect(SessionStatus.of(.stopped, pr: .init(canComplete: false, openThreads: 0, draft: false, approved: true), workDone: false) == .approved)
        #expect(SessionStatus.of(.stopped, pr: .init(canComplete: false, openThreads: 2, draft: false, approved: true), workDone: false) == .comments)
        #expect(SessionStatus.of(.stopped, pr: .init(canComplete: true, openThreads: 0, draft: false, approved: true), workDone: false) == .readyToComplete)
        #expect(SessionStatus.of(.stopped, pr: .init(canComplete: true, openThreads: 0, draft: true), workDone: false) == .draft)
    }

    @Test func doneAndPlainStates() {
        #expect(SessionStatus.of(.stopped, pr: nil, workDone: true) == .done)
        #expect(SessionStatus.of(.idle, pr: nil, workDone: false) == .idle)
        #expect(SessionStatus.of(.stopped, pr: nil, workDone: false) == .notRunning)
    }

    @Test func badgesShowTheSessionAndItsWorkSideBySide() {
        let review = SessionStatus.PRState(canComplete: false, openThreads: 0, draft: false, approved: true)
        #expect(SessionBadges.of(.waiting, linked: true, known: true, pr: review, item: .inPR, workDone: false)
                == SessionBadges(activity: .needsInput, work: .approved))
        #expect(SessionBadges.of(.stopped, linked: true, known: true, pr: nil, item: .inProgress, workDone: false)
                == SessionBadges(activity: nil, work: .inProgress))
        #expect(SessionBadges.of(.working, linked: true, known: false, pr: nil, item: nil, workDone: false)
                == SessionBadges(activity: .running, work: .checking))
        #expect(SessionBadges.of(.idle, linked: true, known: true, pr: nil, item: .resolved, workDone: true).work == .done)
        // Nothing tracked: the process state is all there is.
        #expect(SessionBadges.of(.stopped, linked: false, known: true, pr: nil, item: nil, workDone: false)
                == SessionBadges(activity: .notRunning, work: nil))
        #expect(SessionBadges.of(.blocked, linked: false, known: false, pr: nil, item: nil, workDone: false).needsUser)
    }

    @Test func onlyQuietUntrackedSessionsAreAskedIfTheyAreDone() {
        let now = Date()
        let day = now.addingTimeInterval(-86_400)
        func ask(_ role: SessionRole = .lead, about: String? = nil, busy: Bool = false, needsUser: Bool = false,
                 updated: Date = day, askedAt: Date? = nil) -> Bool {
            FinishedCheck.shouldAsk(role: role, about: about, busy: busy, needsUser: needsUser, archived: false,
                                    hasMessages: true, updated: updated, askedAt: askedAt, now: now)
        }
        #expect(ask())
        #expect(ask(.solo))
        #expect(!ask(.member))
        #expect(!ask(.overseer))
        #expect(!ask(about: "wi:418750"))
        #expect(!ask(about: "mypr:319228"))
        #expect(ask(about: "android/followups/x"))
        #expect(!ask(busy: true))
        #expect(!ask(needsUser: true))
        #expect(!ask(updated: now.addingTimeInterval(-3600)))
        #expect(!ask(updated: now.addingTimeInterval(-30 * 86_400)))
        // Asked already, and only the answer came after: not again. Worked since: again.
        #expect(!ask(updated: day, askedAt: day.addingTimeInterval(-60)))
        #expect(ask(updated: day, askedAt: day.addingTimeInterval(-5 * 3600)))
    }

    @Test func completedPRsDecode() throws {
        let json = #"{"fetched":"x","prs":[{"id":1,"title":"T","repo":"r","repo_id":"i","scope":"s","closed":"2026-11-11T10:00:00","url":"u","remote_branch":true,"repo_path":"/r","branch":"test/1.0","worktrees":[{"path":"/w","dirty":false}],"local_branch":true,"local_branch_safe":true,"checked_out_in_main":false}]}"#
        let pr = try CompletedPRs.decode(json).prs[0]
        #expect(pr.leftovers == ["worktree", "local branch", "remote branch"])
        #expect(pr.keepRemoteByDefault)
    }

    @Test func safeCleanupSkipsWhatWouldLoseWork() throws {
        func pr(dirty: Bool, safe: Bool, checkedOut: Bool, branch: String) throws -> CompletedPRs.PR {
            let json = #"{"fetched":"x","prs":[{"id":7,"title":"T","repo":"r","repo_id":"i","scope":"s","closed":"c","url":"u","remote_branch":true,"repo_path":"/r","branch":"\#(branch)","worktrees":[{"path":"/w","dirty":\#(dirty)}],"local_branch":true,"local_branch_safe":\#(safe),"checked_out_in_main":\#(checkedOut)}]}"#
            return try CompletedPRs.decode(json).prs[0]
        }
        let clean = try pr(dirty: false, safe: true, checkedOut: false, branch: "feature/x")
        #expect(clean.safeCleanupArgs(worktrees: true, localBranch: true, remote: true) == ["pr", "cleanup", "7", "--worktree", "--branch", "--remote"])
        #expect(clean.needsDecision.isEmpty)
        let risky = try pr(dirty: true, safe: false, checkedOut: false, branch: "test/1.0")
        #expect(risky.safeCleanupArgs(worktrees: true, localBranch: true, remote: true) == nil)
        #expect(risky.needsDecision.count == 3)  // the worktree, the untaken commits and the kept test branch
        #expect(clean.safeCleanupArgs(worktrees: false, localBranch: false, remote: false) == nil)
    }
}

@Suite struct CompletingAndDoneTests {
    @Test func autoCompleteAndRunningBuildsSayWhatTheyWaitFor() {
        #expect(SessionStatus.stage(of: .init(canComplete: false, openThreads: 0, draft: false, approved: true, autoComplete: true)) == .completing)
        #expect(SessionStatus.stage(of: .init(canComplete: false, openThreads: 0, draft: false, approved: true, building: true)) == .building)
        #expect(SessionStatus.stage(of: .init(canComplete: false, openThreads: 0, draft: false, approved: true)) == .approved)
        // Comments still come first while auto-complete waits.
        #expect(SessionStatus.stage(of: .init(canComplete: false, openThreads: 2, draft: false, autoComplete: true)) == .comments)
    }

    @Test func onlyQueuedOrRunningChecksCountAsWaiting() {
        #expect(PullRequest(id: 1, title: "x", blockers: ["The build is running"]).waitingForChecks)
        #expect(!PullRequest(id: 1, title: "x", blockers: ["The build is running", "It has merge conflicts"]).waitingForChecks)
        #expect(!PullRequest(id: 1, title: "x").waitingForChecks)
    }

    @Test func aCompletedPRMeansTheWorkIsMergedOnceNoneIsOpen() {
        let list = PullRequestList(prs: [], closed: [ClosedPR(id: 9, workItems: [100]), ClosedPR(id: 8, status: "abandoned", workItems: [200])])
        #expect(list.workMerged(item: 100, itemPRs: []))
        #expect(list.workMerged(item: 300, itemPRs: [9]))
        #expect(!list.workMerged(item: 200, itemPRs: [8]))
        let stillOpen = PullRequestList(prs: [PullRequest(id: 10, title: "y", workItems: [100])], closed: list.closed)
        #expect(!stillOpen.workMerged(item: 100, itemPRs: []))
    }

    @Test func oldListsWithoutClosedStillDecode() throws {
        let list = try PullRequestList.decode(#"{"fetched": "x", "prs": []}"#)
        #expect(list.closed.isEmpty)
    }

    @Test func doneSessionsAskBeforeTheyAreArchived() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let first = DoneArchive.update(nil, done: ["old"], now: now)
        #expect(DoneArchive.autoArchived(doneSince: first["old"], now: now))
        let next = DoneArchive.update(first, done: ["old", "new"], now: now)
        #expect(!DoneArchive.autoArchived(doneSince: next["new"], now: now))
        #expect(DoneArchive.autoArchived(doneSince: next["new"], now: now.addingTimeInterval(DoneArchive.grace)))
        #expect(DoneArchive.update(next, done: ["new"], now: now)["old"] == nil)
    }
}
