import KBCore
import KBEngine
import SwiftUI

extension AppModel {
    func showProposedFactsPane() {
        navigate { [self] in
            multiSelection = []
            closeDocument()
            showProposedFacts = true
        }
    }

    /// Answers a question about a proposed fact before it is approved, from the fact, where it came from and the KB.
    func askAboutProposal(_ entry: KBEntry, question: String) async -> String? {
        let prompt = """
        A fact was proposed for my knowledge base and I'm deciding whether to approve it. Answer my question about it \
        briefly and plainly. Look things up when it helps: where it came from (`kb show <id>` on the proposer), related \
        entries (`kb search <words>`), the facts already saved. Say so when you can't tell.

        The proposed fact: \(entry.title)
        \(entry.summary)
        \(entry.body.prefix(2000))
        \(entry.reason.map { "Why it was proposed: \($0)" } ?? "")
        \(entry.proposedBy.map { "Proposed by: \($0)" } ?? "")

        My question: \(question)
        """
        return await claudeOnce(prompt, system: "You help the user check a proposed fact in their knowledge base before they approve it.",
                                model: model(for: .ask), tools: ["Bash(kb:*)", "Read", "Grep", "Glob"], timeout: 180)
    }
}

/// At the top of Facts: how many proposed facts wait. Opens them in the detail pane.
struct ProposedFactsRow: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        let selected = model.showProposedFacts
        HStack(spacing: 8) {
            Image(systemName: "lightbulb").foregroundStyle(selected ? Color.white : Color.accentColor)
            Text("Proposed facts").fontWeight(.medium)
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(minWidth: 18, minHeight: 18)
                .background(selected ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.18), in: Capsule())
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .foregroundStyle(selected ? Color.white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { model.showProposedFactsPane() }
        .help("Facts that sessions, meetings and reviews picked up, waiting for you to approve or decline")
        .listRowSeparator(.hidden)
    }
}

/// The detail pane for proposed facts: each in full, with where it came from, a question box for anything you
/// don't remember, and approve, edit or decline.
struct ProposedFactsView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject

    var body: some View {
        let proposals = model.factProposals(project: project.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AdaptiveCardLayout(spacing: 10, stackedSpacing: 6, minInfoWidth: 200) {
                    Image(systemName: "lightbulb").font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Proposed facts").font(.title2.weight(.semibold))
                        Text(proposals.isEmpty ? "Nothing waits." : "\(proposals.count) waiting. Approve the ones worth keeping.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if proposals.count > 1 {
                        Button("Approve All") { model.approveInbox(proposals.map(\.id)) }
                            .fixedSize()
                    }
                }
                ForEach(proposals) { ProposedFactCard(entry: $0) }
            }
            .padding(22)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProposedFactCard: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry
    @State private var question = ""
    @State private var answers: [(q: String, a: String)] = []
    @State private var asking = false

    var body: some View {
        let busy = model.busyEntries.contains(entry.id)
        let body = BodyPreview.text(entry.body)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if !entry.date.isEmpty { Text(DateText.display(entry.date)).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
            }
            Text(entry.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !entry.summary.isEmpty {
                Text(entry.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !body.isEmpty {
                Text(body).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let reason = entry.reason {
                Label(reason, systemImage: "quote.bubble").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let by = entry.proposedBy { ProposerLink(raw: by).font(.caption) }
            ForEach(Array(answers.enumerated()), id: \.offset) { _, qa in
                VStack(alignment: .leading, spacing: 3) {
                    Text(qa.q).font(.callout.weight(.medium))
                    Text(LocalizedStringKey(qa.a)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 6) {
                TextField("Ask about it before you decide…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                    .disabled(asking)
                if asking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Ask", action: ask)
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || !model.claudeAvailable)
                }
            }
            ChipRow(spacing: 10) {
                Button("Approve") { model.approveInbox([entry.id]) }
                    .buttonStyle(.borderedProminent)
                Button("Edit") {
                    model.selectEntry(entry.id)
                    model.isEditing = true
                }
                Button("Decline", role: .destructive) { model.rejectInbox([entry.id]) }
            }
            .disabled(busy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        asking = true
        Task {
            let reply = await model.askAboutProposal(entry, question: q)
            asking = false
            answers.append((q, reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No answer came back. Try again."))
            question = ""
        }
    }
}
