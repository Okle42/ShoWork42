import Foundation
import Testing
@testable import ShoWorkCore

// 10-20 第 2 棒 UI/UX 優化（docs/design/office-tower/UIUX優化規劃.md）：比例、需要你列、樓層索引列、標籤避讓、主題評分修正

private func card(_ id: String, _ project: String, _ col: BoardColumn, reason: String = "工作中", at: TimeInterval = 0) -> BoardCard {
    BoardCard(id: id, column: col, reason: reason, project: project, title: "t", lastActivity: Date(timeIntervalSince1970: 1_800_000_000 + at), pid: 1, sessionId: id)
}

@Suite("TowerHUD")
struct TowerHUDTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("比例：坐姿頭頂／層高 ≥ 0.50（ACCAI 約一半；舊版 0.37）；模組 12×9.8×2.9")
    func proportion() {
        #expect(TowerSpec.seatedHeadRatio >= 0.50)
        #expect(TowerSpec.floorHeight == 2.9 && TowerSpec.width == 12 && TowerSpec.depth == 9.8 && TowerSpec.kuboScale == 1.6)
        // 自由座（10-22）：前組四人桌面對面（0＝面向鏡頭、π＝背對）、12 張桌位置都不同；人坐在桌子後方 chairBack（順著朝向）
        // 先分散：前 4 個人一人一區（前、後、右牆、左牆），第 5 個人才併到前組對面
        #expect(TowerLayout.desk(0, of: 4).a == 0 && TowerLayout.desk(1, of: 4).z < -3 && TowerLayout.desk(2, of: 4).a == .pi / 2 && TowerLayout.desk(3, of: 4).a == -.pi / 2)
        #expect(TowerLayout.desk(4, of: 5).a == .pi && TowerLayout.desk(4, of: 5).x == TowerLayout.desk(0, of: 5).x)
        #expect(Set((0..<12).map { i in "\(TowerLayout.desk(i, of: 12).x),\(TowerLayout.desk(i, of: 12).z)" }).count == 12)
        for i in 0..<12 {
            let d = TowerLayout.desk(i, of: 12), s = TowerLayout.seat(i, of: 12)
            #expect(abs(s.x - (d.x - TowerLayout.chairBack * sin(d.a))) < 1e-9 && abs(s.z - (d.z - TowerLayout.chairBack * cos(d.a))) < 1e-9)
            #expect(s.a == d.a)
        }
        #expect(abs(TowerLayout.seat(0, of: 1).z - (-0.3 - TowerLayout.chairBack)) < 1e-9)     // 面向鏡頭：人在桌子後面（z 較小）
        #expect(abs(TowerLayout.seat(4, of: 5).z - (0.4 + TowerLayout.chairBack)) < 1e-9)      // 背對鏡頭：人在桌子前面（z 較大）
    }

    @Test("自由座：12 個座位兩兩人距 ≥ 1.0、桌子（1.4×0.7，依朝向）互不重疊、都在模組內")
    func freeSeating() {
        // 桌子的世界包圍盒：寬 1.4 沿人的左右、深 0.7 沿人的前後；朝向只有 0／π／±π/2，用 |sin a| 判斷要不要轉 90°
        func box(_ i: Int) -> (x0: Double, x1: Double, z0: Double, z1: Double) {
            let d = TowerLayout.desk(i, of: 12)
            let side = abs(sin(d.a)) > 0.5
            let hw = side ? 0.35 : 0.7, hd = side ? 0.7 : 0.35
            return (d.x - hw, d.x + hw, d.z - hd, d.z + hd)
        }
        for i in 0..<12 {
            let b = box(i), s = TowerLayout.seat(i, of: 12)
            #expect(b.x0 >= -6 && b.x1 <= 6 && b.z0 >= TD0.zB && b.z1 <= TD0.zF, "桌 \(i) 超出模組")
            #expect(s.x >= -6 && s.x <= 6 && s.z >= TD0.zB && s.z <= TD0.zF, "座位 \(i) 超出模組")
            for j in (i + 1)..<12 {
                let t = TowerLayout.seat(j, of: 12)
                #expect(hypot(s.x - t.x, s.z - t.z) >= 1.0, "座位 \(i)、\(j) 太近")
                let c = box(j)
                let overlap = b.x0 < c.x1 - 1e-9 && c.x0 < b.x1 - 1e-9 && b.z0 < c.z1 - 1e-9 && c.z0 < b.z1 - 1e-9
                #expect(!overlap, "桌 \(i)、\(j) 重疊")
            }
        }
    }

    /// 大樓模組前後緣（跟 ShoWorkAgent 的 TD.zF／TD.zB 一致；Core 測試看不到 Agent 的常數）
    enum TD0 { static let zF = 2.8, zB = -5.6 }

    @Test("需要你列：等你／卡住／做完依時間先後；人數、樓層數；排隊訊息不算；點「等你」輪流")
    func attention() {
        let cs = [card("a", "P", .review, reason: "等你回答", at: 30), card("b", "P", .review, reason: "要你決定：A？", at: 10),
                  card("c", "Q", .stuck), card("d", "Q", .review, reason: "做完了，你還沒看"), card("e", "R", .active),
                  card("f", "R", .done), card("x#1", "R", .todo)]
        let s = AttentionSummary.make(cs)
        #expect(s.waiting == ["b", "a"] && s.stuck == ["c"] && s.finished == ["d"] && s.working == 1)
        #expect(s.people == 6 && s.floors == 3 && !s.isEmpty)
        #expect(AttentionSummary.next(after: nil, in: s.waiting) == "b")
        #expect(AttentionSummary.next(after: "b", in: s.waiting) == "a")
        #expect(AttentionSummary.next(after: "a", in: s.waiting) == "b")
        #expect(AttentionSummary.next(after: "gone", in: s.waiting) == "b")
        #expect(AttentionSummary.make([]).isEmpty)
    }

    @Test("樓層索引列：由上往下 RF、專案樓層、閒置 N、大廳；每層狀態徽章；閒置清單全部讀得到")
    func rail() {
        var reg = TowerRegistry()
        let deps = [OfficeDepartment(name: "A", isResident: true, isActive: true), OfficeDepartment(name: "B", isResident: true, isActive: true)]
            + (1...22).map { OfficeDepartment(name: "I\($0)", isResident: true, isActive: false) }
        let (plan, _) = TowerPlan.build(departments: deps, cards: [], registry: &reg, usage: { ["a": 2, "b": 1] }, now: t0)
        // 閒置只有 1 層、高 0.9，22 個名字都在這一層
        let idle = plan.floors.filter { $0.kind == .idle }
        #expect(idle.count == 1 && idle[0].plates.count == 22 && idle[0].height == 0.9)
        let decor = ["a": FloorDecor(theme: .call_room, accentColor: "#5B8DB8", props: [], reason: "", source: "ai", decidedAt: t0)]
        let rows = TowerIndex.rows(plan, decor: decor, moods: ["a": [.waiting, .working], "b": [.finished]])
        #expect(rows.map(\.kind) == [.roof, .project, .project, .idle, .lobby])
        #expect(rows[1].title == "B" && rows[2].title == "A" && rows[2].floorNo == "02")
        #expect(rows[2].subtitle == "秘書電話室" && rows[2].accent == "#8C7BB5")          // 識別色＝主題色（不是 AI 給的）
        #expect(rows[2].waiting == 1 && rows[2].working == 1 && rows[1].finished == 1)
        #expect(rows[3].title == "閒置 22" && rows[3].idleNames.count == 22)
    }

    @Test("標籤避讓：任兩個不重疊；等你／卡住一定畫（往上堆、畫引線）；工作中撞到就收進那層 +N；水平夾在畫面內")
    func labels() {
        // 10 個人擠在同一點（最壞情況）
        var boxes: [LabelBox] = []
        for i in 0..<4 { boxes.append(LabelBox(id: "w\(i)", kind: .working, ax: 100, ay: 100, w: 80, h: 22, group: "f1")) }
        for i in 0..<3 { boxes.append(LabelBox(id: "q\(i)", kind: .waiting, ax: 100, ay: 100, w: 160, h: 26, group: "f1")) }
        for i in 0..<3 { boxes.append(LabelBox(id: "s\(i)", kind: .stuck, ax: 100, ay: 100, w: 110, h: 22, group: "f1")) }
        let (p, hidden) = LabelLayout.place(boxes, width: 752, height: 900)
        #expect(LabelLayout.overlaps(p) == 0)
        #expect(p.filter { $0.kind == .waiting }.count == 3 && p.filter { $0.kind == .stuck }.count == 3)
        #expect(p.first?.kind == .waiting)                                          // 優先序
        #expect(p.filter { $0.kind == .working }.count + hidden["f1", default: 0] == 4)
        #expect(p.allSatisfy { $0.x >= 2 && $0.x + $0.w <= 750 })
        // 分得開的：都在頭頂正上方、沒有引線
        let far = (0..<5).map { LabelBox(id: "n\($0)", kind: .working, ax: 60 + Double($0) * 140, ay: 300, w: 90, h: 22) }
        let (q, h2) = LabelLayout.place(far, width: 752, height: 900)
        #expect(q.count == 5 && h2.isEmpty && q.allSatisfy { !$0.leader && abs($0.x + $0.w / 2 - $0.ax) < 1e-9 || $0.x <= 2 })
    }

    @Test("標籤不越層（10-20 第 4 棒）：不超過自己那層的天花、不低於地坪；樓層名當障礙物不被推走；擠的時候挑離頭最近的空位")
    func labelsStayInFloor() {
        // 頭頂離天花只剩 10 pt：頭頂正上放不下，要放在頭的旁邊（仍在這層裡、離頭 ≤ 24 pt）
        let b = LabelBox(id: "a", kind: .waiting, ax: 300, ay: 400, w: 160, h: 24, group: "f2", ceil: 410, floorY: 260)
        let (p, h) = LabelLayout.place([b], width: 752, height: 900)
        #expect(h.isEmpty && p.count == 1)
        #expect(p[0].y + p[0].h <= 410.5 && p[0].y >= 259.5)
        let dx = max(p[0].x - 300, 0, 300 - (p[0].x + p[0].w)), dy = max(p[0].y - 400, 0, 400 - (p[0].y + p[0].h))
        #expect(hypot(dx, dy) <= 24)
        // 樓層名（fixed）佔住頭頂旁邊：標籤不得疊上去，也不會出現在回傳裡
        let floorName = PlacedLabel(id: "floor:f2", kind: .floor, x: 140, y: 380, w: 200, h: 24, leader: false, ax: 0, ay: 0)
        let (p2, _) = LabelLayout.place([b], width: 752, height: 900, fixed: [floorName])
        #expect(p2.count == 1 && !p2[0].overlaps(floorName) && p2.allSatisfy { $0.kind != .floor })
        #expect(p2[0].y + p2[0].h <= 410.5)
        // 7 個卡住擠同一點、這層只有 150 pt 高：全部畫出來、不重疊、都在這層裡
        let many = (0..<7).map { LabelBox(id: "s\($0)", kind: .stuck, ax: 300, ay: 380, w: 120, h: 22, group: "f3", ceil: 420, floorY: 270) }
        let (p3, h3) = LabelLayout.place(many, width: 752, height: 900)
        #expect(p3.count == 7 && h3.isEmpty && LabelLayout.overlaps(p3) == 0)
        #expect(p3.allSatisfy { $0.y + $0.h <= 420.5 && $0.y >= 269.5 })
    }
}

