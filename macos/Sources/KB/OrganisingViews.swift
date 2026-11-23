import KBCore
import SwiftUI

extension AppModel {
    static let myNameKey = "myName"

    /// The names the user goes by: the one in Settings, else their Azure DevOps account.
    var myNames: [String] {
        let typed = UserDefaults.standard.string(forKey: Self.myNameKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return [typed, tracker?.me ?? "", myWork?.me ?? ""].filter { !$0.isEmpty }
    }

    // MARK: Follow-up merges

    func mergeFollowups(keep: String, other: String) {
        runKB(["followup", "merge", keep, other], busy: EntryID(keep)) { [weak self] _ in
            self?.notice = "Merged. The follow-up kept every source link."
        }
    }

    func dismissMerge(_ p: FollowupMergeProposal) {
        runKB(["followup", "merges", "--dismiss", p.keep, p.other], busy: nil) { _ in }
    }

    /// Claude reads the open follow-ups of a scope and proposes merging the ones that say the same thing.
    func findDuplicateFollowups(project: String) {
        guard !findingDuplicates else { return }
        findingDuplicates = true
        let prompt = "List the open follow-ups of scope `\(project)` (`kb list --section followups --project \(project)`; read any you need with `kb show <id>`). Find pairs that ask or do the same thing, even in different words; a follow-up merely on the same topic is not a duplicate. For each pair run `kb followup propose-merge <the one to keep> <the duplicate> --why '<one line>'`, keeping the one with more detail. Change nothing else. Reply with one line: `PROPOSED <n>`."
        Task {
            let reply = await claudeOnce(prompt, system: "You find duplicate follow-ups in a knowledge base and propose merges; the user decides.",
                                         model: backgroundModel, tools: ["Bash(kb:*)", "Read"], timeout: 240)
            findingDuplicates = false
            reload()
            let n = reply.flatMap { r in r.components(separatedBy: "PROPOSED ").last.flatMap { Int($0.prefix { $0.isNumber }) } } ?? 0
            notice = n == 0 ? "No duplicate follow-ups found." : "Found \(n) possible duplicate\(n == 1 ? "" : "s"). Review them at the top of Follow-ups."
        }
    }

    // MARK: Fact links

    func linkFacts(_ a: EntryID, _ b: EntryID, remove: Bool = false) {
        runKB(["fact", "link", a.rawValue, b.rawValue] + (remove ? ["--remove"] : []), busy: a) { _ in }
    }

    /// Claude compares the fact with the others in its project and suggests related ones, for the user to accept or reject.
    func suggestFactLinks(_ id: EntryID) {
        guard let fact = index.entry(id), !suggestingLinks.contains(id) else { return }
        let linked = Set(index.linkedFacts(of: id).map(\.id))
        let rejected = Set(factLinkRejected[id.rawValue] ?? [])
        let scopes = Set([id.project] + index.siblings(of: id.project).map(\.id))
        let others = index.entries.values.filter {
            $0.section == .facts && $0.id != id && !$0.isDraft && scopes.contains($0.id.project)
                && !linked.contains($0.id) && !rejected.contains($0.id.rawValue)
        }
        guard !others.isEmpty else {
            notice = "No other facts to link to."
            return
        }
        suggestingLinks.insert(id)
        let list = others.sorted { $0.id.rawValue < $1.id.rawValue }.prefix(300)
            .map { "- \($0.id.rawValue): \($0.title)\($0.summary.isEmpty ? "" : " — \($0.summary.prefix(160))")" }
            .joined(separator: "\n")
        let prompt = """
        The fact:
        \(fact.title)
        \(fact.summary)
        \(fact.body.prefix(1500))

        Other facts:
        \(list)

        Which other facts are directly related to this one: one depends on, explains, contradicts or completes the other \
        (for example "the BFF issues tokens" and "the device validates them")? Sharing a word or an area isn't enough. \
        Reply with only a JSON array, at most 6, best first: [{"id": "<id>", "why": "<a few words>"}], or [] for none.
        """
        let candidates = Set(others.map(\.id.rawValue))
        Task {
            let reply = await claudeOnce(prompt, system: "You suggest links between facts in a knowledge base. Reply with JSON only.",
                                         model: backgroundModel)
            suggestingLinks.remove(id)
            let found = FactLinkSuggestion.parse(reply ?? "", candidates: candidates)
            factLinkSuggestions[id.rawValue] = found
            if found.isEmpty { notice = "\(Brain.name) found no closely related facts." }
        }
    }

    func acceptLinkSuggestion(_ s: FactLinkSuggestion, for id: EntryID) {
        factLinkSuggestions[id.rawValue]?.removeAll { $0 == s }
        if let other = EntryID(s.id) { linkFacts(id, other) }
    }

    func rejectLinkSuggestion(_ s: FactLinkSuggestion, for id: EntryID) {
        factLinkSuggestions[id.rawValue]?.removeAll { $0 == s }
        factLinkRejected[id.rawValue, default: []].append(s.id)
        saveFactLinkRejected()
    }

    private var factLinkRejectedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KB/factlinks-rejected.json")
    }

