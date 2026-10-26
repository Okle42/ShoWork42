import Foundation

// 科技大樓剖面（10-20 Kang 拍板，規範 docs/design/office-tower/設計規範.md §3）：一層樓＝一個專案部門，樓層疊起來一起看。
//   一樓大廳（01，前台保全）→ 閒置薄層（多個沒人的專案壓成薄薄一層，只放門牌）→ 有 AI 的專案樓層（固定樓層號由下往上）→ 頂樓空中花園（RF）。
//   樓層號：第一次依最近 7 天用量排一次（第 1 名 02），之後寫進 board/tower.json 不再重排；新專案接在最後一號。
//   降樓：全部 AI 關掉後再 2 小時沒人，才降回閒置薄層（中間這 2 小時樓層留著、燈暗著）。
// 這裡只有純邏輯（可測）；讀檔、存檔、算用量在 ShoWorkAgent/TowerSource.swift。

/// 大樓尺寸（公尺）。10-20 第 2 棒 UI/UX 優化（docs/design/office-tower/UIUX優化規劃.md §3.1）：
/// 模組 16×7×3.6 → 12×5.6×2.9、角色放大到 1.6 倍（坐姿頭頂佔層高 ≥ 50%，ACCAI 那種比例）；閒置薄層只留 1 層 0.9。
public enum TowerSpec {
    public static let lobbyHeight = 4.4         // 一樓挑高（10-22 加深後段咖啡館：3.6 時預設 12° 俯角看後段的人頭會被上一層樓板切掉）
    public static let floorHeight = 2.9         // 專案樓層（樓板 0.25＋淨高 2.65）
    public static let idleHeight = 0.9          // 閒置薄層
    public static let roofHeight = 2.4          // 頂樓（樓板＋棚架 2.1）
    public static let width = 12.0, depth = 9.8 // 模組寬、深（10-22 Kang：5.6 太淺 ⇒ 8.4 ⇒ 再深一點 9.8；一樓後段做咖啡館休息區）
    public static let front = 2.8               // 模組前緣（玻璃面）z：加深只往後長，前面的家具、城市座標不動
    public static var back: Double { front - depth }   // 模組後緣 z
    public static var backInner: Double { back + 0.15 } // 後牆內側
    public static let slab = 0.25               // 樓板厚
    public static let platesPerIdle = 8         // （舊）一層薄層幾塊門牌；10-20 起薄層只畫一塊大門牌，名字在左側索引列
    public static let maxIdleLayers = 1         // 薄層只留 1 層（全部閒置專案收在同一層）
    public static let demoteAfter: TimeInterval = 2 * 3600   // 全部 AI 關掉後多久降樓
    public static let firstNumber = 2           // 專案樓層從 02 開始（01 是大廳）

    // 角色比例（純數字，畫面 OfficeBuilder 用同一組；測試量「坐姿頭頂／層高」）
    public static let kuboScale = 1.6           // 方塊 Kubo 放大倍數
    public static let seatTop = 0.56            // 椅面頂（離地坪）
    public static let kuboSeatedHead = 0.62     // 坐著時頭頂離椅面（縮放前）
    /// 坐姿頭頂離地坪幾公尺
    public static var seatedHead: Double { seatTop + kuboSeatedHead * kuboScale }
    /// 坐姿頭頂／層高（≥ 0.5 才像 ACCAI；舊版 0.37）
    public static var seatedHeadRatio: Double { seatedHead / floorHeight }

    /// 樓層號顯示：兩位數（02、11）
    public static func label(_ n: Int) -> String { String(format: "%02d", n) }
}

public enum TowerFloorKind: String, Codable, Sendable { case lobby, idle, project, roof }

/// 閒置薄層上的一塊門牌
public struct IdlePlate: Sendable, Equatable {
    public var name: String          // 專案名；溢出那塊是「+N」
    public var floorNo: String       // 固定樓層號（溢出那塊是空字串）
    public var accent: String?       // 上次的識別色（沒有＝畫 FN-4 暖灰）
    public var overflow = 0          // >0 ＝這塊是「+N」
    public init(name: String, floorNo: String, accent: String? = nil, overflow: Int = 0) {
        self.name = name; self.floorNo = floorNo; self.accent = accent; self.overflow = overflow
    }
}

/// 大樓的一層（由下往上排）
public struct TowerFloor: Sendable, Equatable, Identifiable {
    public var kind: TowerFloorKind
    public var id: String            // lobby、idle-0、idle-1…、p:<專案名小寫>、roof（搬家動畫用 id 對樓層）
    public var floorNo: String       // 01、05、RF；薄層是空字串
    public var project: String?      // 專案樓層的專案名（顯示用寫法）
    public var number: Int?          // 專案樓層的固定號碼
    public var active = false        // 現在有 AI（false＝2 小時緩衝中，燈暗著）
    public var seats = 0             // 桌子數＝實際 AI 數（排隊中的訊息不算）
    public var plates: [IdlePlate] = []   // 薄層的門牌
    public var y = 0.0               // 樓板底面高度
    public var height = 0.0

