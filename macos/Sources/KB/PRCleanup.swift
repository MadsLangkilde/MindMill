import KBCore
import KBEngine
import SwiftUI

enum PRAutoCleanup {
    static let key = "autoCleanupMergedPRs"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}

extension AppModel {
    /// After completing a pull request: ask about its worktree and branches once Azure DevOps lists it as done, or
    /// clean up by itself when the user turned that on.
    func offerCleanup(_ id: Int) {
        let cli = cli
        Task {
            guard let out = try? await cli.run(["pr", "done", "--json"]), let list = try? CompletedPRs.decode(out) else { return }
            donePRs = list
            guard let pr = list.prs.first(where: { $0.id == id }) else { return }
            if PRAutoCleanup.isOn { autoCleanUp(list) } else { prCleanupRequest = pr }
        }
    }

    /// With auto clean-up on: removes what each merged PR left that loses nothing and archives its sessions. What
    /// would lose something stays under My Work → In PR → Merged · to clean up. Each PR is tried once per launch.
    func autoCleanUp(_ list: CompletedPRs) {
        guard PRAutoCleanup.isOn else { return }
        let due = list.prs.filter { !autoCleanedPRs.contains($0.id) }
        guard !due.isEmpty else { return }
        autoCleanedPRs.formUnion(due.map(\.id))
        let cli = cli
        Task {
            var cleaned: [Int] = []
            var left: [Int] = []
            for pr in due {
                if let args = pr.safeCleanupArgs(worktrees: true, localBranch: true, remote: true) {
                    _ = try? await cli.run(args)
                }
                let sessions = sessions(aboutPR: pr.id).filter { !isArchived($0) }
                for s in sessions { setArchived(s, true) }
                cleaned.append(pr.id)
                if !pr.needsDecision.isEmpty { left.append(pr.id) }
            }
            let ids = { (xs: [Int]) in xs.map { "!\($0)" }.joined(separator: ", ") }
            notice = "Cleaned up after \(ids(cleaned))."
                + (left.isEmpty ? "" : " \(ids(left)) still has something that would be lost; it waits under In PR → to clean up.")
            refreshDonePRs(force: true)
        }
    }

    /// The Build sessions about a pull request: its own, or one on a work item it belongs to.
    func sessions(aboutPR id: Int) -> [WorkSession] { engine.sessions.sessions(aboutPR: id) }
}

