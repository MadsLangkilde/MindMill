import Foundation
import KBCore
import KBEngine

/// Which entries the background tagger has scoped, and which ones the user scoped by hand (never touched again).
struct ScopeTagState: Equatable {
    var loaded = false
    var seeded = false
    var checked: [String: String] = [:]
    var manual: Set<String> = []
    var pending: Set<String> = []
    var running: [String] = []
}

extension AppModel {
    private var scopeTagURL: URL {
        AppPaths.instanceFile("scopetags.json")
    }

    /// The text that decides an entry's scopes; its own `scopes` field is left out so tagging doesn't retrigger.
    static func scopeSignature(_ e: KBEntry) -> String {
        var h: UInt64 = 5381
        for b in (e.title + "\u{1}" + e.summary + "\u{1}" + e.body).utf8 { h = (h &* 33) ^ UInt64(b) }
        return String(h, radix: 36)
    }

    /// Entries in a project with more than one scope, not drafts, not scoped by hand.
    private func scopeCandidates() -> [String: String] {
        var out: [String: String] = [:]
        for e in index.entries.values where e.section != .overview && !e.isDraft && !index.siblings(of: e.project).isEmpty {
            out[e.id.rawValue] = Self.scopeSignature(e)
        }
        return out
    }

    private func loadScopeTags() {
        guard !scopeTags.loaded else { return }
        scopeTags.loaded = true
        guard let data = try? Data(contentsOf: scopeTagURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        scopeTags.seeded = obj["seeded"] as? Bool ?? false
        scopeTags.checked = obj["checked"] as? [String: String] ?? [:]
        scopeTags.manual = Set(obj["manual"] as? [String] ?? [])
    }

    private func saveScopeTags() {
        let obj: [String: Any] = ["seeded": scopeTags.seeded, "checked": scopeTags.checked, "manual": scopeTags.manual.sorted()]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: scopeTagURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: scopeTagURL, options: .atomic)
    }

    /// The user set this entry's scopes: from now on they stay as they are.
    func markScopesManual(_ ids: [EntryID]) {
        loadScopeTags()
        for id in ids {
            scopeTags.manual.insert(id.rawValue)
            scopeTags.pending.remove(id.rawValue)
        }
        saveScopeTags()
    }

    func isScopedByHand(_ id: EntryID) -> Bool {
        loadScopeTags()
        return scopeTags.manual.contains(id.rawValue)
    }

    func scopeWatchIndexChanged() {
        guard backgroundStarted, loadError == nil else { return }
        loadScopeTags()
        let candidates = scopeCandidates()
        if !scopeTags.seeded {
            scopeTags.checked = candidates
            scopeTags.seeded = true
            saveScopeTags()
            return
        }
        let changed = candidates.filter { scopeTags.checked[$0.key] != $0.value && !scopeTags.manual.contains($0.key) }.map(\.key)
        guard !changed.isEmpty else { return }
        scopeTags.pending.formUnion(changed)
        let snapshot = scopeTags.pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.scopeTags.pending == snapshot else { return }
            self.runScopeTagging()
        }
    }

    func runScopeTagging() {
        guard !scopeTagger.isRunning, !scopeTags.pending.isEmpty else { return }
        let ids = Array(scopeTags.pending.sorted().prefix(15))
        guard let launch = launch(prompt: ClaudeModes.scopeTagging(ids), sessionID: UUID().uuidString.lowercased(), resume: false,
                                  model: backgroundModel, cwd: rootURL, tools: ["Bash(kb:*)", "Read", "Grep", "Glob"]) else { return }
        scopeTagger.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .turnResult(_, _, let tag) where tag == "tag": self.finishScopeTagging()
            case .exited: if !self.scopeTags.running.isEmpty { self.finishScopeTagging() }
            default: break
            }
        }
        do { try scopeTagger.start(launch, mode: "scopes") } catch { return }
        scopeTags.running = ids
        scopeTagger.send("tag", tag: "tag", show: false)
    }

    private func finishScopeTagging() {
        reload()
        let candidates = scopeCandidates()
        for id in scopeTags.running {
            scopeTags.checked[id] = candidates[id] ?? "checked"
            scopeTags.pending.remove(id)
        }
        scopeTags.running = []
        saveScopeTags()
        scopeTagger.stop()
        if !scopeTags.pending.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.runScopeTagging() }
        }
    }

    /// Adds or removes one scope on several entries, as the user's own choice.
    func changeScope(_ scope: String, on ids: Set<EntryID>, add: Bool) {
        let targets = engine.scopeTargets(scope, on: Array(ids), add: add)
        guard !targets.isEmpty else { return }
        markScopesManual(targets)
        Task {
            let failures = await engine.changeScope(scope, on: targets, add: add)
            let title = index.project(scope)?.title ?? scope
            if failures.isEmpty {
                notice = "\(add ? "Added" : "Removed") \(title) \(add ? "to" : "from") \(targets.count) entr\(targets.count == 1 ? "y" : "ies")."
            } else {
                errorMessage = failures.joined(separator: "\n\n")
            }
        }
    }
}
