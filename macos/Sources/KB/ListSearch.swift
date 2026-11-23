import KBCore
import SwiftUI

/// The lists that have their own search field. Each keeps its text while the app runs.
enum ListSearchKey: String {
    case today, reminders, goals, inbox, followups, backlog, discussions, ideas, research, references, decisions, timeline
    case meetings, facts, architecture, overview, pullRequests, buildSessions, myWork, strategies, projectDocs, quiz

    static func section(_ s: KBSection) -> ListSearchKey {
        switch s {
        case .inbox: return .inbox
        case .followups: return .followups
        case .backlog: return .backlog
        case .discussions: return .discussions
        case .ideas: return .ideas
        case .research: return .research
        case .references: return .references
        case .decisions: return .decisions
        case .meetings: return .meetings
        case .facts: return .facts
        case .architecture: return .architecture
        case .overview: return .overview
        }
    }
}

extension AppModel {
    /// The list's search text, trimmed; empty when it isn't filtering.
    func listQuery(_ key: ListSearchKey) -> String {
        (listSearch[key.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
    }

    func listSearchBinding(_ key: ListSearchKey) -> Binding<String> {
        Binding(get: { self.listSearch[key.rawValue] ?? "" }, set: { self.listSearch[key.rawValue] = $0 })
    }
}

/// A list's own search field, in the layout above its rows. It filters only that list; the toolbar's
/// search still looks through everything.
struct ListSearchField: View {
    @Environment(AppModel.self) private var model
    let key: ListSearchKey
    let prompt: String
    var inset: CGFloat = 12
    @FocusState private var focused: Bool

    var body: some View {
        let text = model.listSearchBinding(key)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { text.wrappedValue = "" }
                .onChange(of: model.findRequest) { _, _ in if takesFind { focused = true } }
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, inset)
        .padding(.vertical, 6)
    }

    /// ⌘F lands here in Build when no conversation is in front (the factory, a pull request).
    private var takesFind: Bool {
        guard key == .buildSessions, model.mode == .build, let sel = model.buildSelection else { return false }
        return model.session(sel) == nil
    }
}

/// What a list says when its search matches nothing, in place of its rows.
struct ListSearchNoMatch: View {
    let query: String

    var body: some View {
        Text("Nothing here matches “\(query)”.")
            .foregroundStyle(.secondary)
            .font(.callout)
            .listRowSeparator(.hidden)
    }
}