/// 28 個常駐專案：用手寫的一句描述當假 README（不是 README 原文），本地評分要 ≥ 26 個等於規劃 §4.2 的「應為」
@Suite("TowerThemeIdentity")
struct TowerThemeIdentityTests {
    static let projects: [(String, String, TowerTheme)] = [
        ("ProjectD", "# ProjectD\n\niPhone app that reads NFC tags and opens a demo business card. Built with SwiftUI, shipped to the App Store.", .app_studio),
        ("ShoWork42", "# ShoWork42\n\nmacOS 選單列常駐程式：讓終端機裡的 AI 發光提示狀態，另有一個 AI 工作戰情中心看板。", .monitor),
        ("ProjectB", "# ProjectB\n\n派車行程 App：機場接送、包車司機排班，行程自動同步到 iPhone 行事曆。", .dispatch_room),
        ("ProjectA", "# ProjectA\n\n讀建築平面圖，自動規劃水電、給排水與裝潢報價。", .drafting_room),
        ("ProjectC", "# ProjectC\n\nLINE 秘書：在平板上代管 LINE 帳號，自動回覆訊息、派單與提醒行程。", .call_room),
        ("demo-studio", "# demo-studio\n\n幫小店經營社群的行銷方案：月費方案、建置與教學。", .marketing),
        ("promo-kit", "# promo-kit\n\n宣傳素材：Threads 貼文、短影音腳本與曝光追蹤。", .marketing),
        ("ProjectE", "# ProjectE\n\n打平板電話直接跟 AI 語音對話，平板自動接聽。", .call_room),
        ("relief-handbook", "# 浮雕手冊\n\n照片轉 CNC 浮雕與雕刻路徑的操作流程。", .print_shop),
        ("money-bot", "# money-bot\n\n個人財務 agent：追還款、催收與可動用資金。", .ledger_room),
        ("worklog-form", "# worklog-form\n\n點數卡填寫表單：用 Apps Script 把手機表單寫進試算表。", .ledger_room),
        ("In_Unison42", "# In_Unison42\n\nPlay audio on all speakers in sync: measures latency with the microphone and matches the volume.", .hw_lab),
        ("SideScreen42", "# SideScreen42\n\nUse a Windows laptop as a wireless extended display for the Mac, H.264 streaming over Wi-Fi.", .hw_lab),
        ("cool42", "# cool42\n\nFan guard for Apple Silicon: watches the temperature and sets the fan curve from the menu bar.", .monitor),
        ("專案A", "# 專案A\n\nWidget generator that outputs STL and STEP parts with build123d.", .print_shop),
        ("projectx", "# projectx\n\nSDF/CAD framework that exports parts and meshes for 3D printing.", .print_shop),
        ("cad-sorter", "# 圖檔整理\n\nCAD 圖檔整理：拆圖、BOM 表與工程圖索引。", .drafting_room),
        ("flight-lookup", "# flight-lookup\n\nFlight status lookup for airport pickups.", .dispatch_room),
        ("ProjectH", "# ProjectH\n\n手機遊戲 AI：角色、關卡與手感調整，iPhone 上可玩。", .game_lab),
        ("term-hub", "# term-hub\n\nA menu-bar command center for terminal sessions.", .monitor),
        ("hig42_design", "# hig42_design\n\nApple Human Interface Guidelines design skill: colors, typography and Liquid Glass.", .design_studio),
        ("screen-mcp", "# screen-mcp\n\nMCP server for screen and mouse control on macOS.", .monitor),
        ("glowstick-ble", "# glowstick-ble\n\n用 BLE 讓演唱會螢光棒變色（藍牙寫入顏色）。", .hw_lab),
        ("studio-agreement", "# studio-agreement\n\n合作協議書與 NDA 簽署流程。", .legal_room),
        ("order-bot", "# order-bot\n\n從派車群自動抓單，轉給司機。", .dispatch_room),
        ("ProjectF", "# ProjectF\n\nVideo production skill: storyboards, voice-over (TTS) and subtitles.", .media_studio),
        ("ProjectG", "# ProjectG\n\n德州撲克工具：翻牌前查表、翻牌後勝率。", .game_lab),
        ("agreement", "# agreement\n\n協議書範本與簽署紀錄。", .legal_room),
    ]

