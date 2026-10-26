import AppKit
import SceneKit
import simd
import ShoWorkCore

// 3D 辦公室第四版：科技大樓剖面（10-20 Kang 拍板，規範 docs/design/office-tower/設計規範.md）的零件。
//   一層樓＝一個模組（16×7，原點在樓板底面中心）：靜態東西（樓板、地坪、家具、桌子、吊燈、窗框）依材質合併成一個 VoxelMesh；
//   會被 cutaway 淡掉的四面牆（front 玻璃、back、left、right）各自一個節點；門牌一個節點。
//   素色：地坪全樓只有 FL-1 淺白橡木（辦公樓層、頂樓）與 FL-2 淺灰磨石（大廳、閒置薄層），不准依部門換色；
//   部門只靠主題家具（一件 ★ 用識別色）＋門牌色條區分。
//   電梯（左外側）、溜滑梯（右外側）、結構柱、天際線在模組外面，搬家飄出時不會撞到。
// 場景組裝在 OfficeBuilder.swift；動畫（搬家、閒晃）的每幀計算在這個檔最後的 TowerMotion（不綁主執行緒，SceneKit 的渲染執行緒會呼叫）。

// MARK: - 色票（規範 §1.1；只准用這張表）

enum TP {
    static let FL1: UInt32 = 0xCDBFA8, FL2: UInt32 = 0xBDBAB3          // 地坪：淺白橡木、淺灰磨石
    static let WL1: UInt32 = 0xEEEBE5, WL2: UInt32 = 0xE3DFD8           // 後牆、側牆
    static let ST1: UInt32 = 0x2F3338, ST2: UInt32 = 0xA7A49E           // 石墨鋼、清水混凝土
    static let ELEV_LED: UInt32 = 0x5CE1FF, ELEV_LAMP: UInt32 = 0xEAF6FF   // 電梯燈條（青）、車廂天花燈（冷白）
    static let GL1: UInt32 = 0xB9D3D8                                   // 玻璃
    static let NE1: UInt32 = 0x8FE3EE, NE2: UInt32 = 0xFF5A5F           // 樓板前緣霓虹、天線燈
    static let LT1: UInt32 = 0xFFD8A6                                   // 暖光 2700K
    static let FN1: UInt32 = 0x8A6A4F, FN2: UInt32 = 0xC2A27F, FN3: UInt32 = 0x2B2C2F
    static let FN4: UInt32 = 0x8F8B85, FN5: UInt32 = 0xF3F1EC, FN6: UInt32 = 0x1E2024
    static let PL1: UInt32 = 0x5C7F55, PL2: UInt32 = 0x7C9A6A, POT: UInt32 = 0xD9D4CB
    static let INK: UInt32 = 0x2F3338
    static let soil: UInt32 = 0x5A4A3A
    // 戶外（白天／夜晚）
    // 10-21 主光改版（研究 R2-2-3）：地平線＝霧色＝天空盒下半＝視窗底色（不一致就會有一條硬的地平線）；天頂比地平線深
    static let skyDay: UInt32 = 0xD3DCE2, skyNight: UInt32 = 0x141B26
    static let zenithDay: UInt32 = 0xA9BCCB, zenithNight: UInt32 = 0x070A10
    static let groundDay: UInt32 = 0xA4ABB0, groundNight: UInt32 = 0x0D1218
    static let cityWindow: UInt32 = 0xE8C98F      // 航班看板的字列（原本也是遠景大樓窗光；遠景 10-21 拿掉）

    static func hex(_ s: String) -> UInt32? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard t.count == 6 else { return nil }
        return UInt32(t, radix: 16)
    }
}

/// 尺寸（跟 ShoWorkCore.TowerSpec／TowerLayout 一致）。10-20 UI/UX 優化 §3.1：模組 16×7×3.6 → 12×5.6×2.9；
/// 電梯改成左外側 1.4×1.4 玻璃井；溜滑梯縮小（半徑 0.6）移到右後角、後牆後面（預設鏡頭大部分被大樓擋住）
enum TD {
    static let W = Float(TowerSpec.width), D = Float(TowerSpec.depth)
    static let Wd = TowerSpec.width, Dd = TowerSpec.depth
    /// 模組前緣（玻璃面）z、後緣 z、中心 z：10-22 Kang 要大樓加深 ⇒ 前緣固定在 2.8（城市、家具座標都不動），只往後長
    static let zF = Float(TowerSpec.front), zB = Float(TowerSpec.front - TowerSpec.depth), zC = (zF + zB) / 2
    static let zFd = TowerSpec.front, zBd = TowerSpec.front - TowerSpec.depth
    static let slab = Float(TowerSpec.slab)
    static let room: Float = slab + 0.01     // 樓板＋地坪面（模組裡的「地面」高度）
    static let clear = Float(TowerSpec.floorHeight - TowerSpec.slab)   // 專案樓層淨高 2.65
    static let backZ: Float = zB + 0.15      // 後牆內側（10-22：原本 −D/2，加深後沒跟著改，貼牆的東西全離牆 1.4 公尺）
    static let elevX = Float(TowerLayout.elevator.x), elevZ = Float(TowerLayout.elevator.z)
    /// 兩部電梯（10-22 Kang）：第 c 部車廂中心；井沿 z 排一列，相鄰兩座中間共用一道隔板（取兩車廂中心的中點）
    static let elevs: [SIMD2<Float>] = TowerLayout.elevators.map { SIMD2(Float($0.x), Float($0.z)) }
    /// 第 c 部電梯門洞（左牆沿 z 的區間）：車廂中心 ±0.45（第 0 部＝原本的 −1.75…−0.85）
    static func elevGap(_ c: Int, h: Float) -> (Float, Float, Float) { (elevs[c].y - 0.45, elevs[c].y + 0.45, h) }
    /// 溜滑梯中心（10-20 第 4 棒：原本 x 6.45 凸出大樓右緣，預設鏡頭下右邊一整條深色鋸齒 ⇒ 縮進右後角後面，從預設方位 16° 看被大樓整個擋住）
    /// 樓層看板立柱（電梯井外側；看板 4.4 寬繞柱轉一圈也碰不到電梯井 x −7.75；底座不壓到堆場匯流道 x −9.95）
    static let boardX: Float = -10.6, boardZ: Float = -1.0
    static let slideX: Float = 4.9, slideZ: Float = zB - 1.0, slideR: Float = 0.6
    static let slideStep: Float = 0.5, slideDrop: Float = 0.16          // 每段轉 0.5 弧度、降 0.16 公尺
    /// 螺旋起點的角度：朝大樓後牆右端那扇門（縮進右後角之後，原本的 π 會在離門最遠的那一側，滑的人要穿牆）
    static let slideA0: Float = .pi / 4
    /// 溜滑梯第 θ 弧度的位置
    static func slidePoint(_ th: Float, top: Float, y: Float) -> SIMD3<Float> {
        SIMD3(slideX + slideR * cos(th), y, slideZ + slideR * sin(th))
    }
    static func slideAngle(top: Float, y: Float) -> Float { slideA0 + (top - y) / slideDrop * slideStep }
}

// MARK: - 材質

@MainActor
enum TM {
    static func f(_ h: UInt32) -> SCNMaterial { VoxMat.flat(h) }
    static func glow(_ h: UInt32, _ day: CGFloat, _ night: CGFloat) -> SCNMaterial { VoxMat.flat(h, emit: (day, night)) }
    /// 樓板側邊（ST-2）：白天 #8E8B85（每層一條清楚的深色水平線）、夜晚維持 #A7A49E（10-20 UI/UX 優化 §3.5）
    static var slab: SCNMaterial { VoxMat.dayNight(0x8E8B85, TP.ST2) }
    /// 後牆（WL-1）：白天 #E6E1D8、夜晚 #EEEBE5
    static var backWall: SCNMaterial { VoxMat.dayNight(0xE6E1D8, TP.WL1) }
    /// 透明玻璃（GL-1）：不寫深度、雙面；一種透明度一份（共用）
    private static var glassCache: [String: SCNMaterial] = [:]
    static func glass(_ alpha: CGFloat, _ h: UInt32 = TP.GL1) -> SCNMaterial {
        let k = "\(h)|\(alpha)"
        if let m = glassCache[k] { return m }
        let m = SCNMaterial()
        m.diffuse.contents = VoxMat.color(h); m.lightingModel = .lambert
        m.transparency = alpha; m.blendMode = .alpha; m.writesToDepthBuffer = false; m.isDoubleSided = true
        glassCache[k] = m
        return m
    }
}

/// 一件家具的積木工具：b(…)＝底面在 y0 的方塊（座標在家具自己的框裡，+z＝正面朝鏡頭）
@MainActor
struct Kit {
    let m: VoxelMesh
    func b(_ xf: Xf, _ x: Float, _ y0: Float, _ z: Float, _ w: Float, _ h: Float, _ d: Float, _ mat: SCNMaterial) {
        m.box(xf, SIMD3(x, y0 + h / 2, z), SIMD3(w, h, d), mat)
    }
}

// MARK: - 主題家具（規範 §2；方塊尺寸照抄）

/// 擺在哪一列：wall＝靠後牆、mid＝後帶前緣（z −2.2）、front＝前帶（≤0.9 高）、high＝掛牆高處、attach＝放在別的家具上
enum PropRow { case wall, mid, front, high, ceiling, onDesk, onBench }

@MainActor
struct PropDef {
    var w: Float, d: Float, h: Float, y0: Float = 0
    var row: PropRow
    var build: (Kit, Xf, SCNMaterial, (CGFloat, CGFloat) -> SCNMaterial) -> Void     // kit、擺放框、識別色、識別色發光(白天,夜晚)
}

@MainActor
enum TowerProps {
    typealias B = (Kit, Xf, SCNMaterial, (CGFloat, CGFloat) -> SCNMaterial) -> Void
    static func def(_ w: Float, _ d: Float, _ h: Float, y0: Float = 0, _ row: PropRow, _ build: @escaping B) -> PropDef {
        PropDef(w: w, d: d, h: h, y0: y0, row: row, build: build)
    }

    static func books(_ k: Kit, _ x: Xf, w: Float, h: Float, d: Float, rows: Int, alt: UInt32? = nil) {
        let cols: [UInt32] = alt.map { [TP.FN5, $0, TP.FN5] } ?? [TP.FN5, TP.FN4, TP.FN2]      // 只用三色輪替（不准彩虹書）
        for r in 0..<rows {
            let y = 0.12 + Float(r) * (h - 0.2) / Float(rows)
            k.b(x, 0, y, d / 2 - 0.12, w - 0.15, 0.28, 0.25, TM.f(cols[r % cols.count]))
        }
    }

