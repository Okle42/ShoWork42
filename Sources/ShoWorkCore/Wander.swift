import Foundation

// 角色閒晃（10-20，規範 §4）：決定每個角色現在待哪（自己的桌、同層茶水角、拜訪別層、頂樓花園）、要不要出發、走哪條路。
//   純邏輯、可重現：隨機數用「session id＋15 秒時段」當種子（同一個時段重算幾次結果都一樣）。
//   不新增 timer：只在看板既有的刷新（FSEvents／15 秒保底）時呼叫。每次最多出發 1 人、全棟同時最多 3 人在路上。
//   狀態優先：等你回答一定在桌前（直接瞬移回來，不播）；工作中／卡住／還沒交代過事的回座位；休息的上頂樓、一樓咖啡館或地下室 B1 看神經網路（下雨不上頂樓）；只有「做完了你還沒看」的會隨機閒晃。
// 路線是預先算好的折線節點（模組本地座標＋樓層 id），畫面照節點時間插值，不做尋路、不做碰撞。

/// 角色現在（或這趟走完之後）待的地方
public enum WanderSpot: Sendable, Hashable, Codable {
    case desk                                     // 自己樓層的座位
    case lounge(slot: Int)                        // 自己樓層前帶（F1／F3）
    case visit(floor: String, host: String)       // 拜訪別層：floor＝樓層 id，host＝對方 session id
    case roof(slot: Int)                          // 頂樓花園站位
    case cafe(slot: Int)                          // 一樓後段咖啡館站位（10-22 Kang：下雨不該在頂樓喝咖啡）
    case b1(slot: Int)                            // 地下室 B1 機房：圍著投影台看神經網路（10-22 Kang：員工也可以搭電梯到 B1 看神經網路）

    public var isDesk: Bool { self == .desk }
    public var isRoof: Bool { if case .roof = self { return true }; return false }
    public var isCafe: Bool { if case .cafe = self { return true }; return false }
    public var isB1: Bool { if case .b1 = self { return true }; return false }
    /// 室內休息點（咖啡館、B1）：下雨也待得住
    public var isIndoorRest: Bool { isCafe || isB1 }
}

/// 路線上的一個點：抵達這個點的方式＋從出發算起第幾秒抵達
public struct WanderNode: Sendable, Equatable {
    public enum Move: String, Sendable { case start, walk, elevator, slide, teleport, wait }
    public var floor: String            // TowerFloor.id（模組本地座標；搬家時跟著模組走）
    public var x: Double
    public var z: Double
    public var move: Move
    public var t: Double
    public var car: Int?                // 搭哪一部電梯（move == .elevator 才有；10-22 兩部電梯）
    public init(floor: String, x: Double, z: Double, move: Move, t: Double, car: Int? = nil) {
        self.floor = floor; self.x = x; self.z = z; self.move = move; self.t = t; self.car = car
    }
}

/// 電梯車廂的一段移動（秒＝從行程出發算起）：空車先開到搭乘樓層、再載人到目的層，畫面照這個播車廂（10-22 Kang：搭電梯不要破圖）
public struct WanderCarMove: Sendable, Equatable {
    public var car: Int
    public var from: String              // 樓層 id
    public var to: String
    public var start: Double
    public var end: Double
    public init(car: Int, from: String, to: String, start: Double, end: Double) {
        self.car = car; self.from = from; self.to = to; self.start = start; self.end = end
    }
}

/// 一部電梯現在停在哪、到什麼時候有人在用（排程用；下一次刷新帶回來）
public struct WanderCar: Sendable, Equatable {
    public var floor: String
    public var freeAt: Date
    public init(floor: String, freeAt: Date) { self.floor = floor; self.freeAt = freeAt }
}

/// 一趟行程（拜訪／茶水角是來回一趟，含中間停留；上頂樓、回座位是單程）
public struct WanderTrip: Sendable, Equatable {
    public var sid: String
    public var start: Date
    public var nodes: [WanderNode]
    public var dest: WanderSpot          // 這趟的目的地（停留的地方）
    public var final: WanderSpot         // 走完之後待哪（來回的＝.desk）
    public var carMoves: [WanderCarMove] = []   // 這趟用到的電梯車廂移動（含空車去接人）
    public var duration: Double { nodes.last?.t ?? 0 }
    public var end: Date { start.addingTimeInterval(duration) }

    /// 第 t 秒在哪（畫面在視窗重新可見、或測試 instant 模式時直接定位用）。電梯／溜滑梯中途回傳出發那層（畫面自己決定怎麼畫車廂）
    public func position(at t: Double) -> (floor: String, x: Double, z: Double) {
        guard let first = nodes.first else { return ("", 0, 0) }
        if t <= first.t { return (first.floor, first.x, first.z) }
        for (a, b) in zip(nodes, nodes.dropFirst()) where t < b.t {
            if a.floor != b.floor || b.move == .teleport { return (a.floor, a.x, a.z) }
            let k = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1
            return (a.floor, a.x + (b.x - a.x) * k, a.z + (b.z - a.z) * k)
        }
        let l = nodes[nodes.count - 1]
        return (l.floor, l.x, l.z)
    }

    /// 停留開始的時間（instant 模式截圖：直接放到目的地）。電梯門口等車的 .wait 不算停留
    public var arriveAt: Double {
        guard let w = nodes.firstIndex(where: { $0.move == .wait && TowerLayout.doorIndex($0.x, $0.z) == nil }), w > 0 else { return duration }
        return nodes[w - 1].t
    }
}

public struct WanderState: Sendable, Equatable {
    public var spot: WanderSpot          // 行程走完之後待哪
    public var trip: WanderTrip?         // 進行中的行程（走完就清掉）
    public init(spot: WanderSpot, trip: WanderTrip? = nil) { self.spot = spot; self.trip = trip }
    public func moving(at now: Date) -> Bool { trip.map { now < $0.end } ?? false }
}

/// 一個角色（畫面那邊從 Islands／卡片組出來）
public struct WanderPerson: Sendable, Equatable {
    public var sid: String
    public var floor: String             // 自己樓層的 TowerFloor.id
    public var mood: Mood
    public var seat: Int                 // 座位序號（同層依卡片 id 排）
    public var seats: Int                // 同層幾個座位
    public init(sid: String, floor: String, mood: Mood, seat: Int, seats: Int) {
        self.sid = sid; self.floor = floor; self.mood = mood; self.seat = seat; self.seats = seats
    }
}

