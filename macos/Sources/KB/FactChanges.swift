import KBCore
import KBEngine
import SwiftUI

/// Which decisions and meetings the background fact check has read, so each is checked once per change.
struct FactCheckState: Equatable {
    var loaded = false
    var seeded = false
    var checked: [String: String] = [:]
    var pending: Set<String> = []
    var running: [String] = []
    var lastSummary: String?
}

extension AppModel {
    // MARK: Pending changes

    /// Inbox entries that propose a change to a fact (`updates: <fact id>`).
    func factChanges(for id: EntryID) -> [KBEntry] {
        index.entries(project: id.project, section: .inbox).filter { $0.field("updates") == id.rawValue }
    }

    func factChangeCount(project: String) -> Int { engine.factChangeCount(project: project) }

    /// New facts proposed by sessions, meetings and reviews, waiting under Facts for the user's yes.
    func factProposals(project: String) -> [KBEntry] { engine.factProposals(project: project) }

    var factChangeCountAll: Int {
        index.entries.values.filter { $0.section == .inbox && $0.field("updates") != nil }.count
    }

    enum FactResolution: String { case update, keep, remove }

    func resolveFactChange(_ change: EntryID, _ how: FactResolution) {
        busyEntries.insert(change)
        Task {
            do {
                try await engine.resolveFactChange(change, how: how.rawValue)
                notice = how == .update ? "Fact updated." : how == .keep ? "Kept the fact, verified today." : "Fact removed."
            } catch {
                errorMessage = error.localizedDescription
            }
            busyEntries.remove(change)
            reload()
        }
    }

    /// A session that looks into the change with the user and resolves it when they agree.
    func clarifyFactChange(_ change: KBEntry, fact: EntryID) {
        let title = index.entry(fact)?.title ?? fact.stem
        let question = change.field("question") ?? change.reason ?? "It may have changed."
        let by = change.proposedBy ?? "unknown"
        newSession(title: "Fact: \(title)", project: fact.project, subject: .entry(fact, title: title),
                   message: "This fact may have changed: “\(question)” It was raised by `\(by)`; the proposed version is the inbox entry `\(change.id.rawValue)` (`kb show \(change.id.rawValue)`). Read the fact, the proposal and what raised it, check other sources where it helps, and tell me briefly what changed and what you recommend. Then ask me with choices: update the fact (`kb fact resolve \(change.id.rawValue) --update`, after editing the proposal if needed), keep it (`--keep`) or remove it (`--remove`). Run the one I pick.",
                   display: "Clarify: \(question)")
    }

    // MARK: Background check

    private var factCheckURL: URL {
        AppPaths.file("factcheck.json")
    }

    /// New decisions and filed meetings, with a signature that changes when they do.
    private func factCheckCandidates() -> [String: String] {
        var out: [String: String] = [:]
        for p in index.projects where !index.entries(project: p.id, section: .facts).isEmpty {
            for e in index.entries(project: p.id, section: .decisions) where e.status != .superseded {
                out[e.id.rawValue] = "\(e.rawStatus)|\(e.summary)|\(e.body.count)"
            }
            for e in index.entries(project: p.id, section: .meetings) {
                guard let s = e.meetingStatus, s == .review || s == .filed else { continue }
                out[e.id.rawValue] = "\(e.body.count)"
            }
        }
        return out
    }