    static let all: [String: PropDef] = {
        var p: [String: PropDef] = [:]
        // ── 通用擺設庫
        p["plant_tall"] = def(0.9, 0.9, 2.15, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.5, 0.5, 0.5, TM.f(TP.POT)); k.b(x, 0, 0.5, 0, 0.08, 0.6, 0.08, TM.f(TP.FN1))
            k.b(x, 0, 1.0, 0, 0.9, 0.7, 0.9, TM.f(TP.PL1)); k.b(x, 0.1, 1.7, -0.05, 0.6, 0.45, 0.6, TM.f(TP.PL2))
        }
        p["plant_low"] = def(0.5, 0.5, 0.7, .front) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.4, 0.35, 0.4, TM.f(TP.POT)); k.b(x, 0, 0.35, 0, 0.5, 0.35, 0.5, TM.f(TP.PL2))
        }
        p["sofa"] = def(2.0, 0.8, 0.82, .front) { k, x, _, _ in
            k.b(x, 0, 0, 0, 2.0, 0.42, 0.8, TM.f(TP.FN4)); k.b(x, 0, 0.42, -0.31, 2.0, 0.40, 0.18, TM.f(TP.FN4))
        }
        p["lounge_chair"] = def(0.75, 0.75, 0.82, .front) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.75, 0.42, 0.75, TM.f(TP.FN4)); k.b(x, 0, 0.42, -0.3, 0.75, 0.40, 0.15, TM.f(TP.FN4))
        }
        p["coffee_cart"] = def(1.0, 0.55, 1.4, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.0, 0.95, 0.55, TM.f(TP.FN1)); k.b(x, -0.2, 0.95, 0, 0.35, 0.45, 0.35, TM.f(TP.FN3))
            for i in 0..<3 { k.b(x, 0.12 + Float(i) * 0.12, 0.95, 0.1, 0.08, 0.08, 0.08, TM.f(TP.FN5)) }      // 杯子
        }
        p["whiteboard"] = def(2.4, 0.12, 1.2, y0: 0.88, .wall) { k, x, _, _ in
            k.b(x, 0, 0.02, -0.03, 2.4, 1.2, 0.06, TM.f(TP.FN5)); k.b(x, 0, 0, 0.0, 2.4, 0.04, 0.12, TM.f(TP.FN3))
        }
        p["meeting_table"] = def(2.0, 1.2, 0.74, .mid) { k, x, _, _ in
            k.b(x, 0, 0.7, 0, 1.2, 0.04, 1.2, TM.f(TP.FN2)); k.b(x, 0, 0, 0, 0.12, 0.7, 0.12, TM.f(TP.FN3))
            for sx: Float in [-0.85, 0.85] { k.b(x, sx, 0, 0, 0.4, 0.45, 0.4, TM.f(TP.FN4)) }
        }
        p["bench"] = def(2.0, 0.45, 0.45, .front) { k, x, _, _ in k.b(x, 0, 0, 0, 2.0, 0.45, 0.45, TM.f(TP.FN2)) }
        p["wall_clock"] = def(0.45, 0.06, 0.45, y0: 1.98, .high) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.45, 0.45, 0.05, TM.f(TP.FN5))
            k.b(x, 0, 0.22, 0.03, 0.02, 0.17, 0.01, TM.f(TP.FN3)); k.b(x, 0.06, 0.22, 0.03, 0.13, 0.02, 0.01, TM.f(TP.FN3))
        }
        // ── 1 監控中心
        p["video_wall"] = def(3.6, 0.14, 1.5, y0: 0.9, .wall) { k, x, _, ag in
            k.b(x, 0, 0, -0.01, 3.6, 1.5, 0.12, TM.f(TP.ST1))
            for i in 0..<4 { for j in 0..<2 {
                let acc = i == 1 && j == 1
                k.b(x, -1.35 + Float(i) * 0.9, 0.08 + Float(j) * 0.68, 0.06, 0.8, 0.6, 0.02, acc ? ag(0.25, 0.8) : TM.glow(0x2A3A4A, 0.25, 0.8))
            } }
        }
        p["status_beacon"] = def(0.3, 0.3, 1.3, .wall) { k, x, _, ag in
            k.b(x, 0, 0, 0, 0.3, 0.1, 0.3, TM.f(TP.FN3)); k.b(x, 0, 0.1, 0, 0.18, 1.2, 0.18, ag(0.15, 0.9))
        }
        p["console"] = def(3.7, 0.72, 0.84, .mid) { k, x, _, _ in
            for i in -1...1 { k.b(x, Float(i) * 1.25, 0, 0, 1.2, 0.8, 0.7, TM.f(TP.FN3)) }
            k.b(x, 0, 0.8, 0, 3.7, 0.04, 0.72, TM.f(TP.FN5))
        }
        p["console1"] = def(1.2, 0.72, 0.84, .mid) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.2, 0.8, 0.7, TM.f(TP.FN3)); k.b(x, 0, 0.8, 0, 1.2, 0.04, 0.72, TM.f(TP.FN5))
            for sx: Float in [-0.3, 0.3] { k.b(x, sx, 0.84, -0.2, 0.5, 0.3, 0.04, TM.f(TP.FN6)) }
        }
        p["server_rack"] = def(0.6, 0.8, 2.0, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.6, 2.0, 0.8, TM.f(TP.FN3))
            for i in 0..<6 { k.b(x, -0.2, 0.3 + Float(i) * 0.28, 0.41, 0.04, 0.04, 0.02, TM.glow(0x6FD08C, 0.6, 1.5)) }
        }
        // ── 2 App 開發室
        p["phone_wall"] = def(2.0, 0.1, 1.2, y0: 1.0, .wall) { k, x, _, _ in
            k.b(x, 0, 0, -0.02, 2.0, 1.2, 0.05, TM.f(TP.FN5))
            for i in 0..<6 { k.b(x, -0.75 + Float(i) * 0.3, 0.29, 0.02, 0.16, 0.32, 0.03, TM.f(TP.FN6)) }
        }
        p["beanbag"] = def(0.8, 0.8, 0.65, .front) { k, x, a, _ in
            k.b(x, 0, 0, 0, 0.8, 0.45, 0.8, a); k.b(x, 0, 0.45, -0.25, 0.6, 0.2, 0.25, a)
        }
        p["standing_desk"] = def(1.6, 0.7, 1.1, .wall) { k, x, _, _ in
            k.b(x, 0, 1.05, 0, 1.6, 0.05, 0.7, TM.f(TP.FN2))
            for sx: Float in [-0.7, 0.7] { k.b(x, sx, 0, 0, 0.06, 1.05, 0.6, TM.f(TP.FN3)) }
        }
        p["device_cart"] = def(0.8, 0.5, 0.95, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.8, 0.9, 0.5, TM.f(TP.FN3))
            for i in 0..<3 { k.b(x, -0.25 + Float(i) * 0.25, 0.9, 0, 0.22, 0.02, 0.3, TM.f(TP.FN6)) }
        }
        // ── 3 研究書房
        p["bookshelf"] = def(2.9, 0.35, 2.2, .wall) { k, x, _, _ in
            for i in -1...1 {
                let s = x.at(Float(i) * 1.0, 0, 0)
                k.b(s, 0, 0, 0, 0.9, 2.2, 0.33, TM.f(TP.FN1))
                books(k, s, w: 0.9, h: 2.2, d: 0.35, rows: 5)
            }
        }
        p["reading_chair"] = def(0.8, 0.8, 0.92, .front) { k, x, a, _ in
            k.b(x, 0, 0, 0, 0.8, 0.42, 0.8, a); k.b(x, 0, 0.42, -0.31, 0.8, 0.5, 0.18, a)
        }
        p["long_table"] = def(2.4, 0.9, 0.75, .mid) { k, x, _, _ in
            k.b(x, 0, 0.7, 0, 2.4, 0.05, 0.9, TM.f(TP.FN1))
            for (sx, sz) in [(-1.1, -0.38), (1.1, -0.38), (-1.1, 0.38), (1.1, 0.38)] as [(Float, Float)] { k.b(x, sx, 0, sz, 0.06, 0.7, 0.06, TM.f(TP.FN3)) }
        }
        p["floor_lamp"] = def(0.35, 0.35, 1.9, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.3, 0.04, 0.3, TM.f(TP.FN3)); k.b(x, 0, 0, 0, 0.05, 1.6, 0.05, TM.f(TP.FN3))
            k.b(x, 0, 1.6, 0, 0.35, 0.3, 0.35, TM.glow(TP.LT1, 0, 1.0))
        }
        p["card_catalog"] = def(0.9, 0.45, 1.1, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.9, 1.1, 0.45, TM.f(TP.FN1))
            for r in 0..<4 { k.b(x, 0, 0.2 + Float(r) * 0.25, 0.23, 0.8, 0.01, 0.01, TM.f(TP.FN3)) }
        }
        p["globe"] = def(0.4, 0.4, 1.2, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.3, 0.04, 0.3, TM.f(TP.FN3)); k.b(x, 0, 0, 0, 0.05, 0.8, 0.05, TM.f(TP.FN3))
            k.b(x, 0, 0.8, 0, 0.4, 0.4, 0.4, TM.f(0xB9B2A5))
        }
        // ── 4 3D 列印工坊
        p["printer"] = def(1.52, 0.62, 1.47, .wall) { k, x, _, _ in
            for sx: Float in [-0.45, 0.45] {
                k.b(x, sx, 0, 0, 0.62, 0.75, 0.62, TM.f(TP.FN4)); k.b(x, sx, 0.75, 0, 0.62, 0.72, 0.62, TM.f(TP.FN3))
                k.b(x, sx, 0.86, 0.315, 0.5, 0.5, 0.01, TM.f(0x9AB0B8))
            }
        }
        p["parts_bin"] = def(0.6, 0.45, 1.0, .wall) { k, x, a, _ in
            k.b(x, 0, 0, 0, 0.6, 1.0, 0.45, a)
            for r in 0..<4 { k.b(x, 0, 0.22 + Float(r) * 0.22, 0.23, 0.5, 0.01, 0.01, TM.f(TP.FN3)) }
        }
        p["workbench"] = def(2.0, 0.7, 2.1, .wall) { k, x, _, _ in
            k.b(x, 0, 0.88, 0, 2.0, 0.06, 0.7, TM.f(TP.FN2))
            for sx: Float in [-0.9, 0.9] { k.b(x, sx, 0, 0, 0.06, 0.88, 0.6, TM.f(TP.FN3)) }
            k.b(x, 0, 1.2, -0.33, 1.6, 0.9, 0.04, TM.f(TP.FN4))
        }
        p["filament_rack"] = def(1.2, 0.35, 1.5, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.2, 1.5, 0.33, TM.f(TP.FN3))
            let c: [UInt32] = [TP.FN5, TP.FN4, TP.FN6]
            for i in 0..<4 { for j in 0..<2 { k.b(x, -0.42 + Float(i) * 0.28, 0.35 + Float(j) * 0.55, 0.2, 0.22, 0.22, 0.12, TM.f(c[(i + j) % 3])) } }
        }
        p["finished_shelf"] = def(1.4, 0.35, 1.45, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.4, 1.2, 0.35, TM.f(TP.FN5))
            for i in 0..<3 { k.b(x, -0.45 + Float(i) * 0.45, 1.2, 0, 0.25, 0.25, 0.25, TM.f(TP.WL1)) }
        }
        // ── 5 秘書電話室
        p["phone_booth"] = def(1.1, 1.1, 2.2, .wall) { k, x, a, _ in
            k.b(x, 0, 0, 0, 1.1, 0.06, 1.1, a); k.b(x, 0, 2.12, 0, 1.1, 0.08, 1.1, a)
            for (sx, sz) in [(-0.53, -0.53), (0.53, -0.53), (-0.53, 0.53), (0.53, 0.53)] as [(Float, Float)] { k.b(x, sx, 0, sz, 0.05, 2.12, 0.05, TM.f(TP.FN3)) }
            k.b(x, 0, 0.08, 0.53, 1.0, 2.0, 0.02, TM.glass(0.3))
            k.b(x, 0, 0, -0.1, 0.4, 0.45, 0.4, TM.f(TP.FN4))
        }
        p["tablet_stand"] = def(0.34, 0.3, 1.4, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.3, 0.06, 0.3, TM.f(TP.FN3)); k.b(x, 0, 0.06, 0, 0.04, 1.1, 0.04, TM.f(TP.FN3))
            k.b(x, 0, 1.16, 0, 0.34, 0.24, 0.03, TM.f(TP.FN6)); k.b(x, 0, 1.18, 0.02, 0.3, 0.2, 0.01, TM.glow(0x7FB8C8, 0.3, 0.9))
        }
        p["side_table"] = def(0.5, 0.5, 0.52, .front) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.5, 0.5, 0.5, TM.f(TP.FN1)); k.b(x, 0.02, 0.5, 0, 0.3, 0.02, 0.22, TM.f(TP.FN5))      // 雜誌
        }
        p["mail_rack"] = def(1.0, 0.3, 0.8, y0: 1.3, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.0, 0.8, 0.3, TM.f(TP.FN1))
            for r in 0..<3 { k.b(x, 0, 0.2 + Float(r) * 0.22, 0.16, 0.9, 0.02, 0.01, TM.f(TP.FN3)) }
        }
        p["switchboard"] = def(1.2, 0.5, 1.0, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.2, 1.0, 0.5, TM.f(TP.FN3))
            for i in 0..<6 { for j in 0..<2 { k.b(x, -0.45 + Float(i) * 0.18, 0.7 + Float(j) * 0.15, 0.26, 0.04, 0.04, 0.02, TM.glow(TP.LT1, 0.2, 1.0)) } }
        }
        // ── 6 交易室
        p["ticker_wall"] = def(3.2, 0.12, 1.12, y0: 1.2, .wall) { k, x, _, ag in
            k.b(x, 0, 0, -0.01, 3.0, 1.0, 0.1, TM.f(TP.ST1))
            for i in 0..<3 { for j in 0..<2 { k.b(x, -1.0 + Float(i) * 1.0, 0.04 + Float(j) * 0.5, 0.05, 0.9, 0.42, 0.01, TM.glow(0x20302A, 0.2, 0.6)) } }
            k.b(x, 0, 0.99, 0.02, 3.2, 0.12, 0.04, ag(0.3, 1.0))        // ★ 跑馬燈（中心高 2.25）
        }
        p["quad_monitor"] = def(1.0, 0.3, 0.7, .onDesk) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.06, 0.4, 0.06, TM.f(TP.FN3))
            for i in 0..<2 { for j in 0..<2 { k.b(x, -0.26 + Float(i) * 0.52, 0.3 + Float(j) * 0.32, 0.03, 0.5, 0.3, 0.03, TM.f(TP.FN6)) } }
        }
        p["bull_statue"] = def(0.6, 0.5, 1.4, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.5, 0.9, 0.5, TM.f(TP.FN5)); k.b(x, 0, 0.9, 0, 0.6, 0.5, 0.3, TM.f(TP.FN6))
        }
        p["safe"] = def(0.6, 0.6, 0.8, .wall) { k, x, _, _ in k.b(x, 0, 0, 0, 0.6, 0.8, 0.6, TM.f(TP.FN3)) }
        // ── 7 攝影棚
        p["backdrop"] = def(2.6, 0.85, 2.6, .wall) { k, x, _, ag in
            k.b(x, 0, 0, -0.4, 2.6, 2.4, 0.05, TM.f(TP.FN4)); k.b(x, 0, 0, 0, 2.6, 0.05, 0.8, TM.f(TP.FN4))
            k.b(x, -1.0, 2.4, -0.38, 0.6, 0.2, 0.08, ag(0.3, 1.2))       // ★ ON AIR 燈箱（掛高 2.5）
        }
        p["softbox"] = def(0.6, 0.6, 2.2, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.05, 1.6, 0.05, TM.f(TP.FN3)); k.b(x, 0, 1.6, 0, 0.6, 0.6, 0.25, TM.glow(TP.FN5, 0.1, 0.8))
        }
        p["camera_tripod"] = def(0.4, 0.4, 1.5, .mid) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.05, 1.3, 0.05, TM.f(TP.FN3)); k.b(x, 0, 1.3, 0, 0.3, 0.2, 0.2, TM.f(TP.FN6))
        }
        p["edit_bay"] = def(1.6, 0.8, 1.15, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.6, 0.75, 0.8, TM.f(TP.FN1))
            for sx: Float in [-0.35, 0.35] { k.b(x, sx, 0.78, -0.2, 0.6, 0.35, 0.04, TM.f(TP.FN6)) }
        }
        // ── 8 設計工作室
        p["moodboard"] = def(2.4, 0.1, 1.4, y0: 0.9, .wall) { k, x, _, _ in
            k.b(x, 0, 0, -0.02, 2.4, 1.4, 0.05, TM.f(TP.FN5))
            let c: [UInt32] = [TP.FN4, TP.FN2, TP.FN1]
            for i in 0..<4 { for j in 0..<2 { k.b(x, -0.85 + Float(i) * 0.57, 0.25 + Float(j) * 0.55, 0.01, 0.4, 0.3, 0.01, TM.f(c[(i + j) % 3])) } }
        }
        p["pendant_dome"] = def(0.9, 0.9, 0.8, y0: 2.45, .ceiling) { k, x, a, _ in
            k.b(x, 0, 0.32, 0, 0.02, 0.5, 0.02, TM.f(TP.FN3))
            k.b(x, 0, 0.02, 0, 0.9, 0.3, 0.9, a); k.b(x, 0, 0, 0, 0.7, 0.02, 0.7, TM.glow(TP.LT1, 0, 1.2))
        }
        p["drafting_table"] = def(1.4, 0.9, 1.05, .mid) { k, x, _, _ in
            for sx: Float in [-0.62, 0.62] { k.b(x, sx, 0, 0, 0.06, 0.92, 0.7, TM.f(TP.FN3)) }
            k.b(x, 0, 0.9, 0.22, 1.4, 0.04, 0.45, TM.f(TP.FN2)); k.b(x, 0, 1.0, -0.22, 1.4, 0.04, 0.45, TM.f(TP.FN2))
        }
        p["material_shelf"] = def(1.2, 0.4, 1.6, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.2, 1.6, 0.38, TM.f(TP.FN2))
            let c: [UInt32] = [TP.FN5, TP.FN4, TP.FN1]
            for r in 0..<3 { for i in 0..<4 { k.b(x, -0.42 + Float(i) * 0.28, 0.2 + Float(r) * 0.5, 0.2, 0.2, 0.2, 0.02, TM.f(c[(r + i) % 3])) } }
        }
        p["easel"] = def(0.8, 0.5, 1.7, .wall) { k, x, _, _ in
            for sx: Float in [-0.3, 0.3] { k.b(x, sx, 0, 0, 0.05, 1.7, 0.05, TM.f(TP.FN1)) }
            k.b(x, 0, 0.75, 0.05, 0.7, 0.85, 0.03, TM.f(TP.FN5))
        }
        // ── 9 法務室
        p["conference_table"] = def(3.0, 2.0, 0.76, .mid) { k, x, _, _ in
            k.b(x, 0, 0.7, 0, 3.0, 0.06, 1.1, TM.f(TP.FN1))
            for sx: Float in [-0.9, 0.9] { k.b(x, sx, 0, 0, 0.2, 0.7, 0.6, TM.f(TP.FN1)) }
            for sx: Float in [-1.0, 0, 1.0] { for sz: Float in [-0.8, 0.8] { k.b(x, sx, 0, sz, 0.45, 0.45, 0.4, TM.f(TP.FN4)) } }
        }
        p["document_safe"] = def(0.8, 0.5, 1.3, .wall) { k, x, a, _ in
            k.b(x, 0, 0, 0, 0.8, 1.3, 0.5, a); k.b(x, 0.25, 0.7, 0.26, 0.08, 0.08, 0.04, TM.f(TP.FN5))
        }
        p["file_cabinet"] = def(1.6, 0.6, 1.3, .wall) { k, x, _, _ in
            for i in -1...1 {
                k.b(x, Float(i) * 0.54, 0, 0, 0.5, 1.3, 0.6, TM.f(TP.FN3))
                for r in 0..<3 { k.b(x, Float(i) * 0.54, 0.35 + Float(r) * 0.4, 0.31, 0.3, 0.03, 0.01, TM.f(TP.FN4)) }
            }
        }
        p["law_shelf"] = def(1.8, 0.35, 2.0, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.8, 2.0, 0.33, TM.f(TP.FN1)); books(k, x, w: 1.8, h: 2.0, d: 0.35, rows: 4, alt: 0x6B5B4B)
        }
        p["seal_desk"] = def(0.7, 0.5, 0.95, .wall) { k, x, _, _ in k.b(x, 0, 0, 0, 0.7, 0.95, 0.5, TM.f(TP.FN5)) }
        // ── 10 財務帳房
        p["ledger_cabinet"] = def(1.8, 0.45, 1.0, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.8, 1.0, 0.45, TM.f(TP.FN1))
            for r in 0..<3 { k.b(x, 0, 0.25 + Float(r) * 0.3, 0.23, 1.7, 0.01, 0.01, TM.f(TP.FN3)) }
        }
        p["brass_safe"] = def(0.7, 0.6, 0.9, .wall) { k, x, a, _ in
            k.b(x, 0, 0, 0, 0.7, 0.9, 0.6, a); k.b(x, 0, 0.45, 0.31, 0.18, 0.18, 0.04, TM.f(TP.FN3))
        }
        p["receipt_tray"] = def(0.5, 0.35, 0.08, .onDesk) { k, x, _, _ in k.b(x, 0, 0, 0, 0.5, 0.08, 0.35, TM.f(TP.FN5)) }
        p["cashier_counter"] = def(1.2, 0.6, 1.04, .mid) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.2, 1.0, 0.6, TM.f(TP.FN3)); k.b(x, 0, 1.0, 0, 1.25, 0.04, 0.65, TM.f(TP.FN5))
        }
        p["ledger_shelf"] = def(1.2, 0.35, 1.8, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.2, 1.8, 0.33, TM.f(TP.FN1)); books(k, x, w: 1.2, h: 1.8, d: 0.35, rows: 4)
        }
        // ── 11 遊戲工作室
        p["arcade"] = def(0.7, 0.8, 1.8, .wall) { k, x, a, _ in
            k.b(x, 0, 0, 0, 0.7, 1.8, 0.8, a); k.b(x, 0, 1.1, 0.4, 0.56, 0.46, 0.02, TM.f(TP.FN6))
            k.b(x, 0, 1.13, 0.41, 0.5, 0.4, 0.01, TM.glow(0xB18CFF, 0.3, 1.0))
        }
        p["arcade_n"] = def(0.7, 0.8, 1.8, .wall) { k, x, _, _ in          // 第二台大型機：中性色（識別色只用在一件）
            k.b(x, 0, 0, 0, 0.7, 1.8, 0.8, TM.f(TP.FN6)); k.b(x, 0, 1.1, 0.4, 0.56, 0.46, 0.02, TM.f(TP.FN3))
            k.b(x, 0, 1.13, 0.41, 0.5, 0.4, 0.01, TM.glow(0x6FA8DC, 0.3, 1.0))
        }
        p["playtest_tv"] = def(1.8, 0.45, 1.5, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.8, 0.5, 0.45, TM.f(TP.FN1)); k.b(x, 0, 0.6, -0.1, 1.6, 0.9, 0.08, TM.f(TP.FN6))
        }
        p["sprite_wall"] = def(2.0, 0.1, 1.2, y0: 0.9, .wall) { k, x, _, _ in
            k.b(x, 0, 0, -0.02, 2.0, 1.2, 0.05, TM.f(TP.FN5))
            for i in 0..<4 { for j in 0..<3 where (i + j) % 2 == 0 { k.b(x, -0.6 + Float(i) * 0.4, 0.2 + Float(j) * 0.35, 0.01, 0.36, 0.3, 0.01, TM.f(j == 1 ? TP.FN2 : TP.FN4)) } }
        }
        p["controller_shelf"] = def(1.0, 0.3, 0.8, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.0, 0.8, 0.3, TM.f(TP.FN3))
            for i in 0..<3 { k.b(x, -0.3 + Float(i) * 0.3, 0.8, 0, 0.2, 0.06, 0.14, TM.f(TP.FN6)) }
        }
        p["trophy_shelf"] = def(1.0, 0.35, 1.9, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.0, 1.6, 0.33, TM.f(TP.FN1))
            for i in 0..<3 { k.b(x, -0.3 + Float(i) * 0.3, 1.6, 0, 0.15, 0.3, 0.15, TM.f(TP.FN5)) }
        }
        // ── 12 硬體實驗室
        p["esd_bench"] = def(2.0, 0.9, 1.1, .wall) { k, x, _, _ in
            k.b(x, 0, 0.71, 0, 2.0, 0.04, 0.9, TM.f(0x7E8A86))
            for (sx, sz) in [(-0.95, -0.4), (0.95, -0.4), (-0.95, 0.4), (0.95, 0.4)] as [(Float, Float)] { k.b(x, sx, 0, sz, 0.05, 0.71, 0.05, TM.f(TP.FN3)) }
            k.b(x, -0.5, 0.75, -0.1, 0.5, 0.3, 0.4, TM.f(TP.FN6)); k.b(x, -0.5, 0.8, 0.105, 0.3, 0.2, 0.01, TM.glow(0x7FD08C, 0.3, 0.9))
        }
        p["speaker_tower"] = def(0.4, 0.4, 1.1, .wall) { k, x, a, _ in
            k.b(x, 0, 0, 0, 0.4, 1.1, 0.4, a)
            for y: Float in [0.3, 0.7] { k.b(x, 0, y, 0.205, 0.25, 0.25, 0.02, TM.f(TP.FN6)) }
        }
        p["parts_wall"] = def(1.6, 0.2, 1.2, y0: 0.9, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.6, 1.2, 0.2, TM.f(TP.FN3))
            for i in 0..<4 { for j in 0..<3 { k.b(x, -0.54 + Float(i) * 0.36, 0.15 + Float(j) * 0.36, 0.1, 0.22, 0.12, 0.15, TM.f(TP.FN4)) } }
        }
        p["soldering_station"] = def(0.4, 0.3, 0.3, .onBench) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.4, 0.3, 0.3, TM.f(TP.FN6)); k.b(x, 0.12, 0.3, 0, 0.03, 0.25, 0.03, TM.f(TP.FN3))
        }
        p["test_rig"] = def(1.0, 0.6, 1.4, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.0, 0.06, 0.6, TM.f(TP.FN3)); k.b(x, 0, 1.34, 0, 1.0, 0.06, 0.6, TM.f(TP.FN3))
            for sx: Float in [-0.47, 0.47] { k.b(x, sx, 0, 0, 0.06, 1.4, 0.6, TM.f(TP.FN3)) }
            k.b(x, 0, 0.5, 0, 0.5, 0.4, 0.4, TM.f(TP.FN6))
        }
        // ── 13 行銷室
        p["content_wall"] = def(2.4, 0.1, 1.6, y0: 1.0, .wall) { k, x, _, ag in
            k.b(x, 0, 0, -0.02, 2.4, 1.2, 0.05, TM.f(TP.FN5))
            for i in 0..<4 { for j in 0..<3 { k.b(x, -0.81 + Float(i) * 0.54, 0.12 + Float(j) * 0.36, 0.01, 0.45, 0.3, 0.01, TM.f((i + j) % 2 == 0 ? TP.FN4 : TP.FN2)) } }
            k.b(x, 0, 1.24, 0, 1.2, 0.4, 0.08, ag(0.3, 1.2))           // ★ 標語燈箱（掛高 2.4）
        }
        p["ring_light"] = def(0.5, 0.3, 2.0, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.05, 1.5, 0.05, TM.f(TP.FN3))
            let l = TM.glow(TP.LT1, 0.2, 1.0)
            k.b(x, 0, 1.5, 0, 0.5, 0.06, 0.06, l); k.b(x, 0, 1.94, 0, 0.5, 0.06, 0.06, l)
            for sx: Float in [-0.22, 0.22] { k.b(x, sx, 1.5, 0, 0.06, 0.5, 0.06, l) }
        }
        p["product_table"] = def(1.2, 0.6, 0.9, .mid) { k, x, _, _ in k.b(x, 0, 0, 0, 1.2, 0.9, 0.6, TM.f(TP.FN5)) }
        // ── 14 調度中心
        p["route_map"] = def(3.0, 0.1, 1.4, y0: 1.0, .wall) { k, x, a, _ in
            k.b(x, 0, 0, -0.02, 3.0, 1.4, 0.05, TM.f(TP.FN5))
            // 三條路線（各 3 段折線，只用識別色）
            let routes: [[(Float, Float)]] = [[(-1.3, 0.3), (-0.4, 0.3), (-0.4, 1.0), (0.8, 1.0)],
                                              [(-1.1, 1.2), (0.0, 1.2), (0.0, 0.5), (1.3, 0.5)],
                                              [(-0.8, 0.15), (0.6, 0.15), (0.6, 0.8), (1.2, 1.2)]]
            for r in routes { for (p0, p1) in zip(r, r.dropFirst()) {
                let cx = (p0.0 + p1.0) / 2, cy = (p0.1 + p1.1) / 2
                k.b(x, cx, cy - 0.02 - abs(p1.1 - p0.1) / 2, 0.01, max(0.04, abs(p1.0 - p0.0) + 0.04), max(0.04, abs(p1.1 - p0.1) + 0.04), 0.01, a)
            } }
        }
        p["radio_desk"] = def(2.4, 0.8, 1.1, .mid) { k, x, _, _ in
            k.b(x, 0, 0, 0, 2.4, 0.8, 0.8, TM.f(TP.FN3)); k.b(x, 0, 0.8, 0, 2.45, 0.04, 0.82, TM.f(TP.FN5))
            for sx: Float in [-0.6, 0.6] { k.b(x, sx, 0.84, -0.2, 0.1, 0.25, 0.08, TM.f(TP.FN6)) }
        }
        p["flight_board"] = def(1.6, 0.1, 0.8, y0: 1.3, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.6, 0.8, 0.08, TM.f(TP.FN6))
            for r in 0..<5 { k.b(x, 0, 0.1 + Float(r) * 0.14, 0.045, 1.4, 0.06, 0.01, TM.glow(TP.cityWindow, 0.2, 0.7)) }
        }
        p["key_cabinet"] = def(0.6, 0.25, 0.9, y0: 1.0, .wall) { k, x, _, _ in k.b(x, 0, 0, 0, 0.6, 0.9, 0.25, TM.f(TP.FN1)) }
        // ── 15 建築製圖室
        p["plan_table"] = def(2.4, 1.2, 1.7, .mid) { k, x, _, ag in
            k.b(x, 0, 0.9, 0, 2.4, 0.06, 1.2, TM.f(TP.FN2))
            for sx: Float in [-1.1, 1.1] { k.b(x, sx, 0, 0, 0.08, 0.9, 1.0, TM.f(TP.FN3)) }
            k.b(x, 0, 0.96, 0, 1.6, 0.01, 0.8, TM.f(TP.FN5))
            // ★ 懸臂燈（夾在大圖桌上）
            k.b(x, 0.85, 0.96, -0.4, 0.3, 0.05, 0.3, TM.f(TP.FN3)); k.b(x, 0.85, 1.0, -0.4, 0.03, 0.55, 0.03, TM.f(TP.FN3))
            k.b(x, 0.85, 1.5, -0.25, 0.22, 0.14, 0.22, ag(0, 0.6))
        }
        p["plan_chest"] = def(1.4, 0.9, 0.9, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.4, 0.9, 0.9, TM.f(TP.FN3))
            for r in 0..<4 { k.b(x, 0, 0.18 + Float(r) * 0.18, 0.455, 1.3, 0.01, 0.01, TM.f(0x55585E)) }
        }
        p["model_plinth"] = def(0.8, 0.8, 1.5, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.8, 1.0, 0.8, TM.f(TP.FN5))
            k.b(x, -0.12, 1.0, 0, 0.3, 0.5, 0.3, TM.f(TP.WL1)); k.b(x, 0.18, 1.0, 0.05, 0.25, 0.3, 0.4, TM.f(TP.WL1))
        }
        p["section_wall"] = def(2.0, 0.1, 1.2, y0: 1.0, .wall) { k, x, _, _ in
            k.b(x, 0, 0, -0.02, 2.0, 1.2, 0.05, TM.f(TP.FN5))
            for r in 0..<4 { k.b(x, 0, 0.2 + Float(r) * 0.25, 0.01, 1.6 - Float(r % 2) * 0.5, 0.02, 0.01, TM.f(TP.FN3)) }
            for i in 0..<3 { k.b(x, -0.6 + Float(i) * 0.6, 0.15, 0.01, 0.02, 0.9, 0.01, TM.f(TP.FN3)) }
        }
        // ── 10-20 UI/UX 優化 §3.2 生活感共用組＋§3.3 主題新件（尺寸照規劃；只用色票裡的顏色，不新增材質種類）
        p["trash_bin"] = def(0.25, 0.25, 0.35, .front) { k, x, _, _ in k.b(x, 0, 0, 0, 0.25, 0.35, 0.25, TM.f(TP.FN3)) }
        p["coat_rack"] = def(0.45, 0.45, 1.75, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.35, 0.04, 0.35, TM.f(TP.FN3)); k.b(x, 0, 0, 0, 0.05, 1.7, 0.05, TM.f(TP.FN3))
            k.b(x, 0, 1.7, 0, 0.4, 0.05, 0.4, TM.f(TP.FN3)); k.b(x, 0.12, 0.95, 0.06, 0.3, 0.6, 0.15, TM.f(TP.FN4))
        }
        p["charging_shelf"] = def(0.9, 0.3, 0.9, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.9, 0.9, 0.3, TM.f(TP.FN3))
            for i in 0..<6 { k.b(x, -0.35 + Float(i % 3) * 0.35, 0.3 + Float(i / 3) * 0.32, 0.15, 0.1, 0.18, 0.02, TM.glow(0x7FB8C8, 0.3, 0.9)) }
        }
        p["box_stack"] = def(1.1, 0.4, 0.8, .front) { k, x, _, _ in
            k.b(x, -0.27, 0, 0, 0.5, 0.4, 0.4, TM.f(TP.FN2)); k.b(x, 0.27, 0, 0, 0.5, 0.4, 0.4, TM.f(TP.FN2))
            k.b(x, -0.1, 0.4, 0, 0.5, 0.4, 0.4, TM.f(TP.FN2))
        }
        p["news_tv"] = def(1.2, 0.08, 0.7, y0: 1.45, .high) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.2, 0.7, 0.06, TM.f(TP.FN6)); k.b(x, 0, 0.06, 0.035, 1.1, 0.58, 0.01, TM.glow(0x5B7A99, 0.3, 0.9))
        }
        p["equipment_case"] = def(0.7, 0.45, 0.4, .front) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.7, 0.4, 0.45, TM.f(TP.FN3)); k.b(x, 0, 0.4, 0, 0.2, 0.04, 0.05, TM.f(TP.FN4))
        }
        p["sample_table"] = def(1.0, 0.6, 0.47, .front) { k, x, _, _ in
            k.b(x, 0, 0, 0, 1.0, 0.45, 0.6, TM.f(TP.FN2))
            for (i, c) in [TP.FN4, TP.FN1, TP.FN5].enumerated() { k.b(x, -0.3 + Float(i) * 0.3, 0.45, 0, 0.2, 0.01, 0.3, TM.f(c)) }
        }
        p["cable_reel"] = def(0.9, 0.4, 0.4, .wall) { k, x, _, _ in
            for sx: Float in [-0.24, 0.24] { k.b(x, sx, 0, 0, 0.4, 0.4, 0.25, TM.f(TP.FN3)); k.b(x, sx, 0.1, 0.13, 0.2, 0.2, 0.01, TM.f(TP.FN2)) }
        }
        p["scope_cart"] = def(0.6, 0.45, 0.85, .front) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.6, 0.05, 0.45, TM.f(TP.FN3)); k.b(x, 0, 0.5, 0, 0.6, 0.05, 0.45, TM.f(TP.FN3))
            for sx: Float in [-0.27, 0.27] { k.b(x, sx, 0, 0, 0.04, 0.55, 0.04, TM.f(TP.FN3)) }
            k.b(x, 0, 0.55, 0, 0.4, 0.3, 0.3, TM.f(TP.FN6)); k.b(x, 0, 0.6, 0.155, 0.28, 0.18, 0.01, TM.glow(0x7FD08C, 0.3, 0.9))
        }
        p["poster_stand"] = def(0.6, 0.3, 1.45, .wall) { k, x, a, _ in
            k.b(x, 0, 0, 0, 0.4, 0.04, 0.3, TM.f(TP.FN3)); k.b(x, 0, 0.04, 0, 0.6, 1.4, 0.05, TM.f(TP.FN5))
            k.b(x, 0, 0.9, 0.03, 0.5, 0.4, 0.01, a)
        }
        p["car_model"] = def(0.5, 0.25, 0.2, .onDesk) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.5, 0.12, 0.25, TM.f(TP.FN6)); k.b(x, -0.03, 0.12, 0, 0.28, 0.08, 0.22, TM.f(TP.FN6))
        }
        p["luggage"] = def(0.9, 0.3, 0.6, .front) { k, x, _, _ in
            for sx: Float in [-0.24, 0.24] { k.b(x, sx, 0, 0, 0.4, 0.6, 0.25, TM.f(TP.FN4)); k.b(x, sx, 0.6, 0, 0.12, 0.04, 0.04, TM.f(TP.FN3)) }
        }
        p["roll_bin"] = def(0.4, 0.4, 0.85, .front) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.35, 0.7, 0.35, TM.f(TP.FN3))
            for (dx, dz) in [(-0.08, -0.08), (0.08, -0.08), (0, 0), (-0.08, 0.08), (0.08, 0.08)] as [(Float, Float)] { k.b(x, dx, 0.5, dz, 0.07, 0.35, 0.07, TM.f(TP.FN5)) }
        }
        // ── 10-20 第 4 棒：生活感組新件（飲水機、影印機）
        p["water_cooler"] = def(0.42, 0.42, 1.2, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.4, 0.85, 0.4, TM.f(TP.FN5)); k.b(x, 0, 0.85, 0, 0.3, 0.35, 0.3, TM.f(TP.POT))
            k.b(x, 0.08, 0.55, 0.205, 0.08, 0.06, 0.02, TM.f(TP.FN3))
        }
        p["copier"] = def(0.9, 0.65, 1.0, .wall) { k, x, _, _ in
            k.b(x, 0, 0, 0, 0.9, 0.85, 0.65, TM.f(TP.FN5)); k.b(x, 0, 0.85, 0, 0.9, 0.12, 0.65, TM.f(TP.FN4))
            k.b(x, 0.25, 0.97, 0.15, 0.3, 0.03, 0.2, TM.f(TP.FN6)); k.b(x, -0.1, 0.5, 0.33, 0.6, 0.06, 0.02, TM.f(TP.FN4))
        }
        // ── 10-20 第 4 棒：每個主題一件「識別色★大件」（評審：遮掉門牌後 5 層看起來一樣）。
        //   寬 2.0（樓層寬的 17%）、放在角色左前方（前帶）、正面朝鏡頭；整座台子是識別色＋正面上緣一條亮邊（不用發光材質，材質數不增加）。
        //   台面上放這個主題才有的東西（≤ 1.25 高，不擋到後面的人）
        @MainActor func hero(_ id: String, _ top: @escaping @MainActor (Kit, Xf, (CGFloat, CGFloat) -> SCNMaterial) -> Void) {
            p["hero_" + id] = def(2.0, 0.66, 1.25, .front) { k, x, a, ag in
                k.b(x, 0, 0, 0, 2.0, 0.8, 0.6, a)
                k.b(x, 0, 0.72, 0.31, 2.0, 0.04, 0.02, TM.f(TP.FN5))       // 正面上緣一條亮邊（不加發光材質，材質數不變）
                k.b(x, 0, 0.1, 0.305, 1.86, 0.6, 0.02, a)
                k.b(x, 0, 0.8, 0, 2.06, 0.04, 0.66, TM.f(TP.FN5))
                top(k, x.at(0, 0.84, 0), ag)
            }
        }
        // 發光只用場景裡本來就有的幾種（材質共用，不增加材質數）
        let scr = TM.glow(0x7FB8C8, 0.3, 0.9), led = TM.glow(TP.LT1, 0.2, 1.0), grn = TM.glow(0x6FD08C, 0.6, 1.5)
        hero("monitor") { k, x, _ in                     // 監控台：三連螢幕
            for i in -1...1 { k.b(x, Float(i) * 0.62, 0, -0.12, 0.58, 0.36, 0.04, TM.f(TP.FN6)); k.b(x, Float(i) * 0.62, 0.03, -0.095, 0.52, 0.3, 0.01, i == 0 ? grn : scr) }
        }
        hero("app_studio") { k, x, _ in                  // 程式碼大螢幕＋手機測試架
            k.b(x, -0.4, 0, -0.15, 1.05, 0.4, 0.04, TM.f(TP.FN6))
            for r in 0..<4 { k.b(x, -0.5 + Float(r % 2) * 0.1, 0.07 + Float(r) * 0.08, -0.125, 0.6 - Float(r % 3) * 0.12, 0.03, 0.01, r == 1 ? grn : scr) }
            k.b(x, 0.55, 0, 0, 0.75, 0.04, 0.3, TM.f(TP.FN3))
            for i in 0..<4 { k.b(x, 0.3 + Float(i) * 0.17, 0.04, 0.02, 0.1, 0.2, 0.02, TM.f(TP.FN6)); k.b(x, 0.3 + Float(i) * 0.17, 0.06, 0.035, 0.08, 0.16, 0.005, scr) }
        }
        hero("library") { k, x, _ in                     // 借還書台：書堆＋檯燈
            for (i, c) in [TP.FN5, TP.FN2, TP.FN4, TP.FN5].enumerated() { k.b(x, -0.7 + Float(i) * 0.22, 0, 0, 0.2, 0.18 + Float(i % 2) * 0.12, 0.28, TM.f(c)) }
            k.b(x, 0.6, 0, 0, 0.12, 0.03, 0.12, TM.f(TP.FN3)); k.b(x, 0.6, 0, 0, 0.03, 0.35, 0.03, TM.f(TP.FN3)); k.b(x, 0.6, 0.33, 0.05, 0.18, 0.08, 0.18, led)
        }
        hero("print_shop") { k, x, _ in                  // 大台 3D 印表機（透明罩）＋印好的件
            k.b(x, -0.35, 0, 0, 0.7, 0.4, 0.5, TM.f(TP.FN6)); k.b(x, -0.35, 0.04, 0.255, 0.6, 0.3, 0.01, TM.glass(0.3))
            k.b(x, -0.35, 0.05, 0, 0.18, 0.12, 0.18, TM.f(TP.FN5))
            for i in 0..<3 { k.b(x, 0.35 + Float(i) * 0.2, 0, 0.05, 0.14, 0.1 + Float(i) * 0.05, 0.14, TM.f(TP.WL1)) }
        }
        hero("call_room") { k, x, ag in                  // 總機台：來電燈號列＋耳機架
            k.b(x, -0.2, 0, -0.15, 1.3, 0.34, 0.06, TM.f(TP.FN6))
            for i in 0..<6 { for j in 0..<2 { k.b(x, -0.75 + Float(i) * 0.22, 0.07 + Float(j) * 0.14, -0.115, 0.12, 0.08, 0.01, (i + j) % 3 == 0 ? scr : led) } }
            for sx: Float in [0.62, 0.86] { k.b(x, sx, 0, 0.05, 0.03, 0.3, 0.03, TM.f(TP.FN3)); k.b(x, sx, 0.28, 0.05, 0.16, 0.05, 0.05, TM.f(TP.FN6)); k.b(x, sx - 0.07, 0.18, 0.05, 0.03, 0.12, 0.05, TM.f(TP.FN6)) }
        }
        hero("trading_desk") { k, x, _ in                // 交易台：雙螢幕＋行情條
            for i in 0..<2 { k.b(x, -0.45 + Float(i) * 0.7, 0, -0.12, 0.64, 0.36, 0.04, TM.f(TP.FN6)); k.b(x, -0.45 + Float(i) * 0.7, 0.03, -0.095, 0.58, 0.3, 0.01, grn) }
            k.b(x, 0, 0.38, -0.12, 1.5, 0.06, 0.03, led)
        }
        hero("media_studio") { k, x, ag in               // 主播台：ON AIR 燈箱＋麥克風
            k.b(x, -0.5, 0, -0.1, 0.6, 0.22, 0.08, led)
            k.b(x, 0.4, 0, 0, 0.1, 0.03, 0.1, TM.f(TP.FN3)); k.b(x, 0.4, 0, 0, 0.03, 0.3, 0.03, TM.f(TP.FN3)); k.b(x, 0.4, 0.28, 0.02, 0.07, 0.12, 0.07, TM.f(TP.FN6))
        }
        hero("design_studio") { k, x, _ in               // 色票樣品台
            let c: [UInt32] = [TP.FN5, TP.FN2, TP.FN1, TP.FN4, TP.PL2, TP.POT]
            for (i, h) in c.enumerated() { k.b(x, -0.75 + Float(i) * 0.3, 0, 0, 0.24, 0.04 + Float(i % 3) * 0.05, 0.3, TM.f(h)) }
        }
        hero("legal_room") { k, x, _ in                  // 文件堆＋天平
            for i in 0..<3 { k.b(x, -0.6 + Float(i) * 0.3, 0, 0, 0.26, 0.12 + Float(i) * 0.06, 0.34, TM.f(TP.FN5)) }
            k.b(x, 0.55, 0, 0, 0.04, 0.4, 0.04, TM.f(TP.FN2)); k.b(x, 0.55, 0.38, 0, 0.5, 0.03, 0.03, TM.f(TP.FN2))
            for sx: Float in [-0.22, 0.22] { k.b(x, 0.55 + sx, 0.22, 0, 0.14, 0.03, 0.14, TM.f(TP.FN2)) }
        }
        hero("ledger_room") { k, x, ag in                // 帳房櫃台：帳本＋算盤＋金幣
            k.b(x, -0.55, 0, 0, 0.5, 0.06, 0.34, TM.f(TP.FN1)); k.b(x, -0.55, 0.06, 0, 0.46, 0.05, 0.3, TM.f(TP.FN5))
            k.b(x, 0.1, 0, 0, 0.5, 0.04, 0.26, TM.f(TP.FN1)); for r in 0..<3 { k.b(x, 0.1, 0.04, -0.08 + Float(r) * 0.08, 0.46, 0.03, 0.02, TM.f(TP.FN6)) }
            for i in 0..<3 { k.b(x, 0.62 + Float(i) * 0.12, 0, 0, 0.1, 0.06 + Float(i) * 0.05, 0.1, TM.f(TP.FN2)) }
        }
        hero("game_lab") { k, x, _ in                    // 試玩台：電視＋手把
            k.b(x, -0.2, 0, -0.15, 1.1, 0.4, 0.05, TM.f(TP.FN6)); k.b(x, -0.2, 0.03, -0.12, 1.0, 0.33, 0.01, TM.glow(0xB18CFF, 0.3, 1.0))
            for sx: Float in [0.55, 0.8] { k.b(x, sx, 0, 0.12, 0.18, 0.05, 0.1, TM.f(TP.FN6)) }
        }
        hero("hw_lab") { k, x, _ in                      // 示波器＋電路板
            k.b(x, -0.45, 0, -0.05, 0.6, 0.38, 0.4, TM.f(TP.FN6)); k.b(x, -0.5, 0.06, 0.155, 0.4, 0.26, 0.01, grn)
            k.b(x, 0.4, 0, 0.05, 0.6, 0.03, 0.4, TM.f(TP.PL1)); for i in 0..<3 { k.b(x, 0.25 + Float(i) * 0.15, 0.03, 0.05, 0.08, 0.05, 0.08, TM.f(TP.FN6)) }
        }
        hero("marketing") { k, x, ag in                  // 產品陳列台：三盒產品＋標語燈箱
            for i in 0..<3 { k.b(x, -0.65 + Float(i) * 0.35, 0, 0, 0.28, 0.2 + Float(i) * 0.06, 0.28, TM.f(i == 1 ? TP.FN5 : TP.FN2)) }
            k.b(x, 0.55, 0, -0.1, 0.6, 0.3, 0.06, led)
        }
        hero("dispatch_room") { k, x, _ in               // 派車台：地圖螢幕＋無線電
            k.b(x, -0.35, 0, -0.15, 1.0, 0.4, 0.04, TM.f(TP.FN6))
            for r in 0..<3 { k.b(x, -0.55 + Float(r) * 0.2, 0.06 + Float(r) * 0.09, -0.125, 0.4, 0.03, 0.01, scr) }
            k.b(x, 0.55, 0, 0, 0.3, 0.16, 0.2, TM.f(TP.FN3)); k.b(x, 0.62, 0.16, 0, 0.03, 0.28, 0.03, TM.f(TP.FN3))
        }
        hero("drafting_room") { k, x, _ in               // 大圖桌：攤開的圖＋捲圖筒
            k.b(x, -0.3, 0, 0, 1.2, 0.01, 0.5, TM.f(TP.FN5))
            for r in 0..<3 { k.b(x, -0.3, 0.01, -0.15 + Float(r) * 0.15, 1.0 - Float(r % 2) * 0.4, 0.005, 0.02, TM.f(TP.FN3)) }
            for i in 0..<4 { k.b(x, 0.55 + Float(i % 2) * 0.12, 0, -0.1 + Float(i / 2) * 0.14, 0.09, 0.32 + Float(i) * 0.04, 0.09, TM.f(TP.FN5)) }
        }
        hero("general") { k, x, _ in                     // 接待台：文件＋小盆栽
            k.b(x, -0.5, 0, 0, 0.3, 0.08, 0.22, TM.f(TP.FN5))
            k.b(x, 0.5, 0, 0, 0.18, 0.15, 0.18, TM.f(TP.POT)); k.b(x, 0.5, 0.15, 0, 0.24, 0.2, 0.24, TM.f(TP.PL2))
        }
        return p
    }()

    /// 一件家具放哪：x、z（nil＝貼後牆）、y（nil＝家具預設離地高）、a（繞 Y 轉）
    struct Slot { var id: String; var x: Float; var z: Float?; var y: Float? = nil; var a: Float = 0 }
    static func S(_ id: String, _ x: Float, _ z: Float? = nil, y: Float? = nil, a: Float = 0) -> Slot { Slot(id: id, x: x, z: z, y: y, a: a) }

    /// 主題擺設表（10-20 UI/UX 優化 §3.3；座標是模組本地，x 協作區 −5.3…−2.3、工作區 −2.3…2.5、休憩角 2.5…5.3；z 前帶 1.1…2.8 只放 ≤0.9 高的）。
    /// 排在前面的優先（★ 識別色那件在前）。跟 §3.3 表格不同的地方：兩座書櫃／兩台印表機的家具本來就是一組 3 格／2 台，只放一組；
    /// 會互相撞到的照撞的結果微調了 x（例：時鐘移到伺服器機櫃上方、新聞電視移到咖啡車左邊）
    static func layout(_ t: TowerTheme) -> [Slot] {
        [S("hero_\(t.rawValue)", -3.6, 2.2)] + themeLayout(t)
    }
    static func themeLayout(_ t: TowerTheme) -> [Slot] {
        switch t {
        case .monitor: [S("status_beacon", 2.8), S("video_wall", 0.1), S("server_rack", -4.9), S("server_rack", -4.2), S("console1", -3.6, -1.4),
                        S("wall_clock", -5.15, y: 2.05), S("wall_clock", -4.55, y: 2.05), S("wall_clock", -3.95, y: 2.05), S("bench", -4.2, 2.3)]
        case .app_studio: [S("beanbag", -1.0, 2.2), S("phone_wall", -3.8, y: 0.9), S("standing_desk", -3.8, -1.2), S("whiteboard", 0.1),
                           S("device_cart", -1.9, -2.3), S("charging_shelf", 2.9)]
        case .library: [S("reading_chair", -4.6, 2.0), S("bookshelf", -3.85), S("long_table", -3.8, -0.9), S("card_catalog", -1.6),
                        S("whiteboard", 0.6), S("globe", -3.2, 0.75)]
        case .print_shop: [S("parts_bin", 2.8), S("printer", -4.55), S("workbench", -2.75), S("filament_rack", -0.6), S("finished_shelf", 1.0),
                           S("box_stack", -4.4, 2.3)]
        case .call_room: [S("phone_booth", -4.7, -2.15), S("switchboard", -3.3), S("tablet_stand", -1.6, -2.4), S("tablet_stand", -1.0, -2.4),
                          S("mail_rack", 0.8, y: 1.3), S("sofa", -3.6, 2.2, a: .pi), S("side_table", -2.2, 2.3)]
        case .trading_desk: [S("ticker_wall", 0.1), S("safe", -4.9), S("bull_statue", -3.7), S("quad_monitor", 0), S("news_tv", 3.0), S("bench", -4.0, 2.3)]
        case .media_studio: [S("backdrop", -3.8), S("softbox", -5.0, -1.0), S("softbox", -2.7, -1.0), S("camera_tripod", -3.8, 0.3),
                             S("edit_bay", 0.8), S("equipment_case", -2.6, 2.2)]
        case .design_studio: [S("pendant_dome", 0.1, 0.5, y: TD.clear - 0.85), S("drafting_table", -3.8, -1.2), S("easel", -5.0), S("moodboard", 0.1),
                              S("material_shelf", -2.0), S("sample_table", -3.6, 2.2)]
        case .legal_room: [S("document_safe", 2.8), S("conference_table", -3.8, -1.0), S("law_shelf", 0.4), S("file_cabinet", -1.5), S("seal_desk", -5.0)]
        case .ledger_room: [S("brass_safe", 2.8), S("ledger_cabinet", -4.0), S("cashier_counter", -3.8, -0.9), S("ledger_shelf", 0.1),
                            S("receipt_tray", 0), S("wall_clock", -1.2, y: 2.0)]
        case .game_lab: [S("arcade", -5.0), S("arcade_n", -4.2), S("sprite_wall", 0.6), S("trophy_shelf", -1.2), S("playtest_tv", -2.8),
                         S("sofa", -2.8, 1.9, a: .pi), S("controller_shelf", -4.6, 2.3)]
        case .hw_lab: [S("speaker_tower", 2.8), S("esd_bench", -3.8, -1.0), S("soldering_station", 0), S("test_rig", -5.0), S("parts_wall", 0.1),
                       S("cable_reel", -1.6), S("scope_cart", -2.6, 2.2)]
        case .marketing: [S("content_wall", 0.1), S("product_table", -3.8, -1.0), S("ring_light", -5.0, -1.0), S("sofa", -3.6, 2.2, a: .pi), S("poster_stand", 2.8)]
        case .dispatch_room: [S("route_map", 0.1), S("radio_desk", -3.8, -1.4), S("key_cabinet", -5.0, y: 1.0), S("flight_board", -2.6, y: 1.3),
                              S("car_model", 0), S("luggage", -4.4, 2.3)]
        case .drafting_room: [S("plan_table", -3.8, -1.0), S("plan_chest", -4.55), S("section_wall", 0.1), S("model_plinth", -1.6), S("roll_bin", -2.6, 2.3)]
        case .general: [S("whiteboard", 0.1), S("meeting_table", -3.8, -0.9), S("bookshelf", -3.85)]
        }
    }

    /// 每層都放的生活感組（§3.2），依優先序；整層家具（主題＋AI 擺設＋這組）最多 16 件，放滿就停。
    /// 10-20 第 4 棒：評審「右側休息區每層一模一樣」⇒ 三種休息區輪流（樓層號 mod 3：咖啡角／沙發＋飲水機／小會議桌＋影印機），相鄰兩層一定不同；
    /// 每種都至少 3 件放前帶（≤0.95 高）
    static func common(_ variant: Int) -> [Slot] {
        let shared = [S("trash_bin", 99, 0), S("coat_rack", -5.0, TD.backZ + 0.35), S("plant_low", -5.6, 2.4)]
        switch ((variant % 3) + 3) % 3 {
        case 1:
            return [S("water_cooler", 4.4), S("copier", 3.1), S("sofa", 4.0, 2.1), S("side_table", 5.5, 2.2), S("news_tv", 4.4, y: 1.5),
                    S("plant_tall", 5.0, 0.6), S("box_stack", 2.0, 2.3)] + shared
        case 2:
            return [S("coffee_cart", 3.2), S("meeting_table", 4.15, -0.5), S("bench", 4.1, 2.3), S("plant_tall", 4.85), S("wall_clock", 4.6, y: 2.0),
                    S("floor_lamp", 5.6, 1.0), S("box_stack", 2.4, 2.35)] + shared
        default:
            return [S("coffee_cart", 3.9), S("lounge_chair", 3.3, 1.9), S("plant_tall", 4.85), S("side_table", 4.0, 2.05), S("wall_clock", 3.9, y: 1.98),
                    S("floor_lamp", 5.5, 1.0), S("lounge_chair", 4.7, 1.9)] + shared
        }
    }
    static let maxItems = 12      // 10-22 Kang：16 件太滿；加深後空間大，少一點才有呼吸感
}

