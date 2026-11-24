import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    /// The parent a proposal's text or sources name, read the way `kb backlog create` reads it.
    func inferredParent(_ e: KBEntry) -> (number: Int, from: String)? {
        let sources = e.sources.compactMap { EntryID($0).flatMap { index.entry($0) } }.map { (title: $0.title, body: $0.body) }
        return WorkItemLinks.inferredParent(body: e.body, ownWorkItem: e.field("work_item"), sources: sources)
    }

    /// A related value as the user reads it: `#431549`, or the other proposal's title.
    func relatedLabel(_ value: String) -> String {
        WorkItemLinks.label(value) { v in EntryID(v).flatMap { index.entry($0) }.map { Self.shortTitle($0.title) } }
    }

    /// The work item numbers of related values: numbers as they are, entries by their created work item.
    func relatedNumbers(_ values: [String]) -> [String] {
        values.compactMap { v in Int(v) != nil ? v : EntryID(v).flatMap { index.entry($0) }?.field("work_item") }
    }

    static func shortTitle(_ s: String) -> String { s.count > 42 ? String(s.prefix(40)) + "…" : s }
}

/// A proposal's parent and related items, and a warning when its text names a parent the field doesn't have.
struct BacklogLinksRow: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry

    var body: some View {
        let parent = WorkItemLinks.parentNumber(entry.field("parent"))
        let hint = model.inferredParent(entry)
        let related = WorkItemLinks.relatedValues(entry.listField("related"))
        if parent != nil || hint != nil || !related.isEmpty {
            ChipRow(spacing: 4) {
                if let parent {
                    Chip(text: "Parent #\(parent)", color: .purple, systemImage: "arrow.up.square")
                } else if let hint, entry.backlogStatus == .proposed {
                    Chip(text: "Parent #\(hint.number) not set", color: .orange, systemImage: "exclamationmark.triangle")
                        .help("\(hint.from.prefix(1).uppercased() + hint.from.dropFirst()) names #\(hint.number) as the parent, but the entry's parent field is empty. The Create sheet fills it in.")
                }
                ForEach(related, id: \.self) { r in
                    Chip(text: "Related: \(model.relatedLabel(r))", color: .teal, systemImage: "link")
                }
            }
        }
    }
}

/// A proposal that may already exist in the tracker: the matching item and what to do about it.
struct DuplicateBox: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry
    let finding: DuplicateFinding
    @State private var confirmLink = false

    var body: some View {
        if let best = finding.best {
            let likely = finding.verdict == .likely
            let color: Color = likely ? .red : .orange
            let busy = model.busyEntries.contains(entry.id)
            VStack(alignment: .leading, spacing: 6) {
                ChipRow(spacing: 6) {
                    Chip(text: "\(likely ? "Likely" : "Possible") duplicate of \(AppModel.shortTitle(best.label))", color: color, systemImage: "doc.on.doc")
                    if !best.state.isEmpty { Chip(text: best.state) }
                }
                matchTitle(best)
                if !best.reasons.isEmpty {
                    Text(best.reasons.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if finding.matches.count > 1 {
                    Text("Also close: " + finding.matches.dropFirst().map(\.label).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(likely ? "It looks like this already exists. It won't be created until you drop it or say it isn't a duplicate."
                     : "Check it before creating this one. It won't be created until you decide.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 8, centered: true) {
                    Button("Drop It") { model.dropDuplicate(entry.id, of: best, comment: false) }
                        .buttonStyle(.borderedProminent)
                        .tint(likely ? .red : .accentColor)
                        .help("Reject this proposal as a duplicate of \(best.label)")
                    if best.number != nil {
                        Button("Link Instead…") { confirmLink = true }
                            .help("Add what this proposal says to \(best.label), then drop the proposal")
                    }
                    Button("Not a Duplicate") { model.markNotDuplicate(entry.id, of: finding.matches) }
                }
                .controlSize(.small)
                .disabled(busy)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .confirmationDialog("Use \(best.label) instead of this proposal?", isPresented: $confirmLink, titleVisibility: .visible) {
                Button("Add Its Notes to \(best.label) as a Comment") { model.dropDuplicate(entry.id, of: best, comment: true) }
                let related = model.relatedNumbers(WorkItemLinks.relatedValues(entry.listField("related")))
                if !related.isEmpty {
                    Button("Link \(best.label) to \(related.map { "#\($0)" }.joined(separator: ", "))") {
                        model.linkInsteadOfDuplicate(entry.id, of: best, related: related)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This writes to \(best.label) in the tracker, then drops the proposal here. KB links stay out of the comment.")
            }
        }
    }

    @ViewBuilder
    private func matchTitle(_ m: DuplicateMatch) -> some View {
        if let u = URL(string: m.url), m.url.hasPrefix("http") {
            Link(m.title, destination: u).font(.callout.weight(.semibold)).multilineTextAlignment(.leading)
        } else if m.kind != .workItem, let id = EntryID(m.id) {
            Button(m.title) { model.openNow(id) }.buttonStyle(.link).font(.callout.weight(.semibold)).multilineTextAlignment(.leading)
        } else {
            Text(m.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
