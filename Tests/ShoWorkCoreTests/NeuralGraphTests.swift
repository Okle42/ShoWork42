import Foundation
import Testing
@testable import ShoWorkCore

// 10-22 地下室神經網路：graph.json 精簡、多專案合併、座標正規化、可重現

@Suite("NeuralGraph")
struct NeuralGraphTests {
    /// 手寫的小 graph.json：度數 A=6、B=6、C=5（含自環 2）、Engine=4、D=3、Lonely=1；Foundation（模組）、SwiftUI（框架名）、String（空 source_file）要被濾掉
    static let json = Data(#"""
    {"directed": true, "nodes": [
      {"id": "hub", "label": "Engine", "community": 1, "source_file": "Sources/Engine.swift"},
      {"id": "a", "label": "A", "community": 1, "source_file": "Sources/A.swift"},
      {"id": "b", "label": "B", "community": 2, "source_file": "Sources/B.swift"},
      {"id": "c", "label": "C", "community": 2, "source_file": "Sources/C.swift"},
      {"id": "d", "label": "D", "community": 3, "source_file": "Sources/D.swift"},
      {"id": "lonely", "label": "Lonely", "community": 4, "source_file": "Sources/L.swift"},
      {"id": "foundation", "label": "Foundation", "community": 9, "source_file": "Sources/A.swift", "type": "module"},
      {"id": "swiftui", "label": "SwiftUI", "community": 9, "source_file": "Sources/B.swift"},
      {"id": "x_string", "label": "String", "community": 9, "source_file": ""}
    ], "links": [
      {"source": "hub", "target": "a", "relation": "calls"},
      {"source": "hub", "target": "b", "relation": "calls"},
      {"source": "hub", "target": "c", "relation": "calls"},
      {"source": "hub", "target": "d", "relation": "calls"},
      {"source": "a", "target": "b", "relation": "calls"},
      {"source": "b", "target": "a", "relation": "references"},
      {"source": "c", "target": "c", "relation": "calls"},
      {"source": "a", "target": "foundation", "relation": "imports"},
      {"source": "b", "target": "foundation", "relation": "imports"},
      {"source": "c", "target": "foundation", "relation": "imports"},
      {"source": "d", "target": "foundation", "relation": "imports"},
      {"source": "a", "target": "swiftui", "relation": "imports"},
      {"source": "b", "target": "swiftui", "relation": "imports"},
      {"source": "a", "target": "x_string", "relation": "references"},
      {"source": "b", "target": "x_string", "relation": "references"},
      {"source": "c", "target": "x_string", "relation": "references"},
      {"source": "d", "target": "x_string", "relation": "references"},
      {"source": "lonely", "target": "x_string", "relation": "references"}
    ]}
    """#.utf8)

    @Test("精簡：濾掉框架名／模組／空 source_file，照連線數取前 N，只留兩端都在的邊（去重、無自環）")
    func slim() throws {
        let c = try #require(NeuralGraphBuild.slim(json: Self.json, project: "P", keep: 4, maxEdges: 120))
        let labels = c.nodes.map(\.label)
        #expect(labels.count == 4)
        #expect(!labels.contains("Foundation") && !labels.contains("SwiftUI") && !labels.contains("String"))
        #expect(labels == ["A", "B", "C", "Engine"])            // 度數高到低；A、B 同分照 id
        #expect(!labels.contains("Lonely") && !labels.contains("D"))   // 度數低，被前 N 擠掉
        #expect(c.nodes.allSatisfy { $0.project == "P" && $0.id.hasPrefix("P#") && $0.file != nil })
        #expect(c.nodes.map(\.degree) == [6, 6, 5, 4])           // 原圖總度數（含連到被濾掉節點的線）
        // 邊：兩端都在、a<b、不重複、沒有自環
        var keys = Set<String>()
        for e in c.edges {
            #expect(e.a < e.b && e.b < c.nodes.count)
            #expect(keys.insert("\(e.a)-\(e.b)").inserted)
        }
        let byLabel = Dictionary(uniqueKeysWithValues: c.nodes.enumerated().map { ($1.label, $0) })
        let hasAB = c.edges.contains { Set([$0.a, $0.b]) == Set([byLabel["A"]!, byLabel["B"]!]) }
        #expect(hasAB)
        #expect(c.edges.count == 4)                             // hub-a、hub-b、hub-c、a-b（d 被擠掉；c 自環不算；a↔b 只算一條）
    }

    @Test("精簡：邊數上限、壞 JSON 回 nil")
    func limits() {
        let c = NeuralGraphBuild.slim(json: Self.json, project: "P", keep: 40, maxEdges: 2)
        #expect(c?.edges.count == 2)
        #expect(c?.nodes.count == 6)
        #expect(NeuralGraphBuild.slim(json: Data("not json".utf8), project: "P") == nil)
    }

    @Test("合併多專案：各團一個中心、專案之間串一條、整張半徑 ≤ 1")
    func merge() throws {
        let cs = try ["P", "Q", "R"].map { try #require(NeuralGraphBuild.slim(json: Self.json, project: $0)) }
        let g = NeuralGraphBuild.merge(cs)
        #expect(g.nodes.count == cs.map(\.nodes.count).reduce(0, +))
        #expect(g.edges.count == cs.map(\.edges.count).reduce(0, +) + 2)       // 3 團串 2 條
        #expect(Set(g.nodes.map(\.project)) == ["P", "Q", "R"])
        for e in g.edges { #expect(e.a != e.b && e.a < g.nodes.count && e.b < g.nodes.count) }
        // 跨專案的邊剛好 2 條，連的是各團度數最高的（A）
        let cross = g.edges.filter { g.nodes[$0.a].project != g.nodes[$0.b].project }
        #expect(cross.count == 2)
        #expect(cross.allSatisfy { g.nodes[$0.a].label == "A" && g.nodes[$0.b].label == "A" })
        for n in g.nodes { #expect((n.x * n.x + n.y * n.y + n.z * n.z).squareRoot() <= 1 + 1e-9) }
        // 各團中心大致落在半徑 0.5 的圓上、彼此分開
        let centers = ["P", "Q", "R"].map { p -> (Double, Double) in
            let ns = g.nodes.filter { $0.project == p }
            return (ns.map(\.x).reduce(0, +) / Double(ns.count), ns.map(\.z).reduce(0, +) / Double(ns.count))
        }
        for c in centers { #expect(abs((c.0 * c.0 + c.1 * c.1).squareRoot() - 0.5) < 0.05) }
    }

    @Test("正規化：超過半徑 1 就整張縮回")
    func normalize() {
        var g = NeuralGraph(nodes: [.init(id: "a", label: "a", project: "p", x: 3, y: 0, z: 0),
                                    .init(id: "b", label: "b", project: "p", x: 0, y: -1.5, z: 0)])
        NeuralGraphBuild.normalize(&g)
        #expect(abs(g.nodes[0].x - 1) < 1e-12)
        #expect(abs(g.nodes[1].y + 0.5) < 1e-12)
    }

    @Test("同輸入兩次結果一模一樣（固定種子、固定迭代）")
    func reproducible() throws {
        let cs = try ["ShoWork42", "ProjectD"].map { try #require(NeuralGraphBuild.slim(json: Self.json, project: $0)) }
        #expect(NeuralGraphBuild.merge(cs) == NeuralGraphBuild.merge(cs))
        let single = NeuralGraphBuild.merge([cs[0]])
        let r = single.nodes.map { ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot() }.max() ?? 0
        #expect(r > 0.2 && r <= NeuralGraphBuild.clusterRadius + 1e-9)        // 只有一團：放在原點、半徑約 0.35
    }

    @Test("重跑規則：沒跑過、HEAD 變、超過 6 小時才跑；安全化資料夾名")
    func rerun() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let s = NeuralGraphBuild.Stamp(head: "abc", at: t)
        #expect(NeuralGraphBuild.needsRun(head: "abc", last: nil, hasGraph: false, now: t))
        #expect(NeuralGraphBuild.needsRun(head: "abc", last: s, hasGraph: false, now: t))
        #expect(!NeuralGraphBuild.needsRun(head: "abc", last: s, hasGraph: true, now: t.addingTimeInterval(3600)))
        #expect(NeuralGraphBuild.needsRun(head: "def", last: s, hasGraph: true, now: t.addingTimeInterval(60)))
        #expect(NeuralGraphBuild.needsRun(head: "abc", last: s, hasGraph: true, now: t.addingTimeInterval(6 * 3600 + 1)))
        let a = NeuralGraphBuild.safeName("中文專案-報價系統"), b = NeuralGraphBuild.safeName("a/../b")
        #expect(!a.contains("/") && !b.contains("/") && !b.contains(".."))
        #expect(NeuralGraphBuild.safeName("a.b") != NeuralGraphBuild.safeName("a_b"))
    }
}