// MARK: - 擺放（AABB 不重疊；放不下的丟掉）

struct PropBox { var x0, x1, y0, y1, z0, z1: Float
    func hits(_ o: PropBox) -> Bool { x0 < o.x1 && o.x0 < x1 && y0 < o.y1 && o.y0 < y1 && z0 < o.z1 && o.z0 < z1 }
}

@MainActor
enum PropPlacer {
    /// AI 挑的、不在主題表裡的擺設：照列找空位（中心 z）
    static func rowZ(_ d: PropDef) -> Float {
        switch d.row {
        case .wall, .high: TD.backZ + d.d / 2 + 0.02
        case .mid: -1.6
        case .front: 2.3
        case .ceiling: 0.5
        case .onDesk, .onBench: 0
        }
    }

    struct Result { var items: [(String, Xf)] = []; var front = 0; var dropped: [String] = []; var ghostSpots: [SIMD2<Float>] = [] }

    /// 影分身站位（10-22 Kang：「像幽靈半透明的娃娃站在窗台邊、有一點穿圖」——原本固定站 x −4.8 起、z 2.3，剛好疊在每層★大件 (−3.6, 2.2) 上）：
    /// 前帶從左到右找沒被家具／座位帶佔走的 0.7×0.7 空地（站著的 Kubo 寬約 0.6），最多 4 格
    static func ghostSpots(_ taken: [PropBox]) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = [], used = taken
        for z: Float in [2.2, 1.85] {
            var x: Float = -4.9
            while x <= 4.9 && out.count < 4 {
                let b = PropBox(x0: x - 0.35, x1: x + 0.35, y0: 0, y1: 1.6, z0: z - 0.35, z1: z + 0.35)
                if used.contains(where: { $0.hits(b) }) { x += 0.2; continue }
                used.append(b); out.append(SIMD2(x, z)); x += 0.85
            }
        }
        return out
    }

    /// 主題表 → AI 擺設 → 生活感組（最多 16 件）。`desks`＝每張桌子中心＋人面向角 a；`mirror`＝樓層號奇數時協作區左右鏡射（同主題相鄰兩層不要一模一樣，§4.4）
    static func place(theme: TowerTheme, props: [String], desks: [(Float, Float, Float)], mirror: Bool, lounge: Int = 0, log: (String) -> Void) -> Result {
        var taken: [PropBox] = []
        // 電梯門口、溜滑梯門口：不放家具
        for e in TD.elevs { taken.append(PropBox(x0: -6.2, x1: -5.25, y0: 0, y1: 2.3, z0: e.y - 0.65, z1: e.y + 0.65)) }   // 兩部電梯門口（10-22）
        taken.append(PropBox(x0: 5.3, x1: 6.2, y0: 0, y1: 2.3, z0: TD.zB - 0.1, z1: TD.zB + 0.7))
        // 座位帶（桌椅＋坐著的人）：本地框 x ±0.75、z 往人那側 chairBack+0.45、另一側 0.4，依桌子朝向轉（側向時 x/z 對調）
        for (x, z, a) in desks {
            let t = Xf(x: x, y: 0, z: z, a: a), back = Float(TowerLayout.chairBack) + 0.45
            let c = [(-0.75, -back), (0.75, -back), (-0.75, 0.4), (0.75, 0.4)].map { t.apply(SIMD3($0.0, 0, $0.1)) }
            taken.append(PropBox(x0: c.map(\.x).min()!, x1: c.map(\.x).max()!, y0: 0, y1: 1.7, z0: c.map(\.z).min()!, z1: c.map(\.z).max()!))
        }
        var r = Result()
        var benchAt: Xf?
        let lo = -TD.W / 2 + 0.15, hi = TD.W / 2 - 0.15
        func box(_ d: PropDef, _ x: Float, _ z: Float, _ y0: Float, _ a: Float) -> PropBox {
            let side = abs(sin(a)) > 0.5
            let w = side ? d.d : d.w, dd = side ? d.w : d.d
            return PropBox(x0: x - w / 2, x1: x + w / 2, y0: y0, y1: y0 + d.h, z0: z - dd / 2, z1: z + dd / 2)
        }
        @discardableResult
        func put(_ s: TowerProps.Slot, auto: Bool = false) -> Bool {
            guard r.items.count < TowerProps.maxItems || [.onDesk, .onBench].contains(TowerProps.all[s.id]?.row) else { return false }
            guard let d = TowerProps.all[s.id] else { log("unknown prop \(s.id)"); return false }
            switch d.row {
            case .onDesk:
                guard let (x, z, a) = desks.first else { r.dropped.append(s.id); log("drop \(s.id)（沒有桌子）"); return false }
                r.items.append((s.id, Xf(x: x, y: 0.75, z: z, a: a).at(-0.35, 0, -0.05))); return true
            case .onBench:
                guard let b = benchAt else { r.dropped.append(s.id); log("drop \(s.id)（沒有工作台）"); return false }
                r.items.append((s.id, b.at(0.55, 0.75, 0))); return true
            default: break
            }
            var xs: [Float] = [s.x]
            if auto { xs += [-4.0, -1.0, 2.0, -3.0, 1.0, -2.0, 3.0, 0, 4.0] }
            // 前帶的矮東西被★大件佔走位置：往右挪到角色前面再試（前帶只放 ≤0.95 高，不擋人）
            else if (s.z ?? 0) > 1.1 { xs += [s.x + 2.6, s.x + 3.6] }
            for x0 in xs {
                var x = x0
                if mirror && !auto && x < -2.3 { x = -7.6 - x }
                let z = s.z ?? TD.backZ + d.d / 2 + 0.02
                let y0 = s.y ?? d.y0
                let half = abs(sin(s.a)) > 0.5 ? d.d / 2 : d.w / 2
                x = min(max(x, lo + half), hi - half)
                let b = box(d, x, z, y0, s.a)
                // 前帶（z > 1.1）只放矮的（≤ 0.95，不擋人）
                //（★大件例外：它在角色左前方的協作區，不在任何人前面；高 1.25 以內）
                if b.z1 > 1.1 + 0.05 && z > 1.1 && b.y1 > 0.95 && !s.id.hasPrefix("hero_") { continue }
                if taken.contains(where: { $0.hits(b) }) { continue }
                taken.append(b)
                if s.id == "esd_bench" { benchAt = Xf(x: x, y: 0, z: z) }
                r.items.append((s.id, Xf(x: x, y: y0, z: z, a: s.a)))
                if z > 1.1 { r.front += 1 }
                return true
            }
            r.dropped.append(s.id); log("drop \(s.id)（放不下）")
            return false
        }
        let table = TowerProps.layout(theme)
        for s in table { put(s) }
        for id in props where !table.contains(where: { $0.id == id }) && TowerProps.all[id] != nil {
            let d = TowerProps.all[id]!
            put(TowerProps.Slot(id: id, x: -4.0, z: rowZ(d)), auto: true)
        }
        // 垃圾桶：第一張桌子旁邊（依朝向的右側 0.95）
        for s in TowerProps.common(lounge) {
            if s.id == "trash_bin" {
                guard let (x, z, a) = desks.first else { continue }
                let p = Xf(x: x, y: 0, z: z, a: a).apply(SIMD3(0.95, 0, -0.1))
                put(TowerProps.Slot(id: s.id, x: p.x, z: p.z, a: a))
            } else { put(s) }
        }
        r.ghostSpots = ghostSpots(taken)
        return r
    }
}


