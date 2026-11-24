import KBCore
import KBEngine
import SwiftUI

// MARK: Shared bits

struct Chip: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .fixedSize()
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct SectionChip: View {
    let section: KBSection

    var body: some View {
        Chip(text: section.singularTitle, color: SectionChip.color(section), systemImage: SidebarView.icon(section))
    }

    static func color(_ s: KBSection) -> Color {
        switch s {
        case .decisions: return .blue
        case .facts: return .orange
        case .architecture: return .purple
        case .followups: return .teal
        case .backlog: return .green
        case .meetings: return .indigo
        default: return .secondary
        }
    }
}

/// `proposed_by`: a meeting id links to it, a Build session opens in Build; `daily:` and others are shown as text.
struct ProposerLink: View {
    @Environment(AppModel.self) private var model
    let raw: String

    var body: some View {
        if EntryID(raw) != nil {
            EntryLink(raw: raw)
        } else if raw.hasPrefix("session:"), let s = model.session(String(raw.dropFirst(8))) {
            Button { model.openSession(s) } label: {
                Label(s.title, systemImage: s.space == .build ? "hammer" : "sparkles").lineLimit(1)
            }
            .buttonStyle(.link)
            .help("Open the session that proposed it")
        } else if raw.hasPrefix("daily:") {
            Label("Morning routine \(raw.dropFirst(6))", systemImage: "sun.max").foregroundStyle(.secondary)
        } else if raw.hasPrefix("ask:") {
            Label("Ask", systemImage: "questionmark.bubble").foregroundStyle(.secondary)
        } else {
            Label(raw, systemImage: "terminal").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

enum BodyPreview {
    /// The first few lines of a Markdown body as plain text.
    static func text(_ body: String, lines: Int = 3) -> String {
        body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .prefix(lines)
            .map { $0.replacingOccurrences(of: "**", with: "") }
            .joined(separator: "\n")
    }
}

struct ActionButtonStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.borderless).controlSize(.small)
    }
}

// MARK: Inbox

