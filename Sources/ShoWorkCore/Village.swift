import Foundation

// 小島村莊（11-12）：3D 戰情中心的新預設場景，大樓保留成可切回的另一種看法。
//   一個 AI session＝一位島民。依專案歸屬住在／工作在對應地點：自家店屋（本機設定的店名）、公司小屋（Okle42）、
//   其他（個人）散在島上的小攤；隊長在鎮公所。工作中＝在自己位置忙；做完／閒置＝到廣場晃；離線＝回家（門關、燈暗）。
//   主人（看板的使用者）是一隻小狗：有人在等你回答時自己跑過去站在旁邊；點地面它走過去；沒事在廣場附近晃。
// 這裡只有純資料與規則（歸屬對照表、誰在哪、座標、找路），畫面在 ShoWorkAgent/OfficeVillage.swift。
// 私人的專案名、店名不寫進原始碼（公開 repo）：放 local.json 的 "village"（LocalConfig）。

/// 島上的區域
public enum VillageZone: String, Codable, Sendable, CaseIterable {
    case shop       // 自家店屋（本機設定的店名；奶油／橄欖／金、門口停休旅車）
    case company    // 公司小屋（Okle42；黑底金色 42）
    case personal   // 個人：散在島上的小攤
    case townhall   // 隊長（11-12 第二輪：鎮公所併進中間的店屋，隊長站在店屋門口）
}

/// 本機設定（local.json 的 "village"）：
/// { "shopName": "我的店", "zones": { "專案資料夾名": "shop" | "company" | "personal" }, "shopKeywords": ["關鍵字"] }
public struct VillageConfig: Codable, Sendable, Equatable {
    public var shopName: String?
    public var zones: [String: String]?
    public var shopKeywords: [String]?
    /// 停在島上的車（11-12 第二輪）：車型＋停哪（shop／company）＋顏色（"#RRGGBB"，沒寫＝車型預設色）＋車主（點車時顯示）
    public var cars: [VillageCarConfig]? = nil
    /// 畫成小狗的島民（戰情中心名字，不分大小寫）＋小狗名牌上的名字（例如「小白」）
    public var petName: String? = nil
    public var petLabel: String? = nil
    /// 主人（看板使用者）那個角色的名牌；沒寫＝「你」
    public var ownerLabel: String? = nil
    public init(shopName: String? = nil, zones: [String: String]? = nil, shopKeywords: [String]? = nil, cars: [VillageCarConfig]? = nil,
                petName: String? = nil, petLabel: String? = nil, ownerLabel: String? = nil) {
        self.shopName = shopName; self.zones = zones; self.shopKeywords = shopKeywords; self.cars = cars
        self.petName = petName; self.petLabel = petLabel; self.ownerLabel = ownerLabel
    }
    /// 小狗名牌：「小白（Puppy）」；沒設 petLabel＝名字本身
    public func petTitle(_ name: String) -> String {
        guard let l = petLabel, !l.isEmpty, l != name else { return name }
        return "\(l)（\(name)）"
    }
    public var ownerTitle: String { ownerLabel.flatMap { $0.isEmpty ? nil : $0 } ?? "你" }
}

/// 車型（只有造型特徵，不畫品牌標誌）
public enum VillageCarModel: String, Codable, Sendable, CaseIterable {
    case suv        // 方正休旅、車頂架
    case mpv        // 高大方盒 MPV、大水箱罩
    case coupe      // 低矮四門轎跑、斜背
    /// 預設顏色
    public var color: UInt32 { switch self { case .suv: 0xF2F2EE; case .mpv: 0x17191C; case .coupe: 0x8E9297 } }
    public var title: String { switch self { case .suv: "休旅車"; case .mpv: "MPV"; case .coupe: "四門轎跑" } }
}

public struct VillageCarConfig: Codable, Sendable, Equatable {
    public var model: String
    public var place: String
    public var color: String?
    public var owner: String?
    public init(model: String, place: String, color: String? = nil, owner: String? = nil) {
        self.model = model; self.place = place; self.color = color; self.owner = owner
    }
}

/// 一台要畫的車（已決定停哪一格）
public struct VillageCar: Sendable, Equatable {
    public var model: VillageCarModel
    public var color: UInt32
    public var owner: String?
    public var zone: VillageZone
    public var slot: Int
}