// MARK: - 文字牌（門牌：霧白底、深字、左側識別色條；PingFang TC Medium、字距 +4%）

@MainActor
enum TowerSign {
    /// 夜晚門牌不要比牆亮（不受光，乘一個暖灰）：記下所有門牌材質，切日夜時一起改
    private static var plates: [Weak] = []
    private final class Weak { weak var m: SCNMaterial?; init(_ m: SCNMaterial) { self.m = m } }
    static func setNight(_ n: Bool) { setDark(n ? 1 : 0) }
    /// 10-21 日出日落：乘色依暗度從白混到暖灰
    static func setDark(_ d: CGFloat) {
        plates.removeAll { $0.m == nil }
        let c = multiply(d)
        for p in plates { p.m?.multiply.contents = c }
    }
    static func multiply(_ d: CGFloat) -> NSColor { VoxMat.mix(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), VoxMat.color(0xC9C4BA), d) }

    static func image(_ s: String, accent: NSColor?, size: CGFloat = 44, dark: Bool = false) -> NSImage {
        let font = NSFont(name: "PingFang TC Medium", size: size) ?? .systemFont(ofSize: size, weight: .medium)
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dark ? VoxMat.color(0xEDEBE6) : VoxMat.color(TP.INK), .kern: size * 0.04]
        let ts = (s as NSString).size(withAttributes: a)
        let padX = size * 0.6, padY = size * 0.3, sw: CGFloat = accent == nil ? 0 : size * 0.28
        let W = ceil(ts.width + padX * 2 + sw), H = ceil(ts.height + padY * 2)
        return NSImage(size: NSSize(width: W, height: H), flipped: false) { r in
            (dark ? VoxMat.color(0x3A3E44) : VoxMat.color(TP.FN5)).setFill(); r.fill()
            if let accent { accent.setFill(); NSRect(x: 0, y: 0, width: sw, height: H).fill() }
            (s as NSString).draw(at: NSPoint(x: sw + padX, y: padY), withAttributes: a)
            return true
        }
    }

    static func material(_ img: CGImage?) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = img; m.lightingModel = .constant
        m.diffuse.mipFilter = .linear; m.diffuse.minificationFilter = .linear
        if VoxMat.dark > 0 { m.multiply.contents = multiply(VoxMat.dark) }
        plates.append(Weak(m))
        return m
    }

    /// 一塊門牌：高 `height` 公尺、寬照字數；原點在左緣中心（貼牆時往右長）
    static func plate(_ s: String, accent: NSColor?, height: CGFloat, maxWidth: CGFloat = 99) -> (SCNNode, CGFloat) {
        let img = image(s, accent: accent)
        var h = height, w = height * img.size.width / img.size.height
        if w > maxWidth { h *= maxWidth / w; w = maxWidth }
        let pl = SCNPlane(width: w, height: h)
        pl.firstMaterial = material(OfficeBuilder.raster(img, scale: 2))
        let inner = SCNNode(geometry: pl); inner.position.x = w / 2
        let n = SCNNode(); n.addChildNode(inner); n.name = "plate"
        return (n, w)
    }

}