/// What to remove after a pull request is merged: worktrees, the local branch, the branch on the server, and
/// whether to archive its sessions. Not Now leaves it under My Work → In PR → To clean up.
struct PRCleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pr: CompletedPRs.PR
    @State private var worktrees = true
    @State private var branch = true
    @State private var remote = false
    @State private var archive = true
    @State private var running = false
    @State private var output: [String] = []
    @State private var failed: String?
    @State private var finished = false
    @State private var confirmAnyway = false
    @AppStorage(PRAutoCleanup.key) private var autoCleanup = false

    var body: some View {
        let dirty = pr.worktrees.contains(where: \.dirty)
        let sessions = model.sessions(aboutPR: pr.id)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Clean up after !\(pr.id)").font(.title2.weight(.semibold))
                Text(pr.title).font(.callout)
                Text("Completed \(pr.closed.prefix(10)) · \(pr.repo) · \(pr.branch)").font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 10) {
                if !pr.worktrees.isEmpty {
                    option($worktrees, pr.worktrees.count == 1 ? "Remove the worktree" : "Remove \(pr.worktrees.count) worktrees",
                           detail: pr.worktrees.map(\.path).joined(separator: "\n"),
                           warning: dirty ? "Has uncommitted changes. They are lost if you remove it." : nil)
                }
                if pr.localBranch {
                    option($branch, "Delete the local branch", detail: pr.branch,
                           warning: pr.checkedOutInMain
                               ? "It is checked out in \(pr.repoPath). Clean Up switches that checkout to \(pr.target ?? "the target branch") first"
                                   + (pr.mainDirty == true ? "; its uncommitted changes come along." : ".")
                               : (!pr.localBranchSafe ? "It has commits the pull request didn't take. They are lost if you delete it." : nil))
                }
                if pr.remoteBranch {
                    option($remote, "Delete the branch on Azure DevOps", detail: pr.branch,
                           warning: pr.keepRemoteByDefault ? "A \(pr.branch.split(separator: "/").first ?? "") branch: kept by default, for example until the build is uploaded." : nil)
                }
                if !sessions.isEmpty {
                    option($archive, sessions.count == 1 ? "Archive its session" : "Archive its \(sessions.count) sessions",
                           detail: sessions.map { SessionTitle.split($0.title).text }.joined(separator: "\n"))
                }
            }
            .disabled(running || finished)
            if !output.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(output, id: \.self) { Label($0, systemImage: "checkmark").font(.caption) }
                }
            }
            if let failed {
                Label(failed, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Toggle(isOn: $autoCleanup) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean up merged pull requests by themselves from now on")
                    Text("Removes what loses nothing and archives their sessions without asking. Anything with a warning still waits here.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            HStack {
                if !finished {
                    Text("Not Now keeps it under My Work → In PR.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if finished {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    if !pr.anywayEffects.isEmpty {
                        Button("Clean Up Anyway…") { confirmAnyway = true }
                            .disabled(running)
                            .help("Removes everything, warnings included, after you confirm what that loses")
                    }
                    Button("Clean Up") { clean(sessions) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || !anything(sessions))
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .alert("Clean up !\(String(pr.id)) anyway?", isPresented: $confirmAnyway) {
            Button("Clean Up Anyway", role: .destructive) { clean(sessions, anyway: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pr.anywayEffects.joined(separator: "\n"))
        }
        .onAppear {
            worktrees = !dirty
            branch = pr.localBranchSafe && !pr.checkedOutInMain && !dirty
            remote = pr.remoteBranch && !pr.keepRemoteByDefault
        }
    }

    private func anything(_ sessions: [WorkSession]) -> Bool {
        (worktrees && !pr.worktrees.isEmpty) || (branch && pr.localBranch) || (remote && pr.remoteBranch)
            || (archive && !sessions.isEmpty)
    }

    private func option(_ on: Binding<Bool>, _ title: String, detail: String, warning: String? = nil, disabled: Bool = false) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3).truncationMode(.middle)
                if let warning {
                    Text(warning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(disabled)
    }

    private func clean(_ sessions: [WorkSession], anyway: Bool = false) {
        running = true
        failed = nil
        var args = ["pr", "cleanup", String(pr.id)]
        if anyway {
            args = pr.forceCleanupArgs
        } else {
            if worktrees && !pr.worktrees.isEmpty { args.append("--worktree") }
            if branch && pr.localBranch { args.append("--branch") }
            if remote && pr.remoteBranch { args.append("--remote") }
            // Ticking a warned option is the user's yes to what it warns about.
            if (worktrees && pr.worktrees.contains(where: \.dirty)) || (branch && (!pr.localBranchSafe || pr.checkedOutInMain)) {
                args.append("--force")
            }
        }
        let doGit = args.count > 3
        let cli = model.cli
        Task {
            if doGit {
                do {
                    let out = try await cli.run(args)
                    output = out.split(separator: "\n").map(String.init)
                } catch {
                    let e = error as? KBCLIError
                    failed = e?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription
                }
            }
            if archive || anyway {
                for s in sessions { model.setArchived(s, true) }
                if !sessions.isEmpty { output.append(sessions.count == 1 ? "archived the session" : "archived \(sessions.count) sessions") }
            }
            running = false
            finished = true
            model.refreshDonePRs(force: true)
        }
    }
}

struct BulkCleanupRequest: Identifiable {
    let id = UUID()
    let prs: [CompletedPRs.PR]
}

/// Cleans up after several merged pull requests at once. Only removes what loses nothing; anything that would
/// (uncommitted changes, commits the PR didn't take) is left for that PR's own Clean Up….
struct BulkCleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let prs: [CompletedPRs.PR]
    @State private var picked: Set<Int> = []
    @State private var worktrees = true
    @State private var branches = true
    @State private var remote = true
    @State private var archive = true
    @State private var running = false
    @State private var results: [Int: String] = [:]
    @State private var finished = false
    @State private var confirmAnyway = false
    @AppStorage(PRAutoCleanup.key) private var autoCleanup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Clean up after \(prs.count) merged pull requests").font(.title2.weight(.semibold))
                Text("Clean Up removes only what loses nothing. Clean Up Anyway also removes what has a warning, after you confirm what that loses.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Remove worktrees", isOn: $worktrees)
                Toggle("Delete local branches", isOn: $branches)
                Toggle("Delete branches on Azure DevOps (release, test, staging and hotfix branches are kept)", isOn: $remote)
                Toggle("Archive their sessions", isOn: $archive)
            }
            .toggleStyle(.checkbox)
            .disabled(running || finished)
            Toggle("Clean up merged pull requests by themselves from now on (what loses nothing; the rest waits here)", isOn: $autoCleanup)
                .toggleStyle(.checkbox)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(prs) { row($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
            HStack {
                Button(picked.count == prs.count ? "Select None" : "Select All") {
                    picked = picked.count == prs.count ? [] : Set(prs.map(\.id))
                }
                .disabled(running || finished)
                Spacer()
                if finished {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    if !anywayEffects.isEmpty {
                        Button("Clean Up Anyway…") { confirmAnyway = true }
                            .disabled(running || picked.isEmpty)
                            .help("Also removes what has a warning, after you confirm what that loses")
                    }
                    Button(running ? "Cleaning Up…" : "Clean Up \(picked.count)") { clean() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || picked.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
        .alert("Clean up anyway?", isPresented: $confirmAnyway) {
            Button("Clean Up Anyway", role: .destructive) { clean(anyway: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(anywayEffects.joined(separator: "\n"))
        }
        .onAppear { picked = Set(prs.map(\.id)) }
    }

    private func row(_ pr: CompletedPRs.PR) -> some View {
        let sessions = model.sessions(aboutPR: pr.id)
        return Toggle(isOn: Binding(get: { picked.contains(pr.id) }, set: { on in
            if on { picked.insert(pr.id) } else { picked.remove(pr.id) }
        })) {
            VStack(alignment: .leading, spacing: 3) {
                Text("!\(String(pr.id)) \(pr.title)").lineLimit(2).fixedSize(horizontal: false, vertical: true)
                ChipRow(spacing: 6) {
                    ForEach(pr.leftovers, id: \.self) { Chip(text: $0, color: .gray) }
                    if !sessions.isEmpty { Chip(text: sessions.count == 1 ? "1 session" : "\(sessions.count) sessions", color: .gray) }
                }
                if !pr.needsDecision.isEmpty {
                    Text("Left for you: \(pr.needsDecision.joined(separator: ", ")).")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let r = results[pr.id] {
                    Text(r).font(.caption).foregroundStyle(r.hasPrefix("Failed") ? Color.orange : Color.green)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(running || finished)
    }

    /// What cleaning up the picked PRs anyway does beyond a safe clean-up, PR by PR.
    private var anywayEffects: [String] {
        prs.filter { picked.contains($0.id) && !$0.anywayEffects.isEmpty }
            .flatMap { pr in pr.anywayEffects.map { "!\(pr.id): \($0)" } }
    }

    private func clean(anyway: Bool = false) {
        running = true
        let chosen = prs.filter { picked.contains($0.id) }
        let cli = model.cli
        Task {
            for pr in chosen {
                var lines: [String] = []
                if let args = anyway ? pr.forceCleanupArgs : pr.safeCleanupArgs(worktrees: worktrees, localBranch: branches, remote: remote) {
                    do {
                        lines += try await cli.run(args).split(separator: "\n").map(String.init)
                    } catch {
                        let e = error as? KBCLIError
                        results[pr.id] = "Failed: " + (e?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription)
                        continue
                    }
                }
                if archive {
                    let sessions = model.sessions(aboutPR: pr.id).filter { !model.isArchived($0) }
                    for s in sessions { model.setArchived(s, true) }
                    if !sessions.isEmpty { lines.append(sessions.count == 1 ? "archived its session" : "archived \(sessions.count) sessions") }
                }
                results[pr.id] = lines.isEmpty ? "Nothing to remove safely." : lines.joined(separator: " · ")
            }
            running = false
            finished = true
            model.refreshDonePRs(force: true)
        }
    }
}
