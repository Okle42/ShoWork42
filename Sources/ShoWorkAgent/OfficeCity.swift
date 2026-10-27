import AppKit
import SceneKit
import SwiftUI
import simd
import ShoWorkCore

// 外部空間城市的 3D（10-21）：大樓四周地面上的街區，資料來自 CityState（CitySource.swift 收集）。
//   左邊：貨櫃堆場（一個磁碟一個；層數＝已用比例；≥90% 堆到圍籬外＋倉庫頂紅燈；拔掉＝鐵捲門拉下、路斷掉）
//   右後：電廠（cool42；冷卻塔的煙量＝溫度、hot 以上變紅）
//   天上：飛艇（iCloud Drive、~/Library/CloudStorage 每個資料夾一艘）
//   城牆圍住整個街區（防火牆關＝缺口）；前牆上的城門＝對外在聽的埠（敞開的紅門＝已知沒認證的）；後牆內側一排關著的門＝只給本機的埠
//   城外對街：分公司（ssh 伺服器；在線亮燈、離線熄燈關門）、港口（GitHub；剛 push／fetch 一艘貨船出港，約 4 秒）
// 風格照大樓（規範 §1.1 色票、素色、低彩度）。省電：整個城市合併成一個 VoxelMesh（一種材質一個 draw call），
// 內容鍵（不含時間）變了才重建；只有兩種會動：狀態剛變時的旋轉警示燈（4 秒）、出港的船（4 秒），都用 playFor，沒有常駐動畫。

@MainActor
final class CityBuilder {
    let root = SCNNode()
    private var key = ""
    private var built = false
    private var alerting = Set<String>()
    private var beacons: [String: SCNNode] = [:]
    private var ships: [String: SCNNode] = [:]
    private var seenShips = Set<String>()
    /// 名牌：id → (錨點, 字, 是不是警示)
    private(set) var labels: [(id: String, anchor: SCNNode, text: String, alert: Bool)] = []
    private var points: [String: SCNVector3] = [:]
    private(set) var state = CityState()

    // 街區範圍（世界座標，大樓 x ±6、z ±2.8 在中間）
    static let x0: Float = -27, x1: Float = 21, z0: Float = -13, z1: Float = 10
    static let wallH: Float = 1.4, wallT: Float = 0.5
    static let streetZ: Float = 12            // 城外那條街的中線
    static let maxYards = 4, maxGates = 8, maxDoors = 10, maxBranches = 4, maxShips = 4
    /// 大樓前那條路穿過的城門（正門）x、堆場匯流道 x（電梯井外側，看板柱再外面）、電廠中心
    static let mainGateX: Float = 2.0, trunkX: Float = -9.4
    static let powerX: Float = 11.5, powerZ: Float = -7.5
    static let shipDuration: TimeInterval = 4
    /// 城內地坪頂面、城內路面頂面
    static let gy: Float = 0.05, ry: Float = 0.09

    init() { root.name = "city" }

    /// 城市的素色材質（10-21 主光改版，研究 R2-2-2）：原本夜晚整片自發光 0.3（像月光），把燈光算出來的明暗抹平、城市變成一塊灰板，
    /// 水面還比大樓亮 ⇒ 改成日夜兩套底色、一律不發光；夜晚看得出量體靠月光＋光池＋霧。同一個白天色只對到一個材質（合併重複＝少 draw call）
    static let nightOf: [UInt32: UInt32] = [
        TP.ST2: 0x4A505A, TP.ST1: 0x14171B, TP.WL2: 0x59606B, TP.FN5: 0x4A505A, TP.POT: 0x5A606A,
        0x8F8B85: 0x3A4250, 0x4A5A7A: 0x3A4250, 0xC98B3C: 0x5A4A30,
    ]
    static func m(_ h: UInt32) -> SCNMaterial { VoxMat.dayNight(h, nightOf[h] ?? h) }
    /// 路燈燈頭、起重機燈、門燈、亮著的窗：全部同一種暖光（原本 4 種強度＝4 個 draw call）
    static var lamp: SCNMaterial { TM.glow(TP.LT1, 0.1, 1.3) }
    static var window: SCNMaterial { lamp }
    /// 狀態紅（敞開的紅門、警示燈）：一種
    static var red: SCNMaterial { TM.glow(0xEF4444, 0.6, 1.8) }
    // 地面分區（研究 §4.2、R2-2-2）：城內地坪比城外亮一階（底座）、路比地坪暗一階、廣場＝大廳磨石延伸出來
    static var ground: SCNMaterial { VoxMat.dayNight(0xC4C0B8, 0x222A35) }
    static var road: SCNMaterial { VoxMat.dayNight(0x8F969D, 0x1B222C) }
    static var plaza: SCNMaterial { VoxMat.dayNight(TP.FL2, 0x2A323E) }
    static var walk: SCNMaterial { VoxMat.dayNight(0xD6D2CA, 0x2B323D) }      // 人行道
    static var pad: SCNMaterial { VoxMat.dayNight(TP.ST2, 0x2A3038) }         // 堆場水泥地
    static var water: SCNMaterial { VoxMat.dayNight(0x5E7A88, 0x0F1C26) }
    static var grass: SCNMaterial { VoxMat.dayNight(TP.PL2, 0x1E2A22) }
    static var leaf: SCNMaterial { VoxMat.dayNight(TP.PL1, 0x18241B) }
    static var trunk: SCNMaterial { VoxMat.dayNight(TP.FN1, 0x2A2420) }
    /// 靜態假影子（不透明的暗色扁塊；城內地坪上／城外大地面上各一種，因為底色不同）
    static var shade: SCNMaterial { VoxMat.dayNight(0xA9A59D, 0x141920) }
    static var shadeOut: SCNMaterial { VoxMat.dayNight(0x8C9297, 0x080B10) }
    /// 夜景光池（兩層＝光暈漸層；白天跟路面同色看不出來）、水面倒影
    static var poolO: SCNMaterial { VoxMat.dayNight(0x8F969D, 0x4A4236, glow: TP.LT1, emit: (0, 0.07)) }
    static var poolI: SCNMaterial { VoxMat.dayNight(0x8F969D, 0x7A6548, glow: TP.LT1, emit: (0, 0.16)) }
    static var glint: SCNMaterial { VoxMat.dayNight(0x5E7A88, 0x6B5A44, glow: TP.LT1, emit: (0, 0.12)) }
    /// 疊在地坪上的扁塊的頂面高度（10-21：同一高度或只差 5 mm 遠看會閃斜條紋 ⇒ 每層至少差 1 cm）：
    /// 大地面 0 → 城外街 0.04 → 城外影子 0.05 → 光池 0.05／0.06 → 城內地坪 0.05 → 路、廣場、堆場 0.09 → 城內影子 0.10 → 人行道 0.11 → 虛線 0.12
    static let shadowIn: Float = 0.10, shadowOut: Float = 0.05

    /// 鏡頭飛過去的點
    func point(_ id: String) -> SCNVector3? { points[id] ?? extraPoints[id] }
    /// 城市外的點（頂樓冷卻水塔，OfficeBuilder 放）
    private var extraPoints: [String: SCNVector3] = [:]
    func setPoint(_ id: String, _ p: SCNVector3) { extraPoints[id] = p }
    /// 點擊盒中心（測試：模擬滑鼠停在建築本體上）
    func hitCenter(_ id: String) -> SCNVector3? { root.childNode(withName: id, recursively: false)?.worldPosition }

    /// 有變才重建；回傳要播幾秒（旋轉警示燈、船）
    func update(_ s: CityState, animate: Bool) -> TimeInterval {
        if built && s == state { return 0 }          // SwiftUI 每次更新都會叫：資料沒變就什麼都不做
        state = s
        var play: TimeInterval = 0
        let k = Self.key(s)
        if k != key {
            key = k
            rebuild(s)
            // 警示燈：只在狀態「變成」警示時轉 4 秒（第一次建好時不轉）
            let now = Set(s.disks.filter(\.alert).map(\.id))
            if built && animate && !Look.reduceMotion {
                for id in now.subtracting(alerting) { if let b = beacons[id] { spin(b); play = max(play, 4.2) } }
            }
            alerting = now
            built = true
        }
        play = max(play, updateShips(s.ships, animate: animate))
        return play
    }

    /// 內容鍵：會改到幾何的才放（時間、檢查時間不放）
    static func key(_ s: CityState) -> String {
        let d = s.disks.prefix(maxYards).map { d -> String in
            let c = CityRules.containers(used: d.used)
            return "\(d.name)|\(d.mounted)|\(c.count)|\(c.overflow)|\(d.alert)"
        }.joined(separator: ",")
        let c = s.clouds.map { "\($0.name)|\($0.known)|\($0.alert)" }.joined(separator: ",")      // 剩多少不放（每 5 分鐘都在變，不重建）
        let v = s.servers.prefix(maxBranches).map { "\($0.alias)|\($0.online.map { "\($0)" } ?? "?")" }.joined(separator: ",")
        let f = "\(s.firewall.enabled.map { "\($0)" } ?? "?")|" + s.firewall.gates.prefix(maxGates).map { "\($0.port)\($0.openRed)" }.joined(separator: ",") + "|\(min(maxDoors, s.firewall.doors.count))"
        let p = "\(s.grid.stage)|\(s.grid.known)|\(CityRules.pct(s.grid.fiveUsed) ?? -1)|\(CityRules.pct(s.grid.sevenUsed) ?? -1)|\(s.grid.fiveReset.map { Int($0.timeIntervalSince1970 / 60) } ?? 0)"
        return [d, c, v, f, p].joined(separator: "#")
    }

