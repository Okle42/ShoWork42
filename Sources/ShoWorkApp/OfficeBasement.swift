import AppKit
import SceneKit
import simd
import ShoWorkCore

// 地下室 B1 伺服器機房（10-22 Kang 看了 Graphify 影片：「做在地下室，很像伺服器機房，中間有一個浮在空中的 3D 神經網路」）。
//   位置：大廳正下方（大廳地板 y 0，B1 地坪 y −4.2、淨高 3.8），範圍跟大樓模組一樣（x ±6、z TowerSpec.back…front）。
//   平常被城市地坪、大地面蓋住看不到；按住滾輪往下平移、鏡頭（世界 y）低於 0 才出現：地面淡出、B1 照一般樓層 cutaway。
//   機房：深色高架地板（細格線）、深灰牆、後牆＋兩側一排排黑色機櫃（正面一格格 LED：綠多、藍次之、少數琥珀；停電跟著熄）、
//   天花線槽、冷藍色燈；三面外側是土層剖面（跟著那面牆一起 cutaway）。全部合併成幾個 mesh（一種材質一個 draw call）。
//   中間浮著神經網路：資料是 NeuralGraph（Graphify 抽的程式碼知識圖譜，畫面不知道 Graphify）；
//   節點＝低面數八面體、全部合成 1 個 geometry（顏色走頂點色，同專案同色）；邊＝.line 一次畫完（半透明青色、加法混色）。
//   整團約 60 秒自轉一圈，只在鏡頭在地下室時轉（OfficeSCNView 才會持續渲染）；地上時整個 B1 藏起來，不送進渲染、不每幀做事。
//   B1 的東西只吃自己的燈（categoryBitMask＝mask）：大樓的暖補光、太陽、夜晚 omni 都照不到；環境光（ambient 不吃位元）照得到。

/// 留言板計時器回呼找得到人（Timer 的 closure 不想抓 self）
@MainActor enum BoardFeed { static weak var basement: OfficeBasement? }

@MainActor
final class OfficeBasement {
    /// B1 專用的光照位元（大樓 1、角色點擊 2、戶外 1<<4）
    static let mask = 1 << 5
    /// B1 地坪（世界 y）、淨高
    static let floorY: Float = -5.6      // 10-22 Kang：再深一點，好觀看（−4.2 → −5.6）
    static let clear: Float = 5.2
    /// 模組原點（樓板底）：模組內座標跟其他樓層一樣（地坪面＝TD.room）
    static let baseY: Float = floorY - TD.room
    /// 土層剖面最底（世界 y；鏡頭 zNear 用的外框下緣）
    static let bottomY: Float = baseY - 1.5
    /// 圖譜中心（模組內座標）：機房正中間、離地 1.9；半徑 2.2（10-22 實測 1.6 在 12 公尺寬的機房裡太小）
    static let graphCenter = SIMD3<Float>(0, TD.room + 2.6, TD.zC)
    static let graphRadius = 2.2
    /// 自轉一圈幾秒
    static let spinPeriod: TimeInterval = 60

    let root = SCNNode()
    private(set) var facades: [Facade] = []
    /// 圖譜的轉軸（自轉的 SCNAction 掛在這；不在地下室時 isPaused）
    private let pivot = SCNNode()
    private var graphNode: SCNNode?
    private(set) var graphCount = (nodes: 0, edges: 0)
    /// 目前畫的擺放（點擊判定用：節點位置、屬於哪個專案）
    private var placement: NeuralPlacement?
    private let key = SCNNode(), glowLight = SCNNode()
    /// 神經網路、投影台光圈自己管亮度（停電只暗到 0.25，不跟一般發光材質一起熄）
    private var neuralMats: [(SCNMaterial, CGFloat)] = []
    private var power: CGFloat = 1
    private(set) var live = false
    /// Agent交流互動板（10-24 Kang：要掛在 B1 牆上）：後牆機櫃上方一面螢幕，畫最近幾則；檔案變了才重畫
    private let boardMat = SCNMaterial()
    private var boardStamp: String?
    private var boardTimer: Timer?
    static let boardShown = 5
    private var boardScreen: SCNNode?

    /// 霓虹調色盤（同專案同色，依第一次出現的順序循環）
    static let palette: [UInt32] = [0x22D3EE, 0xA78BFA, 0xF472B6, 0x34D399, 0xFBBF24, 0x60A5FA, 0xFB7185, 0xA3E635]

