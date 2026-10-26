import Foundation
import Testing
@testable import ShoWorkCore

// 科技大樓資料層（10-20 第 2 棒）：固定樓層號、升降樓與 2 小時緩衝、閒置薄層分組、主題快取與重新裝潢節流、閒晃決策可重現

private func dep(_ n: String, _ active: Bool, resident: Bool = true) -> OfficeDepartment {
    OfficeDepartment(name: n, isResident: resident, isActive: active)
}

private func card(_ id: String, _ project: String, _ col: BoardColumn = .active, reason: String = "工作中") -> BoardCard {
    BoardCard(id: id, column: col, reason: reason, project: project, title: "t", lastActivity: nil, pid: 1, sessionId: id)
}

@Suite("Tower")
struct TowerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("固定樓層號：第一次依 7 天用量排名；之後新專案接在尾端、不重排既有；沒有新專案就不算用量")
    func numbering() {
        var r = TowerRegistry()
        var calls = 0
        let u1 = ["b": 50.0, "c": 10, "a": 10]
        r.assign(["A", "B", "C"], usage: { calls += 1; return u1 }, now: t0)
        #expect(r.number("b") == 2 && r.number("a") == 3 && r.number("C") == 4)   // a、c 一樣多 ⇒ 照名稱
        #expect(r.rankedAt == t0 && calls == 1)
        // 用量大翻轉也不重排；新專案 D、E 接在後面（新的之間照用量）
        let changed = r.assign(["A", "B", "C", "E", "D"], usage: { calls += 1; return ["a": 999, "d": 1, "e": 5] }, now: t0)
        #expect(changed && calls == 2)
        #expect(r.number("b") == 2 && r.number("a") == 3 && r.number("c") == 4 && r.number("e") == 5 && r.number("d") == 6)
        // 沒有新專案：不叫 usage、回傳 false
        #expect(!r.assign(["a", "B"], usage: { calls += 1; return [:] }, now: t0) && calls == 2)
        // 存檔再讀回來號碼一樣
        let back = TowerRegistry.decode(r.encoded()!)!
        #expect(back.numbers == r.numbers && back.names["e"] == "E")
    }

    @Test("升降樓：有 AI 就上樓；全部關掉後 2 小時內留著（緩衝），滿 2 小時降回薄層；別人開關不影響樓層號")
    func upDown() {
        var reg = TowerRegistry()
        let deps0 = [dep("A", true), dep("B", true), dep("C", false)]
        let u = { ["a": 3.0, "b": 2, "c": 1] }
        var (p, dirty) = TowerPlan.build(departments: deps0, cards: [card("s1", "A"), card("s2", "B"), card("s3", "B")],
                                         registry: &reg, usage: u, now: t0)
        #expect(dirty)
        #expect(p.floors.map(\.id) == ["lobby", "idle-0", "p:a", "p:b", "roof"])
        #expect(p.floor(project: "B")?.seats == 2 && p.floor(project: "a")?.floorNo == "02")
        // 同樣狀態再算一次：名冊不髒（不會每次刷新都寫檔）
        (_, dirty) = TowerPlan.build(departments: deps0, cards: [], registry: &reg, usage: u, now: t0.addingTimeInterval(30))
        #expect(!dirty)
        // A 全部關掉：1 小時 59 分還在（緩衝中、燈暗著），B 照樣在 03
        let deps1 = [dep("A", false), dep("B", true), dep("C", false)]
        let tLeave = t0.addingTimeInterval(60)
        (p, dirty) = TowerPlan.build(departments: deps1, cards: [], registry: &reg, usage: u, now: tLeave)
        #expect(dirty && reg.lastSeen["a"] == tLeave)
        (p, _) = TowerPlan.build(departments: deps1, cards: [], registry: &reg, usage: u, now: tLeave.addingTimeInterval(7140))
        #expect(p.floor(project: "A")?.active == false && p.floor(project: "B")?.floorNo == "03")
        #expect(reg.nextDemotion(now: tLeave.addingTimeInterval(7140)) == tLeave.addingTimeInterval(7200))
        // 滿 2 小時：A 降到薄層
        (p, _) = TowerPlan.build(departments: deps1, cards: [], registry: &reg, usage: u, now: tLeave.addingTimeInterval(7201))
        #expect(p.floor(project: "A") == nil && p.idlePlates.map(\.name) == ["A", "C"])
        #expect(p.idlePlates.first?.floorNo == "02")
        // A 又有人：回到原本的 02，排在 B（03）下面
        (p, _) = TowerPlan.build(departments: [dep("A", true), dep("B", true), dep("C", false)], cards: [], registry: &reg, usage: u,
                                 now: tLeave.addingTimeInterval(9000))
        #expect(p.projectFloors.map(\.floorNo) == ["02", "03"])
    }

    @Test("臨時部門（不在常駐名冊）AI 關掉後一樣留 2 小時（燈暗著）才消失；不進薄層")
    func tempLinger() {
        var reg = TowerRegistry()
        let u = { ["a": 3.0, "t": 1] }
        var (p, _) = TowerPlan.build(departments: [dep("A", false), dep("T", true, resident: false)], cards: [card("s1", "T")],
                                     registry: &reg, usage: u, now: t0)
        #expect(p.floor(project: "T")?.active == true && p.floor(project: "T")?.floorNo == "03")
        // T 的 AI 關掉：OfficeDepartments 不再列出 T，但 2 小時內樓層還在、號碼不變、燈暗著
        let tLeave = t0.addingTimeInterval(60)
        (p, _) = TowerPlan.build(departments: [dep("A", false)], cards: [], registry: &reg, usage: u, now: tLeave)
        #expect(p.floor(project: "T")?.active == false && p.floor(project: "T")?.floorNo == "03")
        (p, _) = TowerPlan.build(departments: [dep("A", false)], cards: [], registry: &reg, usage: u, now: tLeave.addingTimeInterval(7100))
        #expect(p.floor(project: "T") != nil)
        // 滿 2 小時：消失，也不在薄層
        (p, _) = TowerPlan.build(departments: [dep("A", false)], cards: [], registry: &reg, usage: u, now: tLeave.addingTimeInterval(7201))
        #expect(p.floor(project: "T") == nil && !p.idlePlates.contains { $0.name == "T" })
    }

    @Test("重開 app：上次存檔時有人、這次沒人 ⇒ 從現在起算 2 小時緩衝")
    func restart() {
        var reg = TowerRegistry()
        _ = TowerPlan.build(departments: [dep("A", true)], cards: [], registry: &reg, usage: { [:] }, now: t0)
        var back = TowerRegistry.decode(reg.encoded()!)!
        let later = t0.addingTimeInterval(86400)
        let (p, dirty) = TowerPlan.build(departments: [dep("A", false)], cards: [], registry: &back, usage: { [:] }, now: later)
        #expect(dirty && p.floor(project: "A") != nil && abs(back.lastSeen["a"]!.timeIntervalSince(later)) < 1)
    }

    @Test("閒置薄層：10-20 UI/UX 優化起只留 1 層（高 0.9），全部閒置專案都在這層；高度由下往上疊；門牌記得上次的識別色")
    func idleLayers() {
        var reg = TowerRegistry()
        let names = (1...30).map { String(format: "P%02d", $0) }
        let deps = names.map { dep($0, $0 == "P05") }
        let (p, _) = TowerPlan.build(departments: deps, cards: [], registry: &reg, usage: { [:] }, accents: ["p02": "#5B8DB8"], now: t0)
        let idle = p.floors.filter { $0.kind == .idle }
        #expect(idle.count == 1 && idle[0].plates.count == 29)                       // 29 個閒置全部在同一層（名字在索引列）
        #expect(idle[0].plates.first?.name == "P01" && idle[0].plates[1].accent == "#5B8DB8")
        #expect(!p.idlePlates.contains { $0.name == "P05" })
        // 高度：大廳 4.4（10-22 挑高）＋薄層 0.9＋專案 2.9＋頂樓 2.4
        #expect(zip(p.floors.map(\.y), [0, 4.4, 5.3, 8.2]).allSatisfy { abs($0 - $1) < 1e-9 } && p.floors.count == 4)
        #expect(abs(p.totalHeight - 10.6) < 1e-9)
        // 沒有閒置的就沒有薄層
        var r2 = TowerRegistry()
        let (q, _) = TowerPlan.build(departments: [dep("A", true)], cards: [], registry: &r2, usage: { [:] }, now: t0)
        #expect(q.floors.map(\.kind) == [.lobby, .project, .roof])
        #expect(TowerPlan.idleLayers((1...9).map { IdlePlate(name: "\($0)", floorNo: "") }).map(\.count) == [8, 1])
    }

    @Test("搬家清單：新上樓、降樓的才算；下面多一層而被推上去的不算")
    func moves() {
        var reg = TowerRegistry()
        let u = { ["a": 3.0, "b": 2, "c": 1] }
        let (p1, _) = TowerPlan.build(departments: [dep("A", false), dep("B", true), dep("C", true)], cards: [], registry: &reg, usage: u, now: t0)
        let (p2, _) = TowerPlan.build(departments: [dep("A", true), dep("B", true), dep("C", true)], cards: [], registry: &reg, usage: u, now: t0)
        let m = TowerPlan.moves(from: p1, to: p2)
        #expect(m.map(\.floorId) == ["p:a"] && m[0].fromIndex == nil && m[0].toIndex == 1)
        #expect(TowerPlan.moves(from: p2, to: p2).isEmpty)
    }

    @Test("7 天用量：只算 7 天內改過的 jsonl；slug 取最長前綴（worktree 有自己的部門就歸它）")
    func usage() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)").path
        func file(_ dir: String, _ name: String, bytes: Int, age: TimeInterval) throws {
            try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
            let p = root + "/" + dir + "/" + name
            try Data(count: bytes).write(to: URL(fileURLWithPath: p))
            try fm.setAttributes([.modificationDate: t0.addingTimeInterval(-age)], ofItemAtPath: p)
        }
        try file("-r-ProjectA", "a.jsonl", bytes: 1_048_576, age: 3600)
        try file("-r-ProjectA", "old.jsonl", bytes: 5_000_000, age: 8 * 86400)
        try file("-r-ProjectA-w1", "b.jsonl", bytes: 2_097_152, age: 3600)
        try file("-r-ProjectA-sub", "c.jsonl", bytes: 1_048_576, age: 60)       // ProjectA 底下的子資料夾啟動
        let u = ProjectUsage.scan(projectsDir: root, projects: ["ProjectA": ["/r/ProjectA"], "ProjectA-w1": ["/r/ProjectA-w1"]], now: t0)
        #expect(u["projecta"] == 2.0 && u["projecta-w1"] == 2.0)
    }
}

