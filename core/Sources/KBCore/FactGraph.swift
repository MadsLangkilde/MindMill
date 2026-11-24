import Foundation

/// Facts as a graph: where to draw each one so linked facts sit together, and which facts surround one.
public enum FactGraph {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Edge: Hashable, Sendable {
        public var a: String
        public var b: String
        public init(_ a: String, _ b: String) {
            (self.a, self.b) = a < b ? (a, b) : (b, a)
        }
    }

    /// A force layout (linked facts pull together, all facts push apart, a weak pull to the middle keeps loose ones
    /// near). The same facts and links always give the same picture. Positions are in a square about `size` across.
    public static func layout(nodes: [String], edges: [Edge], size: Double = 1000, iterations: Int = 250) -> [String: Point] {
        let ids = nodes.sorted()
        let n = ids.count
        guard n > 0 else { return [:] }
        guard n > 1 else { return [ids[0]: Point(x: 0, y: 0)] }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let links = edges.compactMap { e -> (Int, Int)? in
            guard let i = index[e.a], let j = index[e.b], i != j else { return nil }
            return (i, j)
        }
        // A golden-angle spiral, so the start is spread out and fixed.
        var px = [Double](repeating: 0, count: n), py = px
        for i in 0..<n {
            let r = size * 0.45 * sqrt(Double(i) + 0.5) / sqrt(Double(n))
            let a = Double(i) * 2.399963
            px[i] = r * cos(a)
            py[i] = r * sin(a)
        }
        let k = size / sqrt(Double(n)) * 0.6
        var temperature = size / 10
        var dx = [Double](repeating: 0, count: n), dy = dx
        for _ in 0..<iterations {
            for i in 0..<n { dx[i] = 0; dy[i] = 0 }
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var ddx = px[i] - px[j], ddy = py[i] - py[j]
                    var d2 = ddx * ddx + ddy * ddy
                    if d2 < 0.01 { ddx = 0.1; ddy = 0.1; d2 = 0.02 }
                    let f = k * k / d2
                    dx[i] += ddx * f; dy[i] += ddy * f
                    dx[j] -= ddx * f; dy[j] -= ddy * f
                }
            }
            for (i, j) in links {
                let ddx = px[i] - px[j], ddy = py[i] - py[j]
                let d = max(sqrt(ddx * ddx + ddy * ddy), 0.01)
                let f = d / k
                dx[i] -= ddx * f; dy[i] -= ddy * f
                dx[j] += ddx * f; dy[j] += ddy * f
            }
            for i in 0..<n {
                dx[i] -= px[i] * 0.02
                dy[i] -= py[i] * 0.02
                let len = max(sqrt(dx[i] * dx[i] + dy[i] * dy[i]), 0.01)
                let step = min(len, temperature)
                px[i] += dx[i] / len * step
                py[i] += dy[i] / len * step
            }
            temperature = max(temperature * 0.97, 0.5)
        }
        var out: [String: Point] = [:]
        for (i, id) in ids.enumerated() { out[id] = Point(x: px[i], y: py[i]) }
        return out
    }

    /// The fact and those within `depth` links of it.
    public static func neighbourhood(of id: String, edges: [Edge], depth: Int) -> Set<String> {
        var adjacent: [String: [String]] = [:]
        for e in edges {
            adjacent[e.a, default: []].append(e.b)
            adjacent[e.b, default: []].append(e.a)
        }
        var seen: Set<String> = [id]
        var frontier: [String] = [id]
        for _ in 0..<max(depth, 0) {
            frontier = frontier.flatMap { adjacent[$0] ?? [] }.filter { seen.insert($0).inserted }
            if frontier.isEmpty { break }
        }
        return seen
    }

    /// A stable colour slot for a tag, the same in every view and every launch.
    public static func colourSlot(_ tag: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var h: UInt64 = 1469598103934665603
        for b in tag.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Int(h % UInt64(count))
    }

    /// The smallest box around the points, for fitting the graph to the view.
    public static func bounds(_ points: some Collection<Point>) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        guard let first = points.first else { return nil }
        var b = (minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for p in points {
            b.minX = min(b.minX, p.x); b.maxX = max(b.maxX, p.x)
            b.minY = min(b.minY, p.y); b.maxY = max(b.maxY, p.y)
        }
        return b
    }
}
