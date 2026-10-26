import Foundation

// 3D 知識星雲頁（10-22 Kang：「這個圖片可以變成 3D 一點的星雲圖嗎？」——Graphify 原本的 graph.html 是 2D）。
// 頁面範本＋繪圖函式庫（three.js 0.180、3d-force-graph 1.80.1）打包在 assets/nebula/，安裝時放到 App Support/ShoWork42/nebula/，
// 不走 CDN（10-22 隊長 Chris：斷網或 CDN 改版就開不了、也少一條對外連線）。這裡只做純函式：graph.json → 頁面要的精簡資料 → 套範本。

public enum NebulaPage {
    /// 一頁最多幾顆星（再多瀏覽器會卡）
    public static let limit = 2000

    /// Graphify 的 graph.json → 星雲頁資料：依連線數取前 limit 顆（孤點不要）、只留這些星之間的邊、去重複與自己連自己
    public static func data(json: Data, limit: Int = limit) -> Data? {
        guard let g = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let nodes = g["nodes"] as? [[String: Any]] else { return nil }
        let links = (g["links"] as? [[String: Any]]) ?? (g["edges"] as? [[String: Any]]) ?? []
        func id(_ v: Any?) -> String? { (v as? String) ?? (v as? [String: Any])?["id"] as? String }
        var deg: [String: Int] = [:]
        for l in links {
            guard let a = id(l["source"]), let b = id(l["target"]), a != b else { continue }
            deg[a, default: 0] += 1; deg[b, default: 0] += 1
        }
        let kept = nodes.compactMap { n -> [String: Any]? in
            guard let i = n["id"] as? String, (deg[i] ?? 0) > 0 else { return nil }
            return n
        }
        .sorted { (deg[$0["id"] as! String] ?? 0, $1["id"] as! String) > (deg[$1["id"] as! String] ?? 0, $0["id"] as! String) }   // 連線數多的在前；同分照 id（結果固定）
        .prefix(limit)
        let keep = Set(kept.map { $0["id"] as! String })
        var seen = Set<String>(), outLinks: [[String: String]] = []
        for l in links {
            guard let a = id(l["source"]), let b = id(l["target"]), a != b, keep.contains(a), keep.contains(b) else { continue }
            let k = a < b ? "\(a)\u{1F}\(b)" : "\(b)\u{1F}\(a)"
            guard seen.insert(k).inserted else { continue }
            outLinks.append(["source": a, "target": b])
        }
        let outNodes: [[String: Any]] = kept.map { n in
            let i = n["id"] as! String
            return ["id": i, "label": (n["label"] as? String) ?? i, "file": (n["source_file"] as? String) ?? "",
                    "loc": (n["source_location"] as? String) ?? "", "c": (n["community"] as? Int) ?? 0,
                    "cn": (n["community_name"] as? String) ?? "", "deg": deg[i] ?? 0]
        }
        return try? JSONSerialization.data(withJSONObject: ["nodes": outNodes, "links": outLinks], options: [.sortedKeys])
    }

    /// 整棟大樓的星雲（10-22 Kang：「點地下室只有 ProjectB，不是應該這棟大樓相關的都要顯示嗎？」）：
    /// 每個專案平分 limit 顆星（各自取連線數最多的），id 加專案前綴避免撞名；顏色＝專案（c＝專案序號），p＝專案名。專案之間沒有連線，力導向會自然分成一團團
    public static func merge(_ projects: [(name: String, json: Data)], limit: Int = limit) -> Data? {
        let ps = projects.sorted { $0.name < $1.name }
        guard !ps.isEmpty else { return nil }
        let share = max(1, limit / ps.count)
        var nodes: [[String: Any]] = [], links: [[String: String]] = []
        for (i, p) in ps.enumerated() {
            guard let d = data(json: p.json, limit: share),
                  let g = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ns = g["nodes"] as? [[String: Any]], !ns.isEmpty else { continue }
            let pre = p.name + "\u{1F}"
            for var n in ns {
                n["id"] = pre + (n["id"] as! String); n["c"] = i; n["p"] = p.name
                nodes.append(n)
            }
            for l in (g["links"] as? [[String: String]]) ?? [] {
                links.append(["source": pre + l["source"]!, "target": pre + l["target"]!])
            }
        }
        guard !nodes.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["nodes": nodes, "links": links, "projects": ps.map(\.name)], options: [.sortedKeys])
    }

    /// 套範本：__TITLE__ 換成（跳脫過的）專案名、__DATA__ 換成資料（"</" 跳脫，不會提早結束 <script>）
    public static func html(template: String, title: String, data: Data) -> String {
        let t = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        let d = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        return template.replacingOccurrences(of: "__TITLE__", with: t).replacingOccurrences(of: "__DATA__", with: d)
    }
}