    // MARK: 重建

    private func rebuild(_ s: CityState) {
        root.childNodes.forEach { if $0.name != "ship" { $0.removeFromParentNode() } }
        beacons = [:]; labels = []; points = [:]
        let m = VoxelMesh(ao: 0), k = Kit(m: m)
        if Self.auditOn { m.log = []; tagged = [:] }
        let road = Self.road
        let pad = Self.pad
        let lamp = Self.lamp

        // 街區地坪（城牆裡面一整片，比城外亮一階）
        let ground = Self.ground
        // 高度分層（10-21：只差 5 mm 時遠看會閃出斜條紋＝z-fighting）：大地面 0 → 城外的街 0.04 → 城內地坪 0.05 → 城內的路、堆場 0.09
        k.b(.identity, (Self.x0 + Self.x1) / 2, 0, (Self.z0 + Self.z1) / 2, Self.x1 - Self.x0, Self.gy, Self.z1 - Self.z0, ground)
        // 大樓前廣場（10-21 主光改版：原本是一條路面；改成大廳磨石延伸出來的廣場，全城最亮的地坪＝視線落點）
        k.b(.identity, 0, Self.gy, TD.zF + 2.2, TD.W + 8, 0.04, 4, Self.plaza)
        // ── 城牆＋城門 ──
        buildWall(k, s.firewall)

        // 城外的街（城門出去，橫過整個街區）
        k.b(.identity, (Self.x0 + Self.x1 + 10) / 2, 0, Self.streetZ, Self.x1 - Self.x0 + 14, 0.04, 2.6, road)
        // 大樓前面那條路接到城門，再穿過城門接到城外的街（10-21 稽核：原本停在牆前、城門也沒對準這條路）
        // 主路（廣場→城門）2.4 寬＋中央虛線＋兩側人行道（研究 R2-2-5 地坪分區）
        let mz0 = TD.zF + 4.2, mz1 = Self.z1 - Self.wallT / 2
        k.b(.identity, Self.mainGateX, Self.gy, (mz0 + mz1) / 2, 2.4, 0.04, mz1 - mz0, road)
        for z in stride(from: mz0 + 0.3, to: mz1 - 0.6, by: 2.4) { k.b(.identity, Self.mainGateX, 0.10, z + 0.6, 0.06, 0.01, 1.2, Self.m(TP.FN5)) }
        for s: Float in [-1, 1] { k.b(.identity, Self.mainGateX + s * 1.5, Self.gy, (mz0 + mz1) / 2, 0.6, 0.06, mz1 - mz0, Self.walk) }
        k.b(.identity, Self.mainGateX, 0, (Self.z1 + Self.streetZ - 1.3) / 2, 1.6, 0.04, Self.streetZ - 1.3 - Self.z1, road)
        // 堆場那幾條路的匯流道：沿電梯井外側（x −9.4）接到大樓前廣場（10-21 稽核：原本每條路停在大樓左後方的空地上，哪裡都沒接到）
        if !s.disks.isEmpty {
            let zTop = Self.z0 + 3.5 - 0.55, zEnd = TD.zF + 0.2
            k.b(.identity, Self.trunkX, Self.gy, (zTop + zEnd) / 2, 1.1, 0.04, zEnd - zTop, road)
        }
        // 電廠的路：廣場右端 → 電廠正門（10-21 稽核：電廠原本沒有門也沒有路）
        k.b(.identity, Self.powerX, Self.gy, (Self.powerZ + 1.5 + TD.zF + 1.3) / 2, 1.1, 0.04, TD.zF + 1.3 - Self.powerZ - 1.5, road)
        k.b(.identity, (TD.W / 2 + 4 + Self.powerX + 0.55) / 2, Self.gy, TD.zF + 0.75, Self.powerX + 0.55 - TD.W / 2 - 4, 0.04, 1.1, road)

        // ── 貨櫃堆場（左邊，一個磁碟一個）──
        for (i, d) in s.disks.prefix(Self.maxYards).enumerated() {
            let zc = Self.z0 + 3.5 + Float(i) * 5.2
            buildYard(k, d, zc: zc, road: road, pad: pad, lamp: lamp)
        }

        // ── 電廠（右後）──
        buildPower(k, s.grid)

        // ── 分公司（城外對街，左半邊）──
        for (i, sv) in s.servers.prefix(Self.maxBranches).enumerated() {
            buildBranch(k, sv, x: -21 + Float(i) * 6.2, road: road)
        }

        // ── 港口（城外對街，右半邊）──
        buildPort(k, s)

        // ── 飛艇（天上，後面）──
        for (i, c) in s.clouds.prefix(4).enumerated() {
            buildAirship(k, c, x: -21 + Float(i) * 10, y: 6.2, z: -17)
        }

        // 路燈（夜晚的城市才看得到路）：10-21 稽核：原本固定每 6 公尺一支，剛好立在城門正前方擋住出入口 ⇒ 離任何開口 1 公尺內的往旁邊挪
        let gaps = Self.openings(s.firewall)
        var lamps: [Float] = []
        for x0 in stride(from: Self.x0 + 3, through: Self.x1 + 5, by: 6) {
            // 往兩邊找最近一個「離開口 1 公尺以上、離上一支路燈 2 公尺以上」的位置；找不到就不放
            let ok = { (x: Float) in !gaps.contains { x > $0.0 - 1.0 && x < $0.1 + 1.0 } && !lamps.contains { abs($0 - x) < 2 } }
            guard let x = stride(from: Float(0), through: 6, by: 0.2).lazy.flatMap({ [x0 + $0, x0 - $0] }).first(where: ok) else { continue }
            lamps.append(x)
            k.b(.identity, x, 0, Self.streetZ - 1.6, 0.08, 1.8, 0.08, Self.m(TP.ST1))
            k.b(.identity, x, 1.8, Self.streetZ - 1.6, 0.26, 0.1, 0.26, lamp)
            pool(k, x, Self.streetZ - 0.5, top: 0.056, w: 2.6, d: 1.8)
        }
        // 主路上一盞（城門內側）：夜景的視線路徑＝城外大街一串光點 → 城門 → 主路 → 廣場 → 大樓（研究 R2-4 光島）
        let mlz = Self.z1 - Self.wallT / 2 - 0.75
        k.b(.identity, Self.mainGateX + 1.5, Self.gy, mlz, 0.08, 1.8, 0.08, Self.m(TP.ST1))
        k.b(.identity, Self.mainGateX + 1.5, Self.gy + 1.8, mlz, 0.26, 0.1, 0.26, lamp)
        pool(k, Self.mainGateX, mlz, top: 0.105, w: 2.3, d: 1.2)

        // ── 行道樹＋草地（研究 §4.3：群組、留白；只放秩序類裝飾）──
        buildGreen(k, gaps: gaps)
        // ── 靜態假影子（太陽不動 ⇒ 影子不動；往背光方向的扁平暗塊，不開即時陰影）──
        buildShadows(k, s)

        if Self.auditOn, let log = m.log { audit(log) }
        let cn = m.node(name: "city-static"); cn.categoryBitMask = OfficeBuilder.outdoorMask
        root.insertChildNode(cn, at: 0)
    }

    // MARK: 穿插稽核（10-21：堆場旁一坨歪斜貨櫃互相插進對方）

    /// SHOWORK_CITY_AUDIT=1：重建時把「轉了角度的方塊」和「貨櫃、警示燈、起重機」跟城市裡每個方塊比一次，插進去超過 1 公分就印出來
    static let auditOn = ProcessInfo.processInfo.environment["SHOWORK_CITY_AUDIT"] != nil
    private var tagged: [Int: String] = [:]
    private var tagFrom: (Int, String)?
    /// 從現在起加的方塊都標成 tag（稽核用；沒開稽核什麼都不做）
    private func tag(_ k: Kit, _ name: String?) {
        guard Self.auditOn else { return }
        if let (i0, t) = tagFrom { for i in i0..<(k.m.log?.count ?? i0) { tagged[i] = t } }
        tagFrom = name.map { ((k.m.log?.count ?? 0), $0) }
    }
    private func audit(_ log: [CityBox]) {
        var hits = 0, checked = 0
        for (i, a) in log.enumerated() where a.rotated || tagged[i] != nil {
            checked += 1
            for (j, b) in log.enumerated() where j != i {
                // 同一組零件（同一台起重機、同一個警示燈）彼此不比；兩個都要檢查的只印一次
                if let ta = tagged[i], let tb = tagged[j], ta == tb, !ta.hasPrefix("container") { continue }
                if (b.rotated || tagged[j] != nil) && j < i { continue }
                // 扁平地坪（<3 cm 厚）是鋪在地上的，不算
                if b.size.y < 0.03 || a.size.y < 0.03 { continue }
                let p = CityBox.penetration(a, b)
                if p > 0.01 {
                    hits += 1
                    print(String(format: "city audit 穿插 %.2fm  %@ @(%.2f,%.2f,%.2f) %.2fx%.2fx%.2f a=%.2f  ↔  %@ @(%.2f,%.2f,%.2f) %.2fx%.2fx%.2f a=%.2f", p,
                                 tagged[i] ?? "rotated", a.center.x, a.center.y, a.center.z, a.size.x, a.size.y, a.size.z, a.yaw,
                                 tagged[j] ?? (b.rotated ? "rotated" : "box"), b.center.x, b.center.y, b.center.z, b.size.x, b.size.y, b.size.z, b.yaw))
                }
            }
        }
        print("city audit 檢查 \(checked) 個方塊（轉角度的 \(log.filter(\.rotated).count) 個）對全部 \(log.count) 個：穿插 \(hits) 處"); fflush(stdout)
    }