public enum VillageCars {
    /// 沒設定＝店屋門口一台白色休旅車
    public static let fallback = [VillageCarConfig(model: "suv", place: "shop")]

    /// 設定 → 要畫的車：車型認不得跳過；同一地點依序排格子，格子滿了不畫
    public static func list(_ cfg: VillageConfig?) -> [VillageCar] {
        var out: [VillageCar] = []
        var used: [VillageZone: Int] = [:]
        for c in cfg?.cars ?? fallback {
            guard let m = VillageCarModel(rawValue: c.model.lowercased()), let z = VillageZone(rawValue: c.place.lowercased()),
                  let spots = VillageLayout.carSpots[z] else { continue }
            let i = used[z, default: 0]
            guard i < spots.count else { continue }
            used[z] = i + 1
            let col = c.color.flatMap { h -> UInt32? in UInt32(h.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) } ?? m.color
            out.append(VillageCar(model: m, color: col, owner: c.owner, zone: z, slot: i))
        }
        return out
    }
}

/// 專案資料夾名 → 區域的對照表（簡單可改：內建表＋本機 local.json 疊在上面；都沒寫＝個人）
public enum VillageZones {
    /// 內建（公開的專案名）。私人的寫在 local.json village.zones
    public static let builtIn: [String: VillageZone] = [
        "showork42": .company,
        "okle42": .company,
    ]

    /// 合起來的表（鍵一律小寫；本機設定蓋過內建）
    public static func table(_ cfg: VillageConfig?) -> [String: VillageZone] {
        var t = builtIn
        for (k, v) in cfg?.zones ?? [:] {
            if let z = VillageZone(rawValue: v.lowercased()), z != .townhall { t[k.lowercased()] = z }
        }
        return t
    }

    /// 一張卡片住哪一區：隊長＝鎮公所；對照表（不分大小寫）；店屋關鍵字；都沒有＝個人
    public static func zone(project: String, captain: Bool = false, config: VillageConfig?) -> VillageZone {
        if captain { return .townhall }
        let p = project.lowercased()
        if let z = table(config)[p] { return z }
        if (config?.shopKeywords ?? []).contains(where: { !$0.isEmpty && p.contains($0.lowercased()) }) { return .shop }
        return .personal
    }

    /// 店屋招牌（沒設＝「我的店」）
    public static func shopName(_ cfg: VillageConfig?) -> String {
        cfg?.shopName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "我的店"
    }
}

// MARK: - 島民

/// 島民現在在哪
public enum VillageSpot: String, Sendable, Equatable {
    case work       // 在自己的工作位置（店屋前、公司小屋前、自己的小攤、鎮公所）
    case plaza      // 沒事：圍著營火坐（11-12 第二輪；原本在廣場晃）
    case home       // 離線：回家（人不畫，家門關、燈暗）
}

public struct VillageResident: Sendable, Equatable, Identifiable {
    public var id: String               // 卡片 id；離線的＝"home:<名字>"
    public var name: String
    public var project: String
    public var zone: VillageZone
    public var card: BoardCard?         // 離線＝nil
    public var mood: Mood?              // 離線＝nil
    public var spot: VillageSpot
    public var slot: Int                // 在那個地點的第幾個位置（work：同地點序號；plaza：廣場序號）
    public var stall: Int?              // 個人區：第幾個小攤
    public var home: Int?               // 住第幾間家（VillageLayout.homes 的序號；名額滿了＝nil）
    public var pet = false              // 畫成小狗（本機設定 petName）
    public var online: Bool { card != nil }
    /// 頭上冒「！」：等你回答／要你決定、或終端機開著權限對話框
    public var needsAnswer: Bool { mood == .waiting || card?.permit != nil }
}

public struct VillageHome: Sendable, Equatable {
    public var name: String
    public var zone: VillageZone
    public var online: Bool
    public var index: Int               // VillageLayout.homes 的序號
}

public struct VillagePlan: Sendable, Equatable {
    public var residents: [VillageResident] = []
    public var stalls: [String] = []    // 個人小攤的專案名（依序擺在 VillageLayout.stalls）
    public var homes: [VillageHome] = []
    /// 小狗要去誰旁邊：等你回答的人裡最早開始等的那位
    public var dogTarget: String?
    public var shopName = "我的店"
    public init() {}
}