    @Test("28 個常駐專案（手寫描述）本地評分 ≥ 26 個判對")
    func identity28() {
        var ok = 0, wrong: [String] = []
        for (name, readme, want) in Self.projects {
            let got = WorkSignature.make(DecorInput(project: name, readme: readme)).best.theme
            if got == want { ok += 1 } else { wrong.append("\(name): \(got.rawValue) ≠ \(want.rawValue)") }
        }
        print("identity28 ok=\(ok)/\(Self.projects.count) wrong=\(wrong)")
        #expect(ok >= 26, "判錯：\(wrong)")
    }

    @Test("README 去噪：徽章、圖片、程式碼區塊、網址不算；license 徽章不再讓法務室贏；小寫 line 不算 LINE")
    func readmeNoise() {
        let r = "# X\n\n[![License: MIT](https://img.shields.io/badge/license-MIT)](LICENSE)\n![shot](a.png)\nMCP server for mouse control.\n\n```\nlet line = 1\n```\n"
        let s = WorkSignature.make(DecorInput(project: "X", readme: r))
        #expect(s.identity[.legal_room] == nil && s.best.theme == .monitor)
        #expect(WorkSignature.make(DecorInput(project: "x", notes: ["read line by line"])).scores[.call_room] == nil)
        #expect(WorkSignature.make(DecorInput(project: "x", notes: ["LINE 官方帳號"])).scores[.call_room] != nil)
        #expect(WorkSignature.splitName("DemoLine42") == "Demo Line 42" && WorkSignature.splitName("In_Unison42") == "In Unison 42")
    }

