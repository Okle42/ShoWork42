import Foundation
import Testing
@testable import ShoWorkCore

@Suite("小島村莊")
struct VillageTests {
    // 假名（公開 repo 不放真的專案名）
    let cfg = VillageConfig(shopName: "小明的店", zones: ["ProjectShop": "shop", "projectco": "company", "ProjectSolo": "personal", "壞掉": "townhall"],
                            shopKeywords: ["shopline"])

    func card(_ id: String, _ project: String, _ col: BoardColumn, name: String, reason: String = "", captain: Bool = false,
              at: Date? = nil) -> BoardCard {
        var c = BoardCard(id: id, column: col, reason: reason, project: project, title: "\(name)-在做事", lastActivity: at, pid: 1, sessionId: id)
        c.captain = captain
        return c
    }

    @Test("歸屬對照表：本機設定、不分大小寫、內建 Okle42、關鍵字、隊長＝鎮公所、其他＝個人")
    func zones() {
        #expect(VillageZones.zone(project: "ProjectShop", config: cfg) == .shop)
        #expect(VillageZones.zone(project: "PROJECTSHOP", config: cfg) == .shop)
        #expect(VillageZones.zone(project: "ProjectCo", config: cfg) == .company)
        #expect(VillageZones.zone(project: "ShoWork42", config: cfg) == .company)            // 內建
        #expect(VillageZones.zone(project: "ShoWork42", config: nil) == .company)
        #expect(VillageZones.zone(project: "my-shopline-bot", config: cfg) == .shop)          // 關鍵字
        #expect(VillageZones.zone(project: "音樂", config: cfg) == .personal)
        #expect(VillageZones.zone(project: "ProjectShop", captain: true, config: cfg) == .townhall)
        #expect(VillageZones.zone(project: "壞掉", config: cfg) == .personal)                  // 設定不能把專案指到鎮公所
        #expect(VillageZones.shopName(cfg) == "小明的店")
        #expect(VillageZones.shopName(nil) == "我的店")
    }

