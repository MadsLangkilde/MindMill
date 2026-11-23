import KBCore
import SwiftUI

struct NewResearchRequest: Identifiable {
    let id = UUID()
    let project: String
    var target: ResearchTarget?
    var title = ""
    var question = ""
}

extension AppModel {
    static func researchKey(_ id: EntryID) -> String { "research:\(id.rawValue)" }

    func researchSession(_ id: EntryID) -> WorkSession? {
        sessions.first { $0.about == Self.researchKey(id) }
    }

    /// Research done for a PBI, idea or discussion, newest first.
    func research(for target: ResearchTarget) -> [KBEntry] {
        index.entries.values.filter { $0.section == .research && $0.researchFor == target }
            .sorted { $0.researchUpdated > $1.researchUpdated }
    }

    /// What a research is for, in words: "#1234 Title", or the entry's title.
    func researchTargetTitle(_ target: ResearchTarget) -> String {
        switch target {
        case .workItem(let n):
            let title = workItem(n)?.title ?? workItemDetails[n]?.title
                ?? localTrackers.values.lazy.compactMap { $0.item(n)?.title }.first
            return "#\(n)" + (title.map { " \($0)" } ?? "")
        case .entry(let id):
            return index.entry(id)?.title ?? id.stem
        }
    }

    func openResearchTarget(_ target: ResearchTarget, scope: String) {
        switch target {
        case .entry(let id):
            openLink(id.rawValue)
        case .workItem(let n):
            mode = .plan
            if trackerKind(scope) == "local" {
                if projectID != scope { selectProject(scope) }
                selectSidebar(.section(.backlog))
                selectedLocalItem = n
            } else if let item = workItem(n) {
                showInBacklog(item)
            } else if let url = workItemDetails[n].flatMap({ URL(string: $0.url) }) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func openResearch(_ id: EntryID) {
        mode = .plan
        openLink(id.rawValue)
    }

    /// Writes the research down, then starts its session in Plan and opens it.
    func startResearch(_ request: NewResearchRequest) {
        let question = request.question.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            let first = question.components(separatedBy: .newlines).first ?? ""
            title = first.count > 70 ? String(first.prefix(67)) + "…" : first
        }
        if title.isEmpty, let t = request.target { title = researchTargetTitle(t) }
        guard !title.isEmpty else { return }
        Task {
            guard let id = await createResearch(scope: request.project, title: title, question: question, target: request.target) else { return }
            startResearchSession(id, message: "/kb:research start \(id.rawValue)", display: "Research: \(title)")
            openResearch(id)
        }
    }

    private func createResearch(scope: String, title: String, question: String, target: ResearchTarget?) async -> EntryID? {
        var args = ["new", "research", "--scope", scope, "--title", title, "--body-stdin", "--cross-project"]
        if let target { args += ["--field", "for=\(target.rawValue)"] }
        do {
            let out = try await cli.run(args, stdin: ResearchBody.template(question: question))
            guard let line = out.components(separatedBy: .newlines).first, let id = EntryID(line) else {
                errorMessage = "kb new research didn't say what it made: \(out)"
                return nil
            }
            reload()
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func startResearchSession(_ id: EntryID, message: String, display: String) -> WorkSession {
        let title = index.entry(id)?.title ?? id.stem
        return newSession(title: "Research: \(title)", project: id.project, message: message, display: display,
                          about: Self.researchKey(id), show: false, space: .plan)
    }

    /// Sends a kb:research action to the research's session, starting one when it has none.
    func researchAction(_ action: String, _ id: EntryID, display: String) {
        let message = "/kb:research \(action) \(id.rawValue)"
        loadSessionsIfNeeded()
        guard let s = researchSession(id) else {
            startResearchSession(id, message: message, display: display)
            return
        }
        if s.chat.isBusy {
            s.inbox.append((text: message, display: display))
            notice = "\(Brain.name) is busy; it does this when the current reply ends."
        } else {
            send(message, in: s, display: display)
        }
    }

    func setResearch(_ id: EntryID, status: ResearchStatus) {
        busyEntries.insert(id)
        let cli = cli
        Task {
            do {
                _ = try await cli.run(["research", "status", id.rawValue, status.rawValue])
            } catch {
                errorMessage = error.localizedDescription
            }
            busyEntries.remove(id)
            reload()
            if document?.id == id, document?.isDirty != true { openNow(id) }
        }
    }

    /// Carries the picked takeaways to what the research is for, keeps the picked proposals, declines the rest,
    /// and marks the research done. The takeaways stay in the research.
    func finishResearch(_ id: EntryID, takeaways: [String], target: ResearchTarget?, asComment: Bool,
                        keep: [EntryID], decline: [EntryID]) async -> Bool {
        let text = ResearchTransfer.text(takeaways)
        let title = index.entry(id)?.title ?? id.stem
        var errors: [String] = []
        if !text.isEmpty, let target {
            switch target {
            case .workItem(let n):
                var args = ["tracker", "note", String(n), "--scope", id.project, "--heading", "Research: \(title)"]
                if asComment { args.append("--comment") }
                do { _ = try await cli.run(args, stdin: text) } catch { errors.append(error.localizedDescription) }
            case .entry(let eid):
                do {
                    var doc = try KBStore.load(eid, root: rootURL)
                    doc.body = ResearchTransfer.appending(text, to: doc.body, title: title, date: KBDate.today())
                    try KBStore.save(&doc, root: rootURL)
                } catch { errors.append("Could not add to \(eid.stem): \(error.localizedDescription)") }
            }
        }
        for e in keep {
            do { _ = try await cli.approveInbox(e) } catch { errors.append(error.localizedDescription) }
        }
        for e in decline {
            do { try await cli.rejectInbox(e) } catch { errors.append(error.localizedDescription) }
        }
        if errors.isEmpty {
            var args = ["research", "status", id.rawValue, ResearchStatus.done.rawValue]
            if !text.isEmpty, let target { args += ["--transferred", target.rawValue] }
            do { _ = try await cli.run(args) } catch { errors.append(error.localizedDescription) }
        }
        reload()
        if document?.id == id, document?.isDirty != true { openNow(id) }
        if !errors.isEmpty {
            errorMessage = errors.joined(separator: "\n")
            return false
        }
        if !text.isEmpty, let target {
            notice = "Research done. Its takeaways are on \(researchTargetTitle(target))."
        } else {
            notice = "Research done."
        }
        return true
    }

    /// A Build session that turned out to be research: it becomes a research in Plan, and Claude writes down what it has
    /// found so far.
    func moveToResearch(_ s: WorkSession) {
        guard let scope = s.project ?? projectID else {
            errorMessage = "Pick a scope first; research lives in one."
            return
        }
        let first = s.chat.items.first { $0.role == .user }?.text ?? ""
        let target = s.about.flatMap(ResearchTarget.init)
        let title = SessionTitle.split(s.title).text
        Task {
            guard let id = await createResearch(scope: scope, title: title.isEmpty ? "Research" : title,
                                                question: String(first.prefix(2000)), target: target) else { return }
            if s.role == .member {
                s.parentID = nil
                s.role = .solo
            }
            s.space = .plan
            s.about = Self.researchKey(id)
            s.researchOffered = true
            s.researchAskShown = false
            if buildSelection == s.id { buildSelection = nil }
            saveSessions()
            crewChanged()
            let message = "/kb:research adopt \(id.rawValue)"
            let display = "Moved to Research: write down what we have found so far"
            if s.chat.isBusy { s.inbox.append((text: message, display: display)) } else { send(message, in: s, display: display) }
            openResearch(id)
        }
    }

    /// After a Build session's turn: when it reads like research and has changed nothing, ask once whether to move it.
    func offerResearch(_ s: WorkSession) {
        guard s.space == .build, s.role == .solo, !s.researchOffered, !s.chat.isBusy else { return }
        let first = s.chat.items.first { $0.role == .user }?.text ?? ""
        let tools = s.chat.items.filter { $0.role == .tool }.map(\.text)
        guard ResearchDetect.shouldOffer(firstMessage: first, toolLines: tools, offered: s.researchOffered) else { return }
        s.researchOffered = true
        s.researchAskShown = true
        saveSessions()
    }
}

// MARK: List

/// Plan → Research: what is being looked into, what waits to be finished, and what is done.
struct ResearchListView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    @State private var showDone = false
    @State private var showParked = false

    var body: some View {
        let every = model.index.entries(project: project.id, section: .research).filter { !$0.isDraft }
            .sorted { $0.researchUpdated > $1.researchUpdated }
        let query = model.listQuery(.research)
        let all = query.isEmpty ? every : every.filter { $0.matches(query) }
        let review = all.filter { $0.researchStatus == .review }
        let open = all.filter { $0.researchStatus == .open }
        let done = all.filter { $0.researchStatus == .done }
        let parked = all.filter { $0.researchStatus == .parked }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(open.count + review.count) open").font(.headline)
                Spacer()
                Button { model.newResearchRequest = NewResearchRequest(project: project.id) } label: {
                    Label("New Research", systemImage: "plus")
                }
                .help("Look into something with \(Brain.name), from a thought")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if !every.isEmpty { ListSearchField(key: .research, prompt: "Search research") }
            Divider()
            if all.isEmpty && !every.isEmpty {
                ListEmptyState(title: "No research matches “\(query)”", systemImage: "magnifyingglass")
            } else if all.isEmpty {
                ListEmptyState(title: "No Research", systemImage: ResearchStatus.icon,
                               message: "Look into something with \(Brain.name): from a thought, or from a PBI, an idea or a discussion. When you finish, pick the takeaways that go on the PBI and the facts worth keeping.") {
                    Button("New Research…") { model.newResearchRequest = NewResearchRequest(project: project.id) }
                }
            } else {
                List(selection: model.entrySelection) {
                    if !review.isEmpty { Section("Ready to finish · \(review.count)") { rows(review) } }
                    if !open.isEmpty { Section("Researching · \(open.count)") { rows(open) } }
                    if !parked.isEmpty {
                        FoldableSection(isExpanded: Binding(get: { showParked || !query.isEmpty }, set: { showParked = $0 })) { rows(parked) } header: { Text("Parked · \(parked.count)") }
                    }
                    if !done.isEmpty {
                        FoldableSection(isExpanded: Binding(get: { showDone || !query.isEmpty }, set: { showDone = $0 })) { rows(done) } header: { Text("Done · \(done.count)") }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationSubtitle("Research")
        .onAppear { model.loadSessionsIfNeeded() }
    }

    private func rows(_ entries: [KBEntry]) -> some View {
        ForEach(entries) { ResearchRow(entry: $0).tag($0.id).entryContextMenu($0.id) }
    }
}

struct ResearchRow: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry

    var body: some View {
        let parts = ResearchBody(entry.body)
        let state = model.researchSession(entry.id)?.crewState
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.title).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Text(DateText.short(entry.researchUpdated)).font(.caption).foregroundStyle(.secondary)
            }
            if !parts.question.isEmpty {
                Text(parts.question).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            ChipRow(spacing: 6) {
                if let state, state.needsUser {
                    StatusPill(status: state == .blocked ? .needsPermission : .needsInput, compact: true)
                } else if state == .working {
                    StatusPill(status: .running, compact: true)
                }
                if let t = entry.researchFor {
                    Chip(text: t.shortTitle, color: .blue, systemImage: t.isWorkItem ? "list.bullet.rectangle" : "link")
                }
                if !parts.findings.isEmpty {
                    Chip(text: "\(parts.findings.count) finding\(parts.findings.count == 1 ? "" : "s")", color: .teal, systemImage: "text.magnifyingglass")
                }
                if !parts.openQuestions.isEmpty {
                    Chip(text: "\(parts.openQuestions.count) open", color: .orange, systemImage: "questionmark.circle")
                }
            }
        }
        .padding(.vertical, 3)
    }
}

extension ResearchTarget {
    var isWorkItem: Bool { if case .workItem = self { return true } else { return false } }

    /// Short enough for a chip: "#1234", or "For an idea".
    var shortTitle: String {
        switch self {
        case .workItem(let n): return "#\(n)"
        case .entry(let id): return "For a\(id.section == .ideas ? "n" : "") \(id.section.singularTitle.lowercased())"
        }
    }
}

// MARK: Detail

enum ResearchTab: String, CaseIterable {
    case session, notes, finish

    var title: String {
        switch self {
        case .session: return "Session"
        case .notes: return "Notes"
        case .finish: return "Finish"
        }
    }
}

/// A research: its session with Claude, its notes, and finishing it.
struct ResearchDetailView: View {
    @Environment(AppModel.self) private var model
    let doc: EntryDocument
    @State private var tab: ResearchTab?

    var body: some View {
        let entry = model.index.entry(doc.id)
        let status = entry?.researchStatus ?? .open
        let current = model.isEditing ? .notes : tab ?? (status == .review ? .finish : .session)
        VStack(spacing: 0) {
            if let entry { ResearchBanner(entry: entry, tab: Binding(get: { current }, set: { tab = $0 })) }
            switch current {
            case .session:
                if let s = model.researchSession(doc.id) {
                    SessionView(session: s).id(s.id)
                } else {
                    ListEmptyState(title: "No session", systemImage: "bubble.left.and.text.bubble.right",
                                   message: "\(Brain.name) reads the notes so far and carries on.") {
                        Button("Continue with \(Brain.name)") {
                            model.researchAction("continue", doc.id, display: "Continue the research")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .notes:
                EntryDetailView(doc: doc)
            case .finish:
                if let entry { ResearchFinishView(entry: entry).id(entry.id) }
            }
        }
        .onChange(of: status) { _, now in if now == .review { tab = .finish } }
        .onAppear { model.loadSessionsIfNeeded() }
    }
}

/// Above a research: what it is for, where it stands, and the tabs.
struct ResearchBanner: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry
    @Binding var tab: ResearchTab

    var body: some View {
        let busy = model.busyEntries.contains(entry.id)
        let status = entry.researchStatus
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 180) {
                Image(systemName: ResearchStatus.icon).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Menu {
                        ForEach(ResearchStatus.allCases, id: \.self) { s in
                            Button { model.setResearch(entry.id, status: s) } label: {
                                if s == status { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                            }
                        }
                    } label: {
                        Text(status.title).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(busy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    if status == .open || status == .parked {
                        Button("Finish…") {
                            tab = .finish
                            model.researchAction("finish", entry.id, display: "Finish: summarize and propose what to keep")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                        .help("\(Brain.name) writes a summary and takeaways and proposes facts. Then you pick what goes on \(entry.researchFor.map { model.researchTargetTitle($0) } ?? "the knowledge base").")
                    }
                }
                .fixedSize()
            }
            if let t = entry.researchFor {
                Button {
                    model.openResearchTarget(t, scope: entry.project)
                } label: {
                    Label {
                        Text("For \(model.researchTargetTitle(t))").multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: t.isWorkItem ? "list.bullet.rectangle" : "link")
                    }
                }
                .buttonStyle(.link)
                .help("Open what this research is for")
            }
            Picker("", selection: $tab) {
                ForEach(ResearchTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.teal.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Finishing a research: the takeaways to carry over to what it is for, and the facts Claude proposed.
struct ResearchFinishView: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry
    @State private var takeaways: [String] = []
    @State private var picked: Set<Int> = []
    @State private var unticked: Set<EntryID> = []
    @State private var asComment = false
    @State private var applying = false
    @State private var loadedFrom = ""

    var body: some View {
        let parts = ResearchBody(entry.body)
        let proposals = model.index.inbox(project: entry.project, proposedBy: entry.id.rawValue)
        let session = model.researchSession(entry.id)
        let summarizing = entry.researchStatus != .review && entry.researchStatus != .done && session?.chat.isBusy == true
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch entry.researchStatus {
                    case .open, .parked:
                        intro(summarizing: summarizing)
                    case .done:
                        Label("This research is done.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    case .review:
                        EmptyView()
                    }
                    if !parts.summary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Summary").font(.headline)
                            Text(LocalizedStringKey(parts.summary)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if entry.researchStatus == .review {
                        takeawaysSection
                        proposalsSection(proposals)
                    } else if !parts.takeaways.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Takeaways").font(.headline)
                            ForEach(parts.takeaways, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.callout) }
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if entry.researchStatus == .review {
                Divider()
                HStack(spacing: 10) {
                    Button("Back to Researching") { model.setResearch(entry.id, status: .open) }
                        .disabled(applying)
                    Spacer(minLength: 8)
                    if applying { ProgressView().controlSize(.small) }
                    Button(finishTitle(proposals)) { apply(proposals) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(applying)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
        }
        .onAppear { load(parts) }
        .onChange(of: entry.body) { _, _ in load(ResearchBody(entry.body)) }
    }

    private func load(_ parts: ResearchBody) {
        let key = parts.takeaways.joined(separator: "\n")
        guard key != loadedFrom else { return }
        loadedFrom = key
        takeaways = parts.takeaways
        picked = Set(takeaways.indices)
    }

    @ViewBuilder
    private func intro(summarizing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Finish the research").font(.title3.weight(.semibold))
            Text("\(Brain.name) writes a summary and short takeaways, and proposes facts worth keeping. Then you pick which takeaways go on \(entry.researchFor.map { model.researchTargetTitle($0) } ?? "what it is for") and which facts to keep. Everything stays in the research.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if summarizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(Brain.name) is summarizing…").foregroundStyle(.secondary)
                }
            } else {
                Button("Summarize with \(Brain.name)") {
                    model.researchAction("finish", entry.id, display: "Finish: summarize and propose what to keep")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var takeawaysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Takeaways").font(.headline)
                Text("\(picked.count) of \(takeaways.count)").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if let t = entry.researchFor {
                Text("Ticked ones go on \(model.researchTargetTitle(t)). They stay in the research too.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if t.isWorkItem, model.trackerKind(entry.project) != "local" {
                        Picker("", selection: $asComment) {
                            Text("In the description").tag(false)
                            Text("As a comment").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                }
            } else {
                Text("This research isn't for a PBI, idea or discussion, so the takeaways stay here.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if takeaways.isEmpty {
                Text("\(Brain.name) wrote no takeaways.").foregroundStyle(.secondary)
            }
            ForEach(takeaways.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        if picked.contains(i) { picked.remove(i) } else { picked.insert(i) }
                    } label: {
                        Image(systemName: picked.contains(i) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(picked.contains(i) ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(entry.researchFor == nil)
                    TextField("Takeaway", text: Binding(get: { takeaways[i] }, set: { takeaways[i] = $0 }), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func proposalsSection(_ proposals: [KBEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Proposed for the knowledge base").font(.headline)
                Text("\(proposals.filter { !unticked.contains($0.id) }.count) of \(proposals.count) kept").foregroundStyle(.secondary)
            }
            if proposals.isEmpty {
                Text("\(Brain.name) proposed no facts.").foregroundStyle(.secondary)
            }
            ForEach(proposals) { e in
                let on = !unticked.contains(e.id)
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        if on { unticked.insert(e.id) } else { unticked.remove(e.id) }
                    } label: {
                        Image(systemName: on ? "checkmark.square.fill" : "square")
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)
                    VStack(alignment: .leading, spacing: 3) {
                        if let s = e.proposedSection { SectionChip(section: s) }
                        Text(e.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                        if !e.summary.isEmpty {
                            Text(e.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open") { model.openLink(e.id.rawValue) }.buttonStyle(.link).font(.caption)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func finishTitle(_ proposals: [KBEntry]) -> String {
        let n = entry.researchFor == nil ? 0 : picked.count
        let kept = proposals.filter { !unticked.contains($0.id) }.count
        var parts: [String] = []
        if n > 0, let t = entry.researchFor { parts.append("add \(n) to \(t.isWorkItem ? "the PBI" : "it")") }
        if kept > 0 { parts.append("keep \(kept)") }
        return parts.isEmpty ? "Finish" : "Finish: " + parts.joined(separator: ", ")
    }

    private func apply(_ proposals: [KBEntry]) {
        applying = true
        let chosen = takeaways.indices.filter { picked.contains($0) }.map { takeaways[$0] }
        let keep = proposals.filter { !unticked.contains($0.id) }.map(\.id)
        let decline = proposals.filter { unticked.contains($0.id) }.map(\.id)
        Task {
            _ = await model.finishResearch(entry.id, takeaways: entry.researchFor == nil ? [] : chosen, target: entry.researchFor,
                                           asComment: asComment, keep: keep, decline: decline)
            applying = false
        }
    }
}

// MARK: Starting one

struct NewResearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NewResearchRequest
    @State private var title = ""
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Research").font(.title2.weight(.semibold))
            if let t = request.target {
                Label("For \(model.researchTargetTitle(t))", systemImage: t.isWorkItem ? "list.bullet.rectangle" : "link")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What do you want to find out?").font(.headline)
                TextEditor(text: $question)
                    .font(.body)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }
            TextField("Title (optional: the first line of the question)", text: $title)
                .textFieldStyle(.roundedBorder)
            Text("\(Brain.name) starts in a Plan session under Research, looks in the knowledge base, the code and the web, and writes down findings, open questions and sources as it goes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Research") {
                    var r = request
                    r.title = title
                    r.question = question
                    model.startResearch(r)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.target == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            title = request.title
            question = request.question
        }
    }
}

/// On a PBI, idea or discussion: the research done for it, and a way to start more.
struct ResearchLinks: View {
    @Environment(AppModel.self) private var model
    let target: ResearchTarget
    let project: String
    var title = ""

    var body: some View {
        let list = model.research(for: target)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Research").font(.headline)
                Spacer(minLength: 8)
                Button {
                    model.newResearchRequest = NewResearchRequest(project: project, target: target, title: title)
                } label: {
                    Label("Research…", systemImage: ResearchStatus.icon)
                }
                .help("Look into something for this with \(Brain.name). When you finish, you pick the takeaways that go on it.")
            }
            ForEach(list) { r in
                Button {
                    model.openResearch(r.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Chip(text: r.researchStatus.title, color: r.researchStatus == .done ? .green : .teal)
                        Text(r.title).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Under a Build session that reads like research: asked once.
struct ResearchAsk: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession

    var body: some View {
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 220) {
            Image(systemName: ResearchStatus.icon).foregroundStyle(.teal).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("This sounds like research. Move it to Research in Plan?")
                    .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text("It keeps this conversation, writes down what was found so far, and lets you carry the takeaways to a PBI when you finish. It won't ask again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button("Keep in Build") {
                    session.researchAskShown = false
                    model.saveSessions()
                }
                Button("Move to Research") { model.moveToResearch(session) }
                    .buttonStyle(.borderedProminent)
            }
            .fixedSize()
        }
        .padding(12)
        .background(Color.teal.opacity(0.08))
        Divider()
    }
}
