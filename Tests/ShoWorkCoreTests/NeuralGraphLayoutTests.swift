import Foundation
import Testing
@testable import ShoWorkCore

@Suite struct NeuralGraphLayoutTests {
    @Test func fitsRadiusAndCenters() {
        let p = NeuralGraph.demo().placement(radius: 1.6)
        #expect(p.dots.count == 120)
        let far = p.dots.map { sqrt($0.x * $0.x + $0.y * $0.y + $0.z * $0.z) }.max()!
        #expect(abs(far - 1.6) < 1e-9)
        // 包圍盒中心在原點
        let xs = p.dots.map(\.x)
        #expect(abs((xs.min()! + xs.max()!) / 2) < 1e-9)
    }

    @Test func colorPerProjectAndSizeByDegree() {
        let g = NeuralGraph(nodes: [
            .init(id: "a", label: "a", project: "P", degree: 1, x: -1),
            .init(id: "b", label: "b", project: "Q", degree: 9, x: 1),
            .init(id: "c", label: "c", project: "P", degree: 0, y: 1),
        ], edges: [.init(0, 1), .init(1, 0), .init(2, 2), .init(0, 7)])
        let p = g.placement(minSize: 0.05, maxSize: 0.15)
        #expect(p.dots.map(\.color) == [0, 1, 0])
        #expect(p.projects == ["P", "Q"])
        #expect(abs(p.dots[1].size - 0.15) < 1e-9)
        #expect(abs(p.dots[2].size - 0.05) < 1e-9)
        #expect(p.dots[0].size < p.dots[1].size)
        // 重複（反向）、自己連自己、超出範圍的邊都丟掉
        #expect(p.edges == [.init(0, 1)])
    }

    @Test func capKeepsHighDegree() {
        var g = NeuralGraph()
        for i in 0..<10 { g.nodes.append(.init(id: "\(i)", label: "", project: "P", degree: i, x: Double(i))) }
        g.edges = [.init(9, 8), .init(0, 1)]
        let p = g.placement(maxNodes: 3)
        #expect(p.dots.count == 3)
        #expect(p.edges == [.init(1, 2)])        // 原 8、9 ⇒ 新 1、2；0–1 被丟掉
    }

    @Test func empty() {
        #expect(NeuralGraph().placement().dots.isEmpty)
    }
}