@Suite("TowerTheme")
struct TowerThemeTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("本地評分：英文照詞、中文照子字串；.md 多算研究；全部沒命中＝general")
    func signature() {
        let s = WorkSignature.make(DecorInput(project: "ProjectA", prompts: ["把平面圖的給排水接上", "DXF 匯入"],
                                              paths: ["/x/ProjectA/plans/a.dxf", "/x/ProjectA/b.dxf"], commands: ["python3"]))
        #expect(s.best.theme == .drafting_room)
        #expect(s.extensions["dxf"] == 2 && s.folders["plans"] == 1)
        #expect(WorkSignature.make(DecorInput(project: "zzz")).best.theme == .general)
        // fan 是詞，不會被 fancy 命中
        #expect(WorkSignature.make(DecorInput(project: "x", notes: ["fancy"])).scores[.monitor] == nil)
        let lib = WorkSignature.make(DecorInput(project: "x", paths: ["a.md", "b.md", "c.md", "d.swift"]))
        #expect(lib.scores[.library] == 1)
        #expect(WorkSignature.jaccard(["a": 2, "b": 1], ["a": 1, "c": 1]) == 0.25)
        #expect(WorkSignature.jaccard([:], [:]) == 1)
    }

    @Test("transcript 線索：你的指示、檔案路徑、指令第一個字（cd／變數略過）；子 agent 與系統通知不算")
    func extract() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"幫我做 3D 列印外殼"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<task-notification>x</task-notification>"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"1","name":"Edit","input":{"file_path":"/p/case.stl"}},{"type":"tool_use","id":"2","name":"Bash","input":{"command":"cd /p && FOO=1 swift build | tee x.log"}}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"3","name":"Read","input":{"file_path":"/side.md"}}]}}"#,
        ].joined(separator: "\n")
        let x = DecorInput.extract(tail: Data(lines.utf8))
        #expect(x.prompts == ["幫我做 3D 列印外殼"] && x.paths == ["/p/case.stl"] && x.commands == ["swift", "tee"])
        #expect(DecorInput.commandWords("/opt/homebrew/bin/ffmpeg -i a.mov") == ["ffmpeg"])
    }

    @Test("解析 AI 回答：容忍圍欄、主題不認得＝nil、識別色不在 16 色＝主題預設、props 只留合法的並補到 2 件")
    func parse() {
        let sig = WorkSignature()
        let ok = DecorPrompt.parse("```json\n{\"theme\":\"print_shop\",\"accentColor\":\"#c98b3c\",\"props\":[\"workbench\",\"workbench\",\"sofa\",\"rocket\",\"bench\"],\"reason\":\"最近都在改 STL\"}\n```",
                                   signature: sig, model: "haiku", cost: 0.002, now: t0)
        #expect(ok?.theme == .print_shop && ok?.accentColor == "#C98B3C" && ok?.props == ["workbench", "sofa", "bench"] && ok?.source == "ai")
        let fill = DecorPrompt.parse(##"{"theme":"monitor","accentColor":"#FF0000","props":["rocket"],"reason":"x"}"##, signature: sig, model: "haiku", cost: nil, now: t0)
        #expect(fill?.accentColor == "#5B8DB8" && fill?.props == ["console", "server_rack"])
        #expect(DecorPrompt.parse(##"{"theme":"spaceship","accentColor":"#5B8DB8","props":[]}"##, signature: sig, model: "haiku", cost: nil, now: t0) == nil)
        #expect(DecorPrompt.parse("我不知道", signature: sig, model: "haiku", cost: nil, now: t0) == nil)
        // 提示詞含主題庫全部 16 種、16 色，長度在範圍內
        let p = DecorPrompt.make(DecorInput(project: "X", prompts: ["做 App"], readme: "說明"), signature: sig, current: nil)
        #expect(TowerTheme.allCases.allSatisfy { p.contains($0.rawValue + "｜") } && p.contains("#6E8A6A") && p.count < 3500)
    }

    @Test("重新裝潢的判斷：第一次問、被擋就本地；一輪沒結束不動；6 小時內不換；分數與 Jaccard 門檻；你按的跳過門檻")
    func policy() {
        func sig(_ terms: [String: Int], _ scores: [TowerTheme: Int]) -> WorkSignature { var s = WorkSignature(); s.terms = terms; s.scores = scores; return s }
        let cached = FloorDecor(theme: .app_studio, accentColor: "#4E9C8F", props: [], reason: "", source: "ai", decidedAt: t0,
                                signature: ["swift": 10, "xcode": 4], scores: ["app_studio": 14])
        let later = t0.addingTimeInterval(7 * 3600)
        let changed = sig(["stl": 9, "fusion": 4], [.print_shop: 13, .app_studio: 1])
        #expect(DecorPolicy.decide(cached: nil, signature: changed, turnEnded: false, blocked: nil, force: false, now: later) == .ask("第一次"))
        #expect(DecorPolicy.decide(cached: nil, signature: changed, turnEnded: false, blocked: "上限", force: false, now: later) == .local)
        #expect(DecorPolicy.decide(cached: cached, signature: changed, turnEnded: false, blocked: nil, force: false, now: later) == .keep("不是一輪結束"))
        if case .ask = DecorPolicy.decide(cached: cached, signature: changed, turnEnded: true, blocked: nil, force: false, now: later) {} else { Issue.record("應該問") }
        #expect(DecorPolicy.decide(cached: cached, signature: changed, turnEnded: true, blocked: nil, force: false, now: t0.addingTimeInterval(3600))
                == .keep("換裝後 6 小時內不再換"))
        // 新主題分數不到舊的 2 倍
        if case .keep = DecorPolicy.decide(cached: cached, signature: sig(["stl": 9], [.print_shop: 5, .app_studio: 4]), turnEnded: true, blocked: nil, force: false, now: later) {} else { Issue.record("差距不夠應該不動") }
        // 主題換了但詞彙幾乎一樣（Jaccard ≥ 0.5）
        if case .keep = DecorPolicy.decide(cached: cached, signature: sig(["swift": 10, "xcode": 4], [.print_shop: 6]), turnEnded: true, blocked: nil, force: false, now: later) {} else { Issue.record("內容沒變應該不動") }
        #expect(DecorPolicy.decide(cached: cached, signature: WorkSignature(), turnEnded: false, blocked: nil, force: true, now: t0) == .ask("重新裝潢"))
        #expect(DecorPolicy.decide(cached: cached, signature: WorkSignature(), turnEnded: false, blocked: "上限", force: true, now: t0) == .keep("上限"))
    }

    @Test("頻率／成本上限：24 小時 8 次、US$0.10、同專案 6 小時、失敗後 1 小時、同時一個")
    func limits() {
        var l = DecorLedger()
        #expect(DecorPolicy.blocked(project: "A", ledger: l, running: false, enabled: true, force: false, now: t0) == nil)
        #expect(DecorPolicy.blocked(project: "A", ledger: l, running: true, enabled: true, force: false, now: t0) != nil)
        #expect(DecorPolicy.blocked(project: "A", ledger: l, running: false, enabled: false, force: false, now: t0) != nil)
        l.calls = (0..<8).map { .init(at: t0.addingTimeInterval(Double(-$0) * 3600), project: "p\($0)", cost: 0.001, ok: true) }
        #expect(DecorPolicy.blocked(project: "A", ledger: l, running: false, enabled: true, force: true, now: t0)?.contains("8 次") == true)
        #expect(DecorPolicy.blocked(project: "A", ledger: l, running: false, enabled: true, force: false, now: t0.addingTimeInterval(86400)) == nil)
        var c = DecorLedger(); c.calls = [.init(at: t0, project: "x", cost: 0.06, ok: true), .init(at: t0, project: "y", cost: 0.05, ok: true)]
        #expect(DecorPolicy.blocked(project: "A", ledger: c, running: false, enabled: true, force: false, now: t0)?.contains("成本") == true)
        var m = DecorLedger(); m.calls = [.init(at: t0, project: "A", cost: 0.001, ok: true)]
        #expect(DecorPolicy.blocked(project: "a", ledger: m, running: false, enabled: true, force: false, now: t0.addingTimeInterval(3600))?.contains("6 小時") == true)
        #expect(DecorPolicy.blocked(project: "a", ledger: m, running: false, enabled: true, force: true, now: t0.addingTimeInterval(3600)) == nil)
        var f = DecorLedger(); f.calls = [.init(at: t0, project: "A", cost: nil, ok: false)]
        #expect(DecorPolicy.blocked(project: "A", ledger: f, running: false, enabled: true, force: true, now: t0.addingTimeInterval(1800))?.contains("失敗") == true)
        #expect(DecorPolicy.blocked(project: "A", ledger: f, running: false, enabled: true, force: false, now: t0.addingTimeInterval(3700)) == nil)
    }
}