public enum WanderMode: String, Sendable { case animate, instant, off }

public struct WanderPlan: Sendable, Equatable {
    public var states: [String: WanderState] = [:]
    public var started: [WanderTrip] = []    // 這次刷新新出發的（畫面要播）
    public var snapped: [String] = []        // 這次直接瞬移的（畫面直接放到 spot，不播）
    public var cars: [WanderCar] = []        // 兩部電梯的狀態（下一次 plan 傳回來）
    public init(states: [String: WanderState] = [:], started: [WanderTrip] = [], snapped: [String] = []) {
        self.states = states; self.started = started; self.snapped = snapped
    }
    public var movingCount: Int { states.values.filter { $0.trip != nil }.count }
}

/// 樓層內的座標（模組本地）。10-20 UI/UX 優化（UIUX優化規劃.md §3.1）：模組 12×5.6；
/// x：左端電梯門 −6…−5.3、協作區 −5.3…−2.3、工作區 −2.3…2.5、休憩角 2.5…5.3、右端 5.3…6；
/// z：後帶 −2.8…−1.75、中帶（桌子）−1.75…1.1、前帶（走道、矮家具）1.1…2.8。
public enum TowerLayout {
    public static let aisleZ = 1.45
    public static let elevatorDoor = (x: -5.7, z: -1.3)
    public static let elevator = (x: -7.05, z: -1.3)
    /// 兩部電梯（10-22 Kang）：車廂中心、各層電梯門口；第 0 部＝原本那部（elevator／elevatorDoor）
    public static let elevators: [(x: Double, z: Double)] = [(-7.05, -1.3), (-7.05, -2.9)]
    public static let elevatorDoors: [(x: Double, z: Double)] = [(-5.7, -1.3), (-5.7, -2.9)]
    /// 這個點是第幾部電梯的門口（不是門口 ⇒ nil）：分辨「門口等車」的 .wait 和目的地的停留
    public static func doorIndex(_ x: Double, _ z: Double) -> Int? {
        elevatorDoors.firstIndex { abs($0.x - x) < 1e-6 && abs($0.z - z) < 1e-6 }
    }
    public static let slideDoor = (x: 5.5, z: TowerSpec.back + 0.55)   // 後牆右端的門（溜滑梯在後牆後面）
    public static let slideTop = (x: 5.4, z: TowerSpec.back + 0.5)     // 頂樓溜滑梯入口
    public static let lounge: [(x: Double, z: Double)] = [(3.0, 1.1), (4.5, 0.9)]   // 休憩角（單人椅後面、落地燈旁）
    /// 椅子（角色）在桌子後方幾公尺（角色放大 1.6 倍：身體深 0.8，0.62 會穿進桌子）
    public static let chairBack = 0.72
    /// 後段走道（前組桌的人 z −1.02、後組桌的人 z −2.18 之間）：座位在 z < 0 的人走這條去電梯，前面的人走 aisleZ
    public static let backAisleZ = -1.6

    /// 自由座（10-22 Kang：員工不用全部面向鏡頭、辦公室不要那麼死板；加深的後段要用上，各自有各自的位置）：x、z＝桌心，a＝人面向（0＝面向鏡頭 +z、π＝背對、−π/2＝面向左牆、π/2＝面向右牆）。
    /// 桌位有：前組／後組各一組面對面四人桌、左右側牆各兩張單人桌。排序是「先分散」：人少的時候一人一區（前、後、右牆、左牆），人多了才併桌
    public static let freeDesks: [(x: Double, z: Double, a: Double)] = [
        (-0.7, -0.3, 0), (-1.5, -4.3, 0), (2.6, -2.6, .pi / 2), (-4.4, -4.6, -.pi / 2),     // 一人一區：前、後、右牆、左牆
        (-0.7, 0.4, .pi), (-1.5, -3.6, .pi), (0.9, -0.3, 0), (0.1, -4.3, 0),               // 併桌：前組、後組
        (2.6, -4.4, .pi / 2), (-4.4, -3.0, -.pi / 2), (0.9, 0.4, .pi), (0.1, -3.6, .pi)]

    /// 每層從不同的區開始坐（10-22 Kang：每層第一個人都在同一個位置，往上看疊成一直排、很死板）：
    /// 用樓層 id 雜湊出 0–3 的位移，每 4 張一組各自輪轉（同一層永遠一樣，不會每次刷新換座位）
    public static func spin(_ floor: String) -> Int {
        guard !floor.isEmpty else { return 0 }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in floor.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
        return Int(h % 4)
    }
    /// 桌心位置與朝向（12 張以內）；floor＝樓層 id（決定這層從哪一區開始坐）
    public static func desk(_ i: Int, of n: Int, floor: String = "") -> (x: Double, z: Double, a: Double) {
        let i = min(max(i, 0), freeDesks.count - 1), k = spin(floor)
        return freeDesks[i / 4 * 4 + (i % 4 + k) % 4]
    }

    /// 角色坐的位置（桌子後方 chairBack，順著朝向）。13 個以上：多的站前帶（z 2.2，間距 1.0，面向鏡頭）
    public static func seat(_ i: Int, of n: Int, floor: String = "") -> (x: Double, z: Double, a: Double) {
        if i >= 12 {
            let k = i - 12, m = n - 12
            return (0.1 + (Double(k) - Double(m - 1) / 2) * 1.0, 2.2, 0)
        }
        let d = desk(i, of: min(n, 12), floor: floor)
        return (d.x - chairBack * sin(d.a), d.z - chairBack * cos(d.a), d.a)
    }

    /// 從座位走到走道前先繞開自己的桌子：側牆桌先往房間中間退 0.7；後組面向鏡頭的人（桌子擋在前面）往桌子外側繞 1.0
    public static func exitX(_ s: (x: Double, z: Double, a: Double)) -> Double? {
        if abs(sin(s.a)) > 0.5 { return s.x - 0.7 * sin(s.a) }
        if cos(s.a) > 0.5, s.z < backAisleZ - 1 { return s.x < -0.7 ? s.x - 1.1 : s.x + 0.9 }
        return nil
    }
    /// 座位 → 走道的折線（不含座位本身）；回座位時倒過來走
    public static func toAisle(_ s: (x: Double, z: Double, a: Double)) -> [(x: Double, z: Double)] {
        let z = aisle(s)
        if let x = exitX(s) { return [(x, s.z), (x, z)] }
        return [(s.x, z)]
    }

