import Foundation
import Testing
@testable import KBCore

struct FactGraphTests {
    private func distance(_ a: FactGraph.Point?, _ b: FactGraph.Point?) -> Double {
        guard let a, let b else { return .infinity }
        return hypot(a.x - b.x, a.y - b.y)
    }

    @Test func sameInputSamePicture() {
        let nodes = (0..<20).map { "f\($0)" }
        let edges = [FactGraph.Edge("f1", "f2"), FactGraph.Edge("f3", "f2")]
        #expect(FactGraph.layout(nodes: nodes, edges: edges) == FactGraph.layout(nodes: nodes.reversed(), edges: edges))
    }

    @Test func linkedFactsSitCloserThanUnlinkedOnes() {
        let nodes = (0..<30).map { "f\($0)" }
        let edges = [FactGraph.Edge("f0", "f1"), FactGraph.Edge("f1", "f2"), FactGraph.Edge("f10", "f11")]
        let p = FactGraph.layout(nodes: nodes, edges: edges)
        let linked = distance(p["f0"], p["f1"])
        let others = nodes.dropFirst(3).map { distance(p["f0"], p[$0]) }
        #expect(linked < others.reduce(0, +) / Double(others.count))
        #expect(p.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test func neighbourhoodFollowsLinksToTheDepth() {
        let edges = [FactGraph.Edge("a", "b"), FactGraph.Edge("b", "c"), FactGraph.Edge("c", "d")]
        #expect(FactGraph.neighbourhood(of: "b", edges: edges, depth: 1) == ["a", "b", "c"])
        #expect(FactGraph.neighbourhood(of: "a", edges: edges, depth: 2) == ["a", "b", "c"])
        #expect(FactGraph.neighbourhood(of: "x", edges: edges, depth: 2) == ["x"])
    }

    @Test func edgesIgnoreDirectionAndColoursAreStable() {
        #expect(FactGraph.Edge("b", "a") == FactGraph.Edge("a", "b"))
        #expect(FactGraph.colourSlot("auth", count: 8) == FactGraph.colourSlot("auth", count: 8))
        #expect((0..<8).contains(FactGraph.colourSlot("bff", count: 8)))
    }
}