    @Test("local.json 讀得到 village（沒寫也讀得回來）")
    func localConfig() throws {
        let j = #"{"owner":"小明","village":{"shopName":"A店","zones":{"P":"shop"}}}"#
        let c = try JSONDecoder().decode(LocalConfig.self, from: Data(j.utf8))
        #expect(c.village?.shopName == "A店")
        #expect(c.village?.zones?["P"] == "shop")
        let old = try JSONDecoder().decode(LocalConfig.self, from: Data(#"{"owner":"小明"}"#.utf8))
        #expect(old.village == nil)
    }

    @Test("誰在哪：工作中／等你／卡住在自己位置、做完休息到廣場、隊長在鎮公所、排隊訊息不算人")
    func spots() {
        let cards = [
            card("a", "ProjectShop", .active, name: "Ann"),
            card("b", "ProjectShop", .review, name: "Ben", reason: "做完了，你還沒看"),
            card("c", "ProjectCo", .review, name: "Cat", reason: "等你回答"),
            card("d", "音樂", .stuck, name: "Dan"),
            card("e", "健康", .done, name: "Eve"),
            card("f", "ProjectShop", .done, name: "Cap", captain: true),
            card("a#q1", "ProjectShop", .todo, name: "Ann"),
        ]
        let p = Village.plan(cards: cards, config: cfg)
        func r(_ id: String) -> VillageResident { p.residents.first { $0.id == id }! }
        #expect(p.residents.count == 6)
        #expect(r("a").spot == .work && r("a").zone == .shop)
        #expect(r("b").spot == .plaza)
        #expect(r("c").spot == .work && r("c").zone == .company && r("c").needsAnswer)
        #expect(r("d").spot == .work && r("d").stall == 0)
        #expect(r("e").spot == .plaza && r("e").stall == 1)          // 休息的人也有自己的攤（攤位照開）
        #expect(r("f").zone == .townhall && r("f").spot == .work)    // 隊長閒著也在鎮公所
        #expect(p.stalls == ["音樂", "健康"])
        #expect(r("a").name == "Ann")
        #expect(p.shopName == "小明的店")
        #expect(r("f").home == nil)                                  // 隊長住鎮公所，不另外蓋家
        #expect(p.homes.count == 5)
        // 家：店屋的人住店屋後面（北邊中間）、公司住東邊、個人住西邊
        #expect(VillageLayout.homePrefer[.shop]!.prefix(2).contains(r("a").home!))
        #expect(VillageLayout.homePrefer[.company]!.contains(r("c").home!))
        #expect(VillageLayout.homePrefer[.personal]!.contains(r("d").home!))
        #expect(Set(p.homes.map(\.index)).count == p.homes.count)
    }

    @Test("同一個地點的人分到不同位置；廣場的人也是")
    func slots() {
        let cards = (0..<5).map { card("s\($0)", "ProjectShop", .active, name: "N\($0)") } + (0..<3).map { card("p\($0)", "X", .done, name: "P\($0)") }
        let p = Village.plan(cards: cards, config: cfg)
        let work = p.residents.filter { $0.spot == .work }.map(\.slot)
        #expect(Set(work).count == 5)
        let plaza = p.residents.filter { $0.spot == .plaza }.map(\.slot)
        #expect(Set(plaza) == [0, 1, 2])
        let pts = p.residents.filter { $0.spot == .work }.map { VillageLayout.workSpot(zone: $0.zone, stall: $0.stall, slot: $0.slot).0 }
        #expect(Set(pts).count == 5)
    }

    @Test("離線＝回家：記得的人沒有卡片就在家；超過 3 天忘掉")
    func offline() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var m = Village.remember(VillageMemory(), cards: [card("a", "ProjectShop", .active, name: "Ann"), card("b", "ProjectCo", .active, name: "Bob"),
                                                          card("cap", "ProjectShop", .active, name: "Cap", captain: true)], now: now)
        #expect(m.people.keys.sorted() == ["Ann", "Bob"])                // 隊長不記（住鎮公所）
        let p = Village.plan(cards: [card("a", "ProjectShop", .active, name: "Ann")], memory: m, config: cfg, now: now.addingTimeInterval(60))
        let bob = p.residents.first { $0.name == "Bob" }!
        #expect(bob.spot == .home && !bob.online && bob.id == "home:Bob" && bob.zone == .company)
        #expect(p.homes.first { $0.name == "Bob" }?.online == false)
        #expect(p.homes.first { $0.name == "Ann" }?.online == true)
        m = Village.remember(m, cards: [], now: now.addingTimeInterval(Village.keepHome + 1))
        #expect(m.people.isEmpty)
        // 記憶存檔讀回來一樣
        let m2 = Village.remember(VillageMemory(), cards: [card("a", "ProjectShop", .active, name: "Ann")], now: now)
        #expect(VillageMemory.decode(m2.encoded()) == m2)
        #expect(VillageMemory.decode(nil) == VillageMemory())
    }

    @Test("小狗去等最久的那位；沒人等就沒有目標")
    func dog() {
        let t = Date(timeIntervalSince1970: 1_000)
        let cards = [card("x", "P", .review, name: "X", reason: "等你回答", at: t.addingTimeInterval(50)),
                     card("y", "P", .review, name: "Y", reason: "要你決定：發不發", at: t),
                     card("z", "P", .active, name: "Z", at: t.addingTimeInterval(-100))]
        #expect(Village.plan(cards: cards, config: cfg).dogTarget == "y")
        #expect(Village.plan(cards: [cards[2]], config: cfg).dogTarget == nil)
    }

    @Test("小攤最多 6 攤，多的專案共用")
    func stallOverflow() {
        let cards = (0..<8).map { card("c\($0)", "Solo\($0)", .active, name: "S\($0)") }
        let p = Village.plan(cards: cards, config: cfg)
        #expect(p.stalls.count == Village.maxStalls)
        #expect(p.residents.allSatisfy { ($0.stall ?? -1) >= 0 && ($0.stall ?? 99) < Village.maxStalls })
    }

    @Test("島上的東西平常不冒警告，到門檻才冒")
    func signs() {
        var s = CityState()
        #expect(VillageSigns.alerts(s).isEmpty)
        s.grid = CityGrid(fiveUsed: 50, sevenUsed: 40, stage: .normal)
        #expect(VillageSigns.alerts(s).isEmpty)
        #expect(VillageSigns.water(s.grid) == 0.5)
        s.grid = CityGrid(fiveUsed: 97, sevenUsed: 40, stage: .flicker)
        #expect(VillageSigns.alerts(s).map(\.id) == ["city:power"])
        s.grid = CityGrid(fiveUsed: 10, sevenUsed: 96, stage: .normal)
        #expect(VillageSigns.alerts(s).map(\.id) == ["city:fuel"])          // 7 天＝海
        #expect(VillageSigns.alerts(s).first?.text.contains("退潮") == true)
        #expect(abs(VillageSigns.tide(s.grid) - 0.04) < 0.001)
        s.grid = CityGrid(fiveUsed: 10, sevenUsed: 20, stage: .normal)
        #expect(abs(VillageSigns.tide(s.grid) - 0.8) < 0.001)
        #expect(VillageSigns.tide(CityGrid()) == 0.6)
        s.grid = CityGrid(fiveUsed: 100, sevenUsed: 40, stage: .blackout)
        #expect(VillageSigns.water(s.grid) == 0)
        s.grid = CityGrid()
        s.disks = [CityDisk(name: "Macintosh HD", isInternal: true, mounted: true, total: 100, available: 5)]
        #expect(VillageSigns.alerts(s).map(\.id) == ["city:disk:Macintosh HD"])
        s.disks[0].available = 50
        s.power = CityPower(temp: 95, level: "hot")
        #expect(VillageSigns.alerts(s).map(\.id) == ["city:cooler"])
    }

    @Test("座標：工作位置、廣場、家門口都在島上、不在房子裡")
    func layout() {
        let obs = VillageLayout.obstacles()
        var pts: [VPoint] = []
        for z in [VillageZone.shop, .company, .townhall] { for s in 0..<8 { pts.append(VillageLayout.workSpot(zone: z, stall: nil, slot: s).0) } }
        for st in 0..<VillageLayout.stalls.count { for s in 0..<3 { pts.append(VillageLayout.workSpot(zone: .personal, stall: st, slot: s).0) } }
        for s in 0..<29 { pts.append(VillageLayout.plazaSpot(s).0) }
        for i in VillageLayout.homes.indices { pts.append(VillageLayout.homeDoor(i)) }
        for p in pts { #expect(VillageLayout.walkable(p, obstacles: obs, pad: 0.1), "\(p) 擋住了") }
        // 障礙物彼此不重疊（房子不疊在一起）
        let solid = [VillageLayout.shop, VillageLayout.company, VillageLayout.warehouse, VillageLayout.diskShed, VRect(VillageLayout.campfire.x, VillageLayout.campfire.z, 1.4, 1.4)]
            + VillageLayout.carSpots.values.flatMap { $0 }.map { VRect($0.x, $0.z, VillageLayout.carSize.w, VillageLayout.carSize.d) }
            + VillageLayout.stalls + VillageLayout.homes.map { VRect($0.x, $0.z, VillageLayout.homeSize, VillageLayout.homeSize) }
        for (i, a) in solid.enumerated() { for b in solid[(i + 1)...] {
            #expect(abs(a.cx - b.cx) >= (a.w + b.w) / 2 || abs(a.cz - b.cz) >= (a.d + b.d) / 2, "\(a) 跟 \(b) 疊在一起")
        } }
        for h in VillageLayout.homes { #expect(hypot(h.x, h.z) + VillageLayout.homeSize < VillageLayout.radius) }
    }

    @Test("找路：繞過房子、不穿過障礙、走得到")
    func route() {
        let obs = VillageLayout.obstacles()
        let a = VPoint(-12, 3)
        let b = VPoint(-12, -9)                        // 店屋正後方：一定要繞
        let path = VillagePath.route(from: a, to: b, obstacles: obs)
        #expect(path.first == a)
        #expect(path.last!.dist(b) < 0.8)
        for (p, q) in zip(path, path.dropFirst()) { #expect(VillagePath.clear(p, q, obs) || p == a, "\(p)→\(q) 穿過障礙") }
        #expect(VillagePath.length(path) > a.dist(b) + 1)       // 有繞路
        // 點到海裡：走到最近的岸邊
        let sea = VillagePath.route(from: VPoint(0, 8), to: VPoint(0, 24.5), obstacles: obs)
        #expect(hypot(sea.last!.x, sea.last!.z) <= VillageLayout.walkRadius + 0.01)
    }

    @Test("車：設定決定車型、顏色、停哪；沒設定一台白色休旅車；格子滿了不畫")
    func cars() throws {
        #expect(VillageCars.list(nil) == [VillageCar(model: .suv, color: VillageCarModel.suv.color, owner: nil, zone: .shop, slot: 0)])
        let c = VillageConfig(cars: [VillageCarConfig(model: "suv", place: "shop", owner: "A"), VillageCarConfig(model: "MPV", place: "shop", owner: "B"),
                                     VillageCarConfig(model: "coupe", place: "company", color: "#123456"), VillageCarConfig(model: "tank", place: "shop"),
                                     VillageCarConfig(model: "suv", place: "shop")])
        let l = VillageCars.list(c)
        #expect(l.map(\.model) == [.suv, .mpv, .coupe])
        #expect(l.map(\.slot) == [0, 1, 0])
        #expect(l[2].color == 0x123456 && l[1].color == VillageCarModel.mpv.color && l[1].owner == "B")
        let j = #"{"cars":[{"model":"mpv","place":"shop","owner":"X"}]}"#
        let d = try JSONDecoder().decode(VillageConfig.self, from: Data(j.utf8))
        #expect(VillageCars.list(d).first?.model == .mpv)
    }

    @Test("隊長的子 agent 不畫、名牌不掛子 agent")
    func captainSubagents() {
        var c = card("cap", "P", .active, name: "Cap", captain: true)
        c.subagents = [SubagentInfo(description: "背景")]; c.activity = .delegating
        var w = card("w", "P", .active, name: "W")
        w.subagents = [SubagentInfo(description: "子")]
        let p = Village.plan(cards: [c, w], config: cfg)
        #expect(p.residents.first { $0.id == "cap" }?.card?.subagents.isEmpty == true)
        #expect(p.residents.first { $0.id == "cap" }?.card?.activity == AIActivity.none)
        #expect(p.residents.first { $0.id == "w" }?.card?.subagents.count == 1)
        #expect(p.residents.count == 2)
    }

    @Test("小狗＝本機設定的那位島民（名牌「小白（名字）」）；主人名牌沒設＝你")
    func pet() {
        let c = VillageConfig(petName: "puppy", petLabel: "小白", ownerLabel: "老大")
        let p = Village.plan(cards: [card("a", "P", .active, name: "Puppy"), card("b", "P", .active, name: "Ben")], config: c)
        #expect(p.residents.first { $0.name == "Puppy" }?.pet == true)
        #expect(p.residents.first { $0.name == "Ben" }?.pet == false)
        #expect(c.petTitle("Puppy") == "小白（Puppy）")
        #expect(VillageConfig(petName: "x").petTitle("x") == "x")
        #expect(c.ownerTitle == "老大" && VillageConfig().ownerTitle == "你")
    }

    @Test("學校：子資料夾＝科目、數 .md（含子資料夾、不算隱藏）、根目錄的算未分類；不存在用備用；都不在＝沒科目；中文名")
    func school() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("school-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: home) }
        func write(_ p: String) throws {
            let u = URL(fileURLWithPath: home + "/" + p)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        let cfg = VillageSchoolConfig(root: "~/研究", fallback: "~/AI知識庫")
        // 兩個都不在
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        #expect(SchoolScan.scan(cfg, home: home).subjects.isEmpty)
        #expect(SchoolScan.scan(cfg, home: home).summary == "還沒有科目")
        // 只有備用：當成一科「AI」
        try write("AI知識庫/a.md"); try write("AI知識庫/子/b.md"); try write("AI知識庫/c.txt"); try write("AI知識庫/.obsidian/d.md")
        var s = SchoolScan.scan(cfg, home: home)
        #expect(s.usingFallback && s.subjects == [SchoolSubject(name: "AI", notes: 2, latest: s.subjects.first?.latest)])
        // 研究資料夾建了但是空的：0 科（不再用備用）
        try fm.createDirectory(atPath: home + "/研究", withIntermediateDirectories: true)
        s = SchoolScan.scan(cfg, home: home)
        #expect(!s.usingFallback && s.subjects.isEmpty)
        // 中文科目、空科目、根目錄散落的筆記
        try write("研究/機場接送/a.md"); try write("研究/機場接送/深/b.md"); try write("研究/音樂/c.md")
        try fm.createDirectory(atPath: home + "/研究/空的", withIntermediateDirectories: true)
        try write("研究/散的.md")
        s = SchoolScan.scan(cfg, home: home)
        #expect(s.subjects.map(\.name) == ["機場接送", "空的", "音樂", "未分類"])
        #expect(s.subjects.map(\.notes) == [2, 0, 1, 1])
        #expect(s.total == 4 && s.summary == "4 科・4 篇")
        #expect(s.subjects[1].latest == nil && s.subjects[0].latest != nil)
        // 沒設定＝預設路徑（~/Documents/Obsidian/大腦/研究）
        #expect(SchoolScan.scan(nil, home: home).subjects.isEmpty)
    }
}