    /// 這個座位去電梯／回座位走哪條走道（z）
    public static func aisle(_ s: (x: Double, z: Double, a: Double)) -> Double { s.z < 0 ? backAisleZ : aisleZ }

    /// 角色站著的身體範圍：寬 1.55（含手）、深 0.82（10-22 實測包圍盒）⇒ 站位左右至少隔 1.7、離家具前緣 0.45，不然人疊人、插進沙發
    /// 頂樓 7 個休息站位（長椅前 2、咖啡吧前 2、棚架下 3），多的排在植栽槽前
    public static func roofSlot(_ i: Int) -> (x: Double, z: Double) {
        let fixed: [(Double, Double)] = [(-4.4, 1.1), (-2.7, 1.1),                    // 長椅前
                                         (2.4, 0.65), (4.1, 0.65),                    // 咖啡吧前
                                         (-1.0, 0.1), (0.7, 0.2), (-0.2, 1.55)]       // 棚架下
        if i < fixed.count { return fixed[i] }
        let k = i - fixed.count
        return (-4.6 + Double(k % 6) * 1.75, -1.4)
    }

    /// 一樓咖啡館（大樓後段 z −5.45…−2.8，10-22 加深）：從電梯門往後走到這條走道再橫過去
    public static var cafeWalkZ: Double { TowerSpec.backInner + 2.15 }
    public static let cafeEntryX = -5.0
    /// 咖啡館 6 個站位（沙發前 2、吧台前 2、立食桌兩側 2），多的排在走道；a＝面向（0＝面向鏡頭、π＝背對）
    public static func cafeSlot(_ i: Int) -> (x: Double, z: Double, a: Double) {
        // z 都從後牆內側（bz）算：沙發前緣 bz+0.85、吧台前緣 bz+0.8、立食桌 bz+1.15
        let bz = TowerSpec.backInner
        let fixed: [(Double, Double, Double)] = [(-4.4, bz + 1.4, 0), (-2.65, bz + 1.4, 0),           // 沙發前
                                                 (2.05, bz + 1.3, .pi), (3.8, bz + 1.3, .pi),          // 吧台前（背對鏡頭看咖啡師）
                                                 (-0.95, bz + 1.7, 0.4), (0.95, bz + 1.7, -0.4)]       // 立食桌兩側
        if i < fixed.count { return fixed[i] }
        let k = i - fixed.count
        return (-4.4 + Double(k % 3) * 1.75, bz + 2.45, 0)
    }

    // MARK: 地下室 B1（10-22 Kang：員工也可以搭電梯到 B1 看神經網路）

    /// B1 的樓層 id（TowerPlan 裡沒有這層：B1 不算樓層號、不搬家，固定在大廳正下方）
    public static let b1Floor = "b1"
    /// B1 地坪（世界 y）。⚠ 要跟 ShoWorkAgent/OfficeBasement.floorY 同步（畫面那邊的常數，Core 讀不到）
    public static let b1Y = -5.6
    /// B1 模組原點（樓板底，跟 TowerFloor.y 同一種量法：地坪＝原點＋樓板＋0.01）
    public static var b1Origin: Double { b1Y - TowerSpec.slab - 0.01 }
    /// 圖譜中心（模組本地 x、z）：機房正中間（＝OfficeBasement.graphCenter；模組 z 中線）
    public static var b1Center: (x: Double, z: Double) { (0, TowerSpec.front - TowerSpec.depth / 2) }
    /// 內圈半徑（圖譜半徑 2.2 外面一點，看得到整團）、外圈半徑、繞行半徑（兩圈中間）
    public static let b1Ring = 3.0, b1Outer = 4.1, b1WalkR = 3.55
    /// 從電梯門口進機房先走到這條線（x）再繞圈：左牆機櫃讓出來的門口空地
    public static let b1EntryX = -4.6

    /// 站位的角度 φ（弧度）：0＝圖譜正後方（z 小，人面向鏡頭看圖譜）、±π/2＝左右兩側、π＝前方（擋鏡頭，最後才站）。
    /// 內圈 8 個（間距 2.3）；外圈 6 個只在兩側和前方（後方離機櫃不到 1 公尺、左邊 φ−π/2 是電梯門口的走道），跟內圈錯開半格、站位互相隔 1.7 以上
    static let b1Inner: [Double] = [0, -0.25, 0.25, -0.5, 0.5, -0.75, 0.75, 1].map { $0 * .pi }
    static let b1OuterAngles: [Double] = [0.375, -0.375, 0.625, -0.625, 0.875, -0.875].map { $0 * .pi }
    /// 前帶兩個角落（玻璃前、兩側機櫃前；外圈前方站位的外側）：第 15、16 個人
    static let b1Front: [(x: Double, z: Double)] = [(-3.5, 2.35), (3.5, 2.35)]
    /// 第 i 個站位在哪個角度、哪個半徑；nil＝前帶角落（b1Front）。
    /// 超過 16 人（極少見）：站到兩圈中間（外圈的角度、繞行半徑），會跟旁邊的人擠在一起
    static func b1Polar(_ i: Int) -> (phi: Double, r: Double)? {
        if i < b1Inner.count { return (b1Inner[i], b1Ring) }
        let k = i - b1Inner.count
        if k < b1OuterAngles.count { return (b1OuterAngles[k], b1Outer) }
        let f = k - b1OuterAngles.count
        if f < b1Front.count { return nil }
        return (b1OuterAngles[(f - b1Front.count) % b1OuterAngles.count], b1WalkR)
    }
    /// 總共幾個不擠的站位
    public static var b1Capacity: Int { b1Inner.count + b1OuterAngles.count + b1Front.count }
    /// 圓上的點（φ 的定義同上）
    static func b1Point(_ phi: Double, _ r: Double) -> (x: Double, z: Double) {
        let c = b1Center
        return (c.x + r * sin(phi), c.z - r * cos(phi))
    }
    /// B1 站位：x、z（模組本地）＋a＝面向（一律面向圖譜中心）
    public static func b1Slot(_ i: Int) -> (x: Double, z: Double, a: Double) {
        let c = b1Center
        let p: (x: Double, z: Double)
        if let pr = b1Polar(max(0, i)) { p = b1Point(pr.phi, pr.r) }
        else { p = b1Front[(max(0, i) - b1Inner.count - b1OuterAngles.count) % b1Front.count] }
        return (p.x, p.z, atan2(c.x - p.x, c.z - p.z))
    }
    /// 電梯門口 → 站位的折線（不含門口）：先走到門口空地，沿繞行圈（兩圈中間）繞到站位那個角度，再往內／外一步到站位。
    /// 不從中間直穿（中間是投影台、上面浮著圖譜）；要繞半圈以上時走前方（前帶比後方機櫃前寬）
    public static func b1Route(_ i: Int, door d: (x: Double, z: Double)) -> [(x: Double, z: Double)] {
        let s = b1Slot(i)
        var out: [(x: Double, z: Double)] = [(b1EntryX, d.z)]
        guard let pr = b1Polar(max(0, i)) else {
            // 前帶角落：從門口空地往前走到前帶再橫過去
            return out + [(b1EntryX, s.z), (s.x, s.z)]
        }
        let a0 = -Double.pi / 2
        var delta = pr.phi - a0
        while delta >= .pi - 1e-9 { delta -= 2 * .pi }       // 正好對面（φ＝π/2）⇒ 往負方向繞（經過前方）
        while delta < -.pi - 1e-9 { delta += 2 * .pi }
        let steps = max(1, Int((abs(delta) / (.pi / 6)).rounded(.up)))
        for k in 0...steps { out.append(b1Point(a0 + delta * Double(k) / Double(steps), b1WalkR)) }
        out.append((s.x, s.z))
        return out
    }
}