/// 記得最近出現過的島民（名字 → 專案、最後看到）：關掉的 session 還要有家可回。存在 office.village（UserDefaults JSON）
public struct VillageMemory: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var project: String
        public var lastSeen: Date
        public init(project: String, lastSeen: Date) { self.project = project; self.lastSeen = lastSeen }
    }
    public var people: [String: Entry] = [:]
    public init(people: [String: Entry] = [:]) { self.people = people }

    public static func decode(_ d: Data?) -> VillageMemory {
        d.flatMap { try? BoardJSON.decoder.decode(VillageMemory.self, from: $0) } ?? VillageMemory()
    }
    public func encoded() -> Data? { try? BoardJSON.encoder.encode(self) }
}

public enum Village {
    /// 離線多久以內還有家（跟英文名回收的 3 天一樣：之後名字可能給別的 session 用）
    public static let keepHome: TimeInterval = Nicknames.reuseAfter
    public static let maxStalls = VillageLayout.stalls.count
    public static let maxHomes = VillageLayout.homes.count

    /// 島民名字：卡片標題「名字-任務」的名字（看板顯示的英文名）；沒有就 session 名、再沒有就標題
    public static func name(_ c: BoardCard) -> String {
        let t = c.title.split(separator: "-", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !t.isEmpty, t.count <= 16 { return t }
        if let n = c.name, !n.isEmpty { return n }
        return t.isEmpty ? c.sessionId.prefix(6).description : String(t.prefix(15))
    }

    /// 更新記憶：活著的人記下專案與時間；超過 keepHome 的忘掉
    public static func remember(_ m: VillageMemory, cards: [BoardCard], now: Date) -> VillageMemory {
        var out = m
        for c in cards where !c.id.contains("#") && !c.captain {
            out.people[name(c)] = .init(project: c.project, lastSeen: now)
        }
        out.people = out.people.filter { now.timeIntervalSince($0.value.lastSeen) < keepHome }
        return out
    }

    /// 誰在哪、小攤、家、小狗要去哪
    public static func plan(cards: [BoardCard], memory: VillageMemory = VillageMemory(), config: VillageConfig? = nil, now: Date = Date()) -> VillagePlan {
        var plan = VillagePlan()
        plan.shopName = VillageZones.shopName(config)
        let live = cards.filter { !$0.id.contains("#") }
        // 個人小攤：依卡片出現順序，一個專案一攤；超過攤位數的跟最後幾攤共用
        for c in live where !c.captain && VillageZones.zone(project: c.project, config: config) == .personal {
            if !plan.stalls.contains(where: { $0.caseInsensitiveCompare(c.project) == .orderedSame }) && plan.stalls.count < maxStalls {
                plan.stalls.append(c.project)
            }
        }
        func stallIndex(_ project: String) -> Int {
            if let i = plan.stalls.firstIndex(where: { $0.caseInsensitiveCompare(project) == .orderedSame }) { return i }
            return abs(project.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }) % max(1, plan.stalls.count)
        }
        var workCount: [String: Int] = [:]
        var plazaCount = 0
        for var c in live.sorted(by: { $0.id < $1.id }) {
            // 隊長的子 agent（背景 Agent）不另外畫成島民、名牌也不掛「子 agent N」（11-12 第二輪：疊在隊長名牌上）
            if c.captain { c.subagents = []; if c.activity == .delegating { c.activity = .none } }
            let zone = VillageZones.zone(project: c.project, captain: c.captain, config: config)
            let mood = Mood.of(c)
            var r = VillageResident(id: c.id, name: name(c), project: c.project, zone: zone, card: c, mood: mood, spot: .work, slot: 0)
            r.pet = config?.petName.map { $0.caseInsensitiveCompare(r.name) == .orderedSame } ?? false
            let needs = r.needsAnswer
            // 隊長一律在鎮公所；工作中／等你／卡住在自己位置；做完／休息／睡著到廣場
            let atWork = c.captain || needs || mood == .working || mood == .stuck
            if atWork {
                if zone == .personal { r.stall = stallIndex(c.project) }
                let key = zone == .personal ? "personal:\(r.stall ?? 0)" : zone.rawValue
                r.slot = workCount[key, default: 0]; workCount[key, default: 0] += 1
            } else {
                r.spot = .plaza
                r.slot = plazaCount; plazaCount += 1
                if zone == .personal { r.stall = stallIndex(c.project) }
            }
            plan.residents.append(r)
        }
        // 離線：記得的人裡現在沒有卡片的
        let liveNames = Set(plan.residents.map(\.name))
        for (n, e) in memory.people.sorted(by: { $0.key < $1.key }) where !liveNames.contains(n) && now.timeIntervalSince(e.lastSeen) < keepHome {
            let zone = VillageZones.zone(project: e.project, config: config)
            plan.residents.append(VillageResident(id: "home:\(n)", name: n, project: e.project, zone: zone, card: nil, mood: nil, spot: .home, slot: 0))
        }
        // 家：隊長住店屋不另外蓋；店屋的人住北邊（店屋後面）、公司住東邊、個人住西邊；偏好的位置滿了就挑最近的空位
        let order: [VillageZone] = [.shop, .company, .personal]
        let homeless = plan.residents.filter { $0.zone != .townhall }
            .sorted { (order.firstIndex(of: $0.zone) ?? 9, $0.name) < (order.firstIndex(of: $1.zone) ?? 9, $1.name) }
        var seen = Set<String>(), taken = Set<Int>()
        for r in homeless where !seen.contains(r.name) {
            seen.insert(r.name)
            guard let i = (VillageLayout.homePrefer[r.zone] ?? Array(VillageLayout.homes.indices)).first(where: { !taken.contains($0) })
                    ?? VillageLayout.homes.indices.first(where: { !taken.contains($0) }) else { break }
            taken.insert(i)
            plan.homes.append(VillageHome(name: r.name, zone: r.zone, online: r.online, index: i))
        }
        let homeOf = Dictionary(plan.homes.map { ($0.name, $0.index) }, uniquingKeysWith: { a, _ in a })
        for i in plan.residents.indices { plan.residents[i].home = homeOf[plan.residents[i].name] }
        // 小狗：等你回答的人裡最早開始等的
        plan.dogTarget = plan.residents.filter(\.needsAnswer).sorted { a, b in
            let ta = a.card?.permit?.at ?? a.card?.lastActivity ?? .distantFuture, tb = b.card?.permit?.at ?? b.card?.lastActivity ?? .distantFuture
            return ta != tb ? ta < tb : a.id < b.id
        }.first?.id
        return plan
    }
}