    // MARK: 光池、樹、影子（10-21 主光改版）

    /// 路燈底下的兩層光池（外層暗、內層亮＝體素風的光暈；白天跟路面同色）
    private func pool(_ k: Kit, _ x: Float, _ z: Float, top: Float, w: Float, d: Float) {
        k.b(.identity, x, top - 0.006, z, w, 0.006, d, Self.poolO)
        k.b(.identity, x, top + 0.004, z, w * 0.46, 0.006, d * 0.55, Self.poolI)
    }

    private func tree(_ k: Kit, _ x: Float, _ z: Float, base: Float, s: Float = 1, out: Bool = false) {
        k.b(.identity, x, base, z, 0.14, 0.9 * s, 0.14, Self.trunk)
        k.b(.identity, x, base + 0.9 * s, z, 0.9 * s, 0.8 * s, 0.9 * s, Self.leaf)
        k.b(.identity, x + 0.1 * s, base + 1.7 * s, z - 0.05, 0.55 * s, 0.4 * s, 0.55 * s, Self.grass)
        shadow(k, x, z, 0.9 * s, 0.9 * s, base + 1.7 * s, out: out)
    }

    private func buildGreen(_ k: Kit, gaps: [(Float, Float)]) {
        let gtop: Float = 0.11
        // 城門內側那一帶（廣場前、城牆前）：每 3 公尺一棵，避開主路、所有城門／缺口
        let fz = Self.z1 - Self.wallT / 2 - 1.3
        for x in stride(from: Float(-10), through: 19, by: 3) {
            guard abs(x - Self.mainGateX) > 2.7, !gaps.contains(where: { x > $0.0 - 1.1 && x < $0.1 + 1.1 }) else { continue }
            k.b(.identity, x, Self.gy, fz, 1.3, gtop - Self.gy, 1.3, Self.grass)
            tree(k, x, fz, base: gtop)
        }
        // 後牆內側兩條草地帶，樹三棵一組（中間留空）；避開堆場、後牆的門、電廠
        let bz = Self.z0 + Self.wallT / 2 + 0.7
        for (a, b, trees) in [(Float(-13), Float(-4.2), [Float(-12.2), -11.2, -10.2, -6.6, -5.6]), (Float(11.6), Float(20.3), [Float(12.4), 13.4, 19.4])] {
            k.b(.identity, (a + b) / 2, Self.gy, bz, b - a, gtop - Self.gy, 1.2, Self.grass)
            for x in trees { tree(k, x, bz, base: gtop, s: 0.9) }
        }
        // 城外對街（分公司之間、港口左邊）：一排行道樹
        for x: Float in [-17.9, -11.7, -5.5, 0.7] { tree(k, x, Self.streetZ + 1.85, base: 0, out: true) }
    }

    /// 一塊影子：底面 w×d、高 h 的東西，往太陽光的水平方向延伸 h×(0.58, −0.48)（高度上限 4.5 m：大樓 20 m 不能蓋掉半個城）。
    /// 城內的貼在城內地坪上方（只留在城牆內）；out＝城外大地面上
    private func shadow(_ k: Kit, _ x: Float, _ z: Float, _ w: Float, _ d: Float, _ h: Float, out: Bool = false,
                        clip: (lo: SIMD2<Float>, hi: SIMD2<Float>)? = nil) {
        let o = OfficeBuilder.shadowStep * min(h, 4.5)
        var lo = SIMD2(min(x - w / 2, x - w / 2 + o.x), min(z - d / 2, z - d / 2 + o.y))
        var hi = SIMD2(max(x + w / 2, x + w / 2 + o.x), max(z + d / 2, z + d / 2 + o.y))
        let c = clip ?? (out ? nil : (SIMD2(Self.x0 + Self.wallT / 2, Self.z0 + Self.wallT / 2), SIMD2(Self.x1 - Self.wallT / 2, Self.z1 - Self.wallT / 2)))
        if let c { lo = simd_max(lo, c.lo); hi = simd_min(hi, c.hi) }
        guard hi.x - lo.x > 0.05, hi.y - lo.y > 0.05 else { return }
        let top = out ? Self.shadowOut : Self.shadowIn
        k.b(.identity, (lo.x + hi.x) / 2, top - 0.006, (lo.y + hi.y) / 2, hi.x - lo.x, 0.006, hi.y - lo.y, out ? Self.shadeOut : Self.shade)
    }

    private func buildShadows(_ k: Kit, _ s: CityState) {
        // 大樓
        shadow(k, 0, TD.zC, TD.W, TD.D, 4.5)
        // 城牆：前牆（影子往城內）、左牆（往城內）；後牆、右牆的影子落在城外
        let h = Self.wallH, t = Self.wallT
        var x = Self.x0
        for o in Self.openings(s.firewall) {
            if o.0 > x { shadow(k, (x + o.0) / 2, Self.z1, o.0 - x, t, h) }
            x = max(x, o.1)
        }
        if Self.x1 > x { shadow(k, (x + Self.x1) / 2, Self.z1, Self.x1 - x, t, h) }
        shadow(k, Self.x0, (Self.z0 + Self.z1) / 2, t, Self.z1 - Self.z0, h)
        let far: Float = 50
        shadow(k, (Self.x0 + Self.x1) / 2, Self.z0, Self.x1 - Self.x0, t, h, out: true, clip: (SIMD2(-far, -far), SIMD2(far, Self.z0 - t / 2)))
        shadow(k, Self.x1, (Self.z0 + Self.z1) / 2, t, Self.z1 - Self.z0, h, out: true, clip: (SIMD2(Self.x1 + t / 2, -far), SIMD2(far, far)))
        // 堆場：倉庫＋整堆貨櫃（一塊）
        for (i, d) in s.disks.prefix(Self.maxYards).enumerated() {
            let zc = Self.z0 + 3.5 + Float(i) * 5.2
            shadow(k, -22.6, zc, 2.8, 3.6, 2.78)
            let c = CityRules.containers(used: d.used)
            if c.count > 0 {
                let rows = min(4, (min(c.count, CityRules.perLevel) + 2) / 3)
                shadow(k, -18.75, zc - 1.45 + Float(rows - 1) * 0.485, 4.8, Float(rows) * 0.97, Self.ry + Float(c.levels) * 0.72)
            }
            for p in Self.overflowSlots(c.overflow, zc: zc) where p.y == 0 {
                let stacked = Self.overflowSlots(c.overflow, zc: zc).contains { $0.x == p.x && $0.z == p.z && $0.y > 0 }
                shadow(k, p.x, p.z, 1.5, 0.92, Self.gy + (stacked ? 1.44 : 0.72))
            }
        }
        // 電廠、冷卻塔
        shadow(k, Self.powerX, Self.powerZ, 4.4, 3.2, 2.76)
        shadow(k, Self.fuelX, Self.fuelZ, 3.6, 3.6, 3.3)
        // 分公司（城外）
        for i in 0..<min(Self.maxBranches, s.servers.count) { shadow(k, -21 + Float(i) * 6.2, Self.streetZ + 4.2, 4.6, 3.6, 3.16, out: true) }
    }

    private func label(_ id: String, _ p: SIMD3<Float>, _ text: String, alert: Bool, hit: (SIMD3<Float>, SIMD3<Float>)? = nil) {
        let a = SCNNode(); a.name = "anchor"; a.simdPosition = p
        root.addChildNode(a)
        labels.append((id, a, text, alert))
        points[id] = SCNVector3(p.x, p.y - 1.2, p.z)
        // 點擊盒：不畫（isHidden），hitTest 照樣找得到（ignoreHiddenNodes: false）
        if let (c, sz) = hit {
            let b = SCNBox(width: CGFloat(sz.x), height: CGFloat(sz.y), length: CGFloat(sz.z), chamferRadius: 0)
            let n = SCNNode(geometry: b); n.name = id; n.simdPosition = c; n.isHidden = true
            n.categoryBitMask |= OfficeBuilder.pickMask
            root.addChildNode(n)
        }
    }

    // MARK: 城牆

    static let gateW: Float = 1.6, gateStep: Float = 2.6
    /// 第 i 個城門的 x：第 0 個是正門（對準大樓前那條路），之後左右交替往外排（10-21 稽核：原本整排置中，8 個門時路剛好撞在兩門之間的牆上）
    static func gateX(_ i: Int) -> Float { i == 0 ? mainGateX : mainGateX + Float((i + 1) / 2) * gateStep * (i % 2 == 1 ? -1 : 1) }
    /// 前牆所有開口（城門＋防火牆關的缺口）；沒有對外的埠時正門還在（關著），一樣算開口位置
    static func openings(_ f: CityFirewall) -> [(Float, Float)] {
        let n = max(1, min(maxGates, f.gates.count))
        var o: [(Float, Float)] = (0..<n).map { (gateX($0) - gateW / 2, gateX($0) + gateW / 2) }
        if f.enabled == false { o.append((-20, -14.5)) }
        return o.sorted { $0.0 < $1.0 }
    }

