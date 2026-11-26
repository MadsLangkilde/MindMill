import Foundation
import KBCore
import KBEngine

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
        let title = index.entry(id)?.title ?? id.rawValue
        let repo = sharing.repos[id.project]?.name ?? "the repository"
        Task {
            var failed: String?
            do { try await engine.setShared(id, shared) } catch { failed = error.localizedDescription }
            sharingBusy.remove(id)
            if let failed {
                errorMessage = failed
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
        Task {
            let (ok, message) = await engine.pullRepos(scope: scope, only: repo)
            reposPulling.subtract(targets)
            if ok { notice = message } else { errorMessage = message }
            loadRepoStates(scope: scope, fetch: false)
        }
    }
}

extension AppModel {
    /// Makes the existing entries of each kind follow its new default.
    func applySharingDefaults(_ kinds: [(KBSection, Bool)], scope: String) {
        guard !kinds.isEmpty else { return }
        let cli = cli
        Task {
            var changed = 0
            for (kind, shared) in kinds {
                let r = await cli.result(["share", "default", kind.rawValue, shared ? "shared" : "private", "--scope", scope, "--apply", "--json"])
                if r.status != 0 { errorMessage = r.stderr.replacingOccurrences(of: "kb: ", with: ""); break }
                changed += (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any])?["changed"] as? Int ?? 0
            }
            notice = changed == 0 ? "No existing entries needed changing." : "Changed \(changed) existing entr\(changed == 1 ? "y" : "ies")."
            scheduleSharingRefresh(after: 0)
            reload()
        }
    }
}
