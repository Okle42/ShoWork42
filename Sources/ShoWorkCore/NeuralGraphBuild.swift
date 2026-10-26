import Foundation

// 地下室神經網路的資料加工（10-22）：Graphify 的 graph.json → 每個專案精簡成一團 → 合成一張、排好 3D 座標。
// 全部是純函式（不碰檔案、不看時間），同輸入一定同輸出：畫面每次重排不會亂跳、測試可重現。
// graph.json 長相（Graphify 0.9.93，--code-only）：
//   nodes: [{id, label, community, source_file, type?("module"＝import 進來的框架)}]
//   links: [{source, target, relation}]
// 不準的地方：Graphify 把 String／Sendable 這類語言內建型別也當節點（source_file 是空的），框架 import 也是節點，這兩種都濾掉。

public enum NeuralGraphBuild {
    /// 每個專案留幾個節點、幾條邊（畫面上一團 40 顆球剛好看得出形狀，再多就糊成一坨）
    public static let keepNodes = 40
    public static let keepEdges = 120
    /// 團內半徑、各團中心排的圓半徑、上下錯開量
    public static let clusterRadius = 0.35
    public static let ringRadius = 0.5
    public static let ringLift = 0.08
    public static let iterations = 200

    /// 系統框架／套件的 import 名（小寫比對）：連線數很高但對「這個專案在做什麼」沒意義。
    /// String／Sendable 這類語言內建型別不用列：它們的 source_file 是空的，已經濾掉
    public static let frameworks: Set<String> = [
        "foundation", "swiftui", "scenekit", "appkit", "uikit", "testing", "xctest", "coregraphics", "coreimage",
        "corefoundation", "corevideo", "coremedia", "coreaudio", "avfoundation", "metal", "metalkit", "quartzcore",
        "combine", "dispatch", "darwin", "glibc", "simd", "os", "oslog", "observation", "cryptokit", "network",
        "webkit", "mapkit", "corelocation", "corebluetooth", "corenfc", "storekit", "spritekit", "gameplaykit",
        "realitykit", "arkit", "photos", "contacts", "eventkit", "usernotifications", "security", "localauthentication",
        "applicationservices", "carbon", "iokit", "screencapturekit", "vision", "naturallanguage", "speech",
        // 其他語言常見的
        "react", "react-dom", "next", "vue", "express", "lodash", "os.path", "sys", "json", "re", "typing",
        "pathlib", "subprocess", "collections", "datetime", "math", "numpy", "pandas",
    ]

    /// 精簡完的一團（還沒有座標）
    public struct Cluster: Sendable, Equatable {
        public var project: String
        public var nodes: [NeuralGraph.Node]
        public var edges: [NeuralGraph.Edge]     // 團內索引
        public init(project: String, nodes: [NeuralGraph.Node], edges: [NeuralGraph.Edge]) {
            self.project = project; self.nodes = nodes; self.edges = edges
        }
    }

    // MARK: 精簡

    /// graph.json → 連線數最多的前 `keep` 個節點＋它們之間的邊（最多 `maxEdges` 條）。讀不懂回 nil。
    /// 連線數算的是原圖的總度數（含連到被濾掉節點的線）；同分照 id 排，結果固定。
    public static func slim(json: Data, project: String, keep: Int = keepNodes, maxEdges: Int = keepEdges) -> Cluster? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let rawNodes = root["nodes"] as? [[String: Any]] else { return nil }
        let rawLinks = (root["links"] as? [[String: Any]]) ?? (root["edges"] as? [[String: Any]]) ?? []

        var degree: [String: Int] = [:]
        var pairs: [(String, String)] = []
        for l in rawLinks {
            guard let s = endpoint(l["source"]), let t = endpoint(l["target"]) else { continue }
            degree[s, default: 0] += 1; degree[t, default: 0] += 1
            pairs.append((s, t))
        }

