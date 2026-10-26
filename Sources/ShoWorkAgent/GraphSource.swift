import Foundation
import ShoWorkCore

// 地下室神經網路的資料接線（10-22）：大樓上每個專案樓層 → 用 Graphify 離線抽程式碼圖譜 → 精簡合併成一張 NeuralGraph。
// 規則：
//   · 只用 `graphify extract <repo> --code-only`（本機 AST，不呼叫任何 LLM、不讀 API 金鑰；金鑰環境變數也清空才跑）
//   · 產出一律 --out 到 ~/Library/Application Support/ShoWork42/graphs/<專案>/，專案資料夾裡不留任何檔案（10-22 實測 0.9.93 不寫來源資料夾）
//   · 背景 utility QoS、單一序列佇列、一次一個 graphify、60 秒逾時；HEAD 沒變且 6 小時內跑過就不重跑
//   · 過熱／停電（HeatGate.paused）不跑；找不到 graphify 就安靜跳過，畫面維持 demo
//   · 測試視窗（BoardWindow.testMode）不跑，直接用 demo
// 掛在看板既有的刷新上（BoardModel.applyTower），不新增 timer；同一組專案 10 分鐘內不重排程。
// 10-22 Kang「點神經網路要能用它原本的功能」：extract 完接著跑 `graphify cluster-only <輸出> --no-label`（同沙盒、同佇列、60 秒逾時），
//   產出 Graphify 原本的互動圖譜 graph.html＋GRAPH_REPORT.md（一樣只落在我們的輸出資料夾）；地下室點那團 ⇒ htmlFor(project:) 找來開。
//   --no-label：不叫 LLM 幫群集命名（維持 Community N）。實測沙盒斷網照樣產出（2501 節點 1 秒）。
//   注意：graph.html 本身用 unpkg CDN 載 vis-network 畫圖（Graphify 沒有離線版；tree／callflow 也一樣要 CDN）⇒ 開的時候瀏覽器要有網路，
//   只下載公開的 JS 函式庫，圖譜資料在本機檔案裡、不會送出去。

enum GraphPaths {
    static var dir: URL { Paths.supportDir.appendingPathComponent("graphs", isDirectory: true) }
    static func out(_ project: String) -> URL { dir.appendingPathComponent(NeuralGraphBuild.safeName(project), isDirectory: true) }
    static func graph(_ project: String) -> URL { out(project).appendingPathComponent("graphify-out/graph.json") }
    static func stamp(_ project: String) -> URL { out(project).appendingPathComponent("stamp.json") }
    /// Graphify 原本的互動圖譜（cluster-only 產生）
    static func html(_ project: String) -> URL { out(project).appendingPathComponent("graphify-out/graph.html") }
    /// 3D 知識星雲頁（10-22 Kang：「3D 一點的星雲圖」）：跟 graph.html 同資料夾，函式庫用相對路徑 ../../../nebula/ 載（不連網）
    static func nebula(_ project: String) -> URL { out(project).appendingPathComponent("graphify-out/graph3d.html") }
    /// 整棟大樓的星雲（所有專案合在一頁）：放在跟各專案同樣深度的資料夾，範本裡 ../../../nebula/ 相對路徑照樣找得到函式庫
    static var building: URL { dir.appendingPathComponent("_building/graphify-out/graph3d.html") }
    static var buildingKey: URL { dir.appendingPathComponent("_building/projects.txt") }
    static var nebulaTemplate: URL { Paths.supportDir.appendingPathComponent("nebula/graph3d-template.html") }
}

@MainActor
final class GraphSource: ObservableObject {
    static let shared = GraphSource()
    @Published private(set) var graph: NeuralGraph = .demo()

    /// 同一組專案多久內不重排程
    static let throttle: TimeInterval = 600
    private var lastKey: String?
    private var lastAt: Date?
    private var lastNames: String?
    private var lastNamesAt: Date?
    private let worker = GraphWorker()
    /// 最近一次排程的專案名（點神經網路找替代圖譜時，先照這個順序找）
    private var known: [String] = []
    private var paths: [String: String] = [:]          // 專案名 → repo 路徑（點了才產生用）

    private init() {}

