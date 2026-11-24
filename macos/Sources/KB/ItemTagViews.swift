import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    func itemTagKey(_ item: TrackerBacklog.Item) -> String {
        ItemTags.key(kind: trackerKind(item.scope), id: String(item.id))
    }

    func localTags(_ item: TrackerBacklog.Item) -> [String] { itemTags.tags(itemTagKey(item)) }

    /// Mindmill's tags and the tool's together, for filtering a backlog.
    func allTags(_ item: TrackerBacklog.Item) -> [String] { EntryTags.normalized(localTags(item) + item.tags) }

    func updateItemTags(_ change: (inout ItemTags) -> Void) {
        var store = itemTags
        change(&store)
        guard store != itemTags else { return }
        do {
            try store.save(root: rootURL)
            itemTags = store
        } catch {
            errorMessage = "Could not save the tags: \(error.localizedDescription)"
        }
    }

    /// The tool tags can be written only to Azure DevOps for now; the others are reached through Claude's connectors.
    func canAlignTags(_ item: TrackerBacklog.Item) -> Bool { engine.backlog.canAlignTags(item) }

    /// Writes the item's aligned tags to the tool, after the user confirmed exactly these.
    func alignTags(_ item: TrackerBacklog.Item) {
        busyWorkItems.insert(item.id)
        Task {
            defer { busyWorkItems.remove(item.id) }
            do {
                notice = try await engine.backlog.alignTags(item)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// On a work item: the tool's own tags, read-only, and Mindmill's tags beside them, with the opt-in to write some to the tool.
struct WorkItemTagRows: View {
    @Environment(AppModel.self) private var model
    let item: TrackerBacklog.Item
    @State private var confirming = false

    var body: some View {
        let key = model.itemTagKey(item)
        let local = model.localTags(item)
        let pending = model.itemTags.pending(for: key, toolTags: item.tags)
        let tool = model.trackerKind(item.scope) == "azure-devops" ? "Azure DevOps" : "the tracker"
        if !item.tags.isEmpty {
            GridRow {
                Text("Tags in \(tool == "Azure DevOps" ? tool : "tracker")").foregroundStyle(.secondary)
                ChipRow(spacing: 4) { ForEach(item.tags, id: \.self) { Chip(text: $0) } }
                    .help("The tool's own tags. Mindmill never changes them.")
            }
        }
        GridRow {
            Text("Your tags").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                TagEditor(tags: local) { tags in model.updateItemTags { $0.setTags(tags, for: key) } }
                    .help("Kept in your knowledge base only. They reach \(tool) only for tags you align.")
                if !local.isEmpty, model.canAlignTags(item) {
                    ChipRow(spacing: 8) {
                        Menu {
                            Section("Write to \(tool) for this item") {
                                ForEach(local, id: \.self) { tag in
                                    Toggle(tag, isOn: Binding(
                                        get: { model.itemTags.items[key]?.aligned.contains(tag) ?? false },
                                        set: { on in model.updateItemTags { $0.setAligned(tag, on, for: key) } }))
                                }
                            }
                            Section("Write to \(tool) on every item that has it") {
                                ForEach(local, id: \.self) { tag in
                                    Toggle(tag, isOn: Binding(
                                        get: { model.itemTags.alignedTags.contains(tag) },
                                        set: { on in model.updateItemTags { $0.setAlignedEverywhere(tag, on) } }))
                                }
                            }
                        } label: {
                            Label("Align Tags", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Off by default. Pick tags to add to \(tool) as well; nothing is written until you confirm.")
                        if !pending.isEmpty {
                            Button("Write \(pending.count) to \(tool)…") { confirming = true }
                                .controlSize(.small)
                                .disabled(model.busyWorkItems.contains(item.id))
                        }
                    }
                    .font(.caption)
                }
            }
            .confirmationDialog("Add \(pending.joined(separator: ", ")) to #\(String(item.id)) in \(tool)?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Add \(pending.count == 1 ? "Tag" : "Tags")") { model.alignTags(item) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are added beside the item's own tags, which stay as they are. The team sees them.")
            }
        }
    }
}