    private func buildWall(_ k: Kit, _ f: CityFirewall) {
        let wall = Self.m(TP.ST2), cap = Self.m(TP.ST1)
        let h = Self.wallH, t = Self.wallT
        let gates = Array(f.gates.prefix(Self.maxGates))
        let gw = Self.gateW
        // 10-22 Kang 截圖「一堆破圖」：牆段端面跟門柱內側在同一個平面（x＝門寬/2），兩面搶深度、斜看會出鋸齒 ⇒ 牆段縮進門柱裡 10 公分
        let openings = Self.openings(f).map { ($0.0 - 0.1, $0.1 + 0.1) }
        let breach: (Float, Float)? = f.enabled == false ? (-20, -14.5) : nil
        // 前牆分段
        var x = Self.x0
        for o in openings {
            if o.0 > x { k.b(.identity, (x + o.0) / 2, 0, Self.z1, o.0 - x, h, t, wall); k.b(.identity, (x + o.0) / 2, h, Self.z1, o.0 - x, 0.08, t + 0.06, cap) }
            x = max(x, o.1)
        }
        if Self.x1 > x { k.b(.identity, (x + Self.x1) / 2, 0, Self.z1, Self.x1 - x, h, t, wall); k.b(.identity, (x + Self.x1) / 2, h, Self.z1, Self.x1 - x, 0.08, t + 0.06, cap) }
        // 後牆、左右牆
        let W = Self.x1 - Self.x0, D = Self.z1 - Self.z0
        k.b(.identity, (Self.x0 + Self.x1) / 2, 0, Self.z0, W, h, t, wall); k.b(.identity, (Self.x0 + Self.x1) / 2, h, Self.z0, W, 0.08, t + 0.06, cap)
        for xx in [Self.x0, Self.x1] {
            k.b(.identity, xx, 0, (Self.z0 + Self.z1) / 2, t, h, D, wall); k.b(.identity, xx, h, (Self.z0 + Self.z1) / 2, t + 0.06, 0.08, D, cap)
        }
        // 角樓
        for xx in [Self.x0, Self.x1] { for zz in [Self.z0, Self.z1] { k.b(.identity, xx, 0, zz, 1.1, h + 0.7, 1.1, wall); k.b(.identity, xx, h + 0.7, zz, 1.2, 0.1, 1.2, cap) } }
        if let b = breach {
            // 碎塊（10-21：原本 7 塊隨機角度、隨機大小，相鄰的會互相插進去 ⇒ 方正、對齊、彼此留縫，只是高低不一，看得出是倒掉的牆）
            let hs: [Float] = [0.35, 0.22, 0.5, 0.28, 0.42, 0.2, 0.32]
            let step = (b.1 - b.0 - 0.8) / 6
            for i in 0..<7 {
                let xx = b.0 + 0.4 + Float(i) * step
                k.b(.identity, xx, 0, Self.z1 + (i % 2 == 0 ? 0.12 : -0.12), min(0.6, step - 0.1), hs[i], 0.45, wall)
            }
        }
        // 城門：門柱＋門楣；敞開的紅門＝紅色門框（夜晚發光）
        let red = Self.red
        if gates.isEmpty {
            // 沒有對外在聽的埠：正門關著（門框＋兩扇關上的門板）
            let xc = Self.mainGateX
            for dx in [-gw / 2 - 0.15, gw / 2 + 0.15] { k.b(.identity, xc + dx, 0, Self.z1, 0.3, h + 0.8, t + 0.2, cap) }
            k.b(.identity, xc, h + 0.6, Self.z1, gw + 0.6, 0.25, t + 0.2, cap)
            k.b(.identity, xc, 0, Self.z1, gw, h, 0.1, TM.f(TP.FN3))
        }
        for (i, g) in gates.enumerated() {
            let xc = Self.gateX(i)
            let fm = g.openRed ? red : cap
            for dx in [-gw / 2 - 0.15, gw / 2 + 0.15] { k.b(.identity, xc + dx, 0, Self.z1, 0.3, h + 0.8, t + 0.2, fm) }
            k.b(.identity, xc, h + 0.6, Self.z1, gw + 0.6, 0.25, t + 0.2, fm)
            if g.openRed {
                // 兩扇門板往外敞開成 90°（10-21 第二輪稽核：原本轉 1.2 弧度，門板插進旁邊的牆 4 cm ⇒ 方正擺：貼著門柱內側、垂直牆面往外伸）
                for s: Float in [-1, 1] { k.b(.identity, xc + s * (gw / 2 - 0.04), 0, Self.z1 + 0.35 + gw / 4, 0.08, h, gw / 2, red) }
                label("city:gate:\(g.port)", SIMD3(xc, h + 1.6, Self.z1), CityText.gate(g), alert: true, hit: (SIMD3(xc, 1, Self.z1), SIMD3(gw + 0.8, 2.4, 1.4)))
            }
        }
        // 城內關著的門（只給本機的埠）：後牆內側一排
        for i in 0..<min(Self.maxDoors, f.doors.count) {
            let xx = -3 + Float(i) * 1.5
            k.b(.identity, xx, 0, Self.z0 + t / 2 + 0.05, 0.9, 1.15, 0.08, TM.f(TP.FN3))
            k.b(.identity, xx, 1.15, Self.z0 + t / 2 + 0.05, 1.05, 0.1, 0.12, cap)
        }
        let wallAlert = f.enabled == false
        let lx: Float = breach.map { ($0.0 + $0.1) / 2 } ?? -10
        label("city:wall", SIMD3(lx, h + 1.4, Self.z1), CityText.wall(f), alert: wallAlert, hit: (SIMD3(lx, h / 2, Self.z1), SIMD3(6, h + 1, 1.2)))
    }

    // MARK: 貨櫃堆場

    /// 貨櫃 4 色（10-21 主光改版 R2-2-2／5-7：拿掉酒紅、帳綠、青綠——撞「警示紅／完成綠」；琥珀只佔 1/6 當唯一強調）
    static let containerColors: [UInt32] = [TP.ST2, 0x8F8B85, 0x4A5A7A, 0x8F8B85, TP.ST2, 0xC98B3C]

