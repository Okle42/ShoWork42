import AppKit
import SceneKit
import ShoWorkCore

// 螢幕空間標籤（10-20 第 2 棒 UI/UX 優化，規劃 docs/design/office-tower/UIUX優化規劃.md §2.2 C）。
//   原本名牌與頭上符號畫在 3D 世界裡，跟著樓層一起縮：預設鏡頭下名牌 4.8 pt、門牌 5.9 pt，Kang 在電視上完全讀不到。
//   改成疊在 SCNView 上的一層 CALayer（同一個視窗、不另開視窗），固定點數：名字 14 pt、等你回答 16 pt。
//   10-20 實測：原本用 overlaySKScene（SpriteKit），閒置時 CPU 從 0.2% 變 3–4%（SpriteKit 自己一直在跑）⇒ 改 CALayer。
//   位置只在「真的有畫一幀」時才算（SCNSceneRendererDelegate 的 didApplyConstraints，渲染執行緒），算完有變才回主執行緒改圖層：
//   閒置不渲染時不會跑，不加 timer。
//   不讀深度、永遠在 3D 之上（被上一層樓板擋住的人照樣看得到）；碰撞避讓用 ShoWorkCore.LabelLayout（純函式、有測試）。
//   點標籤＝點角色（OfficeSCNView 先問這裡、再問 3D）。

/// 一個要畫的標籤（主執行緒組好、交給渲染執行緒）
struct LabelSpec {
    let id: String              // 卡片 id／guard
    let kind: LabelKind
    let text: String
    let bg: UInt32
    let bgAlpha: CGFloat
    let dot: UInt32?            // 工作中：左側紫點
    let anchor: SCNNode?        // 人的錨點（樓層名、+N、閒置名字不用）
    let floor: String           // 這個人所屬樓層 id（藏起來的算進那層 +N）
    var short: String? = nil    // 樓層在畫面上很小（俯瞰城市）時改用的短字：只留名字（10-21：長句蓋住旁邊的城市）
    /// 玻璃名牌（10-23 Kang：參考 hig42，透明玻璃底＋狀態色文字）：fg＝字色（跟發光設定同一組顏色）
    var fg: UInt32? = nil
    var glass = false
}

struct FloorLabelSpec {
    let id: String
    let node: SCNNode
    let height: Float
    let title: String
    let accent: UInt32?
    let kind: TowerFloorKind
    let names: [String]
}