// MARK: - 島上的東西要不要冒警告（平常不顯示數字，照現有門檻）

public struct VillageSign: Sendable, Equatable {
    public var id: String       // 跟城市同一組 id（點了開同一張細節卡）
    public var text: String
}

public enum VillageSigns {
    /// 風車＝這台 Mac 的溫度（cool42）、水塔＝5 小時額度、海＝7 天額度、熱氣球＝iCloud、倉庫小屋＝內建碟。
    /// 只在到門檻時回傳（cool42 hot 以上、5 小時額度吃緊／停電、7 天剩 ≤5%、iCloud 卡住或空間不足、內建碟 ≥90%）
    public static func alerts(_ s: CityState) -> [VillageSign] {
        var out: [VillageSign] = []
        if s.power.alert { out.append(.init(id: "city:cooler", text: "風車轉不動：這台 Mac 太熱（\(s.power.level ?? "hot")）")) }
        if s.grid.alert {
            out.append(.init(id: "city:power", text: s.grid.stage == .blackout ? "水塔乾了：AI 額度用完" : "水塔快見底：5 小時額度剩不到 5%"))
        }
        if let l = s.grid.sevenLeft, s.grid.known, l <= 5 {
            out.append(.init(id: "city:fuel", text: "海退潮了：7 天額度剩 \(Int(l.rounded()))%"))
        }
        if let c = s.clouds.first(where: { $0.isICloud && $0.alert }) { out.append(.init(id: c.id, text: "熱氣球漏氣：" + CityText.cloud(c))) }
        if let d = s.disks.first(where: { $0.isInternal && $0.alert }) {
            out.append(.init(id: d.id, text: "倉庫快滿了：內建碟已用 \(Int(((d.used ?? 0) * 100).rounded()))%"))
        }
        return out
    }

    /// 海的潮位（0＝退潮露出沙灘、1＝滿潮）：7 天額度剩多少；讀不到＝中間
    public static func tide(_ g: CityGrid) -> Double {
        guard let l = g.sevenLeft, g.known else { return 0.6 }
        return max(0, min(1, l / 100))
    }

    /// 水塔水位（0–1）：5 小時額度剩多少；讀不到＝半滿
    public static func water(_ g: CityGrid) -> Double {
        guard let l = g.fiveLeft else { return 0.5 }
        return g.stage == .blackout ? 0 : max(0, min(1, l / 100))
    }
}

