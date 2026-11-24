import AppKit
import KBCore
import KBEngine
import SwiftUI

/// A follow-up's facts in the detail view: who, when, where it came from, and, once closed, how it was resolved.
struct FollowupFacts: View {
    @Environment(AppModel.self) private var model
    let fm: Frontmatter

    var body: some View {
        let status = FollowupStatus(rawValue: fm.string("status") ?? "open") ?? .open
        let answer = fm.string("summary") ?? ""
        let resolvedBy = fm.string("resolved_by") ?? ""
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    FieldLabel("Kind")
                    Text(fm.string("kind") == "question" ? "Question" : "Action")
                }
                if let owner = fm.string("owner"), !owner.isEmpty, !FollowupResponsibility.isMe(owner, me: model.myNames) {
                    GridRow {
                        FieldLabel("Owner")
                        Text(owner).textSelection(.enabled)
                    }
                }
                if let waiting = fm.string("waiting_on"), !waiting.isEmpty, !FollowupResponsibility.isMe(waiting, me: model.myNames) {
                    GridRow {
                        FieldLabel("Waiting on")
                        Text(waiting).textSelection(.enabled)
                    }
                }
                if let due = fm.string("due"), !due.isEmpty {
                    GridRow {
                        FieldLabel("Due")
                        Text(DateText.display(due))
                    }
                }
                GridRow {
                    FieldLabel("Raised in")
                    if !fm.list("raised_in").isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(fm.list("raised_in"), id: \.self) { SourceView(source: $0) }
                        }
                    } else {
                        Text("Not recorded. Add it with Edit (⌘E).").foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.callout)
            if status != .open {
                resolution(status: status, answer: answer, resolvedBy: resolvedBy)
            } else if !answer.isEmpty {
                Text(answer).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func resolution(status: FollowupStatus, answer: String, resolvedBy: String) -> some View {
        let parsed = ResolvedBy(values: fm.list("resolved_by"))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: status == .done ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(status == .done ? Color.green : .secondary)
                Text(status == .done ? "Done" : "Dropped").font(.title3.weight(.semibold))
            }
            if !answer.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(fm.string("kind") == "question" ? "ANSWER" : "HOW").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text(answer).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("RESOLVED BY").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Spacer()
                    if parsed.items.count > 1 {
                        CopyButton(label: "Copy All", text: parsed.items.map(ResolvedBy.copyText).joined(separator: "\n"))
                    }
                }
                if resolvedBy.isEmpty {
                    Text(status == .done ? "Not recorded. Add it with Edit (⌘E)." : "Nothing; it was dropped.")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(parsed.items, id: \.self) { ResolvedByRow(item: $0) }
                    if !parsed.text.isEmpty {
                        Text(parsed.text).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((status == .done ? Color.green : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder((status == .done ? Color.green : Color.secondary).opacity(0.25)))
    }
}

/// One thing that resolved a follow-up, on its own line: open it, or copy it.
struct ResolvedByRow: View {
    @Environment(AppModel.self) private var model
    let item: ResolvedBy.Item

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Button(action: open) {
                    Text(title).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                }
                .buttonStyle(.link)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            CopyButton(label: "Copy", text: ResolvedBy.copyText(item))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch item {
        case .entry(let id): return SidebarView.icon(id.section)
        case .workItem: return "list.bullet.rectangle.portrait"
        case .url: return "link"
        }
    }

    private var title: String {
        switch item {
        case .entry(let id): return model.index.entry(id)?.title ?? id.stem
        case .workItem(let n, _): return "Work item #\(n)"
        case .url(let u): return u.host ?? u.absoluteString
        }
    }

    private var detail: String {
        switch item {
        case .entry(let id): return "\(id.section.singularTitle) · \(id.rawValue)"
        case .workItem(_, let u), .url(let u): return u.absoluteString
        }
    }

    private func open() {
        switch item {
        case .entry(let id): model.openLink(id.rawValue)
        case .workItem(_, let u), .url(let u): NSWorkspace.shared.open(u)
        }
    }
}

struct CopyButton: View {
    let label: String
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .controlSize(.small)
        .help("Copy to the clipboard")
    }
}
