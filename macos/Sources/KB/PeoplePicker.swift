import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    func loadPeople() { engine.plan.loadPeople() }

    /// Fetches the Azure DevOps directory when it is missing or a week old, or now when forced.
    func refreshPeople(force: Bool = false) { engine.plan.refreshPeople(force: force) }

    /// Keeps someone in the knowledge base's people.json so they come first next time, with mail and initials when known.
    func remember(_ p: Person) { engine.plan.remember(p) }
}

/// Initials in a small circle; a dashed one for someone added by name only.
struct InitialsBadge: View {
    let person: Person?
    let name: String
    var size: CGFloat = 20

    var body: some View {
        let text = person?.initials ?? People.initials(name: name, email: "")
        ZStack {
            Circle().fill(person == nil || person?.isManual == true ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.18))
            Text(text.prefix(4)).font(.system(size: size * (text.count > 3 ? 0.34 : 0.42), weight: .bold))
        }
        .frame(width: size, height: size)
        .foregroundStyle(person == nil || person?.isManual == true ? Color.secondary : Color.accentColor)
    }
}

struct PersonChip: View {
    @Environment(AppModel.self) private var model
    let name: String
    var onRemove: (() -> Void)?

    var body: some View {
        let p = model.people.person(named: name)
        HStack(spacing: 5) {
            InitialsBadge(person: p, name: name, size: 18)
            Text(name).font(.callout).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove \(name)")
            }
        }
        .padding(.leading, 3)
        .padding(.trailing, onRemove == nil ? 8 : 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .help(p.map { [$0.name, $0.initials, $0.email].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "\(name), added by name")
    }
}

/// Attendees or an owner: type to search Azure DevOps people, ↑↓ and Return to pick, or Return on a name nobody
/// matches to add it as it is.
struct PeoplePicker: View {
    @Environment(AppModel.self) private var model
    @Binding var names: [String]
    var placeholder = "Add people"
    var single = false
    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let suggestions = model.people.search(text, excluding: Set(names.map { $0.lowercased() }))
        VStack(alignment: .leading, spacing: 6) {
            if !names.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(names, id: \.self) { n in
                        PersonChip(name: n) { names.removeAll { $0 == n } }
                    }
                }
            }
            if !single || names.isEmpty {
                TextField(names.isEmpty ? placeholder : (single ? placeholder : "Add more"), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { pick(suggestions) }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, suggestions.count)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !text.isEmpty else { return .ignored }
                        text = ""
                        return .handled
                    }
                    .onChange(of: text) { _, _ in highlighted = 0 }
                if focused, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    suggestionList(suggestions)
                }
            }
        }
        .onAppear { model.refreshPeople() }
    }

    private func suggestionList(_ suggestions: [Person]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, p in
                row(highlighted: i == highlighted) {
                    InitialsBadge(person: p, name: p.name)
                    Text(p.name)
                    if !p.email.isEmpty { Text(p.email).foregroundStyle(.secondary).font(.caption).lineLimit(1) }
                    if p.isManual { Text("added by name").foregroundStyle(.tertiary).font(.caption) }
                } action: { add(p.name, p) }
            }
            let free = KBEntry.oneLine(text)
            row(highlighted: highlighted == suggestions.count) {
                Image(systemName: "plus.circle").frame(width: 20)
                Text("Add “\(free)” by name")
                if suggestions.isEmpty {
                    Text(model.peopleSyncing ? "searching the directory…" : "not in Azure DevOps").foregroundStyle(.secondary).font(.caption)
                }
            } action: { add(free, nil) }
        }
        .padding(4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private func row<C: View>(highlighted: Bool, @ViewBuilder _ content: () -> C, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ suggestions: [Person]) {
        let free = KBEntry.oneLine(text)
        guard !free.isEmpty else { return }
        if highlighted < suggestions.count { add(suggestions[highlighted].name, suggestions[highlighted]) } else { add(free, nil) }
    }

    private func add(_ name: String, _ person: Person?) {
        guard !name.isEmpty else { return }
        if !names.contains(where: { $0.lowercased() == name.lowercased() }) {
            if single { names = [name] } else { names.append(name) }
        }
        model.remember(person ?? Person(name: name, source: "manual"))
        text = ""
        highlighted = 0
        focused = !single
    }
}
