import AppKit
import KBCore
import KBEngine
import SwiftUI

struct SessionsWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selectedSessionID) {
                let groups = model.planGroups(scope: nil)
                if groups.sections.isEmpty && groups.older.isEmpty {
                    ListEmptyState(title: "No sessions yet", systemImage: "bubble.left.and.text.bubble.right")
                }
                PlanSessionSections(groups: groups, inSessionsWindow: true)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            .toolbar {
                ToolbarItem {
                    Button { model.newSession() } label: { Label("New Session", systemImage: "square.and.pencil") }
                        .help("New \(Brain.name) session (⇧⌘K)")
                }
                ToolbarItem {
                    Button { model.newAssistantSession() } label: { Label("New Assistant Session", systemImage: "wand.and.stars") }
                        .help("A session that can do anything in Mindmill for you (⌥⌘A)")
                }
            }
        } detail: {
            if let s = model.selectedSession {
                SessionView(session: s).id(s.id)
            } else {
                SessionStartView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .navigationTitle(model.selectedSession?.title ?? "\(Brain.name)")
        .onAppear {
            model.loadSessionsIfNeeded()
            model.loadMeetingChatsIfNeeded()
            if model.selectedSession?.space != .plan {
                model.selectedSessionID = model.sessions.first { $0.space == .plan && $0.role != .overseer }?.id
            }
        }
    }
}

/// Shown when no session is selected: quick starts.
struct SessionStartView: View {
    @Environment(AppModel.self) private var model

