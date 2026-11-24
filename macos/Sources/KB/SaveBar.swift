import KBCore
import KBEngine
import SwiftUI

/// Under the editor whenever there is something to save: a draft to turn into a real entry, or unsaved edits.
struct SaveBar: View {
    @Environment(AppModel.self) private var model
    let doc: EntryDocument
    @State private var confirmDiscard = false

    var body: some View {
        HStack(spacing: 10) {
            if doc.isDraft {
                Image(systemName: "doc.badge.ellipsis").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Draft").font(.callout.weight(.semibold))
                    Text("Kept under Drafts until you save it. \(Brain.name) doesn't see drafts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                Text("Unsaved changes").font(.callout.weight(.semibold))
            }
            Spacer()
            Button(doc.isDraft ? "Discard Draft…" : "Discard Changes", role: .destructive) {
                if doc.isDraft { confirmDiscard = true } else { model.discardChanges() }
            }
            Button {
                model.save()
            } label: {
                Text("Save").frame(minWidth: 60)
            }
            .buttonStyle(.borderedProminent)
            .help("Save (⌘S)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .confirmationDialog("Discard the draft “\(doc.title)”?", isPresented: $confirmDiscard) {
            Button("Discard Draft", role: .destructive) { model.discardDraft() }
        } message: {
            Text("It is deleted.")
        }
    }
}

extension AppModel {
    func discardDraft() {
        guard let doc = document, doc.isDraft else { return }
        try? FileManager.default.removeItem(at: doc.url)
        closeDocument()
        reload()
        notice = "Draft discarded."
    }

    /// Back to what is on disk.
    func discardChanges() {
        guard let doc = document else { return }
        if doc.isNew {
            closeDocument()
        } else {
            openNow(doc.id)
        }
    }
}

/// The section's drafts, at the top of its list.
struct DraftsSection: View {
    let drafts: [KBEntry]

    var body: some View {
        if !drafts.isEmpty {
            Section {
                ForEach(drafts) { e in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.ellipsis").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.headline).lineLimit(2)
                            Text(DateText.display(e.date)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Draft")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    .padding(.vertical, 3)
                    .tag(e.id)
                    .entryContextMenu(e.id)
                }
            } header: {
                Text("Drafts · \(drafts.count)")
            }
        }
    }
}