// MARK: - 樓層模組

/// 會被 cutaway 淡掉的一面（外法線 n 在 XZ 平面）
struct Facade {
    var node: SCNNode
    var n: SIMD2<Float>
    /// 透明的面（玻璃牆、玻璃門、玻璃欄杆、電梯井玻璃）：不擋視線 ⇒ 鏡頭怎麼轉都不藏（10-25 Kang）
    var glass: Bool
    /// 內積超過這個才藏（牆 0.25＝斜 45° 兩面都藏；溜滑梯 0.5＝從右後方看才藏）
    var cut: Float = 0.25
}

/// 模組建好的結果：根節點（放在樓層 y）、四面牆、門牌（可換牆）、門牌寬
@MainActor
struct ModuleParts {
    var node = SCNNode()
    var facades: [Facade] = []
    var plate: SCNNode?
    var plateW: CGFloat = 0
    var plateY: CGFloat = 0
    var plateWalls: Set<Int> = [0, 1, 2, 3]       // 門牌可以搬去的牆（0 後、1 前、2 左、3 右）
    var outsidePlate = false                       // 閒置薄層：門牌貼在外面（朝鏡頭那一面）
    var boxes = 0
    var items = 0                                  // 家具件數（不含桌椅、桌面小物）
    var front = 0                                  // 其中放在前帶的
    var deskItems = 0                              // 桌面小物
    var ghostSpots: [SIMD2<Float>] = []            // 影分身站位（PropPlacer 找的空地，模組本地座標）
}

@MainActor
enum TowerModules {
    /// 四面牆（外法線）：後（−z）、前（+z）、左（−x）、右（+x）
    static let normals: [SIMD2<Float>] = [SIMD2(0, -1), SIMD2(0, 1), SIMD2(-1, 0), SIMD2(1, 0)]

    /// 一面牆＝一個節點（一種材質）：沿著牆排方塊，`gaps`＝門洞（沿牆方向的區間、高）
    /// `extra`＝跟著這面牆一起藏的東西（門框；10-20 第 4 棒：原本在靜態 mesh，牆藏起來後門框浮在半空）
    static func wall(_ side: Int, h: Float, mat: SCNMaterial, y0: Float = TD.room, gaps: [(Float, Float, Float)] = [], name: String,
                     extra: (Kit) -> Void = { _ in }) -> SCNNode {
        let m = VoxelMesh()
        extra(Kit(m: m))
        let t: Float = 0.15
        let len: Float = side < 2 ? TD.W : TD.D
        var cuts: [(Float, Float)] = side < 2 ? [(-len / 2, len / 2)] : [(TD.zB, TD.zF)]   // 側牆沿 z：模組前緣固定、往後加深（10-22）
        for g in gaps {
            cuts = cuts.flatMap { c -> [(Float, Float)] in
                if g.1 <= c.0 || g.0 >= c.1 { return [c] }
                return [(c.0, g.0), (g.1, c.1)].filter { $0.1 - $0.0 > 0.01 }
            }
        }
        func put(_ a: Float, _ b: Float, _ y: Float, _ hh: Float) {
            let c = (a + b) / 2, l = b - a
            switch side {
            case 0: m.box(.identity, SIMD3(c, y + hh / 2, TD.zB + t / 2), SIMD3(l, hh, t), mat)
            case 1: m.box(.identity, SIMD3(c, y + hh / 2, TD.zF - t / 2), SIMD3(l, hh, t), mat)
            case 2: m.box(.identity, SIMD3(-TD.W / 2 + t / 2, y + hh / 2, c), SIMD3(t, hh, l), mat)
            default: m.box(.identity, SIMD3(TD.W / 2 - t / 2, y + hh / 2, c), SIMD3(t, hh, l), mat)
            }
        }
        for c in cuts { put(c.0, c.1, y0, h) }
        for g in gaps where g.2 < h { put(g.0, g.1, y0 + g.2, h - g.2) }      // 門楣
        return m.node(name: name)
    }

    /// 正面＝玻璃＋直框（每 2 公尺一支）＝一個 cutaway 節點
    static func glassFront(h: Float, y0: Float = TD.room, alpha: CGFloat = 0.15, mullionsAt: [Float] = (0...6).map { -6 + Float($0) * 2 },
                           door: (x0: Float, x1: Float, h: Float)? = nil, extra: (Kit) -> Void = { _ in }) -> SCNNode {
        let m = VoxelMesh(), k = Kit(m: m)
        if let d = door {   // 門洞那段不放固定玻璃（只留門上的氣窗），滑門另外掛（frontDoor）
            let L = TD.W / 2
            m.box(.identity, SIMD3((-L + d.x0) / 2, y0 + h / 2, TD.zF - 0.02), SIMD3(d.x0 + L, h, 0.02), TM.glass(alpha))
            m.box(.identity, SIMD3((d.x1 + L) / 2, y0 + h / 2, TD.zF - 0.02), SIMD3(L - d.x1, h, 0.02), TM.glass(alpha))
            m.box(.identity, SIMD3((d.x0 + d.x1) / 2, y0 + d.h + (h - d.h) / 2, TD.zF - 0.02), SIMD3(d.x1 - d.x0, h - d.h, 0.02), TM.glass(alpha))
        } else {
            m.box(.identity, SIMD3(0, y0 + h / 2, TD.zF - 0.02), SIMD3(TD.W, h, 0.02), TM.glass(alpha))
        }
        for x in mullionsAt { k.b(.identity, x, y0, TD.zF - 0.03, 0.05, h, 0.05, TM.f(TP.ST1)) }
        extra(k)
        return m.node(name: "front")
    }

    /// 樓板＋地坪＋前緣霓虹＋後側轉角細框
    static func shell(_ k: Kit, floorColor: UInt32, h: Float, neon: Bool = true) {
        k.b(.identity, 0, 0, TD.zC, TD.W, TD.slab, TD.D, TM.slab)
        k.b(.identity, 0, TD.slab, TD.zC, TD.W - 0.02, 0.01, TD.D - 0.02, TM.f(floorColor))
        if neon { k.b(.identity, 0, TD.slab - 0.02, TD.zF + 0.011, TD.W, 0.02, 0.02, TM.glow(TP.NE1, 0, 0.9)) }
        let st = TM.f(TP.ST1)
        for x: Float in [-TD.W / 2, TD.W / 2] { k.b(.identity, x, TD.room, TD.zB + 0.03, 0.05, h, 0.05, st) }
    }

    /// 線性吊燈（座位帶正上方，離天花 0.45）；off＝這層沒人（2 小時緩衝），燈不亮
    static func pendant(_ k: Kit, x: Float, z: Float, len: Float, ceil: Float, off: Bool) {
        let drop: Float = 0.45
        for dx in [-len / 2 + 0.3, len / 2 - 0.3] { k.b(.identity, x + dx, ceil - drop + 0.06, z, 0.02, drop - 0.06, 0.02, TM.f(TP.FN3)) }
        k.b(.identity, x, ceil - drop, z, len, 0.06, 0.12, TM.f(TP.FN3))
        k.b(.identity, x, ceil - drop - 0.02, z, len - 0.1, 0.02, 0.08, off ? TM.f(TP.FN5) : TM.glow(TP.LT1, 0, 1.4))
    }

    /// 一張標準座位：桌面 1.4×0.7 頂高 0.75、螢幕朝人、椅子在桌子後方 chairBack（角色放大 1.6 倍，椅面 0.56）。
    /// 本地座標原點在桌心、螢幕在 +z；a＝人面向角（10-22 自由座，見 TowerLayout.freeDesks），整組照 a 旋轉
    static func desk(_ k: Kit, x: Float, z: Float, a: Float = 0) {
        let t = Xf(x: x, y: TD.room, z: z, a: a)
        k.b(t, 0, 0.70, 0, 1.4, 0.05, 0.7, TM.f(TP.FN2))
        for (dx, dz) in [(-0.64, -0.3), (0.64, -0.3), (-0.64, 0.3), (0.64, 0.3)] as [(Float, Float)] { k.b(t, dx, 0, dz, 0.05, 0.7, 0.05, TM.f(TP.FN3)) }
        k.b(t, 0, 0.76, 0.2, 0.62, 0.20, 0.04, TM.f(TP.FN6))
        k.b(t, 0, 0.75, 0.24, 0.12, 0.05, 0.12, TM.f(TP.FN6))
        let cz = -Float(TowerLayout.chairBack), seat = Float(TowerSpec.seatTop)
        k.b(t, 0, seat - 0.08, cz, 0.55, 0.08, 0.55, TM.f(TP.FN4))
        k.b(t, 0, 0, cz, 0.06, seat - 0.08, 0.06, TM.f(TP.FN3))
        k.b(t, 0, seat, cz - 0.3, 0.55, 0.55, 0.06, TM.f(TP.FN4))
    }

    /// 桌面小物（§3.2）：依「專案名＋桌號」挑 2 件，放桌面左右（馬克杯、文件堆、小盆栽、檯燈、耳機、第二螢幕）；跟桌子一起照 a 旋轉
    static func deskItems(_ k: Kit, x: Float, z: Float, a: Float = 0, seed: String) -> Int {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let t = Xf(x: x, y: TD.room + 0.75, z: z, a: a), y: Float = 0   // 桌面本地座標（原點桌心、y 0＝桌面）
        let n = 2                                           // 10-20 第 4 棒：每張桌子都 2 件（評審：桌上沒有生活物件）
        for i in 0..<n {
            let kind = Int((h >> UInt64(8 + i * 5)) % 6)
            let sx: Float = i == 0 ? -0.48 : 0.48, cz: Float = -0.08
            switch kind {
            case 0: k.b(t, sx, y, cz, 0.09, 0.11, 0.09, TM.f(TP.FN5))                          // 馬克杯
            case 1: k.b(t, sx, y, cz, 0.3, 0.06, 0.22, TM.f(TP.FN5)); k.b(t, sx + 0.02, y + 0.06, cz, 0.28, 0.02, 0.2, TM.f(TP.FN4))   // 文件堆
            case 2: k.b(t, sx, y, cz, 0.14, 0.12, 0.14, TM.f(TP.POT)); k.b(t, sx, y + 0.12, cz, 0.16, 0.14, 0.16, TM.f(TP.PL2))  // 小盆栽
            case 3:                                                                                                  // 檯燈
                k.b(t, sx, y, cz, 0.12, 0.03, 0.12, TM.f(TP.FN3)); k.b(t, sx, y + 0.03, cz, 0.03, 0.35, 0.03, TM.f(TP.FN3))
                k.b(t, sx, y + 0.36, cz + 0.04, 0.14, 0.08, 0.14, TM.glow(TP.LT1, 0, 0.8))
            case 4: k.b(t, sx, y, cz, 0.16, 0.06, 0.1, TM.f(TP.FN3))                         // 耳機
            default:                                                                                                 // 第二螢幕（直立）
                k.b(t, sx, y, 0.18, 0.1, 0.12, 0.1, TM.f(TP.FN3)); k.b(t, sx, y + 0.1, 0.2, 0.22, 0.36, 0.03, TM.f(TP.FN6))
            }
        }
        return n
    }

    /// 每張桌子的桌心＋人面向角 a（12 張以內）
    static func deskCenters(_ seats: Int, floor: String) -> [(Float, Float, Float)] {
        (0..<min(seats, 12)).map { i in
            let d = TowerLayout.desk(i, of: min(seats, 12), floor: floor)
            return (Float(d.x), Float(d.z), Float(d.a))
        }
    }

    // MARK: 專案樓層（12×5.6×2.9；10-20 UI/UX 優化 §3）

    static func project(_ f: TowerFloor, decor: FloorDecor?, log: (String) -> Void) -> ModuleParts {
        var p = ModuleParts()
        let m = VoxelMesh(), k = Kit(m: m)
        let h = TD.clear
        shell(k, floorColor: TP.FL1, h: h)
        // 四面牆：左牆開兩部電梯門（z −1.75…−0.85、−3.35…−2.45）、後牆右端開往溜滑梯的門（x 5.35…5.95）
        let theme = decor?.theme ?? .general
        // 識別色一律鎖主題預設色（10-20 §4.3）
        let accentHex = TP.hex(theme.accent) ?? TP.FN4
        let accent = TM.f(accentHex)
        p.facades = [
            // 10-20 第 4 棒：後牆協作區那一段（3 公尺）刷主題識別色：遮掉門牌也認得出是哪個主題（跟著後牆一起藏）
            Facade(node: wall(0, h: h, mat: TM.backWall, gaps: [(5.35, 5.95, 2.1)], name: "back") { wk in
                wk.b(.identity, -3.8, TD.room, TD.backZ + 0.012, 3.0, h, 0.02, accent)
                // 往溜滑梯的門：識別色門框（評審：電梯門、溜滑梯入口在截圖裡看不出來；用同一個材質，不加 draw call）
                for x: Float in [5.3, 6.0] { wk.b(.identity, x, TD.room, TD.backZ + 0.02, 0.1, 2.2, 0.04, accent) }
                wk.b(.identity, 5.65, TD.room + 2.1, TD.backZ + 0.02, 0.8, 0.1, 0.04, accent)
            }, n: normals[0], glass: false),
            Facade(node: glassFront(h: h), n: normals[1], glass: true),
            Facade(node: wall(2, h: h, mat: TM.f(TP.WL2), gaps: TD.elevs.indices.map { TD.elevGap($0, h: 2.1) }, name: "left") { wk in
                // 電梯門：石墨鋼門框＋門楣（兩部同一個材質，每層仍只多 1 個 draw call）
                for e in TD.elevs {
                    for z: Float in [e.y - 0.5, e.y + 0.5] { wk.b(.identity, -TD.W / 2 + 0.17, TD.room, z, 0.06, 2.2, 0.1, TM.f(TP.ST1)) }
                    wk.b(.identity, -TD.W / 2 + 0.17, TD.room + 2.1, e.y, 0.06, 0.12, 1.1, TM.f(TP.ST1))
                }
            }, n: normals[2], glass: false),
            Facade(node: wall(3, h: h, mat: TM.f(TP.WL2), name: "right"), n: normals[3], glass: false),
        ]
        let ag: (CGFloat, CGFloat) -> SCNMaterial = { TM.glow(accentHex, $0, $1) }
        // 吊燈：前組四人桌上方一條；後組有人坐（2 人以上，第 2 個人就坐後段）再加一條
        pendant(k, x: 0.1, z: 0.05, len: 3.2, ceil: TD.room + h, off: !f.active)
        if f.seats > 0 { pendant(k, x: -0.7, z: -3.95, len: 3.2, ceil: TD.room + h, off: !f.active) }
        // 桌子＝實際 AI 數（13 個以上的站前帶，不加桌子）
        let desks = deskCenters(f.seats, floor: f.id)
        for (i, (x, z, a)) in desks.enumerated() {
            desk(k, x: x, z: z, a: a)
            p.deskItems += deskItems(k, x: x, z: z, a: a, seed: "\(f.project ?? "")#\(i)")
        }
        // 10-20 第 4 棒：人少的樓層補空桌（椅子靠進去、螢幕關著）：像一間辦公室，不是房間正中間一張桌子。
        // 10-22 自由座：只補 1 張空桌（Kang：補滿四張看起來滿滿的）
        let spare: [(Float, Float, Float)] = (f.seats < 4 ? [f.seats] : []).map { i in
            let d = TowerLayout.desk(i, of: 4, floor: f.id)
            return (Float(d.x), Float(d.z), Float(d.a))
        }
        for (j, (x, z, a)) in spare.enumerated() {
            desk(k, x: x, z: z, a: a)
            p.deskItems += deskItems(k, x: x, z: z, a: a, seed: "\(f.project ?? "")#spare\(j)")
        }
        // 10-20 UI/UX 優化：樓層名改在左側索引列＋拉近時的螢幕標籤（3D 門牌在預設鏡頭只有 6 pt，讀不到），專案樓層不再畫 3D 門牌
        let r = PropPlacer.place(theme: theme, props: decor?.props ?? [], desks: desks + spare, mirror: (f.number ?? 0) % 2 == 1, lounge: f.number ?? 0, log: log)
        for (id, xf) in r.items {
            guard let d = TowerProps.all[id] else { continue }
            var xf2 = xf; xf2.y += TD.room
            d.build(k, xf2, accent, ag)
        }
        p.items = r.items.count; p.front = r.front; p.ghostSpots = r.ghostSpots
        p.boxes = m.boxes
        p.node.addChildNode(m.node(name: "static"))
        for f in p.facades { p.node.addChildNode(f.node) }
        return p
    }

    // MARK: 閒置薄層（只 1 層、高 0.9）：空的薄層（名字在左側索引列）

    static func idle(_ f: TowerFloor) -> ModuleParts {
        var p = ModuleParts()
        let m = VoxelMesh(), k = Kit(m: m)
        let h = Float(TowerSpec.idleHeight) - TD.slab
        k.b(.identity, 0, 0, TD.zC, TD.W, TD.slab, TD.D, TM.slab)
        k.b(.identity, 0, TD.slab, TD.zC, TD.W - 0.02, 0.01, TD.D - 0.02, TM.f(TP.FL2))
        for x: Float in [-TD.W / 2 + 0.075, TD.W / 2 - 0.075] { k.b(.identity, x, TD.room, TD.zC, 0.15, h, TD.D, TM.f(TP.WL2)) }
        p.facades = [Facade(node: wall(0, h: h, mat: TM.f(TP.WL2), name: "back"), n: normals[0], glass: false)]
        // 10-20 第 4 棒：3D 大門牌拿掉（預設鏡頭下斜貼、7–8 pt 糊掉）⇒ 改成螢幕空間樓層名「閒置 N 個專案・名字在左側清單」（OfficeLabels）
        p.boxes = m.boxes
        p.node.addChildNode(m.node(name: "static"))
        p.node.addChildNode(storefront(y0: 0, h: Float(TowerSpec.idleHeight)))
        for f in p.facades { p.node.addChildNode(f.node) }
        return p
    }

    // MARK: 一樓大廳＋前台保全（12×5.6×3.6）

