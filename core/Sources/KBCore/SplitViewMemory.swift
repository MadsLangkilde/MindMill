import Foundation

/// Plan and Build are different split views in the same window, and AppKit saves both under one key. Restored
/// from the other mode's columns, a split view first lays out at the wrong widths and then jumps to its own. So
/// each mode keeps its own copy, put back under the shared key before that mode's split view appears.
public enum SplitViewMemory {
    public static let sharedKey = "NSSplitView Subview Frames main, SidebarNavigationSplitView"

    static func modeKey(_ mode: String) -> String { "kbSplitViewFrames." + mode }

    /// The sidebar keeps its width across the switch: the new mode's columns come back with the old mode's sidebar
    /// width, the column beside it giving or taking the difference.
    public static func swap(from old: String, to new: String, defaults: UserDefaults = .standard) {
        guard old != new else { return }
        let current = defaults.stringArray(forKey: sharedKey)
        if let current {
            defaults.set(current, forKey: modeKey(old))
        }
        if let saved = defaults.stringArray(forKey: modeKey(new)) {
            let width = current.flatMap(sidebarWidth)
            defaults.set(width.map { withSidebarWidth(saved, width: $0) } ?? saved, forKey: sharedKey)
        } else {
            defaults.removeObject(forKey: sharedKey)
        }
    }

    /// The width shared by both modes' sidebars, so either can be dragged to the same size.
    public static let sidebarRange: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (220, 260, 360)

    /// `x, y, width, height, collapsed, hidden` per column, as AppKit saves them.
    static func parse(_ frame: String) -> [String] {
        frame.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func sidebarWidth(_ frames: [String]) -> Double? {
        guard let first = frames.first else { return nil }
        let f = parse(first)
        guard f.count >= 4, f.count < 5 || f[4] != "YES" else { return nil }
        return Double(f[2])
    }

    static func withSidebarWidth(_ frames: [String], width: Double) -> [String] {
        guard frames.count >= 2 else { return frames }
        var first = parse(frames[0]), second = parse(frames[1])
        guard first.count >= 4, second.count >= 4, let x0 = Double(first[0]), let w0 = Double(first[2]),
              let x1 = Double(second[0]), let w1 = Double(second[2]) else { return frames }
        let gap = x1 - (x0 + w0)
        let newX1 = x0 + width + gap
        let newW1 = x1 + w1 - newX1
        guard newW1 > 50 else { return frames }
        first[2] = format(width)
        second[0] = format(newX1)
        second[2] = format(newW1)
        var out = frames
        out[0] = first.joined(separator: ", ")
        out[1] = second.joined(separator: ", ")
        return out
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