struct InboxView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject

    var body: some View {
        // Proposed facts and changes to facts wait under Facts, until the user decides.
        let all = model.index.entries(project: project.id, section: .inbox).filter(\.waitsInInbox)
        let query = model.listQuery(.inbox)
        let entries = model.tagFiltered(query.isEmpty ? all : all.filter { $0.matches(query) }, .inbox)
        if all.isEmpty {
            ListEmptyState(title: "Inbox is empty", systemImage: "tray", message: "Proposals from meetings, sessions and the morning routine for \(project.title) wait here for approval.")
        } else {
            VStack(spacing: 0) {
                InboxToolbar(entries: entries)
                ListSearchField(key: .inbox, prompt: "Search the inbox")
                TagFilterBar(key: .inbox, available: all.map(\.tags))
                Divider()
                List(selection: Binding(get: { model.selectedEntryID }, set: { model.selectEntry($0) })) {
                    if entries.isEmpty {
                        if query.isEmpty { TagFilterNoMatch(key: .inbox) } else { ListSearchNoMatch(query: query) }
                    }
                    ForEach(DaySections.group(entries, date: \.date)) { day in
                        Section(day.title) {
                            ForEach(day.items) { entry in
                                InboxCard(entry: entry).tag(entry.id).entryContextMenu(entry.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .navigationSubtitle("Inbox")
        }
    }
}

struct InboxToolbar: View {
    @Environment(AppModel.self) private var model
    let entries: [KBEntry]

    var body: some View {
        let ids = Set(entries.map(\.id))
        let selected = model.inboxSelection.intersection(ids)
        HStack(spacing: 10) {
            Button {
                if selected.count == ids.count { model.inboxSelection.subtract(ids) } else { model.inboxSelection.formUnion(ids) }
            } label: {
                Image(systemName: selected.isEmpty ? "square" : selected.count == ids.count ? "checkmark.square.fill" : "minus.square.fill")
            }
            .buttonStyle(.borderless)
            .help(selected.count == ids.count ? "Deselect all" : "Select all")
            Text(selected.isEmpty ? "\(entries.count) waiting" : "\(selected.count) selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if !selected.isEmpty {
                Button("Reject", role: .destructive) { model.rejectInbox(Array(selected).sorted()) }
                    .controlSize(.small)
                Button("Approve Selected") { model.approveInbox(Array(selected).sorted()) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct InboxCard: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry
    /// In the Inbox, cards have a checkbox for approving several at once.
    var selectable = true
    var rejectTitle = "Reject"

    var body: some View {
        let busy = model.busyEntries.contains(entry.id)
        let checked = model.inboxSelection.contains(entry.id)
        HStack(alignment: .top, spacing: 8) {
            if selectable {
                Button {
                    if checked { model.inboxSelection.remove(entry.id) } else { model.inboxSelection.insert(entry.id) }
                } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    ChipRow(spacing: 6) {
                        if let s = entry.proposedSection { SectionChip(section: s) }
                        if entry.section == .inbox, entry.proposedSection == .followups {
                            Chip(text: entry.followupKind.capitalized)
                        }
                    }
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.small) }
                }
                Text(entry.title).font(.headline).lineLimit(3)
                if !entry.summary.isEmpty {
                    Text(entry.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                ForEach(entry.supersedes, id: \.self) { old in
                    HStack(spacing: 4) {
                        Text("replaces").foregroundStyle(.secondary)
                        EntryLink(raw: old)
                    }
                    .font(.caption)
                }
                if let reason = entry.reason {
                    Label(reason, systemImage: "quote.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let by = entry.proposedBy {
                    ProposerLink(raw: by).font(.caption)
                }
                let preview = BodyPreview.text(entry.body)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
                HStack(spacing: 12) {
                    Button("Approve") { model.approveInbox([entry.id]) }
                        .fontWeight(.semibold)
                    Button("Edit") {
                        model.selectEntry(entry.id)
                        model.isEditing = true
                    }
                    Button(rejectTitle, role: .destructive) { model.rejectInbox([entry.id]) }
                }
                .modifier(ActionButtonStyleModifier())
                .disabled(busy)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: Follow-ups

struct FollowupsView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    @State private var filter = "all"
    @AppStorage("followupWho") private var who = "all"
    @State private var showHandled = true

    var body: some View {
        let everything = model.index.entries(project: project.id, section: .followups)
        let drafts = everything.filter(\.isDraft)
        let all = everything.filter { !$0.isDraft }
        let query = model.listQuery(.followups)
        let tags = model.tagSelection(.followups)
        let me = model.myNames
        let filtered = all.filter { (filter == "all" || $0.followupKind == filter) && (query.isEmpty || $0.matches(query))
            && EntryTags.matches($0.tags, selected: tags) && (who == "all" || $0.responsibility(me: me).rawValue == who) }
        let ids = Set(all.map(\.id.rawValue))
        let merges = model.mergeProposals.filter { ids.contains($0.keep) || ids.contains($0.other) }
        let open = filtered.filter { $0.followupStatus == .open }.sorted(by: FollowupsView.order)
        let handled = filtered.filter { $0.followupStatus != .open }
            .sorted { ($0.field("closed") ?? $0.date) > ($1.field("closed") ?? $1.date) }
        VStack(spacing: 0) {
            ChipRow(spacing: 10) {
                Picker("Kind", selection: $filter) {
                    Text("All").tag("all")
                    Text("Questions").tag("question")
                    Text("Actions").tag("action")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Whose", selection: $who) {
                    Text("Everyone's").tag("all")
                    Text("On me").tag(FollowupResponsibility.me.rawValue)
                    Text("Waiting on others").tag(FollowupResponsibility.others.rawValue)
                }
                .labelsHidden()
                .fixedSize()
                .help("On me: yours, or with no owner. Waiting on others: owned by someone else, or waiting on someone.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            HStack(spacing: 6) {
                Text(model.isCheckingFollowups ? "Checking against what was saved…" : "Kept up to date from the facts, decisions and meetings you save.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                if model.isCheckingFollowups {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check Now") { model.checkFollowupsNow(project: project.id) }
                        .controlSize(.small)
                        .disabled(open.isEmpty || !model.claudeAvailable)
                        .help("Check the open follow-ups against what was saved here and product-wide in the last 30 days")
                }
                if model.findingDuplicates {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Find Duplicates") { model.findDuplicateFollowups(project: project.id) }
                        .controlSize(.small)
                        .disabled(open.count < 2 || !model.claudeAvailable)
                        .help("\(Brain.name) looks for open follow-ups that say the same thing and suggests merging them; you decide each one")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            ListSearchField(key: .followups, prompt: "Search follow-ups")
            TagFilterBar(key: .followups, available: all.map(\.tags))
            Divider()
            if filtered.isEmpty && drafts.isEmpty && !query.isEmpty {
                ListEmptyState(title: "No follow-ups match “\(query)”", systemImage: "magnifyingglass")
            } else if filtered.isEmpty && drafts.isEmpty && !tags.isEmpty {
                ListEmptyState(title: "No follow-ups have every picked tag", systemImage: "tag") {
                    Button("Clear Tags") { model.setTagSelection(.followups, []) }
                }
            } else if filtered.isEmpty && drafts.isEmpty {
                ListEmptyState(title: "No follow-ups", systemImage: "checklist", message: "Open questions and action items for \(project.title) appear here.") {
                    Button("New Follow-up…") { model.requestNewEntry(.followups) }
                }
            } else {
                List(selection: model.entrySelection) {
                    DraftsSection(drafts: drafts)
                    if !merges.isEmpty {
                        Section("Possible duplicates · \(merges.count)") {
                            ForEach(merges) { MergeProposalCard(proposal: $0) }
                        }
                    }
                    Section("Open · \(open.count)") {
                        if open.isEmpty {
                            Text(query.isEmpty ? "Nothing open." : "Nothing open matches “\(query)”.").foregroundStyle(.secondary)
                        }
                        ForEach(open) { FollowupRow(entry: $0).tag($0.id).entryContextMenu($0.id) }
                    }
                    if !handled.isEmpty {
                        FoldableSection(isExpanded: $showHandled) {
                            ForEach(handled) { FollowupRow(entry: $0).tag($0.id).entryContextMenu($0.id) }
                        } header: {
                            Text("Handled · \(handled.count)")
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationSubtitle("Follow-ups")
    }

    /// Overdue first, then by due date, then undated by raised date.
    static func order(_ a: KBEntry, _ b: KBEntry) -> Bool {
        let da = a.field("due") ?? "9999", db = b.field("due") ?? "9999"
        return da == db ? a.date > b.date : da < db
    }
}

struct FollowupRow: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry

    var body: some View {
        let status = entry.followupStatus
        let overdue = entry.isOverdue()
        let busy = model.busyEntries.contains(entry.id)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.followupKind == "question" ? "questionmark.circle" : "arrow.right.circle")
                .foregroundStyle(status == .open ? Color.teal : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.headline)
                    .strikethrough(status == .dropped)
                    .foregroundStyle(status == .open ? .primary : .secondary)
                    .lineLimit(3)
                ChipRow(spacing: 8) {
                    if let owner = entry.field("owner"), !FollowupResponsibility.isMe(owner, me: model.myNames) {
                        Label(owner, systemImage: "person").labelStyle(.titleAndIcon)
                    }
                    if let waiting = entry.field("waiting_on"), !FollowupResponsibility.isMe(waiting, me: model.myNames) {
                        Label("waiting on \(waiting)", systemImage: "hourglass").labelStyle(.titleAndIcon)
                    }
                    if let due = entry.field("due") {
                        Label(DateText.display(due), systemImage: overdue ? "exclamationmark.circle.fill" : "calendar")
                            .foregroundStyle(overdue ? Color.red : .secondary)
                            .fontWeight(overdue ? .semibold : .regular)
                    }
                    if status != .open {
                        Chip(text: status.handledTitle, color: status == .done ? .green : .gray)
                        if entry.closedByKB {
                            Chip(text: "by Mindmill", color: .accentColor, systemImage: "sparkles")
                                .help("Mindmill found it handled by something you saved. Reopen it if that's wrong.")
                        }
                    } else if entry.latestUpdate != nil {
                        Chip(text: "Updated", color: .accentColor, systemImage: "arrow.triangle.2.circlepath")
                    }
                    ScopeChips(entry: entry)
                    TagChips(tags: entry.tags, key: .followups)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !entry.raisedIn.isEmpty {
                    ChipRow(spacing: 4) {
                        Text("raised in").foregroundStyle(.tertiary)
                        ForEach(entry.raisedIn, id: \.self) { SourceView(source: $0) }
                    }
                    .font(.caption)
                }
                if status != .open {
                    if !entry.summary.isEmpty {
                        Text(entry.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if let by = entry.field("resolved_by"), !by.isEmpty {
                        HStack(spacing: 4) {
                            Text(entry.closedByKB ? "handled by" : "resolved by").foregroundStyle(.tertiary)
                            SourceView(source: by)
                        }
                        .font(.caption)
                    }
                    HStack(spacing: 12) {
                        Button("Reopen") { model.closeFollowup(entry.id, status: .open, resolvedBy: nil, answer: nil) }
                            .help("It still needs following up")
                        if busy { ProgressView().controlSize(.mini) }
                    }
                    .modifier(ActionButtonStyleModifier())
                    .disabled(busy)
                } else {
                    if let update = entry.latestUpdate {
                        Text(update).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                    HStack(spacing: 12) {
                        Button("Mark Done…") { model.followupCloseRequest = FollowupCloseRequest(entry: entry.id) }
                        Button("Create PBI…") { model.newPBIRequest = NewPBIRequest(source: entry.id) }
                        Button("Drop") { model.closeFollowup(entry.id, status: .dropped, resolvedBy: nil, answer: nil) }
                        if busy { ProgressView().controlSize(.mini) }
                    }
                    .modifier(ActionButtonStyleModifier())
                    .disabled(busy)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct FollowupCloseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: EntryID
    @State private var answer = ""
    @State private var resolvedBy = ""

    var body: some View {
        let entry = model.index.entry(id)
        VStack(alignment: .leading, spacing: 14) {
            Text("Mark Done").font(.title2.weight(.semibold))
            Text(entry?.title ?? id.rawValue).font(.headline)
            if entry?.followupKind == "question" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Answer").font(.callout).foregroundStyle(.secondary)
                    TextField("What was the answer? (optional)", text: $answer, axis: .vertical)
                        .lineLimit(2...)
                        .scrollingInput(answer, maxLines: 5)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Note").font(.callout).foregroundStyle(.secondary)
                    TextField("Outcome (optional)", text: $answer, axis: .vertical)
                        .lineLimit(1...)
                        .scrollingInput(answer, maxLines: 4)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Resolved by").font(.callout).foregroundStyle(.secondary)
                TextField("Decision id or work-item URL (optional)", text: $resolvedBy)
                    .font(.body.monospaced())
                if !resolvedBy.isEmpty { SourceView(source: resolvedBy).font(.caption) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Mark Done") {
                    model.closeFollowup(id, status: .done, resolvedBy: resolvedBy, answer: answer)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 480)
    }
}

// MARK: Backlog

struct KindChip: View {
    let kind: String
    var body: some View {
        kind == "bug" ? Chip(text: "Bug", color: .red, systemImage: "ladybug") : Chip(text: "PBI", color: .blue, systemImage: "doc.plaintext")
    }
}

struct BacklogCard: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry
    let prefix: String

    var body: some View {
        let status = entry.backlogStatus
        let busy = model.busyEntries.contains(entry.id)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                KindChip(kind: entry.backlogKind)
                if let wi = entry.field("work_item") {
                    if let u = entry.field("url").flatMap(URL.init(string:)) {
                        Link("#\(wi)", destination: u).font(.caption.weight(.semibold))
                    } else {
                        Text("#\(wi)").font(.caption.weight(.semibold))
                    }
                }
                if status == .rejected { Chip(text: "Rejected", color: .gray) }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
            }
            (Text(prefix).foregroundStyle(.tertiary) + Text(entry.title).foregroundStyle(status == .rejected ? .secondary : .primary))
                .font(.headline)
                .strikethrough(status == .rejected)
                .lineLimit(3)
            if !entry.summary.isEmpty {
                Text(entry.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            if !entry.sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.sources, id: \.self) { SourceView(source: $0) }
                }
                .font(.caption)
            }
            let areas = backlogAreas
            if !areas.isEmpty || !entry.tags.isEmpty {
                ChipRow(spacing: 4) {
                    ForEach(areas, id: \.self) { ProjectChip(project: $0) }
                    TagChips(tags: entry.tags, key: .backlog)
                }
            }
            BacklogLinksRow(entry: entry)
            if status == .proposed, let best = model.unresolvedDuplicate(entry.id) {
                Chip(text: "Possible duplicate of \(AppModel.shortTitle(best.label))", color: .orange, systemImage: "doc.on.doc")
                    .help("Open Suggested backlog items to check it")
            }
            if status == .proposed {
                HStack(spacing: 12) {
                    Button(BacklogBatchCreateSheet.createLabel(model.settings(for: entry.project).tracker.kind) + "…") {
                        model.backlogCreateRequest = BacklogCreateRequest(entry: entry.id)
                    }
                        .fontWeight(.semibold)
                    Button("Reject", role: .destructive) { model.rejectBacklog(entry.id) }
                }
                .modifier(ActionButtonStyleModifier())
                .disabled(busy)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }

    /// The scopes it touches: where it lives, the scopes it is tagged with, and scopes whose tracker tag it carries.
    private var backlogAreas: [String] {
        var out = entry.scopes.isEmpty ? [entry.project] : entry.scopes
        let tags = Set(entry.tags.map { $0.lowercased() })
        for p in model.index.siblings(of: entry.project) where !out.contains(p.id) {
            if model.settings(for: p.id).tracker.tags.contains(where: { tags.contains($0.lowercased()) }) { out.append(p.id) }
        }
        return out
    }
}

// MARK: Detail banners

/// Actions shown above an entry's header for inbox, follow-up, backlog and active meeting entries.
struct EntryActionBanner: View {
    @Environment(AppModel.self) private var model
    let doc: EntryDocument

    var body: some View {
        if !doc.isNew, let entry = model.index.entry(doc.id) {
            content(entry)
        }
    }

    @ViewBuilder
    private func content(_ entry: KBEntry) -> some View {
        let busy = model.busyEntries.contains(entry.id)
        switch entry.section {
        case .inbox:
            bar(color: .orange) {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(.orange)
                Text("Proposed").fontWeight(.semibold)
                if let s = entry.proposedSection { SectionChip(section: s) }
                if let by = entry.proposedBy { ProposerLink(raw: by).font(.callout).lineLimit(1).fixedSize() }
            } actions: {
                if busy { ProgressView().controlSize(.small) }
                Button("Reject", role: .destructive) { model.rejectInbox([entry.id]) }.disabled(busy)
                Button("Approve") { model.approveInbox([entry.id]) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
        case .followups where entry.followupStatus == .open:
            bar(color: .teal) {
                Image(systemName: "checklist").foregroundStyle(.teal)
                Text(entry.followupKind == "question" ? "Open question" : "Open action").fontWeight(.semibold)
                if entry.isOverdue() { Chip(text: "Overdue", color: .red) }
            } actions: {
                if busy { ProgressView().controlSize(.small) }
                Button("Create PBI…") { model.newPBIRequest = NewPBIRequest(source: entry.id) }
                    .help("Turn this into a PBI or bug, after checking the backlog for one that exists")
                Button("Drop") { model.closeFollowup(entry.id, status: .dropped, resolvedBy: nil, answer: nil) }.disabled(busy)
                Button("Mark Done…") { model.followupCloseRequest = FollowupCloseRequest(entry: entry.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
        case .backlog:
            VStack(spacing: 0) {
                bar(color: .green) {
                    KindChip(kind: entry.backlogKind)
                    let prefix = model.settings(for: entry.project).tracker.titlePrefix
                    (Text(prefix).foregroundStyle(.secondary) + Text(entry.title)).lineLimit(1)
                } actions: {
                    if busy { ProgressView().controlSize(.small) }
                    switch entry.backlogStatus {
                    case .proposed:
                        Button("Reject", role: .destructive) { model.rejectBacklog(entry.id) }.disabled(busy)
                        Button(BacklogBatchCreateSheet.createLabel(model.settings(for: entry.project).tracker.kind) + "…") {
                            model.backlogCreateRequest = BacklogCreateRequest(entry: entry.id)
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                    case .created:
                        if let wi = entry.field("work_item"), let u = entry.field("url").flatMap(URL.init(string:)) {
                            Link("Work item #\(wi)", destination: u)
                        } else {
                            Chip(text: "Created", color: .green)
                        }
                    case .rejected:
                        Chip(text: "Rejected", color: .gray)
                    }
                }
                if entry.backlogStatus == .proposed, let f = model.duplicateFindings(for: [entry])[entry.id], f.verdict != .none {
                    DuplicateBox(entry: entry, finding: f)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
        case .discussions:
            DiscussionBanner(entry: entry)
        case .ideas:
            IdeaBanner(entry: entry)
        case .references:
            ReferenceBanner(entry: entry)
        case .meetings:
            if let status = entry.meetingStatus, status.isActive {
                bar(color: .indigo) {
                    Image(systemName: "person.2.wave.2").foregroundStyle(.indigo)
                    Text("Meeting").fontWeight(.semibold)
                    let chip = MeetingDayRow.chip(entry)
                    Chip(text: chip.text, color: chip.color)
                    Text(status.isUpcoming ? "Prepare it with \(Brain.name), or start taking notes." :
                            entry.meetingSummarizing ? "\(Brain.name) is writing the summary." :
                            status == .live ? "Notes are being taken." : "Review what \(Brain.name) proposed, then file it.")
                        .foregroundStyle(.secondary)
                } actions: {
                    if status.isUpcoming {
                        Button("Prepare…") { model.prepareMeeting(entry.id) }
                        Button("Take Notes") { model.takeNotes(entry.id) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(status == .live ? "Resume Meeting" : "Review…") { model.openMeeting(entry.id) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        case .facts:
            let changes = model.factChanges(for: entry.id)
            if !changes.isEmpty {
                // Above the entry's own scroll view: a long proposal must scroll here, never grow the window.
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(changes) { c in FactChangeCard(change: c, fact: entry) }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .bottom) { Divider() }
            }
        default:
            EmptyView()
        }
    }

    /// What it is on the left, scrolling sideways when the window is narrow; the actions always fit on the right.
    private func bar<I: View, A: View>(color: Color, @ViewBuilder _ info: () -> I, @ViewBuilder actions: () -> A) -> some View {
        HStack(spacing: 10) {
            ChipRow(spacing: 8) { info() }
            Spacer(minLength: 8)
            HStack(spacing: 8) { actions() }.fixedSize()
        }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color.opacity(0.10))
            .overlay(alignment: .bottom) { Divider() }
    }
}