    func loadFactLinkRejected() {
        guard let data = try? Data(contentsOf: factLinkRejectedURL),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        factLinkRejected = map
    }

    private func saveFactLinkRejected() {
        guard let data = try? JSONEncoder().encode(factLinkRejected) else { return }
        try? FileManager.default.createDirectory(at: factLinkRejectedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: factLinkRejectedURL, options: .atomic)
    }

    /// Runs a `kb` command, then reloads; `done` gets its output. Errors go to the alert.
    func runKB(_ args: [String], busy: EntryID?, done: @escaping @MainActor (String) -> Void) {
        let cli = cli
        if let busy { busyEntries.insert(busy) }
        Task {
            defer { if let busy { busyEntries.remove(busy) } }
            do {
                let out = try await cli.run(args)
                reload()
                done(out)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A date that may be left out: a Set button while there is none, a date picker and a clear button once set.
struct OptionalDateField: View {
    @Binding var value: String

    var body: some View {
        HStack(spacing: 6) {
            if let date = KBDate.parse(value) {
                DatePicker("", selection: Binding(get: { date }, set: { value = KBDate.today($0) }), displayedComponents: .date)
                    .labelsHidden()
                    .fixedSize()
                Button { value = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("No due date")
            } else {
                Button("Set Due Date") { value = KBDate.today(Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()) }
                    .buttonStyle(.link)
                if !value.isEmpty {
                    Text(value).foregroundStyle(.secondary).help("Not a date Mindmill can read; set one to replace it")
                }
            }
        }
    }
}

/// At the top of Follow-ups: two that may say the same thing, to merge or keep apart.
struct MergeProposalCard: View {
    @Environment(AppModel.self) private var model
    let proposal: FollowupMergeProposal

    var body: some View {
        let keep = EntryID(proposal.keep).flatMap { model.index.entry($0) }
        let other = EntryID(proposal.other).flatMap { model.index.entry($0) }
        if let keep, let other {
            VStack(alignment: .leading, spacing: 6) {
                Label("These may say the same thing", systemImage: "arrow.triangle.merge")
                    .font(.callout.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("• " + keep.title).fixedSize(horizontal: false, vertical: true)
                    Text("• " + other.title).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                if let why = proposal.why, !why.isEmpty {
                    Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ChipRow(spacing: 8) {
                    Button("Merge") { model.mergeFollowups(keep: proposal.keep, other: proposal.other) }
                        .buttonStyle(.borderedProminent)
                        .help("Keep “\(keep.title)” with the sources, tags, due date and notes of both; the other is closed as merged")
                    Button("Not the Same") { model.dismissMerge(proposal) }
                        .help("Keep both; Mindmill won't suggest merging these again")
                }
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }
}

/// On a fact: the facts it is linked to, adding and removing links, and Claude's suggestions to accept or reject.
struct LinkedFactsSection: View {
    @Environment(AppModel.self) private var model
    let id: EntryID
    @State private var adding = false
    @State private var query = ""

    var body: some View {
        let linked = model.index.linkedFacts(of: id)
        let suggestions = model.factLinkSuggestions[id.rawValue] ?? []
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Linked facts").font(.headline)
                Spacer(minLength: 4)
                if model.suggestingLinks.contains(id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Suggest") { model.suggestFactLinks(id) }
                        .buttonStyle(.link)
                        .disabled(!model.claudeAvailable)
                        .help("\(Brain.name) looks for facts that depend on, explain or complete this one")
                }
                Button(adding ? "Done" : "Link a Fact…") { adding.toggle(); query = "" }
                    .buttonStyle(.link)
            }
            if linked.isEmpty && suggestions.isEmpty && !adding {
                Text("None yet.").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(linked) { f in
                HStack(spacing: 6) {
                    EntryLink(raw: f.id.rawValue)
                    Spacer(minLength: 4)
                    Button { model.linkFacts(id, f.id, remove: true) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove this link")
                }
            }
            ForEach(suggestions, id: \.id) { s in
                AdaptiveCardLayout(spacing: 8, stackedSpacing: 4, minInfoWidth: 180) {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(EntryID(s.id).flatMap { model.index.entry($0)?.title } ?? s.id)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(s.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Button("Link") { model.acceptLinkSuggestion(s, for: id) }
                        Button("No") { model.rejectLinkSuggestion(s, for: id) }
                            .help("Not related; it won't be suggested again")
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                .font(.callout)
            }
            if adding { picker(excluding: Set(linked.map(\.id))) }
        }
    }

    @ViewBuilder
    private func picker(excluding: Set<EntryID>) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let scopes = Set([id.project] + model.index.siblings(of: id.project).map(\.id))
        let matches = model.index.entries.values
            .filter { $0.section == .facts && $0.id != id && !excluding.contains($0.id) && scopes.contains($0.id.project)
                && (q.isEmpty || $0.matches(q)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .prefix(8)
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search facts", text: $query)
                .textFieldStyle(.roundedBorder)
            ForEach(Array(matches)) { f in
                Button {
                    model.linkFacts(id, f.id)
                    query = ""
                } label: {
                    Label(f.title, systemImage: "link").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }
            if matches.isEmpty { Text("No facts match.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