    static func lobby(sign: Bool = false) -> ModuleParts {
        var p = ModuleParts()
        let m = VoxelMesh(), k = Kit(m: m)
        let h = Float(TowerSpec.lobbyHeight) - TD.slab, r = TD.room
        shell(k, floorColor: TP.FL2, h: h, neon: true)
        // 正面（10-25 Kang）：大門搬到 Okle42 招牌正下方（x 0），原本右邊 x 3.8 的門拿掉；
        // 兩側改成整片純透明大玻璃（中間的直框全拿掉，只留兩端轉角），只有門框＋門楣
        let dx = SlideDoor.front.w + 0.04, x0 = TowerCore.frontX
        let front = glassFront(h: h, alpha: 0.1, mullionsAt: [-TD.W / 2, TD.W / 2], door: (x0 - dx, x0 + dx, 2.4)) { fk in
            for s: Float in [-1, 1] { fk.b(.identity, x0 + s * dx, r, TD.zF - 0.05, 0.08, 2.4, 0.08, TM.f(TP.ST1)) }
            fk.b(.identity, x0, r + 2.4, TD.zF - 0.05, 2 * dx + 0.08, 0.08, 0.08, TM.f(TP.ST1))
        }
        p.facades = [
            Facade(node: wall(0, h: h, mat: TM.backWall, name: "back") { wk in cafeBricks(wk, h: h) }, n: normals[0], glass: false),
            Facade(node: front, n: normals[1], glass: true),
            Facade(node: wall(2, h: h, mat: TM.f(TP.WL2), gaps: TD.elevs.map { ($0.y - 0.5, $0.y + 0.5, 2.3) }, name: "left") { wk in
                for e in TD.elevs {   // 兩部電梯門（10-22）：第 0 部 z −1.8…−0.8、第 1 部 z −3.4…−2.4。10-25：實心門板拿掉，改玻璃滑門（landingDoor）＋門框
                    for z: Float in [e.y - 0.5, e.y + 0.5] { wk.b(.identity, -TD.W / 2 + 0.17, r, z, 0.06, 2.3, 0.1, TM.f(TP.ST1)) }
                    wk.b(.identity, -TD.W / 2 + 0.17, r + 2.1, e.y, 0.06, 0.2, 1.1, TM.f(TP.ST1))
                }
            }, n: normals[2], glass: false),
            Facade(node: wall(3, h: h, mat: TM.f(TP.WL2), name: "right"), n: normals[3], glass: false),
        ]
        // 主牆：胡桃木細格柵（10-22 大樓加深後變成前台跟後段咖啡館的隔屏，兩側留走道）
        let divZ = TowerLobby.divZ
        // 只擋在前台正後方（x −1.4…2.0）：兩側看得進咖啡館
        k.b(.identity, 0.3, r, divZ, 3.5, 0.45, 0.12, TM.f(TP.FN1))
        for i in 0..<13 { k.b(.identity, -1.4 + Float(i) * 0.28, r + 0.45, divZ, 0.06, 2.35, 0.08, TM.f(TP.FN1)) }
        // 前台：胡桃木量體＋霧白檯面
        k.b(.identity, 0.3, r, 0.1, 2.6, 1.05, 0.75, TM.f(TP.FN1)); k.b(.identity, 0.3, r + 1.05, 0.1, 2.7, 0.04, 0.85, TM.f(TP.FN5))
        for i in 0..<3 { k.b(.identity, -0.45 + Float(i) * 0.75, r + 1.6, divZ + 0.14, 0.7, 0.44, 0.05, TM.f(TP.FN6)) }
        k.b(.identity, 1.4, r + 1.09, 0.3, 0.06, 0.6, 0.06, TM.f(0x9CA3AF))          // Wi-Fi 天線桿（10-21 稽核：原本 x 1.75 在檯面外、懸空，還插進保全的帽簷）
        // 等候長凳、植栽、雜誌架
        k.b(.identity, -3.9, r, 1.5, 2.0, 0.45, 0.5, TM.f(TP.FN2))
        TowerProps.all["plant_tall"]!.build(k, Xf(x: 5.3, y: r, z: -2.1), TM.f(TP.FN4), { _, _ in TM.f(TP.FN4) })
        TowerProps.all["plant_low"]!.build(k, Xf(x: -2.1, y: r, z: -2.3), TM.f(TP.FN4), { _, _ in TM.f(TP.FN4) })   // 左邊改矮盆栽：讓出電梯→咖啡館的走道、不擋沙發區
        TowerProps.all["plant_low"]!.build(k, Xf(x: 2.5, y: r, z: 2.2), TM.f(TP.FN4), { _, _ in TM.f(TP.FN4) })
        TowerProps.all["side_table"]!.build(k, Xf(x: -5.3, y: r, z: 1.5), TM.f(TP.FN4), { _, _ in TM.f(TP.FN4) })
        pendant(k, x: 0.3, z: 0.1, len: 3.4, ceil: r + h, off: false)
        k.b(.identity, TD.slideX, 0, TD.slideZ, 1.2, 0.1, 1.2, TM.slab)             // 溜滑梯出口落地平台
        cafe(k, h: h)
        // 10-20 第 4 棒：3D 門牌（「AI 工作戰情中心」「01 大廳・前台保全」）拿掉：遠看是讀不到的另一套字；樓層名改由螢幕空間標籤畫
        p.boxes = m.boxes
        p.node.addChildNode(m.node(name: "static"))
        p.node.addChildNode(TowerLobby.neon("Coffeeshop", at: SIMD3(-3.6, r + 2.75, TD.backZ + 0.06), w: 2.6, h: 0.7))
        if sign { p.node.addChildNode(storefront(y0: Float(TowerSpec.lobbyHeight) - 0.55, h: 0.8)) }
        for f in p.facades { p.node.addChildNode(f.node) }
        return p
    }

    /// 一樓後段咖啡館的紅磚牆（貼在後牆內側，跟後牆一起 cutaway）
    static func cafeBricks(_ k: Kit, h: Float) {
        let z = TD.backZ + 0.015, x0: Float = -5.85, x1: Float = 5.2, top = min(h, 3.5)
        k.b(.identity, (x0 + x1) / 2, TD.room, z - 0.005, x1 - x0, top, 0.01, TM.f(0xCDBFAE))      // 灰縫
        let bw: Float = 0.42, bh: Float = 0.17
        var row = 0
        var y = TD.room + 0.02
        while y + bh <= TD.room + top {
            var x = x0 + (row % 2 == 0 ? 0.02 : -bw / 2 + 0.02)
            var i = 0
            while x < x1 - 0.05 {
                let a = max(x, x0 + 0.02), b = min(x + bw - 0.03, x1 - 0.02)
                if b - a > 0.05 {
                    let c: UInt32 = [0x9A4631, 0xA9553B, 0x8C3F2C, 0xB0624A][(row * 7 + i * 3) % 4]
                    k.b(.identity, (a + b) / 2, y, z + 0.012, b - a, bh - 0.03, 0.02, TM.f(c))
                }
                x += bw; i += 1
            }
            y += bh; row += 1
        }
    }

    /// 一樓後段：荷蘭 coffeeshop 風休息區（10-22 Kang：員工有地方 chill；下雨天休息的人都來這）
    /// 左：橘色地毯＋沙發＋懶骨頭；中：立食桌；右：吧台（台夫特藍磁磚、咖啡機、吊燈）＋荷蘭腳踏車；隔屏後一排鬱金香
    static func cafe(_ k: Kit, h: Float) {
        let r = TD.room, bz = TD.backZ, ceil = r + h
        let none: (CGFloat, CGFloat) -> SCNMaterial = { _, _ in TM.f(TP.FN4) }
        // 地坪：咖啡館區換成深色木地板
        k.b(.identity, 0, TD.slab + 0.005, (bz + TowerLobby.divZ) / 2 - 0.1, TD.W - 0.32, 0.01, TowerLobby.divZ - bz - 0.25, TM.f(0x7A5A40))
        // 沙發區
        k.b(.identity, -3.6, r + 0.01, bz + 1.2, 3.4, 0.01, 1.7, TM.f(0xE07B39))                      // 荷蘭橘地毯
        k.b(.identity, -3.6, r, bz + 0.45, 2.2, 0.42, 0.8, TM.f(0x3E5A4C)); k.b(.identity, -3.6, r + 0.42, bz + 0.14, 2.2, 0.42, 0.18, TM.f(0x3E5A4C))   // 墨綠絨布沙發
        for dx: Float in [-1.05, 1.05] { k.b(.identity, -3.6 + dx, r, bz + 0.45, 0.14, 0.62, 0.8, TM.f(0x34503F)) }
        for x: Float in [-5.25, -1.95] { TowerProps.all["side_table"]!.build(k, Xf(x: x, y: r, z: bz + 0.4), TM.f(TP.FN4), none) }
        k.b(.identity, -5.25, r + 0.52, bz + 0.4, 0.14, 0.16, 0.14, TM.glow(TP.LT1, 0.2, 1.2))     // 小檯燈
        k.b(.identity, -1.95, r + 0.52, bz + 0.4, 0.1, 0.1, 0.1, TM.f(TP.FN5))                       // 咖啡杯
        TowerProps.all["beanbag"]!.build(k, Xf(x: -1.2, y: r, z: bz + 0.55), TM.f(0xE0B04A), none)
        TowerProps.all["floor_lamp"]!.build(k, Xf(x: -5.5, y: r, z: bz + 2.15), TM.f(TP.FN4), { _, _ in TM.glow(TP.LT1, 0.2, 1.4) })
        // 立食桌
        let tz = bz + 1.15
        k.b(.identity, 0, r, tz, 0.08, 1.0, 0.08, TM.f(TP.FN3)); k.b(.identity, 0, r, tz, 0.5, 0.04, 0.5, TM.f(TP.FN3))
        k.b(.identity, 0, r + 1.0, tz, 0.75, 0.05, 0.75, TM.f(TP.FN1))
        k.b(.identity, -0.15, r + 1.05, tz + 0.05, 0.09, 0.1, 0.09, TM.f(TP.FN5)); k.b(.identity, 0.18, r + 1.05, tz - 0.05, 0.09, 0.1, 0.09, TM.f(TP.FN5))
        // 吧台：胡桃木＋台夫特藍白磁磚腰帶
        let bx: Float = 2.9, bw: Float = 3.2, bzc = bz + 0.5
        k.b(.identity, bx, r, bzc, bw, 1.02, 0.6, TM.f(TP.FN1)); k.b(.identity, bx, r + 1.02, bzc, bw + 0.1, 0.04, 0.7, TM.f(0x2B2C2F))
        for i in 0..<16 { for j in 0..<2 {
            k.b(.identity, bx - bw / 2 + 0.1 + Float(i) * 0.2, r + 0.3 + Float(j) * 0.2, bzc + 0.305, 0.18, 0.18, 0.01, TM.f((i + j) % 2 == 0 ? 0x2F5FA8 : 0xF3F1EC))
        } }
        k.b(.identity, 2.1, r + 1.06, bzc - 0.05, 0.55, 0.42, 0.4, TM.f(0xB8BCC2)); k.b(.identity, 2.1, r + 1.38, bzc + 0.16, 0.5, 0.06, 0.04, TM.f(0xC0392B))   // 咖啡機
        k.b(.identity, 2.75, r + 1.06, bzc - 0.05, 0.2, 0.45, 0.2, TM.f(TP.FN3))                     // 磨豆機
        for i in 0..<4 { k.b(.identity, 3.3 + Float(i) * 0.22, r + 1.06, bzc + 0.1, 0.1, 0.11, 0.1, TM.f(TP.FN5)) }   // 杯子
        // 吧台後：層板＋豆罐、黑板菜單
        k.b(.identity, bx, r + 1.45, bz + 0.15, 2.8, 0.04, 0.26, TM.f(TP.FN1))
        for i in 0..<7 { k.b(.identity, bx - 1.2 + Float(i) * 0.4, r + 1.49, bz + 0.15, 0.16, 0.24, 0.16, TM.f([0x6B4A33, 0xD9D4CB, 0x3E2A1E][i % 3])) }
        k.b(.identity, bx, r + 1.85, bz + 0.04, 1.7, 0.7, 0.03, TM.f(0x24302A))
        for i in 0..<4 { k.b(.identity, bx - 0.25, r + 2.32 - Float(i) * 0.14, bz + 0.06, 0.9 - Float(i % 2) * 0.3, 0.03, 0.01, TM.f(0xE8E4DA)) }
        // 吧台吊燈
        for x: Float in [2.0, 2.9, 3.8] {
            k.b(.identity, x, ceil - 0.75, bzc + 0.1, 0.02, 0.75, 0.02, TM.f(TP.FN3))
            k.b(.identity, x, ceil - 0.95, bzc + 0.1, 0.3, 0.2, 0.3, TM.f(TP.FN3))
            k.b(.identity, x, ceil - 0.99, bzc + 0.1, 0.22, 0.05, 0.22, TM.glow(TP.LT1, 0.3, 1.6))
        }
        // 荷蘭腳踏車（墨綠車架、黑輪、前籃），靠右牆
        let wx: Float = 5.55
        for wz: Float in [bz + 1.5, bz + 2.5] {
            for (dy, dz, hh, dd) in [(0.0, 0.0, 0.05, 0.5), (0.6, 0.0, 0.05, 0.5), (0.05, -0.27, 0.55, 0.05), (0.05, 0.27, 0.55, 0.05)] as [(Float, Float, Float, Float)] {
                k.b(.identity, wx, r + dy, wz + dz, 0.04, hh, dd, TM.f(0x1E2024))
            }
        }
        k.b(.identity, wx, r + 0.33, bz + 2.0, 0.05, 0.05, 1.0, TM.f(0x2E5A44))
        k.b(.identity, wx, r + 0.33, bz + 1.7, 0.05, 0.55, 0.05, TM.f(0x2E5A44)); k.b(.identity, wx, r + 0.85, bz + 1.7, 0.2, 0.06, 0.25, TM.f(0x3A2A1E))   // 座管＋座墊
        k.b(.identity, wx, r + 0.33, bz + 2.4, 0.05, 0.7, 0.05, TM.f(0x2E5A44)); k.b(.identity, wx, r + 1.02, bz + 2.4, 0.5, 0.04, 0.05, TM.f(0x1E2024))    // 龍頭
        k.b(.identity, wx, r + 0.72, bz + 2.65, 0.3, 0.22, 0.25, TM.f(0xB08A5A))                         // 前籃
        TowerProps.all["plant_tall"]!.build(k, Xf(x: 5.35, y: r, z: bz + 0.5), TM.f(TP.FN4), none)
        // 隔屏後一排鬱金香（紅、黃、粉、橘）
        k.b(.identity, 0.3, r, TowerLobby.divZ - 0.28, 3.4, 0.35, 0.3, TM.f(0x5A4A3A))
        for i in 0..<14 {
            let x = -1.3 + Float(i) * 0.245
            k.b(.identity, x, r + 0.35, TowerLobby.divZ - 0.28, 0.025, 0.25, 0.025, TM.f(TP.PL1))
            k.b(.identity, x, r + 0.58, TowerLobby.divZ - 0.28, 0.09, 0.11, 0.09, TM.f([0xD7263D, 0xF2C14E, 0xF08BB0, 0xF47C2C][i % 4]))
        }
        // 沙發區暖光吊燈
        k.b(.identity, -3.6, ceil - 0.6, bz + 1.05, 0.02, 0.6, 0.02, TM.f(TP.FN3))
        k.b(.identity, -3.6, ceil - 0.85, bz + 1.05, 0.5, 0.25, 0.5, TM.f(0xE0B04A)); k.b(.identity, -3.6, ceil - 0.88, bz + 1.05, 0.4, 0.04, 0.4, TM.glow(TP.LT1, 0.3, 1.6))
    }

    /// 公司招牌（10-22 Kang：一、二樓中間那條改成 Okle42 招牌）：閒置薄層（0.9 高）正面整條黑色招牌，白字置中；
    /// 沒有閒置專案（沒有薄層）時改掛在大廳正面頂端。
    /// 夜晚字會亮、停電跟著熄（走 VoxMat 的發光清單）
    static let brand = "Okle42"
    /// 招牌材質（同尺寸只做一次：模組重建時不重複登記發光清單）
    private static var signMats: [String: SCNMaterial] = [:]
    static func signMaterial(w: CGFloat, h: CGFloat) -> SCNMaterial {
        let key = "\(w)x\(h)"
        if let m = signMats[key] { return m }
        let px: CGFloat = 160                      // 每公尺幾點
        let size = NSSize(width: w * px, height: h * px)
        let img = NSImage(size: size, flipped: false) { r in
            VoxMat.color(0x16181C).setFill(); r.fill()
            VoxMat.color(0x2A2E35).setFill(); NSRect(x: 0, y: r.height - 6, width: r.width, height: 6).fill()   // 上緣一道亮邊
            // 10-22 Kang：字再大、「42」用金色
            let font = NSFont.systemFont(ofSize: r.height * 0.8, weight: .heavy)
            let t = NSMutableAttributedString(string: brand, attributes: [.font: font, .foregroundColor: VoxMat.color(0xF4F2EE), .kern: r.height * 0.05])
            if let g = brand.range(of: "42") { t.addAttribute(.foregroundColor, value: VoxMat.color(0xE0B04A), range: NSRange(g, in: brand)) }
            let ts = t.size()
            t.draw(at: NSPoint(x: (r.width - ts.width) / 2, y: (r.height - ts.height) / 2))
            return true
        }
        let m = SCNMaterial()
        let cg = OfficeBuilder.raster(img, scale: 1)
        m.diffuse.contents = cg; m.emission.contents = cg
        m.diffuse.mipFilter = .linear; m.diffuse.minificationFilter = .linear
        m.lightingModel = .lambert
        VoxMat.registerGlow(m, day: 0.35, night: 1.0)
        signMats[key] = m
        return m
    }

    /// y0＝招牌底邊、h＝高（模組座標）
    static func storefront(y0: Float, h hh: Float) -> SCNNode {
        let h = CGFloat(hh), y = CGFloat(y0) + h / 2
        let n = SCNNode(); n.name = "storefront"
        /// 一面招牌：中心 (x, z)、寬 w、朝向 a（0＝朝 +z）；黑盒厚 6 公分在後、字面在前
        func side(w: CGFloat, x: CGFloat, z: CGFloat, a: CGFloat) {
            let g = SCNNode(); g.position = SCNVector3(x, y, z); g.eulerAngles.y = a
            let pl = SCNPlane(width: w, height: h); pl.firstMaterial = signMaterial(w: w, h: h)
            let face = SCNNode(geometry: pl); face.position.z = 0.035
            let box = SCNNode(geometry: SCNBox(width: w, height: h, length: 0.06, chamferRadius: 0))
            box.geometry!.firstMaterial = TM.f(0x16181C)
            g.addChildNode(box); g.addChildNode(face); n.addChildNode(g)
        }
        // 10-22 Kang：除了電梯那一側（左），前、右、後三面都要有招牌
        side(w: CGFloat(TD.W) + 0.1, x: 0, z: CGFloat(TD.zF) + 0.035, a: 0)                                  // 正面
        side(w: CGFloat(TD.D) - 0.6, x: CGFloat(TD.W / 2) + 0.035, z: CGFloat(TD.zC), a: .pi / 2)            // 右側：貼牆，夾在前後兩根結構柱中間（10-22 Kang：原本在柱子外面、看起來飄在空中）
        // 背面：整面（10-22 Kang：右端空一塊不行）；溜滑梯往後退到 zB−1.0，螺旋外緣離牆 0.18，不會穿過招牌
        side(w: CGFloat(TD.W) + 0.1, x: 0, z: CGFloat(TD.zB) - 0.035, a: .pi)
        // 四個角：結構柱轉到靠鏡頭那側會淡掉（cutaway）⇒ 招牌轉角露出一個缺口像破圖（10-22 Kang）。
        // 招牌高度那一段補一塊跟柱子同位置的黑色轉角塊，招牌自己的一部分，不跟著柱子藏
        for x: Float in [-TD.W / 2 - 0.15, TD.W / 2 + 0.15] {
            for z: Float in [TD.zB + 0.15, TD.zF - 0.15] {
                let c = SCNNode(geometry: SCNBox(width: 0.34, height: h, length: 0.34, chamferRadius: 0))
                c.geometry!.firstMaterial = TM.f(0x16181C)
                c.position = SCNVector3(CGFloat(x), y, CGFloat(z))
                n.addChildNode(c)
            }
        }
        return n
    }

    // MARK: 頂樓空中花園（12×5.6，棚架 2.1）

