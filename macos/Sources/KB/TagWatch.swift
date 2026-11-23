import Foundation
import KBCore

/// Which entries the background tagger has read, so it reads each new or changed one once.
struct TagWatchState: Equatable {
    var loaded = false
    var seeded = false
    var checked: [String: String] = [:]
    var pending: Set<String> = []
    var running: [String] = []
}

extension AppModel {
    /// The sections whose entries get area tags.
    static let taggedSections: Set<KBSection> = [.meetings, .facts, .followups, .backlog, .decisions, .architecture]

    private var tagWatchURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KB/tagwatch.json")
    }

    private func tagCandidates() -> [String: String] {
        var out: [String: String] = [:]
        for e in index.entries.values where Self.taggedSections.contains(e.section) && !e.isDraft {
            out[e.id.rawValue] = Self.scopeSignature(e)
        }
        return out
    }

    private func loadTagWatch() {
        guard !tagWatch.loaded else { return }
        tagWatch.loaded = true
        guard let data = try? Data(contentsOf: tagWatchURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        tagWatch.seeded = obj["seeded"] as? Bool ?? false
        tagWatch.checked = obj["checked"] as? [String: String] ?? [:]
    }

    private func saveTagWatch() {
        let obj: [String: Any] = ["seeded": tagWatch.seeded, "checked": tagWatch.checked]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: tagWatchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: tagWatchURL, options: .atomic)
    }

    /// Every tag in use on KB entries and on tracker items, the most used first.
    var tagVocabulary: [String] {
        EntryTags.vocabulary(index.entries.values.map(\.tags) + localItemTagLists).map(\.tag)
    }

    /// New and changed entries are tagged a little after the last change. On the first run the existing entries are
    /// only noted; Auto-Tag Everything tags them.
    func tagWatchIndexChanged() {
        guard backgroundStarted, loadError == nil else { return }
        loadTagWatch()
        let candidates = tagCandidates()
        if !tagWatch.seeded {
            tagWatch.checked = candidates
            tagWatch.seeded = true
            saveTagWatch()
            return
        }
        let changed = candidates.filter { tagWatch.checked[$0.key] != $0.value }.map(\.key)
        guard !changed.isEmpty else { return }
        tagWatch.pending.formUnion(changed)
        let snapshot = tagWatch.pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 50) { [weak self] in
            guard let self, self.tagWatch.pending == snapshot else { return }
            self.runTagging()
        }
    }

    /// Queues every entry without tags in the tagged sections; they are tagged in batches in the background.
    func autoTagEverything() {
        loadTagWatch()
        let untagged = index.entries.values.filter { Self.taggedSections.contains($0.section) && !$0.isDraft && $0.tags.isEmpty }
        guard !untagged.isEmpty else {
            notice = "Every entry already has tags."
            return
        }
        tagWatch.pending.formUnion(untagged.map(\.id.rawValue))
        notice = "Tagging \(untagged.count) entr\(untagged.count == 1 ? "y" : "ies") in the background. You can keep working."
        runTagging()
    }

    var isAutoTagging: Bool { tagger.isRunning || !tagWatch.pending.isEmpty }

    func runTagging() {
        guard !tagger.isRunning, !tagWatch.pending.isEmpty else { return }
        let ids = Array(tagWatch.pending.sorted().prefix(15))
        guard let launch = launch(prompt: ClaudeModes.tagging(ids, vocabulary: tagVocabulary), sessionID: UUID().uuidString.lowercased(),
                                  resume: false, model: backgroundModel, cwd: rootURL, tools: ["Bash(kb:*)", "Read", "Grep", "Glob"]) else { return }
        tagger.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .turnResult(_, _, let tag) where tag == "tag": self.finishTagging()
            case .exited: if !self.tagWatch.running.isEmpty { self.finishTagging() }
            default: break
            }
        }
        do { try tagger.start(launch, mode: "tags") } catch { return }
        tagWatch.running = ids
        tagger.send("tag", tag: "tag", show: false)
    }

    private func finishTagging() {
        reload()
        let candidates = tagCandidates()
        for id in tagWatch.running {
            tagWatch.checked[id] = candidates[id] ?? "checked"
            tagWatch.pending.remove(id)
        }
        tagWatch.running = []
        saveTagWatch()
        tagger.stop()
        if !tagWatch.pending.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.runTagging() }
        }
    }

    /// Sets the open entry's tags as the user's own choice, and saves unless it is being edited. Removed tags stay off.
    func setTags(_ tags: [String]) {
        guard let doc = document else { return }
        document?.frontmatter.set("tags", .list(EntryTags.normalized(tags)))
        if !isEditing && !doc.isDraft { save(publish: false) }
    }

    func tagSelection(_ key: ListSearchKey) -> Set<String> { tagFilter[key.rawValue] ?? [] }

    func setTagSelection(_ key: ListSearchKey, _ tags: Set<String>) { tagFilter[key.rawValue] = tags }

    /// The entries that have every tag picked in the list's tag filter.
    func tagFiltered(_ entries: [KBEntry], _ key: ListSearchKey) -> [KBEntry] {
        let selected = tagSelection(key)
        return selected.isEmpty ? entries : entries.filter { EntryTags.matches($0.tags, selected: selected) }
    }
}

extension AppModel {
    var localItemTagLists: [[String]] { itemTags.allTagLists }
}