/// 渲染執行緒上跑的那一半：投影、避讓、改 SpriteKit 節點。資料用鎖保護
final class OfficeLabels: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    /// 疊在 SCNView 上、不吃滑鼠的那一層（主執行緒建、主執行緒改）
    let view: LabelHostView
    private let lock = NSLock()
    private var specs: [LabelSpec] = []
    private var floors: [FloorLabelSpec] = []
    private var size = CGSize(width: 10, height: 10)
    private var textures: [String: (CGImage?, CGSize)] = [:]
    private var shownSig = ""
    private var hits: [(String, CGRect)] = []
    private(set) var lastStats = ""
    /// 拉近到多近才顯示（樓層在畫面上的高度，點）
    static let detailPx: CGFloat = 70, floorNamePx: CGFloat = 80, idleNamesPx: CGFloat = 48, idleTitlePx: CGFloat = 24
    static let maxTextures = 64

    @MainActor override init() {
        view = LabelHostView(frame: .zero)
        super.init()
    }

    // MARK: 主執行緒：交資料

    func set(_ specs: [LabelSpec], floors: [FloorLabelSpec]) {
        lock.lock(); self.specs = specs; self.floors = floors; lock.unlock()
    }
    func resize(_ s: CGSize) { lock.lock(); size = s; lock.unlock() }
    /// 左下角開著卡片（回答卡、保全卡、細節卡）：那一塊不畫標籤（標籤層在 3D 上面，會疊到卡片的字）
    private var occluder: CGRect?
    func setOccluder(_ r: CGRect?) { lock.lock(); let changed = occluder != r; occluder = r; if changed { shownSig = "" }; lock.unlock() }

    /// 點到哪個標籤（主執行緒；座標＝view 座標，y 往上）
    func label(at p: CGPoint) -> String? {
        lock.lock(); defer { lock.unlock() }
        return hits.last { $0.1.contains(p) && !$0.0.hasPrefix("floor:") && !$0.0.hasPrefix("more:") }?.0
    }

    /// 某個標籤現在的框（PROBE 點點看用）
    func rect(_ id: String) -> CGRect? { lock.lock(); defer { lock.unlock() }; return hits.first { $0.0 == id }?.1 }

    var stats: String { lock.lock(); defer { lock.unlock() }; return lastStats + " textures=\(textures.count)" }

    // MARK: 渲染執行緒：每畫一幀

    // 畫幀統計（10-24 查「視窗關著 3D 還在畫」）：每 60 秒一行 OFFICE frames 進 agent.log
    nonisolated(unsafe) static var visibleFlag = true
    private var frameCount = 0, frameSince = Date()
    func renderer(_ renderer: any SCNSceneRenderer, didApplyConstraintsAtTime time: TimeInterval) {
        lock.lock()
        frameCount += 1
        if Date().timeIntervalSince(frameSince) >= 60 {
            Log.note(String(format: "OFFICE frames %d 幀/%.0f 秒 視窗看得到=%@", frameCount, Date().timeIntervalSince(frameSince), Self.visibleFlag ? "是" : "否"))
            frameCount = 0; frameSince = Date()
        }
        let specs = self.specs, floors = self.floors, size = self.size, occ = self.occluder
        lock.unlock()
        let W = Double(size.width), H = Double(size.height)
        let cam = renderer.pointOfView?.presentation.worldPosition ?? SCNVector3(0, 0, 100)
        let hw = CGFloat(TD.W / 2), hd = CGFloat(TD.zF), hb = CGFloat(TD.zB)
        // 面向鏡頭的那一面（10-20 第 4 棒：轉到側面時，樓層名要貼在「看得到的那面」的左上角，不是固定在正面）
        let faces: [(CGFloat, CGFloat, [(CGFloat, CGFloat)])] = [(0, 1, [(-hw, hd), (hw, hd)]), (1, 0, [(hw, hd), (hw, hb)]),
                                                                (0, -1, [(hw, hb), (-hw, hb)]), (-1, 0, [(-hw, hb), (-hw, hd)])]
        let face = faces.max { a, b in a.0 * cam.x + a.1 * cam.z < b.0 * cam.x + b.1 * cam.z }!.2
        // 每層：世界 y 範圍＋看得到那面的左上／右上、左下（點）
        struct FloorGeo { let y0: CGFloat; let y1: CGFloat; let tl: SCNVector3; let tr: SCNVector3; let bl: SCNVector3; let br: SCNVector3; let px: CGFloat; let front: Bool }
        var geo: [String: FloorGeo] = [:]
        for f in floors {
            let y = f.node.presentation.worldPosition.y, top = y + CGFloat(f.height)
            let p0 = renderer.projectPoint(SCNVector3(face[0].0, top, face[0].1)), p1 = renderer.projectPoint(SCNVector3(face[1].0, top, face[1].1))
            let (a, b, left) = p0.x <= p1.x ? (p0, p1, face[0]) : (p1, p0, face[1])
            let right = left == face[0] ? face[1] : face[0]
            var bl = renderer.projectPoint(SCNVector3(left.0, y + CGFloat(TD.room), left.1))
            let br = renderer.projectPoint(SCNVector3(right.0, y + CGFloat(TD.room), right.1))
            // 拉近時樓層左角在畫面外：沿著樓板前緣（畫面上是直線）取畫面左緣那一點，不用畫面外的延伸點（10-20 第 4 棒：04 的名字掛到 05 裡）
            var tl = a
            if a.x < 4, b.x > a.x {
                let t = (4 - a.x) / (b.x - a.x)
                tl = SCNVector3(4, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
                let tb = (4 - bl.x) / max(0.001, br.x - bl.x)
                bl = SCNVector3(4, bl.y + (br.y - bl.y) * tb, bl.z)
            }
            // front：這層看得到那面的兩個上角都在鏡頭前面（10-21 稽核：大樓整個在鏡頭背後時，投影出來的點會落在畫面裡，名字掛在空中）
            let front = [p0, p1, bl, br].allSatisfy { $0.z > 0 && $0.z < 1 }
            geo[f.id] = FloorGeo(y0: y, y1: top, tl: tl, tr: b, bl: bl, br: br, px: abs(tl.y - bl.y), front: front)
        }
        /// 這一點朝鏡頭水平走到大樓外緣（樓板前緣就是你眼睛看到的那條線）
        func edge(_ p: SCNVector3) -> (CGFloat, CGFloat) {
            var dx = cam.x - p.x, dz = cam.z - p.z
            let l = max(0.001, hypot(dx, dz)); dx /= l; dz /= l
            let tx = dx > 0.001 ? (hw - p.x) / dx : dx < -0.001 ? (-hw - p.x) / dx : .infinity
            let tz = dz > 0.001 ? (hd - p.z) / dz : dz < -0.001 ? (-hd - p.z) / dz : .infinity
            let t = max(0, min(tx, tz))
            return (p.x + dx * t, p.z + dz * t)
        }
        // 樓層名（先放、當障礙物）：只在那層真的在畫面裡、標籤整塊塞得進那層時畫；畫面外的樓層不夾到畫面頂端（10-20 第 4 棒：04 掛成 06 的錯標）
        var text: [String: (LabelSpec, CGImage?, CGSize)] = [:]
        var fixed: [PlacedLabel] = []
        for f in floors {
            // 10-21 稽核：整棟在畫面左邊外面時，上面「沿樓板前緣取畫面左緣那一點」會外插出一個假的點，名字掛在空無一物的天上 ⇒ 右角也要在畫面裡
            guard let g = geo[f.id], g.front, g.tl.z > 0, g.tl.z < 1, g.tr.x > 60, g.tl.x < size.width - 40 else { continue }
            let need = f.kind == .idle ? Self.idleTitlePx : Self.floorNamePx
            guard g.px >= need else { continue }
            let s = LabelSpec(id: "floor:\(f.id)", kind: .floor, text: f.title, bg: 0x14161A, bgAlpha: 0.86, dot: f.accent, anchor: nil, floor: f.id)
            let (tex, sz) = texture(s)
            let x = max(2, g.tl.x + 8)
            let y = f.kind == .idle ? (g.tl.y + g.bl.y) / 2 - sz.height / 2 : min(g.tl.y - sz.height - 8, size.height - sz.height - 4)
            guard y >= g.bl.y + 2 || f.kind == .idle, y >= 2, y + sz.height <= size.height, x + sz.width <= size.width else { continue }
            text[s.id] = (s, tex, sz)
            fixed.append(PlacedLabel(id: s.id, kind: .floor, x: Double(x), y: Double(y), w: Double(sz.width), h: Double(sz.height), leader: false, ax: 0, ay: 0))
        }
        // 每個人：錨點投影；自己那層的天花／地坪（朝鏡頭的外緣）在畫面上的 y ⇒ 標籤不得越層
        var boxes: [LabelBox] = []
        var cityBoxes: [LabelBox] = []
        var cityDist: [String: CGFloat] = [:]
        var hiddenSmall: [String: Int] = [:]
        var anchorAt: [String: CGPoint] = [:]
        for s in specs {
            // 錨點已經不在場景裡（出港的船開完了）：不畫
            guard let anchor = s.anchor, anchor.parent != nil else { continue }
            let wp = anchor.presentation.worldPosition
            let p = renderer.projectPoint(wp)
            guard p.z > 0, p.z <= 1, p.x > -40, p.x < size.width + 40, p.y > -40, p.y < size.height + 60 else { continue }
            // 外部空間城市（10-21）：不屬於任何樓層；另外放（大樓當障礙物，名牌不壓到大樓）
            if s.floor == "city" {
                guard p.x >= 0, p.x <= size.width, p.y >= 0, p.y <= size.height else { continue }
                let (tex, sz) = texture(s)
                text[s.id] = (s, tex, sz)
                anchorAt[s.id] = CGPoint(x: p.x, y: p.y)
                cityBoxes.append(LabelBox(id: s.id, kind: s.kind, ax: Double(p.x), ay: Double(p.y), w: Double(sz.width), h: Double(sz.height), group: "city"))
                cityDist[s.id] = hypot(wp.x - cam.x, wp.z - cam.z)      // 水平距離（跟大樓軸比）
                continue
            }
            // 錨點在哪一層（走在路上的人照所在高度算）
            // B1（地面以下，10-22）：不屬於任何樓層，自成一組、不受樓層天花限制（原本歸到自己樓層 ⇒ 擺不下被收起來）
            let fid = wp.y < -0.5 ? "b1" : floors.first { f in let g = geo[f.id]; return g.map { wp.y >= $0.y0 && wp.y < $0.y1 } ?? false }?.id ?? s.floor
            var ceil = Double.infinity, bottom = -Double.infinity, floorPx = CGFloat(999)
            if let g = geo[fid] {
                let (ex, ez) = edge(wp)
                let c = renderer.projectPoint(SCNVector3(ex, g.y1, ez)), b = renderer.projectPoint(SCNVector3(ex, g.y0 + CGFloat(TD.room), ez))
                ceil = Double(c.y) + 3; bottom = Double(b.y) + 2      // 評審上限：天花 +4 pt
                // 轉到側面時人在樓層深處：從鏡頭看頭頂已經在上一層樓板前緣「上面」（被樓板擋住）⇒ 改用人那個深度的天花，名牌跟著頭走
                if Double(p.y) + 4 > ceil {
                    ceil = Double(renderer.projectPoint(SCNVector3(wp.x, g.y1, wp.z)).y) + 3
                }; floorPx = g.px
            }
            if !s.kind.mustShow && floorPx < Self.detailPx { hiddenSmall[fid, default: 0] += 1; continue }
            var s = s
            if floorPx < Self.detailPx, let t = s.short {
                s = LabelSpec(id: s.id, kind: s.kind, text: t, bg: s.bg, bgAlpha: s.bgAlpha, dot: s.dot, anchor: s.anchor, floor: s.floor)
            }
            let (tex, sz) = texture(s)
            text[s.id] = (s, tex, sz)
            anchorAt[s.id] = CGPoint(x: p.x, y: p.y)
            boxes.append(LabelBox(id: s.id, kind: s.kind, ax: Double(p.x), ay: Double(p.y), w: Double(sz.width), h: Double(sz.height), group: fid,
                                  ceil: ceil, floorY: bottom))
        }
        let (placed, hidden) = LabelLayout.place(boxes, width: W, height: H, fixed: fixed)
        // 每層被收起來的「+N」放在那層看得到那面的右上角；收起來的有等你／卡住的 ⇒ 紅底
        let urgentHidden = Set(boxes.filter { b in b.kind.mustShow && !placed.contains { $0.id == b.id } }.map(\.group))
        var more: [PlacedLabel] = []
        for (fid, n) in hidden.merging(hiddenSmall, uniquingKeysWith: +) where n > 0 {
            guard let g = geo[fid] else { continue }
            let urgent = urgentHidden.contains(fid)
            let s = LabelSpec(id: "more:\(fid)", kind: .more, text: urgent ? "! +\(n) 人" : "+\(n) 人", bg: urgent ? 0xEF4444 : 0x14161A,
                              bgAlpha: urgent ? 1 : 0.75, dot: nil, anchor: nil, floor: fid)
            let (tex, sz) = texture(s)
            text[s.id] = (s, tex, sz)
            guard g.front, g.tr.x > 60, g.tl.x < size.width - 40 else { continue }
            let y0 = min(g.tr.y - sz.height - 8, size.height - sz.height - 4)
            guard y0 >= g.bl.y else { continue }
            // 10-21 稽核：「+N 人」原本直接蓋在那層右上角，會壓到已經放好的名牌（側面看時 Bella 的名牌被「+1 人」蓋住）⇒ 往下、再往左找空位
            let x0 = Double(min(g.tr.x - sz.width - 8, size.width - sz.width - 4))
            let others = fixed + placed + more
            func free(_ x: Double, _ y: Double) -> Bool {
                !others.contains { o in x < o.x + o.w + 4 && o.x < x + Double(sz.width) + 4 && y < o.y + o.h + 3 && o.y < y + Double(sz.height) + 3 }
            }
            var spot: (Double, Double)?
            search: for dx in stride(from: 0.0, through: 240, by: 60) {
                for dy in stride(from: 0.0, through: Double(y0 - g.bl.y), by: Double(sz.height) + 4) where x0 - dx >= 2 {
                    if free(x0 - dx, Double(y0) - dy) { spot = (x0 - dx, Double(y0) - dy); break search }
                }
            }
            guard let (mx, my) = spot else { continue }
            more.append(PlacedLabel(id: s.id, kind: .more, x: mx, y: my,
                                    w: Double(sz.width), h: Double(sz.height), leader: false, ax: 0, ay: 0))
        }
        // 城市名牌：大樓（每層一塊，含電梯井、溜滑梯）在畫面上的範圍當障礙物，再避開已經放好的標籤
        var bldg: [PlacedLabel] = []
        var cityPlaced: [PlacedLabel] = []
        var cityHidden = 0
        if !cityBoxes.isEmpty {
            for f in floors {
                let y0 = f.node.presentation.worldPosition.y, y1 = y0 + CGFloat(f.height) + (f.kind == .roof ? 1.2 : 0)
                var x0 = CGFloat.infinity, x1 = -CGFloat.infinity, b0 = CGFloat.infinity, b1 = -CGFloat.infinity, ok = true
                for x: CGFloat in [-7.9, 6.6] { for y in [y0, y1] { for z: CGFloat in [-4.6, 3.0] {
                    let q = renderer.projectPoint(SCNVector3(x, y, z))
                    if q.z <= 0 || q.z >= 1 { ok = false }
                    x0 = min(x0, q.x); x1 = max(x1, q.x); b0 = min(b0, q.y); b1 = max(b1, q.y)
                } } }
                guard ok else { continue }
                bldg.append(PlacedLabel(id: "bldg:\(f.id)", kind: .floor, x: Double(x0), y: Double(b0), w: Double(x1 - x0), h: Double(b1 - b0), leader: false, ax: 0, ay: 0))
            }
            // 10-21 稽核：被大樓擋住的建築（錨點在大樓畫面範圍內、而且比大樓離鏡頭遠）名牌不畫——原本名牌浮在大樓旁邊的天上，指著看不到的東西
            let towerDist = hypot(cam.x, cam.z) + CGFloat(TD.zF)
            cityBoxes.removeAll { b in
                (cityDist[b.id] ?? 0) > towerDist && bldg.contains { r in b.ax >= r.x && b.ax <= r.x + r.w && b.ay >= r.y && b.ay <= r.y + r.h }
            }
            let (cp, ch) = LabelLayout.place(cityBoxes, width: W, height: H, fixed: fixed + bldg + placed + more)
            cityPlaced = cp; cityHidden = ch.values.reduce(0, +)
        }
        // 10-22 Kang：閒置薄層正面已是 Okle42 招牌，樓層名和專案名字標籤會擋住招牌 ⇒ 都不畫（清單在左側索引列「閒置」）
        let idleIds = Set(floors.filter { $0.kind == .idle }.map { "floor:\($0.id)" })
        fixed.removeAll { idleIds.contains($0.id) }
        let idle: [PlacedLabel] = []
        let all = idle + fixed + cityPlaced.reversed() + placed.reversed() + more        // 後畫的在上面：優先序高的最後畫
        var items: [LabelHostView.Item] = []
        for p in all {
            guard let (_, img, sz) = text[p.id] else { continue }
            if let occ, occ.intersects(CGRect(x: p.x, y: p.y, width: sz.width, height: sz.height)) { continue }
            items.append(.init(id: p.id, image: img, frame: CGRect(x: p.x.rounded(), y: p.y.rounded(), width: sz.width, height: sz.height),
                               leader: p.leader ? CGRect(x: p.ax - 0.75, y: p.ay, width: 1.5, height: max(1, p.y - p.ay)) : nil))
        }
        // 有變才回主執行緒改圖層（位置四捨五入到點；鏡頭沒動時每幀都一樣 ⇒ 不排工作）
        let sig = items.map { "\($0.id)@\(Self.int($0.frame.minX)),\(Self.int($0.frame.minY))" }.joined(separator: ";")
        lock.lock(); let changed = sig != shownSig; if changed { shownSig = sig }; lock.unlock()
        if changed {
            let host = view
            DispatchQueue.main.async { MainActor.assumeIsolated { host.apply(items) } }
        }
        let rects = (placed + cityPlaced + more + fixed).map { ($0.id, CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)) }
        let minH = placed.map(\.h).min() ?? 0
        // 驗收：標籤離本人頭頂多遠（標籤框上最近的一點，點）、有沒有越過自己那層的天花
        var maxDist = 0.0, outOfFloor = 0, far: [String] = []
        for p in placed {
            guard let a = anchorAt[p.id], let b = boxes.first(where: { $0.id == p.id }) else { continue }
            let dx = max(p.x - Double(a.x), 0, Double(a.x) - (p.x + p.w)), dy = max(p.y - Double(a.y), 0, Double(a.y) - (p.y + p.h))
            maxDist = max(maxDist, hypot(dx, dy))
            if hypot(dx, dy) > 24 { far.append("\(p.id.prefix(8))=\(Self.int(hypot(dx, dy)))@a(\(Self.int(a.x)),\(Self.int(a.y)))r(\(Self.int(p.x)),\(Self.int(p.y)),\(Self.int(p.w)))c\(Self.int(b.ceil))") }
            if p.y + p.h > b.ceil + 1 || p.y < b.floorY - 1 { outOfFloor += 1 }
        }
        let cityOnBldg = cityPlaced.filter { c in bldg.contains { $0.overlaps(c) } }.count
        let stat = "labels n=\(placed.count) overlaps=\(LabelLayout.overlaps(placed + fixed + more + cityPlaced)) city=\(cityPlaced.count)/hidden \(cityHidden)/onBuilding \(cityOnBldg) more=\(more.count) floors=\(fixed.count) idleNames=\(idle.count) "
            + "minH=\(String(format: "%.0f", minH))pt maxDist=\(String(format: "%.0f", maxDist))pt far=[\(far.joined(separator: ","))] outOfFloor=\(outOfFloor) "
            + "kinds=" + Dictionary(grouping: placed, by: { "\($0.kind)" }).map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ",")
            + " floorNames=" + fixed.map { $0.id.replacingOccurrences(of: "floor:", with: "") }.joined(separator: ",")
        lock.lock(); hits = rects; lastStats = stat; lock.unlock()
    }

    /// 10-23：診斷字串用。B1 沒有樓層幾何 ⇒ 天花是 +∞，Int(∞) 直接當（10-22 17:13 起當 19 次）
    static func int(_ d: some BinaryFloatingPoint) -> String { d.isFinite ? String(Int(d)) : (d.isNaN ? "nan" : (d > 0 ? "inf" : "-inf")) }

    // MARK: 貼圖（同字串只畫一次；超過 64 張整批清掉重畫）

    private func texture(_ s: LabelSpec) -> (CGImage?, CGSize) {
        let key = "\(s.kind.rawValue)|\(s.bg)|\(s.dot ?? 0)|\(s.fg ?? 0)|\(s.glass)|\(s.text)"
        if let t = textures[key] { return t }
        if textures.count >= Self.maxTextures { textures.removeAll() }
        let t = Self.draw(s)
        textures[key] = t
        return t
    }

    static func font(_ k: LabelKind) -> NSFont {
        switch k {
        case .waiting: .systemFont(ofSize: 16, weight: .heavy)
        case .stuck: .systemFont(ofSize: 14, weight: .bold)
        case .finished, .working: .systemFont(ofSize: 14, weight: .semibold)
        case .rest, .idleName, .more: .systemFont(ofSize: 13, weight: .medium)
        case .floor, .guardian: .systemFont(ofSize: 13, weight: .semibold)
        case .cityAlert: .systemFont(ofSize: 14, weight: .bold)
        case .city: .systemFont(ofSize: 12, weight: .medium)
        }
    }

    /// 圓角底＋字（2× 像素，Retina 與 1080p 電視都清楚）
    static func draw(_ s: LabelSpec) -> (CGImage?, CGSize) {
        if s.glass { return drawGlass(s) }
        let f = font(s.kind)
        let fg: NSColor = s.kind == .rest ? VoxMat.color(0xD6D3CE) : s.kind == .idleName ? VoxMat.color(TP.INK) : .white
        let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: fg]
        let ts = (s.text as NSString).size(withAttributes: a)
        let padX: CGFloat = 7, dotW: CGFloat = s.dot == nil ? 0 : (s.kind == .floor ? 7 : 12)
        let W = ceil(ts.width + padX * 2 + dotW), H = ceil(ts.height + 6)
        let scale: CGFloat = 2
        guard let sp = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0, space: sp,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, CGSize(width: W, height: H)) }
        ctx.scaleBy(x: scale, y: scale)
        let r = CGRect(x: 0, y: 0, width: W, height: H)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(VoxMat.color(s.bg).withAlphaComponent(s.bgAlpha).cgColor); ctx.fillPath()
        if let d = s.dot {
            ctx.setFillColor(VoxMat.color(d).cgColor)
            if s.kind == .floor { ctx.fill(CGRect(x: 0, y: 0, width: 4, height: H)) }
            else { ctx.fillEllipse(in: CGRect(x: padX, y: (H - 8) / 2, width: 8, height: 8)) }
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (s.text as NSString).draw(at: NSPoint(x: padX + dotW, y: (H - ts.height) / 2), withAttributes: a)
        NSGraphicsContext.restoreGraphicsState()
        return (ctx.makeImage(), CGSize(width: W, height: H))
    }

    /// 玻璃名牌（hig42 §3.1a：底下是任意 3D 畫面 ⇒ clear 玻璃＋暗化層，不用 regular）。
    /// 點陣圖模擬（標籤是 CALayer 點陣圖，跟著人每幀移動；真的背景模糊要每個標籤一個 NSVisualEffectView，太貴）：
    /// 膠囊形、約 40% 深色暗化層、上半部一道淡白反光、只有上緣亮（下緣極淡）的邊光，字用狀態色＋一圈淡陰影（亮背景上也讀得到）
    static func drawGlass(_ s: LabelSpec) -> (CGImage?, CGSize) {
        let f = font(s.kind)
        let fg = s.fg.map { VoxMat.color($0) } ?? .white
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.55); sh.shadowBlurRadius = 2; sh.shadowOffset = .zero
        let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: fg, .shadow: sh]
        let ts = (s.text as NSString).size(withAttributes: a)
        let padX: CGFloat = 9
        let W = ceil(ts.width + padX * 2), H = ceil(ts.height + 7)
        let scale: CGFloat = 2
        guard let sp = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0, space: sp,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, CGSize(width: W, height: H)) }
        ctx.scaleBy(x: scale, y: scale)
        let r = CGRect(x: 0, y: 0, width: W, height: H)
        let cap = CGPath(roundedRect: r, cornerWidth: H / 2, cornerHeight: H / 2, transform: nil)
        // 暗化層（稍微帶一點狀態色，玻璃「吸收」顏色）
        ctx.addPath(cap); ctx.setFillColor(NSColor(srgbRed: 0.07, green: 0.08, blue: 0.1, alpha: s.kind == .rest ? 0.34 : 0.42).cgColor); ctx.fillPath()
        ctx.addPath(cap); ctx.setFillColor(fg.withAlphaComponent(0.08).cgColor); ctx.fillPath()
        // 上半部反光
        ctx.saveGState(); ctx.addPath(cap); ctx.clip()
        if let g = CGGradient(colorsSpace: sp, colors: [NSColor(white: 1, alpha: 0.2).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H * 0.45), options: [])
        }
        ctx.restoreGState()
        // 邊光：上緣亮、下緣淡（Dock／widget 的方向性）
        ctx.saveGState(); ctx.addPath(cap); ctx.clip()
        if let g = CGGradient(colorsSpace: sp, colors: [NSColor(white: 1, alpha: 0.55).cgColor, NSColor(white: 1, alpha: 0.06).cgColor, NSColor(white: 1, alpha: 0.18).cgColor] as CFArray, locations: [0, 0.6, 1]) {
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.4, dy: 0.4), cornerWidth: H / 2 - 0.4, cornerHeight: H / 2 - 0.4, transform: nil))
            ctx.setLineWidth(0.8); ctx.replacePathWithStrokedPath(); ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: .zero, options: [])
        }
        ctx.restoreGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (s.text as NSString).draw(at: NSPoint(x: padX, y: (H - ts.height) / 2), withAttributes: a)
        NSGraphicsContext.restoreGraphicsState()
        return (ctx.makeImage(), CGSize(width: W, height: H))
    }

    /// 狀態色（跟終端機發光同一組設定，改了發光顏色名牌跟著變）。太暗的顏色往白提亮，玻璃上才讀得到
    @MainActor static func glassText(_ m: Mood) -> UInt32 {
        let c = (KuboArt.tint(m).usingColorSpace(.sRGB) ?? .white)
        var r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if lum < 0.45 { let k = min(0.6, (0.45 - lum) / 0.45 + 0.15); r += (1 - r) * k; g += (1 - g) * k; b += (1 - b) * k }
        return UInt32(r * 255) << 16 | UInt32(g * 255) << 8 | UInt32(b * 255)
    }

    /// 測試：--label-sheet（見 main.swift）
    @MainActor static func labelSheet(bg path: String, out: String) {
        guard let bg = NSImage(contentsOfFile: path), let cg = bg.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("讀不到背景"); return }
        let W = cg.width, H = cg.height
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        // BoardCard 沒有對外的 init ⇒ 直接組各狀態的名牌（文字同 spec 的格式，假名）
        let rows: [(Mood, LabelKind, String)] = [(.working, .working, "小明"), (.waiting, .waiting, "小明・要你決定：要不要…"), (.finished, .finished, "小明"),
                                                 (.stuck, .stuck, "小明・權限"), (.idle, .rest, "☕ 小明"), (.asleep, .rest, "Zzz 小明")]
        var specs = rows.map { m, k, t in
            LabelSpec(id: t, kind: k, text: t, bg: 0, bgAlpha: 0, dot: nil, anchor: nil, floor: "f1",
                      fg: m == .idle || m == .asleep ? 0xE7E5E4 : glassText(m), glass: true)
        }
        specs.append(OfficeLabels.guardSpec(GuardStatus(), scanning: false, anchor: SCNNode()))
        var alert = GuardStatus(); alert.level = .alert
        specs.insert(OfficeLabels.guardSpec(alert, scanning: false, anchor: SCNNode()), at: 0)   // 放第一列（最底列會超出背景圖）
        // 三欄：左邊暗的城市、中間亮的室內、右邊暗的夜空（2× 圖，標籤也是 2×）
        for (col, fx) in [0.08, 0.45, 0.82].enumerated() {
            for (i, s) in specs.enumerated() {
                let (img, sz) = OfficeLabels.draw(s)
                guard let img else { continue }
                let x = Int(Double(W) * fx) - (col == 1 ? Int(sz.width) : 0), y = H - 260 - i * 70
                ctx.draw(img, in: CGRect(x: x, y: y, width: Int(sz.width * 2), height: Int(sz.height * 2)))
            }
        }
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("sheet saved", out)
    }

    // MARK: 文字（主執行緒組 LabelSpec 時用）

    static func shortName(_ c: BoardCard) -> String {
        let n = c.title.split(separator: "-", maxSplits: 1).first.map(String.init) ?? c.title
        return n.count > 14 ? String(n.prefix(13)) + "…" : n
    }

    static func blockedShort(_ r: BlockedReason?) -> String {
        switch r {
        case .permission: "權限"
        case .rateLimit: "額度"
        case .apiError: "API 錯誤"
        case .testRun: "測試跑很久"
        case .build: "建置跑很久"
        case .install: "安裝跑很久"
        case .unknown, nil: "卡住"
        }
    }

    /// 一個人的標籤（狀態決定樣式）。10-23 Kang：名字前不放 ✓／!／?／🔒 符號，狀態只靠字色分（符號太亂）；
    /// 休息 ☕／🧠、睡著 Zzz 保留（兩者同為灰字，靠它分）
    @MainActor static func spec(_ c: BoardCard, mood: Mood, anchor: SCNNode, floor: String) -> LabelSpec {
        var l = plainSpec(c, mood: mood, anchor: anchor, floor: floor)
        l.glass = true
        l.fg = mood == .idle || mood == .asleep ? 0xE7E5E4 : glassText(mood)
        return l
    }

    private static func plainSpec(_ c: BoardCard, mood: Mood, anchor: SCNNode, floor: String) -> LabelSpec {
        let name = shortName(c)
        switch mood {
        case .waiting:
            let q: String
            if c.blockedReason == .permission { q = "等你按允許" }
            else if let ask = c.report?.ask, !ask.isEmpty { q = "要你決定：" + Board.plain(ask) }
            else { q = c.reason }
            let qs = q.count > 14 ? String(q.prefix(14)) + "…" : q
            return LabelSpec(id: c.id, kind: .waiting, text: "\(name)・\(qs)", bg: 0xEF4444, bgAlpha: 1, dot: nil, anchor: anchor, floor: floor, short: name)
        case .stuck:
            return LabelSpec(id: c.id, kind: .stuck, text: "\(name)・\(blockedShort(c.blockedReason))", bg: 0xF97316, bgAlpha: 1, dot: nil, anchor: anchor, floor: floor, short: name)
        case .finished:
            return LabelSpec(id: c.id, kind: .finished, text: name, bg: 0x16A34A, bgAlpha: 1, dot: nil, anchor: anchor, floor: floor)
        case .working:
            let subs = c.subagents.count
            return LabelSpec(id: c.id, kind: .working, text: subs > 0 ? "\(name)・子 agent \(subs)" : name, bg: 0x14161A, bgAlpha: 0.82, dot: 0xA78BFA, anchor: anchor, floor: floor)
        case .idle:
            // B1 機房禁止飲食（10-22 Kang）：在那裡休息的是在看神經網路，不是喝咖啡
            return LabelSpec(id: c.id, kind: .rest, text: "\(floor == "b1" ? "🧠" : "☕") \(name)", bg: 0x14161A, bgAlpha: 0.6, dot: nil, anchor: anchor, floor: floor)
        case .asleep:
            return LabelSpec(id: c.id, kind: .rest, text: "Zzz \(name)", bg: 0x14161A, bgAlpha: 0.6, dot: nil, anchor: anchor, floor: floor)
        }
    }

    /// 城市建築的名牌：正常小字深底；警示（≥90%、離線、防火牆關、敞開紅門、hot）紅底、跟等你同級
    static func citySpec(id: String, text: String, alert: Bool, anchor: SCNNode) -> LabelSpec {
        LabelSpec(id: id, kind: alert ? .cityAlert : .city, text: alert ? "! " + text : text, bg: alert ? 0xDC2626 : 0x14161A,
                  bgAlpha: alert ? 1 : 0.72, dot: nil, anchor: anchor, floor: "city")
    }

    @MainActor static func guardSpec(_ g: GuardStatus, scanning: Bool, anchor: SCNNode) -> LabelSpec {
        // 10-24 Kang：名牌改英文「🛡️ Security」（盾牌同保全卡標題）；狀態靠字色分（掃描中藍、注意橘、正常綠），只有警示在最後加 🚨
        let t = !scanning && g.level == .alert ? "🛡️ Security 🚨" : "🛡️ Security"
        // 玻璃名牌（同人物）：掃描中藍、警示紅、注意橘、正常綠（紅綠跟發光設定同一組）
        let fg: UInt32 = scanning ? 0x7DB8FF : g.level == .alert ? glassText(.waiting) : g.level == .notice ? glassText(.stuck) : glassText(.finished)
        return LabelSpec(id: "guard", kind: .guardian, text: t, bg: 0, bgAlpha: 0, dot: nil, anchor: anchor, floor: "lobby", fg: fg, glass: true)
    }
}