    static func roof() -> ModuleParts {
        var p = ModuleParts()
        let m = VoxelMesh(), k = Kit(m: m)
        let r = TD.room
        shell(k, floorColor: TP.FL1, h: 0, neon: true)
        for x: Float in [-4.4, -0.9, 2.6] {
            let z = TD.zB + 0.55
            k.b(.identity, x, r, z, 2.2, 0.5, 0.8, TM.slab)
            k.b(.identity, x, r + 0.5, z, 2.0, 0.08, 0.6, TM.f(TP.soil))
            k.b(.identity, x, r + 0.55, z, 0.12, 0.9, 0.12, TM.f(TP.FN1))
            k.b(.identity, x, r + 1.35, z, 1.2, 0.85, 0.9, TM.f(TP.PL1))
            k.b(.identity, x + 0.2, r + 2.1, z - 0.05, 0.7, 0.5, 0.6, TM.f(TP.PL2))
        }
        // 黑鐵棚架＋暖光串燈
        for (x, z) in [(-2.4, -0.5), (1.4, -0.5), (-2.4, 1.9), (1.4, 1.9)] as [(Float, Float)] { k.b(.identity, x, r, z, 0.1, 2.1, 0.1, TM.f(TP.FN3)) }
        for i in 0..<6 { k.b(.identity, -2.4 + Float(i) * 0.76, r + 2.1, 0.7, 0.06, 0.1, 2.5, TM.f(TP.FN3)) }
        k.b(.identity, -0.5, r + 1.98, 0.7, 3.8, 0.02, 0.02, TM.glow(TP.LT1, 0, 1.6))
        // 長椅、咖啡吧
        k.b(.identity, -3.6, r, 1.9, 2.2, 0.42, 0.7, TM.f(TP.FN2)); k.b(.identity, -3.6, r + 0.42, 2.18, 2.2, 0.4, 0.15, TM.f(TP.FN2))
        k.b(.identity, 3.3, r, -0.15, 2.0, 1.0, 0.65, TM.f(TP.FN1)); k.b(.identity, 3.3, r + 1.0, -0.15, 2.1, 0.04, 0.75, TM.f(TP.FN5))
        k.b(.identity, 2.8, r + 1.04, -0.25, 0.3, 0.4, 0.3, TM.f(TP.FN3))
        // 溜滑梯入口平台、天線＋NE-2
        k.b(.identity, 5.6, r, TD.zB + 0.4, 0.7, 0.25, 0.7, TM.slab)
        k.b(.identity, 4.8, r, TD.zB + 0.4, 0.1, 2.4, 0.1, TM.f(0x9AA3B2)); k.b(.identity, 4.8, r + 2.4, TD.zB + 0.4, 0.26, 0.26, 0.26, TM.glow(TP.NE2, 0.5, 2.0))
        // 欄杆扶手（石墨鋼；玻璃是 cutaway 的四面）
        k.b(.identity, 0, r + 1.0, TD.zF - 0.05, TD.W, 0.05, 0.06, TM.f(TP.ST1))
        for x: Float in [-TD.W / 2 + 0.05, TD.W / 2 - 0.05] { k.b(.identity, x, r + 1.0, TD.zC, 0.06, 0.05, TD.D, TM.f(TP.ST1)) }
        let rail = TM.glass(0.25)
        func railNode(_ side: Int) -> SCNNode {
            let mm = VoxelMesh()
            switch side {
            case 0: mm.box(.identity, SIMD3(0, r + 0.5, TD.zB + 0.03), SIMD3(TD.W, 1.0, 0.03), rail)
            case 1: mm.box(.identity, SIMD3(0, r + 0.5, TD.zF - 0.05), SIMD3(TD.W, 1.0, 0.03), rail)
            case 2: mm.box(.identity, SIMD3(-TD.W / 2 + 0.05, r + 0.5, TD.zC), SIMD3(0.03, 1.0, TD.D), rail)
            default: mm.box(.identity, SIMD3(TD.W / 2 - 0.05, r + 0.5, TD.zC), SIMD3(0.03, 1.0, TD.D), rail)
            }
            return mm.node(name: "rail\(side)")
        }
        p.facades = (0..<4).map { Facade(node: railNode($0), n: normals[$0], glass: true) }
        p.boxes = m.boxes
        p.node.addChildNode(m.node(name: "static"))
        for f in p.facades { p.node.addChildNode(f.node) }
        return p
    }

    /// 搬家時樓板底下的 NE-1 光框
    static func glowFrame() -> SCNNode {
        let m = VoxelMesh(), mat = TM.glow(TP.NE1, 0.6, 1.6)
        let w = TD.W + 0.2, d = TD.D + 0.2
        m.box(.identity, SIMD3(0, -0.03, TD.zC + d / 2), SIMD3(w, 0.04, 0.04), mat)
        m.box(.identity, SIMD3(0, -0.03, TD.zC - d / 2), SIMD3(w, 0.04, 0.04), mat)
        m.box(.identity, SIMD3(-w / 2, -0.03, TD.zC), SIMD3(0.04, 0.04, d), mat)
        m.box(.identity, SIMD3(w / 2, -0.03, TD.zC), SIMD3(0.04, 0.04, d), mat)
        return m.node(name: "glowframe")
    }
}

/// 一樓咖啡館的共用尺寸＋霓虹字招牌
@MainActor
enum TowerLobby {
    /// 前台格柵隔屏的位置（原本的後牆，加深前的 backZ）
    static let divZ: Float = -2.65
    private static var neonMats: [String: SCNMaterial] = [:]
    /// 霓虹字（綠，夜晚亮、停電熄）：貼牆的透明底平面
    static func neon(_ text: String, at p: SIMD3<Float>, w: CGFloat = 2.2, h: CGFloat = 0.5) -> SCNNode {
        let m: SCNMaterial
        if let c = neonMats[text] { m = c } else {
            let px: CGFloat = 200
            let img = NSImage(size: NSSize(width: w * px, height: h * px), flipped: false) { r in
                NSColor.clear.setFill(); r.fill()
                let font = NSFont(name: "SnellRoundhand-Bold", size: r.height * 0.78) ?? NSFont.systemFont(ofSize: r.height * 0.7, weight: .bold)
                let t = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: VoxMat.color(0x6BF08A)])
                let ts = t.size()
                t.draw(at: NSPoint(x: (r.width - ts.width) / 2, y: (r.height - ts.height) / 2))
                return true
            }
            m = SCNMaterial()
            let cg = OfficeBuilder.raster(img, scale: 1)
            m.diffuse.contents = cg; m.emission.contents = cg
            m.lightingModel = .constant; m.blendMode = .alpha; m.writesToDepthBuffer = false
            VoxMat.registerGlow(m, day: 0.7, night: 1.0)
            neonMats[text] = m
        }
        let pl = SCNPlane(width: w, height: h); pl.firstMaterial = m
        let n = SCNNode(geometry: pl); n.name = "neon"
        n.simdPosition = p
        return n
    }
}

/// 滑門的幾何（10-25）：兩片沿 axis 往外滑；第 side（L＝+1、R＝−1）片在開度 k 的位置
struct SlideDoor: Sendable {
    var axis: SIMD3<Float>, w: Float, slide: Float
    func pos(_ side: Float, _ k: Float) -> SIMD3<Float> { axis * side * (w / 2 + slide * k) }
    /// 電梯門：沿 z，各 0.45、滑 0.43（＝TowerCore.doorW／doorSlide）
    static let elevator = SlideDoor(axis: SIMD3(0, 0, 1), w: 0.45, slide: 0.43)
    /// 1 樓正門（Kang：對開電動側滑玻璃門）：沿 x，招牌正下方，門洞 −0.9…0.9（兩側門框中心 ±0.9）
    static let front = SlideDoor(axis: SIMD3(1, 0, 0), w: 0.86, slide: 0.82)
}

// MARK: - 模組外：結構柱、電梯井、溜滑梯、天際線

@MainActor
enum TowerCore {
    /// 結構柱＋玻璃電梯井（4 根角柱＋每層一道橫框，玻璃照 cutaway）＋溜滑梯（右後角、後牆後面，整條合併一個 mesh）。
    /// 10-20 UI/UX 優化 §3.4：原本 2×2 灰色實心井（畫面左邊一大條）、溜滑梯在右外側半徑 1.1（佔畫面寬 12%）⇒ 視覺重量減半
    static func build(top: Float, roofFloor: Float, floorYs: [Float] = []) -> (node: SCNNode, facades: [Facade]) {
        let root = SCNNode(); root.name = "core"
        let m = VoxelMesh(), k = Kit(m: m)
        var facades: [Facade] = []
        // 四根結構柱：各自一個 cutaway 節點（10-20 UI/UX 優化：轉到側面時正前方那根柱子剛好切過整棟中間，跟著牆一起藏）
        for x: Float in [-TD.W / 2 - 0.15, TD.W / 2 + 0.15] {
            for z: Float in [TD.zB + 0.15, TD.zF - 0.15] {
                let cm = VoxelMesh(); Kit(m: cm).b(.identity, x, 0, z, 0.3, top + 0.3, 0.3, TM.f(TP.ST1))
                let node = cm.node(name: "column"); root.addChildNode(node)
                facades.append(Facade(node: node, n: simd_normalize(SIMD2(x > 0 ? 1 : -1, z > 0 ? 1 : -1)), glass: false, cut: 0.8))
            }
        }
        // 電梯井（10-22 Kang 兩部電梯）：沿 z 排一列，每座 x 寬 1.4；相鄰兩座共用中間那道隔板（取兩車廂中心的中點：
        // z −1.3／−2.9 ⇒ 前緣 −0.6、隔板 −2.1、後緣 −3.6），角柱、橫框、玻璃都只畫一次，不重疊、不 z-fighting
        let H = top + 0.9, e: Float = 0.7
        let y0 = OfficeBasement.baseY       // 10-22 Kang：電梯井往下通到 B1 機房
        let ex = TD.elevs.map(\.x), ez = TD.elevs.map(\.y)
        // 每座井沿 z 的範圍 (前緣, 後緣)：外側離車廂中心 0.7，中間取中點
        let spans: [(Float, Float)] = ez.indices.map { c in
            (c == 0 ? ez[c] + e : (ez[c - 1] + ez[c]) / 2, c == ez.count - 1 ? ez[c] - e : (ez[c] + ez[c + 1]) / 2)
        }
        // 每道橫向邊界（前緣、各隔板、後緣）各一組角柱＋每層橫框；左側每座各自一條縱框
        let bounds = [spans[0].0] + spans.map(\.1)
        for (i, z) in bounds.enumerated() {
            let x = i < ex.count ? ex[i] : ex[ex.count - 1]
            for dx in [-e, e] { k.b(.identity, x + dx, y0, z, 0.08, H - y0, 0.08, TM.f(TP.ST1)) }
            for y in floorYs + [y0] { k.b(.identity, x, y + 0.02, z, 1.4, 0.06, 0.06, TM.f(TP.ST1)) }
            // 10-22 Kang 科技感：外側角柱貼一條細 LED（白天淡、夜晚亮）
            k.b(.identity, x - e - 0.045, y0, z, 0.012, H - y0, 0.03, TM.glow(TP.ELEV_LED, 0.5, 2.2))
        }
        for c in ez.indices {
            let (z0, z1) = spans[c], d = z0 - z1
            for y in floorYs + [y0] {
                k.b(.identity, ex[c] - e, y + 0.02, (z0 + z1) / 2, 0.06, 0.06, d, TM.f(TP.ST1))
                k.b(.identity, ex[c] - e - 0.035, y + 0.035, (z0 + z1) / 2, 0.012, 0.025, d - 0.1, TM.glow(TP.ELEV_LED, 0.5, 2.2))   // 每層一道發光橫框
            }
            // 頂蓋：只有最外側兩端各多出 0.05（跟原本 1.5 見方一樣出簷），中間接縫剛好接上、不重疊
            let c0 = z0 + (c == 0 ? 0.05 : 0), c1 = z1 - (c == ez.count - 1 ? 0.05 : 0)
            k.b(.identity, ex[c], H, (c0 + c1) / 2, 1.5, 0.1, c0 - c1, TM.f(TP.ST1))
        }
        // 樓層看板的立柱（10-21 稽核：看板原本浮在電梯井外的半空中、轉向鏡頭時還插進電梯井）：
        // 看板掛在這根柱子上、只繞柱子轉（柱心＝看板轉軸，看板永遠在柱子靠鏡頭那一側）
        // 只在有看板顯示時才出現（鏡頭遠時看板全藏，剩一根光禿禿的長桿很怪）：獨立節點，updateLOD 跟著看板開關
        let mast = VoxelMesh(), mk = Kit(m: mast)
        mk.b(.identity, TD.boardX, 0, TD.boardZ, 0.9, 0.12, 0.9, TM.f(TP.ST2))
        mk.b(.identity, TD.boardX, 0.12, TD.boardZ, 0.16, top + 0.2, 0.16, TM.f(TP.ST1))
        let mn = mast.node(name: "board-mast"); mn.isHidden = true
        root.addChildNode(mn)
        func pane(_ name: String, _ c: SIMD3<Float>, _ s: SIMD3<Float>, n: SIMD2<Float>) {
            let mm = VoxelMesh(); mm.box(.identity, c, s, TM.glass(0.12))
            let node = mm.node(name: name); root.addChildNode(node)
            facades.append(Facade(node: node, n: n, glass: true))
        }
        // 玻璃（cutaway）：每座 back／left 各一片（名字加編號）；front 只有最前面那座有，後面幾座的前面＝前一座的 back（共用，不重複）
        for c in ez.indices {
            let (z0, z1) = spans[c], d = z0 - z1
            let cy = (H + y0) / 2, hh = H - y0
            if c == 0 { pane("shaft-front\(c)", SIMD3(ex[c], cy, z0), SIMD3(1.4, hh, 0.02), n: SIMD2(0, 1)) }
            pane("shaft-back\(c)", SIMD3(ex[c], cy, z1), SIMD3(1.4, hh, 0.02), n: SIMD2(0, -1))
            pane("shaft-left\(c)", SIMD3(ex[c] - e, cy, (z0 + z1) / 2), SIMD3(0.02, hh, d), n: SIMD2(-1, 0))
        }
        // 溜滑梯：從頂樓平台往下螺旋到大廳；每 0.5 弧度一段（滑面＋外側擋板，ST-2 跟樓板同色、低對比），中央柱 ST-1
        let slideTop = roofFloor + TD.room + 0.25
        let steps = max(1, Int((slideTop - TD.room) / TD.slideDrop))
        let sm = VoxelMesh()
        for i in 0...steps {
            let th = TD.slideA0 + Float(i) * TD.slideStep
            let y = slideTop - Float(i) * TD.slideDrop
            let p = TD.slidePoint(th, top: slideTop, y: y)
            sm.box(Xf(x: p.x, y: y - 0.03, z: p.z, a: -th), SIMD3(0, 0, 0), SIMD3(0.45, 0.06, 0.3), TM.slab)
            let o = SIMD3<Float>(TD.slideX + (TD.slideR + 0.22) * cos(th), y + 0.06, TD.slideZ + (TD.slideR + 0.22) * sin(th))
            sm.box(Xf(x: o.x, y: o.y, z: o.z, a: -th + .pi / 2), SIMD3(0, 0, 0), SIMD3(0.45, 0.16, 0.03), TM.slab)
        }
        Kit(m: sm).b(.identity, TD.slideX, 0, TD.slideZ, 0.1, slideTop + 0.5, 0.1, TM.f(TP.ST1))
        let slide = sm.node(name: "slide"); root.addChildNode(slide)
        facades.append(Facade(node: slide, n: simd_normalize(SIMD2(1, -1)), glass: false, cut: 0.5))   // 溜滑梯是實心的，擋到要藏
        root.insertChildNode(m.node(name: "core-static"), at: 0)
        return (root, facades)
    }

    // MARK: 電梯玻璃滑門（10-25 Kang：每層都要有門、透明玻璃、左門往左滑右門往右滑、電梯到了才開）

    /// 門洞 0.9 寬：兩片各 0.45；開門時各往外滑 0.43（滑進牆裡）
    static let doorW: Float = 0.45, doorH: Float = 2.08, doorSlide: Float = 0.43
    /// 開／關門動畫秒數、到站後開著等多久才關
    static let doorTime: TimeInterval = 0.6, doorDwell: TimeInterval = 3

    /// 第 c 部電梯的一組滑門（掛在樓層模組底下，跟著樓層搬家）。站在大樓裡面向電梯看：左手邊＝+z、右手邊＝−z
    /// 子節點 L（往 +z 滑）、R（往 −z 滑）；位置在牆的中線（關著剛好填滿門洞，開了滑進牆裡）
    static func landingDoor(_ c: Int) -> SCNNode {
        let n = SCNNode(); n.name = "edoor-\(c)"
        n.simdPosition = SIMD3(-TD.W / 2 + 0.075, TD.room, TD.elevs[c].y)
        let steel = TM.f(TP.ST1), led = TM.glow(TP.ELEV_LED, 0.4, 1.8)
        for (name, side) in [("L", Float(1)), ("R", Float(-1))] {
            let panel = SCNNode(); panel.name = name
            panel.simdPosition = SIMD3(0, 0, side * doorW / 2)
            // 玻璃：不寫深度、排在不透明的後面畫（renderingOrder），不跟樓板、門框搶深度閃爍
            let g = SCNNode(geometry: SCNBox(width: 0.02, height: CGFloat(doorH - 0.1), length: CGFloat(doorW - 0.05), chamferRadius: 0))
            g.geometry?.firstMaterial = TM.glass(0.2)
            g.simdPosition = SIMD3(0, doorH / 2, 0); g.renderingOrder = 10; g.castsShadow = false
            panel.addChildNode(g)
            // 細鋼框（上下橫檔、外側直框）＋內側對接邊一條細 LED（關著時兩條併成門縫的一道光）
            let fm = VoxelMesh(), fk = Kit(m: fm)
            fk.b(.identity, 0, 0, 0, 0.035, 0.05, doorW, steel)
            fk.b(.identity, 0, doorH - 0.05, 0, 0.035, 0.05, doorW, steel)
            fk.b(.identity, 0, 0, side * (doorW / 2 - 0.0175), 0.035, doorH, 0.035, steel)
            fk.b(.identity, 0, 0.05, -side * (doorW / 2 - 0.008), 0.03, doorH - 0.1, 0.016, led)
            panel.addChildNode(fm.node(name: "frame"))
            n.addChildNode(panel)
        }
        return n
    }

    static let frontX: Float = 0, frontH: Float = 2.32      // 10-25：招牌正下方（原本 x 3.8）

    /// 1 樓正門的一組滑門（掛在大廳模組底下）：兩片透明玻璃＋細鋼框＋對接邊 LED；L 往 +x、R 往 −x
    static func frontDoor() -> SCNNode {
        let g = SlideDoor.front, n = SCNNode(); n.name = "fdoor"
        n.simdPosition = SIMD3(frontX, TD.room, TD.zF - 0.06)
        let steel = TM.f(TP.ST1), led = TM.glow(TP.ELEV_LED, 0.4, 1.8)
        for (name, side) in [("L", Float(1)), ("R", Float(-1))] {
            let panel = SCNNode(); panel.name = name; panel.simdPosition = g.pos(side, 0)
            let gl = SCNNode(geometry: SCNBox(width: CGFloat(g.w - 0.05), height: CGFloat(frontH - 0.1), length: 0.02, chamferRadius: 0))
            gl.geometry?.firstMaterial = TM.glass(0.2)
            gl.simdPosition = SIMD3(0, frontH / 2, 0); gl.renderingOrder = 10; gl.castsShadow = false
            panel.addChildNode(gl)
            let fm = VoxelMesh(), fk = Kit(m: fm)
            fk.b(.identity, 0, 0, 0, g.w, 0.05, 0.035, steel)
            fk.b(.identity, 0, frontH - 0.05, 0, g.w, 0.05, 0.035, steel)
            fk.b(.identity, side * (g.w / 2 - 0.0175), 0, 0, 0.035, frontH, 0.035, steel)
            fk.b(.identity, -side * (g.w / 2 - 0.008), 0.05, 0, 0.016, frontH - 0.1, 0.03, led)
            panel.addChildNode(fm.node(name: "frame"))
            n.addChildNode(panel)
        }
        return n
    }

