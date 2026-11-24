import AppKit
import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    /// Asks the session that owns the work to resolve its PR's merge conflicts; a session for the PR when none does.
    func resolveConflicts(_ pr: PullRequest, in session: WorkSession? = nil) {
        askAboutPR(pr, in: session, message: PRFix.conflicts(pr), display: "Resolve the merge conflicts in !\(pr.id)")
    }

    func fixFailedBuild(_ pr: PullRequest, in session: WorkSession? = nil) {
        askAboutPR(pr, in: session, message: PRFix.failedBuild(pr), display: "Fix the failed build of !\(pr.id)")
    }

    /// Runs the PR's failed, expired or stuck builds again, as Re-queue in Azure DevOps does.
    func rerunBuild(_ pr: PullRequest) {
        let cli = cli
        Task {
            do {
                _ = try await cli.run(["pr", "checks", String(pr.id), "--requeue", "--log-lines", "0"])
                notice = "The build of !\(pr.id) is queued again."
                try? await Task.sleep(for: .seconds(10))
                refreshPullRequests(force: true)
            } catch {
                notice = "Could not run the build of !\(pr.id) again: \(error.localizedDescription)"
            }
        }
    }

    private func askAboutPR(_ pr: PullRequest, in session: WorkSession?, message: String, display: String) {
        engine.sessions.askAboutPR(pr, in: session, message: message, display: display)
    }
}

/// Everything to do about a session's pull request, for its header menu and its row's right-click menu.
struct PRActionItems: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let session: WorkSession

    var body: some View {
        let problem = PRProblem.of(pr)
        if problem == .conflicts {
            Button("Resolve Merge Conflicts with \(Brain.name)") { model.resolveConflicts(pr, in: session) }
        }
        if problem == .buildFailed {
            Button("Fix the Failed Build with \(Brain.name)") { model.fixFailedBuild(pr, in: session) }
        }
        if problem == .buildFailed || problem == .buildExpired || problem == .buildQueued {
            Button(problem == .buildExpired ? "Run the Expired Build Again" : "Run the Build Again") { model.rerunBuild(pr) }
        }
        if pr.openThreads > 0 {
            Button("Show Comments on !\(String(pr.id))…") { model.prCommentsRequest = PRCommentsRequest(id: pr.id, session: session.id) }
            Menu("Handle Comments with \(Brain.name)") {
                ForEach(PRCommentsMode.allCases) { m in Button(m.title) { model.handlePRComments(pr, mode: m, in: session) } }
            }
        }
        if pr.canComplete, !pr.draft {
            Button("Complete !\(String(pr.id))…") { model.completePRRequest = CompletePRRequest(id: pr.id) }
        }
        Divider()
        Button("Open !\(String(pr.id)) in Mindmill") { model.openPRInBuild(pr.id) }
        if let url = URL(string: pr.url), !pr.url.isEmpty {
            Button("Open in Azure DevOps") { NSWorkspace.shared.open(url) }
        }
    }
}

/// The session header's pull request menu, beside Strategy and in the same plain style.
struct PRMenuButton: View {
    let pr: PullRequest
    let session: WorkSession

    var body: some View {
        let problem = PRProblem.of(pr)
        Menu {
            PRActionItems(pr: pr, session: session)
        } label: {
            Label("!\(String(pr.id))", systemImage: "arrow.triangle.pull")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(problem?.needsFixing == true ? .red : .primary)
        .help(problem.map { "!\(pr.id): \($0.label). Fix it from here." } ?? "!\(pr.id): what to do with this pull request")
    }
}

/// In the session, when its pull request has merge conflicts: say so, with the button that resolves them.
struct MergeConflictBanner: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let session: WorkSession

    var body: some View {
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 200) {
            Image(systemName: "arrow.triangle.merge").foregroundStyle(.red).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("!\(String(pr.id)) has merge conflicts").font(.callout.weight(.semibold))
                Text("\(pr.target) has changed since \(pr.source) branched off. \(Brain.name) merges it in, resolves the conflicts, asks you about any it's unsure of, builds, tests and pushes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button("Open PR") { model.openPRInBuild(pr.id) }
                Button("Resolve Conflicts") { model.resolveConflicts(pr, in: session) }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.chat.isBusy)
                    .help(session.chat.isBusy ? "The session is busy; it can resolve them when this turn ends" : "")
            }
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color.red.opacity(0.07))
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension AppModel {
    /// The pull request a review session is about (`pr:<id>`).
    func reviewedPR(_ s: WorkSession) -> Int? { Self.number(s.about ?? "", "pr:") }

    func castVote(_ vote: ReviewVote, on prID: Int, from session: WorkSession?) {
        let cli = cli
        Task {
            do {
                let out = try await cli.run(["pr", "vote", String(prID), "--vote", vote.rawValue])
                let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
                notice = line.isEmpty ? "Voted on !\(prID)." : line
                session?.chat.items.append(.init(role: .status, text: "You voted \(vote.title) on !\(prID) from Mindmill."))
                saveSessions()
                refreshMyWork(force: true)
            } catch {
                let e = error as? KBCLIError
                notice = "Could not vote on !\(prID): " + (e?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription)
            }
        }
    }
}

/// Vote on the pull request a review session is about, after confirming the vote.
struct ReviewVoteMenu: View {
    @Environment(AppModel.self) private var model
    let prID: Int
    let session: WorkSession
    @State private var pending: ReviewVote?

    var body: some View {
        Menu {
            ReviewVoteItems(prID: prID) { pending = $0 }
        } label: {
            Label("Vote", systemImage: "hand.thumbsup")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Cast your vote on !\(prID)")
        .alert("Vote \(pending?.title ?? "") on !\(String(prID))?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(pending?.title ?? "Vote") { if let v = pending { model.castVote(v, on: prID, from: session) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your vote shows on the pull request in Azure DevOps straight away.")
        }
    }
}

struct ReviewVoteItems: View {
    let prID: Int
    let pick: (ReviewVote) -> Void

    var body: some View {
        ForEach(ReviewVote.allCases) { v in
            if v == .reset { Divider() }
            Button(v.title) { pick(v) }
        }
    }
}