    /// 點地下室神經網路（10-22 Kang：「不是應該這棟大樓相關的都要顯示嗎？」）⇒ 開整棟大樓的星雲。
    /// 點到的那個專案還沒圖譜就先當場產生；其他專案用已有的 graph.json（還沒有的等背景排程補）。失敗回 nil
    func openBuilding(clicked: String, done: @escaping @MainActor ((url: URL, count: Int)?) -> Void) {
        let w = worker
        let all = known.compactMap { n in paths[n].map { GraphWorker.Project(name: n, path: $0) } }
        let me = all.first { $0.name == clicked }
        w.queue.async {
            if let me, !FileManager.default.fileExists(atPath: GraphPaths.graph(me.name).path) { _ = w.makeNow(me) }
            let r = w.building(all)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(r) } }
        }
    }

    /// 這個專案的 graph.html（還沒產生回 nil）
    func htmlURL(project: String) -> URL? {
        for u in [GraphPaths.nebula(project), GraphPaths.html(project)] where FileManager.default.fileExists(atPath: u.path) { return u }   // 先開 3D 星雲
        return nil
    }

    /// 點神經網路要開哪一份：那個專案的；沒有就大樓上任一個有的；再沒有就輸出資料夾裡任一份（資料夾名去掉雜湊尾巴當名字）。都沒有回 nil
    func htmlFor(project: String) -> (name: String, url: URL)? {
        if let u = htmlURL(project: project) { return (project, u) }
        for n in known where n != project { if let u = htmlURL(project: n) { return (n, u) } }
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(atPath: GraphPaths.dir.path))?.sorted() ?? []
        for d in dirs where !d.hasPrefix("_") {          // _building 是整棟版，不算單一專案
            let base = GraphPaths.dir.appendingPathComponent(d, isDirectory: true)
            guard let u = ["graphify-out/graph3d.html", "graphify-out/graph.html"].map({ base.appendingPathComponent($0) })
                .first(where: { fm.fileExists(atPath: $0.path) }) else { continue }
            let name = d.range(of: "-", options: .backwards).map { String(d[..<$0.lowerBound]) } ?? d
            return (name, u)
        }
        return nil
    }

    /// 看板每次刷新叫（便宜）：專案名單 10 分鐘內沒變就直接回；變了才去找各專案的 git 根目錄
    func consider(tower: TowerPlan, cards: [BoardCard]) {
        guard !BoardWindow.testMode else { return }
        let names = tower.projectFloors.compactMap(\.project).sorted()
        guard !names.isEmpty else { return }
        let key = names.joined(separator: "\n"), now = Date()
        if key == lastNames, let t = lastNamesAt, now.timeIntervalSince(t) < Self.throttle { return }
        lastNames = key; lastNamesAt = now
        var list: [(name: String, path: String)] = []
        for n in names {
            let mine = cards.filter { $0.project.caseInsensitiveCompare(n) == .orderedSame && !$0.id.contains("#") }
            if let root = TowerDecor.root(n, cards: mine) { list.append((n, root)) }   // root() 只回有 .git 的資料夾
        }
        refresh(projects: list)
    }

    /// 排一次背景重建：跑需要更新的 graphify、讀所有專案的 graph.json、合成一張。同一組專案 10 分鐘內不重排程
    func refresh(projects: [(name: String, path: String)]) {
        guard !BoardWindow.testMode else { return }
        var seen = Set<String>()
        let list = projects
            .filter { !$0.path.isEmpty && seen.insert($0.name.lowercased()).inserted }
            .sorted { $0.name < $1.name }
            .map { GraphWorker.Project(name: $0.name, path: $0.path) }
        guard !list.isEmpty else { return }
        known = list.map(\.name)
        for p in list { paths[p.name] = p.path }
        let key = list.map { "\($0.name)=\($0.path)" }.joined(separator: "\n"), now = Date()
        if key == lastKey, let t = lastAt, now.timeIntervalSince(t) < Self.throttle { return }
        lastKey = key; lastAt = now
        let w = worker
        w.queue.async {
            guard let g = w.build(list) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { GraphSource.shared.publish(g) } }
        }
    }

    private func publish(_ g: NeuralGraph) {
        guard !g.isEmpty else { return }
        // builtAt 不同但內容一樣就不發布（畫面不用重建）
        var a = g, b = graph
        a.builtAt = nil; b.builtAt = nil
        guard a != b else { return }
        graph = g
        Log.note("GRAPH 地下室圖譜更新：\(Set(g.nodes.map(\.project)).count) 個專案、\(g.nodes.count) 節點、\(g.edges.count) 邊")
    }
}

