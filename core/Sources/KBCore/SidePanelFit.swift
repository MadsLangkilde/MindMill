/// How a main view and a side panel share a row: the panel keeps the width the user chose while the main view
/// still gets its minimum, and never gets narrower than its own minimum.
public enum SidePanelFit {
    public static func widths(available: Double, divider: Double, preferred: Double,
                              panelMin: Double, mainMin: Double) -> (main: Double, panel: Double) {
        let room = max(0, available - divider)
        let panel = min(room, max(panelMin, min(preferred, room - mainMin)))
        return (room - panel, panel)
    }
}
