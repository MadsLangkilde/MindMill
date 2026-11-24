import Foundation

/// A part of a factory's view that the user can move, resize, hide or add back.
public enum FactoryPanel: String, Codable, CaseIterable, Sendable, Identifiable {
    case board, details, history, approvals, questions, stats, rules

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .board: return "Board"
        case .details: return "Item details"
        case .history: return "History"
        case .approvals: return "To approve"
        case .questions: return "Questions for you"
        case .stats: return "Numbers"
        case .rules: return "Rules"
        }
    }

    public var icon: String {
        switch self {
        case .board: return "rectangle.split.3x1"
        case .details: return "doc.text.magnifyingglass"
        case .history: return "clock.arrow.circlepath"
        case .approvals: return "checkmark.seal"
        case .questions: return "questionmark.bubble"
        case .stats: return "number"
        case .rules: return "slider.horizontal.3"
        }
    }

    public var summary: String {
        switch self {
        case .board: return "The work items from Up next to Done."
        case .details: return "The item you click on the board: what its session does, its pull request and timeline."
        case .history: return "Everything the factory did, newest first."
        case .approvals: return "Facts and work items its sessions proposed, waiting for your yes."
        case .questions: return "Every open question with its work item, answered right here."
        case .stats: return "Places in use, questions, items in review, done and up next."
        case .rules: return "The factory's rules in short."
        }
    }
}

public struct FactoryPanelSlot: Codable, Equatable, Sendable, Identifiable {
    public var kind: FactoryPanel
    /// Full width; otherwise half, beside the next half-width panel.
    public var wide: Bool
    /// Folded to its title bar.
    public var collapsed: Bool

    public var id: String { kind.rawValue }

    public init(_ kind: FactoryPanel, wide: Bool = true, collapsed: Bool = false) {
        self.kind = kind
        self.wide = wide
        self.collapsed = collapsed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(FactoryPanel.self, forKey: .kind)
        wide = try c.decodeIfPresent(Bool.self, forKey: .wide) ?? true
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }

    enum CodingKeys: String, CodingKey { case kind, wide, collapsed }
}

/// How a factory's view is laid out: panels top to bottom, half-width ones side by side in pairs.
public struct FactoryDashboard: Codable, Equatable, Sendable {
    public var panels: [FactoryPanelSlot]

    public init(panels: [FactoryPanelSlot]) { self.panels = panels }

    public static let standard = FactoryDashboard(panels: [
        FactoryPanelSlot(.board),
        FactoryPanelSlot(.details),
        FactoryPanelSlot(.history, wide: false),
        FactoryPanelSlot(.approvals, wide: false),
    ])

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decode([FailableSlot].self, forKey: .panels))?.compactMap(\.slot) ?? Self.standard.panels
        var seen = Set<FactoryPanel>()
        panels = raw.filter { seen.insert($0.kind).inserted }
    }

    enum CodingKeys: String, CodingKey { case panels }

    /// A slot whose kind a newer app added is left out instead of failing the whole layout.
    private struct FailableSlot: Decodable {
        var slot: FactoryPanelSlot?
        init(from decoder: Decoder) throws { slot = try? FactoryPanelSlot(from: decoder) }
    }

    /// The panels not shown, to add back.
    public var hidden: [FactoryPanel] { FactoryPanel.allCases.filter { k in !panels.contains { $0.kind == k } } }

    public func contains(_ kind: FactoryPanel) -> Bool { panels.contains { $0.kind == kind } }

    /// Rows to draw: a wide panel alone, two half-width panels in a row; a half-width panel without a partner
    /// takes the row alone.
    public var rows: [[FactoryPanelSlot]] {
        var out: [[FactoryPanelSlot]] = []
        var pending: FactoryPanelSlot?
        for p in panels {
            if p.wide {
                if let h = pending { out.append([h]); pending = nil }
                out.append([p])
            } else if let h = pending {
                out.append([h, p])
                pending = nil
            } else {
                pending = p
            }
        }
        if let h = pending { out.append([h]) }
        return out
    }

    private func index(_ kind: FactoryPanel) -> Int? { panels.firstIndex { $0.kind == kind } }

    public mutating func move(_ kind: FactoryPanel, by offset: Int) {
        guard let i = index(kind) else { return }
        let j = min(max(0, i + offset), panels.count - 1)
        guard i != j else { return }
        panels.insert(panels.remove(at: i), at: j)
    }

    /// Moves a panel to where `target` is, pushing `target` down (or up, when it moves down).
    public mutating func move(_ kind: FactoryPanel, to target: FactoryPanel) {
        guard kind != target, let i = index(kind), let j = index(target) else { return }
        let p = panels.remove(at: i)
        panels.insert(p, at: j)
    }

    public mutating func setWide(_ kind: FactoryPanel, _ wide: Bool) {
        if let i = index(kind) { panels[i].wide = wide }
    }

    public mutating func setCollapsed(_ kind: FactoryPanel, _ collapsed: Bool) {
        if let i = index(kind) { panels[i].collapsed = collapsed }
    }

    public mutating func remove(_ kind: FactoryPanel) { panels.removeAll { $0.kind == kind } }

    public mutating func add(_ kind: FactoryPanel) {
        guard !contains(kind) else { return }
        panels.append(FactoryPanelSlot(kind, wide: kind == .board || kind == .details))
    }
}

/// A work item's full text, for the context of a factory question.
public struct WorkItemDetail: Codable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var state: String
    public var type: String
    public var iteration: String
    public var assignee: String
    public var tags: [String]
    public var description: String
    public var acceptance: String
    public var repro: String
    public var url: String

    public static func decode(_ text: String) throws -> WorkItemDetail {
        try JSONDecoder().decode(WorkItemDetail.self, from: Data(text.utf8))
    }
}
