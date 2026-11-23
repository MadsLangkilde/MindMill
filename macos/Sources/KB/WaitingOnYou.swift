import KBCore
import SwiftUI

/// What waits on the user, answerable right here: in the Overview every Build session that needs you (and factory
/// questions), in a lead the sessions under it. Answering here is the same as answering in the session itself.
/// It docks above the input on the right by default; its handle drags it to another dock, and its menu puts it back.
struct WaitingOnYouPanel: View {
    static let space = "sessionView"
    @Environment(AppModel.self) private var model
    let session: WorkSession
    var dock: PanelDock = .standard
    /// Where the handle was let go, in the session view's coordinates.
    var dropped: (CGPoint) -> Void = { _ in }
    var move: (PanelDock) -> Void = { _ in }
    @State private var open = true
    @State private var contentHeight: CGFloat = 0
    @State private var drag: CGSize = .zero

    private var waiting: [WorkSession] {
        switch session.role {
        case .overseer: return model.buildSessionsNeedingUser.sorted { $0.updated > $1.updated }
        case .lead: return model.members(of: session).filter(\.crewState.needsUser)
        default: return []
        }
    }

    private var factories: [(factory: Factory, count: Int)] {
        guard session.role == .overseer else { return [] }
        return model.factories.compactMap { f in
            let n = f.run?.openQuestions.count ?? 0
            return n > 0 ? (f, n) : nil
        }
    }

    /// Sessions whose work is done, asking to be archived (the Overview only).
    private var done: [WorkSession] {
        guard session.role == .overseer else { return [] }
        return model.buildSessions.filter(model.asksToArchive).sorted { $0.updated > $1.updated }
    }

    var body: some View {
        let sessions = waiting
        let factories = factories
        let done = done
        let plan = session.role == .overseer ? model.planSessionsNeedingUser : []
        let total = sessions.count + factories.reduce(0) { $0 + $1.count } + plan.count
        if total + done.count > 0 {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(coordinateSpace: .named(Self.space))
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            drag = .zero
                            withAnimation(.snappy) { dropped(value.location) }
                        })
                    .help("Drag to move this panel: to the top, or above the input on the left or right")
                Button { withAnimation(.snappy) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Text(session.role == .lead ? "Sessions under this lead wait on you" : "Waiting on you")
                            .font(.callout.weight(.semibold))
                        if total > 0 {
                            Text("\(total)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.orange, in: Capsule())
                        }
                        if !done.isEmpty {
                            Text("\(done.count) done").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                }
                .padding(.leading, 10)
                .padding(.trailing, 18)
                .padding(.vertical, 8)
                .contextMenu {
                    ForEach(PanelDock.allCases, id: \.self) { d in
                        Button { withAnimation(.snappy) { move(d) } } label: {
                            if d == dock { Label(d.title, systemImage: "checkmark") } else { Text(d.title) }
                        }
                    }
                    Divider()
                    Button("Back to the Default Place") { withAnimation(.snappy) { move(.standard) } }
                }
                if open {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(sessions) { s in WaitingSessionCard(waiting: s, from: session) }
                            ForEach(factories, id: \.factory.id) { item in factoryRow(item.factory, item.count) }
                            if !plan.isEmpty { planRow(plan) }
                            ForEach(done) { s in ArchiveAsk(session: s, inOverview: true) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { h in
                            if abs(h - contentHeight) > 1 { contentHeight = h }
                        }
                    }
                    // A scroll bar only once it is capped, so the bar's width can't change the height it measures.
                    .scrollIndicators(contentHeight > cap ? .automatic : .never)
                    .frame(height: min(max(contentHeight, 1), cap))
                }
            }
            .background(dock == .top ? Color.orange.opacity(0.06) : Color(nsColor: .windowBackgroundColor))
            .background(Color.orange.opacity(dock == .top ? 0 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: dock == .top ? 0 : 10))
            .overlay {
                if dock != .top { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)) }
            }
            .padding(dock == .top ? 0 : 10)
            .offset(drag)
            .shadow(color: .black.opacity(drag == .zero ? 0 : 0.25), radius: 10, y: 4)
            .zIndex(drag == .zero ? 0 : 10)
            if dock == .top { Divider() }
        }
    }

    /// Above the input it shares the height with the conversation, so it stays shorter.
    private var cap: CGFloat { dock == .top ? 380 : 300 }

    /// Plan sessions are answered in Plan; this only says they wait there.
    private func planRow(_ plan: [WorkSession]) -> some View {
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 200) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(plan.count) session\(plan.count == 1 ? "" : "s") in Plan need\(plan.count == 1 ? "s" : "") you")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(plan.map { "“\($0.title)”" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open in Plan") { if let s = plan.first { model.openPlanSession(s) } }
                .fixedSize()
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
    }

    private func factoryRow(_ f: Factory, _ count: Int) -> some View {
        AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 200) {
            Image(systemName: "gearshape.2.fill").foregroundStyle(.orange)
            Text("\(f.name) has \(count) question\(count == 1 ? "" : "s") for you")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open Factory") { model.buildSelection = AppModel.factoryTag + f.id }
                .fixedSize()
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
    }
}

