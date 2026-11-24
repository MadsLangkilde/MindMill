import KBCore
import SwiftUI

/// A field that searches the scope's tracker by id or title as you type and lists the matches under it, in the layout.
/// Picking one hands it to `onPick` and clears the field.
struct WorkItemSearchField: View {
    @Environment(AppModel.self) private var model
    let scope: String
    var prompt = "Search by id or title"
    /// Ids not to offer (already picked).
    var exclude: Set<Int> = []
    let onPick: (FoundWorkItem) -> Void
    @State private var query = ""
    @State private var results: [FoundWorkItem] = []
    @State private var searching = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField(prompt, text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { if let first = shown.first { pick(first) } }
                if searching { ProgressView().controlSize(.small) }
            }
            let q = query.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if let failure {
                        Text(failure).font(.caption).foregroundStyle(.secondary).padding(6)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if shown.isEmpty && !searching {
                        Text("Nothing matches “\(q)”.").font(.caption).foregroundStyle(.secondary).padding(6)
                    }
                    ForEach(shown) { item in
                        Button { pick(item) } label: { WorkItemLine(item: item).padding(.horizontal, 6).padding(.vertical, 4) }
                            .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .task(id: query) { await search() }
    }

    private var shown: [FoundWorkItem] { results.filter { !exclude.contains($0.id) } }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = []
            failure = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await model.cli.trackerFind(q, scope: scope)
            guard !Task.isCancelled else { return }
            results = found
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            failure = "Couldn't search the tracker: \(error.localizedDescription)"
        }
    }

    private func pick(_ item: FoundWorkItem) {
        onPick(item)
        query = ""
        results = []
    }
}

/// "#123 · PBI · Title · Active", wrapping rather than cut off.
struct WorkItemLine: View {
    let item: FoundWorkItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "#\(item.id)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(item.typeTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(item.title).font(.callout).fixedSize(horizontal: false, vertical: true)
            if !item.state.isEmpty { Text(item.state).font(.caption).foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
