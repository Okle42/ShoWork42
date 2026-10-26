import Foundation

// 地下室 B1 神經網路的擺放（純數字，可測）：圖譜本地座標 → 機房裡的位置（以圖譜中心為原點、縮到指定半徑），
// 節點大小依 degree、顏色依專案（同專案同色、照第一次出現的順序循環調色盤）。畫面（OfficeBasement.swift）只拿這份結果畫。

public struct NeuralPlacement: Sendable, Equatable {
    public struct Dot: Sendable, Equatable {
        public var x: Double, y: Double, z: Double
        public var size: Double          // 方塊邊長（公尺）
        public var color: Int            // 調色盤索引（同專案同一個）
        public var project: Int = 0      // projects 的索引（點擊時找回是哪個專案；color 會循環，不能拿來反查）
    }
    public var dots: [Dot]
    /// 有效的邊（兩端索引都在範圍內、不是自己連自己、不重複）
    public var edges: [NeuralGraph.Edge]
    public var projects: [String]        // 專案（第一次出現的順序；第 i 個用調色盤 i % palette）
}

extension NeuralGraph {
    /// 擺到半徑 `radius` 的球裡（包圍盒中心當原點；最遠的節點剛好在半徑上）。
    /// 節點大小：`minSize` 起跳、依 √degree 長大、最大 `maxSize`；`maxNodes` 以上只留 degree 高的（畫面上限）
    public func placement(radius: Double = 1.6, minSize: Double = 0.05, maxSize: Double = 0.16,
                          palette: Int = 8, maxNodes: Int = 1500) -> NeuralPlacement {
        guard !nodes.isEmpty else { return NeuralPlacement(dots: [], edges: [], projects: []) }
        // 太多就留 degree 高的（原順序不變，邊的索引跟著重編）
        var keep = Array(nodes.indices)
        if nodes.count > maxNodes {
            keep = Array(nodes.indices.sorted { nodes[$0].degree != nodes[$1].degree ? nodes[$0].degree > nodes[$1].degree : $0 < $1 }.prefix(maxNodes)).sorted()
        }
        var remap: [Int: Int] = [:]
        for (i, k) in keep.enumerated() { remap[k] = i }
        let ns = keep.map { nodes[$0] }
        let lo = (ns.map(\.x).min()!, ns.map(\.y).min()!, ns.map(\.z).min()!)
        let hi = (ns.map(\.x).max()!, ns.map(\.y).max()!, ns.map(\.z).max()!)
        let c = ((lo.0 + hi.0) / 2, (lo.1 + hi.1) / 2, (lo.2 + hi.2) / 2)
        let far = ns.map { sqrt(pow($0.x - c.0, 2) + pow($0.y - c.1, 2) + pow($0.z - c.2, 2)) }.max() ?? 0
        let k = far > 1e-9 ? radius / far : 0
        let maxDeg = Double(max(1, ns.map(\.degree).max() ?? 1))
        var projects: [String] = []
        var color: [String: Int] = [:]
        let dots = ns.map { n -> NeuralPlacement.Dot in
            let pj: Int
            if let v = color[n.project] { pj = v } else {
                pj = projects.count; color[n.project] = pj; projects.append(n.project)
            }
            let ci = pj % max(1, palette)
            let t = sqrt(Double(max(0, n.degree)) / maxDeg)
            return .init(x: (n.x - c.0) * k, y: (n.y - c.1) * k, z: (n.z - c.2) * k, size: minSize + (maxSize - minSize) * t, color: ci, project: pj)
        }
        var seen = Set<Int>()
        var es: [NeuralGraph.Edge] = []
        for e in edges {
            guard let a = remap[e.a], let b = remap[e.b], a != b else { continue }
            let key = min(a, b) * ns.count + max(a, b)
            if seen.insert(key).inserted { es.append(.init(min(a, b), max(a, b))) }
        }
        return NeuralPlacement(dots: dots, edges: es, projects: projects)
    }
}