        struct Raw { var id: String; var label: String; var file: String; var community: Int }
        var cands: [Raw] = []
        var seen = Set<String>()
        for n in rawNodes {
            guard let id = n["id"] as? String, !seen.contains(id) else { continue }
            let label = (n["label"] as? String) ?? id
            let file = (n["source_file"] as? String) ?? ""
            if file.isEmpty { continue }                                           // 語言內建型別、外部符號
            if (n["type"] as? String) == "module" { continue }                     // import 進來的模組
            if frameworks.contains(label.lowercased()) { continue }
            seen.insert(id)
            let comm = (n["community"] as? Int) ?? (n["community"] as? NSNumber)?.intValue ?? 0
            cands.append(Raw(id: id, label: label, file: file, community: comm))
        }
        cands.sort { a, b in
            let da = degree[a.id] ?? 0, db = degree[b.id] ?? 0
            return da != db ? da > db : a.id < b.id
        }
        let kept = Array(cands.prefix(max(0, keep)))
        var index: [String: Int] = [:]
        for (i, r) in kept.enumerated() { index[r.id] = i }
        let nodes = kept.map { r in
            NeuralGraph.Node(id: "\(project)#\(r.id)", label: r.label, project: project, file: r.file,
                             community: r.community, degree: degree[r.id] ?? 0)
        }

