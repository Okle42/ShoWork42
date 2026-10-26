import Foundation

// 地下室 B1 機房中間浮著的 3D 神經網路（10-22 Kang：參考 Graphify「整個專案變成一張知識圖譜」）。
// 資料：各專案用 Graphify（離線、只做程式碼 AST）抽出 graph.json → 精簡成每個專案最重要的幾十個節點 → 排成 3D 位置。
// 畫面只讀這個結構，不知道 Graphify 的存在；座標是「圖譜本地座標」，半徑約 1，畫面自己縮放擺到機房中間。

public struct NeuralGraph: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public var id: String
        public var label: String           // 類別／函式名
        public var project: String         // 屬於哪個專案（樓層名）
        public var file: String?           // 原始檔（相對 repo）
        public var community: Int          // Graphify 分群
        public var degree: Int             // 連線數（畫面決定大小）
        public var x: Double, y: Double, z: Double
        public init(id: String, label: String, project: String, file: String? = nil, community: Int = 0, degree: Int = 0,
                    x: Double = 0, y: Double = 0, z: Double = 0) {
            self.id = id; self.label = label; self.project = project; self.file = file
            self.community = community; self.degree = degree; self.x = x; self.y = y; self.z = z
        }
    }
    public struct Edge: Sendable, Equatable {
        public var a: Int                  // nodes 的索引
        public var b: Int
        public init(_ a: Int, _ b: Int) { self.a = a; self.b = b }
    }
    public var nodes: [Node]
    public var edges: [Edge]
    public var builtAt: Date?
    public init(nodes: [Node] = [], edges: [Edge] = [], builtAt: Date? = nil) {
        self.nodes = nodes; self.edges = edges; self.builtAt = builtAt
    }
    public var isEmpty: Bool { nodes.isEmpty }

    /// 還沒有真資料時（第一次跑 Graphify 之前、測試視窗）：固定種子的假圖，讓畫面有東西
    public static func demo(projects: [String] = ["專案A", "專案B", "專案C"], perProject: Int = 40) -> NeuralGraph {
        var g = NeuralGraph()
        var seed: UInt64 = 42
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        for (pi, p) in projects.enumerated() {
            let base = g.nodes.count
            let ang = Double(pi) / Double(max(projects.count, 1)) * 2 * .pi
            let cx = 0.45 * cos(ang), cz = 0.45 * sin(ang)
            for i in 0..<perProject {
                let u = rnd() * 2 * .pi, v = acos(2 * rnd() - 1), r = 0.15 + 0.4 * pow(rnd(), 0.6)
                g.nodes.append(Node(id: "\(p)#\(i)", label: "\(p)-\(i)", project: p, community: i % 5, degree: i < 4 ? 12 : 1 + Int(rnd() * 5),
                                    x: cx + r * sin(v) * cos(u), y: r * cos(v), z: cz + r * sin(v) * sin(u)))
                if i > 0 { g.edges.append(Edge(base + i, base + Int(rnd() * Double(min(i, 4))))) }
                if i > 6, rnd() < 0.5 { g.edges.append(Edge(base + i, base + Int(rnd() * Double(i)))) }
            }
            if pi > 0 { g.edges.append(Edge(base, base - perProject)) }
        }
        return g
    }
}