    func factWatchIndexChanged() {
        guard backgroundStarted, loadError == nil else { return }
        if !factCheck.loaded {
            factCheck.loaded = true
            if let data = try? Data(contentsOf: factCheckURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                factCheck.seeded = obj["seeded"] as? Bool ?? false
                factCheck.checked = obj["checked"] as? [String: String] ?? [:]
            }
        }
        let candidates = factCheckCandidates()
        if !factCheck.seeded {
            factCheck.checked = candidates
            factCheck.seeded = true
            saveFactCheck()
            return
        }
        let changed = candidates.filter { factCheck.checked[$0.key] != $0.value }.map(\.key)
        guard !changed.isEmpty else { return }
        factCheck.pending.formUnion(changed)
        let snapshot = factCheck.pending
        // Wait until edits settle: a meeting is written in several steps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.factCheck.pending == snapshot else { return }
            self.runFactCheck()
        }
    }

    private func saveFactCheck() {
        let obj: [String: Any] = ["seeded": factCheck.seeded, "checked": factCheck.checked]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: factCheckURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: factCheckURL, options: .atomic)
    }

    func runFactCheck() {
        guard !factChecker.isRunning, !factCheck.pending.isEmpty else { return }
        let ids = Array(factCheck.pending.sorted().prefix(8))
        guard let launch = launch(prompt: ClaudeModes.factCheck(ids), sessionID: UUID().uuidString.lowercased(), resume: false,
                                  model: backgroundModel, cwd: rootURL, tools: ["Bash(kb:*)", "Read", "Grep", "Glob"]) else { return }
        factChecker.onEvent = { [weak self] event in self?.factCheckEvent(event) }
        do { try factChecker.start(launch, mode: "facts") } catch { return }
        factCheck.running = ids
        factChecker.send("check", tag: "check", show: false)
    }

    private func factCheckEvent(_ event: ClaudeEvent) {
        switch event {
        case .turnResult(let text, let isError, let tag) where tag == "check":
            finishFactCheck(text: isError ? "" : text)
        case .exited:
            if !factCheck.running.isEmpty { finishFactCheck(text: "") }
        default:
            break
        }
    }

    private func finishFactCheck(text: String) {
        let candidates = factCheckCandidates()
        for id in factCheck.running {
            factCheck.checked[id] = candidates[id] ?? "checked"
            factCheck.pending.remove(id)
        }
        factCheck.running = []
        saveFactCheck()
        factChecker.stop()
        let line = text.components(separatedBy: .newlines).first { $0.hasPrefix("FACTS") } ?? ""
        let n = Int(line.split(separator: " ").dropFirst().first ?? "") ?? 0
        if n > 0 {
            factCheck.lastSummary = "\(n) fact\(n == 1 ? "" : "s") may have changed"
            notice = "\(factCheck.lastSummary ?? ""). See Facts."
        }
        reload()
        if !factCheck.pending.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.runFactCheck() }
        }
    }
}

// MARK: Views

/// On a fact: each pending change stays here until the user decides.
struct FactChangeCard: View {
    @Environment(AppModel.self) private var model
    let change: KBEntry
    let fact: KBEntry
    @State private var showProposal = true
    @State private var confirmRemove = false

    var body: some View {
        let busy = model.busyEntries.contains(change.id)
        let proposed = change.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNewText = proposed != fact.body.trimmingCharacters(in: .whitespacesAndNewlines) || change.title != fact.title
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("This may have changed").font(.headline)
                    Text(change.field("question") ?? change.reason ?? "Something new may contradict this fact.")
                        .fixedSize(horizontal: false, vertical: true)
                    if let by = change.proposedBy {
                        HStack(spacing: 4) {
                            Text("Raised by").foregroundStyle(.secondary)
                            ProposerLink(raw: by)
                        }
                        .font(.caption)
                    }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            if hasNewText {
                DisclosureGroup(isExpanded: $showProposal) {
                    VStack(alignment: .leading, spacing: 4) {
                        if change.title != fact.title {
                            Text(change.title).font(.callout.weight(.semibold))
                        }
                        ScrollView(.vertical) {
                            MarkdownDocument(text: proposed.isEmpty ? "_(empty)_" : proposed)
                                .font(.callout)
                        }
                        .frame(maxHeight: 180)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                } label: {
                    Text("Proposed new text").font(.callout.weight(.medium))
                }
            }
            HStack(spacing: 8) {
                if hasNewText {
                    Button("Update the Fact") { model.resolveFactChange(change.id, .update) }
                        .buttonStyle(.borderedProminent)
                        .help("Replace the fact with the proposed text and mark it verified today")
                }
                Button("Still True") { model.resolveFactChange(change.id, .keep) }
                    .help("Keep the fact as it is and mark it verified today")
                Button("No Longer True…") { confirmRemove = true }
                Spacer()
                Button {
                    model.clarifyFactChange(change, fact: fact.id)
                } label: {
                    Label("Clarify with \(Brain.name)", systemImage: "sparkles")
                }
                .help("Look into it with \(Brain.name): what changed, other sources, then decide")
            }
            .disabled(busy)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .confirmationDialog("Remove “\(fact.title)”?", isPresented: $confirmRemove) {
            Button("Remove the Fact", role: .destructive) { model.resolveFactChange(change.id, .remove) }
        } message: {
            Text("The fact is deleted, with every pending change to it.")
        }
    }
}

/// The chip on a fact's row while a change waits for a decision.
struct MayHaveChangedChip: View {
    var body: some View {
        Label("May have changed", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .labelStyle(.titleAndIcon)
    }
}

/// On an entry's row: sessions working on it in Build mode.
struct InBuildChip: View {
    @Environment(AppModel.self) private var model
    let id: EntryID

    var body: some View {
        let list = model.sessions(about: id)
        if let s = list.first(where: { $0.chat.isRunning }) ?? list.first {
            Button {
                model.showInBuild(s)
            } label: {
                Label(s.crewState == .working ? "Building" : "In Build", systemImage: "hammer.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("“\(s.title)” works on this in Build mode: \(s.crewState.label.lowercased())")
        }
    }
}
