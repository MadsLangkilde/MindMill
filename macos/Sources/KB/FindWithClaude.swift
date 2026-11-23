import KBCore
import SwiftUI

/// What Claude found for a half-remembered search in Plan.
struct ClaudeFind: Equatable {
    struct Hit: Identifiable, Equatable {
        let id: EntryID
        let why: String
    }

    var query = ""
    var running = false
    var hits: [Hit] = []
    var failed = false
}

extension AppModel {
    /// Has Claude search the KB with its own words and synonyms for something the user only vaguely remembers.
    func findWithClaude(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !(claudeFind.running && claudeFind.query == q) else { return }
        claudeFind = ClaudeFind(query: q, running: true)
        let scope = searchAllProjects ? nil : projectID
        Task {
            let reply = await claudeOnce(ClaudeModes.find(q, scope: scope),
                                         system: "You search the user's knowledge base with the kb command line tool and reply with JSON only.",
                                         tools: ["Bash(kb:*)", "Read", "Grep", "Glob"], timeout: 180)
            guard claudeFind.query == q else { return }
            var seen = Set<EntryID>()
            let hits = ClaudeModes.parseFind(reply ?? "").compactMap { h -> ClaudeFind.Hit? in
                guard let id = EntryID(h.id), index.entry(id) != nil, seen.insert(id).inserted else { return nil }
                return ClaudeFind.Hit(id: id, why: h.why)
            }
            claudeFind = ClaudeFind(query: q, running: false, hits: hits, failed: reply == nil)
        }
    }
}

/// At the top of Plan's search results: entries that have most of the words, and Claude's search for what the
/// user describes.
struct VagueSearchSection: View {
    @Environment(AppModel.self) private var model
    let query: String
    let strictCount: Int

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let find = model.claudeFind
        let loose = strictCount < 5 ? model.index.looseSearch(q, project: model.searchAllProjects ? nil : model.projectID, limit: 12) : []
        Section {
            if find.query == q && (find.running || !find.hits.isEmpty || find.failed) {
                if find.running {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(Brain.name) is looking with other words and synonyms…").foregroundStyle(.secondary)
                    }
                } else if find.failed {
                    Text("\(Brain.name) couldn't search right now.").foregroundStyle(.secondary)
                } else {
                    ForEach(find.hits) { hit in
                        if let e = model.index.entry(hit.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                EntryRow(entry: e, showSection: true)
                                if !hit.why.isEmpty {
                                    Label(hit.why, systemImage: "sparkles").font(.caption).foregroundStyle(Color.accentColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .tag(e.id).entryContextMenu(e.id)
                        }
                    }
                }
            } else if find.query == q && !find.running {
                Text("\(Brain.name) found nothing that fits. Try describing it differently.").foregroundStyle(.secondary)
            } else {
                Button {
                    model.findWithClaude(q)
                } label: {
                    Label("Ask \(Brain.name) to find “\(q)”", systemImage: "sparkles")
                }
                .buttonStyle(.borderless)
                .disabled(!model.claudeAvailable)
                .help("Describe what you remember, in your own words. \(Brain.name) searches with other words and synonyms, in every section.")
            }
        } header: {
            HStack {
                Image(systemName: "sparkles")
                Text("Can't find it? Describe it")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        if !loose.isEmpty {
            Section {
                ForEach(loose) { e in EntryRow(entry: e, showSection: true).tag(e.id).entryContextMenu(e.id) }
            } header: {
                HStack {
                    Image(systemName: "text.magnifyingglass")
                    Text("Close matches")
                    Spacer()
                    Text("\(loose.count)").monospacedDigit()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
    }
}