// MARK: - 座標（世界座標：+x 東、+z 南＝靠鏡頭；地面 y＝0）

public struct VPoint: Sendable, Equatable, Hashable {
    public var x: Double, z: Double
    public init(_ x: Double, _ z: Double) { self.x = x; self.z = z }
    public func dist(_ o: VPoint) -> Double { hypot(x - o.x, z - o.z) }
}

/// 長方形（中心＋寬深）
public struct VRect: Sendable, Equatable {
    public var cx: Double, cz: Double, w: Double, d: Double
    public init(_ cx: Double, _ cz: Double, _ w: Double, _ d: Double) { self.cx = cx; self.cz = cz; self.w = w; self.d = d }
    public func contains(_ p: VPoint, pad: Double = 0) -> Bool { abs(p.x - cx) <= w / 2 + pad && abs(p.z - cz) <= d / 2 + pad }
}

public enum VillageLayout {
    /// 島的半徑（草地）；沙灘到 radius+2
    public static let radius = 25.0
    /// 可以走的範圍（離海邊留 1.5）
    public static let walkRadius = radius - 1.5

    /// 自家店屋在島中間北邊（11-12 第二輪：原本的鎮公所位置；隊長也在這）
    public static let shop = VRect(0, -10, 7, 5.5)
    public static var townhall: VRect { shop }
    public static let company = VRect(12, -4, 5.6, 4.6)
    /// 停車格（車頭朝 +z）：店屋西側兩格並排、公司小屋東側一格
    public static let carSpots: [VillageZone: [VPoint]] = [.shop: [VPoint(-5.3, -9.0), VPoint(-7.6, -9.0)], .company: [VPoint(16.6, -4.0)]]
    /// 每區偏好住哪幾間（VillageLayout.homes 的序號，前面的先住）
    public static let homePrefer: [VillageZone: [Int]] = [.shop: [5, 6, 4, 7, 3, 8], .company: [9, 10, 11, 8], .personal: [0, 1, 2, 3, 11, 10]]
    public static let carSize = (w: 2.1, d: 4.8)
    /// 營火（沒事的島民圍著坐）：廣場西南邊的草地
    public static let campfire = VPoint(-9, 17)
    public static let plaza = VPoint(0, 3)
    public static let plazaRadius = 4.6
    public static let fountain = VRect(0, 3, 2.2, 2.2)
    public static let well = VPoint(6.2, 6.4)        // 水塔（11-12 第二輪：水井改高架水塔）
    public static let windmill = VPoint(18.5, 9.5)
    public static let warehouse = VRect(-18.2, 11.6, 3.6, 3.0)
    public static let balloonTether = VPoint(-9, -19.5)
    /// 個人小攤（攤子本體；攤主站在攤子後面、面向 +z）
    public static let stalls: [VRect] = [VRect(-8.5, 11, 2.4, 1.4), VRect(-2.8, 13.5, 2.4, 1.4), VRect(2.8, 13.5, 2.4, 1.4),
                                          VRect(8.5, 11, 2.4, 1.4), VRect(-13.2, 7.4, 2.4, 1.4), VRect(13.2, 7.4, 2.4, 1.4)]
    /// 家（由西繞北到東）：中心
    public static let homes: [VPoint] = [VPoint(-21.2, 5.6), VPoint(-21.4, -0.6), VPoint(-19.2, -8.6), VPoint(-15.2, -13.6),
                                         VPoint(-9.6, -16.6), VPoint(-4.6, -18.4), VPoint(4.6, -18.4), VPoint(9.6, -16.6),
                                         VPoint(15.2, -13.6), VPoint(19.2, -8.6), VPoint(21.4, -0.6), VPoint(21.2, 5.6)]
    public static let homeSize = 2.6
    public static let trees: [VPoint] = [VPoint(-6.5, -5.5), VPoint(6.5, -5.5), VPoint(-17, -3), VPoint(-13.5, -5.5), VPoint(-10.4, -2.6), VPoint(-12.6, -8.4), VPoint(-5.2, 9.6), VPoint(-15.5, 15.8),
                                         VPoint(11, 15.5), VPoint(17, 1), VPoint(0, -15.5), VPoint(-14, 2.6), VPoint(4.5, -13.5),
                                         VPoint(-3.6, 21.2), VPoint(5.5, 18.6), VPoint(16, -18.5), VPoint(-16, 18)]