/// 背景工作：只在自己的序列佇列上跑（狀態只在佇列上碰，所以標 @unchecked Sendable）
final class GraphWorker: @unchecked Sendable {
    struct Project: Sendable { var name: String; var path: String }
    let queue = DispatchQueue(label: "showork.graph", qos: .utility)
    static let timeout: TimeInterval = 60
    /// 跑失敗的：同一個 HEAD 6 小時內不再試（不然每 10 分鐘撞一次）
    private var failed: [String: NeuralGraphBuild.Stamp] = [:]
    /// cluster-only 失敗的：6 小時內不再試
    private var vizFailed: [String: Date] = [:]
    /// 沙盒：允許一切、只禁網路（10-22 隊長 Chris 審查）
    static let sandbox = "(version 1)(allow default)(deny network*)"
    /// 跑 graphify 前清空的金鑰環境變數（就算 graphify 想叫 LLM 也拿不到金鑰）
    static let noKeys = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "MOONSHOT_API_KEY", "KIMI_API_KEY",
                         "DEEPSEEK_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_BASE_URL"].reduce(into: [String: String]()) { $0[$1] = "" }

    static func graphify() -> String? {
        let h = BoardPaths.home
        return [h + "/.local/bin/graphify", "/opt/homebrew/bin/graphify", "/usr/local/bin/graphify"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 佇列上呼叫：必要時跑 graphify，再把所有專案的 graph.json 合成一張。沒有 graphify 或一個能讀的都沒有就回 nil
    /// 點了才產生：沒 graph.json 先 extract，再 cluster-only；不看過熱（使用者按的、幾秒而已）
    func makeNow(_ p: Project) -> Bool {
        guard let exe = Self.graphify() else { return false }
        let fm = FileManager.default
        if !fm.fileExists(atPath: GraphPaths.graph(p.name).path) { run(exe, p, head: Self.head(p.path), now: Date()) }
        guard fm.fileExists(atPath: GraphPaths.graph(p.name).path) else { return false }
        if !fm.fileExists(atPath: GraphPaths.html(p.name).path) { visualize(exe, p) }
        nebula(p)
        return fm.fileExists(atPath: GraphPaths.nebula(p.name).path) || fm.fileExists(atPath: GraphPaths.html(p.name).path)
    }

    func build(_ projects: [Project], heavy: Bool = true) -> NeuralGraph? {
        guard let exe = Self.graphify() else { return nil }
        let fm = FileManager.default
        for p in projects where heavy {
            if Self.paused() { Log.note("GRAPH 機器熱／停電，暫不跑 graphify"); break }
            let head = Self.head(p.path)
            let stampURL = GraphPaths.stamp(p.name)
            let last = fm.contents(atPath: stampURL.path).flatMap { try? Self.decoder.decode(NeuralGraphBuild.Stamp.self, from: $0) }
            let now = Date()
            guard NeuralGraphBuild.needsRun(head: head, last: last, hasGraph: fm.fileExists(atPath: GraphPaths.graph(p.name).path), now: now)
            else { continue }
            if let f = failed[p.name], f.head == (head ?? ""), now.timeIntervalSince(f.at) < NeuralGraphBuild.maxAge { continue }
            run(exe, p, head: head, now: now)
        }
        // 互動圖譜：graph.json 有了但 graph.html 沒有（extract 剛跑完、或舊版只跑過 extract）⇒ 補跑 cluster-only
        // 不看過熱（10-22 Kang 等太久：一直判斷機器熱、圖譜網頁一直沒產生；cluster-only 只要 1 秒左右）；停電照樣不跑
        for p in projects where fm.fileExists(atPath: GraphPaths.graph(p.name).path) && !fm.fileExists(atPath: GraphPaths.html(p.name).path) {
            if Self.blackout() { break }
            if let t = vizFailed[p.name], Date().timeIntervalSince(t) < NeuralGraphBuild.maxAge { continue }
            visualize(exe, p)
        }
        for p in projects { nebula(p) }        // 3D 星雲頁：純本機運算（不叫 graphify），graph.json 比它新才重產
        _ = building(projects)
        prune(projects)
        var clusters: [NeuralGraphBuild.Cluster] = []
        var newest: Date?
        for p in projects {
            let url = GraphPaths.graph(p.name)
            guard let d = fm.contents(atPath: url.path), let c = NeuralGraphBuild.slim(json: d, project: p.name), !c.nodes.isEmpty else { continue }
            clusters.append(c)
            if let m = FileStat.lstat(url.path)?.date, newest.map({ m > $0 }) ?? true { newest = m }
        }
        guard !clusters.isEmpty else { return nil }
        return NeuralGraphBuild.merge(clusters, builtAt: newest)
    }

    private func run(_ exe: String, _ p: Project, head: String?, now: Date) {
        let out = GraphPaths.out(p.name)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // cwd 也設在輸出資料夾：就算工具有相對路徑的暫存，也只會落在我們自己的資料夾
        let t0 = Date()
        // 包在「禁止網路」的沙盒裡跑（10-22 隊長 Chris 審查：確保程式碼不會對外送；code-only 模式實測斷網照樣跑完）
        let r = Tools.run("/usr/bin/sandbox-exec", ["-p", Self.sandbox,
                                                    exe, "extract", p.path, "--code-only", "--max-workers", "2", "--out", out.path],
                          cwd: out.path, env: Self.noKeys, timeout: Self.timeout, qos: .utility)
        let ok = r.code == 0 && FileManager.default.fileExists(atPath: GraphPaths.graph(p.name).path)
        let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
        if ok {
            failed[p.name] = nil
            // 舊的互動圖譜已過期：刪掉，build() 後段會用新的 graph.json 重產
            try? FileManager.default.removeItem(at: GraphPaths.html(p.name))
            vizFailed[p.name] = nil
            if let d = try? Self.encoder.encode(NeuralGraphBuild.Stamp(head: head ?? "", at: now)) {
                try? d.write(to: GraphPaths.stamp(p.name), options: .atomic)
            }
            Log.note("GRAPH graphify \(p.name) 完成 \(secs)s")
        } else {
            failed[p.name] = NeuralGraphBuild.Stamp(head: head ?? "", at: now)
            Log.note("GRAPH graphify \(p.name) 失敗 code=\(r.code) \(secs)s \(r.err.suffix(200).replacingOccurrences(of: "\n", with: " "))")
        }
    }

    /// 產生 Graphify 原本的互動圖譜：對我們的輸出資料夾跑 cluster-only（讀 graphify-out/graph.json、寫 graph.html＋GRAPH_REPORT.md；
    /// 也會重寫 graph.json，格式不變）。--no-label 不叫 LLM；同一個禁網路沙盒、同樣清空金鑰、60 秒逾時
    private func visualize(_ exe: String, _ p: Project) {
        let out = GraphPaths.out(p.name)
        let t0 = Date()
        let r = Tools.run("/usr/bin/sandbox-exec", ["-p", Self.sandbox, exe, "cluster-only", out.path, "--no-label"],
                          cwd: out.path, env: Self.noKeys, timeout: Self.timeout, qos: .utility)
        let ok = r.code == 0 && FileManager.default.fileExists(atPath: GraphPaths.html(p.name).path)
        let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
        if ok { vizFailed[p.name] = nil; Log.note("GRAPH 互動圖譜 \(p.name) 完成 \(secs)s") }
        else {
            vizFailed[p.name] = Date()
            Log.note("GRAPH 互動圖譜 \(p.name) 失敗 code=\(r.code) \(secs)s \(r.err.suffix(200).replacingOccurrences(of: "\n", with: " "))")
        }
    }

    /// 產生 3D 知識星雲頁 graph3d.html：graph.json 精簡成前 2000 顆星、套 App Support/ShoWork42/nebula/ 的範本。
    /// 沒有範本（還沒重新安裝）就跳過；graph3d.html 比 graph.json 新就不重做
    func nebula(_ p: Project) {
        let fm = FileManager.default, src = GraphPaths.graph(p.name), dst = GraphPaths.nebula(p.name)
        guard let tpl = try? String(contentsOf: GraphPaths.nebulaTemplate, encoding: .utf8), fm.fileExists(atPath: src.path) else { return }
        if let a = FileStat.lstat(dst.path)?.date, let b = FileStat.lstat(src.path)?.date, a >= b { return }
        guard let json = fm.contents(atPath: src.path), let d = NebulaPage.data(json: json) else { return }
        do {
            try NebulaPage.html(template: tpl, title: p.name, data: d).write(to: dst, atomically: true, encoding: .utf8)
            Log.note("GRAPH 3D 星雲頁 \(p.name) 完成")
        } catch { Log.note("GRAPH 3D 星雲頁 \(p.name) 寫入失敗 \(error)") }
    }

    /// 整棟大樓星雲頁：有 graph.json 的專案合成一頁。專案名單沒變、而且每份 graph.json 都比頁面舊就不重做。回 (頁面, 專案數)
    func building(_ projects: [Project]) -> (url: URL, count: Int)? {
        let fm = FileManager.default, dst = GraphPaths.building
        let have = projects.filter { fm.fileExists(atPath: GraphPaths.graph($0.name).path) }.sorted { $0.name < $1.name }
        guard !have.isEmpty, let tpl = try? String(contentsOf: GraphPaths.nebulaTemplate, encoding: .utf8) else {
            return fm.fileExists(atPath: dst.path) ? (dst, 0) : nil
        }
        let key = have.map(\.name).joined(separator: "\n")
        let old = try? String(contentsOf: GraphPaths.buildingKey, encoding: .utf8)
        if old == key, let a = FileStat.lstat(dst.path)?.date,
           have.allSatisfy({ (FileStat.lstat(GraphPaths.graph($0.name).path)?.date).map { $0 <= a } ?? true }) { return (dst, have.count) }
        let src = have.compactMap { p in fm.contents(atPath: GraphPaths.graph(p.name).path).map { (name: p.name, json: $0) } }
        guard let d = NebulaPage.merge(src) else { return nil }
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try NebulaPage.html(template: tpl, title: "整棟大樓", data: d).write(to: dst, atomically: true, encoding: .utf8)
            try key.write(to: GraphPaths.buildingKey, atomically: true, encoding: .utf8)
            Log.note("GRAPH 整棟大樓星雲頁完成：\(have.count) 個專案")
            return (dst, have.count)
        } catch { Log.note("GRAPH 整棟大樓星雲頁寫入失敗 \(error)"); return nil }
    }

    /// 大小上限（GraphPrune）：不在大樓上超過 14 天、或總量超過 300 MB 時最舊的專案輸出丟垃圾桶（不 rm，丟錯了還撿得回來）
    func prune(_ projects: [Project]) {
        let fm = FileManager.default, root = GraphPaths.dir
        let active = Set(projects.map { NeuralGraphBuild.safeName($0.name) })
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }
        let dirs: [GraphPrune.Dir] = names.map { n in
            let u = root.appendingPathComponent(n, isDirectory: true)
            var bytes: Int64 = 0
            if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let f as URL in e { bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            }
            let m = FileStat.lstat(u.appendingPathComponent("graphify-out/graph.json").path)?.date ?? FileStat.lstat(u.path)?.date ?? Date()
            return GraphPrune.Dir(name: n, bytes: bytes, modified: m, active: active.contains(n))
        }
        for n in GraphPrune.pick(dirs, now: Date()) {
            do { try fm.trashItem(at: root.appendingPathComponent(n, isDirectory: true), resultingItemURL: nil); Log.note("GRAPH 輸出超過上限／過期，丟垃圾桶：\(n)") }
            catch { Log.note("GRAPH 丟垃圾桶失敗 \(n) \(error)") }
        }
    }

    /// 專案目前的 HEAD（不是 git 資料夾或沒有 commit 回 nil）
    static func head(_ path: String) -> String? {
        let r = Tools.run("/usr/bin/git", ["-C", path, "rev-parse", "HEAD"], timeout: 10, qos: .utility)
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.code == 0 && !s.isEmpty ? s : nil
    }

    /// HeatGate 只在主執行緒；從背景佇列同步問一下（主執行緒從不等這個佇列，不會互卡）
    static func blackout() -> Bool {
        DispatchQueue.main.sync { MainActor.assumeIsolated { HeatGate.shared.blackout } }
    }
    static func paused() -> Bool {
        DispatchQueue.main.sync { MainActor.assumeIsolated { HeatGate.shared.paused } }
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