    public init(kind: TowerFloorKind, id: String, floorNo: String, project: String? = nil, number: Int? = nil,
                active: Bool = false, seats: Int = 0, plates: [IdlePlate] = [], y: Double = 0, height: Double = 0) {
        self.kind = kind; self.id = id; self.floorNo = floorNo; self.project = project; self.number = number
        self.active = active; self.seats = seats; self.plates = plates; self.y = y; self.height = height
    }

    public static func projectId(_ name: String) -> String { "p:" + name.lowercased() }
}

/// 樓層號名冊（存 board/tower.json）。鍵一律用專案名小寫（APFS 不分大小寫，跟 OfficeDepartments 同規則）
public struct TowerRegistry: Codable, Sendable, Equatable {
    public var numbers: [String: Int] = [:]      // 專案 → 固定樓層號（2 起）
    public var names: [String: String] = [:]     // 專案 → 顯示寫法
    public var lastSeen: [String: Date] = [:]    // 專案 → 最後一次「有 AI」的時間（只在有人進出時更新，不是每次刷新）
    public var active: [String] = []             // 上次看到有 AI 的專案（排序過，判斷進出用）
    public var rankedAt: Date?                   // 第一次排名的時間
    public var rankedBy: [String: Double] = [:]  // 第一次排名用的 7 天用量（MB；除錯用）
    public init() {}

    public var nextNumber: Int { max(TowerSpec.firstNumber, (numbers.values.max() ?? TowerSpec.firstNumber - 1) + 1) }
    public func number(_ project: String) -> Int? { numbers[project.lowercased()] }

    /// 沒有號碼的專案發號碼。名冊是空的（第一次）＝全部依 7 天用量排名（多的在前、一樣多照名稱）；
    /// 之後只把新專案接在最後（新的之間也照用量排），**不重排已經有號碼的**。`usage` 只在有新專案時才叫（鍵＝小寫）。
    /// 回傳有沒有發新號碼
    @discardableResult
    public mutating func assign(_ projects: [String], usage: () -> [String: Double], now: Date) -> Bool {
        var seen = Set<String>()
        let fresh = projects.filter { p in
            let k = p.lowercased()
            return numbers[k] == nil && seen.insert(k).inserted
        }
        guard !fresh.isEmpty else { return false }
        let u = usage()
        let first = numbers.isEmpty
        let ordered = fresh.sorted { a, b in
            let ua = u[a.lowercased()] ?? 0, ub = u[b.lowercased()] ?? 0
            return ua != ub ? ua > ub : ResidentProjects.order(a, b)
        }
        var n = nextNumber
        for p in ordered {
            let k = p.lowercased()
            numbers[k] = n; names[k] = p; n += 1
            if first, let x = u[k] { rankedBy[k] = (x * 10).rounded() / 10 }
        }
        if first { rankedAt = now }
        return true
    }

    /// 記錄誰有 AI：剛進來、剛離開的都把 lastSeen 設成現在（離開那一刻就是「最後一次有人」）。
    /// 上次存檔時還有人、這次沒人（例如 app 關掉重開）也算剛離開。回傳有沒有變
    @discardableResult
    public mutating func markActive(_ projects: Set<String>, now: Date) -> Bool {
        let now0 = Set(projects.map { $0.lowercased() })
        let was = Set(active)
        guard now0 != was else { return false }
        for k in now0.symmetricDifference(was) { lastSeen[k] = now }
        active = now0.sorted()
        return true
    }

    /// 這個專案還在樓上嗎：現在有 AI，或最後一次有人在 `demoteAfter` 之內
    public func isUp(_ project: String, now: Date, demoteAfter: TimeInterval = TowerSpec.demoteAfter) -> Bool {
        let k = project.lowercased()
        if active.contains(k) { return true }
        guard let t = lastSeen[k] else { return false }
        return now.timeIntervalSince(t) < demoteAfter
    }

    /// 什麼時候會降樓（給畫面排一次性的重算；沒有在緩衝中的就 nil）
    public func nextDemotion(now: Date, demoteAfter: TimeInterval = TowerSpec.demoteAfter) -> Date? {
        lastSeen.filter { !active.contains($0.key) && now.timeIntervalSince($0.value) < demoteAfter }
            .values.map { $0.addingTimeInterval(demoteAfter) }.min()
    }

