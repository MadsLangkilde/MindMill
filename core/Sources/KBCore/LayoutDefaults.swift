import Foundation

/// Where a movable panel sits in a session: docked into the layout, never over the content.
public enum PanelDock: String, CaseIterable, Sendable {
    case top, bottomLeading, bottomTrailing

    public static let standard = PanelDock.bottomTrailing

    public var title: String {
        switch self {
        case .top: return "Top"
        case .bottomLeading: return "Above the Input, Left"
        case .bottomTrailing: return "Above the Input, Right"
        }
    }

    /// Where a panel dropped at `point` in a view of `size` goes: the upper half is the top, the lower half the
    /// side above the input it is nearer.
    public static func drop(at point: CGPoint, in size: CGSize) -> PanelDock {
        if point.y < size.height / 2 { return .top }
        return point.x < size.width / 2 ? .bottomLeading : .bottomTrailing
    }

    public static func key(_ panel: String) -> String { "layout.\(panel)" }
}

/// The layout the app remembers per screen (column widths, orders, folded sections, panel places), and putting it
/// back to how it came.
public enum LayoutReset {
    public enum Screen: String, CaseIterable, Sendable {
        case plan, build, meeting

        public var title: String { rawValue.capitalized }
    }

    public static func keys(_ screen: Screen) -> [String] {
        switch screen {
        case .plan:
            return ["sidebarWorkOrder", "sidebarPlanningOrder", "kbSplitViewFrames.plan", "decisionsTimeline",
                    "relatedPBIsExpanded"]
        case .build:
            return ["buildMyWorkOnRight", "buildMyWorkWidth", "buildCollapsedScopes", "buildCollapsedLeads",
                    "kbSplitViewFrames.build", "myWorkTab", PanelDock.key("waitingPanel.overseer"),
                    PanelDock.key("waitingPanel.lead")]
        case .meeting:
            return ["meetingTranscriptShown", "meetingMaterialsExpanded"]
        }
    }

    /// Removes the screens' remembered layout. `current` is the mode on screen now: its split view's live frames
    /// go too, so it comes back at the standard widths.
    public static func reset(_ screens: [Screen], current: Screen?, defaults: UserDefaults = .standard) {
        for screen in screens {
            for key in keys(screen) { defaults.removeObject(forKey: key) }
        }
        if let current, screens.contains(current) { defaults.removeObject(forKey: SplitViewMemory.sharedKey) }
        if screens.count == Screen.allCases.count { defaults.removeObject(forKey: "NSWindow Frame main") }
    }
}

/// What waits on the user, counted once so every badge agrees.
public struct WaitingTally: Equatable, Sendable {
    public var buildSessions: Int
    public var overseer: Bool
    public var factoryQuestions: Int
    public var planSessions: Int

    public init(buildSessions: Int, overseer: Bool, factoryQuestions: Int, planSessions: Int) {
        self.buildSessions = buildSessions
        self.overseer = overseer
        self.factoryQuestions = factoryQuestions
        self.planSessions = planSessions
    }

    /// What the overview session lists for the user: sessions in Build and Plan and factory questions. Its own
    /// question shows in its conversation, not in this count.
    public var overview: Int { buildSessions + factoryQuestions + planSessions }
    /// Build's toolbar badge: everything in Build, the overview session's own question included.
    public var build: Int { buildSessions + (overseer ? 1 : 0) + factoryQuestions }
}