    @Test("工作分數要換掉身分主題：≥ 身分最高 ×2 且命中 ≥ 5")
    func workOverride() {
        let readme = "# ProjectA\n\n讀建築平面圖。"
        // 身分 drafting（name room ×2＋建築、平面圖 ×4＝10）；工作一點點列印 ⇒ 不換
        let a = WorkSignature.make(DecorInput(project: "ProjectA", readme: readme))
        #expect(a.best.theme == .drafting_room)
        let b = WorkSignature.make(DecorInput(project: "ProjectA", paths: ["a.stl", "b.stl"], readme: readme))
        #expect(b.best.theme == .drafting_room)
        let c = WorkSignature.make(DecorInput(project: "ProjectA", paths: (0..<25).map { "p\($0).stl" }, readme: readme))
        #expect(c.best.theme == .print_shop)
    }

    @Test("AI 只微調：主題不在本地身分前 2 名就不採用（只收擺設）；看不出身分時採用；識別色鎖主題色")
    func reconcile() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let sig = WorkSignature.make(DecorInput(project: "ShoWork42", readme: Self.projects[1].1))
        let ai = FloorDecor(theme: .call_room, accentColor: "#4E9C8F", props: ["mail_rack", "console"], reason: "LINE", source: "ai", decidedAt: t0)
        let r = DecorPolicy.reconcile(ai, identity: sig)
        #expect(r.theme == .monitor && r.accentColor == TowerTheme.monitor.accent && r.props.contains("console") && !r.props.contains("mail_rack"))
        // 看不出身分（沒有 README、名字也沒命中）：AI 說了算，識別色照樣鎖
        let none = WorkSignature.make(DecorInput(project: "zzz"))
        let r2 = DecorPolicy.reconcile(FloorDecor(theme: .app_studio, accentColor: "#5B8DB8", props: [], reason: "", source: "ai", decidedAt: t0), identity: none)
        #expect(r2.theme == .app_studio && r2.accentColor == "#4E9C8F")
        // 前 2 名之內：採用
        let ride = WorkSignature.make(DecorInput(project: "ProjectB", readme: Self.projects[2].1))
        let top2 = ride.identityTop(2)
        let r3 = DecorPolicy.reconcile(FloorDecor(theme: top2[1], accentColor: "#000000", props: [], reason: "", source: "ai", decidedAt: t0), identity: ride)
        #expect(r3.theme == top2[1] && r3.accentColor == top2[1].accent)
    }

    @Test("ThemePicker：AI 回了身分前 2 名以外的主題 ⇒ 快取存本地身分主題、識別色＝主題色（假 runner）")
    func pickerReconcile() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picker-\(UUID().uuidString)")
        let r = FakeRunner([FakeRunner.ok("call_room")])
        let p = ThemePicker(dir: dir, clock: { Date(timeIntervalSince1970: 1_800_000_000) }, runner: { r.run($0) })
        let sem = DispatchSemaphore(value: 0)
        let inp = DecorInput(project: "ShoWork42", readme: Self.projects[1].1)
        _ = p.consider("ShoWork42", turnEnded: false, enabled: true, input: { inp }, finished: { _ in sem.signal() })
        sem.wait()
        #expect(r.calls == 1)
        #expect(p.cached("ShoWork42")?.theme == .monitor && p.cached("ShoWork42")?.accentColor == TowerTheme.monitor.accent)
        try? FileManager.default.removeItem(at: dir)
    }
}