    public static func decode(_ d: Data) -> TowerRegistry? { try? BoardJSON.decoder.decode(TowerRegistry.self, from: d) }
    public func encoded() -> Data? { try? BoardJSON.encoder.encode(self) }
}

/// 一次搬家：某個專案樓層出現、離開、或換了位置（第 3 棒播「飄出→升降→插回」用）
public struct TowerMove: Sendable, Equatable {
    public var project: String
    public var floorId: String
    public var fromIndex: Int?       // 舊清單裡的位置（nil＝原本在薄層）
    public var toIndex: Int?         // 新清單裡的位置（nil＝降到薄層）
    public var fromY: Double?
    public var toY: Double?
}

public struct TowerPlan: Sendable, Equatable {
    public var floors: [TowerFloor] = []          // 由下往上
    public init(floors: [TowerFloor] = []) { self.floors = floors }

    public var totalHeight: Double { floors.last.map { $0.y + $0.height } ?? 0 }
    public var projectFloors: [TowerFloor] { floors.filter { $0.kind == .project } }
    public var idlePlates: [IdlePlate] { floors.filter { $0.kind == .idle }.flatMap(\.plates) }
    public func floor(id: String) -> TowerFloor? { floors.first { $0.id == id } }
    public func floor(project: String) -> TowerFloor? { floor(id: TowerFloor.projectId(project)) }

    /// 組大樓。`departments`＝OfficeDepartments.build 的結果（常駐＋臨時，isActive＝有 AI）；`cards` 只拿來算桌子數；
    /// `registry` 會被更新（發新號碼、記錄進出），呼叫端看回傳的 `dirty` 決定要不要存檔；
    /// `accents`＝專案（小寫）→ 上次的識別色（薄層門牌色條用）。
    public static func build(departments: [OfficeDepartment], cards: [BoardCard], registry: inout TowerRegistry,
                             usage: () -> [String: Double], accents: [String: String] = [:],
                             now: Date) -> (plan: TowerPlan, dirty: Bool) {
        var dirty = registry.assign(departments.map(\.name), usage: usage, now: now)
        dirty = registry.markActive(Set(departments.filter(\.isActive).map(\.name)), now: now) || dirty
        // 10-20 第 4 棒：臨時部門（不在常駐名冊、只因為有 AI 才出現）AI 一關就從 departments 消失，原本樓層會立刻不見、
        // 沒有 2 小時緩衝 ⇒ 名冊裡還在緩衝中的補回來（燈暗著）；滿 2 小時就自然消失（臨時部門不進薄層）
        var departments = departments
        let listed = Set(departments.map { $0.name.lowercased() })
        for (k, _) in registry.lastSeen.sorted(by: { $0.key < $1.key }) where !listed.contains(k) && registry.isUp(k, now: now) {
            departments.append(OfficeDepartment(name: registry.names[k] ?? k, isResident: false, isActive: false))
        }
        var seats: [String: Int] = [:]
        for c in cards where !c.id.contains("#") { seats[c.project.lowercased(), default: 0] += 1 }

        let byNumber = departments.sorted { a, b in
            let na = registry.number(a.name) ?? Int.max, nb = registry.number(b.name) ?? Int.max
            return na != nb ? na < nb : ResidentProjects.order(a.name, b.name)
        }
        let up = byNumber.filter { $0.isActive || registry.isUp($0.name, now: now) }
        let idle = byNumber.filter { d in !up.contains { $0.name == d.name } }

        var floors: [TowerFloor] = []
        var y = 0.0
        func push(_ f: TowerFloor, _ h: Double) { var f = f; f.y = y; f.height = h; floors.append(f); y += h }
        push(TowerFloor(kind: .lobby, id: "lobby", floorNo: "01"), TowerSpec.lobbyHeight)
        // 10-20 UI/UX 優化：閒置薄層只留 1 層、全部閒置專案都放在這層（3D 只畫一塊大門牌，名字在左側索引列）
        let idlePlates = idle.map { d in
            IdlePlate(name: d.name, floorNo: registry.number(d.name).map(TowerSpec.label) ?? "", accent: accents[d.name.lowercased()])
        }
        if !idlePlates.isEmpty {
            push(TowerFloor(kind: .idle, id: "idle-0", floorNo: "", plates: idlePlates), TowerSpec.idleHeight)
        }
        for d in up {
            let n = registry.number(d.name)
            push(TowerFloor(kind: .project, id: TowerFloor.projectId(d.name), floorNo: n.map(TowerSpec.label) ?? "",
                            project: d.name, number: n, active: d.isActive, seats: seats[d.name.lowercased()] ?? 0),
                 TowerSpec.floorHeight)
        }
        push(TowerFloor(kind: .roof, id: "roof", floorNo: "RF"), TowerSpec.roofHeight)
        return (TowerPlan(floors: floors), dirty)
    }

