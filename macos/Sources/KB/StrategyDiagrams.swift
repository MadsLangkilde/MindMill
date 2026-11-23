import KBCore
import SwiftUI

/// A box in a strategy diagram.
private struct DiagramNode: View {
    let label: String
    let systemImage: String
    var detail: String?
    var color: Color = .accentColor
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font((compact ? Font.caption : .callout).weight(.medium)).lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, compact ? 7 : 10)
        .padding(.vertical, compact ? 4 : 6)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.35)))
    }
}

private struct Connector: View {
    var systemImage = "arrow.left.and.right"
    var label: String?

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: systemImage).font(.caption).foregroundStyle(.secondary)
            if let label { Text(label).font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize() }
        }
        .padding(.horizontal, 2)
    }
}

/// Who works: you, the overview, the lead that follows the strategy, and the sessions it starts.
/// Side by side when there is room, top to bottom when not, so nothing is cut off.
struct StrategyTeamDiagram: View {
    let strategy: Strategy
    var compact = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chain(vertical: false) }
            VStack(alignment: .leading, spacing: 4) { chain(vertical: true) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func chain(vertical: Bool) -> some View {
        let shape = strategy.shape
        DiagramNode(label: "You", systemImage: "person.fill", color: .blue, compact: compact)
        Connector(systemImage: vertical ? "arrow.up.and.down" : "arrow.left.and.right", label: compact ? nil : "ask, steer")
        DiagramNode(label: "Overview", systemImage: "binoculars.fill", color: .indigo, compact: compact)
        Connector(systemImage: vertical ? "arrow.up.and.down" : "arrow.left.and.right", label: compact ? nil : "reports, needs")
        DiagramNode(label: "Lead", systemImage: "person.crop.circle.badge.checkmark",
                    detail: compact ? nil : [strategy.title, strategy.leadModel.capitalized].filter { !$0.isEmpty }.joined(separator: " · "),
                    color: .purple, compact: compact)
        if !shape.helpers.isEmpty {
            Connector(systemImage: vertical ? "arrow.down" : "arrow.right", label: compact ? nil : "starts")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(shape.helpers.enumerated()), id: \.offset) { _, h in
                    HStack(spacing: 6) {
                        DiagramNode(label: h.label, systemImage: Self.icon(h.role?.kind),
                                    detail: h.model.isEmpty ? nil : h.model.capitalized, color: Self.color(h.role?.kind), compact: compact)
                        if !compact, let r = h.role { Text(Self.relation(r)).font(.caption2).foregroundStyle(.secondary).fixedSize() }
                    }
                }
            }
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.teal.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            if !compact, strategy.roles.isEmpty {
                Text(shape.helpers.count > 1 ? "up to \(strategy.maxSessions), in parallel" : "checks each step")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize()
            }
        } else if !compact {
            Text("works alone").font(.caption2).foregroundStyle(.secondary).fixedSize()
        }
    }

    static func icon(_ kind: StrategyRole.Kind?) -> String {
        switch kind {
        case .builder: return "hammer.fill"
        case .reviewer: return "checkmark.shield.fill"
        case .helper: return "wrench.and.screwdriver.fill"
        case nil: return "person.2.fill"
        }
    }

    static func color(_ kind: StrategyRole.Kind?) -> Color {
        switch kind {
        case .reviewer: return .orange
        case .helper: return .gray
        default: return .teal
        }
    }

    static func relation(_ r: StrategyRole) -> String {
        switch r.kind {
        case .builder: return r.count > 1 ? "build parts in parallel" : "builds a part"
        case .reviewer: return "checks " + r.checkpoint.title.lowercased()
        case .helper: return "helps"
        }
    }
}

/// How it runs: the numbered steps top to bottom, approvals in orange, repeated steps marked.
struct StrategyFlowDiagram: View {
    let strategy: Strategy

