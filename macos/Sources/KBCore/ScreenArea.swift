import CoreGraphics

/// A part of a watched window or screen, in fractions of its size (0…1, origin top left), so it stays the same
/// part when the window is resized.
public enum ScreenArea {
    /// The smallest area worth reading, as a fraction of each side.
    public static let minimumSide: CGFloat = 0.04

    /// The area between two points dragged in a view of `size`, clamped to the view; nil when it is too small.
    public static func area(from a: CGPoint, to b: CGPoint, in size: CGSize) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        let x0 = clamp(min(a.x, b.x) / size.width), x1 = clamp(max(a.x, b.x) / size.width)
        let y0 = clamp(min(a.y, b.y) / size.height), y1 = clamp(max(a.y, b.y) / size.height)
        guard x1 - x0 >= minimumSide, y1 - y0 >= minimumSide else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The area in pixels of an image `width` × `height`, rounded to whole pixels and kept inside it.
    public static func pixels(_ area: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        let x = (area.minX * w).rounded(.down), y = (area.minY * h).rounded(.down)
        let r = CGRect(x: x, y: y, width: (area.maxX * w).rounded(.up) - x, height: (area.maxY * h).rounded(.up) - y)
        return r.intersection(CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// The area in a view of `size`, for drawing it.
    public static func rect(_ area: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: area.minX * size.width, y: area.minY * size.height, width: area.width * size.width, height: area.height * size.height)
    }
}