/// 標籤那一層：每個標籤一個 CALayer（圖＝預先畫好的 2× 點陣圖）、被往上推的畫一條 1.5 點引線。不吃滑鼠（點擊由 SCNView 問 OfficeLabels.label(at:)）
@MainActor
final class LabelHostView: NSView {
    struct Item: @unchecked Sendable { let id: String; let image: CGImage?; let frame: CGRect; let leader: CGRect? }
    private var layers: [String: CALayer] = [:]
    private var leaders: [String: CALayer] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    func apply(_ items: [Item]) {
        guard let root = layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var used = Set<String>()
        for (z, it) in items.enumerated() {
            used.insert(it.id)
            let l = layers[it.id] ?? { let l = CALayer(); l.contentsScale = 2; l.contentsGravity = .resize; root.addSublayer(l); layers[it.id] = l; return l }()
            if l.contents as! CGImage? !== it.image { l.contents = it.image }
            l.frame = it.frame
            l.zPosition = CGFloat(z) + 1
            if let r = it.leader {
                let ld = leaders[it.id] ?? { let l = CALayer(); l.backgroundColor = NSColor(white: 1, alpha: 0.85).cgColor; root.addSublayer(l); leaders[it.id] = l; return l }()
                ld.frame = r; ld.zPosition = CGFloat(z) + 0.5; ld.isHidden = false
            } else { leaders[it.id]?.isHidden = true }
        }
        for (id, l) in layers where !used.contains(id) { l.removeFromSuperlayer(); layers[id] = nil; leaders[id]?.removeFromSuperlayer(); leaders[id] = nil }
        CATransaction.commit()
    }
}