/// 可以撥的時鐘
final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

/// 假 runner：照順序回答，記錄被叫幾次
final class FakeRunner: @unchecked Sendable {
    private let lock = NSLock()
    var replies: [(Int32, String)]
    private(set) var calls = 0
    private(set) var prompts: [String] = []
    init(_ r: [(Int32, String)]) { replies = r }
    func run(_ p: String) -> (code: Int32, out: String, err: String) {
        lock.lock(); defer { lock.unlock() }
        calls += 1; prompts.append(p)
        let r = replies.isEmpty ? (0, "") : replies.removeFirst()
        return (r.0, r.1, r.0 == 0 ? "" : "timeout")
    }
    static func ok(_ theme: String, cost: Double = 0.002) -> (Int32, String) {
        let inner = ##"{\"theme\":\"\##(theme)\",\"accentColor\":\"#C98B3C\",\"props\":[\"workbench\",\"filament_rack\"],\"reason\":\"測試\"}"##
        return (0, ##"{"type":"result","is_error":false,"result":"\##(inner)","total_cost_usd":\##(cost)}"##)
    }
}

@Suite("ThemePicker", .serialized)
struct ThemePickerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func picker(_ r: FakeRunner, _ clock: Clock, limits: DecorLimits = DecorLimits()) -> (ThemePicker, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picker-\(UUID().uuidString)")
        return (ThemePicker(dir: dir, limits: limits, clock: { clock.now }, runner: { r.run($0) }), dir)
    }

    /// 跑一次 consider 並等它結束；回傳 (有沒有排工作, 結果)
    @discardableResult
    func run(_ p: ThemePicker, _ project: String, turnEnded: Bool = false, force: Bool = false, input: DecorInput? = nil) -> (Bool, DecorDecision?) {
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        let inp = input ?? DecorInput(project: project, paths: ["/a/case.stl", "/a/b.3mf"], commands: ["blender"])
        let ok = p.consider(project, turnEnded: turnEnded, enabled: true, force: force, input: { inp },
                            finished: { d in box.set(d); sem.signal() })
        if ok { sem.wait() }
        return (ok, box.get())
    }