    var body: some View {
        let shape = strategy.shape
        HStack(alignment: .top, spacing: 10) {
            if shape.loops {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise").font(.caption).foregroundStyle(.orange)
                    Rectangle().fill(Color.orange.opacity(0.4)).frame(width: 2)
                    Text("for each").font(.caption2).foregroundStyle(.orange).fixedSize().rotationEffect(.degrees(-90))
                        .frame(width: 14, height: 50)
                    Rectangle().fill(Color.orange.opacity(0.4)).frame(width: 2)
                }
                .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shape.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .center, spacing: 10) {
                        ZStack {
                            if step.kind == .approval {
                                RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.18))
                                    .frame(width: 20, height: 20).rotationEffect(.degrees(45))
                                Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                            } else if step.kind == .review {
                                Circle().fill(Color.orange.opacity(0.15)).frame(width: 24, height: 24)
                                Image(systemName: "checkmark.shield.fill").font(.caption).foregroundStyle(.orange)
                            } else {
                                Circle().fill(Color.purple.opacity(0.15)).frame(width: 24, height: 24)
                                Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.purple)
                            }
                        }
                        .frame(width: 28, height: 28)
                        Text(step.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if step.kind == .approval {
                            Text("you approve").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                        if step.kind == .review {
                            Text("reviewer").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                        if step.repeats {
                            Label("repeats", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if i < shape.steps.count - 1 {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2, height: 12).padding(.leading, 13)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One line: the steps as small chips with arrows, for cards and menus.
struct StrategyMiniFlow: View {
    let strategy: Strategy

    var body: some View {
        let steps = strategy.shape.steps
        ChipRow(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
                Text(step.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(step.kind == .work ? Color.primary : .orange)
                    .background((step.kind == .work ? Color.purple : Color.orange).opacity(0.10), in: Capsule())
            }
        }
    }
}

/// Both diagrams with the summary: what a strategy looks like before you pick it.
struct StrategyPicture: View {
    let strategy: Strategy

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !strategy.summary.isEmpty {
                Text(strategy.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Who works").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                StrategyTeamDiagram(strategy: strategy)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("How it runs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                StrategyFlowDiagram(strategy: strategy)
            }
        }
    }
}

/// The overview's ```strategy block: a card per strategy to click, and one for none.
struct StrategyPicker: View {
    @Environment(AppModel.self) private var model
    let options: [String]
    let handler: ChoiceHandler?

    var body: some View {
        let entries = options.map { raw -> (Strategy?, String, Bool) in
            let recommended = raw.localizedCaseInsensitiveContains("(recommended)")
            let key = raw.replacingOccurrences(of: "(Recommended)", with: "").replacingOccurrences(of: "(recommended)", with: "")
                .trimmingCharacters(in: .whitespaces)
            let st = model.strategies.first { $0.slug == key || $0.title.caseInsensitiveCompare(key) == .orderedSame }
            return (st, key, recommended)
        }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                card(e.0, key: e.1, recommended: e.2)
            }
            if !entries.contains(where: { $0.1.lowercased().contains("no strategy") || $0.1.lowercased() == "none" }) {
                card(nil, key: "No strategy", recommended: false)
            }
            if handler != nil { Text("Or type your own answer below.").font(.caption).foregroundStyle(.tertiary) }
        }
    }

    private func card(_ st: Strategy?, key: String, recommended: Bool) -> some View {
        Button {
            handler?.choose(st.map { "Use the “\($0.title)” strategy (\($0.slug))." } ?? "No strategy.")
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: st == nil ? "circle.slash" : "point.3.connected.trianglepath.dotted").foregroundStyle(.purple)
                    Text(st?.title ?? (key.isEmpty ? "No strategy" : key)).font(.callout.weight(.semibold))
                    if recommended {
                        Text("Recommended").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                if let st {
                    if !st.summary.isEmpty { Text(st.summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                    StrategyTeamDiagram(strategy: st, compact: true)
                    StrategyMiniFlow(strategy: st)
                } else {
                    Text("The session works on it as you ask, without a set way of working.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(recommended ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(recommended ? Color.accentColor.opacity(0.5) : Color.purple.opacity(0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(handler == nil)
    }
}