    /// 門開幾成（0＝關、1＝全開）直接擺好（測試截圖、停車時用）
    static func setDoor(_ door: SCNNode, open k: Float, _ g: SlideDoor = SlideDoor.elevator) {
        for (name, side) in [("L", Float(1)), ("R", Float(-1))] {
            guard let p = door.childNode(withName: name, recursively: false) else { continue }
            p.removeAction(forKey: "door")
            p.simdPosition = g.pos(side, k)
        }
    }

    /// 一次性排好這組門的開關（隊長 10-25：到站開、離站關；不 repeatForever、不每幀檢查）。
    /// stops＝車廂停在這層的時段（絕對時間）；每段到了開、結束前 doorTime 關。回傳最後一個動作結束的時間（給渲染延長）
    @discardableResult
    static func runDoor(_ door: SCNNode, stops: [(from: Date, to: Date)], now: Date, _ g: SlideDoor = SlideDoor.elevator) -> Date {
        var end = now
        for (name, side) in [("L", Float(1)), ("R", Float(-1))] {
            guard let p = door.childNode(withName: name, recursively: false) else { continue }
            p.removeAction(forKey: "door")
            let shut = g.pos(side, 0), open = g.pos(side, 1)
            var acts: [SCNAction] = [], t = now, isOpen = simd_length(p.simdPosition - shut) > 0.01
            func move(_ to: SIMD3<Float>) {
                let a = SCNAction.move(to: SCNVector3(to), duration: doorTime); a.timingMode = .easeInEaseOut
                acts.append(a); t = t.addingTimeInterval(doorTime)
            }
            for st in stops.sorted(by: { $0.from < $1.from }) {
                let closeAt = st.to.addingTimeInterval(-doorTime)
                guard closeAt > max(t, st.from), closeAt > now else { continue }
                if st.from > t { acts.append(.wait(duration: st.from.timeIntervalSince(t))); t = st.from }
                if !isOpen { move(open); isOpen = true }
                if closeAt > t { acts.append(.wait(duration: closeAt.timeIntervalSince(t))); t = closeAt }
                move(shut); isOpen = false
            }
            if isOpen { move(shut) }                     // 這層沒有要停：開著的關起來
            if !acts.isEmpty { p.runAction(.sequence(acts), forKey: "door") }
            end = max(end, t)
        }
        return end
    }

    /// 電梯車廂 1.1×2.1×1.1：開口朝前、朝大樓（看得到裡面的人）
    static func car() -> SCNNode {
        let m = VoxelMesh(), k = Kit(m: m), w = TM.f(TP.FN5)
        k.b(.identity, 0, 0, 0, 1.1, 0.05, 1.1, w); k.b(.identity, 0, 2.05, 0, 1.1, 0.05, 1.1, w)
        k.b(.identity, 0, 0, -0.52, 1.1, 2.1, 0.05, w); k.b(.identity, -0.52, 0, 0, 0.05, 2.1, 1.1, w)
        k.b(.identity, 0.53, 0, 0.53, 0.04, 2.1, 0.04, TM.f(TP.ST1))
        // 10-22 Kang：「電梯移動要有光（電梯裡照明、外面玻璃井打光，高級科技感）」——全用自發光材質＋一層加色光暈，不加真的燈（不多算光照）
        let led = TM.glow(TP.ELEV_LED, 1.4, 3.0)
        k.b(.identity, 0, 1.97, 0, 0.8, 0.04, 0.8, TM.glow(TP.ELEV_LAMP, 1.2, 2.6))            // 天花燈板
        for (x, z): (Float, Float) in [(-0.48, -0.48), (0.48, -0.48), (-0.48, 0.48)] {
            k.b(.identity, x, 0.08, z, 0.03, 1.88, 0.03, led)                                       // 角落直條燈
        }
        k.b(.identity, 0.53, 0.05, 0, 0.03, 0.025, 1.0, led)                                         // 門檻燈條（面向大樓那側）
        k.b(.identity, 0, 0.05, 0.53, 1.0, 0.025, 0.03, led)
        let node = m.node(name: "car")
        // 光暈：比車廂大一圈的加色半透明盒子，跟著車廂走，隔著玻璃井看像一團光在井裡上下
        let halo = SCNNode(geometry: SCNBox(width: 1.3, height: 2.3, length: 1.3, chamferRadius: 0.05))
        let hm = SCNMaterial()
        hm.diffuse.contents = NSColor.black; hm.emission.contents = VoxMat.color(TP.ELEV_LED).blended(withFraction: 0.88, of: .black)   // 加色混合不吃 transparency：直接把光暈顏色壓暗
        hm.lightingModel = .constant; hm.blendMode = .add
        hm.writesToDepthBuffer = false
        halo.geometry?.firstMaterial = hm
        halo.name = "car-halo"; halo.position = SCNVector3(0, 1.05, 0); halo.castsShadow = false
        node.addChildNode(halo)
        return node
    }

    /// 地面＋遠景城市（白天、夜晚各一份，切換時只換顯示；夜晚多一層窗光條）
    /// 大地面（城外的地；日夜共用一個節點，底色跟著 VoxMat.setNight 換）。
    /// 10-21 Kang：背景的遠景大樓剪影拿掉（醜、佔畫面）；原本另有一塊大樓前路面被城市的路完全蓋住（重複），一起拿掉
    static func environment() -> SCNNode {
        let m = VoxelMesh(), k = Kit(m: m)
        // 10-21 主光改版：520×420 → 1600×1600（邊緣落在霧完全遮住的距離外，夜晚不會露出一塊比天空暗的長方形）
        k.b(.identity, 0, -0.4, 0, 1600, 0.4, 1600, VoxMat.dayNight(TP.groundDay, TP.groundNight))
        return m.node(name: "env")
    }

    /// 漸層天空盒（6 張 64×64 正方形：不是正方形整片會變白）。側面下半＝地平線色、上半漸到天頂；頂＝天頂、底＝地平線。
    /// 日夜各產一次；切換只換 scene.background.contents
    static let skyDay: [CGImage] = sky(TP.skyDay, TP.zenithDay)
    static let skyNight: [CGImage] = sky(TP.skyNight, TP.zenithNight)
    /// 日出日落的天空盒（10-21）：跟 sky() 同一套上下漸層，再加太陽那一側地平線的光暈（水平角 cos 衰減、往上指數衰減）。
    /// `sunAngle`＝太陽在世界座標的水平方向（弧度，(sin, 0, −cos)）；一次 6×64×64 像素，每分鐘最多一次
    nonisolated static func sky(horizon ch: SIMD3<Float>, zenith cz: SIMD3<Float>, glow: SIMD3<Float>, glowAmount: Float, sunAngle: Float) -> [CGImage] {
        let n = 64
        let sx = sin(sunAngle), sz = -cos(sunAngle)
        // 側面：法線、往右（從天空盒裡面看）
        let faces: [(SIMD3<Float>, SIMD3<Float>)] = [(SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1)),
                                                     (SIMD3(0, 0, 1), SIMD3(1, 0, 0)), (SIMD3(0, 0, -1), SIMD3(-1, 0, 0))]
        func make(_ f: (Int, Int) -> SIMD3<Float>) -> CGImage? {
            var px = [UInt8](repeating: 255, count: n * n * 4)
            for row in 0..<n { for x in 0..<n {
                let c = simd_clamp(f(row, x), SIMD3(repeating: 0), SIMD3(repeating: 255))
                let i = (row * n + x) * 4; px[i] = UInt8(c.x); px[i + 1] = UInt8(c.y); px[i + 2] = UInt8(c.z)
            } }
            return px.withUnsafeMutableBytes { b -> CGImage? in
                guard let sp = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(data: b.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: sp,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                return ctx.makeImage()
            }
        }
        let ch = ch * 255, cz = cz * 255, cg = glow * 255
        var sides: [CGImage] = []
        for (nrm, right) in faces {
            guard let im = make({ row, x in
                let u = (Float(x) + 0.5) / Float(n) * 2 - 1
                let d = nrm + right * u
                let h = simd_normalize(SIMD2(d.x, d.z))
                let toward = max(0, (h.x * sx + h.y * sz + 1) / 2)            // 1＝正對太陽、0＝背對
                let side = toward * toward * toward
                var c = ch, up: Float = 0
                if row < n / 2 {
                    let t = Float(n / 2 - 1 - row) / Float(n / 2 - 1)
                    let s = t * t * (3 - 2 * t)
                    c = ch + (cz - ch) * s; up = t
                }
                // 光暈：太陽那側最濃、背面留一點（整圈地平線都偏暖）；越往上越淡
                let w = glowAmount * (0.18 + 0.82 * side) * exp(-up * 3.2)
                return c + (cg - c) * min(1, w)
            }) else { return [] }
            sides.append(im)
        }
        guard let top = make({ _, _ in cz }), let bottom = make({ _, _ in ch }) else { return [] }
        return [sides[0], sides[1], top, bottom, sides[2], sides[3]]       // +X −X +Y −Y +Z −Z
    }

    nonisolated static func sky(_ h: UInt32, _ z: UInt32) -> [CGImage] {
        let n = 64
        func rgb(_ c: UInt32) -> SIMD3<Float> { SIMD3(Float(c >> 16 & 255), Float(c >> 8 & 255), Float(c & 255)) }
        let ch = rgb(h), cz = rgb(z)
        func img(_ f: (Int) -> SIMD3<Float>) -> CGImage? {
            var px = [UInt8](repeating: 255, count: n * n * 4)
            for row in 0..<n {          // row 0＝圖的最上面
                let c = f(row)
                for x in 0..<n { let i = (row * n + x) * 4; px[i] = UInt8(c.x); px[i + 1] = UInt8(c.y); px[i + 2] = UInt8(c.z) }
            }
            return px.withUnsafeMutableBytes { b -> CGImage? in
                guard let sp = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(data: b.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: sp,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                return ctx.makeImage()
            }
        }
        let side = img { row in
            guard row < n / 2 else { return ch }
            let t = Float(n / 2 - 1 - row) / Float(n / 2 - 1)        // 0＝地平線、1＝最上緣
            let s = t * t * (3 - 2 * t)
            return ch + (cz - ch) * s
        }
        let top = img { _ in cz }, bottom = img { _ in ch }
        guard let side, let top, let bottom else { return [] }
        return [side, side, top, bottom, side, side]       // +X −X +Y −Y +Z −Z
    }
}

// MARK: - 動畫（不綁主執行緒：SceneKit 在渲染執行緒呼叫 customAction）

/// 搬家（規範 §3.7）：0–0.45 秒往前飄出、0.45–1.45 升降（讓位的同時移動）、1.45–2.0 滑回
final class MoveAnim: @unchecked Sendable {
    struct Item { let node: SCNNode; let fromY: Float; let toY: Float; let floats: Bool; let glow: SCNNode? }
    let items: [Item]
    static let duration: Double = 2.0
    init(items: [Item]) { self.items = items }

    static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }
    /// 第 t 秒的姿勢（測試截圖直接呼叫；動畫每幀呼叫）
    func apply(_ t: Double) {
        let t = Float(t)
        for it in items {
            var y = it.fromY, z: Float = 0, a: Float = 0, lift: Float = 0, g: Float = 0
            let mid = min(max((t - 0.45) / 1.0, 0), 1)
            y = it.fromY + (it.toY - it.fromY) * Self.ease(mid)
            if it.floats {
                if t < 0.45 { let k = 1 - pow(1 - t / 0.45, 2); z = 4 * k; lift = 0.3 * k; a = -0.08 * k; g = k }
                else if t < 1.45 { z = 4; lift = 0.3; a = -0.08; g = 1 }
                else { let k = min(1, (t - 1.45) / 0.55); let e = k * k; z = 4 * (1 - e); lift = 0.3 * (1 - e); a = -0.08 * (1 - e); g = 1 - e }
            }
            it.node.position = SCNVector3(0, CGFloat(y + lift), CGFloat(z))
            it.node.eulerAngles.y = CGFloat(a)
            it.glow?.opacity = CGFloat(g)
        }
    }

    nonisolated static func action(_ anim: MoveAnim) -> SCNAction {
        SCNAction.customAction(duration: duration) { _, el in anim.apply(Double(el)) }
    }
    /// 跑在 driver 節點上；播完回主執行緒
    nonisolated static func run(_ anim: MoveAnim, on driver: SCNNode, done: @escaping @Sendable () -> Void) {
        driver.runAction(action(anim), forKey: "move") { DispatchQueue.main.async(execute: done) }
    }
}

/// 一趟閒晃的世界座標路線（模組不轉，所以本地→世界只是加樓層 y）
final class TripPath: @unchecked Sendable {
    struct Key { let t: Double; let p: SIMD3<Float>; let face: Float?; let ride: Bool }
    let keys: [Key]
    let duration: Double
    /// 每段（keys[i-1]→keys[i]）：是不是走路、走路方向、進這段前面向哪、累積走路距離（段首）、所在連續走路區間的起訖距離
    private struct Seg { var walking = false; var heading: Float = 0; var enter: Float = 0; var d0: Float = 0; var len: Float = 0; var runStart: Float = 0; var runEnd: Float = 0 }
    private let segs: [Seg]

    init(keys: [Key]) {
        self.keys = keys; duration = keys.last?.t ?? 0
        var segs = [Seg](repeating: Seg(), count: keys.count)
        var d: Float = 0, face = keys.first?.face ?? 0
        for i in keys.indices.dropFirst() {
            let a = keys[i - 1], b = keys[i], v = b.p - a.p
            var g = Seg()
            g.len = hypot(v.x, v.z)
            g.walking = !b.ride && g.len > 0.01
            g.heading = g.walking ? atan2(v.x, v.z) : (b.face ?? a.face ?? face)
            g.enter = face
            g.d0 = d
            if g.walking { d += g.len }
            face = g.walking ? g.heading : (b.face ?? a.face ?? face)
            segs[i] = g
        }
        // 連續走路的區間：起步、停下時擺幅漸入漸出
        var i = 1
        while i < keys.count {
            guard segs[i].walking else { i += 1; continue }
            var j = i
            while j + 1 < keys.count, segs[j + 1].walking { j += 1 }
            let s0 = segs[i].d0, s1 = segs[j].d0 + segs[j].len
            for k in i...j { segs[k].runStart = s0; segs[k].runEnd = s1 }
            i = j + 1
        }
        self.segs = segs
    }

    /// 轉角不瞬間轉向：進新的一段前 0.3 秒內從原本的朝向轉過去
    static let turnTime = 0.3
    static func lerpAngle(_ a: Float, _ b: Float, _ k: Float) -> Float {
        var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
        return a + d * k
    }

    /// 第 t 秒的位置、朝向、是不是在走路、走了多遠（步伐相位用）、擺幅（起步／停下漸變 0–1）
    func pose(_ t: Double) -> (p: SIMD3<Float>, face: Float, walking: Bool, dist: Float, amp: Float) {
        guard let first = keys.first else { return (.zero, 0, false, 0, 0) }
        if t <= first.t { return (first.p, first.face ?? 0, false, 0, 0) }
        for i in keys.indices.dropFirst() where t < keys[i].t {
            let a = keys[i - 1], b = keys[i], g = segs[i]
            let k = Float(b.t > a.t ? (t - a.t) / (b.t - a.t) : 1)
            let p = a.p + (b.p - a.p) * k
            guard g.walking else {
                // 停著（左右掃、等電梯）照 key 的朝向內插；搭乘（電梯、溜滑梯）同
                let fa = a.face ?? g.enter, fb = b.face ?? fa
                return (p, Self.lerpAngle(fa, fb, k), false, g.d0, 0)
            }
            let turn = Float(min(1, (t - a.t) / Self.turnTime))
            let face = Self.lerpAngle(g.enter, g.heading, turn * turn * (3 - 2 * turn))
            let d = g.d0 + g.len * k
            let amp = min(1, max(0, min(d - g.runStart, g.runEnd - d) / 0.3))
            return (p, face, true, d, amp)
        }
        let l = keys[keys.count - 1]
        return (l.p, l.face ?? 0, false, 0, 0)
    }

    /// 步態（10-24 Kang：原本兩格硬切、看起來很假）：依走過的距離算相位，腳不會在地上滑
    ///   一個完整步伐循環（左右各一步）＝ stride 公尺；腿前後 sin 擺、身體在雙腳垂直時最高（上下兩次／循環）、
    ///   左右微晃（重心移到支撐腳）、身體微微前傾；起步與停下 0.3 公尺內擺幅漸變
    static let stride: Float = 0.84, legSwing: Float = 0.5, bobH: Float = 0.035, sway: Float = 0.07, lean: Float = 0.06

    func apply(_ node: SCNNode, at t: Double) {
        let q = pose(t)
        let ph = q.dist / Self.stride * 2 * .pi
        let bob = q.walking ? Self.bobH * q.amp * (1 + cos(2 * ph)) / 2 : 0
        node.simdPosition = SIMD3(q.p.x, q.p.y + bob, q.p.z)
        node.eulerAngles.y = CGFloat(q.face)
        let swing = CGFloat(Self.legSwing * q.amp * sin(ph))
        node.childNode(withName: "legL", recursively: true)?.eulerAngles.x = swing
        node.childNode(withName: "legR", recursively: true)?.eulerAngles.x = -swing
        if let body = node.childNode(withName: "body", recursively: true) {
            body.eulerAngles.z = CGFloat(Self.sway * q.amp * sin(ph))
            body.eulerAngles.x = CGFloat(Self.lean * q.amp)
        }
    }

    nonisolated static func run(_ path: TripPath, from elapsed: Double, on node: SCNNode, done: @escaping @Sendable () -> Void) {
        let rest = max(0.05, path.duration - elapsed)
        let a = SCNAction.customAction(duration: rest) { n, el in path.apply(n, at: elapsed + Double(el)) }
        node.runAction(a, forKey: "trip") { DispatchQueue.main.async(execute: done) }
    }

    /// 車廂的一段上下（世界座標高度＋絕對時間）
    struct CarLeg: Sendable, Equatable { let y0: Float; let y1: Float; let start: Date; let end: Date }

    /// 第 at 秒車廂的高度：照排好的段落線性內插（跟搭乘的人同一條線，人才不會穿出車廂）；
    /// 第一段開始前停在 rest（現在停的高度），段落之間停在上一段的終點
    nonisolated static func carY(_ legs: [CarLeg], at: Date, rest: Float) -> Float {
        var y = rest
        for l in legs where l.start <= at {
            if at < l.end {
                let k = Float(at.timeIntervalSince(l.start) / max(0.05, l.end.timeIntervalSince(l.start)))
                return l.y0 + (l.y1 - l.y0) * min(1, max(0, k))
            }
            y = l.y1
        }
        return y
    }

    /// 一部電梯車廂照排程上下（10-22 兩部電梯：同一部可能接連載好幾趟，整份排程一次播完；其他時間停著，不跳回大廳）
    nonisolated static func runCar(_ car: SCNNode, x: Float, z: Float, legs: [CarLeg], rest: Float, now: Date) {
        car.removeAction(forKey: "car")
        guard let last = legs.map(\.end).max(), last > now else {
            car.simdPosition = SIMD3(x, carY(legs, at: now, rest: rest), z)
            return
        }
        let dur = max(0.05, last.timeIntervalSince(now))
        let a = SCNAction.customAction(duration: dur) { n, el in
            n.simdPosition = SIMD3(x, carY(legs, at: now.addingTimeInterval(Double(el)), rest: rest), z)
        }
        car.runAction(a, forKey: "car")
    }
}