    /// 家的大門朝向（面向島中心）：繞 y 軸的角度（0＝朝 +z）
    public static func homeFacing(_ i: Int) -> Double {
        let h = homes[i]
        return atan2(-h.x, -h.z)
    }
    /// 家門口（人回家前走到的那一點）
    public static func homeDoor(_ i: Int) -> VPoint {
        let h = homes[i], a = homeFacing(i), k = homeSize / 2 + 0.9
        return VPoint(h.x + sin(a) * k, h.z + cos(a) * k)
    }

    /// 工作位置：店屋／公司小屋前院兩排、小攤後面、鎮公所門口。回傳位置＋面向（0＝朝 +z）
    public static func workSpot(zone: VillageZone, stall: Int?, slot: Int) -> (VPoint, Double) {
        switch zone {
        case .townhall:
            // 店屋正門口（店屋的人站在兩側，中間留給隊長）
            return (VPoint(shop.cx, shop.cz + shop.d / 2 + 1.25 + Double(slot % 2) * 1.4), 0)
        case .shop:
            let xs = [-2.9, -1.6, 1.6, 2.9], row = (slot / xs.count) % 2
            return (VPoint(shop.cx + xs[slot % xs.count] + (row == 1 ? 0.3 : 0), shop.cz + shop.d / 2 + 1.2 + Double(row) * 1.4), 0)
        case .company:
            let b = company
            let perRow = 3
            let row = (slot / perRow) % 2, col = slot % perRow
            let span = b.w - 1.4, x0 = b.cx - span / 2
            let x = perRow == 1 ? b.cx : x0 + span * Double(col) / Double(perRow - 1) + (row == 1 ? 0.6 : 0)
            return (VPoint(x, b.cz + b.d / 2 + 1.2 + Double(row) * 1.4), 0)
        case .personal:
            let s = stalls[(stall ?? 0) % stalls.count]
            let xs = [0.0, -0.8, 0.8]
            return (VPoint(s.cx + xs[slot % xs.count], s.cz - s.d / 2 - 0.75 - Double(slot / xs.count) * 0.9), 0)
        }
    }

    /// 營火旁的座位：第一圈 8 個、第二圈 12 個，面向火（第三圈之後跟第二圈同位置，疊著也比不見好）
    public static func plazaSpot(_ slot: Int) -> (VPoint, Double) {
        let per = [8, 12], ring = slot < 8 ? 0 : 1, k = ring == 0 ? slot : (slot - 8) % 12
        let r = ring == 0 ? 2.4 : 3.6
        let a = Double(k) / Double(per[ring]) * 2 * .pi + (ring == 0 ? 0.39 : 0.0)
        let p = VPoint(campfire.x + sin(a) * r, campfire.z + cos(a) * r)
        return (p, atan2(campfire.x - p.x, campfire.z - p.z))
    }

    /// 地上擋路的東西（找路、點地面時避開）。stallCount＝現在有畫幾個小攤
    public static func obstacles(stallCount: Int = stalls.count) -> [VRect] {
        var o = [townhall, shop, company, fountain, warehouse, VRect(campfire.x, campfire.z, 1.4, 1.4),
                 VRect(well.x, well.z, 2.2, 2.2), VRect(windmill.x, windmill.z, 2.4, 2.4), VRect(balloonTether.x, balloonTether.z, 0.8, 0.8)]
        o += carSpots.values.flatMap { $0 }.map { VRect($0.x, $0.z, carSize.w, carSize.d) }
        o += stalls.prefix(stallCount)
        o += homes.map { VRect($0.x, $0.z, homeSize, homeSize) }
        o += trees.map { VRect($0.x, $0.z, 1.0, 1.0) }
        return o
    }

    public static func walkable(_ p: VPoint, obstacles: [VRect], pad: Double = 0.25) -> Bool {
        hypot(p.x, p.z) <= walkRadius && !obstacles.contains { $0.contains(p, pad: pad) }
    }
}

// MARK: - 找路（小狗、島民走路）

public enum VillagePath {
    public static let cell = 0.5