        // 只留兩端都在裡面的邊；無向去重、不要自己連自己；兩端度數加總高的先留
        var edgeSet = Set<Int>()
        var edges: [NeuralGraph.Edge] = []
        for (s, t) in pairs {
            guard let a = index[s], let b = index[t], a != b else { continue }
            let lo = min(a, b), hi = max(a, b)
            if edgeSet.insert(lo * 100_000 + hi).inserted { edges.append(NeuralGraph.Edge(lo, hi)) }
        }
        edges.sort { x, y in
            let wx = nodes[x.a].degree + nodes[x.b].degree, wy = nodes[y.a].degree + nodes[y.b].degree
            if wx != wy { return wx > wy }
            return x.a != y.a ? x.a < y.a : x.b < y.b
        }
        if edges.count > maxEdges { edges = Array(edges.prefix(max(0, maxEdges))) }
        return Cluster(project: project, nodes: nodes, edges: edges)
    }

    /// links 的端點：一般是字串 id；有些版本會是 {id: …} 物件
    static func endpoint(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let o = v as? [String: Any] { return o["id"] as? String }
        return nil
    }

    // MARK: 合併＋排版

    /// 多個專案合成一張：各團中心均勻排在半徑 0.5 的圓上（單數團稍微往上、雙數往下），團內力導向排成半徑約 0.35；
    /// 專案之間用各團度數最高的節點依序串一條線。最後整張縮到半徑 ≤ 1。
    public static func merge(_ clusters: [Cluster], builtAt: Date? = nil, iterations: Int = iterations) -> NeuralGraph {
        let cs = clusters.filter { !$0.nodes.isEmpty }
        var g = NeuralGraph(builtAt: builtAt)
        var hubs: [Int] = []
        for (k, c) in cs.enumerated() {
            let base = g.nodes.count
            let pos = layout(c, seed: fnv(c.project), iterations: iterations)
            let center: (Double, Double, Double)
            if cs.count == 1 {
                center = (0, 0, 0)
            } else {
                let ang = Double(k) / Double(cs.count) * 2 * .pi
                center = (ringRadius * cos(ang), k % 2 == 0 ? ringLift : -ringLift, ringRadius * sin(ang))
            }
            for (i, var n) in c.nodes.enumerated() {
                n.x = center.0 + pos[i].0; n.y = center.1 + pos[i].1; n.z = center.2 + pos[i].2
                g.nodes.append(n)
            }
            for e in c.edges { g.edges.append(NeuralGraph.Edge(base + e.a, base + e.b)) }
            // 度數最高（同分取前面的）＝這一團的代表
            var hub = 0
            for i in c.nodes.indices where c.nodes[i].degree > c.nodes[hub].degree { hub = i }
            hubs.append(base + hub)
        }
        for i in hubs.indices.dropFirst() { g.edges.append(NeuralGraph.Edge(hubs[i - 1], hubs[i])) }
        normalize(&g)
        return g
    }

    /// 整張縮到半徑 ≤ 1（只縮不放；原點不動）
    public static func normalize(_ g: inout NeuralGraph, limit: Double = 1) {
        let r = g.nodes.map { ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot() }.max() ?? 0
        guard r > limit else { return }
        let s = limit / r
        for i in g.nodes.indices { g.nodes[i].x *= s; g.nodes[i].y *= s; g.nodes[i].z *= s }
    }

    /// 團內 3D 力導向（Fruchterman–Reingold 簡化版）：固定種子、固定迭代、逐步降溫；最後縮放到最遠的點＝clusterRadius
    static func layout(_ c: Cluster, seed: UInt64, iterations: Int) -> [(Double, Double, Double)] {
        let n = c.nodes.count
        guard n > 1 else { return Array(repeating: (0, 0, 0), count: n) }
        var s = seed | 1
        func rnd() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
        var p = (0..<n).map { _ in (rnd() * 2 - 1, rnd() * 2 - 1, rnd() * 2 - 1) }
        let k = 1.0 / Double(n).squareRoot()                 // 理想間距（單位立方體內）
        var temp = 0.1
        let cool = temp / Double(max(iterations, 1))
        for _ in 0..<iterations {
            var d = Array(repeating: (0.0, 0.0, 0.0), count: n)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var dx = p[i].0 - p[j].0, dy = p[i].1 - p[j].1, dz = p[i].2 - p[j].2
                    var dist2 = dx * dx + dy * dy + dz * dz
                    if dist2 < 1e-9 { dx = 0.01 * Double(i - j); dy = 0.01; dz = 0; dist2 = dx * dx + dy * dy }
                    let dist = dist2.squareRoot()
                    let f = k * k / dist                             // 斥力
                    let ux = dx / dist * f, uy = dy / dist * f, uz = dz / dist * f
                    d[i].0 += ux; d[i].1 += uy; d[i].2 += uz
                    d[j].0 -= ux; d[j].1 -= uy; d[j].2 -= uz
                }
            }
            for e in c.edges {
                let dx = p[e.a].0 - p[e.b].0, dy = p[e.a].1 - p[e.b].1, dz = p[e.a].2 - p[e.b].2
                let dist = max((dx * dx + dy * dy + dz * dz).squareRoot(), 1e-6)
                let f = dist * dist / k                              // 引力
                let ux = dx / dist * f, uy = dy / dist * f, uz = dz / dist * f
                d[e.a].0 -= ux; d[e.a].1 -= uy; d[e.a].2 -= uz
                d[e.b].0 += ux; d[e.b].1 += uy; d[e.b].2 += uz
            }
            for i in 0..<n {
                // 往中心拉一點（沒有邊的孤點才不會飛走）
                d[i].0 -= p[i].0 * 0.5; d[i].1 -= p[i].1 * 0.5; d[i].2 -= p[i].2 * 0.5
                let len = (d[i].0 * d[i].0 + d[i].1 * d[i].1 + d[i].2 * d[i].2).squareRoot()
                guard len > 1e-12 else { continue }
                let step = min(len, temp) / len
                p[i].0 += d[i].0 * step; p[i].1 += d[i].1 * step; p[i].2 += d[i].2 * step
            }
            temp = max(temp - cool, 0.002)
        }
        // 置中＋縮放到半徑 clusterRadius
        let mx = p.map(\.0).reduce(0, +) / Double(n), my = p.map(\.1).reduce(0, +) / Double(n), mz = p.map(\.2).reduce(0, +) / Double(n)
        p = p.map { ($0.0 - mx, $0.1 - my, $0.2 - mz) }
        let r = p.map { ($0.0 * $0.0 + $0.1 * $0.1 + $0.2 * $0.2).squareRoot() }.max() ?? 0
        let sc = r > 1e-9 ? clusterRadius / r : 0
        return p.map { ($0.0 * sc, $0.1 * sc, $0.2 * sc) }
    }

    /// 固定的字串雜湊（Swift 的 hashValue 每次啟動不同，不能拿來當種子）
    public static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    // MARK: 跑 Graphify 的規則

    /// 專案名 → 資料夾名（只留英數、-、_；其他換 _；空的給 "_"）。後面接雜湊尾巴避免「a.b」「a_b」撞名
    public static func safeName(_ s: String) -> String {
        let body = String(s.unicodeScalars.map { ($0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")) ? Character($0) : "_" })
        let tail = String(fnv(s) & 0xffff, radix: 16)
        return (body.isEmpty ? "_" : String(body.prefix(60))) + "-" + tail
    }

    /// 上次跑的紀錄（存在 graphs/<名>/stamp.json）
    public struct Stamp: Codable, Sendable, Equatable {
        public var head: String
        public var at: Date
        public init(head: String, at: Date) { self.head = head; self.at = at }
    }
    public static let maxAge: TimeInterval = 6 * 3600

    /// 要不要重跑：沒跑過、沒產出、HEAD 變了、或超過 6 小時
    public static func needsRun(head: String?, last: Stamp?, hasGraph: Bool, now: Date, maxAge: TimeInterval = maxAge) -> Bool {
        guard hasGraph, let last else { return true }
        if let head, head != last.head { return true }
        return now.timeIntervalSince(last.at) > maxAge
    }
}
