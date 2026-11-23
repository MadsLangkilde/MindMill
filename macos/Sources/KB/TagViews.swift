import KBCore
import SwiftUI

/// One tag as a small tinted capsule. With `key`, clicking it filters that list by the tag.
struct TagChip: View {
    @Environment(AppModel.self) private var model
    let tag: String
    var key: ListSearchKey?

    var body: some View {
        let label = Text(tag)
            .lineLimit(1)
            .fixedSize()
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.10), in: Capsule())
        if let key {
            Button {
                var picked = model.tagSelection(key)
                picked.insert(tag)
                model.setTagSelection(key, picked)
            } label: { label }
            .buttonStyle(.plain)
            .help("Show only items tagged \(tag)")
        } else {
            label
        }
    }
}

/// A row's tags, inside its chip row: a couple show as they are; more fold into one "n tags" pill that opens them.
struct TagChips: View {
    let tags: [String]
    var key: ListSearchKey?
    @State private var showing = false

    static let inlineLimit = 2

    var body: some View {
        if tags.count <= Self.inlineLimit {
            ForEach(tags, id: \.self) { TagChip(tag: $0, key: key) }
        } else {
            Button { showing.toggle() } label: {
                Label("\(tags.count) tags", systemImage: "tag")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .fixedSize()
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(tags.joined(separator: ", "))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                FlowLayout(spacing: 5, centered: false) {
                    ForEach(tags, id: \.self) { TagChip(tag: $0, key: key) }
                }
                .padding(12)
                .frame(width: 280)
            }
        }
    }
}

/// Under a list's search field: pick tags to show only the items that have all of them. Hidden while the list has
/// no tags at all.
struct TagFilterBar: View {
    @Environment(AppModel.self) private var model
    let key: ListSearchKey
    /// The tags of the list's items, before filtering.
    let available: [[String]]
    var inset: CGFloat = 12

    var body: some View {
        let picked = model.tagSelection(key)
        let vocab = EntryTags.vocabulary(available)
        if !vocab.isEmpty || !picked.isEmpty {
            ChipRow(spacing: 6) {
                Menu {
                    ForEach(vocab, id: \.tag) { v in
                        Toggle("\(v.tag)  (\(v.count))", isOn: Binding(
                            get: { picked.contains(v.tag) },
                            set: { on in
                                var p = picked
                                if on { p.insert(v.tag) } else { p.remove(v.tag) }
                                model.setTagSelection(key, p)
                            }))
                    }
                } label: {
                    Label(picked.isEmpty ? "Tags" : "Tags · \(picked.count)", systemImage: "tag")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Show only the items that have every tag you pick")
                ForEach(picked.sorted(), id: \.self) { tag in
                    Button {
                        var p = picked
                        p.remove(tag)
                        model.setTagSelection(key, p)
                    } label: {
                        HStack(spacing: 3) {
                            Text(tag).lineLimit(1)
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .fixedSize()
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Stop filtering by \(tag)")
                }
                if picked.count > 1 {
                    Button("Clear") { model.setTagSelection(key, []) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.bottom, 4)
        }
    }
}

/// What a filtered list says when the tags leave nothing, in place of its rows.
struct TagFilterNoMatch: View {
    @Environment(AppModel.self) private var model
    let key: ListSearchKey

    var body: some View {
        HStack(spacing: 6) {
            Text("Nothing here has every picked tag.").foregroundStyle(.secondary)
            Button("Clear Tags") { model.setTagSelection(key, []) }.buttonStyle(.link)
        }
        .font(.callout)
        .listRowSeparator(.hidden)
    }
}

/// An item's tags with a remove button each, and a field to add one. `set` receives the new list.
struct TagEditor: View {
    @Environment(AppModel.self) private var model
    let tags: [String]
    let set: ([String]) -> Void
    @State private var adding = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        ChipRow(spacing: 5) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 3) {
                    Text(tag).lineLimit(1)
                    Button {
                        set(tags.filter { $0 != tag })
                    } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(tag). The automatic tagger won't add it back.")
                }
                .fixedSize()
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.10), in: Capsule())
            }
            if adding {
                TextField("tag", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 120)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { adding = false; draft = "" }
                let others = model.tagVocabulary.filter { !tags.contains($0) }
                if !others.isEmpty {
                    Menu("Existing") {
                        ForEach(others.prefix(40), id: \.self) { t in
                            Button(t) { set(tags + [t]); adding = false; draft = "" }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                }
            } else {
                Button {
                    adding = true
                    focused = true
                } label: {
                    Label(tags.isEmpty ? "Add Tag" : "Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Tags name areas and systems, like auth or bff, so you can follow one area across the knowledge base")
            }
        }
    }

    private func commit() {
        let new = draft.split(separator: ",").map(String.init)
        if !new.isEmpty { set(tags + new) }
        draft = ""
        adding = false
    }
}