/// One waiting session: what it asks, its choices, a reply box, and Allow when it was refused a tool.
private struct WaitingSessionCard: View {
    @Environment(AppModel.self) private var model
    let waiting: WorkSession
    /// The session showing the card (the Overview or a lead).
    let from: WorkSession
    @State private var reply = ""
    @State private var picked: Set<String> = []
    @State private var whole = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveCardLayout(spacing: 8, stackedSpacing: 6, minInfoWidth: 200) {
                StateDot(state: waiting.crewState)
                VStack(alignment: .leading, spacing: 1) {
                    Text(SessionTitle.split(waiting.title).text).font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(place).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open Session") { model.openSession(waiting) }.fixedSize()
            }
            if !waiting.chat.denials.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Brain.name) wasn't allowed to run:").font(.caption.weight(.medium))
                    ForEach(waiting.chat.denials, id: \.self) { d in
                        Text(d).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Button("Allow for That Session") { model.allowDenied(in: waiting) }
                        .help(waiting.chat.denials.map(AppModel.allowPattern).joined(separator: ", "))
                }
            } else if let last = waiting.chat.items.last(where: { $0.role == .assistant }) {
                let tail = MarkdownBlocks.tail(last.text)
                if tail.cut {
                    Button(whole ? "Show less" : "Show the whole message") { whole.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
                MarkdownDocument(text: whole ? last.text : (tail.cut ? "…\n\n" : "") + tail.text, choices: choices(for: last.id))
                    .textSelection(.enabled)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Answer \(SessionTitle.split(waiting.title).text)…", text: $reply, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || waiting.chat.isBusy)
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
    }

    private var place: String {
        var parts: [String] = []
        if let p = waiting.project.flatMap({ model.index.project($0)?.title }) { parts.append(p) }
        if waiting.role == .member, from.role != .lead, let lead = model.session(waiting.parentID) {
            parts.append("under “\(SessionTitle.split(lead.title).text)”")
        }
        parts.append(waiting.crewState.label)
        return parts.joined(separator: " · ")
    }

    private func choices(for itemID: UUID) -> ChoiceHandler? {
        guard let w = waiting.waitingChoices, w.itemID == itemID else { return nil }
        return ChoiceHandler(
            multi: w.multi,
            picked: picked,
            toggle: { o in if picked.contains(o) { picked.remove(o) } else { picked.insert(o) } },
            choose: { answer in
                picked = []
                model.send(answer, in: waiting)
                model.userAnswered(waiting, answer)
            })
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !waiting.chat.isBusy else { return }
        model.send(text, in: waiting)
        model.userAnswered(waiting, text)
        reply = ""
    }
}

/// A session whose work is done asks whether to archive it. Keep leaves it in the list for good; unanswered, it is
/// archived by itself after a few days.
struct ArchiveAsk: View {
    @Environment(AppModel.self) private var model
    let session: WorkSession
    var inOverview = false

    var body: some View {
        let card = AdaptiveCardLayout(spacing: 10, stackedSpacing: 8, minInfoWidth: 220) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(inOverview ? "“\(SessionTitle.split(session.title).text)” is done. Archive it?" : "The work is done. Archive this session?")
                    .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(model.doneReason(session) + " Archived sessions stay under Archived and can be moved back.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if inOverview { Button("Open") { model.openSession(session) } }
                Button("Keep") { session.archived = false; model.saveSessions() }
                    .help("Keep it in the list; it won't ask again")
                Button("Archive") { model.setArchived(session, true) }
                    .buttonStyle(.borderedProminent)
            }
            .fixedSize()
        }
        if inOverview {
            card.padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.green.opacity(0.35)))
        } else {
            card.padding(12).background(Color.green.opacity(0.08))
            Divider()
        }
    }
}