    private let starts: [(title: String, icon: String, message: String?)] = [
        ("Blank session", "bubble.left.and.text.bubble.right", nil),
        ("Create a PBI or bug", "plus.rectangle.on.rectangle", "/mindmill:create-pbi"),
        ("Plan my day", "sun.max", "/mindmill:today"),
        ("Brief me on the project", "doc.text.magnifyingglass", "/mindmill:brief"),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles").font(.system(size: 38)).foregroundStyle(Color.accentColor)
            Text("Work on something with \(Brain.name)").font(.title2.weight(.semibold))
            Text("\(Brain.name) works in \(model.project?.title ?? "the knowledge base") and can run any skill. Type / in a session to pick one.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            VStack(spacing: 8) {
                ForEach(starts, id: \.title) { start in
                    Button {
                        model.newSession(title: start.message == nil ? nil : start.title, message: start.message,
                                         display: start.message == nil ? nil : start.title)
                    } label: {
                        Label(start.title, systemImage: start.icon).frame(width: 240, alignment: .leading)
                    }
                    .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.kbTheme) private var theme
    @Bindable var session: WorkSession
    @FocusState private var inputFocused: Bool
    @State private var multiPicked: Set<String> = []
    @State private var suggestionIndex = 0
    @State private var dropTargeted = false
    @State private var viewSize: CGSize = .zero
    @AppStorage(PanelDock.key("waitingPanel.overseer")) private var overseerDock = PanelDock.standard.rawValue
    @AppStorage(PanelDock.key("waitingPanel.lead")) private var leadDock = PanelDock.standard.rawValue

    private var hasWaitingPanel: Bool { session.space == .build && (session.role == .overseer || session.role == .lead) }

    private var waitingDock: PanelDock {
        PanelDock(rawValue: session.role == .lead ? leadDock : overseerDock) ?? .standard
    }

    private func setWaitingDock(_ dock: PanelDock) {
        if session.role == .lead { leadDock = dock.rawValue } else { overseerDock = dock.rawValue }
    }

    private var waitingPanel: some View {
        WaitingOnYouPanel(session: session, dock: waitingDock) { point in
            setWaitingDock(PanelDock.drop(at: point, in: viewSize))
        } move: { setWaitingDock($0) }
    }
    /// The way of working picked in an empty session; it starts with the first message.
    @State private var startStrategy: String?
    @State private var finding = false
    @State private var findText = ""
    @State private var findIndex = 0
    @State private var scrollTarget: UUID?
    @FocusState private var findFocused: Bool
    /// The conversation is scrolled to (near) its end; new output keeps it there. Scrolled up, a bar offers the way back.
    @State private var atEnd = true
    @State private var newBelow = false
    @State private var jumpToEnd = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if finding { findBar }
            if session.space == .build { workBanner }
            if session.space == .build, session.role != .member, let pr = model.linkedPR(session), !pr.draft,
               PRProblem.of(pr) == .conflicts, model.status(session) != .approved {
                MergeConflictBanner(pr: pr, session: session)
            }
            if session.space == .plan { CreatedItemsBar(session: session) }
            if hasWaitingPanel, waitingDock == .top { waitingPanel }
            transcript
                .environment(\.captureTarget, .session(session.id))
            if newBelow, !atEnd { newBelowBar }
            Divider()
            if !session.chat.denials.isEmpty, !session.chat.isBusy { denialCard }
            if session.chat.needsAzureSignIn, !session.chat.isBusy { AzureSignInCard(session: session) }
            if hasWaitingPanel, waitingDock != .top {
                waitingPanel
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, alignment: waitingDock == .bottomLeading ? .leading : .trailing)
            }
            if session.space == .build, session.role != .overseer { completeAsks }
            if session.space == .build, model.asksToArchive(session) { ArchiveAsk(session: session) }
            if session.space == .build, session.researchAskShown { ResearchAsk(session: session) }
            if session.space == .build, session.testAskShown { TestAskCard(session: session) }
            if let s = session.subject { subjectChip(s) }
            if !suggestions.isEmpty { suggestionList }
            inputBar
        }
        .background(Color(hex: theme.contentBackground) ?? Color(nsColor: .textBackgroundColor))
        .coordinateSpace(name: WaitingOnYouPanel.space)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        .onAppear { inputFocused = true }
        .onChange(of: model.findRequest) { _, _ in
            guard isInFront else { return }
            finding = true
            findFocused = true
        }
    }

    /// The session the user sees: the one picked in Build, the Overview when nothing is, or the one open in the
    /// Claude window.
    private var isInFront: Bool {
        if session.space == .build {
            return model.mode == .build && (model.buildSelection == session.id || (session.role == .overseer && model.buildSelection == nil))
        }
        return model.selectedSessionID == session.id
    }

    // MARK: Find

    /// The messages that have the text searched for, in order.
    private var findMatches: [UUID] {
        let q = findText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return groups.filter { g in g.items.contains { $0.text.localizedCaseInsensitiveContains(q) } }.map(\.id)
    }

    private var findBar: some View {
        let matches = findMatches
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in this conversation", text: $findText)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { step(1) }
                .onChange(of: findText) { _, _ in
                    findIndex = 0
                    scrollTarget = findMatches.first
                }
            Text(findText.isEmpty ? "" : matches.isEmpty ? "No matches" : "\(min(findIndex, matches.count - 1) + 1) of \(matches.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(matches.count < 2).help("Previous match (⇧↩)")
                .keyboardShortcut(.return, modifiers: .shift)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .disabled(matches.count < 2).help("Next match (↩)")
            Button("Done") { closeFind() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func step(_ by: Int) {
        let matches = findMatches
        guard !matches.isEmpty else { return }
        findIndex = (findIndex + by + matches.count) % matches.count
        scrollTarget = matches[findIndex]
    }

    private func closeFind() {
        finding = false
        findText = ""
        scrollTarget = nil
        inputFocused = true
    }

    // MARK: Header

    private var header: some View {
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 180) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Title", text: $session.title, axis: .vertical).textFieldStyle(.plain).font(.headline).lineLimit(1...3)
                Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                PlannedInLink(session: session)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ChipRow(spacing: 10) { headerActions }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var headerActions: some View {
        if session.space == .build {
            let badges = model.badges(session)
            if session.role != .overseer {
                SessionBadgePills(session: session, badges: badges)
            } else if let activity = badges.activity, activity.needsUser || activity == .running {
                StatusPill(status: activity)
            }
        }
        if session.space == .build, session.role != .member, let pr = model.linkedPR(session), pr.openThreads > 0, !pr.draft {
            CommentsButton(pr: pr, session: session)
        }
        if session.space == .build, session.role != .overseer, let pr = model.linkedPR(session) {
            PRMenuButton(pr: pr, session: session)
        }
        if session.space == .build, let id = model.reviewedPR(session) {
            ReviewVoteMenu(prID: id, session: session)
        }
        if let item = model.sessionWorkItem(session), let scope = session.project {
            WorkItemHeaderButton(item: item, scope: scope)
        }
        if session.space == .build, session.role != .overseer, session.project != nil { TestHeaderButton(session: session) }
        if session.role != .overseer { StrategyButton(session: session) }
        if session.space == .plan { PlanArchiveButton(session: session) }
        if session.chat.isBusy {
            Button { model.stopSession(session) } label: { Label("Stop", systemImage: "stop.circle") }
                .help("Stop \(Brain.name). Your next message continues the same conversation.")
        }
        Menu {
            Button("Continue in Terminal") { model.openSessionInTerminal(session) }
            Button("Reconnect Tools") { model.reconnectSession(session) }
                .disabled(session.chat.isBusy || session.claudeSessionID == nil)
                .help("Start \(Brain.name) again on this conversation, for when a tool such as the doc connector dropped out")
            if session.space == .plan, !session.isResearchSession, !session.isAssistant {
                Button("Move to Build") { model.moveToBuild(session) }
            }
            if session.role == .solo || session.role == .member, !session.isResearchSession, !session.isAssistant {
                Button("Move to Research in Plan") { model.moveToResearch(session) }
            }
            Button("Copy Conversation") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.chat.items.filter { $0.role == .user || $0.role == .assistant }
                    .map { ($0.role == .user ? "**You:** " : "") + $0.text }.joined(separator: "\n\n"), forType: .string)
            }
            Divider()
            if session.space == .build {
                if model.isArchived(session) {
                    Button("Move Out of the Archive") { model.setArchived(session, false) }
                } else {
                    Button("Archive") { model.setArchived(session, true) }
                }
            }
            Button("Delete Session", role: .destructive) { model.deleteSession(session) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The session's pull request, when it is approved but something still blocks it.
    @ViewBuilder
    private var workBanner: some View {
        if let pr = model.linkedPR(session), !pr.draft, pr.openThreads == 0, model.status(session) == .approved, !pr.canComplete {
            AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 200) {
                Image(systemName: "checkmark.seal").foregroundStyle(.mint).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("!\(String(pr.id)) is approved").font(.callout.weight(.semibold))
                    Text("Before it can be completed: \(pr.blockers.joined(separator: ", ").lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button("Open PR") { model.openPRInBuild(pr.id) }
                    Button("Fix Blockers") { model.fixBlockers(pr, in: session) }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.chat.isBusy || pr.blockers.allSatisfy { $0 == PRBlocker.buildQueued || $0 == PRBlocker.buildExpired })
                        .help("This session fixes the build or the conflicts, pushes, and tells you when the PR can be completed")
                }
                .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Color.mint.opacity(0.08))
            Divider()
        }
    }

    private var location: String {
        let project = session.project.flatMap { model.index.project($0)?.title } ?? "Knowledge base"
        let path = session.workingDirectory.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        var parts: [String] = []
        switch session.role {
        case .overseer: return "Overview session · sees every session"
        case .lead: parts.append("Lead")
        case .member: parts.append("Under " + (model.session(session.parentID)?.title ?? "a lead"))
        case .solo: break
        }
        parts += [project, path]
        return parts.joined(separator: " · ")
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if session.chat.items.isEmpty && !session.chat.isBusy {
                        if session.role == .overseer { OverviewEmptyState() } else { emptyState }
                    }
                    let matches = finding ? findMatches : []
                    let current = matches.isEmpty ? nil : matches[min(findIndex, matches.count - 1)]
                    ForEach(groups) { group in
                        groupView(group).id(group.id)
                            .padding(matches.contains(group.id) ? 6 : 0)
                            .background {
                                if matches.contains(group.id) {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.yellow.opacity(group.id == current ? 0.28 : 0.1))
                                }
                            }
                    }
                    if session.chat.isBusy {
                        WorkingIndicator(activity: session.chat.activity).id("busy")
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
                Color.clear.frame(height: 18).id("end")
            }
            // Opens at the end, without scrolling down through the conversation.
            .defaultScrollAnchor(.bottom)
            .modifier(EndTracker(atEnd: $atEnd))
            .onChange(of: atEnd) { _, now in if now { newBelow = false } }
            .onChange(of: session.chat.items.count) { old, new in
                guard !finding else { return }
                // Your own message always takes the view to the end.
                if session.chat.items.last?.role == .user { atEnd = true }
                // A conversation loading in (many items at once) jumps; one new message glides.
                follow(proxy, animated: old > 0 && new - old <= 2)
            }
            .onChange(of: session.chat.items.last?.text.count) { _, _ in if !finding { follow(proxy, animated: false) } }
            .onChange(of: session.chat.isBusy) { _, _ in if !finding { follow(proxy) } }
            .onChange(of: jumpToEnd) { _, _ in
                atEnd = true
                newBelow = false
                scrollToEnd(proxy)
            }
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear { scrollToEnd(proxy, animated: false) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
        } else {
            proxy.scrollTo("end", anchor: .bottom)
        }
    }

    /// Keeps the end in view while you're there; scrolled up, it only says something new arrived.
    private func follow(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if atEnd {
            scrollToEnd(proxy, animated: animated)
        } else if !session.chat.items.isEmpty {
            newBelow = true
        }
    }

    /// In the layout under the conversation, never over it.
    private var newBelowBar: some View {
        Button { jumpToEnd += 1 } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                Text(session.chat.isBusy ? "New output below" : "A response is ready below")
                Spacer(minLength: 0)
                Text("Scroll to the end").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .background(Color.accentColor.opacity(0.08))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What do you want to work on?").font(.title3.weight(.semibold))
            Text("Describe the task, or type / to run a skill such as /mindmill:create-pbi. \(Brain.name) can read the knowledge base and the project's code, and asks before anything leaves this Mac.")
                .foregroundStyle(.secondary)
            if session.role == .solo, session.parentID == nil, session.strategy == nil, !model.strategies.isEmpty {
                StartWayPicker(selection: $startStrategy)
                    .padding(.top, 14)
            }
        }
        .padding(.top, 24)
    }

    private struct Group: Identifiable {
        let id: UUID
        let items: [ClaudeChat.Item]
        var isTools: Bool { items.first?.role == .tool }
    }

    /// Consecutive tool calls fold into one group.
    private var groups: [Group] {
        var out: [Group] = []
        for item in session.chat.items {
            if item.role == .tool, let last = out.last, last.isTools {
                out[out.count - 1] = Group(id: last.id, items: last.items + [item])
            } else {
                out.append(Group(id: item.id, items: [item]))
            }
        }
        return out
    }

    @ViewBuilder
    private func groupView(_ group: Group) -> some View {
        if group.isTools {
            ToolSteps(items: group.items, running: session.chat.isBusy && group.id == groups.last?.id)
        } else if let item = group.items.first {
            switch item.role {
            case .user:
                VStack(alignment: .trailing, spacing: 4) {
                    if !item.attachments.isEmpty { MessageAttachments(attachments: item.attachments) }
                    if !item.text.isEmpty { UserMessageView(text: item.text) }
                    if let tag = item.tag, session.chat.pendingTags.contains(tag) {
                        Button {
                            model.cancelMessage(item, in: session)
                        } label: {
                            Label("Cancel and Edit", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Take this message back: it returns to the box below to change. If \(Brain.name) has started on it, it stops.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            case .assistant:
                MarkdownDocument(text: item.text, choices: choicesHandler(for: item))
            case .error:
                VStack(alignment: .leading, spacing: 6) {
                    Label(item.text, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    if session.chat.needsSignIn, ClaudeAuth.isSignInProblem(item.text), item.id == lastErrorID {
                        Button("Sign In Again…") { model.openClaudeSignIn() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("Sign in to \(Brain.name) in the browser; this session then sends your message again")
                    } else if item.id == session.chat.retryItemID {
                        Button { model.retryLast(in: session) } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .help("Send your last message again")
                    }
                }
            case .status, .tool:
                Text(item.text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var lastErrorID: UUID? { session.chat.items.last { $0.role == .error }?.id }

    private func choicesHandler(for item: ClaudeChat.Item) -> ChoiceHandler? {
        guard let waiting = session.waitingChoices, waiting.itemID == item.id else { return nil }
        return ChoiceHandler(
            multi: waiting.multi,
            picked: multiPicked,
            toggle: { option in
                if multiPicked.contains(option) { multiPicked.remove(option) } else { multiPicked.insert(option) }
            },
            choose: { answer in
                multiPicked = []
                if session.role == .overseer {
                    model.askOverseer(answer)
                } else {
                    model.send(answer, in: session)
                    model.userAnswered(session, answer)
                }
            })
    }

    // MARK: Bottom

    /// Asks to complete each pull request that is ready: the session's own, and for a lead, those of the
    /// sessions under it.
    @ViewBuilder
    private var completeAsks: some View {
        let ready = model.readyPRs(session).filter { !model.completeAsksDeclined.contains($0.pr.id) }
        ForEach(ready, id: \.pr.id) { item in
            let pr = item.pr
            AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 220) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("!\(String(pr.id)) is ready to complete. Complete it now?").font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(pr.title).font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(detail(pr, from: item.session))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button("Not Now") { model.completeAsksDeclined.insert(pr.id) }
                        .help("Stop asking in this session until Mindmill restarts. Complete stays in the session's menu.")
                    Button("Open PR") { model.openPRInBuild(pr.id) }
                    Button("Complete…") { model.completePRRequest = CompletePRRequest(id: pr.id) }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                }
                .fixedSize()
            }
            .padding(12)
            .background(Color.green.opacity(0.08))
            Divider()
        }
    }

    private func detail(_ pr: PullRequest, from: WorkSession) -> String {
        var parts = ["\(pr.approvals) approval\(pr.approvals == 1 ? "" : "s")", "checks passed", "no open comments", pr.repo]
        if from.id != session.id { parts.insert("From “\(SessionTitle.split(from.title).text)”", at: 0) }
        return parts.joined(separator: " · ")
    }

    private var denialCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Brain.name) wasn't allowed to run:").font(.callout.weight(.medium))
                ForEach(session.chat.denials, id: \.self) { d in
                    Text(d).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button("Allow for This Session") { model.allowDenied(in: session) }
                .help(session.chat.denials.map(AppModel.allowPattern).joined(separator: ", "))
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
    }

    private func subjectChip(_ s: AskSubject) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip").foregroundStyle(Color.accentColor)
            Text("About: ").foregroundStyle(.secondary) + Text(s.title).fontWeight(.medium)
            Spacer()
            Button { session.subject = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var suggestions: [String] {
        let t = session.input
        guard t.hasPrefix("/"), !t.contains(" "), !t.contains("\n") else { return [] }
        let q = t.dropFirst().lowercased()
        let all = session.chat.commands.isEmpty ? model.fallbackCommands(for: session) : session.chat.commands
        let matches = all.filter { q.isEmpty || $0.lowercased().contains(q) }
        let ranked = matches.sorted { a, b in
            let ap = a.lowercased().hasPrefix(q) || a.lowercased().hasPrefix("mindmill:" + q)
            let bp = b.lowercased().hasPrefix(q) || b.lowercased().hasPrefix("mindmill:" + q)
            return ap != bp ? ap : a < b
        }
        return Array(ranked.prefix(8))
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { i, name in
                Button {
                    session.input = "/\(name) "
                    inputFocused = true
                } label: {
                    HStack {
                        Text("/\(name)").font(.callout.monospaced())
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(i == min(suggestionIndex, suggestions.count - 1) ? Color.accentColor.opacity(0.14) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
        PendingAttachments(session: session)
        HStack(alignment: .bottom, spacing: 8) {
            TextField(session.chat.items.isEmpty ? "Describe the task, or type / for a skill…" : "Reply…",
                      text: $session.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...)
                .scrollingInput(session.input, maxLines: 10)
                .focused($inputFocused)
                .padding(.vertical, 10)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textInputArea { inputFocused = true }
                .onSubmit(submit)
                .onKeyPress(.tab) {
                    guard let pick = currentSuggestion else { return .ignored }
                    session.input = "/\(pick) "
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    suggestionIndex = min(suggestionIndex + 1, suggestions.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    suggestionIndex = max(suggestionIndex - 1, 0)
                    return .handled
                }
                .onChange(of: session.input) { _, _ in suggestionIndex = 0 }
                .promptKeys($session.input, paused: !suggestions.isEmpty)
                .pastesAttachments(active: inputFocused) { model.attachFromPasteboard($0, to: session) }
            Button { model.pickAttachments(for: session) } label: { Image(systemName: "paperclip") }
                .buttonStyle(.borderless)
                .help("Attach files, images or folders. You can also paste them (⌘V), or a picture you copied in a browser, or drop them here.")
                .padding(.bottom, 14)
            ShareWebPageButton(target: .session(session.id))
                .padding(.bottom, 14)
            DictationButton(text: $session.input, onSend: submit)
                .padding(.bottom, 14)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.pendingAttachments.isEmpty)
            .keyboardShortcut(.return, modifiers: [.command])
            .padding(.bottom, 10)
        }
        .padding(.trailing, 12)
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { model.attachDropped($0, to: session) }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: dropTargeted ? 2 : 1))
        .padding(12)
    }

    private var currentSuggestion: String? {
        suggestions.isEmpty ? nil : suggestions[min(suggestionIndex, suggestions.count - 1)]
    }

    private func submit() {
        if let pick = currentSuggestion, session.input == "/" + session.input.dropFirst(), !session.input.contains(" "),
           pick != String(session.input.dropFirst()) {
            session.input = "/\(pick) "
            return
        }
        let files = session.pendingAttachments
        model.recordPrompt(session.input)
        if session.role == .overseer {
            let t = session.input
            session.input = ""
            model.askOverseer(t, attachments: files)
        } else if session.chat.items.isEmpty, let slug = startStrategy, let st = model.strategies.first(where: { $0.slug == slug }) {
            let task = session.input
            session.input = ""
            startStrategy = nil
            model.start(task, with: st, in: session, attachments: files)
        } else {
            let text = session.input
            model.send(text, in: session, attachments: files)
            model.userAnswered(session, text)
        }
    }
}

/// In an empty session: work on it alone, or with a strategy. Auto crew comes first; the choice starts with the
/// first message. The header's Strategy menu changes it later.
private struct StartWayPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How do you want to work on it?").font(.headline)
            card(title: "Just this session", summary: "You and \(Brain.name), one conversation.", icon: "bubble.left.and.text.bubble.right",
                 selected: selection == nil, flow: nil) { selection = nil }
            ForEach(ordered) { st in
                card(title: st.title, summary: st.summary, icon: st.spawns ? "person.3.fill" : "point.3.connected.trianglepath.dotted",
                     selected: selection == st.slug, flow: st) { selection = st.slug }
            }
            Text(selection == nil ? "Pick a strategy any time from Strategy at the top."
                 : "It starts with your first message. Describe the task below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var ordered: [Strategy] {
        model.strategies.sorted { a, b in
            if (a.slug == "auto-crew") != (b.slug == "auto-crew") { return a.slug == "auto-crew" }
            return false
        }
    }

    private func card(title: String, summary: String, icon: String, selected: Bool, flow: Strategy?,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: icon).font(.body.weight(.medium))
                    if !summary.isEmpty {
                        Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    if let flow { StrategyMiniFlow(strategy: flow) }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WorkingIndicator: View {
    let activity: String?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(activity.map { "Working… \($0)" } ?? "Thinking…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// A command in a small code box: monospaced, scrolls sideways, copyable.
struct CommandBlock: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(12)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.15)))
    }
}

/// A run of tool calls, folded to one line; expands to show each step.
struct ToolSteps: View {
    let items: [ClaudeChat.Item]
    let running: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2.weight(.semibold))
                    Image(systemName: "wrench.and.screwdriver").font(.caption)
                    Text(expanded ? "\(items.count) step\(items.count == 1 ? "" : "s")" : summary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        let step = ToolDescription.step(item.text)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            if let code = step.code { CommandBlock(code: code) }
                        }
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let step = items.last.map { ToolDescription.step($0.text).title } ?? ""
        return items.count == 1 ? step : "\(items.count) steps · \(step)"
    }
}

/// What the user sent, or a message from another session (✉), in a bubble on the right. Markdown shows
/// formatted, code in a box, and a session's message gets its sender on top and its option lists on lines.
struct UserMessageView: View {
    let text: String
    var minLeading: CGFloat = 80

    var body: some View {
        HStack {
            Spacer(minLength: minLeading)
            VStack(alignment: .leading, spacing: 6) {
                if let m = CrewMessage.split(text) {
                    Label(m.from, systemImage: "envelope.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    MarkdownDocument(text: CrewMessage.readable(m.text))
                } else if Self.isPlain(text) {
                    Text(text).textSelection(.enabled)
                } else {
                    MarkdownDocument(text: text)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One short line without markup reads best as it is, and keeps the bubble narrow.
    static func isPlain(_ s: String) -> Bool {
        !s.contains("\n") && !s.contains("`") && !s.contains("**") && !s.contains("|")
    }
}

/// Whether a scroll view shows its end, on macOS 15 and later; before that it always counts as at the end, so
/// new output keeps scrolling into view as it did.
private struct EndTracker: ViewModifier {
    @Binding var atEnd: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
            } action: { _, now in
                if now != atEnd { atEnd = now }
            }
        } else {
            content
        }
    }
}

extension View {
    /// The whole area focuses the text field and shows the text cursor, not just the line of text.
    func textInputArea(focus: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: focus)
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.iBeam.set()
                case .ended: NSCursor.arrow.set()
                }
            }
    }
}