    /// 門牌分層：一層 perLayer 塊、最多 maxLayers 層；超過時最後一塊改成「+N」（N＝沒畫出來的數量）。
    /// 10-20 起大樓只用 1 層薄層（build 不再呼叫這個）；留著給舊版門牌條排版用
    public static func idleLayers(_ plates: [IdlePlate], perLayer: Int = TowerSpec.platesPerIdle,
                                  maxLayers: Int = 3) -> [[IdlePlate]] {
        guard !plates.isEmpty else { return [] }
        let cap = perLayer * maxLayers
        var list = plates
        if list.count > cap {
            let hidden = list.count - (cap - 1)
            list = Array(list.prefix(cap - 1)) + [IdlePlate(name: "+\(hidden)", floorNo: "", overflow: hidden)]
        }
        return stride(from: 0, to: list.count, by: perLayer).map { Array(list[$0..<min($0 + perLayer, list.count)]) }
    }

    /// 兩個版本之間的搬家：專案樓層出現／離開／換位置（index 是 floors 裡的位置）。
    /// 只因為下面多一層或少一層而被推上推下的（相對順序沒變）不算搬家，那是「讓位」
    public static func moves(from old: TowerPlan, to new: TowerPlan) -> [TowerMove] {
        let a = old.projectFloors.map(\.id), b = new.projectFloors.map(\.id)
        let common = a.filter { b.contains($0) }
        let commonNew = b.filter { a.contains($0) }
        var out: [TowerMove] = []
        for f in new.projectFloors {
            let oi = old.floors.firstIndex { $0.id == f.id }, ni = new.floors.firstIndex { $0.id == f.id }
            let reordered = oi != nil && common.firstIndex(of: f.id) != commonNew.firstIndex(of: f.id)
            if oi == nil || reordered {
                out.append(TowerMove(project: f.project ?? f.id, floorId: f.id, fromIndex: oi, toIndex: ni,
                                     fromY: oi.map { old.floors[$0].y }, toY: f.y))
            }
        }
        for f in old.projectFloors where new.floor(id: f.id) == nil {
            out.append(TowerMove(project: f.project ?? f.id, floorId: f.id, fromIndex: old.floors.firstIndex { $0.id == f.id },
                                 toIndex: nil, fromY: f.y, toY: nil))
        }
        return out
    }
}

// MARK: - 最近 7 天用量（排樓層號用）

/// 便宜的估法（10-20 取捨）：`~/.claude/projects/<slug>/*.jsonl` 裡**最近 7 天內有改過**的對話紀錄，加總檔案大小（MB）。
/// slug＝啟動 cwd 換字元（`SessionRecord.projectSlug`）；一個資料夾歸給「slug 前綴最長」的專案（ProjectA-w1 有自己的部門就歸它，
/// 沒有就歸 ProjectA）。不讀檔內容、不開 git，只 stat。
/// 不準的地方：①檔案大小是整個對話累計，不是 7 天內的量（長壽 session 會偏高）；②在家目錄啟動再 cd 進專案的 session 算不到；
/// ③讀圖的行很大，圖多的專案偏高。只用來排一次樓層號，夠用；要精準得掃 token（TokenTally 要讀整個檔，太貴）。
public enum ProjectUsage {
    public static let window: TimeInterval = 7 * 86400

    /// `projects`：專案名 → 它的資料夾路徑（可以多個，例如常駐的 ~/github-repos/X 與臨時部門卡片的 cwd）
    public static func scan(projectsDir: String, projects: [String: [String]], now: Date, window: TimeInterval = window) -> [String: Double] {
        let fm = FileManager.default
        // slug → 專案（小寫）；比對時取最長前綴
        var slugs: [(slug: String, key: String)] = []
        for (name, paths) in projects {
            for p in paths { slugs.append((SessionRecord(pid: 0, sessionId: "", cwd: p).projectSlug, name.lowercased())) }
        }
        slugs.sort { $0.slug.count > $1.slug.count }
        var out: [String: Double] = [:]
        for dir in (try? fm.contentsOfDirectory(atPath: projectsDir)) ?? [] {
            guard let hit = slugs.first(where: { dir == $0.slug || dir.hasPrefix($0.slug + "-") }) else { continue }
            let path = projectsDir + "/" + dir
            for f in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where f.hasSuffix(".jsonl") {
                guard let a = FileStat.lstat(path + "/" + f), now.timeIntervalSince(a.date) <= window else { continue }
                let size = Double(a.size)
                out[hit.key, default: 0] += size / 1_048_576
            }
        }
        return out
    }
}