    /// 格子 A*（8 方向）：從 a 走到 b，避開障礙物、不下海。起點／終點在障礙物裡＝先找最近能走的格子。
    /// 回傳經過的點（含起點與終點，中間已經拉直：看得到下一個轉角就不停）
    public static func route(from a: VPoint, to b: VPoint, obstacles: [VRect]) -> [VPoint] {
        let R = Int((VillageLayout.walkRadius / cell).rounded(.up))
        func key(_ p: VPoint) -> (Int, Int) { (Int((p.x / cell).rounded()), Int((p.z / cell).rounded())) }
        func pt(_ k: (Int, Int)) -> VPoint { VPoint(Double(k.0) * cell, Double(k.1) * cell) }
        func ok(_ k: (Int, Int)) -> Bool { abs(k.0) <= R && abs(k.1) <= R && VillageLayout.walkable(pt(k), obstacles: obstacles) }
        func nearestOK(_ k: (Int, Int)) -> (Int, Int)? {
            if ok(k) { return k }
            for r in 1...12 {
                var best: ((Int, Int), Int)?
                for dx in -r...r { for dz in -r...r where max(abs(dx), abs(dz)) == r {
                    let c = (k.0 + dx, k.1 + dz)
                    if ok(c), best == nil || dx * dx + dz * dz < best!.1 { best = (c, dx * dx + dz * dz) }
                } }
                if let b = best { return b.0 }
            }
            return nil
        }
        guard let s = nearestOK(key(a)), let g = nearestOK(key(b)) else { return [a, b] }
        let W = 2 * R + 1
        func idx(_ k: (Int, Int)) -> Int { (k.1 + R) * W + (k.0 + R) }
        var gScore = [Double](repeating: .infinity, count: W * W)
        var came = [Int](repeating: -1, count: W * W)
        var closed = [Bool](repeating: false, count: W * W)
        func h(_ k: (Int, Int)) -> Double { hypot(Double(k.0 - g.0), Double(k.1 - g.1)) }
        var open: [(f: Double, k: (Int, Int))] = [(h(s), s)]
        gScore[idx(s)] = 0
        var found = false
        while !open.isEmpty {
            var bi = 0
            for i in open.indices where open[i].f < open[bi].f { bi = i }
            let cur = open.remove(at: bi).k
            let ci = idx(cur)
            if closed[ci] { continue }
            closed[ci] = true
            if cur == g { found = true; break }
            for dx in -1...1 { for dz in -1...1 where dx != 0 || dz != 0 {
                let n = (cur.0 + dx, cur.1 + dz)
                guard ok(n) else { continue }
                if dx != 0 && dz != 0 && (!ok((cur.0 + dx, cur.1)) || !ok((cur.0, cur.1 + dz))) { continue }   // 不切角穿過牆角
                let ni = idx(n)
                if closed[ni] { continue }
                let t = gScore[ci] + (dx != 0 && dz != 0 ? 1.4142 : 1)
                if t < gScore[ni] { gScore[ni] = t; came[ni] = ci; open.append((t + h(n), n)) }
            } }
        }
        guard found else { return [a, b] }
        var cells: [(Int, Int)] = []
        var i = idx(g)
        while i >= 0 { cells.append((i % W - R, i / W - R)); i = came[i] }
        cells.reverse()
        // 拉直：從目前的點往後找最遠一個「直線走過去不碰障礙」的格子
        var out: [VPoint] = [a]
        var cur = pt(cells[0])
        var j = 0
        if a.dist(cur) > 0.01, !clear(a, cur, obstacles) { out.append(cur) }
        while j < cells.count - 1 {
            var k = cells.count - 1
            while k > j + 1 && !clear(cur, pt(cells[k]), obstacles) { k -= 1 }
            cur = pt(cells[k]); j = k
            out.append(cur)
        }
        if let last = out.last, last.dist(b) > 0.01 {
            if VillageLayout.walkable(b, obstacles: obstacles, pad: 0) && clear(last, b, obstacles) { out.append(b) }
        }
        return out
    }

    /// 兩點之間直線走過去會不會碰到障礙物（每 0.2 公尺檢查一次）
    public static func clear(_ a: VPoint, _ b: VPoint, _ obstacles: [VRect]) -> Bool {
        let n = max(1, Int(a.dist(b) / 0.2))
        for i in 0...n {
            let t = Double(i) / Double(n)
            let p = VPoint(a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t)
            if !VillageLayout.walkable(p, obstacles: obstacles, pad: 0.15) { return false }
        }
        return true
    }

    public static func length(_ pts: [VPoint]) -> Double {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + $1.0.dist($1.1) }
    }
}