    @Test("第一次：先寫本地結果、再問 AI 寫回；快取寫在 themes/<專案>.json，之後不是一輪結束就不再叫 runner")
    func firstAndCache() throws {
        let r = FakeRunner([FakeRunner.ok("print_shop")]), clock = Clock(t0)
        let (p, dir) = picker(r, clock)
        let (ok, d) = run(p, "ProjectA")
        #expect(ok && d == .ask("第一次") && r.calls == 1)
        #expect(p.cached("projecta")?.source == "ai" && p.cached("ProjectA")?.theme == .print_shop && p.cached("ProjectA")?.costUSD == 0.002)
        #expect(r.prompts[0].contains("【專案】ProjectA") && r.prompts[0].contains(".stl ×1"))
        // 從磁碟讀回（新的 picker）
        let p2 = ThemePicker(dir: dir, clock: { clock.now }, runner: { r.run($0) })
        #expect(p2.cached("ProjectA")?.theme == .print_shop && p2.ledgerSnapshot.calls.count == 1)
        // 不是一輪結束：連背景工作都不排
        #expect(!p2.mayChange("ProjectA", turnEnded: false, enabled: true))
        #expect(run(p2, "ProjectA").0 == false && r.calls == 1)
        // 一輪結束但 6 小時內：也不排
        #expect(!p2.mayChange("ProjectA", turnEnded: true, enabled: true))
    }