    private func buildYard(_ k: Kit, _ d: CityDisk, zc: Float, road: SCNMaterial, pad: SCNMaterial, lamp: SCNMaterial) {
        let xL: Float = -24, xR: Float = -14            // 堆場範圍
        let depth: Float = 4.4
        k.b(.identity, (xL + xR) / 2, Self.gy, zc, xR - xL, 0.04, depth, pad)
        // 圍籬（細柱＋兩條橫桿；靠大樓那側留出入口）
        let post = Self.m(TP.ST1)
        for x in stride(from: xL, through: xR, by: 1.25) {
            for z in [zc - depth / 2, zc + depth / 2] { k.b(.identity, x, 0, z, 0.06, 1.0, 0.06, post) }
        }
        for z in [zc - depth / 2, zc + depth / 2] { for y: Float in [0.45, 0.95] { k.b(.identity, (xL + xR) / 2, y, z, xR - xL, 0.04, 0.04, post) } }
        for z in stride(from: zc - depth / 2, through: zc + depth / 2, by: 1.1) { k.b(.identity, xR, 0, z, 0.06, 1.0, 0.06, post) }
        for y: Float in [0.45, 0.95] {
            k.b(.identity, xR, y, zc - depth / 2 + 0.6, 0.04, 0.04, 1.2, post); k.b(.identity, xR, y, zc + depth / 2 - 0.6, 0.04, 0.04, 1.2, post)
        }
        // 倉庫（左端；鐵捲門朝大樓）
        let wx: Float = -22.6
        k.b(.identity, wx, 0, zc, 2.6, 2.6, 3.4, Self.m(TP.WL2))
        k.b(.identity, wx, 2.6, zc, 2.8, 0.18, 3.6, Self.m(TP.ST2))
        let doorX = wx + 1.31
        if d.mounted {
            k.b(.identity, doorX, 0, zc, 0.04, 1.9, 1.8, TM.f(TP.FN6))              // 開著：裡面暗
            k.b(.identity, doorX, 1.75, zc, 0.12, 0.2, 1.9, Self.m(TP.ST2))           // 捲起來的門
            k.b(.identity, doorX + 0.06, 2.05, zc, 0.08, 0.08, 0.5, lamp)           // 門燈（10-21 稽核：原本凸出 0.1 插進第 3 層貨櫃 2 cm）
        } else {
            for i in 0..<9 { k.b(.identity, doorX, Float(i) * 0.21, zc, 0.06, 0.2, 1.9, Self.m(i % 2 == 0 ? TP.ST2 : 0x8F8B85)) }   // 鐵捲門拉下
        }
        // 貨櫃：一層 3×4、最多 4 層；顏色依磁碟名固定
        let c = CityRules.containers(used: d.used)
        let seed = d.name.unicodeScalars.reduce(UInt32(5)) { $0 &* 31 &+ $1.value }
        let cw: Float = 1.5, ch: Float = 0.72, cd: Float = 0.92
        tag(k, "container")
        for n in 0..<c.count {
            let lv = n / CityRules.perLevel, j = n % CityRules.perLevel
            let col = j % 3, row = j / 3
            let x = -20.4 + Float(col) * 1.65, z = zc - 1.45 + Float(row) * 0.97
            let h = Self.containerColors[Int((seed &+ UInt32(n * 7)) % UInt32(Self.containerColors.count))]
            k.b(.identity, x, Self.ry + Float(lv) * ch, z, cw, ch - 0.04, cd, Self.m(h))
        }
        // 圍籬外的貨櫃（≥90%，堆場放不下溢出來）：10-21 第二輪：原本歪斜亂放、互相插進去像破圖 ⇒
        // 整齊排在出口那條路兩側（貼著路、對齊格線、彼此留 0.1 縫），一側兩個、再多就疊第二層
        for (n, p) in Self.overflowSlots(c.overflow, zc: zc).enumerated() {
            k.b(.identity, p.x, Self.gy + p.y, p.z, cw, ch - 0.04, cd, Self.m(Self.containerColors[(n + 2) % Self.containerColors.count]))
        }
        tag(k, nil)
        // 路：堆場入口 → 大樓左邊（電梯井外）；拔掉＝中間斷一截
        let ra: Float = -13.94, rb: Float = Self.trunkX + 0.55
        if d.mounted {
            k.b(.identity, (ra + rb) / 2, Self.gy, zc, rb - ra, 0.04, 1.1, road)
        } else {
            k.b(.identity, ra + 0.9, Self.gy, zc, 1.8, 0.04, 1.1, road); k.b(.identity, rb - 1.0, Self.gy, zc, 2.0, 0.04, 1.1, road)
            k.b(.identity, ra + 2.1, Self.gy, zc - 0.2, 0.45, 0.1, 0.3, road)       // 斷口碎塊（10-21 第二輪：方正擺，不歪）
        }
        // 警示燈：倉庫頂；≥90% 紅燈（靜態發光），狀態剛變時轉 4 秒
        let top = max(2.8, Self.ry + Float(c.levels) * ch)
        if d.alert {
            // 警示燈（10-21 第二輪：原本紅方塊＋一根橫桿＝遠看像十字架 ⇒ 改成屋頂上的旋轉警示燈：深色底座＋紅燈罩＋深色燈帽，沒有任何伸出去的桿子）
            let b = SCNNode(); b.simdPosition = SIMD3(wx, 2.78, zc)
            let mm = VoxelMesh(), kk = Kit(m: mm), red = Self.red, dark = Self.m(TP.ST1)
            kk.b(.identity, 0, 0, 0, 0.5, 0.08, 0.5, dark)            // 底座
            kk.b(.identity, 0, 0.08, 0, 0.34, 0.3, 0.34, red)         // 燈罩
            kk.b(.identity, 0, 0.38, 0, 0.4, 0.06, 0.4, dark)         // 燈帽
            let bn = mm.node(name: "beacon"); bn.categoryBitMask = OfficeBuilder.outdoorMask
            b.addChildNode(bn)
            root.addChildNode(b)
            beacons[d.id] = b
            if Self.auditOn, k.m.log != nil {      // 稽核：警示燈是另一個節點，外框記進城市的紀錄一起比（不畫）
                k.m.log!.append(CityBox(center: SIMD3(wx, 2.78 + 0.22, zc), size: SIMD3(0.5, 0.44, 0.5))); tagged[k.m.log!.count - 1] = "beacon"
            }
        }
        label(d.id, SIMD3(-19, top + 1.0, zc), CityText.disk(d), alert: d.alert,
              hit: (SIMD3(-19, 1.4, zc), SIMD3(xR - xL, 3.0, depth)))
    }

    /// 圍籬外溢出貨櫃的位置（底面中心，y＝離地高）：出口那條路兩側各一排，每排兩個（x −13.05／−11.45，留 0.1 縫），超過 4 個疊第二層。
    /// 路寬 1.1（zc±0.55）⇒ 貨櫃內緣離路 0.15；圍籬在 x −14、匯流道在 x −9.95 以東，都碰不到
    static func overflowSlots(_ n: Int, zc: Float) -> [SIMD3<Float>] {
        let xs: [Float] = [-13.05, -11.45], dz: Float = 0.55 + 0.15 + 0.46, ch: Float = 0.72
        return (0..<min(n, 8)).map { i in
            let side: Float = i % 2 == 0 ? -1 : 1, col = (i / 2) % 2, lv = i / 4
            return SIMD3(xs[col], Float(lv) * ch, zc + side * dz)
        }
    }

    /// 狀態剛變成警示：燈罩閃 4 秒（10-21 第二輪：原本整個轉，燈改成方正的之後轉起來看不出來）
    private func spin(_ b: SCNNode) {
        b.removeAction(forKey: "spin")
        let blink = SCNAction.sequence([.fadeOpacity(to: 0.25, duration: 0.25), .fadeOpacity(to: 1, duration: 0.25)])
        b.runAction(.repeat(blink, count: 8), forKey: "spin")
    }

    // MARK: 電廠

    /// 號誌燈（電廠屋頂、電表、逃生燈）：自己做的材質、不登記到 VoxMat 的發光清單 ⇒ 停電把燈全關時它照樣亮
    private static var signals: [UInt32: SCNMaterial] = [:]
    static func signal(_ h: UInt32) -> SCNMaterial {
        if let m = signals[h] { return m }
        let m = SCNMaterial()
        m.diffuse.contents = VoxMat.color(h); m.emission.contents = VoxMat.color(h); m.emission.intensity = 1.4
        m.lightingModel = .constant
        signals[h] = m
        return m
    }
    static func stageColor(_ s: CityGrid.Stage) -> UInt32 {
        switch s { case .normal: 0x22C55E; case .dim: 0xF59E0B; case .flicker, .blackout: 0xEF4444 }
    }
    /// 油槽中心（原本冷卻塔的位置；冷卻塔 10-22 搬上頂樓）
    static let fuelX: Float = 16.8, fuelZ: Float = -7.8
    /// 輸電線（10-22 Kang：走最短路徑）：電廠左牆 → 大樓右牆，一條直線（z −6.4、離地 1.6）；上面有光點一顆顆往大樓流＝電力輸入
    static let wireZ: Float = -6.4, wireY: Float = 1.6
    static var wireX0: Float { powerX - 2.1 }            // 電廠左牆
    static var wireX1: Float { TD.W / 2 }                // 大樓右牆

    // 10-22 Kang 拍板：電廠＝AI 額度。5 小時額度＝電力（電表＋屋頂號誌燈；用完＝停電），7 天額度＝油槽液位
    private func buildPower(_ k: Kit, _ g: CityGrid) {
        let bx = Self.powerX, bz = Self.powerZ
        let out = g.stage == .blackout
        k.b(.identity, bx, 0, bz, 4.2, 2.6, 3.0, Self.m(TP.WL2))
        k.b(.identity, bx, 0, bz + 1.51, 1.0, 1.7, 0.04, TM.f(TP.FN6))          // 正門（朝大樓，路接到這裡）
        k.b(.identity, bx, 2.6, bz, 4.4, 0.16, 3.2, Self.m(TP.ST2))
        let win = g.known && !out ? Self.window : TM.f(TP.FN6)
        for i in 0..<4 { k.b(.identity, bx - 1.5 + Float(i), 1.9, bz + 1.51, 0.6, 0.45, 0.04, win) }
        // 屋頂號誌燈：綠＝正常、黃＝80% 以上、紅＝95% 以上／停電
        let col = Self.stageColor(g.stage)
        k.b(.identity, bx + 1.4, 2.76, bz - 0.6, 0.16, 0.5, 0.16, TM.f(TP.ST1))
        k.b(.identity, bx + 1.4, 3.26, bz - 0.6, 0.42, 0.42, 0.42, g.known ? Self.signal(col) : TM.f(TP.FN6))
        // 電表（門右邊，朝大樓）：外框＋剩餘量的柱
        let mx = bx + 1.25, mz = bz + 1.75, mh: Float = 1.9
        k.b(.identity, mx, 0, mz, 0.62, mh + 0.2, 0.32, TM.f(TP.ST1))
        k.b(.identity, mx, 0.1, mz + 0.161, 0.42, mh, 0.02, TM.f(TP.FN6))
        let left = Float(g.fiveLeft ?? 0) / 100
        if left > 0 { k.b(.identity, mx, 0.1, mz + 0.17, 0.36, max(0.06, mh * left), 0.02, Self.signal(col)) }
        // 油槽（7 天額度）：圓槽（方塊疊）＋正面液位窗
        let tx = Self.fuelX, tz = Self.fuelZ, th: Float = 3.2
        k.b(.identity, tx, 0, tz, 3.6, th, 2.4, Self.m(TP.ST2))       // 兩塊交叉＝八角形的槽
        k.b(.identity, tx, 0, tz, 2.4, th, 3.6, Self.m(TP.ST2))
        k.b(.identity, tx, th, tz, 2.2, 0.12, 2.2, Self.m(TP.ST1))
        let wz = tz + 1.81, wh: Float = 2.4
        k.b(.identity, tx, 0.4, wz, 0.5, wh, 0.03, TM.f(TP.FN6))
        let fuel = Float(g.sevenLeft ?? 0) / 100
        if fuel > 0 { k.b(.identity, tx, 0.4, wz + 0.01, 0.4, max(0.06, wh * fuel), 0.03, TM.f(fuel <= 0.05 ? 0xEF4444 : 0xC98B3C)) }
        // 油管：油槽 → 電廠
        k.b(.identity, (bx + 2.1 + tx - 1.8) / 2, 0.5, tz + 0.2, tx - 1.8 - bx - 2.1, 0.3, 0.3, Self.m(TP.ST1))
        // 輸電線（停電時線還在，只是大樓暗了）
        let post = TM.f(TP.ST1), x0 = Self.wireX0, x1 = Self.wireX1, cz = Self.wireZ, cy = Self.wireY
        k.b(.identity, (x0 + x1) / 2, cy - 0.06, cz, x0 - x1, 0.12, 0.12, post)                 // 電纜管（深色）
        k.b(.identity, (x0 + x1) / 2, cy - 0.015, cz + 0.065, x0 - x1, 0.03, 0.01, out ? TM.f(TP.FN6) : Self.signal(0x1E6FD9))   // 管側一條細藍燈
        for x in [x0 - 0.12, x1 + 0.12] { k.b(.identity, x, cy - 0.3, cz, 0.24, 0.6, 0.4, post) }   // 兩端的接線箱（電廠牆上、大樓牆上）
        k.b(.identity, (x0 + x1) / 2, 0, cz, 0.1, cy - 0.06, 0.1, post)                         // 中間一根支架
        addPulses(stage: g.stage)
        label("city:power", SIMD3(bx, 4.6, bz), CityText.grid(g, now: Date()), alert: g.alert,
              hit: (SIMD3(bx, 1.5, bz + 0.2), SIMD3(4.6, 3.6, 3.6)))
        label("city:fuel", SIMD3(tx, th + 1.4, tz), CityText.fuel(g), alert: (g.sevenLeft ?? 100) <= 5,
              hit: (SIMD3(tx, th / 2, tz), SIMD3(3.8, th + 0.2, 3.8)))
    }

