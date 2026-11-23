import Foundation
import KBCore

/// Private or shared entries, and the repositories a scope works on or takes knowledge from.
extension AppModel {
    /// Syncs the shared copies with the repositories and reads where each stands, shortly after the KB changes.
    func scheduleSharingRefresh(after delay: TimeInterval = 1.5) {
        guard index.projects.contains(where: { !$0.paths.isEmpty }) else { return }
        sharingTask?.cancel()
        let cli = cli
        sharingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let r = await cli.result(["share", "status", "--sync", "--json"])
            guard !Task.isCancelled, r.status == 0, let status = SharingStatus.parse(r.stdout) else { return }
            await MainActor.run {
                guard let self else { return }
                self.sharingRefreshed = Date()
                if status != self.sharing { self.sharing = status }
            }
        }
    }

    func sharingState(_ id: EntryID) -> EntrySharing { sharing.state(of: id) }

    func setShared(_ id: EntryID, _ shared: Bool, quiet: Bool = false) {
        if document?.id == id, document?.isDirty == true, !quiet { save() }
        sharingBusy.insert(id)
        let cli = cli
        let title = index.entry(id)?.title ?? id.rawValue
        let repo = sharing.repos[id.project]?.name ?? "the repository"
        Task {
            let r = await cli.result(["share", "set", id.rawValue, shared ? "shared" : "private"])
            sharingBusy.remove(id)
            if r.status != 0 {
                errorMessage = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "kb: ", with: "")
            } else if !quiet {
                notice = shared
                    ? "“\(title)” is shared: a copy is in \(repo)/knowledgebase, ready to commit and push."
                    : "“\(title)” is private. Its copy in \(repo) is removed; that goes out with your next commit and push there."
            }
            scheduleSharingRefresh(after: 0)
        }
    }

    /// A shared entry saved here: its copy in the main checkout's repository follows.
    func pushShared(_ id: EntryID) {
        let cli = cli
        Task {
            _ = await cli.result(["share", "sync", "--scope", id.project, "--push", id.rawValue])
            scheduleSharingRefresh(after: 0)
        }
    }

    // MARK: Repositories

    func repositories(of scope: String) -> ScopeRepositories { ScopeRepositories.of(scope, in: index) }

    /// Reads each repository's branch and distance from its remote; with `fetch`, asks the remotes first.
    func loadRepoStates(scope: String, fetch: Bool) {
        reposLoading = true
        let cli = cli
        Task {
            let r = await cli.result(["repos", "--scope", scope, "--json"] + (fetch ? ["--fetch"] : []))
            reposLoading = false
            let states = RepoState.parse(r.stdout)
            for (k, v) in states { repoStates[k] = v }
        }
    }

    /// Fast-forwards repositories to their remote; never merges or overwrites local work.
    func pullRepos(scope: String, only repo: String? = nil) {
        let targets = repo.map { [$0] } ?? repositories(of: scope).all.filter { $0.checkout != nil }.map(\.scope)
        reposPulling.formUnion(targets)
        let cli = cli
        Task {
            let r = await cli.result(["repos", "pull", "--scope", scope] + (repo.map { ["--repo", $0] } ?? []))
            reposPulling.subtract(targets)
            let lines = (r.stdout + r.stderr).split(separator: "\n").map(String.init).filter { !$0.hasPrefix("  ") && !$0.isEmpty }
            let failed = lines.filter { $0.contains("not pulled") || $0.contains("not on this Mac") }
            if failed.isEmpty {
                notice = targets.count == 1 ? "Pulled \(lines.first.map { $0.components(separatedBy: ":").first ?? "" } ?? "the repository")." : "Pulled \(targets.count) repositories."
            } else {
                errorMessage = failed.joined(separator: "\n")
            }
            loadRepoStates(scope: scope, fetch: false)
            reload()
        }
    }
}