    @Test("AI 回壞 JSON／逾時：快取留本地結果、記失敗、1 小時內不再試；之後再試成功")
    func failures() {
        let r = FakeRunner([(0, #"{"result":"不是 JSON","total_cost_usd":0.001}"#), (143, ""), FakeRunner.ok("hw_lab")]), clock = Clock(t0)
        let (p, _) = picker(r, clock)
        let (_, d) = run(p, "A")
        if case .keep(let why) = d! { #expect(why.hasPrefix("AI 失敗")) } else { Issue.record("應該失敗") }
        #expect(p.cached("A")?.source == "local" && p.cached("A")?.theme == .print_shop)     // 本地：stl／3mf／blender
        #expect(p.ledgerSnapshot.calls.last?.ok == false)
        // 30 分鐘後：退避中，不排工作
        clock.advance(1800)
        #expect(!p.mayChange("A", turnEnded: true, enabled: true) && run(p, "A").0 == false && r.calls == 1)
        // 1 小時後：再試（逾時）
        clock.advance(1900)
        run(p, "A")
        #expect(r.calls == 2 && p.cached("A")?.source == "local")
        clock.advance(3700)
        run(p, "A")
        #expect(r.calls == 3 && p.cached("A")?.theme == .hw_lab && p.cached("A")?.source == "ai")
    }

    @Test("節流：24 小時 8 次上限後只給本地結果；你按的重新裝潢也擋；成本到 US$0.10 一樣擋")
    func throttle() {
        let r = FakeRunner((0..<20).map { _ in FakeRunner.ok("monitor", cost: 0.001) }), clock = Clock(t0)
        let (p, _) = picker(r, clock)
        for i in 0..<10 { run(p, "P\(i)") }
        #expect(r.calls == 8)
        #expect(p.cached("P9")?.source == "local" && p.cached("P7")?.source == "ai")
        #expect(run(p, "P0", force: true).0 == false && r.calls == 8)
        #expect(!p.mayChange("P0", turnEnded: true, enabled: true, force: true))
        // 成本上限
        let r2 = FakeRunner((0..<5).map { _ in FakeRunner.ok("monitor", cost: 0.06) })
        let (p2, _) = picker(r2, clock)
        run(p2, "X"); run(p2, "Y"); run(p2, "Z")
        #expect(r2.calls == 2 && p2.cached("Z")?.source == "local")
    }

    @Test("重新裝潢：工作內容明顯變了＋一輪結束＋超過 6 小時才問；你按的跳過門檻")
    func redecorate() {
        let r = FakeRunner([FakeRunner.ok("app_studio"), FakeRunner.ok("print_shop"), FakeRunner.ok("hw_lab")]), clock = Clock(t0)
        let (p, _) = picker(r, clock)
        let app = DecorInput(project: "N", paths: ["/n/A.swift", "/n/B.swift"], commands: ["xcodebuild", "xcodebuild", "swift"])
        run(p, "N", input: app)
        #expect(p.cached("N")?.theme == .app_studio && r.calls == 1)
        clock.advance(7 * 3600)
        // 同樣的工作：不問
        let (_, same) = run(p, "N", turnEnded: true, input: app)
        if case .keep = same! {} else { Issue.record("內容沒變不該問") }
        #expect(r.calls == 1)
        // 改做 3D 列印：問
        let cad = DecorInput(project: "N", prompts: ["改外殼 STL"], paths: ["/n/case.stl", "/n/lid.stl", "/n/a.3mf"], commands: ["blender"])
        run(p, "N", turnEnded: true, input: cad)
        #expect(r.calls == 2 && p.cached("N")?.theme == .print_shop)
        #expect(r.prompts[1].contains("【目前主題】app_studio"))
        // 剛換過：你按「重新裝潢」還是可以（跳過 6 小時）
        run(p, "N", force: true, input: cad)
        #expect(r.calls == 3 && p.cached("N")?.theme == .hw_lab)
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock(); private var v: DecorDecision?
    func set(_ d: DecorDecision) { lock.lock(); v = d; lock.unlock() }
    func get() -> DecorDecision? { lock.lock(); defer { lock.unlock() }; return v }
}

@Suite("Wander")
struct WanderTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func tower() -> TowerPlan {
        var reg = TowerRegistry()
        return TowerPlan.build(departments: [dep("A", true), dep("B", true), dep("C", true)], cards: [], registry: &reg,
                               usage: { ["a": 3, "b": 2, "c": 1] }, now: t0).plan
    }
    func person(_ sid: String, _ floor: String, _ mood: Mood, seat: Int = 0, seats: Int = 1) -> WanderPerson {
        WanderPerson(sid: sid, floor: "p:" + floor, mood: mood, seat: seat, seats: seats)
    }

    /// 找第一個會有人出發的時間（亂數由 session id＋15 秒時段決定，可重現）
    func firstDeparture(_ people: [WanderPerson], _ t: TowerPlan) -> (Date, WanderPlan)? {
        for k in 0..<2000 {
            let now = t0.addingTimeInterval(Double(k) * 15)
            let w = WanderPlanner.plan(people: people, tower: t, previous: [:], now: now)
            if !w.started.isEmpty { return (now, w) }
        }
        return nil
    }

    @Test("可重現：同樣的人、同一個 15 秒時段，算幾次都一樣；每次最多出發 1 人")
    func reproducible() throws {
        let t = tower()
        let people = (0..<6).map { person("s\($0)", ["a", "b", "c"][$0 % 3], .finished, seat: $0 / 3, seats: 2) }
        let (now, w) = try #require(firstDeparture(people, t))
        #expect(w.started.count == 1)
        // 同一個時段（15 秒內）再算：同一個人、同一條路線（出發時間是「現在」，不比）
        let again = WanderPlanner.plan(people: people, tower: t, previous: [:], now: now.addingTimeInterval(10))
        #expect(again.started.map(\.sid) == w.started.map(\.sid) && again.started.map(\.nodes) == w.started.map(\.nodes)
                && again.started.map(\.dest) == w.started.map(\.dest))
        #expect(WanderPlanner.plan(people: people, tower: t, previous: [:], now: now) == w)
        let trip = w.started[0]
        #expect(trip.final == .desk && trip.nodes.contains { $0.move == .wait })
        // 回到座位：最後一個點＝起點
        #expect(trip.nodes.first!.x == trip.nodes.last!.x && trip.nodes.first!.z == trip.nodes.last!.z)
        if case .visit(let f, let host) = trip.dest {
            #expect(f != people.first { $0.sid == trip.sid }!.floor && people.contains { $0.sid == host && $0.floor == f })
        }
    }

    @Test("狀態優先：等你回答的一定在桌前（路上的直接拉回）；休息的上頂樓；從頂樓變工作搭溜滑梯回座位")
    func moodFirst() throws {
        let t = tower()
        // 休息 → 頂樓（電梯）
        let idle = WanderPlanner.plan(people: [person("x", "a", .idle)], tower: t, previous: ["x": WanderState(spot: .desk)], now: t0)
        let up = try #require(idle.started.first)
        // 晴天：每個人固定偏好頂樓、一樓咖啡館或 B1（10-22）
        #expect((up.final == .roof(slot: 0) && up.nodes.last?.floor == "roof") || (up.final == .cafe(slot: 0) && up.nodes.last?.floor == "lobby")
                || (up.final == .b1(slot: 0) && up.nodes.last?.floor == "b1"))
        #expect(up.nodes.contains { $0.move == .elevator })
        // 等你回答：在頂樓或路上都直接回桌前（不播）
        let wait = WanderPlanner.plan(people: [person("x", "a", .waiting)], tower: t, previous: idle.states, now: t0.addingTimeInterval(1))
        #expect(wait.states["x"] == WanderState(spot: .desk) && wait.snapped == ["x"] && wait.started.isEmpty)
        // 在頂樓（行程走完了）變成工作中：溜滑梯回來
        let atRoof = ["x": WanderState(spot: .roof(slot: 3))]
        let back = WanderPlanner.plan(people: [person("x", "b", .working)], tower: t, previous: atRoof, now: t0)
        let down = try #require(back.started.first)
        #expect(down.nodes.contains { $0.move == .slide } && down.nodes.last?.floor == "p:b" && back.states["x"]?.spot == .desk)
        // 新來就在休息的：直接放頂樓（不播）
        let fresh = WanderPlanner.plan(people: [person("y", "a", .idle), person("z", "a", .idle)], tower: t, previous: [:], now: t0)
        #expect(fresh.started.isEmpty && fresh.states.values.allSatisfy { $0.spot.isRoof || $0.spot.isIndoorRest } && Set(fresh.states.values.map(\.spot)).count == 2)
    }

    @Test("下雨：休息的去室內（一樓咖啡館或 B1）、頂樓的搭電梯下來；咖啡館變工作搭電梯回座位")
    func rain() throws {
        let t = tower()
        let people = (0..<6).map { person("r\($0)", "a", .idle, seat: $0, seats: 6) }
        let fresh = WanderPlanner.plan(people: people, tower: t, previous: [:], now: t0, rain: true)
        // 10-22：下雨不上頂樓，室內兩處（咖啡館、B1）都可以
        #expect(fresh.states.values.allSatisfy { $0.spot.isIndoorRest } && Set(fresh.states.values.map(\.spot)).count == 6)
        // 晴天在頂樓的，下雨了：下到他偏好的室內點（x 偏好咖啡館；B1 的情況另外在 b1RainDown 測）
        let x = try sid("x", sunny: .roof(slot: -1), rainy: .cafe(slot: -1))
        let wet = WanderPlanner.plan(people: [person(x, "a", .idle)], tower: t, previous: [x: WanderState(spot: .roof(slot: 2))], now: t0, rain: true)
        let down = try #require(wet.started.first)
        #expect(down.final == .cafe(slot: 0) && down.nodes.first?.floor == "roof" && down.nodes.last?.floor == "lobby" && down.nodes.contains { $0.move == .elevator })
        // 雨停了：已經在咖啡館的不會又跑上頂樓
        let dry = WanderPlanner.plan(people: [person("x", "a", .idle)], tower: t, previous: ["x": WanderState(spot: .cafe(slot: 0))], now: t0)
        #expect(dry.started.isEmpty && dry.states["x"]?.spot == .cafe(slot: 0))
        // 咖啡館 → 工作：電梯回自己樓層的座位
        let back = WanderPlanner.plan(people: [person("x", "b", .working)], tower: t, previous: ["x": WanderState(spot: .cafe(slot: 1))], now: t0)
        let up = try #require(back.started.first)
        #expect(up.nodes.first?.floor == "lobby" && up.nodes.last?.floor == "p:b" && up.nodes.contains { $0.move == .elevator } && back.states["x"]?.spot == .desk)
    }

    @Test("同時最多 3 人在路上：多的直接瞬移；視窗看不到 ⇒ 不出發、路上的落地；off 模式全部落地")
    func limits() {
        let t = tower()
        let people = (0..<5).map { person("i\($0)", "a", .idle, seat: $0, seats: 5) }
        let prev = Dictionary(uniqueKeysWithValues: people.map { ($0.sid, WanderState(spot: .desk)) })
        let w = WanderPlanner.plan(people: people, tower: t, previous: prev, now: t0)
        #expect(w.started.count == 3 && w.snapped.count == 2 && w.movingCount == 3)
        #expect(Set(w.states.values.map(\.spot)).count == 5)                 // 每人一個頂樓站位
        // 同層一起出發：錯開 2.5 秒（不然三個人走同一條走道疊成一團；10-20 第 4 棒）
        #expect(w.started.map { $0.start.timeIntervalSince(t0) }.sorted() == [0, WanderPlanner.stagger, 2 * WanderPlanner.stagger])
        let hidden = WanderPlanner.plan(people: people, tower: t, previous: w.states, now: t0.addingTimeInterval(2), visible: false)
        #expect(hidden.started.isEmpty && hidden.movingCount == 0 && hidden.snapped.count == 3)
        let off = WanderPlanner.plan(people: people, tower: t, previous: prev, now: t0, mode: .off)
        #expect(off.started.isEmpty && off.movingCount == 0)
        // 走完了：下一次刷新清掉行程、留在頂樓
        let later = WanderPlanner.plan(people: people, tower: t, previous: w.states, now: t0.addingTimeInterval(600))
        #expect(later.movingCount == 0 && later.states.values.allSatisfy { $0.spot.isRoof || $0.spot.isIndoorRest })
    }

    @Test("拜訪只去有人在座位上的樓層；單程超過 20 秒電梯那段改瞬移；行程中途位置插值")
    func visitAndCap() throws {
        let t = tower()
        // 別層沒人在座位（都在休息）⇒ 只會去茶水角
        let people = [person("v", "a", .finished), person("h", "b", .idle)]
        let (_, w) = try #require(firstDeparture(people, t))
        if case .lounge = w.started[0].dest {} else { Issue.record("沒有可拜訪的人應該去茶水角") }
        // 高樓：電梯那段 > 12 秒（20 層 ≈ 30 秒）⇒ 瞬移；3 層樓的照常搭
        var reg = TowerRegistry()
        let tall = TowerPlan.build(departments: (0..<20).map { dep("F\($0)", true) }, cards: [], registry: &reg, usage: { [:] }, now: t0).plan
        let nodes = WanderPlanner.toRoof(WanderPerson(sid: "q", floor: "p:f0", mood: .idle, seat: 0, seats: 1), slot: 0, tower: tall)
        #expect(nodes.contains { $0.move == .teleport } && !nodes.contains { $0.move == .elevator } && nodes.last!.t <= 20)
        // 插值：走道上一半的位置
        let trip = WanderTrip(sid: "q", start: t0, nodes: [WanderNode(floor: "p:a", x: 0, z: 0, move: .start, t: 0),
                                                            WanderNode(floor: "p:a", x: 2, z: 0, move: .walk, t: 2)], dest: .desk, final: .desk)
        #expect(trip.position(at: 1).x == 1 && trip.position(at: 9).x == 2)
        // 座位（10-22 自由座、先分散）：第 1 個人前組 (−0.7, −0.3) 面向鏡頭 ⇒ z −0.3−0.72；第 2 個人坐後段 (−1.5, −4.3) ⇒ z −4.3−0.72；
        // 第 5 個人併到前組對面 (−0.7, 0.4) 背對 ⇒ z 0.4＋0.72
        #expect(abs(TowerLayout.seat(0, of: 1).x - (-0.7)) < 1e-9 && abs(TowerLayout.seat(0, of: 1).z - (-0.3 - 0.72)) < 1e-9
                && abs(TowerLayout.seat(1, of: 2).z - (-4.3 - 0.72)) < 1e-9
                && abs(TowerLayout.seat(4, of: 5).z - (0.4 + 0.72)) < 1e-9)
    }

    /// 每部車所有移動（絕對時間）照開始排好
    func carSpans(_ trips: [WanderTrip]) -> [Int: [(from: String, to: String, s: Date, e: Date)]] {
        var out: [Int: [(from: String, to: String, s: Date, e: Date)]] = [:]
        for t in trips { for m in t.carMoves { out[m.car, default: []].append((m.from, m.to, t.start.addingTimeInterval(m.start), t.start.addingTimeInterval(m.end))) } }
        return out.mapValues { $0.sorted { $0.s < $1.s } }
    }

    @Test("兩部電梯（10-22 Kang）：同時出發用不同部、第三個人在門口等；同一部車不重疊；空車先開去接人")
    func twoElevators() throws {
        let t = tower()
        let people = (0..<3).map { person("e\($0)", "a", .idle, seat: $0, seats: 3) }
        let prev = Dictionary(uniqueKeysWithValues: people.map { ($0.sid, WanderState(spot: .desk)) })
        let w = WanderPlanner.plan(people: people, tower: t, previous: prev, now: t0, rain: true)
        #expect(w.started.count == 3 && w.cars.count == 2)
        let trips = w.started.sorted { $0.start < $1.start }
        let carOf = trips.map { $0.nodes.first { $0.move == .elevator }?.car }
        // 前兩個人：不同部；車原本停一樓 ⇒ 第一段是空車從 lobby 開上來、第二段載人下去
        #expect(carOf[0] == 0 && carOf[1] == 1)
        for k in 0..<2 {
            let m = trips[k].carMoves
            // 下雨休息去室內：一樓咖啡館或 B1（10-22），載人那段開到這趟的終點樓層
            let dest = try #require(trips[k].nodes.last?.floor)
            #expect(dest == "lobby" || dest == "b1")
            #expect(m.count == 2 && m[0].from == "lobby" && m[0].to == "p:a" && m[1].from == "p:a" && m[1].to == dest && m[0].end <= m[1].start)
            #expect(!trips[k].nodes.contains { $0.move == .wait })      // 車比人先到門口，不用等
        }
        // 電梯門口／車廂座標換成那一部的
        let e1 = try #require(trips[1].nodes.first { $0.move == .elevator })
        #expect(e1.x == TowerLayout.elevators[1].x && e1.z == TowerLayout.elevators[1].z)
        #expect(trips[1].nodes.contains { $0.x == TowerLayout.elevatorDoors[1].x && $0.z == TowerLayout.elevatorDoors[1].z })
        // 第三個人：兩部都在忙 ⇒ 門口等，電梯段在那部車空出來之後才開始
        let third = trips[2], c = try #require(carOf[2])
        let wi = try #require(third.nodes.firstIndex { $0.move == .wait })
        #expect(TowerLayout.doorIndex(third.nodes[wi].x, third.nodes[wi].z) == c)
        let before = trips[c].carMoves.last!.end
        let ride = try #require(third.carMoves.last)
        #expect(third.start.addingTimeInterval(ride.start) >= trips[c].start.addingTimeInterval(before))
        #expect(third.carMoves.first!.from == trips[c].nodes.last!.floor)   // 先從上一趟放人的樓層（一樓或 B1）空車開回來
        // 同一部車的移動不重疊；首尾相接（下一段從上一段的終點開始）
        for (_, spans) in carSpans(trips) {
            for (a, b) in zip(spans, spans.dropFirst()) { #expect(a.e.timeIntervalSince(b.s) <= 1e-6 && a.to == b.from) }
        }
        // 車廂狀態帶回去：停在最後放人的樓層（一樓或 B1）、有空的時間＝最後一段載人結束
        for (c, spans) in carSpans(trips) { #expect(w.cars[c].floor == spans.last!.to) }
        for (c, spans) in carSpans(trips) { #expect(abs(w.cars[c].freeAt.timeIntervalSince(spans.last!.e)) < 1e-6) }
        // 停留時間（instant 截圖）不把門口等車當成到了
        #expect(third.arriveAt == third.duration)
    }

    @Test("電梯排程：帶回上一次的車廂狀態；瞬移段不佔車；instant／看不到不排")
    func elevatorCarry() throws {
        let t = tower()
        let p = person("x", "a", .idle)
        // 兩部都在頂樓、10 秒後才有空 ⇒ 等、先從頂樓空車開下來
        let busy = [WanderCar(floor: "roof", freeAt: t0.addingTimeInterval(10)), WanderCar(floor: "roof", freeAt: t0.addingTimeInterval(10))]
        let w = WanderPlanner.plan(people: [p], tower: t, previous: ["x": WanderState(spot: .desk)], now: t0, rain: true, cars: busy)
        let trip = try #require(w.started.first)
        #expect(trip.carMoves.first?.from == "roof" && trip.carMoves.first!.start >= 10 && trip.nodes.contains { $0.move == .wait })
        #expect(trip.nodes.first { $0.move == .elevator }?.car == 0 && w.cars[1] == busy[1])
        // 沒給：兩部都停一樓
        let fresh = WanderPlanner.plan(people: [], tower: t, previous: [:], now: t0)
        #expect(fresh.cars == [WanderCar(floor: "lobby", freeAt: t0), WanderCar(floor: "lobby", freeAt: t0)])
        // 高樓（電梯段換成瞬移）：不排車
        var reg = TowerRegistry()
        let tall = TowerPlan.build(departments: (0..<20).map { dep("F\($0)", true) }, cards: [], registry: &reg, usage: { [:] }, now: t0).plan
        var cars = WanderPlanner.initialCars([], now: t0)
        let s = WanderPlanner.schedule(start: t0, cars: &cars, tower: tall) {
            WanderPlanner.toRoof(WanderPerson(sid: "q", floor: "p:f0", mood: .idle, seat: 0, seats: 1), slot: 0, tower: tall, car: $0)
        }
        #expect(s.moves.isEmpty && cars == WanderPlanner.initialCars([], now: t0) && s.nodes.contains { $0.move == .teleport })
        // instant／看不到：直接瞬移，車廂不動
        let inst = WanderPlanner.plan(people: [p], tower: t, previous: ["x": WanderState(spot: .desk)], now: t0, mode: .instant, rain: true, cars: busy)
        #expect(inst.started.isEmpty && inst.cars == busy)
        let hidden = WanderPlanner.plan(people: [p], tower: t, previous: ["x": WanderState(spot: .desk)], now: t0, visible: false, rain: true, cars: busy)
        #expect(hidden.started.isEmpty && hidden.cars.allSatisfy { $0.freeAt == t0 })
    }

    @Test("拜訪來回：回程同一部車、車在對方樓層等，放車時間＝回程電梯結束")
    func visitHoldsCar() throws {
        let t = tower()
        let p = person("v", "a", .finished), h = person("h", "b", .working)
        var cars = WanderPlanner.initialCars([], now: t0)
        let s = WanderPlanner.schedule(start: t0, cars: &cars, tower: t) { WanderPlanner.visit(p, host: h, stay: 10, tower: t, car: $0) }
        let rides = s.nodes.filter { $0.move == .elevator }
        #expect(rides.count == 2 && rides.allSatisfy { $0.car == 0 })
        // 空車上去接 → 載去 B → 載回 A（回程不用再空車）
        #expect(s.moves.map(\.from) == ["lobby", "p:a", "p:b"] && s.moves.map(\.to) == ["p:a", "p:b", "p:a"])
        #expect(cars[0].floor == "p:a" && abs(cars[0].freeAt.timeIntervalSince(t0.addingTimeInterval(s.moves.last!.end))) < 1e-6)
        #expect(cars[1] == WanderCar(floor: "lobby", freeAt: t0))
        // 停留還是對方桌旁那段
        let trip = WanderTrip(sid: "v", start: t0, nodes: s.nodes, dest: .visit(floor: "p:b", host: "h"), final: .desk)
        #expect(trip.position(at: trip.arriveAt + 1).floor == "p:b")
    }

    // MARK: 地下室 B1（10-22 Kang：員工也可以搭電梯到 B1 看神經網路）

    /// 找一個休息偏好符合條件的 session id（偏好由 sid 決定，可重現）
    func sid(_ prefix: String, sunny: WanderSpot?, rainy: WanderSpot?) throws -> String {
        for k in 0..<500 {
            let s = "\(prefix)\(k)", p = person(s, "a", .idle)
            if let sunny, WanderPlanner.restSpot(p, rain: false, roof: true, cafe: true) != sunny { continue }
            if let rainy, WanderPlanner.restSpot(p, rain: true, roof: true, cafe: true) != rainy { continue }
            return s
        }
        throw CancellationError()
    }

    @Test("休息偏好三選一（頂樓／咖啡館／B1，依 sid 固定）；下雨不上頂樓，咖啡館和 B1 都有人去")
    func restPreference() {
        let ps = (0..<90).map { person("pref\($0)", "a", .idle) }
        let sunny = ps.map { WanderPlanner.restSpot($0, rain: false, roof: true, cafe: true) }
        let rainy = ps.map { WanderPlanner.restSpot($0, rain: true, roof: true, cafe: true) }
        let roof = sunny.filter { $0?.isRoof == true }.count, cafe = sunny.filter { $0?.isCafe == true }.count, b1 = sunny.filter { $0?.isB1 == true }.count
        #expect(roof + cafe + b1 == 90 && roof >= 15 && cafe >= 15 && b1 >= 15)
        #expect(rainy.allSatisfy { $0?.isIndoorRest == true } && rainy.contains { $0?.isCafe == true } && rainy.contains { $0?.isB1 == true })
        // 偏好咖啡館／B1 的人下雨照舊；固定偏好（再算一次一樣）
        for (a, b) in zip(sunny, rainy) where a?.isIndoorRest == true { #expect(a == b) }
        #expect(ps.map { WanderPlanner.restSpot($0, rain: false, roof: true, cafe: true) } == sunny)
        // 沒有頂樓 ⇒ 室內；沒有大廳（也就沒有 B1）⇒ 頂樓；都沒有 ⇒ 不動
        #expect(ps.allSatisfy { WanderPlanner.restSpot($0, rain: false, roof: false, cafe: true)?.isIndoorRest == true })
        #expect(ps.allSatisfy { WanderPlanner.restSpot($0, rain: false, roof: true, cafe: false) == .roof(slot: -1) })
        #expect(WanderPlanner.restSpot(ps[0], rain: false, roof: false, cafe: false) == nil)
        // 下雨：整批休息的人沒有一個在頂樓
        let t = tower()
        let many = (0..<12).map { person("w\($0)", ["a", "b", "c"][$0 % 3], .idle, seat: $0 / 3, seats: 4) }
        let wet = WanderPlanner.plan(people: many, tower: t, previous: [:], now: t0, rain: true)
        #expect(wet.states.values.allSatisfy { $0.spot.isIndoorRest } && wet.states.values.contains { $0.spot.isB1 })
    }

    @Test("B1 站位：內圈 8 個圍著投影台、面向圖譜中心；16 個以內互相隔 1.7 以上、不撞機櫃和電梯門口")
    func b1Slots() {
        let c = TowerLayout.b1Center
        #expect(abs(c.z - (TowerSpec.front - TowerSpec.depth / 2)) < 1e-9 && TowerLayout.b1Y == -5.6)
        let slots = (0..<20).map(TowerLayout.b1Slot)
        #expect(TowerLayout.b1Capacity == 16)
        for (i, s) in slots.enumerated() {
            // 面向中心：(sin a, cos a) 指向圖譜
            let d = hypot(c.x - s.x, c.z - s.z)
            #expect(abs(sin(s.a) - (c.x - s.x) / d) < 1e-9 && abs(cos(s.a) - (c.z - s.z) / d) < 1e-9)
            if i < 8 { #expect(abs(d - 3.0) < 1e-9) }
            // 機房範圍：兩側機櫃 |x| ≥ 4.8、後排機櫃前緣 z −5.8、正面玻璃 z 2.8（人身寬 1.55、深 0.82）
            #expect(abs(s.x) + 0.78 <= 4.8 + 1e-9 && s.z - 0.41 >= TowerSpec.back + 1.2 - 1e-9 && s.z + 0.41 <= TowerSpec.front)
            // 電梯門口前 1.5 公尺內不站人
            for d0 in TowerLayout.elevatorDoors { #expect(hypot(s.x - d0.x, s.z - d0.z) >= 1.5) }
            // 16 個以內不擠（超過的站兩圈中間，允許擠）
            if i < TowerLayout.b1Capacity { for t in slots[..<i] { #expect(hypot(s.x - t.x, s.z - t.z) >= 1.7 - 1e-6) } }
        }
        // 繞圈走：門口空地起步、不從中間（投影台＋圖譜下方，半徑 2.2 內）直穿
        for i in 0..<20 {
            let r = TowerLayout.b1Route(i, door: TowerLayout.elevatorDoors[1])
            #expect(r.first!.x == TowerLayout.b1EntryX && r.last!.x == slots[i].x && r.last!.z == slots[i].z)
            for (a, b) in zip(r, r.dropFirst()) {
                for k in 0...10 {
                    let f = Double(k) / 10
                    #expect(hypot(a.x + (b.x - a.x) * f - c.x, a.z + (b.z - a.z) * f - c.z) > 2.2)
                }
            }
        }
    }

    @Test("去 B1：搭電梯（排車）到 \"b1\"、從電梯門口走到站位；B1 回座位搭電梯回自己樓層")
    func toAndFromB1() throws {
        let t = tower()
        let s = try sid("b", sunny: .b1(slot: -1), rainy: nil)
        let w = WanderPlanner.plan(people: [person(s, "a", .idle)], tower: t, previous: [s: WanderState(spot: .desk)], now: t0)
        let trip = try #require(w.started.first)
        #expect(trip.final == .b1(slot: 0) && w.states[s]?.spot == .b1(slot: 0))
        let last = try #require(trip.nodes.last), slot = TowerLayout.b1Slot(0)
        #expect(last.floor == "b1" && last.x == slot.x && last.z == slot.z)
        let ride = try #require(trip.nodes.first { $0.move == .elevator })
        #expect(ride.floor == "b1" && ride.car != nil)
        // 下車後先到這部電梯的門口
        let ri = trip.nodes.firstIndex { $0.move == .elevator }!
        let door = TowerLayout.elevatorDoors[ride.car!]
        #expect(trip.nodes[ri + 1].floor == "b1" && trip.nodes[ri + 1].x == door.x && trip.nodes[ri + 1].z == door.z)
        // 車廂：空車從一樓開上來接人、載到 B1；B1 那段的秒數照 B1 的高度算（不是 0）
        #expect(trip.carMoves.last?.to == "b1" && w.cars[ride.car!].floor == "b1")
        let fromY = try #require(t.floor(id: "p:a")).y
        let rideSec = trip.carMoves.last!.end - trip.carMoves.last!.start
        #expect(abs(rideSec - (fromY - TowerLayout.b1Origin) / WanderPlanner.elevatorSpeed) < 0.05)
        // 走完之後下一次刷新：留在 B1
        let later = WanderPlanner.plan(people: [person(s, "a", .idle)], tower: t, previous: w.states, now: t0.addingTimeInterval(600), cars: w.cars)
        #expect(later.started.isEmpty && later.states[s]?.spot == .b1(slot: 0))
        // B1 → 工作：電梯回自己樓層的座位（車停在 B1，直接上車）
        let back = WanderPlanner.plan(people: [person(s, "b", .working, seat: 1, seats: 2)], tower: t, previous: later.states,
                                      now: t0.addingTimeInterval(615), cars: later.cars)
        let up = try #require(back.started.first)
        let seat = TowerLayout.seat(1, of: 2, floor: "p:b")
        #expect(up.nodes.first?.floor == "b1" && up.nodes.first?.x == slot.x && up.nodes.last?.floor == "p:b"
                && up.nodes.last?.x == seat.x && up.nodes.last?.z == seat.z && back.states[s]?.spot == .desk)
        #expect(up.nodes.contains { $0.move == .elevator && $0.floor == "p:b" } && up.carMoves.contains { $0.from == "b1" && $0.to == "p:b" })
        // 做完了也一樣回座位；站位放出來給下一個人
        let done = WanderPlanner.plan(people: [person(s, "a", .finished)], tower: t, previous: [s: WanderState(spot: .b1(slot: 3))], now: t0)
        #expect(done.started.first?.nodes.last?.floor == "p:a" && done.states[s]?.spot == .desk)
        // instant：直接放到 B1 站位（不播）
        let inst = WanderPlanner.plan(people: [person(s, "a", .idle)], tower: t, previous: [s: WanderState(spot: .desk)], now: t0, mode: .instant)
        #expect(inst.started.isEmpty && inst.states[s]?.spot == .b1(slot: 0))
    }

    @Test("下雨：偏好頂樓、室內選 B1 的人從頂樓搭電梯下到 B1；B1 的人雨停不會跑上頂樓")
    func b1RainDown() throws {
        let t = tower()
        let s = try sid("r", sunny: .roof(slot: -1), rainy: .b1(slot: -1))
        let wet = WanderPlanner.plan(people: [person(s, "a", .idle)], tower: t, previous: [s: WanderState(spot: .roof(slot: 1))], now: t0, rain: true)
        let down = try #require(wet.started.first)
        #expect(down.final == .b1(slot: 0) && down.nodes.first?.floor == "roof" && down.nodes.last?.floor == "b1")
        #expect(down.nodes.contains { $0.move == .elevator && $0.floor == "b1" } && down.carMoves.last?.to == "b1")
        let dry = WanderPlanner.plan(people: [person(s, "a", .idle)], tower: t, previous: [s: WanderState(spot: .b1(slot: 0))], now: t0)
        #expect(dry.started.isEmpty && dry.states[s]?.spot == .b1(slot: 0))
        // 同時好幾個人下 B1：站位不重複
        let many = (0..<10).map { k in person("m\(k)", "a", .idle, seat: k, seats: 10) }
        let prev = Dictionary(uniqueKeysWithValues: many.map { ($0.sid, WanderState(spot: .b1(slot: -1))) })
        let w = WanderPlanner.plan(people: many, tower: t, previous: prev, now: t0)
        #expect(Set(w.states.values.map(\.spot)) == Set((0..<10).map { WanderSpot.b1(slot: $0) }))
    }
}

@Suite("HeatPolicy") struct HeatPolicyTests {
    @Test("cool42 warm 以上或系統 serious 以上算熱") func hot() {
        #expect(!HeatPolicy.hot(level: .ok, thermal: 1))
        #expect(HeatPolicy.hot(level: .warm, thermal: 0))
        #expect(HeatPolicy.hot(level: nil, thermal: 2))
        #expect(!HeatPolicy.hot(level: nil, thermal: 0))
    }
    @Test("退燒要穩定 60 秒才恢復") func debounce() {
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(HeatPolicy.paused(hotNow: true, wasPaused: false, coolSince: nil, now: t0))
        #expect(HeatPolicy.paused(hotNow: false, wasPaused: true, coolSince: t0, now: t0.addingTimeInterval(30)))
        #expect(!HeatPolicy.paused(hotNow: false, wasPaused: true, coolSince: t0, now: t0.addingTimeInterval(61)))
        #expect(!HeatPolicy.paused(hotNow: false, wasPaused: false, coolSince: nil, now: t0))
    }
    @Test("解析 cool42 state.json") func parse() {
        #expect(HeatPolicy.parseLevel(#"{"level":"hot","cpuAvg":70}"#.data(using: .utf8)) == .hot)
        #expect(HeatPolicy.parseLevel(Data("x".utf8)) == nil)
        #expect(HeatPolicy.parseLevel(nil) == nil)
    }
}