    /// 電纜上的光點：一顆顆從電廠流向大樓（SCNAction，只在畫面有在畫時動；看板每 30 秒會播幾秒讓它流一下）；停電沒有光點、吃緊變紅
    private func addPulses(stage: CityGrid.Stage) {
        guard stage != .blackout else { return }
        let x0 = Self.wireX0, x1 = Self.wireX1, n = 4, dur: TimeInterval = 2.4
        let col: UInt32 = stage == .normal ? 0x7DD3FC : Self.stageColor(stage)
        let mat = Self.signal(col)
        for i in 0..<n {
            let b = SCNNode(geometry: SCNBox(width: 0.22, height: 0.08, length: 0.08, chamferRadius: 0.02))
            b.geometry!.firstMaterial = mat
            b.name = "power-pulse"
            b.simdPosition = SIMD3(x0, Self.wireY + 0.02, Self.wireZ + 0.075)
            b.opacity = 0
            let go = SCNAction.sequence([
                .wait(duration: dur / Double(n) * Double(i)),
                .repeatForever(.sequence([
                    .move(to: SCNVector3(CGFloat(x0), CGFloat(Self.wireY + 0.02), CGFloat(Self.wireZ + 0.075)), duration: 0),
                    .fadeIn(duration: 0.2),
                    .move(to: SCNVector3(CGFloat(x1 + 0.1), CGFloat(Self.wireY + 0.02), CGFloat(Self.wireZ + 0.075)), duration: dur - 0.4),
                    .fadeOut(duration: 0.2),
                ])),
            ])
            b.runAction(go, forKey: "pulse")
            root.addChildNode(b)
        }
    }

    // MARK: 分公司

    private func buildBranch(_ k: Kit, _ s: CityServer, x: Float, road: SCNMaterial) {
        let z: Float = Self.streetZ + 4.2
        let on = s.online == true
        k.b(.identity, x, 0, z, 4.4, 3.0, 3.4, Self.m(TP.WL2))
        k.b(.identity, x, 3.0, z, 4.6, 0.16, 3.6, Self.m(TP.ST2))
        let win = on ? Self.window : TM.f(TP.FN6)
        for zz in [z - 1.71, z + 1.71] { for i in 0..<3 { k.b(.identity, x - 1.4 + Float(i) * 1.4, 1.8, zz, 0.8, 0.6, 0.04, win) } }
        // 門（朝街）：在線＝開著（暗的門洞）；離線＝關上
        if on { k.b(.identity, x, 0, z - 1.71, 1.0, 1.6, 0.04, TM.f(TP.FN6)) }
        else { k.b(.identity, x, 0, z - 1.73, 1.1, 1.65, 0.08, Self.m(TP.ST2)) }
        // 屋頂招牌燈：綠＝在線、灰＝離線／還沒測
        k.b(.identity, x + 1.6, 3.16, z, 0.3, 0.3, 0.3, on ? TM.glow(0x22C55E, 0.6, 1.8) : TM.f(0x6B7280))
        k.b(.identity, x, 0, z - 2.4, 1.0, 0.07, 1.3, road)       // 接到街上的小路
        label(s.id, SIMD3(x, 4.3, z), CityText.server(s), alert: s.alert, hit: (SIMD3(x, 1.5, z), SIMD3(4.6, 3.2, 3.6)))
    }

    // MARK: 港口

    static let waterX0: Float = 4, waterX1: Float = 44, waterZ0: Float = CityBuilder.streetZ + 2.2, waterZ1: Float = CityBuilder.streetZ + 9

    private func buildPort(_ k: Kit, _ s: CityState) {
        let water = Self.water
        k.b(.identity, (Self.waterX0 + Self.waterX1) / 2, 0, (Self.waterZ0 + Self.waterZ1) / 2, Self.waterX1 - Self.waterX0, 0.03, Self.waterZ1 - Self.waterZ0, water)   // 大地面頂在 y=0：水面高 3 cm（太近會閃）
        // 碼頭：沿街的岸壁＋伸出去的棧橋
        k.b(.identity, (Self.waterX0 + Self.waterX1) / 2, 0, Self.waterZ0 + 0.3, Self.waterX1 - Self.waterX0, 0.14, 0.6, Self.m(TP.ST2))
        k.b(.identity, 7.0, 0, Self.waterZ0 + 3.4, 2.0, 0.14, 6.2, Self.m(TP.ST2))
        // 另外兩邊的岸（10-21 稽核：原本水面另外兩邊直接貼著地面，像一塊藍色地墊，不像港）
        k.b(.identity, Self.waterX0 - 0.15, 0, (Self.waterZ0 + Self.waterZ1) / 2, 0.3, 0.14, Self.waterZ1 - Self.waterZ0, Self.m(TP.ST2))
        k.b(.identity, (Self.waterX0 + Self.waterX1) / 2, 0, Self.waterZ1 + 0.15, Self.waterX1 - Self.waterX0 + 0.3, 0.14, 0.3, Self.m(TP.ST2))
        // 岸邊龍門吊（10-21 第二輪：原本一根柱子＋一條橫臂＋一條吊索，從正面看像十字架 ⇒ 改成真的貨櫃起重機：
        // 四腳門架跨在棧橋上、吊臂往水面伸出去、上面有機房、吊臂下有台車＋吊索＋吊具；沒有任何「一根柱子穿過一條橫桿」的造型）
        tag(k, "crane")
        let cx: Float = 7.0, cz: Float = Self.waterZ0 + 2.2
        let steel = Self.m(TP.ST1), hi = Self.m(0xC98B3C)            // 吊臂、機房用琥珀（港口機具色，跟貨櫃強調色同一個材質）
        let legX: [Float] = [cx - 0.8, cx + 0.8], legZ: [Float] = [cz - 0.7, cz + 0.7], legTop: Float = 0.14 + 3.4
        for x in legX { for z in legZ { k.b(.identity, x, 0.14, z, 0.16, 3.4, 0.16, steel) } }        // 四隻腳
        for x in legX {
            k.b(.identity, x, 0.14, cz, 0.3, 0.16, 1.56, steel)                                       // 腳底的行走台車（沿棧橋）
            k.b(.identity, x, 1.7, cz, 0.12, 0.12, 1.24, steel)                                       // 中段繫桿（夾在兩腳之間）
            k.b(.identity, x, legTop, cz, 0.24, 0.24, 1.56, steel)                                    // 頂部橫樑
        }
        for z in legZ { k.b(.identity, cx, legTop, z, 1.36, 0.24, 0.2, steel) }                       // 門架前後樑（夾在兩條頂部橫樑之間）
        let by = legTop + 0.24                                                                         // 吊臂底面
        k.b(.identity, cx + 1.6, by, cz, 5.8, 0.26, 0.5, hi)                                          // 吊臂（x 4.1–9.9，往水面伸）
        k.b(.identity, cx - 1.05, by + 0.26, cz, 0.7, 0.4, 0.6, steel)                                // 後端配重
        k.b(.identity, cx, by + 0.26, cz, 1.0, 0.6, 0.8, hi)                                          // 機房
        k.b(.identity, cx + 0.62, by + 0.4, cz, 0.24, 0.3, 0.6, Self.window)                          // 機房的窗（朝水面）
        k.b(.identity, cx, by + 0.86, cz, 0.18, 0.12, 0.18, Self.lamp)                                // 機房頂燈
        let tx = cx + 3.2                                                                              // 台車（吊臂下）
        k.b(.identity, tx, by - 0.18, cz, 0.6, 0.18, 0.6, steel)
        for dx: Float in [-0.2, 0.2] { k.b(.identity, tx + dx, 2.26, cz, 0.03, by - 0.18 - 2.26, 0.03, steel) }   // 兩條吊索
        k.b(.identity, tx, 2.12, cz, 1.5, 0.14, 0.5, hi)                                              // 吊具（跟貨櫃一樣長）
        tag(k, nil)
        // 夜晚水面：燈的倒影（幾條細長亮線，沿視線方向；水本身不發光）
        for (gx, len) in [(cx + 0.05, 2.6), (cx + 0.3, 1.6), (cx + 0.55, 2.2)] as [(Float, Float)] {
            k.b(.identity, gx + 1.4, 0.03, cz + 1.4 + len / 2, 0.08, 0.012, len, Self.glint)
        }
        // 停著的貨櫃：疊在棧橋末端（10-21 稽核：原本放在 x 4.8 的水面上，整疊浮在水上）
        tag(k, "container-port")
        for i in 0..<3 { k.b(.identity, 7.0, 0.14 + Float(i) * 0.7, Self.waterZ0 + 5.6, 1.5, 0.66, 0.9, Self.m(Self.containerColors[i])) }
        tag(k, nil)
        label("city:port", SIMD3(9.5, 5.4, cz), "港口・GitHub\(s.repos > 0 ? " \(s.repos) 個 repo" : "")", alert: false,
              hit: (SIMD3(8, 2, cz + 1), SIMD3(6, 4.5, 6)))
    }

