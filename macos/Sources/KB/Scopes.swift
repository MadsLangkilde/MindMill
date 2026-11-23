import KBCore
import SwiftUI

extension AppModel {
    var selectedGroup: KBGroup? { projectID.flatMap { index.group(of: $0) } }

    /// Other scopes of the project that the text names ("Android", "iOS", "Comet"…), for one-click tagging.
    func suggestedScopes(text: String, in scope: String, excluding: [String] = []) -> [KBProject] {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return [] }
        let group = [index.project(scope)].compactMap { $0 } + index.siblings(of: scope)
        let shared = Self.sharedWords(group)
        return index.siblings(of: scope).filter { s in
            !s.wide && !excluding.contains(s.id) && Self.keywords(of: s).subtracting(shared).contains { word in
                lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
            }
        }
    }

    static func keywords(of s: KBProject) -> Set<String> {
        let generic: Set<String> = ["product", "wide", "project", "catalog", "shared", "the", "and", "app", "firmware"]
        let words = (s.title + " " + s.id.replacingOccurrences(of: "-", with: " "))
            .lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words.filter { $0.count >= 3 && !generic.contains($0) })
    }

    /// Words in the name of every scope of a project, like the company's name: they say nothing about which scope.
    static func sharedWords(_ scopes: [KBProject]) -> Set<String> {
        guard scopes.count > 2 else { return [] }
        let sets = scopes.map(keywords(of:))
        var counts: [String: Int] = [:]
        for s in sets { for w in s { counts[w, default: 0] += 1 } }
        return Set(counts.filter { $0.value * 2 > sets.count }.map(\.key))
    }

    /// Sets the open entry's scopes (the folder's scope always stays) and saves unless it is being edited.
    func setScopes(_ scopes: [String]) {
        guard let doc = document else { return }
        let extra = scopes.filter { $0 != doc.id.project }
        document?.frontmatter.set("scopes", extra.isEmpty ? nil : .list([doc.id.project] + extra))
        markScopesManual([doc.id])
        if !isEditing && !doc.isDraft { save(publish: false) }
    }
}

/// Scope chips that toggle; a suggested one is outlined with a sparkle.
struct ScopeToggles: View {
    let scopes: [KBProject]
    @Binding var selected: Set<String>
    var suggested: Set<String> = []

    var body: some View {
        ChipRow(spacing: 6) {
            ForEach(scopes) { s in
                let on = selected.contains(s.id)
                Button {
                    if on { selected.remove(s.id) } else { selected.insert(s.id) }
                } label: {
                    HStack(spacing: 3) {
                        if on { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                        else if suggested.contains(s.id) { Image(systemName: "sparkles").font(.caption2) }
                        Text(s.title).lineLimit(1)
                    }
                    .fixedSize()
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(on ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(suggested.contains(s.id) && !on ? Color.accentColor : .clear))
                }
                .buttonStyle(.plain)
                .help(suggested.contains(s.id) && !on ? "It mentions \(s.title): add it to that scope too" : s.title)
            }
        }
    }
}

/// On an entry: the scopes it is in, and the ones its text suggests.
struct EntryScopesRow: View {
    @Environment(AppModel.self) private var model
    let doc: EntryDocument

    var body: some View {
        let siblings = model.index.siblings(of: doc.id.project)
        if !siblings.isEmpty {
            let current = Set(doc.frontmatter.list("scopes"))
            let text = [doc.title, doc.frontmatter.string("summary") ?? "", doc.body].joined(separator: " ")
            let suggested = Set(model.suggestedScopes(text: text, in: doc.id.project, excluding: Array(current)).map(\.id))
            ScopeToggles(scopes: [model.index.project(doc.id.project)].compactMap { $0 } + siblings,
                         selected: Binding(get: { current.union([doc.id.project]) },
                                           set: { model.setScopes(Array($0)) }),
                         suggested: suggested)
                .help(model.isScopedByHand(doc.id)
                      ? "You set these scopes; they stay as you set them. Click a scope to add or remove it."
                      : "Set automatically from what the entry says. Click a scope to add or remove it; from then on they stay as you set them.")
        }
    }
}

/// On a list row: the entry's other scopes than the one being viewed.
struct ScopeChips: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry

    var body: some View {
        let others = entry.scopes.filter { $0 != model.projectID }
        if entry.scopes.count > 1 || entry.project != model.projectID {
            ForEach(others, id: \.self) { s in
                Text(model.index.project(s)?.title ?? s)
                    .lineLimit(1)
                    .fixedSize()
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                    .help("Also in " + (model.index.project(s)?.title ?? s))
            }
        }
    }
}