public enum WanderPlanner {
    public static let departP = 0.125            // 每次刷新出發機率（15 秒一次 ⇒ 平均每人 2 分鐘一趟；10-23 Kang 嫌死板，原 0.0625＝4 分鐘）
    public static let maxMoving = 3              // 全棟同時在路上
    public static let maxDepartPerTick = 1       // 每次刷新最多隨機出發幾人
    public static let walkSpeed = 1.1            // m/s
    public static let elevatorSpeed = 2.4        // m/s
    public static let slidePerFloor = 1.2        // 秒／層
    /// 電梯／溜滑梯那一段超過這麼久就換成瞬移（10-20 第 2 棒調整：規範寫「單程超過 20 秒」，但光走路 座位→左門＋電梯口→站位
    /// 就約 17 秒，照字面幾乎每趟電梯都會變瞬移；改成只看垂直那段，12 秒 ≈ 電梯 8 層、溜滑梯 10 層，貼近規範「例如 10 層以上」的意思）
    public static let maxRide = 12.0
    public static let bucket: TimeInterval = 15  // 隨機種子的時段長度
    public static let stagger: TimeInterval = 2.5 // 同層同時出發：每人錯開幾秒（出發前站在原地）

    // MARK: 可重現的亂數

    /// FNV-1a 64 → SplitMix64 → [0, 1)
    public static func rand(_ sid: String, _ slot: Int, _ salt: String) -> Double {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in "\(sid)|\(slot)|\(salt)".utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
        h &+= 0x9E37_79B9_7F4A_7C15
        var z = h
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    // MARK: 決策

    /// `previous`＝上次的 states；`visible`＝視窗看得到（被蓋住／縮小就 false：不出發、進行中的直接落地）
    /// 休息去哪：每個人固定偏好（不會每次刷新換來換去）。晴天三選一：頂樓／一樓咖啡館／地下室 B1 各約三分之一；
    /// 下雨（或沒有頂樓）不上頂樓：偏好咖啡館、B1 的照舊，偏好頂樓的改去他固定的室內點（咖啡館或 B1 一半一半）。
    /// B1 在大廳正下方、從大廳的電梯下去 ⇒ 有大廳才有 B1（`cafe`＝有大廳）
    static func restSpot(_ p: WanderPerson, rain: Bool, roof: Bool, cafe: Bool) -> WanderSpot? {
        let b1 = cafe
        let pref = min(2, Int(rand(p.sid, 0, "rest3") * 3))      // 0 頂樓、1 咖啡館、2 B1
        let indoor: WanderSpot? = !cafe ? nil
            : pref == 1 ? .cafe(slot: -1) : pref == 2 ? .b1(slot: -1)
            : rand(p.sid, 0, "indoor") < 0.5 ? .cafe(slot: -1) : .b1(slot: -1)
        if rain || !roof { return indoor }
        if pref == 0 || !b1 { return .roof(slot: -1) }
        return indoor
    }

    /// `rain`＝現在下雨（休息的人不上頂樓、已經在頂樓的下到偏好的室內點：一樓咖啡館或 B1）
    /// `cars`＝上一次 plan 的 `WanderPlan.cars`（兩部電梯停哪、何時有空；沒給＝都停一樓、現在有空）
    public static func plan(people: [WanderPerson], tower: TowerPlan, previous: [String: WanderState], now: Date,
                            visible: Bool = true, mode: WanderMode = .animate, rain: Bool = false,
                            cars: [WanderCar] = []) -> WanderPlan {
        let slot = Int(now.timeIntervalSince1970 / bucket)
        var out = WanderPlan()
        let roof = tower.floor(id: "roof"), lobby = tower.floor(id: "lobby")
        func rest(_ p: WanderPerson) -> WanderSpot? { restSpot(p, rain: rain, roof: roof != nil, cafe: lobby != nil) }
        // 1. 舊狀態：走完的清掉；人不在了就丟掉；看不到／關掉閒晃 ⇒ 進行中的直接落地
        for p in people {
            var s = previous[p.sid] ?? WanderState(spot: p.mood == .idle ? rest(p) ?? .desk : .desk)
            if let t = s.trip, now >= t.end || !visible || mode == .off { s.trip = nil; if now < t.end { out.snapped.append(p.sid) } }
            // 拜訪的對象樓層不在了（降樓）⇒ 直接回座位
            if case .visit(let f, _) = s.spot, tower.floor(id: f) == nil { s = WanderState(spot: .desk); out.snapped.append(p.sid) }
            out.states[p.sid] = s
        }
        // 頂樓站位：先保留已經在頂樓的，-1（新來的）之後再發
        var roofTaken = Set(out.states.values.compactMap { s -> Int? in if case .roof(let i) = s.spot, i >= 0 { return i }; return nil })
        func freeRoofSlot() -> Int { var i = 0; while roofTaken.contains(i) { i += 1 }; roofTaken.insert(i); return i }
        var cafeTaken = Set(out.states.values.compactMap { s -> Int? in if case .cafe(let i) = s.spot, i >= 0 { return i }; return nil })
        func freeCafeSlot() -> Int { var i = 0; while cafeTaken.contains(i) { i += 1 }; cafeTaken.insert(i); return i }
        var b1Taken = Set(out.states.values.compactMap { s -> Int? in if case .b1(let i) = s.spot, i >= 0 { return i }; return nil })
        func freeB1Slot() -> Int { var i = 0; while b1Taken.contains(i) { i += 1 }; b1Taken.insert(i); return i }
        for p in people.sorted(by: { $0.sid < $1.sid }) {
            if case .roof(let i) = out.states[p.sid]!.spot, i < 0 { out.states[p.sid]!.spot = .roof(slot: freeRoofSlot()) }
            if case .cafe(let i) = out.states[p.sid]!.spot, i < 0 { out.states[p.sid]!.spot = .cafe(slot: freeCafeSlot()) }
            if case .b1(let i) = out.states[p.sid]!.spot, i < 0 { out.states[p.sid]!.spot = .b1(slot: freeB1Slot()) }
        }
        var moving = out.states.values.filter { $0.moving(at: now) }.count
        let canAnimate = visible && mode != .off
        // 10-20 第 4 棒：同一次刷新、同一層一起出發的人（例如三個人同時變休息）走同一條走道會疊成一團 ⇒ 第 2、3 個晚 stagger 秒出發
        var sameFloor: [String: Int] = [:]
        // 電梯：播不了（看不到／關掉）⇒ 路上的都落地了，車廂也當作現在有空
        var cars = initialCars(cars, now: now)
        if !canAnimate { for c in cars.indices where cars[c].freeAt > now { cars[c].freeAt = now } }
        out.cars = cars
        /// 排電梯＋組成行程（依呼叫順序排，同一次刷新的行程不會搶同一部車）
        func makeTrip(_ sid: String, start: Date, dest: WanderSpot, final: WanderSpot, route: (Int) -> [WanderNode]) -> WanderTrip {
            let s = schedule(start: start, cars: &cars, tower: tower, build: route)
            out.cars = cars
            var t = WanderTrip(sid: sid, start: start, nodes: s.nodes, dest: dest, final: final)
            t.carMoves = s.moves
            return t
        }

        /// 發一趟行程；超過同時上限或不能播 ⇒ 直接瞬移到 final。`route(c)`＝走第 c 部電梯的路線（instant 模式＝nil）
        func go(_ p: WanderPerson, to dest: WanderSpot, final: WanderSpot, route: ((Int) -> [WanderNode])?) {
            if canAnimate, moving < maxMoving, let route, case let nodes = route(0), nodes.count > 1 {
                let from = nodes[0].floor, k = sameFloor[from, default: 0]
                sameFloor[from] = k + 1
                let trip = makeTrip(p.sid, start: now.addingTimeInterval(Double(k) * stagger), dest: dest, final: final, route: route)
                out.states[p.sid] = WanderState(spot: final, trip: trip)
                out.started.append(trip)
                moving += 1
            } else {
                out.states[p.sid] = WanderState(spot: final)
                out.snapped.append(p.sid)
            }
        }

        // 2. 狀態優先的必走（不受機率限制，但受同時 3 人限制）
        for p in people.sorted(by: { $0.sid < $1.sid }) {
            let s = out.states[p.sid]!
            switch p.mood {
            case .waiting:
                // 等你回答：一定在桌前。正在路上（含來回趟）也直接拉回
                if !s.spot.isDesk || s.trip != nil {
                    out.states[p.sid] = WanderState(spot: .desk)
                    if !out.snapped.contains(p.sid) { out.snapped.append(p.sid) }
                }
            case .working, .stuck, .asleep:
                guard s.trip == nil, !s.spot.isDesk else { break }      // 在路上的（來回趟）走完自然回座位
                if case .roof(let i) = s.spot {
                    roofTaken.remove(i)
                    go(p, to: .desk, final: .desk, route: mode == .instant ? nil : { _ in fromRoof(p, slot: i, tower: tower) })
                } else if case .cafe(let i) = s.spot {
                    cafeTaken.remove(i)
                    go(p, to: .desk, final: .desk, route: mode == .instant ? nil : { fromCafe(p, slot: i, tower: tower, car: $0) })
                } else if case .b1(let i) = s.spot {
                    b1Taken.remove(i)
                    go(p, to: .desk, final: .desk, route: mode == .instant ? nil : { fromB1(p, slot: i, tower: tower, car: $0) })
                } else {
                    out.states[p.sid] = WanderState(spot: .desk); out.snapped.append(p.sid)
                }
            case .idle:
                guard s.trip == nil else { break }
                if case .roof(let i) = s.spot {
                    // 下雨了（或頂樓不在了）：頂樓的人搭電梯下到他偏好的室內點（一樓咖啡館或 B1）
                    guard rain || roof == nil, lobby != nil, let r = rest(p) else { break }
                    roofTaken.remove(i)
                    if r.isB1 {
                        let j = freeB1Slot()
                        go(p, to: .b1(slot: j), final: .b1(slot: j), route: mode == .instant ? nil : { roofToB1(slot: i, b1: j, tower: tower, car: $0) })
                    } else {
                        let j = freeCafeSlot()
                        go(p, to: .cafe(slot: j), final: .cafe(slot: j), route: mode == .instant ? nil : { roofToCafe(slot: i, cafe: j, tower: tower, car: $0) })
                    }
                    break
                }
                guard !s.spot.isIndoorRest, let r = rest(p) else { break }
                if r.isCafe {
                    let i = freeCafeSlot()
                    go(p, to: .cafe(slot: i), final: .cafe(slot: i), route: mode == .instant ? nil : { toCafe(p, slot: i, tower: tower, car: $0) })
                } else if r.isB1 {
                    let i = freeB1Slot()
                    go(p, to: .b1(slot: i), final: .b1(slot: i), route: mode == .instant ? nil : { toB1(p, slot: i, tower: tower, car: $0) })
                } else {
                    let i = freeRoofSlot()
                    go(p, to: .roof(slot: i), final: .roof(slot: i), route: mode == .instant ? nil : { toRoof(p, slot: i, tower: tower, car: $0) })
                }
            case .finished:
                guard s.trip == nil else { break }
                if case .roof(let i) = s.spot {        // 從休息變成做完：回座位
                    roofTaken.remove(i)
                    go(p, to: .desk, final: .desk, route: mode == .instant ? nil : { _ in fromRoof(p, slot: i, tower: tower) })
                } else if case .cafe(let i) = s.spot {
                    cafeTaken.remove(i)
                    go(p, to: .desk, final: .desk, route: mode == .instant ? nil : { fromCafe(p, slot: i, tower: tower, car: $0) })
                } else if case .b1(let i) = s.spot {
                    b1Taken.remove(i)
                    go(p, to: .desk, final: .desk, route: mode == .instant ? nil : { fromB1(p, slot: i, tower: tower, car: $0) })
                }
            }
        }

        // 3. 隨機閒晃：只有「做完了你還沒看」、在座位上、沒在路上的
        guard canAnimate else { return out }
        var departed = 0
        let hosts = people.filter { h in
            [.working, .stuck, .waiting, .finished].contains(h.mood) && out.states[h.sid]?.spot.isDesk == true && out.states[h.sid]?.trip == nil
        }
        for p in people.sorted(by: { $0.sid < $1.sid }) where p.mood == .finished {
            guard departed < maxDepartPerTick, moving < maxMoving else { break }
            guard let s = out.states[p.sid], s.spot.isDesk, s.trip == nil else { continue }
            guard rand(p.sid, slot, "go") < departP else { continue }
            let others = hosts.filter { $0.floor != p.floor && $0.sid != p.sid }
            let trip: WanderTrip
            if !others.isEmpty, rand(p.sid, slot, "kind") < 0.5 {
                let h = others[Int(rand(p.sid, slot, "host") * Double(others.count)) % others.count]
                let stay = 8 + rand(p.sid, slot, "stay") * 7
                trip = makeTrip(p.sid, start: now, dest: .visit(floor: h.floor, host: h.sid), final: .desk) {
                    visit(p, host: h, stay: stay, tower: tower, car: $0)
                }
            } else {
                let k = rand(p.sid, slot, "lounge") < 0.5 ? 0 : 1
                let stay = 10 + rand(p.sid, slot, "stay") * 15
                trip = WanderTrip(sid: p.sid, start: now, nodes: lounge(p, slot: k, stay: stay), dest: .lounge(slot: k), final: .desk)
            }
            out.states[p.sid] = WanderState(spot: .desk, trip: trip)
            out.started.append(trip)
            moving += 1; departed += 1
        }
        return out
    }

    // MARK: 路線（模組本地座標）

    /// 沿折線排時間：走路 1.1 m/s
    static func timed(_ pts: [(floor: String, x: Double, z: Double, move: WanderNode.Move)], startT: Double = 0,
                      tower: TowerPlan) -> [WanderNode] {
        var out: [WanderNode] = []
        var t = startT
        for (i, p) in pts.enumerated() {
            if i > 0 {
                let a = out[i - 1]
                switch p.move {
                case .walk, .start: t += hypot(p.x - a.x, p.z - a.z) / walkSpeed
                case .elevator: t += abs(floorY(p.floor, tower: tower) - floorY(a.floor, tower: tower)) / elevatorSpeed
                case .slide: t += Double(floorsBetween(a.floor, p.floor, tower: tower)) * slidePerFloor
                case .teleport, .wait: break
                }
            }
            out.append(WanderNode(floor: p.floor, x: p.x, z: p.z, move: i == 0 ? .start : p.move, t: (t * 100).rounded() / 100))
        }
        return capLeg(out)
    }

    /// 電梯／溜滑梯那段太久（超過 maxRide）：換成瞬移（規範 §4.3「走到電梯口 → 瞬移到目的層電梯口」），後面的時間往前收
    static func capLeg(_ n: [WanderNode]) -> [WanderNode] {
        var out = n
        var removed = 0.0
        for i in n.indices.dropFirst() {
            let seg = n[i].t - n[i - 1].t
            if (n[i].move == .elevator || n[i].move == .slide), seg > maxRide {
                removed += seg
                out[i].move = .teleport
            }
            out[i].t = ((n[i].t - removed) * 100).rounded() / 100
        }
        return out
    }

    // MARK: 電梯排程（10-22 Kang：電梯兩部、搭電梯不要破圖、沒有電梯要等）

    static func cab(_ c: Int) -> (x: Double, z: Double) { TowerLayout.elevators[min(max(c, 0), TowerLayout.elevators.count - 1)] }
    static func door(_ c: Int) -> (x: Double, z: Double) { TowerLayout.elevatorDoors[min(max(c, 0), TowerLayout.elevatorDoors.count - 1)] }

    /// 沒給（第一次刷新）：每部都停一樓、現在有空；少給的補齊
    static func initialCars(_ given: [WanderCar], now: Date) -> [WanderCar] {
        var cars = given
        while cars.count < TowerLayout.elevators.count { cars.append(WanderCar(floor: "lobby", freeAt: now)) }
        return Array(cars.prefix(TowerLayout.elevators.count))
    }

    /// 樓層的高度（模組原點 y）：B1 不在 TowerPlan 裡 ⇒ 用 TowerLayout.b1Origin；找不到的樓層當 0（大廳）
    static func floorY(_ id: String, tower: TowerPlan) -> Double {
        if id == TowerLayout.b1Floor { return TowerLayout.b1Origin }
        return tower.floor(id: id)?.y ?? 0
    }

    /// 車廂在兩層之間開幾秒（跟人搭電梯同一個速度；往上取到 0.01 秒）
    static func carTravel(_ a: String, _ b: String, tower: TowerPlan) -> Double {
        let d = abs(floorY(b, tower: tower) - floorY(a, tower: tower)) / elevatorSpeed
        return (d * 100).rounded(.up) / 100
    }

    /// 排一趟行程的電梯：`build(c)`＝走第 c 部電梯的路線。挑「最早能上車」的那部（一樣早挑編號小的），
    /// 車廂先從它停的樓層空車開過來（最早在它有空、而且這趟出發之後才動），人到門口車還沒到就在門口 .wait 等，後面的節點往後推。
    /// 一部車一次只載一趟（不共乘）：來回的行程回程也用同一部，車在目的層等他，到回程結束才放出來。
    /// 瞬移段（capLeg 換掉的）不是 .elevator，不佔車。路線裡沒有電梯段 ⇒ 原樣回傳、不動車
    static func schedule(start: Date, cars: inout [WanderCar], tower: TowerPlan,
                         build: (Int) -> [WanderNode]) -> (nodes: [WanderNode], moves: [WanderCarMove]) {
        let base = build(0)
        guard base.contains(where: { $0.move == .elevator }) else { return (base, []) }
        // 1. 挑車：第一段電梯的上車時間＝max(走到門口, 車開過來)
        var best: (c: Int, board: Date, nodes: [WanderNode])?
        for c in cars.indices {
            let n = c == 0 ? base : build(c)
            guard let i = n.firstIndex(where: { $0.move == .elevator }), i >= 1 else { continue }
            let d = i >= 2 ? i - 2 : i - 1
            let ready = max(cars[c].freeAt, start).addingTimeInterval(carTravel(cars[c].floor, n[i - 1].floor, tower: tower))
            let board = max(start.addingTimeInterval(n[d].t), ready)
            if best == nil || board < best!.board { best = (c, board, n) }
        }
        guard let pick = best else { return (base, []) }
        let c = pick.c, nodes = pick.nodes
        var car = cars[c]
        var out: [WanderNode] = [], moves: [WanderCarMove] = []
        // 每段電梯的門口（電梯段往前兩個點：門口 → 車廂 → 電梯段）
        var doorOf: [Int: Int] = [:]
        for i in nodes.indices where i >= 1 && nodes[i].move == .elevator { doorOf[i >= 2 ? i - 2 : i - 1] = i }
        var shift = 0.0
        for (k, n0) in nodes.enumerated() {
            var n = n0
            n.t = ((n.t + shift) * 100).rounded() / 100
            if n.move == .elevator, k >= 1 {
                // 載人那段：從上車點（前一個點）開到這層
                n.car = c
                let from = out[out.count - 1]
                moves.append(WanderCarMove(car: c, from: from.floor, to: n.floor, start: from.t, end: n.t))
                car.floor = n.floor
                car.freeAt = start.addingTimeInterval(n.t)
            }
            out.append(n)
            guard let i = doorOf[k] else { continue }
            // 門口：車要先開到這層（空車），還沒到就在門口等
            let boardFloor = nodes[i - 1].floor
            let leave = (max(car.freeAt, start).timeIntervalSince(start) * 100).rounded(.up) / 100
            var ready = leave
            if car.floor != boardFloor {
                let travel = carTravel(car.floor, boardFloor, tower: tower)
                moves.append(WanderCarMove(car: c, from: car.floor, to: boardFloor, start: leave, end: leave + travel))
                ready = leave + travel
                car.floor = boardFloor
            }
            if ready > n.t + 0.0001 {
                let w = ((ready - n.t) * 100).rounded(.up) / 100
                shift += w
                out.append(WanderNode(floor: n.floor, x: n.x, z: n.z, move: .wait, t: ((n.t + w) * 100).rounded() / 100))
            }
        }
        cars[c] = car
        return (out, moves)
    }

    static func floorsBetween(_ a: String, _ b: String, tower: TowerPlan) -> Int {
        guard let i = tower.floors.firstIndex(where: { $0.id == a }), let j = tower.floors.firstIndex(where: { $0.id == b }) else { return 1 }
        return max(1, abs(i - j))
    }

    /// 座位 → 走道 → 電梯門 → 電梯（到目的層）→ 目的層電梯門 → 走道
    static func toElevator(_ p: WanderPerson, car: Int = 0) -> [(floor: String, x: Double, z: Double, move: WanderNode.Move)] {
        let s = TowerLayout.seat(p.seat, of: p.seats, floor: p.floor)
        let az = TowerLayout.aisle(s)
        return [(p.floor, s.x, s.z, .start)] + TowerLayout.toAisle(s).map { (p.floor, $0.x, $0.z, .walk) } + [(p.floor, -5.2, az, .walk),
                (p.floor, door(car).x, door(car).z, .walk), (p.floor, cab(car).x, cab(car).z, .walk)]
    }

    static func toRoof(_ p: WanderPerson, slot: Int, tower: TowerPlan, car: Int = 0) -> [WanderNode] {
        let r = TowerLayout.roofSlot(slot)
        return timed(toElevator(p, car: car) + [("roof", cab(car).x, cab(car).z, .elevator),
                                      ("roof", door(car).x, door(car).z, .walk),
                                      ("roof", r.x, r.z, .walk)], tower: tower)
    }

    /// 一樓：電梯門 → 往後走到咖啡館走道 → 站位
    static func cafeLeg(_ i: Int, car: Int = 0) -> [(floor: String, x: Double, z: Double, move: WanderNode.Move)] {
        let c = TowerLayout.cafeSlot(i)
        return [("lobby", door(car).x, door(car).z, .walk),
                ("lobby", TowerLayout.cafeEntryX, TowerLayout.cafeWalkZ, .walk),
                ("lobby", c.x, TowerLayout.cafeWalkZ, .walk), ("lobby", c.x, c.z, .walk)]
    }

    static func toCafe(_ p: WanderPerson, slot: Int, tower: TowerPlan, car: Int = 0) -> [WanderNode] {
        timed(toElevator(p, car: car) + [("lobby", cab(car).x, cab(car).z, .elevator)] + cafeLeg(slot, car: car), tower: tower)
    }

    /// 頂樓（下雨了）→ 電梯 → 一樓咖啡館
    static func roofToCafe(slot: Int, cafe: Int, tower: TowerPlan, car: Int = 0) -> [WanderNode] {
        let r = TowerLayout.roofSlot(slot)
        return timed([("roof", r.x, r.z, .start), ("roof", door(car).x, door(car).z, .walk),
                      ("roof", cab(car).x, cab(car).z, .walk),
                      ("lobby", cab(car).x, cab(car).z, .elevator)] + cafeLeg(cafe, car: car), tower: tower)
    }

    /// B1：電梯門 → 門口空地 → 繞圈 → 站位
    static func b1Leg(_ i: Int, car: Int = 0) -> [(floor: String, x: Double, z: Double, move: WanderNode.Move)] {
        let f = TowerLayout.b1Floor
        return [(f, door(car).x, door(car).z, .walk)] + TowerLayout.b1Route(i, door: door(car)).map { (f, $0.x, $0.z, .walk) }
    }

    /// 座位 → 電梯 → B1 → 站位
    static func toB1(_ p: WanderPerson, slot: Int, tower: TowerPlan, car: Int = 0) -> [WanderNode] {
        timed(toElevator(p, car: car) + [(TowerLayout.b1Floor, cab(car).x, cab(car).z, .elevator)] + b1Leg(slot, car: car), tower: tower)
    }

    /// 頂樓（下雨了）→ 電梯 → B1
    static func roofToB1(slot: Int, b1: Int, tower: TowerPlan, car: Int = 0) -> [WanderNode] {
        let r = TowerLayout.roofSlot(slot)
        return timed([("roof", r.x, r.z, .start), ("roof", door(car).x, door(car).z, .walk),
                      ("roof", cab(car).x, cab(car).z, .walk),
                      (TowerLayout.b1Floor, cab(car).x, cab(car).z, .elevator)] + b1Leg(b1, car: car), tower: tower)
    }

    /// B1 站位 → 原路繞回電梯 → 自己樓層 → 走道 → 座位
    static func fromB1(_ p: WanderPerson, slot: Int, tower: TowerPlan, car: Int = 0) -> [WanderNode] {
        let f = TowerLayout.b1Floor, s = TowerLayout.seat(p.seat, of: p.seats, floor: p.floor)
        let back = b1Leg(slot, car: car).reversed().map { (floor: $0.floor, x: $0.x, z: $0.z, move: WanderNode.Move.walk) }
        return timed([(f, back[0].x, back[0].z, .start)] + back.dropFirst() + [(f, cab(car).x, cab(car).z, .walk),
                      (p.floor, cab(car).x, cab(car).z, .elevator), (p.floor, door(car).x, door(car).z, .walk),
                      (p.floor, -5.2, TowerLayout.aisle(s), .walk)] + TowerLayout.toAisle(s).reversed().map { (p.floor, $0.x, $0.z, .walk) } + [(p.floor, s.x, s.z, .walk)], tower: tower)
    }

    /// 咖啡館 → 電梯 → 自己樓層 → 走道 → 座位
    static func fromCafe(_ p: WanderPerson, slot: Int, tower: TowerPlan, car: Int = 0) -> [WanderNode] {
        let c = TowerLayout.cafeSlot(slot), s = TowerLayout.seat(p.seat, of: p.seats, floor: p.floor)
        return timed([("lobby", c.x, c.z, .start), ("lobby", c.x, TowerLayout.cafeWalkZ, .walk),
                      ("lobby", TowerLayout.cafeEntryX, TowerLayout.cafeWalkZ, .walk),
                      ("lobby", door(car).x, door(car).z, .walk), ("lobby", cab(car).x, cab(car).z, .walk),
                      (p.floor, cab(car).x, cab(car).z, .elevator), (p.floor, door(car).x, door(car).z, .walk),
                      (p.floor, -5.2, TowerLayout.aisle(s), .walk)] + TowerLayout.toAisle(s).reversed().map { (p.floor, $0.x, $0.z, .walk) } + [(p.floor, s.x, s.z, .walk)], tower: tower)
    }

    /// 頂樓 → 溜滑梯 → 自己樓層右門 → 走道 → 座位
    static func fromRoof(_ p: WanderPerson, slot: Int, tower: TowerPlan) -> [WanderNode] {
        let r = TowerLayout.roofSlot(slot), s = TowerLayout.seat(p.seat, of: p.seats, floor: p.floor)
        return timed([("roof", r.x, r.z, .start), ("roof", TowerLayout.slideTop.x, TowerLayout.slideTop.z, .walk),
                      (p.floor, TowerLayout.slideDoor.x, TowerLayout.slideDoor.z, .slide), (p.floor, 5.2, TowerLayout.aisle(s), .walk)]
                      + TowerLayout.toAisle(s).reversed().map { (p.floor, $0.x, $0.z, .walk) } + [(p.floor, s.x, s.z, .walk)], tower: tower)
    }

    /// 拜訪：搭電梯到對方樓層，站在對方桌旁 0.9 面向他，停留後原路（搭電梯）回
    static func visit(_ p: WanderPerson, host h: WanderPerson, stay: Double, tower: TowerPlan, car: Int = 0) -> [WanderNode] {
        let hs = TowerLayout.seat(h.seat, of: h.seats, floor: h.floor)
        let side = sin(hs.a) > 0.5 ? -0.9 : 0.9          // 右牆的人（桌子在他右邊）站左邊
        let go: [(floor: String, x: Double, z: Double, move: WanderNode.Move)] = toElevator(p, car: car) + [
            (h.floor, cab(car).x, cab(car).z, .elevator),
            (h.floor, door(car).x, door(car).z, .walk),
            (h.floor, -5.2, TowerLayout.aisle(hs), .walk), (h.floor, hs.x + side, TowerLayout.aisle(hs), .walk), (h.floor, hs.x + side, hs.z, .walk)]
        return roundTrip(timed(go, tower: tower), stay: stay, tower: tower)
    }

    /// 同層茶水角：座位 → 走道 → F1／F3，停留後原路回
    static func lounge(_ p: WanderPerson, slot: Int, stay: Double) -> [WanderNode] {
        let s = TowerLayout.seat(p.seat, of: p.seats, floor: p.floor), l = TowerLayout.lounge[slot]
        let go = timed([(p.floor, s.x, s.z, .start)] + TowerLayout.toAisle(s).map { (p.floor, $0.x, $0.z, .walk) } + [(p.floor, l.x, TowerLayout.aisleZ, .walk),
                        (p.floor, l.x, l.z, .walk)], tower: TowerPlan())
        return roundTrip(go, stay: stay, tower: TowerPlan())
    }

    /// 去程＋停留＋原路回（回程的每段花的時間跟去程一樣）
    static func roundTrip(_ go: [WanderNode], stay: Double, tower: TowerPlan) -> [WanderNode] {
        guard let last = go.last else { return go }
        var out = go
        let arrive = last.t + (stay * 100).rounded() / 100
        out.append(WanderNode(floor: last.floor, x: last.x, z: last.z, move: .wait, t: arrive))
        let back = Array(go.reversed())
        for k in 1..<back.count {
            let seg = back[k - 1].t - back[k].t
            out.append(WanderNode(floor: back[k].floor, x: back[k].x, z: back[k].z, move: back[k - 1].move == .start ? .walk : back[k - 1].move,
                                  t: ((out[out.count - 1].t + seg) * 100).rounded() / 100))
        }
        return out
    }
}