    /// 出港：新的船從棧橋邊往右開出去 4 秒後消失（playFor，不常駐）。不能播（被蓋住、太熱）＝不開船；測試視窗定在第 1.5 秒
    private func updateShips(_ list: [CityShip], animate: Bool) -> TimeInterval {
        var play: TimeInterval = 0
        let live = Set(list.map(\.id))
        for (id, n) in ships where !live.contains(id) && n.action(forKey: "sail") == nil { n.removeFromParentNode(); ships[id] = nil }
        for (i, s) in list.suffix(Self.maxShips).enumerated() where !seenShips.contains(s.id) {
            seenShips.insert(s.id)
            let posed = BoardWindow.testMode
            guard animate || posed else { continue }
            let n = makeShip(s.repo)
            let start = SIMD3<Float>(10.4, 0, Self.waterZ0 + 2.0 + Float(i) * 1.6)   // 10-21 稽核：原本 8.6 船身插進棧橋與起重機腳
            n.simdPosition = start
            root.addChildNode(n)
            ships[s.id] = n
            if posed {
                n.simdPosition = start + SIMD3(1.5 / Float(Self.shipDuration) * 13, 0, 0)
            } else {
                n.runAction(.sequence([.moveBy(x: 13, y: 0, z: 0, duration: Self.shipDuration), .fadeOut(duration: 0.2), .removeFromParentNode()]), forKey: "sail")   // 水面延伸到 x 44，船不會開上岸
                play = max(play, Self.shipDuration + 0.4)
            }
        }
        if seenShips.count > 200 { seenShips = Set(seenShips.suffix(50)) }
        return play
    }

    private func makeShip(_ repo: String) -> SCNNode {
        let n = SCNNode(); n.name = "ship"
        let m = VoxelMesh(), k = Kit(m: m)
        k.b(.identity, 0, -0.05, 0, 3.2, 0.55, 1.2, TM.f(TP.FN3))
        k.b(.identity, 1.75, -0.05, 0, 0.4, 0.4, 0.8, TM.f(TP.FN3))
        k.b(.identity, -1.2, 0.5, 0, 0.7, 0.8, 0.9, Self.m(TP.FN5))
        k.b(.identity, -1.2, 0.95, 0.46, 0.5, 0.18, 0.02, Self.lamp)
        for i in 0..<3 { k.b(.identity, -0.3 + Float(i) * 0.75, 0.5, 0, 0.7, 0.55, 0.85, Self.m(Self.containerColors[(i + repo.count) % Self.containerColors.count])) }
        let sn = m.node(); sn.categoryBitMask = OfficeBuilder.outdoorMask
        n.addChildNode(sn)
        let a = SCNNode(); a.name = "anchor"; a.simdPosition = SIMD3(0, 1.8, 0)
        n.addChildNode(a)
        return n
    }

    /// 船的名牌（錨點跟著船走）
    var shipLabels: [(id: String, anchor: SCNNode, text: String)] {
        ships.compactMap { id, n in n.childNode(withName: "anchor", recursively: false).map { ("ship:\(id)", $0, "⛴ \(id.split(separator: "@").first ?? "")") } }
    }

    // MARK: 飛艇

    private func buildAirship(_ k: Kit, _ c: CityCloud, x: Float, y: Float, z: Float) {
        let body = Self.m(TP.FN5), shade = Self.m(TP.POT)
        k.b(.identity, x, y, z, 5.2, 1.6, 1.6, body)
        k.b(.identity, x, y + 0.2, z, 4.0, 1.2, 2.0, body)
        k.b(.identity, x + 3.0, y + 0.35, z, 0.8, 0.9, 1.0, shade)
        k.b(.identity, x - 3.0, y + 0.35, z, 0.8, 0.9, 1.0, shade)
        k.b(.identity, x - 3.3, y + 1.0, z, 0.9, 1.0, 0.08, Self.m(TP.ST2))       // 尾翼
        k.b(.identity, x - 3.3, y + 0.55, z, 0.9, 0.08, 1.8, Self.m(TP.ST2))
        k.b(.identity, x + 0.3, y - 0.45, z, 1.6, 0.45, 0.7, Self.m(TP.ST1))      // 吊艙
        // 繫留塔（10-21 稽核：飛艇原本懸在半空、沒有任何支撐）：機頭頂在塔頂的繫留臂上，塔底一塊水泥停機坪
        let mx = x + 3.75
        k.b(.identity, mx, 0, z, 1.2, 0.1, 1.2, Self.m(TP.ST2))
        for (dx, dz) in [(-0.3, -0.3), (0.3, -0.3), (-0.3, 0.3), (0.3, 0.3)] as [(Float, Float)] { k.b(.identity, mx + dx, 0.1, z + dz, 0.1, y + 0.25, 0.1, Self.m(TP.ST1)) }
        for yy in stride(from: Float(1.4), to: y, by: 1.4) { k.b(.identity, mx, yy, z, 0.7, 0.06, 0.7, Self.m(TP.ST1)) }
        k.b(.identity, mx, y + 0.35, z, 0.8, 0.2, 0.8, Self.m(TP.ST1))
        k.b(.identity, mx - 0.35, y + 0.3, z, 0.3, 0.14, 0.14, Self.m(TP.ST1))           // 繫留臂：接到機頭
        k.b(.identity, mx, y + 0.55, z, 0.16, 0.16, 0.16, Self.lamp)                    // 塔頂燈（跟路燈同一個材質，不多一個 draw call）
        // 狀態燈：讀得到同步狀態＝綠、卡住／快滿＝紅；只知道連著＝灰（不假裝在同步）
        k.b(.identity, x + 1.2, y - 0.3, z + 0.36, 0.16, 0.16, 0.04, c.alert ? Self.red : c.known ? TM.glow(0x22C55E, 0.6, 1.8) : TM.f(0x9CA3AF))
        label(c.id, SIMD3(x, y + 2.0, z), CityText.cloud(c), alert: c.alert, hit: (SIMD3(x, y + 0.3, z), SIMD3(7, 2.4, 2.2)))
    }

    /// 俯瞰取景要框的範圍
    static var bounds: (lo: SIMD3<Double>, hi: SIMD3<Double>) {
        (SIMD3(Double(x0) - 1, 0, Double(z0) - 5), SIMD3(Double(x1) + 1, 9, Double(waterZ1)))
    }
}

// MARK: - 細節卡（點城市的建築）＋懸停卡（10-21 第二輪：滑鼠停在建築或名牌上就浮出來，內容跟細節卡共用 CityDetail）

