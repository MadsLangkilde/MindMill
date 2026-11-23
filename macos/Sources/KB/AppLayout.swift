import KBCore

extension AppModel {
    /// Puts the screens' columns, sidebar order, folded sections and panel places back the way KB comes.
    func resetLayout(_ screens: [LayoutReset.Screen]) {
        LayoutReset.reset(screens, current: mode == .build ? .build : .plan)
        layoutGeneration += 1
        let names = screens.count == LayoutReset.Screen.allCases.count ? "every screen" : screens.map(\.title).joined(separator: " and ")
        notice = "The layout of \(names) is back to the default."
    }
}