    init() {
        root.name = "basement"
        root.simdPosition = SIMD3(0, Self.baseY, 0)
        root.isHidden = true                     // 鏡頭到地下才出現
        buildRoom()
        pivot.name = "neural"
        pivot.simdPosition = Self.graphCenter
        root.addChildNode(pivot)
        // 自轉：一直掛著、用 isPaused 開關（停的時候停在當下角度，下次接著轉）
        pivot.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: Self.spinPeriod)), forKey: "spin")
        pivot.isPaused = true
        // 冷藍色主燈（從前上方往下照）＋圖譜中心一盞青色 omni（照亮投影台四周地板）：只照 B1
        key.light = SCNLight(); key.light!.type = .directional; key.light!.categoryBitMask = Self.mask
        key.light!.color = VoxMat.color(0x9CC8FF)
        key.eulerAngles = SCNVector3(-1.05, 0.35, 0)
        root.addChildNode(key)
        glowLight.light = SCNLight(); glowLight.light!.type = .omni; glowLight.light!.categoryBitMask = Self.mask
        glowLight.light!.color = VoxMat.color(0x5EEAD4)
        glowLight.light!.attenuationStartDistance = 0.5; glowLight.light!.attenuationEndDistance = 4.5
        glowLight.simdPosition = Self.graphCenter
        root.addChildNode(glowLight)
        setPower(1)
        setGraph(.demo())
    }

    /// 鏡頭在不在地下室：在 ⇒ 整個 B1 出現、圖譜開始轉（reduceMotion 不轉）
    func setLive(_ on: Bool, spin: Bool) {
        let was = live
        live = on
        root.isHidden = !on
        pivot.isPaused = !(on && spin)
        // 留言板：進 B1 時看一次檔案，人在 B1 的期間每 10 秒看一次（只比 mtime／大小，沒變不重畫）
        if on, !was {
            refreshBoard()
            boardTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in MainActor.assumeIsolated { BoardFeed.basement?.refreshBoard() } }
            BoardFeed.basement = self
        } else if !on { boardTimer?.invalidate(); boardTimer = nil }
    }

    func refreshBoard(force: Bool = false) {
        let st = FileStat.lstat(B1Board.file.path)?.stamp ?? "none"
        guard force || st != boardStamp else { return }
        boardStamp = st
        boardMat.diffuse.contents = Self.boardImage(Array(B1Board.all().suffix(Self.boardShown).reversed()), total: B1Board.all().count)
    }

    /// 留言板畫面（1840×840 px）：標題＋最新在上的幾則，每則「#編號 名字（專案）時間」一行＋內容最多兩行
    static func boardImage(_ posts: [B1Post], total: Int) -> CGImage? {
        let W: CGFloat = 920, H: CGFloat = 420
        let img = NSImage(size: NSSize(width: W, height: H), flipped: true) { r in
            NSColor(srgbRed: 0.04, green: 0.07, blue: 0.11, alpha: 1).setFill(); r.fill()
            let cyan = NSColor(srgbRed: 0.37, green: 0.92, blue: 0.83, alpha: 1)
            cyan.withAlphaComponent(0.8).setStroke()
            let frame = NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 4), xRadius: 10, yRadius: 10); frame.lineWidth = 3; frame.stroke()
            OfficeBuilder.draw("Agent交流互動板", at: NSPoint(x: 26, y: 16), size: 30, weight: .bold, color: cyan, width: 400)
            let sub = total == 0 ? "" : "共 \(total) 則・最新在上"
            OfficeBuilder.draw(sub, at: NSPoint(x: W - 226, y: 28), size: 16, weight: .medium, color: NSColor(white: 0.7, alpha: 1), width: 200)
            guard !posts.isEmpty else {
                OfficeBuilder.draw("還沒有留言。Agent 到 B1 休息時會留下工作心得。", at: NSPoint(x: 26, y: 90), size: 20, weight: .regular, color: NSColor(white: 0.75, alpha: 1), width: W - 52)
                return true
            }
            let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
            var y: CGFloat = 66
            let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byWordWrapping
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor(white: 0.93, alpha: 1), .paragraphStyle: ps]
            for (i, p) in posts.enumerated() {
                let c = VoxMat.color(palette[p.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % palette.count])
                let head = "#\(p.id)  \(p.name)" + (p.project.isEmpty ? "" : "（\(p.project)）") + (p.re.map { "  ↪#\($0)" } ?? "") + "  " + f.string(from: p.at)
                OfficeBuilder.draw(head, at: NSPoint(x: 26, y: y), size: 16, weight: .semibold, color: c, width: W - 52)
                (p.text as NSString).draw(with: NSRect(x: 26, y: y + 22, width: W - 52, height: 46),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: body)
                y += 70
                if i < posts.count - 1 { NSColor(white: 1, alpha: 0.08).setFill(); NSRect(x: 26, y: y - 5, width: W - 52, height: 1).fill() }
            }
            return true
        }
        return OfficeBuilder.raster(img, scale: 2)
    }
    /// 圖譜正在轉（OfficeSCNView 依這個決定要不要持續渲染）
    var spinning: Bool { live && !pivot.isPaused && graphCount.nodes > 0 }

    /// 電力乘數（1 正常 … 0 停電）：機房燈跟著暗；神經網路、光圈最暗 0.25（停電時還看得到一團微光）
    func setPower(_ p: CGFloat) {
        power = p
        key.light!.intensity = 650 * p
        glowLight.light!.intensity = 420 * p
        key.isHidden = p <= 0.001; glowLight.isHidden = p <= 0.001
        let k = max(0.25, p)
        for (m, base) in neuralMats { m.diffuse.intensity = base * k }
    }

    private func neural(_ m: SCNMaterial, base: CGFloat) -> SCNMaterial {
        m.diffuse.intensity = base * max(0.25, power)
        neuralMats.append((m, base))
        return m
    }

    // MARK: 機房（靜態，合併成幾個 mesh）

    private func buildRoom() {
        let m = VoxelMesh(), k = Kit(m: m)
        let r = TD.room, h = Self.clear, top = -Self.baseY - 0.02      // top＝世界 y −0.02（地表下一點點，不跟大地面打架）
        let W = TD.W, zB = TD.zB, zF = TD.zF, zC = TD.zC, D = TD.D
        // 樓板＋高架地板（深色，0.6 公尺一格的細格線）
        k.b(.identity, 0, 0, zC, W, TD.slab, D, TM.f(0x23272D))
        k.b(.identity, 0, TD.slab, zC, W - 0.02, 0.01, D - 0.02, TM.f(0x1A1E24))
        let line = TM.f(0x343C47)
        for x in stride(from: -W / 2 + 0.6, to: W / 2 - 0.1, by: 0.6) { k.b(.identity, x, r, zC, 0.02, 0.004, D - 0.32, line) }
        for z in stride(from: zB + 0.6, to: zF - 0.1, by: 0.6) { k.b(.identity, 0, r, z, W - 0.32, 0.004, 0.02, line) }
        // 中間冷通道幾塊打孔地板（亮一階）
        let perf = TM.f(0x262C35)
        let tiles: [(Float, Float)] = [(-1.8, zC - 1.8), (1.8, zC - 1.8), (-1.8, zC + 1.8), (1.8, zC + 1.8), (0, zC + 2.4), (0, zC - 2.4)]
        for (x, z) in tiles {
            k.b(.identity, x, r, z, 0.56, 0.006, 0.56, perf)
        }
        // 樓板前緣冷光條
        k.b(.identity, 0, TD.slab - 0.02, zF + 0.011, W, 0.02, 0.02, TM.glow(0x38BDF8, 0.9, 0.9))
        // 天花（B1 頂板：r+h → 地表下）
        k.b(.identity, 0, r + h, zC, W, top - r - h, D, TM.f(0x1C1F24))
        // 天花線槽：後排一條（沿 x）、兩側各一條（沿 z），吊桿每 1.5 公尺；槽上兩色電纜
        let tray = TM.f(0x454B54), rod = TM.f(0x2F3338), cableA = TM.f(0x1E40AF), cableB = TM.f(0xB45309)
        let ty = r + h - 0.38
        func trayX(_ z: Float, _ x0: Float, _ x1: Float) {
            k.b(.identity, (x0 + x1) / 2, ty, z, x1 - x0, 0.06, 0.4, tray)
            k.b(.identity, (x0 + x1) / 2, ty + 0.06, z - 0.08, x1 - x0, 0.06, 0.12, cableA)
            k.b(.identity, (x0 + x1) / 2, ty + 0.06, z + 0.09, x1 - x0, 0.05, 0.1, cableB)
            for x in stride(from: x0 + 0.3, through: x1 - 0.3, by: 1.5) { k.b(.identity, x, ty + 0.06, z, 0.02, r + h - ty - 0.06, 0.02, rod) }
        }
        func trayZ(_ x: Float, _ z0: Float, _ z1: Float) {
            k.b(.identity, x, ty, (z0 + z1) / 2, 0.4, 0.06, z1 - z0, tray)
            k.b(.identity, x - 0.08, ty + 0.06, (z0 + z1) / 2, 0.12, 0.06, z1 - z0, cableA)
            k.b(.identity, x + 0.09, ty + 0.06, (z0 + z1) / 2, 0.1, 0.05, z1 - z0, cableB)
            for z in stride(from: z0 + 0.3, through: z1 - 0.3, by: 1.5) { k.b(.identity, x, ty + 0.06, z, 0.02, r + h - ty - 0.06, 0.02, rod) }
        }
        trayX(TD.backZ + 0.55, -5.0, 5.0)
        trayZ(-5.3, zB + 1.0, zF - 1.0)
        trayZ(5.3, zB + 1.0, zF - 1.0)
        // 天花冷白燈條（兩條沿 z，讓開中間的圖譜）
        let strip = TM.glow(0xCFE8FF, 0.9, 0.9)
        for x: Float in [-3.0, 3.0] { k.b(.identity, x, r + h - 0.05, zC, 0.12, 0.05, D - 2.4, strip) }

        // 機櫃：後牆一排 15 座（面向 +z）、兩側各 11 座（面向室內）
        var rng = PixelTex.RNG(s: 0xB1_5E_4F_E2)
        let led: [SCNMaterial] = [TM.glow(0x22C55E, 1.5, 1.5), TM.glow(0x3B82F6, 1.5, 1.5), TM.glow(0xF59E0B, 1.5, 1.5)]
        let body = TM.f(0x0F1114), unit = TM.f(0x1A1D22), vent = TM.f(0x2A2F36)
        func rack(_ xf: Xf) {
            k.b(xf, 0, r, 0, 0.6, 2.1, 1.0, body)
            k.b(xf, 0, r + 2.1, 0, 0.5, 0.03, 0.8, vent)
            for u in 0..<8 {
                let y = r + 0.12 + Float(u) * 0.24
                k.b(xf, 0, y, 0.505, 0.54, 0.2, 0.01, unit)
                for i in 0..<4 {
                    let v = rng.next()
                    guard v > 0.12 else { continue }                       // 一成多不亮（看起來才不像整齊的燈牆）
                    let mat = v < 0.62 ? led[0] : v < 0.92 ? led[1] : led[2]
                    k.b(xf, -0.21 + Float(i) * 0.055, y + 0.13, 0.515, 0.03, 0.02, 0.01, mat)
                }
                if rng.next() < 0.35 { k.b(xf, 0.17, y + 0.04, 0.515, 0.12, 0.012, 0.01, led[1]) }   // 硬碟活動燈條
            }
        }
        for i in 0..<15 { rack(Xf(x: -4.55 + Float(i) * 0.65, y: 0, z: TD.backZ + 0.55, a: 0)) }
        for i in 0..<11 {
            let z = zB + 1.8 + Float(i) * 0.65
            if !(z > -3.75 && z < -0.45) { rack(Xf(x: -W / 2 + 0.7, y: 0, z: z, a: .pi / 2)) }   // 左牆讓出兩部電梯的門口
            rack(Xf(x: W / 2 - 0.7, y: 0, z: z, a: -.pi / 2))
        }
        // 機櫃排前的地面冷光條（高架地板縫透出來的藍光）
        let floorGlow = TM.glow(0x38BDF8, 0.8, 0.8)
        k.b(.identity, 0, r, TD.backZ + 1.1, 9.6, 0.01, 0.03, floorGlow)
        for s: Float in [-1, 1] { k.b(.identity, s * (W / 2 - 1.25), r, zB + 1.8 + 3.25, 0.03, 0.01, 7.0, floorGlow) }

        // 投影台底座（光圈另外一個 mesh，亮度跟神經網路一起管）
        k.b(.identity, 0, r, zC, 1.3, 0.1, 1.3, TM.f(0x15181D))
        k.b(.identity, 0, r + 0.1, zC, 1.0, 0.02, 1.0, TM.f(0x0B0D10))

        // 土層剖面底部（B1 樓板下）
        k.b(.identity, 0, -1.5, zC - 1.5, W + 7, 1.5, D + 3, TM.f(0x241E19))
        let st = m.node(name: "basement-static")
        root.addChildNode(st)

        // 光圈：兩圈發光小段（地上投影台）＋底座頂面的方形光板
        let rm = VoxelMesh(), rk = Kit(m: rm)
        let ringMat = neural(Self.constant(0x5EEAD4), base: 1.4)
        for (rad, n) in [(Float(1.15), 48), (Float(0.8), 32)] {
            for i in 0..<n {
                let t = Float(i) / Float(n) * 2 * .pi
                rk.b(Xf(x: cos(t) * rad, y: 0, z: zC + sin(t) * rad, a: -t), 0, r + 0.003, 0, 0.05, 0.012, rad * 2 * .pi / Float(n) * 0.62, ringMat)
            }
        }
        rk.b(.identity, 0, r + 0.12, zC, 0.7, 0.01, 0.7, neural(Self.constant(0x22D3EE), base: 0.9))
        root.addChildNode(rm.node(name: "basement-ring"))

        // 牆：後、左、右各一面（深灰）＋外側土層（跟著那面牆一起 cutaway）；正面玻璃
        let wall = TM.f(0x2A2E35)
        let bands: [(Float, Float, UInt32)] = [(0, 1.0, 0x2B241E), (1.0, 2.6, 0x332A22), (2.6, 3.9, 0x3B3027), (3.9, top, 0x4A3A2C)]
        func earth(_ wk: Kit, x: Float, z: Float, w: Float, d: Float) {
            for (y0, y1, c) in bands where y1 > y0 { wk.b(.identity, x, y0, z, w, y1 - y0, d, TM.f(c)) }
        }
        facades = [
            Facade(node: TowerModules.wall(0, h: h, mat: wall, name: "b1-back") { wk in earth(wk, x: 0, z: zB - 1.5, w: W, d: 3) },
                   n: TowerModules.normals[0], glass: false),
            Facade(node: TowerModules.glassFront(h: h, alpha: 0.12), n: TowerModules.normals[1], glass: true),
            // 左牆：兩部電梯的門（10-22 Kang：B1 要留電梯出口）；左側土層讓出電梯井（x −7.8…−6.0、z −3.65…−0.55）
            Facade(node: TowerModules.wall(2, h: h, mat: wall, gaps: TowerLayout.elevatorDoors.map { (Float($0.z) - 0.45, Float($0.z) + 0.45, 2.1) },
                                           name: "b1-left") { wk in
                let z0 = zC - 1.5 - (D + 3) / 2, z1 = zC - 1.5 + (D + 3) / 2
                earth(wk, x: -W / 2 - 2.65, z: zC - 1.5, w: 1.7, d: D + 3)
                earth(wk, x: -W / 2 - 0.9, z: (-0.55 + z1) / 2, w: 1.8, d: z1 + 0.55)
                earth(wk, x: -W / 2 - 0.9, z: (z0 - 3.65) / 2, w: 1.8, d: -3.65 - z0)
                for d in TowerLayout.elevatorDoors {
                    let dz = Float(d.z)
                    for z in [dz - 0.5, dz + 0.5] { wk.b(.identity, -W / 2 + 0.17, TD.room, z, 0.06, 2.2, 0.1, TM.f(0x5FD4FF)) }
                    wk.b(.identity, -W / 2 + 0.17, TD.room + 2.1, dz, 0.06, 0.12, 1.1, TM.f(0x5FD4FF))
                }
            },
                   n: TowerModules.normals[2], glass: false),
            Facade(node: TowerModules.wall(3, h: h, mat: wall, name: "b1-right") { wk in earth(wk, x: W / 2 + 1.75, z: zC - 1.5, w: 3.5, d: D + 3) },
                   n: TowerModules.normals[3], glass: false),
        ]
        // 牆面頂端到天花之間的空隙：牆只到 r+h，頂板從 r+h 起 ⇒ 剛好接上
        for f in facades { root.addChildNode(f.node) }
        // 留言板：後牆、機櫃上方（機櫃頂 r+2.13），面向 +z；掛在後牆節點下 ⇒ 後牆 cutaway 時一起藏
        let bw: CGFloat = 4.6, bh: CGFloat = 2.1
        let bezel = SCNNode(geometry: SCNBox(width: bw + 0.12, height: bh + 0.12, length: 0.06, chamferRadius: 0.02))
        bezel.geometry?.firstMaterial = TM.f(0x0B0D10)
        bezel.simdPosition = SIMD3(0, r + 2.45 + Float(bh) / 2, TD.backZ + 0.05)
        let screen = SCNPlane(width: bw, height: bh)
        boardMat.lightingModel = .constant
        boardMat.diffuse.contents = Self.boardImage([], total: 0)
        screen.firstMaterial = neural(boardMat, base: 1.0)
        let sn = SCNNode(geometry: screen); sn.name = "b1-board"; sn.position.z = 0.032
        bezel.addChildNode(sn)
        facades[0].node.addChildNode(bezel)
        boardScreen = sn
        Self.mark(root)
        // 10-24 Kang：留言板要能點開看全部 ⇒ 螢幕也吃點擊位元（OfficeSCNView.person 認 "b1-board"）
        boardScreen?.categoryBitMask = Self.mask | OfficeBuilder.pickMask
    }

    /// 只吃 B1 自己的燈
    private static func mark(_ n: SCNNode) {
        if n.geometry != nil { n.categoryBitMask = mask }
        for c in n.childNodes { mark(c) }
    }

    /// 自發光感的純色（不吃燈光；亮度＝diffuse.intensity，HDR 下超過 1 會泛光）
    private static func constant(_ h: UInt32, alpha: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = VoxMat.color(h)
        m.lightingModel = .constant
        if alpha < 1 { m.transparency = alpha; m.blendMode = .add; m.writesToDepthBuffer = false }
        return m
    }

    // MARK: 神經網路

    /// 換圖譜（重建 2 個 geometry：節點、邊）；空圖 ⇒ 只剩投影台
    func setGraph(_ g: NeuralGraph) {
        graphNode?.removeFromParentNode(); graphNode = nil
        neuralMats.removeAll { m in m.0.name == "neural-dots" || m.0.name == "neural-edges" }
        let p = g.placement(radius: Self.graphRadius, palette: Self.palette.count)
        placement = p
        graphCount = (p.dots.count, p.edges.count)
        guard !p.dots.isEmpty else { return }
        let n = SCNNode(); n.name = "neural-graph"
        n.addChildNode(Self.dotsNode(p, mat: neural(Self.named(Self.constant(0xFFFFFF), "neural-dots"), base: 1.6)))
        if !p.edges.isEmpty { n.addChildNode(Self.edgesNode(p, mat: neural(Self.named(Self.constant(0x67E8F9, alpha: 0.38), "neural-edges"), base: 1.2))) }
        Self.mark(n)
        pivot.addChildNode(n)
        graphNode = n
    }

    private static func named(_ m: SCNMaterial, _ s: String) -> SCNMaterial { m.name = s; return m }

    // MARK: 點擊（10-22 Kang：點中間那一坨神經網路 ⇒ 開 Graphify 原本的互動圖譜）

    /// 點擊判定的寬容：比圖譜半徑大一點（外圍的小節點也點得到）
    static let pickSlack: Double = 0.35

    /// 世界座標的射線（滑鼠那一點從近平面到遠平面）點到圖譜 ⇒ 離射線最近的節點屬於哪個專案；沒點到回 nil。
    /// 不在地下室、圖譜空的都回 nil。射線換到圖譜轉軸自己的座標（用 presentation：自轉中的當下角度）再交給 NeuralPick
    func pickProject(from a: SCNVector3, to b: SCNVector3) -> String? {
        guard live, let placement, !placement.dots.isEmpty else { return nil }
        let pv = pivot.presentation
        let la = pv.simdConvertPosition(SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)), from: nil)
        let lb = pv.simdConvertPosition(SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z)), from: nil)
        let o = SIMD3<Double>(la), d = SIMD3<Double>(lb - la)
        let pts = placement.dots.map { SIMD3($0.x, $0.y, $0.z) }
        guard let i = NeuralPick.pick(pts, origin: o, dir: d, radius: Self.graphRadius + Self.pickSlack) else { return nil }
        let k = placement.dots[i].project
        return placement.projects.indices.contains(k) ? placement.projects[k] : nil
    }

    /// 點到時閃一下：節點、邊、光圈亮度 0.08 秒拉到 2.4 倍、再 0.6 秒退回（跟著目前電力）
    func flash() {
        guard graphNode != nil else { return }
        let mats = neuralMats, k = max(0.25, power)
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.08
        for (m, base) in mats { m.diffuse.intensity = base * k * 2.4 }
        SCNTransaction.completionBlock = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let k = max(0.25, self?.power ?? 1)          // 閃的期間停電／復電：退回時用當下電力
                    SCNTransaction.begin(); SCNTransaction.animationDuration = 0.6
                    for (m, base) in mats { m.diffuse.intensity = base * k }
                    SCNTransaction.commit()
                }
            }
        }
        SCNTransaction.commit()
    }

    private static func rgb(_ h: UInt32) -> SIMD3<Float> {
        SIMD3(Float(h >> 16 & 255) / 255, Float(h >> 8 & 255) / 255, Float(h & 255) / 255)
    }

    /// 節點：每個一顆八面體（8 面、每面 3 個頂點，面各自明暗 ⇒ 不吃燈也看得出立體），顏色＝頂點色；全部 1 個 element
    private static func dotsNode(_ p: NeuralPlacement, mat: SCNMaterial) -> SCNNode {
        var pos: [Float] = [], col: [Float] = []
        var idx: [UInt32] = []
        pos.reserveCapacity(p.dots.count * 72); col.reserveCapacity(p.dots.count * 96); idx.reserveCapacity(p.dots.count * 24)
        let ax: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        // 8 個面：(x±, y±, z±) 各取一個；逆時針朝外
        let faces: [(Int, Int, Int)] = [(0, 2, 4), (4, 2, 1), (1, 2, 5), (5, 2, 0), (4, 3, 0), (1, 3, 4), (5, 3, 1), (0, 3, 5)]
        let light = simd_normalize(SIMD3<Float>(0.3, 1, 0.5))
        for d in p.dots {
            let c = SIMD3<Float>(Float(d.x), Float(d.y), Float(d.z)), s = Float(d.size) / 2
            let base = rgb(palette[d.color % palette.count])
            for f in faces {
                let a = c + ax[f.0] * s, b = c + ax[f.1] * s, e = c + ax[f.2] * s
                let nrm = simd_normalize(simd_cross(b - a, e - a))
                let shade = 0.62 + 0.38 * max(0, simd_dot(nrm, light))
                let k = UInt32(pos.count / 3)
                for v in [a, b, e] { pos += [v.x, v.y, v.z]; col += [base.x * shade, base.y * shade, base.z * shade, 1] }
                idx += [k, k + 1, k + 2]
            }
        }
        let n = SCNNode(geometry: geometry(pos: pos, col: col, idx: idx, type: .triangles, mat: mat))
        n.name = "neural-dots"
        return n
    }

    /// 邊：所有線段一個 .line element（頂點＝節點中心）
    private static func edgesNode(_ p: NeuralPlacement, mat: SCNMaterial) -> SCNNode {
        var pos: [Float] = [], col: [Float] = []
        for d in p.dots { pos += [Float(d.x), Float(d.y), Float(d.z)]; col += [1, 1, 1, 1] }
        let idx = p.edges.flatMap { [UInt32($0.a), UInt32($0.b)] }
        let n = SCNNode(geometry: geometry(pos: pos, col: col, idx: idx, type: .line, mat: mat))
        n.name = "neural-edges"
        n.renderingOrder = 10        // 透明的最後畫
        return n
    }

    private static func geometry(pos: [Float], col: [Float], idx: [UInt32], type: SCNGeometryPrimitiveType, mat: SCNMaterial) -> SCNGeometry {
        let count = pos.count / 3
        let vs = SCNGeometrySource(data: pos.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex, vectorCount: count,
                                   usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let cs = SCNGeometrySource(data: col.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color, vectorCount: count,
                                   usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let el = SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: type,
                                    primitiveCount: type == .line ? idx.count / 2 : idx.count / 3, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [vs, cs], elements: [el])
        g.materials = [mat]
        return g
    }
}