struct CityCard: View {
    let id: String
    let city: CityState
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(CityDetail.title(id, city)).font(.headline).lineLimit(1)
                if city.demo { Text("示範資料").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("關閉").keyboardShortcut(.cancelAction)
            }
            CityDetail(id: id, city: city).font(.callout)
        }
        .padding(12)
        .frame(width: 440, alignment: .leading)
        .background(AnswerCard.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 懸停卡：跟著滑鼠位置浮出來（不吃滑鼠、不擋點擊）；位置由 OfficeView 夾在畫面內
struct CityHoverCard: View {
    let id: String
    let city: CityState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(CityDetail.title(id, city)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if city.demo { Text("示範資料").font(.caption2).foregroundStyle(.secondary) }
            }
            CityDetail(id: id, city: city, compact: true).font(.system(size: 12))
            Text("點一下釘住").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(width: 320, alignment: .leading)
        .background(AnswerCard.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

/// 城市建築的細節內容（細節卡、懸停卡共用）
struct CityDetail: View {
    let id: String
    let city: CityState
    var compact = false

    static func title(_ id: String, _ city: CityState) -> String {
        if let d = city.disks.first(where: { $0.id == id }) { return "📦 貨櫃堆場・\(CityText.diskName(d))" }
        if let c = city.clouds.first(where: { $0.id == id }) { return "🎈 飛艇・\(c.name)" }
        if let s = city.servers.first(where: { $0.id == id }) { return "🏢 分公司・\(s.alias)" }
        if id == "city:wall" || id.hasPrefix("city:gate:") { return "🧱 城牆・防火牆" }
        if id == "city:power" { return "🏭 電廠・AI 額度（5 小時）" }
        if id == "city:fuel" { return "🛢 油槽・AI 額度（7 天）" }
        if id == "city:cooler" { return "🌫 冷卻水塔・cool42" }
        if id == "city:port" { return "⚓ 港口・GitHub" }
        if id.hasPrefix("ship:") { return "⛴ 出港・\(id.dropFirst(5).split(separator: "@").first ?? "")" }
        return "城市"
    }

    /// 「3 分鐘前」「昨天 14:05」這種
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "剛剛" }
        if s < 3600 { return "\(Int(s / 60)) 分鐘前" }
        if s < 86400 { return "\(Int(s / 3600)) 小時前（\(d.formatted(date: .omitted, time: .shortened))）" }
        return d.formatted(.dateTime.month().day().hour().minute())
    }

    private func row(_ k: String, _ v: String, warn: Bool = false) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).foregroundStyle(warn ? Color.red : Color.primary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ t: String) -> some View { Text(t).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
    }

    @ViewBuilder private var content: some View {
        if let d = city.disks.first(where: { $0.id == id }) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row("種類", d.isInternal ? "內建碟（資料卷）" : "外接碟")
                if !d.mounted {
                    row("狀態", "已拔除")
                    row("最後看到", d.lastSeen.map { Self.ago($0) } ?? "不知道（這版之前就拔掉了）")
                } else if let u = d.used {
                    row("總容量", CityText.bytes(d.total))
                    row("已用", "\(CityText.bytes(d.total - d.available))（\(Int((u * 100).rounded()))%）", warn: d.alert)
                    if d.isInternal {
                        row("可用", "\(CityText.bytes(d.availablePlain))（現在空著的）")
                        row("重要用途可用", "\(CityText.bytes(d.available))（含系統可清出的快取）")
                    } else {
                        row("可用", CityText.bytes(d.available))
                    }
                    if let f = d.format { row("檔案系統", f) }
                    if let m = d.mountPath { row("掛載點", m) }
                } else {
                    row("容量", "讀不到")
                }
            }
            if d.mounted, let u = d.used { UsageBar(value: u, alert: d.alert) }
            if !compact { note(d.alert ? "90% 以上：貨櫃堆到圍籬外、倉庫頂亮紅燈" : "貨櫃層數＝已用比例（滿 4 層＝100%）") }
        } else if let c = city.clouds.first(where: { $0.id == id }) {
            if c.isICloud, let s = c.sync {
                let now = c.checkedAt ?? Date()
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    row("剩餘額度", s.remaining.map { CityText.bytes($0) } ?? "讀不到", warn: (s.remaining ?? .max) < CloudSync.lowQuota)
                    row("iCloud Drive", s.stuck(now: now) ? "同步卡住（\(s.driveState ?? "")）" : s.driveState == "idle" ? (s.caughtUp ? "已同步" : "閒置") : "同步中（\(s.driveState ?? "")）",
                        warn: s.stuck(now: now))
                    row("上次同步", s.lastSync.map { Self.ago($0, now: now) } ?? "沒有紀錄")
                    row("待同步", s.pending == 0 ? "沒有" : "\(s.pending) 個 App 的資料")
                    row("被擋住", s.blocked == 0 ? "沒有" : "\(s.blocked) 個 App 的資料", warn: s.blocked > 0)
                    if let dd = s.desktopDocs { row("桌面與文件", dd ? "有同步到 iCloud" : "沒有同步") }
                }
                note("總額度 macOS 沒給讀，所以只寫剩多少；剩不到 5 GB 才警示。已刪除 App 的資料停止同步是正常的，不算。本機佔用不讀（掃 iCloud 資料夾會跳隱私權限視窗）。每 5 分鐘讀一次")
            } else {
                Text(c.isICloud ? "已連線（iCloud Drive 資料夾在這台 Mac 上；brctl 讀不到同步狀態）" : "已連線（資料夾掛在 ~/Library/CloudStorage）")
                note(c.isICloud ? "" : "同步進度由 \(c.name) 自己的程式管，macOS 沒開放給其他程式讀")
            }
        } else if let s = city.servers.first(where: { $0.id == id }) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row("狀態", s.online == nil ? "檢查中" : s.online! ? "在線" : "離線", warn: s.alert)
                row("上次連上", s.lastOnline.map { Self.ago($0) } ?? "這次開程式後還沒連上過", warn: s.alert)
                row("延遲", s.latencyMs.map { "\($0) ms（TCP 連線）" } ?? "—")
                if let h = s.hostName { row("位址", "\(h):\(s.port ?? 22)") }
                row("上次檢查", s.checkedAt.map { Self.ago($0) } ?? "還沒")
            }
            if !compact { note("來自 ~/.ssh/config；每 60 秒對 ssh 埠連一次（2 秒逾時，只連這一個埠）") }
        } else if id == "city:wall" || id.hasPrefix("city:gate:") {
            let f = city.firewall
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row("防火牆", f.enabled == nil ? "讀不到" : f.enabled! ? "開著" : "關閉（城牆有缺口）", warn: f.enabled == false)
                row("對外開放", "\(f.gates.count) 個埠" + (f.openRed.isEmpty ? "" : "，\(f.openRed.count) 個沒有認證"), warn: !f.openRed.isEmpty)
                row("只給本機", "\(f.doors.count) 個埠")
            }
            if !f.gates.isEmpty {
                Text("對外城門（別台電腦連得到）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(f.gates.prefix(compact ? 8 : 20).enumerated()), id: \.offset) { _, g in
                        HStack(spacing: 6) {
                            Text(verbatim: String(g.port)).monospacedDigit().frame(width: 44, alignment: .trailing)
                            Text(g.knownOpen ?? g.process).lineLimit(1)
                            if g.openRed { Text("⚠ 沒有認證").foregroundStyle(.red) }
                        }.font(.caption)
                    }
                    if f.gates.count > (compact ? 8 : 20) { Text("⋯還有 \(f.gates.count - (compact ? 8 : 20)) 個").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let t = f.checkedAt { note("每 5 分鐘檢查；上次 \(Self.ago(t))") }
        } else if id == "city:power" || id == "city:fuel" {
            let g = city.grid, now = Date()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row("5 小時", CityRules.pct(g.fiveUsed).map { "已用 \($0)%・剩 \(100 - $0)%" } ?? "讀不到", warn: g.alert)
                row("重置", g.fiveReset.map { CityText.clock($0, now: now) } ?? "—")
                row("7 天", CityRules.pct(g.sevenUsed).map { "已用 \($0)%・剩 \(100 - $0)%" } ?? "讀不到", warn: (g.sevenLeft ?? 100) <= 5)
                row("重置", g.sevenReset.map { CityText.clock($0, now: now) } ?? "—")
                row("電力", ["正常", "節電（80% 以上，燈調暗）", "吃緊（95% 以上）", "停電（用完，AI 定格）"][g.stage.rawValue], warn: g.alert)
            }
            if let u = g.fiveLeft { UsageBar(value: 1 - u / 100, alert: g.alert) }
            if !compact { note("資料來自狀態列存的 rate_limits.json（有 session 在跑才會更新）；數字跟視窗右上角同一份") }
        } else if id == "city:cooler" {
            let p = city.power
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row("溫度", p.temp.map { "約 \(CityRules.tempStep($0))°C（控制溫度，10°C 一格）" } ?? "cool42 沒在跑", warn: p.alert)
                row("CPU 平均", p.cpuAvg.map { "\(Int($0.rounded()))°C" } ?? "—")
                row("cool42 等級", (p.level ?? "—") + (p.stale ? "（超過 2 分鐘沒更新）" : ""), warn: p.alert)
            }
            if !compact { note("在大樓頂樓；煙越多越熱，hot 以上亮紅燈") }
        } else if id == "city:port" || id.hasPrefix("ship:") {
            Text("看著 \(city.repos) 個 repo 的遠端分支")
            if !city.recent.isEmpty {
                Text("最近 push／fetch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(city.recent.enumerated()), id: \.offset) { _, r in
                        HStack(spacing: 6) { Text(r.repo).lineLimit(1); Spacer(minLength: 4); Text(Self.ago(r.at)).foregroundStyle(.secondary) }.font(.caption)
                    }
                }
            }
            if !city.ships.isEmpty { Text("剛出港：" + city.ships.map(\.repo).joined(separator: "、")).font(.caption) }
            if !compact { note("剛 push／fetch 有新東西，就有一艘貨船出港（時間＝遠端 ref 檔的修改時間）") }
        }
    }
}

/// 使用率長條（≥90% 紅）
struct UsageBar: View {
    let value: Double
    var alert = false
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(alert ? Color.red : value >= 0.75 ? Color.orange : Color.accentColor)
                    .frame(width: max(4, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
    }
}
